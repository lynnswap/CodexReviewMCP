import CodexReviewModel
import Foundation
import ReviewCore
import ReviewDomain
import ReviewRuntime

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
        var stateChangeSignal: ReviewExecutionStateChangeSignal
        var bootstrapInterrupter: (@Sendable () async -> Void)?
    }

    private let configuration: Configuration
    private let appServerManager: any AppServerManaging
    private let runtimeStateDidChange: @Sendable (AppServerRuntimeState) async -> Void
    private var executions: [String: ExecutionHandle] = [:]

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
        let stateChangeSignal = ReviewExecutionStateChangeSignal()
        let task = Task {
            await startupGate.wait()
            try await self.runReview(
                jobID: jobID,
                sessionID: sessionID,
                request: requestOptions,
                initialModel: initialResolvedModel,
                stateChangeSubscription: await stateChangeSignal.subscription(),
                store: store
            )
        }
        executions[jobID] = .init(
            sessionID: sessionID,
            task: task,
            requestedTerminationReason: nil,
            stateChangeSignal: stateChangeSignal,
            bootstrapInterrupter: {
                task.cancel()
            }
        )
        if let pendingTerminationReason = await store.pendingTerminationReason(
            jobID: jobID,
            sessionID: sessionID
        ) {
            await recordRequestedTerminationReason(jobID: jobID, reason: pendingTerminationReason)
        }
        await startupGate.open()

        do {
            try await task.value
        } catch {
            await removeExecution(jobID: jobID)
            throw error
        }

        let result = try await store.readReview(jobID: jobID, sessionID: sessionID)
        await removeExecution(jobID: jobID)
        await store.pruneClosedJobIfNeeded(jobID: jobID)
        return result
    }

    package func cancelReview(
        jobID: String,
        sessionID: String,
        reason: String = "Cancellation requested.",
        store: CodexReviewStore
    ) async throws -> ReviewCancelOutcome {
        let normalizedReason = reason.nilIfEmpty ?? "Cancellation requested."
        let job = try await store.resolveJob(
            sessionID: sessionID,
            selector: .init(jobID: jobID)
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
            await recordRequestedTerminationReason(jobID: jobID, reason: closeReason)
        }
        for jobID in targetIDs {
            guard let job = try? await store.resolveJob(jobID: jobID, sessionID: sessionID) else {
                continue
            }
            _ = try? await cancelResolvedJob(
                job: job,
                sessionID: sessionID,
                reason: reason,
                store: store
            )
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

        for (_, handle) in snapshot {
            _ = try? await handle.task.value
        }
    }

    private func runReview(
        jobID: String,
        sessionID: String,
        request: ReviewRequestOptions,
        initialModel: String?,
        stateChangeSubscription: AsyncStreamSubscription<Void>,
        store: CodexReviewStore
    ) async throws {
        let now = Date()
        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                codexCommand: configuration.codexCommand,
                environment: configuration.environment
            )
        )
        let requestedTerminationReason: @Sendable () async -> ReviewTerminationReason? = { [weak self] in
            guard let self else {
                return nil
            }
            return await self.requestedTerminationReason(jobID: jobID)
        }

        do {
            if case .cancelled(let reason)? = await requestedTerminationReason() {
                throw ReviewBootstrapFailure(message: reason, model: initialModel)
            }

            let transport = try await appServerManager.checkoutTransport(sessionID: sessionID)
            defer {
                clearBootstrapInterrupter(jobID: jobID)
            }
            defer {
                Task {
                    await transport.close()
                }
            }
            if let runtimeState = await appServerManager.currentRuntimeState() {
                await runtimeStateDidChange(runtimeState)
            }
            if case .cancelled(let reason)? = await requestedTerminationReason() {
                throw ReviewBootstrapFailure(message: reason, model: initialModel)
            }

            let outcome = try await runner.run(
                session: transport,
                request: request,
                defaultTimeoutSeconds: configuration.defaultTimeoutSeconds,
                resolvedModelHint: initialModel,
                diagnosticLineSubscription: await appServerManager.diagnosticLineStream(),
                stateChangeSubscription: stateChangeSubscription,
                diagnosticsTail: { [appServerManager] in
                    await appServerManager.diagnosticsTail()
                },
                onStart: { startedAt in
                    await store.markStarted(
                        jobID: jobID,
                        startedAt: startedAt
                    )
                },
                onReviewStarted: {
                    await self.clearBootstrapInterrupter(jobID: jobID)
                },
                onEvent: { event in
                    await store.handle(jobID: jobID, event: event)
                },
                requestedTerminationReason: {
                    await requestedTerminationReason()
                }
            )
            await store.completeReview(jobID: jobID, outcome: outcome)
        } catch is CancellationError {
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
                    message: "Failed to start review.",
                    model: initialModel,
                    startedAt: now,
                    endedAt: Date()
                )
            }
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
    private func requestedTerminationReason(jobID: String) -> ReviewTerminationReason? {
        executions[jobID]?.requestedTerminationReason
    }

    private func recordRequestedTerminationReason(
        jobID: String,
        reason: ReviewTerminationReason
    ) async {
        guard var handle = executions[jobID] else {
            return
        }
        handle.requestedTerminationReason = reason
        executions[jobID] = handle
        await handle.stateChangeSignal.yield()
    }

    private func removeExecution(jobID: String) async {
        guard let handle = executions.removeValue(forKey: jobID) else {
            return
        }
        await handle.stateChangeSignal.finish()
    }

    private func clearBootstrapInterrupter(jobID: String) {
        guard var handle = executions[jobID] else {
            return
        }
        handle.bootstrapInterrupter = nil
        executions[jobID] = handle
    }

    private func interruptBootstrapIfPresent(jobID: String) async {
        guard let interrupter = executions[jobID]?.bootstrapInterrupter else {
            return
        }
        await interrupter()
    }

    private func cancelResolvedJob(
        job: CodexReviewJob,
        sessionID: String,
        reason: String,
        store: CodexReviewStore
    ) async throws -> ReviewCancelOutcome {
        let normalizedReason = reason.nilIfEmpty ?? "Cancellation requested."
        let terminationReason = ReviewTerminationReason.cancelled(normalizedReason)
        await recordRequestedTerminationReason(jobID: job.id, reason: terminationReason)
        let result = try await store.requestCancellation(
            jobID: job.id,
            sessionID: sessionID,
            reason: normalizedReason
        )
        if result.signalled {
            await interruptBootstrapIfPresent(jobID: job.id)
        }
        let resolvedThreadID = await job.threadID
        let status = await job.status.state
        let cancelled = result.state == .cancelled
            || status == .cancelled
            || (result.signalled && status == .running)
        return ReviewCancelOutcome(
            jobID: job.id,
            threadID: resolvedThreadID,
            cancelled: cancelled,
            status: status
        )
    }
}

private actor ReviewExecutionStateChangeSignal {
    private var continuation: AsyncStream<Void>.Continuation?

    func subscription() -> AsyncStreamSubscription<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        self.continuation = continuation
        return .init(
            stream: stream,
            cancel: {
                await self.finish()
            }
        )
    }

    func yield() {
        continuation?.yield(())
    }

    func finish() {
        continuation?.finish()
        continuation = nil
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
