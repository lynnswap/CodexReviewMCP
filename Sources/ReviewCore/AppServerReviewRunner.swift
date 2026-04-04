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

package struct AppServerReviewRunner: Sendable {
    package var settingsBuilder: ReviewExecutionSettingsBuilder
    package var pollInterval: Duration = .milliseconds(100)
    package var threadUnavailableGracePeriod: Duration = .seconds(1)

    package init(settingsBuilder: ReviewExecutionSettingsBuilder = .init()) {
        self.settingsBuilder = settingsBuilder
    }

    package func run(
        session: any AppServerSessionTransport,
        request: ReviewRequestOptions,
        defaultTimeoutSeconds: Int?,
        resolvedModelHint: String? = nil,
        onStart: @escaping @Sendable (Date) async -> Void,
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
        await onStart(startedAt)
        await onEvent(.progress(.started, "Review started."))

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
            let configResponse: AppServerConfigReadResponse = try await session.request(
                method: "config/read",
                params: AppServerConfigReadParams(
                    cwd: request.cwd,
                    includeLayers: false
                ),
                responseType: AppServerConfigReadResponse.self
            )
            resolvedConfig = mergeAppServerConfig(
                primary: configResponse.config,
                fallback: fallbackAppServerConfig
            )
        } catch {
            guard shouldFallbackFromConfigReadError(error) else {
                throw ReviewBootstrapFailure(
                    message: "Failed to read app-server config: \(error.localizedDescription)",
                    model: effectiveModel
                )
            }
            resolvedConfig = fallbackAppServerConfig
            await onEvent(.logEntry(.init(
                kind: .progress,
                text: "Falling back to local config parsing because `config/read` is unavailable."
            )))
        }

        let reviewSpecificModel = localConfig.reviewModel?.nilIfEmpty
            ?? resolvedConfig.reviewModel?.nilIfEmpty
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
            threadResponse = try await session.request(
                method: "thread/start",
                params: threadStart,
                responseType: AppServerThreadStartResponse.self
            )
        } catch {
            throw ReviewBootstrapFailure(
                message: bootstrapFailureMessage(
                    prefix: "Failed to start review thread: \(error.localizedDescription)",
                    diagnostics: await session.diagnosticsTail()
                ),
                model: effectiveModel
            )
        }
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
            appServerReviewRunnerDebug("cleanupThread before review/start because cancellation was requested")
            await cleanupThread(session: session, threadID: threadResponse.thread.id)
            await onEvent(.progress(.completed, "Review cancelled."))
            return cancelledOutcome(
                model: effectiveModel,
                startedAt: startedAt,
                endedAt: Date(),
                reason: cancellationReason
            )
        }

        let reviewResponse: AppServerReviewStartResponse
        do {
            reviewResponse = try await session.request(
                method: "review/start",
                params: AppServerReviewStartParams(
                    threadID: threadResponse.thread.id,
                    target: request.target,
                    delivery: "inline"
                ),
                responseType: AppServerReviewStartResponse.self
            )
        } catch {
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
        await onEvent(.reviewStarted(
            reviewThreadID: reviewThreadID,
            threadID: threadResponse.thread.id,
            turnID: turnID,
            model: effectiveModel
        ))
        await onEvent(.progress(.threadStarted, "Review started: \(reviewThreadID)"))

        var cancellationReasonValue: String?
        var timeoutMessage: String?
        var interruptSent = false
        var awaitingInterruptResolution = false
        var completedWithoutReviewObservedAt: Date?
        var pendingThreadUnavailableObservedAt: ContinuousClock.Instant?
        var diagnosticsTracker = DiagnosticsTailTracker()
        let timeoutSeconds = request.timeoutSeconds ?? defaultTimeoutSeconds
        let clock = ContinuousClock()

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
                return nil
            } catch {
                let endedAt = Date()
                let interruptFailure = "Failed to interrupt review: \(error.localizedDescription)"
                await onEvent(.failed(interruptFailure))
                appServerReviewRunnerDebug("cleanupThread because turn/interrupt failed: \(error.localizedDescription)")
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

        while true {
            await emitDiagnosticTailDelta(
                session: session,
                tracker: &diagnosticsTracker,
                onEvent: onEvent
            )
            let drainedNotifications = await session.drainNotifications()
            let sawTrackedActivity = await state.containsTrackedActivity(drainedNotifications)
            for notification in drainedNotifications {
                await handle(notification: notification, state: state, onEvent: onEvent)
            }

            if cancellationReasonValue == nil {
                cancellationReasonValue = await cancellationReason(requestedTerminationReason: requestedTerminationReason)
            }

            if timeoutMessage == nil,
               let timeoutSeconds,
               Date().timeIntervalSince(startedAt) >= Double(timeoutSeconds)
            {
                timeoutMessage = "Review timed out after \(timeoutSeconds) seconds."
                cancellationReasonValue = timeoutMessage
            }

            let snapshot = await state.snapshot()
            if snapshot.pendingThreadUnavailableReason != nil {
                if snapshot.turnStatus == nil || snapshot.turnStatus == .inProgress {
                    if awaitingInterruptResolution {
                        pendingThreadUnavailableObservedAt = nil
                    } else if cancellationReasonValue != nil || timeoutMessage != nil {
                        pendingThreadUnavailableObservedAt = nil
                    } else if sawTrackedActivity == false {
                        let observedAt = pendingThreadUnavailableObservedAt ?? clock.now
                        pendingThreadUnavailableObservedAt = observedAt
                        if clock.now >= observedAt.advanced(by: threadUnavailableGracePeriod),
                           let reason = await state.finalizePendingThreadUnavailableFailure()
                        {
                            await onEvent(.logEntry(.init(kind: .error, text: reason)))
                            await onEvent(.failed(reason))
                            continue
                        }
                    } else {
                        pendingThreadUnavailableObservedAt = nil
                    }
                } else {
                    pendingThreadUnavailableObservedAt = nil
                }
            } else {
                pendingThreadUnavailableObservedAt = nil
            }

            if (snapshot.turnStatus == nil || snapshot.turnStatus == .inProgress),
               let cancellationReasonValue,
               interruptSent == false
            {
                if let outcome = await requestInterrupt(
                    using: snapshot,
                    cancellationReasonValue: cancellationReasonValue
                ) {
                    return outcome
                }
                try? await Task.sleep(for: pollInterval)
                continue
            }

            if let turnStatus = snapshot.turnStatus {
                if awaitingInterruptResolution,
                   turnStatus == .inProgress,
                   let cancellationReasonValue
                {
                    let endedAt = Date()
                    appServerReviewRunnerDebug("cleanupThread while awaiting interrupt resolution because turn stayed inProgress")
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
                       snapshot.finalReview?.nilIfEmpty == nil
                    {
                        let observedAt = completedWithoutReviewObservedAt ?? Date()
                        completedWithoutReviewObservedAt = observedAt
                        let completionGraceSeconds: Double
                        if snapshot.pendingThreadUnavailableReason == nil {
                            completionGraceSeconds = 0.25
                        } else {
                            let components = threadUnavailableGracePeriod.components
                            completionGraceSeconds =
                                Double(components.seconds)
                                + Double(components.attoseconds) / 1_000_000_000_000_000_000
                        }
                        if Date().timeIntervalSince(observedAt) < completionGraceSeconds {
                            try? await Task.sleep(for: .milliseconds(20))
                            continue
                        }
                    } else {
                        completedWithoutReviewObservedAt = nil
                    }

                    let endedAt = Date()
                    appServerReviewRunnerDebug("cleanupThread after terminal turn status \(turnStatus.rawValue)")
                    await cleanupThread(session: session, threadID: snapshot.threadID ?? threadResponse.thread.id)
                    let finalSnapshot = await state.snapshot()

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

            if let disconnectError = await session.disconnectError() {
                let endedAt = Date()
                let finalSnapshot = await state.snapshot()
                appServerReviewRunnerDebug("cleanupThread because websocket disconnected: \(disconnectError.localizedDescription)")
                await cleanupThread(session: session, threadID: finalSnapshot.threadID ?? threadResponse.thread.id)
                await onUnrecoverableTransportFailure()
                await emitDiagnosticTailDelta(
                    session: session,
                    tracker: &diagnosticsTracker,
                    onEvent: onEvent
                )
                if finalSnapshot.reviewThreadID == nil {
                    throw ReviewBootstrapFailure(
                        message: bootstrapFailureMessage(
                            prefix: disconnectError.localizedDescription,
                            diagnostics: await session.diagnosticsTail()
                        ),
                        model: effectiveModel
                    )
                }
                let reason = timeoutMessage
                    ?? cancellationReasonValue
                    ?? finalSnapshot.errorMessage
                    ?? disconnectError.localizedDescription
                let progressMessage: String
                let state: ReviewJobState
                let summary: String
                if let timeoutMessage {
                    progressMessage = "Review timed out."
                    state = .failed
                    summary = timeoutMessage
                } else if cancellationReasonValue != nil {
                    progressMessage = "Review cancelled."
                    state = .cancelled
                    summary = "Review cancelled."
                } else {
                    progressMessage = "Review failed."
                    state = .failed
                    summary = "Review failed."
                }
                await onEvent(.progress(.completed, progressMessage))
                return ReviewProcessOutcome(
                    state: state,
                    exitCode: timeoutMessage == nil ? (state == .failed ? 1 : 0) : 124,
                    reviewThreadID: finalSnapshot.reviewThreadID,
                    threadID: finalSnapshot.threadID,
                    turnID: finalSnapshot.turnID,
                    model: effectiveModel,
                    hasFinalReview: finalSnapshot.finalReview?.nilIfEmpty != nil,
                    lastAgentMessage: finalSnapshot.lastAgentMessage ?? "",
                    errorMessage: reason,
                    summary: summary,
                    startedAt: startedAt,
                    endedAt: endedAt,
                    content: finalSnapshot.finalReview ?? finalSnapshot.lastAgentMessage ?? reason
                )
            }

            if snapshot.turnStatus == .inProgress {
                try? await Task.sleep(for: pollInterval)
                continue
            }

            try? await Task.sleep(for: pollInterval)
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
        var cleanupSucceeded = true
        do {
            let _: AppServerEmptyResponse = try await session.request(
                method: "thread/backgroundTerminals/clean",
                params: AppServerThreadBackgroundTerminalsCleanParams(threadID: threadID),
                responseType: AppServerEmptyResponse.self
            )
        } catch {
            cleanupSucceeded = false
        }
        do {
            let _: AppServerEmptyResponse = try await session.request(
                method: "thread/unsubscribe",
                params: AppServerThreadUnsubscribeParams(threadID: threadID),
                responseType: AppServerEmptyResponse.self
            )
        } catch {
            cleanupSucceeded = false
        }
        _ = await session.drainNotifications()
        let disconnectError = await session.disconnectError()
        if cleanupSucceeded == false || disconnectError != nil {
            await session.close()
        }
    }
}

private func appServerReviewRunnerDebug(_ message: String) {
    guard codexReviewMCPRunnerDebugEnabled else {
        return
    }
    fputs("[codex-review-mcp.runner] \(message)\n", stderr)
}

private let codexReviewMCPRunnerDebugEnabled: Bool = {
    let value = ProcessInfo.processInfo.environment["CODEX_REVIEW_MCP_DEBUG_RUNNER"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    switch value {
    case "1", "true", "yes", "on":
        return true
    default:
        return false
    }
}()

private struct DiagnosticsTailTracker {
    fileprivate var lastTail = ""
}

private func emitDiagnosticTailDelta(
    session: any AppServerSessionTransport,
    tracker: inout DiagnosticsTailTracker,
    onEvent: @escaping @Sendable (ReviewProcessEvent) async -> Void
) async {
    let currentTail = await session.diagnosticsTail()
    guard currentTail.isEmpty == false, currentTail != tracker.lastTail else {
        tracker.lastTail = currentTail
        return
    }

    let deltaText: String
    if tracker.lastTail.isEmpty {
        deltaText = currentTail
    } else if currentTail.hasPrefix(tracker.lastTail) {
        var suffix = String(currentTail.dropFirst(tracker.lastTail.count))
        if suffix.first == "\n" {
            suffix.removeFirst()
        }
        deltaText = suffix
    } else {
        deltaText = currentTail
    }
    tracker.lastTail = currentTail

    for line in deltaText.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
        await onEvent(.rawLine(String(line)))
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

    func containsTrackedActivity(_ notifications: [AppServerServerNotification]) -> Bool {
        notifications.contains { notification in
            switch notification {
            case .threadStatusChanged(let payload):
                return isActiveReviewThread(payload.threadID)
            case .threadClosed(let payload):
                return isActiveReviewThread(payload.threadID)
            case .turnStarted(let payload):
                return isActiveReviewThread(payload.threadID) || isTrackedTurn(payload.turn.id)
            case .turnCompleted(let payload):
                return isActiveReviewThread(payload.threadID) || isTrackedTurn(payload.turn.id)
            case .error(let payload):
                return isActiveReviewThread(payload.threadID) && isTrackedTurn(payload.turnID)
            case .itemStarted(let payload):
                return isActiveReviewThread(payload.threadID) && isTrackedTurn(payload.turnID)
            case .itemCompleted(let payload):
                return isActiveReviewThread(payload.threadID) && isTrackedTurn(payload.turnID)
            case .agentMessageDelta(let payload):
                return isActiveReviewThread(payload.threadID) && isTrackedTurn(payload.turnID)
            case .planDelta(let payload):
                return isActiveReviewThread(payload.threadID) && isTrackedTurn(payload.turnID)
            case .commandExecutionOutputDelta(let payload):
                return isActiveReviewThread(payload.threadID) && isTrackedTurn(payload.turnID)
            case .reasoningSummaryTextDelta(let payload):
                return isActiveReviewThread(payload.threadID) && isTrackedTurn(payload.turnID)
            case .reasoningSummaryPartAdded(let payload):
                return isActiveReviewThread(payload.threadID) && isTrackedTurn(payload.turnID)
            case .reasoningTextDelta(let payload):
                return isActiveReviewThread(payload.threadID) && isTrackedTurn(payload.turnID)
            case .mcpToolCallProgress(let payload):
                return isActiveReviewThread(payload.threadID) && isTrackedTurn(payload.turnID)
            case .ignored:
                return false
            }
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

    private func isTrackedTurn(_ turnID: String) -> Bool {
        turnID == self.turnID
    }
}
