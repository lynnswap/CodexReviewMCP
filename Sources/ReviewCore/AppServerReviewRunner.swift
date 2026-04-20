import Foundation
import ReviewJobs

package struct ReviewBootstrapFailure: Error, LocalizedError, Sendable {
    package var message: String
    package var model: String?

    package init(message: String, model: String? = nil) {
        self.message = message
        self.model = model
    }

    package var errorDescription: String? {
        message
    }
}

package struct ReviewProcessOutcome: Sendable {
    package var state: ReviewJobState
    package var exitCode: Int
    package var reviewThreadID: String?
    package var threadID: String?
    package var turnID: String?
    package var model: String?
    package var hasFinalReview: Bool
    package var lastAgentMessage: String
    package var errorMessage: String?
    package var summary: String
    package var startedAt: Date
    package var endedAt: Date
    package var content: String
}

private enum AppServerReviewRunnerSignal: Sendable {
    case notification(AppServerServerNotification)
    case diagnosticLine(String)
    case stateChanged
    case timeoutFired
    case threadUnavailableGraceExpired
    case completedWithoutFinalReviewGraceExpired
    case completedTurnSettleExpired
    case transportDisconnectGraceExpired
    case interruptResolutionCheck
    case transportClosed
    case transportDisconnected(String)
}

private enum AppServerNotificationDeliveryTier: Sendable {
    case lossless
    case bestEffort
    case auxiliary
}

private struct AppServerTrackedNotificationDisposition: Sendable {
    var shouldProcess: Bool
    var countsAsActivity: Bool
}

private func codexNotificationDeliveryTier(
    _ notification: AppServerServerNotification
) -> AppServerNotificationDeliveryTier {
    switch notification {
    case .turnCompleted, .itemCompleted, .agentMessageDelta, .planDelta, .reasoningSummaryTextDelta, .reasoningTextDelta:
        .lossless
    case .commandExecutionOutputDelta:
        .bestEffort
    case .threadStatusChanged, .threadClosed, .turnStarted, .itemStarted, .reasoningSummaryPartAdded, .mcpToolCallProgress, .error, .accountLoginCompleted, .accountUpdated, .accountRateLimitsUpdated, .ignored:
        .auxiliary
    }
}

private actor AppServerReviewRunnerSignalEmitter {
    private let continuation: AsyncStream<AppServerReviewRunnerSignal>.Continuation

    init(continuation: AsyncStream<AppServerReviewRunnerSignal>.Continuation) {
        self.continuation = continuation
    }

    func yield(_ signal: AppServerReviewRunnerSignal) {
        continuation.yield(signal)
    }
}

private func makeNotificationSourceTask(
    subscription: AsyncThrowingStreamSubscription<AppServerServerNotification>,
    emitter: AppServerReviewRunnerSignalEmitter
) -> Task<Void, Never> {
    Task {
        await withTaskCancellationHandler {
            do {
                for try await notification in subscription.stream {
                    await emitter.yield(.notification(notification))
                }
                guard Task.isCancelled == false else {
                    return
                }
                await emitter.yield(.transportClosed)
            } catch {
                guard Task.isCancelled == false else {
                    return
                }
                await emitter.yield(.transportDisconnected(error.localizedDescription))
            }
        } onCancel: {
            Task {
                await subscription.cancel()
            }
        }
    }
}

private func makeStringSourceTask(
    subscription: AsyncStreamSubscription<String>,
    emitter: AppServerReviewRunnerSignalEmitter
) -> Task<Void, Never> {
    Task {
        await withTaskCancellationHandler {
            for await line in subscription.stream {
                await emitter.yield(.diagnosticLine(line))
            }
        } onCancel: {
            Task {
                await subscription.cancel()
            }
        }
    }
}

private func makeVoidSourceTask(
    subscription: AsyncStreamSubscription<Void>,
    emitter: AppServerReviewRunnerSignalEmitter
) -> Task<Void, Never> {
    Task {
        await withTaskCancellationHandler {
            for await _ in subscription.stream {
                await emitter.yield(.stateChanged)
            }
        } onCancel: {
            Task {
                await subscription.cancel()
            }
        }
    }
}

private func makeDelayedSignalTask(
    duration: Duration,
    signal: AppServerReviewRunnerSignal,
    emitter: AppServerReviewRunnerSignalEmitter,
    clock: any ReviewClock,
    yieldFirst: Bool = false
) -> Task<Void, Never> {
    Task {
        do {
            if yieldFirst {
                await Task.yield()
            }
            try Task.checkCancellation()
            try await clock.sleep(for: duration)
            try Task.checkCancellation()
        } catch {
            return
        }
        await emitter.yield(signal)
    }
}

private func runWithinRemainingReviewTimeout<Result: Sendable>(
    timeoutSeconds: Int?,
    startedAt: ContinuousClock.Instant,
    clock: any ReviewClock,
    operation: @escaping @Sendable () async throws -> Result
) async throws -> Result {
    guard let timeoutDuration = try remainingReviewTimeoutDuration(
        timeoutSeconds: timeoutSeconds,
        startedAt: startedAt,
        now: clock.now
    ) else {
        return try await operation()
    }
    return try await withThrowingTaskGroup(of: Result.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await clock.sleep(for: timeoutDuration)
            let timeoutSeconds = timeoutSeconds ?? 0
            throw ReviewError.io("Review timed out after \(timeoutSeconds) seconds.")
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else {
            throw ReviewError.io("review operation finished without a result.")
        }
        return result
    }
}

package func remainingReviewTimeoutDuration(
    timeoutSeconds: Int?,
    startedAt: ContinuousClock.Instant,
    now: ContinuousClock.Instant
) throws -> Duration? {
    guard let timeoutSeconds else {
        return nil
    }

    let elapsed = startedAt.duration(to: now)
    let timeoutDuration = Duration.seconds(timeoutSeconds)
    let remaining = timeoutDuration - elapsed
    guard remaining > .zero else {
        throw ReviewError.io("Review timed out after \(timeoutSeconds) seconds.")
    }

    return remaining
}

package struct AppServerReviewRunner: Sendable {
    package var settingsBuilder: ReviewExecutionSettingsBuilder
    package var threadUnavailableGracePeriod: Duration = .seconds(1)
    package var clock: any ReviewClock = ContinuousClock()

    package init(settingsBuilder: ReviewExecutionSettingsBuilder = .init()) {
        self.settingsBuilder = settingsBuilder
    }

    /// `requestedTerminationReason` can change while the review is running.
    /// Callers must provide `stateChangeSubscription` and yield it whenever that
    /// termination reason changes so the runner can wake and observe the update.
    package func run(
        session: any AppServerSessionTransport,
        request: ReviewRequestOptions,
        defaultTimeoutSeconds: Int?,
        resolvedModelHint: String? = nil,
        diagnosticLineSubscription: AsyncStreamSubscription<String> = .init(
            stream: AsyncStream { continuation in
                continuation.finish()
            },
            cancel: {}
        ),
        stateChangeSubscription: AsyncStreamSubscription<Void>,
        diagnosticsTail: @escaping @Sendable () async -> String = { "" },
        onStart: @escaping @Sendable (Date) async -> Void,
        onReviewStarted: @escaping @Sendable () async -> Void = {},
        onEvent: @escaping @Sendable (ReviewProcessEvent) async -> Void,
        requestedTerminationReason: @escaping @Sendable () async -> ReviewTerminationReason?,
        onUnrecoverableTransportFailure: @escaping @Sendable () async -> Void = {}
    ) async throws -> ReviewProcessOutcome {
        let settings = try settingsBuilder.build(request: request)
        let request = settings.request
        var effectiveModel: String? = resolvedModelHint
        if let cancelled = await cancelledOutcomeBeforeStart(
            requestedModel: effectiveModel,
            requestedTerminationReason: requestedTerminationReason,
            onEvent: onEvent
        ) {
            return cancelled
        }

        let startedAt = Date()
        let startedAtInstant = clock.now
        await onStart(startedAt)
        await onEvent(.progress(.started, "Review started."))
        let timeoutSeconds = request.timeoutSeconds ?? defaultTimeoutSeconds
        let bootstrapTimeoutSeconds: Int? = if let requestTimeout = request.timeoutSeconds {
            requestTimeout
        } else if let defaultTimeoutSeconds, defaultTimeoutSeconds > 0 {
            defaultTimeoutSeconds
        } else {
            nil
        }

        let state = AppServerReviewState()
        let initializeResponse = await session.initializeResponse()
        let resolvedCodexHome = ReviewHomePaths.resolvedCodexHomeURL(
            appServerCodexHome: initializeResponse.codexHome,
            environment: settings.command.environment
        )

        let localConfig: ReviewLocalConfig
        do {
            localConfig = try loadReviewLocalConfig(environment: settings.command.environment)
        } catch {
            throw ReviewError.bootstrapFailed("Failed to read ReviewMCP config: \(error.localizedDescription)")
        }

        let fallbackAppServerConfig = loadFallbackAppServerConfig(
            environment: settings.command.environment,
            codexHome: resolvedCodexHome
        )
        effectiveModel = resolveReviewModelSelection(
            localConfig: localConfig,
            resolvedConfig: fallbackAppServerConfig
        ).reportedModelBeforeThreadStart

        let resolvedConfig: AppServerConfigReadResponse.Config
        do {
            let configResponse: AppServerConfigReadResponse = try await runWithinRemainingReviewTimeout(
                timeoutSeconds: bootstrapTimeoutSeconds,
                startedAt: startedAtInstant,
                clock: clock
            ) {
                try await session.request(
                    method: "config/read",
                    params: AppServerConfigReadParams(
                        cwd: request.cwd,
                        includeLayers: false
                    ),
                    responseType: AppServerConfigReadResponse.self
                )
            }
            resolvedConfig = mergeAppServerConfig(
                primary: configResponse.config,
                fallback: fallbackAppServerConfig
            )
        } catch {
            guard shouldFallbackFromConfigReadError(error) else {
                throw ReviewBootstrapFailure(
                    message: bootstrapFailureMessage(
                        prefix: "Failed to read app-server config: \(error.localizedDescription)",
                        diagnostics: await diagnosticsTail()
                    ),
                    model: effectiveModel
                )
            }
            resolvedConfig = fallbackAppServerConfig
            await onEvent(.logEntry(.init(
                kind: .progress,
                text: "Falling back to local config parsing because `config/read` is unavailable."
            )))
        }

        let reviewSpecificModel = resolveReviewModelOverride(
            localConfig: localConfig,
            resolvedConfig: resolvedConfig
        )
        let resolvedModels = resolveReviewModelSelection(
            localConfig: localConfig,
            resolvedConfig: resolvedConfig
        )
        effectiveModel = resolvedModels.reportedModelBeforeThreadStart

        if let cancelled = await cancelledOutcomeBeforeStart(
            requestedModel: effectiveModel,
            requestedTerminationReason: requestedTerminationReason,
            onEvent: onEvent
        ) {
            return cancelled
        }

        let threadStart = AppServerThreadStartParams(
            model: resolvedModels.threadStartModelHint,
            cwd: request.cwd,
            approvalPolicy: settings.overrides.approvalPolicy,
            sandbox: settings.overrides.sandbox,
            config: makeReviewThreadStartConfig(
                reviewSpecificModel: reviewSpecificModel,
                localConfig: localConfig,
                resolvedConfig: resolvedConfig,
                clampModel: resolvedModels.clampModel,
                environment: settings.command.environment,
                codexHome: resolvedCodexHome
            ),
            personality: settings.overrides.personality,
            ephemeral: true
        )

        let threadResponse: AppServerThreadStartResponse
        do {
            threadResponse = try await runWithinRemainingReviewTimeout(
                timeoutSeconds: bootstrapTimeoutSeconds,
                startedAt: startedAtInstant,
                clock: clock
            ) {
                try await session.request(
                    method: "thread/start",
                    params: threadStart,
                    responseType: AppServerThreadStartResponse.self
                )
            }
        } catch {
            throw ReviewBootstrapFailure(
                message: bootstrapFailureMessage(
                    prefix: "Failed to start review thread: \(error.localizedDescription)",
                    diagnostics: await diagnosticsTail()
                ),
                model: effectiveModel
            )
        }
        await state.noteActiveThread(threadID: threadResponse.thread.id)
        effectiveModel = if reviewSpecificModel != nil {
            resolvedModels.reportedModelBeforeThreadStart
                ?? threadResponse.model?.nilIfEmpty
                ?? effectiveModel
        } else {
            threadResponse.model?.nilIfEmpty
                ?? resolvedModels.reportedModelBeforeThreadStart
                ?? effectiveModel
        }

        if let cancellationReason = await cancellationReason(requestedTerminationReason: requestedTerminationReason) {
            await cleanupThread(session: session, threadID: threadResponse.thread.id)
            await onEvent(.progress(.completed, "Review cancelled."))
            return cancelledOutcome(
                model: effectiveModel,
                startedAt: startedAt,
                endedAt: Date(),
                reason: cancellationReason
            )
        }

        let notificationSubscription = await session.notificationStream()
        var signalContinuation: AsyncStream<AppServerReviewRunnerSignal>.Continuation!
        let signalStream = AsyncStream<AppServerReviewRunnerSignal>(bufferingPolicy: .unbounded) {
            signalContinuation = $0
        }
        let signalEmitter = AppServerReviewRunnerSignalEmitter(continuation: signalContinuation)
        var sourceTasks: [Task<Void, Never>] = [
            makeNotificationSourceTask(subscription: notificationSubscription, emitter: signalEmitter),
            makeStringSourceTask(subscription: diagnosticLineSubscription, emitter: signalEmitter),
            makeVoidSourceTask(subscription: stateChangeSubscription, emitter: signalEmitter),
        ]
        if await requestedTerminationReason() != nil {
            await signalEmitter.yield(.stateChanged)
        }
        let initialTimeoutDuration: Duration?
        let expiredTimeoutMessage: String?
        do {
            initialTimeoutDuration = try remainingReviewTimeoutDuration(
                timeoutSeconds: timeoutSeconds,
                startedAt: startedAtInstant,
                now: clock.now
            )
            expiredTimeoutMessage = nil
        } catch {
            initialTimeoutDuration = nil
            expiredTimeoutMessage = (error as? ReviewError)?.errorDescription ?? error.localizedDescription
        }

        if let initialTimeoutDuration {
            sourceTasks.append(
                makeDelayedSignalTask(
                    duration: initialTimeoutDuration,
                    signal: .timeoutFired,
                    emitter: signalEmitter,
                    clock: clock
                )
            )
        }

        var cancellationReasonValue: String?
        var timeoutMessage: String?
        var interruptSent = false
        var awaitingInterruptResolution = false
        var completedWithoutFinalReviewGraceSatisfied = false
        var completedTurnSettleSatisfied = false
        var transportDisconnectGraceSatisfied = false
        var completionGraceDuration: Duration?
        var completionGraceTask: Task<Void, Never>?
        var completedTurnSettleTask: Task<Void, Never>?
        var threadUnavailableGraceTask: Task<Void, Never>?
        var transportDisconnectGraceTask: Task<Void, Never>?
        var pendingTransportDisconnectReason: String?

        func stopSignalSources() async {
            threadUnavailableGraceTask?.cancel()
            completionGraceTask?.cancel()
            completedTurnSettleTask?.cancel()
            transportDisconnectGraceTask?.cancel()
            for task in sourceTasks {
                task.cancel()
            }
            signalContinuation.finish()
            if let threadUnavailableGraceTask {
                _ = await threadUnavailableGraceTask.value
            }
            if let completionGraceTask {
                _ = await completionGraceTask.value
            }
            if let completedTurnSettleTask {
                _ = await completedTurnSettleTask.value
            }
            if let transportDisconnectGraceTask {
                _ = await transportDisconnectGraceTask.value
            }
            for task in sourceTasks {
                _ = await task.value
            }
        }

        func cancelThreadUnavailableGraceTask() {
            threadUnavailableGraceTask?.cancel()
            threadUnavailableGraceTask = nil
        }

        func scheduleThreadUnavailableGraceTask() {
            cancelThreadUnavailableGraceTask()
            threadUnavailableGraceTask = makeDelayedSignalTask(
                duration: threadUnavailableGracePeriod,
                signal: .threadUnavailableGraceExpired,
                emitter: signalEmitter,
                clock: clock,
                yieldFirst: true
            )
        }

        func cancelCompletionGraceTask() {
            completionGraceTask?.cancel()
            completionGraceTask = nil
            completionGraceDuration = nil
            completedWithoutFinalReviewGraceSatisfied = false
        }

        func scheduleCompletionGraceTask(duration: Duration) {
            guard completionGraceTask == nil || completionGraceDuration != duration else {
                return
            }
            cancelCompletionGraceTask()
            completionGraceDuration = duration
            completionGraceTask = makeDelayedSignalTask(
                duration: duration,
                signal: .completedWithoutFinalReviewGraceExpired,
                emitter: signalEmitter,
                clock: clock
            )
        }

        func scheduleCompletedTurnSettleTask() {
            guard completedTurnSettleTask == nil else {
                return
            }
            completedTurnSettleSatisfied = false
            completedTurnSettleTask = makeDelayedSignalTask(
                duration: .zero,
                signal: .completedTurnSettleExpired,
                emitter: signalEmitter,
                clock: clock,
                yieldFirst: true
            )
        }

        func scheduleTransportDisconnectGraceTask() {
            guard transportDisconnectGraceTask == nil else {
                return
            }
            transportDisconnectGraceSatisfied = false
            transportDisconnectGraceTask = makeDelayedSignalTask(
                duration: threadUnavailableGracePeriod,
                signal: .transportDisconnectGraceExpired,
                emitter: signalEmitter,
                clock: clock,
                yieldFirst: true
            )
        }

        func noteTransportDisconnect(reason: String) {
            if pendingTransportDisconnectReason == nil {
                pendingTransportDisconnectReason = reason
            }
            scheduleTransportDisconnectGraceTask()
        }

        func shouldWaitForHigherPriorityOutcome(
            snapshot: AppServerReviewState.Snapshot
        ) -> Bool {
            if let turnStatus = snapshot.turnStatus {
                switch turnStatus {
                case .completed:
                    return snapshot.finalReview?.nilIfEmpty == nil
                        && completedWithoutFinalReviewGraceSatisfied == false
                case .failed, .interrupted:
                    return true
                case .inProgress:
                    break
                }
            }

            return snapshot.pendingThreadUnavailableReason != nil
                && (snapshot.turnStatus == nil || snapshot.turnStatus == .inProgress)
        }

        func updateTimers(
            snapshot: AppServerReviewState.Snapshot,
            trackedActivity: Bool
        ) {
            let canTrackThreadUnavailable = snapshot.pendingThreadUnavailableReason != nil
                && (snapshot.turnStatus == nil || snapshot.turnStatus == .inProgress)
                && awaitingInterruptResolution == false
                && cancellationReasonValue == nil
                && timeoutMessage == nil
            if canTrackThreadUnavailable {
                if trackedActivity || threadUnavailableGraceTask == nil {
                    scheduleThreadUnavailableGraceTask()
                }
            } else {
                cancelThreadUnavailableGraceTask()
            }

            let wantsCompletionGrace = snapshot.turnStatus == .completed
                && snapshot.finalReview?.nilIfEmpty == nil
                && cancellationReasonValue == nil
                && timeoutMessage == nil
            if completedWithoutFinalReviewGraceSatisfied && wantsCompletionGrace {
                return
            }
            if wantsCompletionGrace {
                let duration: Duration = snapshot.pendingThreadUnavailableReason == nil
                    ? .milliseconds(250)
                    : threadUnavailableGracePeriod
                scheduleCompletionGraceTask(duration: duration)
            } else {
                cancelCompletionGraceTask()
            }
        }

        func requestInterrupt(
            using snapshot: AppServerReviewState.Snapshot,
            cancellationReasonValue: String
        ) async -> ReviewProcessOutcome? {
            interruptSent = true
            do {
                let _: AppServerEmptyResponse = try await session.request(
                    method: "turn/interrupt",
                    params: AppServerTurnInterruptParams(
                        threadID: snapshot.threadID ?? threadResponse.thread.id,
                        turnID: snapshot.turnID ?? turnID
                    ),
                    responseType: AppServerEmptyResponse.self
                )
                awaitingInterruptResolution = true
                await onEvent(.logEntry(.init(kind: .progress, text: "Cancellation requested.")))
                if snapshot.turnStatus == .inProgress {
                    await signalEmitter.yield(.interruptResolutionCheck)
                }
                return nil
            } catch {
                let endedAt = Date()
                let interruptFailure = "Failed to interrupt review: \(error.localizedDescription)"
                await onEvent(.failed(interruptFailure))
                await cleanupThread(session: session, threadID: snapshot.threadID ?? threadResponse.thread.id)
                await onUnrecoverableTransportFailure()
                let finalSnapshot = await state.snapshot()

                if let timeoutMessage {
                    await onEvent(.progress(.completed, "Review timed out."))
                    return ReviewProcessOutcome(
                        state: .failed,
                        exitCode: 124,
                        reviewThreadID: finalSnapshot.reviewThreadID ?? reviewThreadID,
                        threadID: finalSnapshot.threadID ?? threadResponse.thread.id,
                        turnID: finalSnapshot.turnID ?? turnID,
                        model: effectiveModel,
                        hasFinalReview: finalSnapshot.finalReview?.nilIfEmpty != nil,
                        lastAgentMessage: finalSnapshot.lastAgentMessage ?? "",
                        errorMessage: timeoutMessage,
                        summary: timeoutMessage,
                        startedAt: startedAt,
                        endedAt: endedAt,
                        content: finalSnapshot.finalReview ?? finalSnapshot.lastAgentMessage ?? timeoutMessage
                    )
                }

                let reason = finalSnapshot.errorMessage ?? cancellationReasonValue
                await onEvent(.progress(.completed, "Review cancelled."))
                return ReviewProcessOutcome(
                    state: .cancelled,
                    exitCode: 0,
                    reviewThreadID: finalSnapshot.reviewThreadID ?? reviewThreadID,
                    threadID: finalSnapshot.threadID ?? threadResponse.thread.id,
                    turnID: finalSnapshot.turnID ?? turnID,
                    model: effectiveModel,
                    hasFinalReview: finalSnapshot.finalReview?.nilIfEmpty != nil,
                    lastAgentMessage: finalSnapshot.lastAgentMessage ?? "",
                    errorMessage: reason,
                    summary: "Review cancelled.",
                    startedAt: startedAt,
                    endedAt: endedAt,
                    content: finalSnapshot.finalReview ?? finalSnapshot.lastAgentMessage ?? reason
                )
            }
        }

        let reviewResponse: AppServerReviewStartResponse
        do {
            reviewResponse = try await runWithinRemainingReviewTimeout(
                timeoutSeconds: bootstrapTimeoutSeconds,
                startedAt: startedAtInstant,
                clock: clock
            ) {
                try await session.request(
                    method: "review/start",
                    params: AppServerReviewStartParams(
                        threadID: threadResponse.thread.id,
                        target: request.target,
                        delivery: "inline"
                    ),
                    responseType: AppServerReviewStartResponse.self
                )
            }
        } catch {
            await stopSignalSources()
            await cleanupThread(session: session, threadID: threadResponse.thread.id)
            throw ReviewBootstrapFailure(
                message: "Failed to start review: \(error.localizedDescription)",
                model: effectiveModel
            )
        }
        let reviewThreadID = reviewResponse.reviewThreadID
        let turnID = reviewResponse.turn.id
        await state.markReviewStarted(
            reviewThreadID: reviewThreadID,
            threadID: threadResponse.thread.id,
            turnID: turnID
        )
        await onReviewStarted()
        await onEvent(.reviewStarted(
            reviewThreadID: reviewThreadID,
            threadID: threadResponse.thread.id,
            turnID: turnID,
            model: effectiveModel
        ))
        await onEvent(.progress(.threadStarted, "Review started: \(reviewThreadID)"))
        if let expiredTimeoutMessage {
            timeoutMessage = expiredTimeoutMessage
            cancellationReasonValue = expiredTimeoutMessage
            let snapshot = await state.snapshot()
            if let outcome = await requestInterrupt(
                using: snapshot,
                cancellationReasonValue: expiredTimeoutMessage
            ) {
                await stopSignalSources()
                return outcome
            }
        }

        func awaitOutcome() async throws -> ReviewProcessOutcome {
            for await signal in signalStream {
                var trackedActivity = false

            switch signal {
            case .notification(let notification):
                let disposition = await state.trackingDisposition(for: notification)
                trackedActivity = disposition.countsAsActivity
                if disposition.shouldProcess {
                    await handle(notification: notification, state: state, onEvent: onEvent)
                }
            case .diagnosticLine(let line):
                await onEvent(.rawLine(line))
            case .stateChanged:
                break
            case .timeoutFired:
                if timeoutMessage == nil {
                    timeoutMessage = timeoutSeconds.map { "Review timed out after \($0) seconds." }
                    guard let timeoutMessage else {
                        break
                    }
                    cancellationReasonValue = timeoutMessage
                }
            case .threadUnavailableGraceExpired:
                if let reason = await state.finalizePendingThreadUnavailableFailure() {
                    await onEvent(.logEntry(.init(kind: .error, text: reason)))
                    await onEvent(.failed(reason))
                }
            case .completedWithoutFinalReviewGraceExpired:
                completedWithoutFinalReviewGraceSatisfied = true
            case .completedTurnSettleExpired:
                completedTurnSettleSatisfied = true
                completedTurnSettleTask = nil
            case .transportDisconnectGraceExpired:
                transportDisconnectGraceSatisfied = true
                transportDisconnectGraceTask = nil
            case .interruptResolutionCheck:
                break
            case .transportClosed:
                noteTransportDisconnect(reason: "app-server stdio transport closed.")
            case .transportDisconnected(let message):
                noteTransportDisconnect(reason: message)
            }

            if cancellationReasonValue == nil {
                cancellationReasonValue = await cancellationReason(requestedTerminationReason: requestedTerminationReason)
            }

            let snapshot = await state.snapshot()
            updateTimers(snapshot: snapshot, trackedActivity: trackedActivity)

            if pendingTransportDisconnectReason != nil,
               snapshot.reviewThreadID == nil
            {
                throw ReviewBootstrapFailure(
                    message: bootstrapFailureMessage(
                        prefix: pendingTransportDisconnectReason ?? "app-server stdio transport disconnected.",
                        diagnostics: await diagnosticsTail()
                    ),
                    model: effectiveModel
                )
            }

            if (snapshot.turnStatus == nil || snapshot.turnStatus == .inProgress),
               let cancellationReasonValue,
               interruptSent == false,
               pendingTransportDisconnectReason == nil
            {
                if let outcome = await requestInterrupt(
                    using: snapshot,
                    cancellationReasonValue: cancellationReasonValue
                ) {
                    return outcome
                }
            }

            if let turnStatus = snapshot.turnStatus {
                if awaitingInterruptResolution,
                   turnStatus == .inProgress,
                   let cancellationReasonValue
                {
                    let endedAt = Date()
                    await cleanupThread(session: session, threadID: snapshot.threadID ?? threadResponse.thread.id)
                    await onUnrecoverableTransportFailure()
                    let finalSnapshot = await state.snapshot()
                    if let timeoutMessage {
                        await onEvent(.progress(.completed, "Review timed out."))
                        return ReviewProcessOutcome(
                            state: .failed,
                            exitCode: 124,
                            reviewThreadID: finalSnapshot.reviewThreadID ?? reviewThreadID,
                            threadID: finalSnapshot.threadID ?? threadResponse.thread.id,
                            turnID: finalSnapshot.turnID ?? turnID,
                            model: effectiveModel,
                            hasFinalReview: finalSnapshot.finalReview?.nilIfEmpty != nil,
                            lastAgentMessage: finalSnapshot.lastAgentMessage ?? "",
                            errorMessage: timeoutMessage,
                            summary: timeoutMessage,
                            startedAt: startedAt,
                            endedAt: endedAt,
                            content: finalSnapshot.finalReview ?? finalSnapshot.lastAgentMessage ?? timeoutMessage
                        )
                    }
                    let reason = finalSnapshot.errorMessage ?? cancellationReasonValue
                    await onEvent(.progress(.completed, "Review cancelled."))
                    return ReviewProcessOutcome(
                        state: .cancelled,
                        exitCode: 0,
                        reviewThreadID: finalSnapshot.reviewThreadID ?? reviewThreadID,
                        threadID: finalSnapshot.threadID ?? threadResponse.thread.id,
                        turnID: finalSnapshot.turnID ?? turnID,
                        model: effectiveModel,
                        hasFinalReview: finalSnapshot.finalReview?.nilIfEmpty != nil,
                        lastAgentMessage: finalSnapshot.lastAgentMessage ?? "",
                        errorMessage: reason,
                        summary: "Review cancelled.",
                        startedAt: startedAt,
                        endedAt: endedAt,
                        content: finalSnapshot.finalReview ?? finalSnapshot.lastAgentMessage ?? reason
                    )
                }

                if turnStatus != .inProgress {
                    if turnStatus == .completed,
                       snapshot.finalReview?.nilIfEmpty != nil,
                       timeoutMessage == nil,
                       cancellationReasonValue == nil,
                       completedTurnSettleSatisfied == false
                    {
                        scheduleCompletedTurnSettleTask()
                        continue
                    }

                    if turnStatus == .completed,
                       snapshot.finalReview?.nilIfEmpty == nil,
                       (
                           completedWithoutFinalReviewGraceSatisfied == false
                               || (
                                   pendingTransportDisconnectReason != nil
                                       && transportDisconnectGraceSatisfied == false
                               )
                       ),
                       timeoutMessage == nil,
                       cancellationReasonValue == nil
                    {
                        continue
                    }

                    let endedAt = Date()
                    await cleanupThread(session: session, threadID: snapshot.threadID ?? threadResponse.thread.id)
                    let finalSnapshot = await state.snapshot()
                    if pendingTransportDisconnectReason != nil {
                        await onUnrecoverableTransportFailure()
                    }

                    switch turnStatus {
                    case .completed:
                        if let timeoutMessage {
                            await onEvent(.progress(.completed, "Review timed out."))
                            return ReviewProcessOutcome(
                                state: .failed,
                                exitCode: 124,
                                reviewThreadID: finalSnapshot.reviewThreadID ?? reviewThreadID,
                                threadID: finalSnapshot.threadID ?? threadResponse.thread.id,
                                turnID: finalSnapshot.turnID ?? turnID,
                                model: effectiveModel,
                                hasFinalReview: finalSnapshot.finalReview?.nilIfEmpty != nil,
                                lastAgentMessage: finalSnapshot.lastAgentMessage ?? "",
                                errorMessage: timeoutMessage,
                                summary: timeoutMessage,
                                startedAt: startedAt,
                                endedAt: endedAt,
                                content: finalSnapshot.finalReview ?? finalSnapshot.lastAgentMessage ?? timeoutMessage
                            )
                        }
                        if let cancellationReasonValue {
                            await onEvent(.progress(.completed, "Review cancelled."))
                            return ReviewProcessOutcome(
                                state: .cancelled,
                                exitCode: 0,
                                reviewThreadID: finalSnapshot.reviewThreadID ?? reviewThreadID,
                                threadID: finalSnapshot.threadID ?? threadResponse.thread.id,
                                turnID: finalSnapshot.turnID ?? turnID,
                                model: effectiveModel,
                                hasFinalReview: finalSnapshot.finalReview?.nilIfEmpty != nil,
                                lastAgentMessage: finalSnapshot.lastAgentMessage ?? "",
                                errorMessage: cancellationReasonValue,
                                summary: "Review cancelled.",
                                startedAt: startedAt,
                                endedAt: endedAt,
                                content: finalSnapshot.finalReview ?? finalSnapshot.lastAgentMessage ?? cancellationReasonValue
                            )
                        }
                        guard let review = finalSnapshot.finalReview?.nilIfEmpty else {
                            if let transportDisconnectReason = pendingTransportDisconnectReason {
                                await onEvent(.progress(.completed, "Review failed."))
                                return ReviewProcessOutcome(
                                    state: .failed,
                                    exitCode: 1,
                                    reviewThreadID: finalSnapshot.reviewThreadID ?? reviewThreadID,
                                    threadID: finalSnapshot.threadID ?? threadResponse.thread.id,
                                    turnID: finalSnapshot.turnID ?? turnID,
                                    model: effectiveModel,
                                    hasFinalReview: false,
                                    lastAgentMessage: finalSnapshot.lastAgentMessage ?? "",
                                    errorMessage: transportDisconnectReason,
                                    summary: "Review failed.",
                                    startedAt: startedAt,
                                    endedAt: endedAt,
                                    content: finalSnapshot.lastAgentMessage ?? transportDisconnectReason
                                )
                            }
                            return ReviewProcessOutcome(
                                state: .failed,
                                exitCode: 1,
                                reviewThreadID: finalSnapshot.reviewThreadID ?? reviewThreadID,
                                threadID: finalSnapshot.threadID ?? threadResponse.thread.id,
                                turnID: finalSnapshot.turnID ?? turnID,
                                model: effectiveModel,
                                hasFinalReview: false,
                                lastAgentMessage: finalSnapshot.lastAgentMessage ?? "",
                                errorMessage: "Review completed without an `exitedReviewMode` item.",
                                summary: "Review failed.",
                                startedAt: startedAt,
                                endedAt: endedAt,
                                content: finalSnapshot.lastAgentMessage ?? "Review failed."
                            )
                        }
                        let summary = "Review completed successfully."
                        await onEvent(.progress(.completed, summary))
                        return ReviewProcessOutcome(
                            state: .succeeded,
                            exitCode: 0,
                            reviewThreadID: finalSnapshot.reviewThreadID ?? reviewThreadID,
                            threadID: finalSnapshot.threadID ?? threadResponse.thread.id,
                            turnID: finalSnapshot.turnID ?? turnID,
                            model: effectiveModel,
                            hasFinalReview: true,
                            lastAgentMessage: review,
                            errorMessage: nil,
                            summary: summary,
                            startedAt: startedAt,
                            endedAt: endedAt,
                            content: review
                        )
                    case .interrupted:
                        if let timeoutMessage {
                            await onEvent(.progress(.completed, "Review timed out."))
                            return ReviewProcessOutcome(
                                state: .failed,
                                exitCode: 124,
                                reviewThreadID: finalSnapshot.reviewThreadID ?? reviewThreadID,
                                threadID: finalSnapshot.threadID ?? threadResponse.thread.id,
                                turnID: finalSnapshot.turnID ?? turnID,
                                model: effectiveModel,
                                hasFinalReview: finalSnapshot.finalReview?.nilIfEmpty != nil,
                                lastAgentMessage: finalSnapshot.lastAgentMessage ?? "",
                                errorMessage: timeoutMessage,
                                summary: timeoutMessage,
                                startedAt: startedAt,
                                endedAt: endedAt,
                                content: finalSnapshot.finalReview ?? finalSnapshot.lastAgentMessage ?? timeoutMessage
                            )
                        }
                        let reason = cancellationReasonValue ?? finalSnapshot.errorMessage ?? "Review cancelled."
                        await onEvent(.progress(.completed, "Review cancelled."))
                        return ReviewProcessOutcome(
                            state: .cancelled,
                            exitCode: 0,
                            reviewThreadID: finalSnapshot.reviewThreadID ?? reviewThreadID,
                            threadID: finalSnapshot.threadID ?? threadResponse.thread.id,
                            turnID: finalSnapshot.turnID ?? turnID,
                            model: effectiveModel,
                            hasFinalReview: finalSnapshot.finalReview?.nilIfEmpty != nil,
                            lastAgentMessage: finalSnapshot.lastAgentMessage ?? "",
                            errorMessage: reason,
                            summary: "Review cancelled.",
                            startedAt: startedAt,
                            endedAt: endedAt,
                            content: finalSnapshot.finalReview ?? finalSnapshot.lastAgentMessage ?? reason
                        )
                    case .failed:
                        let errorMessage = finalSnapshot.errorMessage ?? "Review failed."
                        await onEvent(.progress(.completed, "Review failed."))
                        return ReviewProcessOutcome(
                            state: .failed,
                            exitCode: 1,
                            reviewThreadID: finalSnapshot.reviewThreadID ?? reviewThreadID,
                            threadID: finalSnapshot.threadID ?? threadResponse.thread.id,
                            turnID: finalSnapshot.turnID ?? turnID,
                            model: effectiveModel,
                            hasFinalReview: finalSnapshot.finalReview?.nilIfEmpty != nil,
                            lastAgentMessage: finalSnapshot.lastAgentMessage ?? "",
                            errorMessage: errorMessage,
                            summary: "Review failed.",
                            startedAt: startedAt,
                            endedAt: endedAt,
                            content: finalSnapshot.finalReview ?? finalSnapshot.lastAgentMessage ?? errorMessage
                        )
                    case .inProgress:
                        break
                    }
                }
            }

            if let transportDisconnectReason = pendingTransportDisconnectReason {
                if let timeoutMessage {
                    let endedAt = Date()
                    await cleanupThread(session: session, threadID: snapshot.threadID ?? threadResponse.thread.id)
                    await onUnrecoverableTransportFailure()
                    let finalSnapshot = await state.snapshot()
                    await onEvent(.progress(.completed, "Review timed out."))
                    return ReviewProcessOutcome(
                        state: .failed,
                        exitCode: 124,
                        reviewThreadID: finalSnapshot.reviewThreadID ?? reviewThreadID,
                        threadID: finalSnapshot.threadID ?? threadResponse.thread.id,
                        turnID: finalSnapshot.turnID ?? turnID,
                        model: effectiveModel,
                        hasFinalReview: finalSnapshot.finalReview?.nilIfEmpty != nil,
                        lastAgentMessage: finalSnapshot.lastAgentMessage ?? "",
                        errorMessage: timeoutMessage,
                        summary: timeoutMessage,
                        startedAt: startedAt,
                        endedAt: endedAt,
                        content: finalSnapshot.finalReview ?? finalSnapshot.lastAgentMessage ?? timeoutMessage
                    )
                }

                if let cancellationReasonValue,
                   snapshot.turnStatus == nil || snapshot.turnStatus == .inProgress
                {
                    let endedAt = Date()
                    await cleanupThread(session: session, threadID: snapshot.threadID ?? threadResponse.thread.id)
                    await onUnrecoverableTransportFailure()
                    let finalSnapshot = await state.snapshot()
                    let reason = finalSnapshot.errorMessage ?? cancellationReasonValue
                    await onEvent(.progress(.completed, "Review cancelled."))
                    return ReviewProcessOutcome(
                        state: .cancelled,
                        exitCode: 0,
                        reviewThreadID: finalSnapshot.reviewThreadID ?? reviewThreadID,
                        threadID: finalSnapshot.threadID ?? threadResponse.thread.id,
                        turnID: finalSnapshot.turnID ?? turnID,
                        model: effectiveModel,
                        hasFinalReview: finalSnapshot.finalReview?.nilIfEmpty != nil,
                        lastAgentMessage: finalSnapshot.lastAgentMessage ?? "",
                        errorMessage: reason,
                        summary: "Review cancelled.",
                        startedAt: startedAt,
                        endedAt: endedAt,
                        content: finalSnapshot.finalReview ?? finalSnapshot.lastAgentMessage ?? reason
                    )
                }

                if transportDisconnectGraceSatisfied {
                    if shouldWaitForHigherPriorityOutcome(snapshot: snapshot) {
                        continue
                    }
                    let endedAt = Date()
                    await cleanupThread(session: session, threadID: snapshot.threadID ?? threadResponse.thread.id)
                    await onUnrecoverableTransportFailure()
                    let finalSnapshot = await state.snapshot()
                    await onEvent(.progress(.completed, "Review failed."))
                    return ReviewProcessOutcome(
                        state: .failed,
                        exitCode: 1,
                        reviewThreadID: finalSnapshot.reviewThreadID ?? reviewThreadID,
                        threadID: finalSnapshot.threadID ?? threadResponse.thread.id,
                        turnID: finalSnapshot.turnID ?? turnID,
                        model: effectiveModel,
                        hasFinalReview: finalSnapshot.finalReview?.nilIfEmpty != nil,
                        lastAgentMessage: finalSnapshot.lastAgentMessage ?? "",
                        errorMessage: transportDisconnectReason,
                        summary: "Review failed.",
                        startedAt: startedAt,
                        endedAt: endedAt,
                        content: finalSnapshot.finalReview ?? finalSnapshot.lastAgentMessage ?? transportDisconnectReason
                    )
                }
            }
        }

            throw ReviewError.io("review signal stream ended unexpectedly")
        }

        do {
            let outcome = try await awaitOutcome()
            await stopSignalSources()
            return outcome
        } catch {
            await stopSignalSources()
            throw error
        }
    }

    private func shouldFallbackFromConfigReadError(_ error: Error) -> Bool {
        guard let responseError = error as? AppServerResponseError else {
            return false
        }
        return responseError.isUnsupportedMethod
    }

    private func cancelledOutcomeBeforeStart(
        requestedModel: String?,
        requestedTerminationReason: @escaping @Sendable () async -> ReviewTerminationReason?,
        onEvent: @escaping @Sendable (ReviewProcessEvent) async -> Void
    ) async -> ReviewProcessOutcome? {
        guard let cancellationReason = await cancellationReason(requestedTerminationReason: requestedTerminationReason) else {
            return nil
        }
        let startedAt = Date()
        await onEvent(.progress(.completed, "Review cancelled."))
        return ReviewProcessOutcome(
            state: .cancelled,
            exitCode: 130,
            reviewThreadID: nil,
            threadID: nil,
            turnID: nil,
            model: requestedModel,
            hasFinalReview: false,
            lastAgentMessage: "",
            errorMessage: cancellationReason,
            summary: "Review cancelled.",
            startedAt: startedAt,
            endedAt: startedAt,
            content: cancellationReason
        )
    }

    private func cancelledOutcome(
        model: String?,
        startedAt: Date,
        endedAt: Date,
        reason: String
    ) -> ReviewProcessOutcome {
        ReviewProcessOutcome(
            state: .cancelled,
            exitCode: 130,
            reviewThreadID: nil,
            threadID: nil,
            turnID: nil,
            model: model,
            hasFinalReview: false,
            lastAgentMessage: "",
            errorMessage: reason,
            summary: "Review cancelled.",
            startedAt: startedAt,
            endedAt: endedAt,
            content: reason
        )
    }

    private func cancellationReason(
        requestedTerminationReason: @escaping @Sendable () async -> ReviewTerminationReason?
    ) async -> String? {
        if Task.isCancelled {
            return "Review cancelled."
        }
        if case .cancelled(let reason)? = await requestedTerminationReason() {
            return reason
        }
        return nil
    }

    private func cleanupThread(
        session: any AppServerSessionTransport,
        threadID: String
    ) async {
        _ = try? await session.request(
            method: "thread/backgroundTerminals/clean",
            params: AppServerThreadBackgroundTerminalsCleanParams(threadID: threadID),
            responseType: AppServerEmptyResponse.self
        ) as AppServerEmptyResponse

        let unsubscribeResponse = try? await session.request(
            method: "thread/unsubscribe",
            params: AppServerThreadUnsubscribeParams(threadID: threadID),
            responseType: AppServerThreadUnsubscribeResponse.self
        ) as AppServerThreadUnsubscribeResponse
        switch unsubscribeResponse?.status {
        case .unsubscribed, .notSubscribed, .notLoaded:
            return
        case nil:
            return
        }
    }
}

private func bootstrapFailureMessage(prefix: String, diagnostics: String) -> String {
    guard diagnostics.isEmpty == false else {
        return prefix
    }
    return "\(prefix): \(diagnostics)"
}

private func rawReasoningGroupID(itemID: String, contentIndex: Int) -> String {
    "\(itemID):\(contentIndex)"
}

private func reasoningSummaryGroupID(itemID: String, summaryIndex: Int) -> String {
    "\(itemID):summary:\(summaryIndex)"
}

private func handle(
    notification: AppServerServerNotification,
    state: AppServerReviewState,
    onEvent: @escaping @Sendable (ReviewProcessEvent) async -> Void
) async {
    switch notification {
    case .threadStatusChanged(let payload):
        if let reason = await state.noteThreadStatusChanged(
            threadID: payload.threadID,
            statusType: payload.status.type
        ) {
            await onEvent(.logEntry(.init(kind: .event, text: reason)))
        }
    case .threadClosed(let payload):
        if let reason = await state.noteThreadClosed(threadID: payload.threadID) {
            await onEvent(.logEntry(.init(kind: .event, text: reason)))
        }
    case .turnStarted(let payload):
        await state.noteTurnStarted(turnID: payload.turn.id)
        await onEvent(.logEntry(.init(kind: .event, text: "Turn started: \(payload.turn.id)")))
    case .turnCompleted(let payload):
        await state.noteTurnCompleted(turn: payload.turn)
    case .itemStarted(let payload):
        switch payload.item {
        case .enteredReviewMode(_, let review):
            await onEvent(.logEntry(.init(kind: .progress, text: "Reviewing \(review)")))
        case .commandExecution(_, let command, _, _, _):
            await onEvent(.logEntry(.init(kind: .command, text: "$ \(command)")))
        case .mcpToolCall(let itemID, let server, let tool, _, _, _):
            await state.noteToolCall(itemID: itemID, server: server, tool: tool)
            await onEvent(.logEntry(.init(
                kind: .toolCall,
                groupID: itemID,
                text: "MCP \(server).\(tool) started."
            )))
        case .contextCompaction:
            await onEvent(.logEntry(.init(kind: .event, text: "Context compaction started.")))
        case .exitedReviewMode, .agentMessage, .plan, .reasoning, .unsupported:
            break
        }
    case .itemCompleted(let payload):
        switch payload.item {
        case .exitedReviewMode(_, let review):
            await state.noteFinalReview(review)
            await onEvent(.agentMessage(review))
            await onEvent(.logEntry(.init(kind: .agentMessage, groupID: payload.turnID, text: review)))
        case .agentMessage(let itemID, let text):
            let completed = await state.noteCompletedAgentMessage(itemID: itemID, text: text)
            await onEvent(.agentMessage(completed.latestText))
            if let logUpdate = completed.logUpdate {
                await onEvent(.logEntry(.init(
                    kind: .agentMessage,
                    groupID: itemID,
                    replacesGroup: logUpdate.replacesGroup,
                    text: logUpdate.text
                )))
            }
        case .commandExecution(let itemID, _, let output, _, _):
            if let output = await state.noteCommandCompleted(itemID: itemID, aggregatedOutput: output),
               output.isEmpty == false
            {
                await onEvent(.logEntry(.init(kind: .commandOutput, groupID: itemID, text: output)))
            }
        case .plan(let itemID, let text):
            if let finalUpdate = await state.notePlanCompleted(itemID: itemID, text: text) {
                await onEvent(.logEntry(.init(
                    kind: .plan,
                    groupID: itemID,
                    replacesGroup: finalUpdate.replacesGroup,
                    text: finalUpdate.text
                )))
            }
        case .reasoning(let itemID, let summary, let content):
            let completed = await state.noteReasoningCompleted(
                itemID: itemID,
                summary: summary,
                content: content
            )
            for summaryEntry in completed.summaryEntries where summaryEntry.update.text.isEmpty == false {
                await onEvent(.logEntry(.init(
                    kind: .reasoningSummary,
                    groupID: summaryEntry.groupID,
                    replacesGroup: summaryEntry.update.replacesGroup,
                    text: summaryEntry.update.text
                )))
            }
            for rawEntry in completed.rawEntries where rawEntry.update.text.isEmpty == false {
                await onEvent(.logEntry(.init(
                    kind: .rawReasoning,
                    groupID: rawEntry.groupID,
                    replacesGroup: rawEntry.update.replacesGroup,
                    text: rawEntry.update.text
                )))
            }
        case .mcpToolCall(let itemID, let server, let tool, let status, let error, let result):
            await state.noteToolCall(itemID: itemID, server: server, tool: tool)
            var text = "MCP \(server).\(tool) \(status)."
            if let error = error?.nilIfEmpty {
                text += " Error: \(error)"
            } else if let result = result?.nilIfEmpty {
                text += " Result: \(result)"
            }
            await onEvent(.logEntry(.init(kind: .toolCall, groupID: itemID, text: text)))
        case .contextCompaction:
            await onEvent(.logEntry(.init(kind: .event, text: "Context compacted.")))
        case .enteredReviewMode, .unsupported:
            break
        }
    case .agentMessageDelta(let payload):
        if let latest = await state.appendAgentMessageDelta(itemID: payload.itemID, delta: payload.delta) {
            await onEvent(.agentMessage(latest))
            await onEvent(.logEntry(.init(kind: .agentMessage, groupID: payload.itemID, text: payload.delta)))
        }
    case .planDelta(let payload):
        if await state.notePlanDelta(itemID: payload.itemID, delta: payload.delta) {
            await onEvent(.logEntry(.init(kind: .plan, groupID: payload.itemID, text: payload.delta)))
        }
    case .commandExecutionOutputDelta(let payload):
        await state.noteCommandOutput(itemID: payload.itemID, delta: payload.delta)
        if payload.delta.isEmpty == false {
            await onEvent(.logEntry(.init(kind: .commandOutput, groupID: payload.itemID, text: payload.delta)))
        }
    case .reasoningSummaryTextDelta(let payload):
        if await state.noteReasoningSummaryDelta(
            itemID: payload.itemID,
            summaryIndex: payload.summaryIndex,
            delta: payload.delta
        ) {
            await onEvent(.logEntry(.init(
                kind: .reasoningSummary,
                groupID: reasoningSummaryGroupID(itemID: payload.itemID, summaryIndex: payload.summaryIndex),
                text: payload.delta
            )))
        }
    case .reasoningSummaryPartAdded(let payload):
        _ = await state.noteReasoningSummaryPartAdded(
            itemID: payload.itemID,
            summaryIndex: payload.summaryIndex
        )
    case .reasoningTextDelta(let payload):
        if await state.noteRawReasoningDelta(
            itemID: payload.itemID,
            contentIndex: payload.contentIndex,
            delta: payload.delta
        ),
           payload.delta.isEmpty == false
        {
            await onEvent(.logEntry(.init(
                kind: .rawReasoning,
                groupID: rawReasoningGroupID(itemID: payload.itemID, contentIndex: payload.contentIndex),
                text: payload.delta
            )))
        }
    case .mcpToolCallProgress(let payload):
        let label = await state.toolCallLabel(itemID: payload.itemID)
        let prefix = label.map { "MCP \($0): " } ?? "MCP: "
        await onEvent(.logEntry(.init(
            kind: .toolCall,
            groupID: payload.itemID,
            text: prefix + payload.message
        )))
    case .error(let payload):
        let message = payload.error.additionalDetails?.nilIfEmpty.map {
            "\(payload.error.message) \($0)"
        } ?? payload.error.message
        let isTrackedError = await state.noteErrorNotification(
            threadID: payload.threadID,
            turnID: payload.turnID,
            message: message,
            willRetry: payload.willRetry
        )
        guard isTrackedError else {
            break
        }
        let kind: ReviewLogEntry.Kind = payload.willRetry ? .progress : .error
        await onEvent(.logEntry(.init(kind: kind, text: message)))
        if payload.willRetry == false {
            await onEvent(.failed(message))
        }
    case .accountLoginCompleted, .accountUpdated, .accountRateLimitsUpdated:
        break
    case .ignored:
        break
    }
}

private actor AppServerReviewState {
    enum GroupTextUpdate: Sendable {
        case append(String)
        case replace(String)

        var text: String {
            switch self {
            case .append(let text), .replace(let text):
                return text
            }
        }

        var replacesGroup: Bool {
            switch self {
            case .append:
                return false
            case .replace:
                return true
            }
        }
    }

    struct Snapshot: Sendable {
        var reviewThreadID: String?
        var threadID: String?
        var turnID: String?
        var turnStatus: AppServerTurnStatus?
        var pendingThreadUnavailableReason: String?
        var lastAgentMessage: String?
        var finalReview: String?
        var errorMessage: String?
        var stderrText: String
    }

    struct CompletedAgentMessage: Sendable {
        var latestText: String
        var logUpdate: GroupTextUpdate?
    }

    struct ReasoningCompletion: Sendable {
        struct SummaryEntry: Sendable {
            var groupID: String
            var update: GroupTextUpdate
        }

        struct RawEntry: Sendable {
            var groupID: String
            var update: GroupTextUpdate
        }

        var summaryEntries: [SummaryEntry]
        var rawEntries: [RawEntry]
    }

    private var reviewThreadID: String?
    private var threadID: String?
    private var turnID: String?
    private var turnStatus: AppServerTurnStatus?
    private var finalReview: String?
    private var lastAgentMessage: String?
    private var errorMessage: String?
    private var pendingThreadUnavailableReason: String?
    private var stderrLines: [String] = []
    private var agentMessagesByItemID: [String: String] = [:]
    private var completedAgentMessageItemIDs: Set<String> = []
    private var commandOutputsByItemID: [String: String] = [:]
    private var completedCommandItemIDs: Set<String> = []
    private var plansByItemID: [String: String] = [:]
    private var completedPlanItemIDs: Set<String> = []
    private var streamedReasoningSummaryByItemID: [String: [Int: String]] = [:]
    private var streamedRawReasoningByItemID: [String: [Int: String]] = [:]
    private var completedReasoningItemIDs: Set<String> = []
    private var toolCallLabelsByItemID: [String: String] = [:]

    func noteActiveThread(threadID: String) {
        self.threadID = threadID
    }

    func markReviewStarted(
        reviewThreadID: String,
        threadID: String,
        turnID: String
    ) {
        self.reviewThreadID = reviewThreadID
        self.threadID = threadID
        self.turnID = turnID
    }

    func noteTurnStarted(turnID: String) {
        guard turnStatus == nil || turnStatus == .inProgress else {
            return
        }
        if let existingTurnID = self.turnID, existingTurnID != turnID {
            return
        }
        self.turnID = turnID
        turnStatus = .inProgress
    }

    func noteTurnCompleted(turn: AppServerTurn) {
        if let existingTurnID = turnID, existingTurnID != turn.id {
            return
        }
        if turnStatus == .interrupted && turn.status != .interrupted {
            return
        }
        turnID = turn.id
        if turnStatus != .failed || turn.status == .failed {
            turnStatus = turn.status
        }
        errorMessage = turn.error?.message?.nilIfEmpty ?? errorMessage
    }

    func noteThreadStatusChanged(threadID: String, statusType: String) -> String? {
        guard statusType == "notLoaded" else {
            return nil
        }
        return notePendingThreadUnavailable(
            threadID: threadID,
            message: "Review thread was unloaded before the review completed."
        )
    }

    func noteThreadClosed(threadID: String) -> String? {
        notePendingThreadUnavailable(
            threadID: threadID,
            message: "Review thread closed before the review completed."
        )
    }

    func noteErrorNotification(
        threadID: String,
        turnID: String,
        message: String,
        willRetry: Bool
    ) -> Bool {
        guard isActiveReviewThread(threadID), isTrackedTurn(turnID) else {
            return false
        }
        if willRetry == false {
            errorMessage = message.nilIfEmpty ?? errorMessage
            turnStatus = .failed
            pendingThreadUnavailableReason = nil
        }
        return true
    }

    func finalizePendingThreadUnavailableFailure() -> String? {
        guard let reason = pendingThreadUnavailableReason,
              turnStatus == nil || turnStatus == .inProgress
        else {
            return nil
        }
        turnStatus = .failed
        errorMessage = errorMessage ?? reason
        pendingThreadUnavailableReason = nil
        return errorMessage
    }

    func appendAgentMessageDelta(itemID: String, delta: String) -> String? {
        guard completedAgentMessageItemIDs.contains(itemID) == false else {
            return nil
        }
        let updated = (agentMessagesByItemID[itemID] ?? "") + delta
        agentMessagesByItemID[itemID] = updated
        lastAgentMessage = updated
        return updated
    }

    func noteCompletedAgentMessage(itemID: String, text: String) -> CompletedAgentMessage {
        let streamedText = agentMessagesByItemID[itemID]
        agentMessagesByItemID[itemID] = text
        completedAgentMessageItemIDs.insert(itemID)
        lastAgentMessage = text
        return .init(
            latestText: text,
            logUpdate: completionGroupUpdate(streamedText: streamedText, finalText: text)
        )
    }

    func noteCommandOutput(itemID: String, delta: String) {
        commandOutputsByItemID[itemID, default: ""].append(delta)
    }

    func noteCommandCompleted(itemID: String, aggregatedOutput: String?) -> String? {
        guard completedCommandItemIDs.contains(itemID) == false else {
            return nil
        }
        completedCommandItemIDs.insert(itemID)
        let streamedOutput = commandOutputsByItemID[itemID]
        let finalOutput = aggregatedOutput ?? streamedOutput ?? ""
        commandOutputsByItemID[itemID] = finalOutput
        return completionGroupUpdate(streamedText: streamedOutput, finalText: finalOutput)?.text
    }

    func notePlanDelta(itemID: String, delta: String) -> Bool {
        guard completedPlanItemIDs.contains(itemID) == false else {
            return false
        }
        plansByItemID[itemID, default: ""].append(delta)
        return true
    }

    func notePlanCompleted(itemID: String, text: String) -> GroupTextUpdate? {
        let streamedText = plansByItemID[itemID]
        plansByItemID[itemID] = text
        completedPlanItemIDs.insert(itemID)
        return completionGroupUpdate(streamedText: streamedText, finalText: text)
    }

    func noteReasoningSummaryDelta(itemID: String, summaryIndex: Int, delta: String) -> Bool {
        guard completedReasoningItemIDs.contains(itemID) == false else {
            return false
        }
        var sections = streamedReasoningSummaryByItemID[itemID] ?? [:]
        sections[summaryIndex, default: ""].append(delta)
        streamedReasoningSummaryByItemID[itemID] = sections
        return true
    }

    func noteReasoningSummaryPartAdded(itemID: String, summaryIndex: Int) -> Bool {
        guard completedReasoningItemIDs.contains(itemID) == false else {
            return false
        }
        let sections = streamedReasoningSummaryByItemID[itemID] ?? [:]
        _ = sections[summaryIndex, default: ""]
        streamedReasoningSummaryByItemID[itemID] = sections
        return true
    }

    func noteRawReasoningDelta(itemID: String, contentIndex: Int, delta: String) -> Bool {
        guard completedReasoningItemIDs.contains(itemID) == false else {
            return false
        }
        var sections = streamedRawReasoningByItemID[itemID] ?? [:]
        sections[contentIndex, default: ""].append(delta)
        streamedRawReasoningByItemID[itemID] = sections
        return true
    }

    func noteReasoningCompleted(
        itemID: String,
        summary: [String],
        content: [String]
    ) -> ReasoningCompletion {
        completedReasoningItemIDs.insert(itemID)
        let streamedSummary = streamedReasoningSummaryByItemID[itemID] ?? [:]
        var summaryEntries: [ReasoningCompletion.SummaryEntry] = []

        for (index, finalText) in summary.enumerated() {
            guard let remainder = completionGroupUpdate(
                streamedText: streamedSummary[index],
                finalText: finalText
            ) else {
                continue
            }
            summaryEntries.append(.init(
                groupID: reasoningSummaryGroupID(itemID: itemID, summaryIndex: index),
                update: remainder
            ))
        }

        var rawEntries: [ReasoningCompletion.RawEntry] = []
        let streamedRaw = streamedRawReasoningByItemID[itemID] ?? [:]
        for (index, finalText) in content.enumerated() {
            guard let remainder = completionGroupUpdate(
                streamedText: streamedRaw[index],
                finalText: finalText
            ) else {
                continue
            }
            rawEntries.append(.init(
                groupID: rawReasoningGroupID(itemID: itemID, contentIndex: index),
                update: remainder
            ))
        }

        return ReasoningCompletion(
            summaryEntries: summaryEntries,
            rawEntries: rawEntries
        )
    }

    func noteToolCall(itemID: String, server: String, tool: String) {
        toolCallLabelsByItemID[itemID] = "\(server).\(tool)"
    }

    func toolCallLabel(itemID: String) -> String? {
        toolCallLabelsByItemID[itemID]
    }

    func noteFinalReview(_ review: String) {
        finalReview = review
        lastAgentMessage = review
    }

    func appendStandardError(_ line: String) {
        stderrLines.append(line)
    }

    func snapshot() -> Snapshot {
        Snapshot(
            reviewThreadID: reviewThreadID,
            threadID: threadID,
            turnID: turnID,
            turnStatus: turnStatus,
            pendingThreadUnavailableReason: pendingThreadUnavailableReason,
            lastAgentMessage: lastAgentMessage,
            finalReview: finalReview,
            errorMessage: errorMessage,
            stderrText: stderrLines.joined(separator: "\n")
        )
    }

    func trackingDisposition(
        for notification: AppServerServerNotification
    ) -> AppServerTrackedNotificationDisposition {
        switch notification {
        case .threadStatusChanged(let payload):
            let isTracked = isActiveReviewThread(payload.threadID)
            return .init(
                shouldProcess: isTracked,
                countsAsActivity: isTracked
            )
        case .threadClosed(let payload):
            let isTracked = isActiveReviewThread(payload.threadID)
            return .init(
                shouldProcess: isTracked,
                countsAsActivity: isTracked
            )
        case .turnStarted(let payload):
            let isTracked = isTrackedTurnLifecycle(threadID: payload.threadID, turnID: payload.turn.id)
            return .init(
                shouldProcess: isTracked,
                countsAsActivity: isTracked
            )
        case .turnCompleted(let payload):
            let isTracked = isTrackedTurnLifecycle(threadID: payload.threadID, turnID: payload.turn.id)
            return .init(
                shouldProcess: isTracked,
                countsAsActivity: isTracked
            )
        case .itemStarted(let payload):
            return dispositionForTrackedTurnEvent(
                threadID: payload.threadID,
                turnID: payload.turnID,
                countsAsActivity: true
            )
        case .itemCompleted(let payload):
            return dispositionForTrackedTurnEvent(
                threadID: payload.threadID,
                turnID: payload.turnID,
                countsAsActivity: true
            )
        case .agentMessageDelta(let payload):
            return dispositionForTrackedTurnEvent(
                threadID: payload.threadID,
                turnID: payload.turnID,
                countsAsActivity: codexNotificationDeliveryTier(notification) != .bestEffort
            )
        case .planDelta(let payload):
            return dispositionForTrackedTurnEvent(
                threadID: payload.threadID,
                turnID: payload.turnID,
                countsAsActivity: codexNotificationDeliveryTier(notification) != .bestEffort
            )
        case .commandExecutionOutputDelta(let payload):
            return dispositionForTrackedTurnEvent(
                threadID: payload.threadID,
                turnID: payload.turnID,
                countsAsActivity: false
            )
        case .reasoningSummaryTextDelta(let payload):
            return dispositionForTrackedTurnEvent(
                threadID: payload.threadID,
                turnID: payload.turnID,
                countsAsActivity: codexNotificationDeliveryTier(notification) != .bestEffort
            )
        case .reasoningSummaryPartAdded(let payload):
            return dispositionForTrackedTurnEvent(
                threadID: payload.threadID,
                turnID: payload.turnID,
                countsAsActivity: codexNotificationDeliveryTier(notification) != .bestEffort
            )
        case .reasoningTextDelta(let payload):
            return dispositionForTrackedTurnEvent(
                threadID: payload.threadID,
                turnID: payload.turnID,
                countsAsActivity: codexNotificationDeliveryTier(notification) != .bestEffort
            )
        case .mcpToolCallProgress(let payload):
            return dispositionForTrackedTurnEvent(
                threadID: payload.threadID,
                turnID: payload.turnID,
                countsAsActivity: codexNotificationDeliveryTier(notification) != .bestEffort
            )
        case .error(let payload):
            return dispositionForTrackedTurnEvent(
                threadID: payload.threadID,
                turnID: payload.turnID,
                countsAsActivity: codexNotificationDeliveryTier(notification) != .bestEffort
            )
        case .accountLoginCompleted, .accountUpdated, .accountRateLimitsUpdated, .ignored:
            return .init(shouldProcess: false, countsAsActivity: false)
        }
    }

    private func completionGroupUpdate(streamedText: String?, finalText: String) -> GroupTextUpdate? {
        guard finalText.isEmpty == false else {
            return nil
        }
        guard let streamedText else {
            return .append(finalText)
        }
        if streamedText.isEmpty {
            return .append(finalText)
        }
        if finalText.hasPrefix(streamedText) {
            guard let suffix = String(finalText.dropFirst(streamedText.count)).nilIfEmpty else {
                return nil
            }
            return .append(suffix)
        }
        return .replace(finalText)
    }

    private func notePendingThreadUnavailable(threadID: String, message: String) -> String? {
        guard isActiveReviewThread(threadID) else {
            return nil
        }
        let canTrackUnavailable = turnStatus == nil
            || turnStatus == .inProgress
            || (turnStatus == .completed && finalReview?.nilIfEmpty == nil)
        guard canTrackUnavailable else {
            return nil
        }
        pendingThreadUnavailableReason = message
        return message
    }

    private func isActiveReviewThread(_ threadID: String) -> Bool {
        guard let activeThreadID = self.threadID else {
            return false
        }
        return threadID == activeThreadID
    }

    private func isTrackedTurnLifecycle(threadID: String, turnID: String) -> Bool {
        isActiveReviewThread(threadID) || isTrackedTurn(turnID)
    }

    private func dispositionForTrackedTurnEvent(
        threadID: String,
        turnID: String,
        countsAsActivity: Bool
    ) -> AppServerTrackedNotificationDisposition {
        let isTracked = isTrackedTurnEvent(threadID: threadID, turnID: turnID)
        return .init(
            shouldProcess: isTracked,
            countsAsActivity: isTracked && countsAsActivity
        )
    }

    private func isTrackedTurnEvent(threadID: String, turnID: String) -> Bool {
        guard isActiveReviewThread(threadID) else {
            return false
        }
        if let trackedTurnID = self.turnID {
            return trackedTurnID == turnID
        }
        return true
    }

    private func isTrackedTurn(_ turnID: String) -> Bool {
        turnID == self.turnID
    }
}
