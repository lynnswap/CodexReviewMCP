import Foundation
import ReviewCore
import ReviewJobs

package actor ReviewExecutionCoordinator {
    package struct Configuration: Sendable {
        package var defaultTimeoutSeconds: Int?
        package var codexCommand: String
        package var environment: [String: String]

        package init(
            defaultTimeoutSeconds: Int? = nil,
            codexCommand: String = "codex",
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) {
            self.defaultTimeoutSeconds = defaultTimeoutSeconds
            self.codexCommand = codexCommand
            self.environment = environment
        }
    }

    private struct ExecutionHandle {
        var sessionID: String
        var task: Task<Void, Error>
        var requestedTerminationReason: ReviewTerminationReason?
    }

    private let configuration: Configuration
    private let appServerManager: any AppServerManaging
    private let runtimeStateDidChange: @Sendable (AppServerRuntimeState) async -> Void
    private var executions: [String: ExecutionHandle] = [:]
    private var sessionLanes: [String: ReviewSessionLane] = [:]

    package init(
        configuration: Configuration = .init(),
        appServerManager: any AppServerManaging,
        runtimeStateDidChange: @escaping @Sendable (AppServerRuntimeState) async -> Void = { _ in }
    ) {
        self.configuration = configuration
        self.appServerManager = appServerManager
        self.runtimeStateDidChange = runtimeStateDidChange
    }

    package func startReview(
        sessionID: String,
        request: ReviewStartRequest,
        store: CodexReviewStore
    ) async throws -> ReviewReadResult {
        let request = try request.validated()
        let requestOptions = try request.reviewRequestOptions().validated()
        let initialResolvedModel = resolveInitialReviewModel(environment: configuration.environment)
        let jobID = try await store.enqueueReview(
            sessionID: sessionID,
            request: requestOptions,
            initialModel: initialResolvedModel
        )

        let startupGate = StartupGate()
        let task = Task {
            await startupGate.wait()
            try await self.runReview(
                jobID: jobID,
                sessionID: sessionID,
                request: requestOptions,
                initialModel: initialResolvedModel,
                store: store
            )
        }
        executions[jobID] = .init(
            sessionID: sessionID,
            task: task,
            requestedTerminationReason: nil
        )
        if let pendingTerminationReason = await store.pendingTerminationReason(
            jobID: jobID,
            sessionID: sessionID
        ) {
            recordRequestedTerminationReason(jobID: jobID, reason: pendingTerminationReason)
        }
        await startupGate.open()

        do {
            try await task.value
        } catch {
            executions[jobID] = nil
            throw error
        }

        let result = try await store.readReview(jobID: jobID, sessionID: sessionID)
        executions[jobID] = nil
        await store.pruneClosedJobIfNeeded(jobID: jobID)
        return result
    }

    package func cancelReview(
        reviewThreadID: String,
        sessionID: String,
        reason: String = "Cancellation requested.",
        store: CodexReviewStore
    ) async throws -> ReviewCancelOutcome {
        let normalizedReason = reason.nilIfEmpty ?? "Cancellation requested."
        let job = try await store.resolveJob(
            sessionID: sessionID,
            selector: .init(reviewThreadID: reviewThreadID)
        )
        return try await cancelResolvedJob(
            job: job,
            sessionID: sessionID,
            reason: normalizedReason,
            store: store
        )
    }

    package func cancelReview(
        selector: ReviewJobSelector,
        sessionID: String,
        store: CodexReviewStore
    ) async throws -> ReviewCancelOutcome {
        let job = try await store.resolveJob(sessionID: sessionID, selector: selector)
        return try await cancelResolvedJob(
            job: job,
            sessionID: sessionID,
            reason: "Cancellation requested.",
            store: store
        )
    }

    package func closeSession(
        _ sessionID: String,
        reason: String,
        store: CodexReviewStore
    ) async {
        let targetIDs = await store.closeSessionState(sessionID)
        let closeReason = ReviewTerminationReason.cancelled(reason.nilIfEmpty ?? "Cancellation requested.")
        for jobID in targetIDs {
            recordRequestedTerminationReason(jobID: jobID, reason: closeReason)
        }
        if let lane = sessionLanes[sessionID] {
            await lane.notifyPendingStateChange()
        }
        for jobID in targetIDs {
            guard let job = try? await store.resolveJob(jobID: jobID, sessionID: sessionID) else {
                continue
            }
            _ = try? await cancelResolvedJob(
                job: job,
                sessionID: sessionID,
                reason: reason,
                store: store,
                notifyLane: false
            )
        }
        if let lane = sessionLanes.removeValue(forKey: sessionID) {
            await lane.close(reason: reason)
        }
        await store.pruneClosedSessionJobs(
            sessionID: sessionID,
            excludingJobIDs: Set(executions.keys)
        )
    }

    package func shutdown(reason: String, store: CodexReviewStore) async {
        let snapshot = executions
        for (jobID, handle) in snapshot {
            guard let job = try? await store.resolveJob(jobID: jobID, sessionID: handle.sessionID) else {
                continue
            }
            _ = try? await cancelResolvedJob(
                job: job,
                sessionID: handle.sessionID,
                reason: reason,
                store: store
            )
        }

        for (_, lane) in sessionLanes {
            await lane.close(reason: reason)
        }

        for (_, handle) in snapshot {
            _ = try? await handle.task.value
        }

        sessionLanes.removeAll()
    }

    private func runReview(
        jobID: String,
        sessionID: String,
        request: ReviewRequestOptions,
        initialModel: String?,
        store: CodexReviewStore
    ) async throws {
        let now = Date()
        let lane = sessionLane(for: sessionID)
        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                codexCommand: configuration.codexCommand,
                environment: configuration.environment
            )
        )

        do {
            let outcome = try await lane.runReview(
                runner: runner,
                request: request,
                defaultTimeoutSeconds: configuration.defaultTimeoutSeconds,
                resolvedModelHint: initialModel,
                onStart: { startedAt in
                    await store.markStarted(
                        jobID: jobID,
                        startedAt: startedAt
                    )
                },
                onEvent: { event in
                    await store.handle(jobID: jobID, event: event)
                },
                requestedTerminationReason: {
                    await self.requestedTerminationReason(jobID: jobID)
                },
                onUnrecoverableTransportFailure: {
                    await self.handleUnrecoverableTransportFailure(sessionID: sessionID)
                }
            )
            await store.completeReview(jobID: jobID, outcome: outcome)
        } catch let error as ReviewBootstrapFailure {
            if case .cancelled(let reason)? = self.requestedTerminationReason(jobID: jobID) {
                await store.markBootstrapCancelled(
                    jobID: jobID,
                    reason: reason,
                    model: error.model ?? initialModel,
                    startedAt: now,
                    endedAt: Date()
                )
            } else {
                await store.failToStart(
                    jobID: jobID,
                    message: error.errorDescription ?? "Failed to start review.",
                    model: error.model ?? initialModel,
                    startedAt: now,
                    endedAt: Date()
                )
            }
        } catch let error as ReviewError where isBootstrapFailure(error) {
            if case .cancelled(let reason)? = self.requestedTerminationReason(jobID: jobID) {
                await store.markBootstrapCancelled(
                    jobID: jobID,
                    reason: reason,
                    model: initialModel,
                    startedAt: now,
                    endedAt: Date()
                )
            } else {
                await store.failToStart(
                    jobID: jobID,
                    message: error.errorDescription ?? "Failed to start review.",
                    model: initialModel,
                    startedAt: now,
                    endedAt: Date()
                )
            }
        } catch {
            let message = (error as? ReviewError)?.errorDescription ?? error.localizedDescription
            await store.failToStart(
                jobID: jobID,
                message: message,
                model: initialModel,
                startedAt: now,
                endedAt: Date()
            )
        }

    }

    private func sessionLane(for sessionID: String) -> ReviewSessionLane {
        if let existing = sessionLanes[sessionID] {
            return existing
        }
        let lane = ReviewSessionLane(
            sessionID: sessionID,
            appServerManager: appServerManager,
            runtimeStateDidChange: runtimeStateDidChange
        )
        sessionLanes[sessionID] = lane
        return lane
    }

    private func requestedTerminationReason(jobID: String) -> ReviewTerminationReason? {
        executions[jobID]?.requestedTerminationReason
    }

    private func recordRequestedTerminationReason(
        jobID: String,
        reason: ReviewTerminationReason
    ) {
        guard var handle = executions[jobID] else {
            return
        }
        handle.requestedTerminationReason = reason
        executions[jobID] = handle
    }

    private func cancelResolvedJob(
        job: CodexReviewJob,
        sessionID: String,
        reason: String,
        store: CodexReviewStore,
        notifyLane: Bool = true
    ) async throws -> ReviewCancelOutcome {
        let normalizedReason = reason.nilIfEmpty ?? "Cancellation requested."
        let terminationReason = ReviewTerminationReason.cancelled(normalizedReason)
        recordRequestedTerminationReason(jobID: job.id, reason: terminationReason)
        if notifyLane, let lane = sessionLanes[sessionID] {
            await lane.notifyPendingStateChange()
        }
        let result = try await store.requestCancellation(
            jobID: job.id,
            sessionID: sessionID,
            reason: normalizedReason
        )
        if result.signalled, let lane = sessionLanes[sessionID] {
            await lane.invalidateTransport()
        }
        let resolvedReviewThreadID = await job.reviewThreadID
        let resolvedThreadID = await job.threadID
        let status = await job.status.state
        let cancelled = result.state == .cancelled
            || status == .cancelled
            || (result.signalled && status == .running)
        return ReviewCancelOutcome(
            reviewThreadID: resolvedReviewThreadID ?? job.id,
            threadID: resolvedThreadID,
            cancelled: cancelled,
            status: status
        )
    }

    private func handleUnrecoverableTransportFailure(sessionID: String) async {
        guard let lane = sessionLanes[sessionID] else {
            return
        }
        await lane.invalidateTransport()
    }
}

private actor ReviewSessionLane {
    private let sessionID: String
    private let appServerManager: any AppServerManaging
    private let runtimeStateDidChange: @Sendable (AppServerRuntimeState) async -> Void
    private var transport: (any AppServerSessionTransport)?
    private var reviewInFlight = false
    private var isClosed = false
    private var closeReason: String?
    private var queuedReviewWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        sessionID: String,
        appServerManager: any AppServerManaging,
        runtimeStateDidChange: @escaping @Sendable (AppServerRuntimeState) async -> Void
    ) {
        self.sessionID = sessionID
        self.appServerManager = appServerManager
        self.runtimeStateDidChange = runtimeStateDidChange
    }

    func runReview(
        runner: AppServerReviewRunner,
        request: ReviewRequestOptions,
        defaultTimeoutSeconds: Int?,
        resolvedModelHint: String?,
        onStart: @escaping @Sendable (Date) async -> Void,
        onEvent: @escaping @Sendable (ReviewProcessEvent) async -> Void,
        requestedTerminationReason: @escaping @Sendable () async -> ReviewTerminationReason?,
        onUnrecoverableTransportFailure: @escaping @Sendable () async -> Void
    ) async throws -> ReviewProcessOutcome {
        try await acquireReviewSlot(requestedTerminationReason: requestedTerminationReason)
        defer { releaseReviewSlot() }

        if case .cancelled(let reason)? = await requestedTerminationReason() {
            throw ReviewBootstrapFailure(message: reason, model: nil)
        }
        let transport = try await connectedTransport()
        do {
            return try await runner.run(
                session: transport,
                request: request,
                defaultTimeoutSeconds: defaultTimeoutSeconds,
                resolvedModelHint: resolvedModelHint,
                onStart: onStart,
                onEvent: onEvent,
                requestedTerminationReason: requestedTerminationReason,
                onUnrecoverableTransportFailure: onUnrecoverableTransportFailure
            )
        } catch {
            await transport.close()
            self.transport = nil
            throw error
        }
    }

    func close() async {
        await close(reason: nil)
    }

    func close(reason: String?) async {
        isClosed = true
        if let reason {
            closeReason = reason
        }
        notifyPendingStateChange()
        if let transport {
            await transport.close()
        }
        transport = nil
        _ = sessionID
    }

    private func connectedTransport() async throws -> any AppServerSessionTransport {
        if isClosed {
            throw ReviewBootstrapFailure(message: closeReason ?? "Review cancelled.", model: nil)
        }
        if let transport,
           await transport.isClosed() == false,
           await transport.disconnectError() == nil
        {
            return transport
        }

        let newTransport = try await appServerManager.makeSessionTransport(sessionID: sessionID)
        if isClosed {
            await newTransport.close()
            throw ReviewBootstrapFailure(message: closeReason ?? "Review cancelled.", model: nil)
        }
        transport = newTransport
        if let runtimeState = await appServerManager.currentRuntimeState() {
            await runtimeStateDidChange(runtimeState)
        }
        return newTransport
    }

    func notifyPendingStateChange() {
        guard queuedReviewWaiters.isEmpty == false else {
            return
        }
        let continuations = queuedReviewWaiters
        queuedReviewWaiters.removeAll(keepingCapacity: false)
        for continuation in continuations {
            continuation.resume()
        }
    }

    private func acquireReviewSlot(
        requestedTerminationReason: @escaping @Sendable () async -> ReviewTerminationReason?
    ) async throws {
        while true {
            if case .cancelled(let reason)? = await requestedTerminationReason() {
                throw ReviewBootstrapFailure(message: reason, model: nil)
            }
            if reviewInFlight == false {
                reviewInFlight = true
                return
            }
            await withCheckedContinuation { continuation in
                queuedReviewWaiters.append(continuation)
            }
            if case .cancelled(let reason)? = await requestedTerminationReason() {
                throw ReviewBootstrapFailure(message: reason, model: nil)
            }
        }
    }

    private func releaseReviewSlot() {
        reviewInFlight = false
        notifyPendingStateChange()
    }

    func invalidateTransport() async {
        if let transport {
            await transport.close()
        }
        transport = nil
    }
}

private actor StartupGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen {
            return
        }
        await withCheckedContinuation { continuation in
            if isOpen {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    func open() {
        guard isOpen == false else {
            return
        }
        isOpen = true
        let continuations = waiters
        waiters.removeAll(keepingCapacity: false)
        for continuation in continuations {
            continuation.resume()
        }
    }
}

private func isBootstrapFailure(_ error: ReviewError) -> Bool {
    switch error {
    case .bootstrapFailed, .spawnFailed:
        true
    case .invalidArguments, .jobNotFound, .accessDenied, .io:
        false
    }
}
