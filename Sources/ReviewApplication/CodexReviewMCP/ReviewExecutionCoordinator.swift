import Foundation
import ReviewPorts
import ReviewDomain

package actor ReviewExecutionCoordinator {
    private enum ExecutionPhase {
        case bootstrapping
        case running
    }

    package struct Configuration: Sendable {
        package var dateNow: @Sendable () -> Date

        package init(
            dateNow: @escaping @Sendable () -> Date = { Date() }
        ) {
            self.dateNow = dateNow
        }
    }

    private struct ExecutionHandle {
        var sessionID: String
        var task: Task<Void, Error>
        var requestedTerminationReason: ReviewTerminationReason?
        var stateChangeContinuation: AsyncStream<Void>.Continuation
        var phase: ExecutionPhase
    }

    private let configuration: Configuration
    private let reviewEngine: any ReviewEngine
    private var executions: [String: ExecutionHandle] = [:]

    package init(
        configuration: Configuration = .init(),
        reviewEngine: any ReviewEngine
    ) {
        self.configuration = configuration
        self.reviewEngine = reviewEngine
    }

    package func startReview(
        sessionID: String,
        request: ReviewStartRequest,
        store: CodexReviewStore
    ) async throws -> ReviewReadResult {
        let request = try request.validated()
        let requestOptions = try request.reviewRequestOptions().validated()
        let initialResolvedModel = await reviewEngine.initialReviewModel()
        let jobID = try await store.enqueueReview(
            sessionID: sessionID,
            request: requestOptions,
            initialModel: initialResolvedModel
        )

        let startupGate = StartupGate()
        let (stateChangeStream, stateChangeContinuation) = makeStateChangeStream()
        let task = Task {
            await startupGate.wait()
            try await self.runReview(
                jobID: jobID,
                sessionID: sessionID,
                request: requestOptions,
                initialModel: initialResolvedModel,
                stateChangeStream: stateChangeStream,
                store: store
            )
        }
        executions[jobID] = .init(
            sessionID: sessionID,
            task: task,
            requestedTerminationReason: nil,
            stateChangeContinuation: stateChangeContinuation,
            phase: .bootstrapping
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
        cancellation: ReviewCancellation = .system(),
        store: CodexReviewStore
    ) async throws -> ReviewCancelOutcome {
        let job = try await store.resolveJob(
            sessionID: sessionID,
            selector: .init(jobID: jobID)
        )
        return try await cancelResolvedJob(
            job: job,
            sessionID: sessionID,
            cancellation: cancellation,
            store: store
        )
    }

    package func cancelReview(
        selector: ReviewJobSelector,
        sessionID: String,
        cancellation: ReviewCancellation = .system(),
        store: CodexReviewStore
    ) async throws -> ReviewCancelOutcome {
        let job = try await store.resolveJob(sessionID: sessionID, selector: selector)
        return try await cancelResolvedJob(
            job: job,
            sessionID: sessionID,
            cancellation: cancellation,
            store: store
        )
    }

    package func closeSession(
        _ sessionID: String,
        reason: String,
        store: CodexReviewStore
    ) async {
        let targetIDs = await store.closeSessionState(sessionID)
        let closeCancellation = ReviewCancellation.sessionClosed(message: reason.nilIfEmpty ?? "Cancellation requested.")
        for jobID in targetIDs {
            guard let job = try? await store.resolveJob(jobID: jobID, sessionID: sessionID) else {
                continue
            }
            _ = try? await cancelResolvedJob(
                job: job,
                sessionID: sessionID,
                cancellation: closeCancellation,
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
                cancellation: .system(message: reason.nilIfEmpty ?? "Cancellation requested."),
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
        stateChangeStream: AsyncStream<Void>,
        store: CodexReviewStore
    ) async throws {
        let now = configuration.dateNow()
        let requestedTerminationReason: @Sendable () async -> ReviewTerminationReason? = { [weak self] in
            guard let self else {
                return nil
            }
            return await self.requestedTerminationReason(jobID: jobID)
        }

        do {
            let outcome = try await reviewEngine.runReview(
                jobID: jobID,
                sessionID: sessionID,
                request: request,
                resolvedModelHint: initialModel,
                stateChangeStream: stateChangeStream,
                onStart: { startedAt in
                    await store.markStarted(
                        jobID: jobID,
                        startedAt: startedAt
                    )
                },
                onReviewStarted: {
                    await self.markExecutionRunning(jobID: jobID)
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
                    cancellation: reason,
                    model: initialModel,
                    startedAt: now,
                    endedAt: configuration.dateNow()
                )
            } else {
                await store.failToStart(
                    jobID: jobID,
                    message: "Failed to start review.",
                    model: initialModel,
                    startedAt: now,
                    endedAt: configuration.dateNow()
                )
            }
        } catch let error as ReviewBootstrapFailure {
            if case .cancelled(let reason)? = self.requestedTerminationReason(jobID: jobID) {
                await store.markBootstrapCancelled(
                    jobID: jobID,
                    cancellation: reason,
                    model: error.model ?? initialModel,
                    startedAt: now,
                    endedAt: configuration.dateNow()
                )
            } else {
                await store.failToStart(
                    jobID: jobID,
                    message: error.errorDescription ?? "Failed to start review.",
                    model: error.model ?? initialModel,
                    startedAt: now,
                    endedAt: configuration.dateNow()
                )
            }
        } catch let error as ReviewError where isBootstrapFailure(error) {
            if case .cancelled(let reason)? = self.requestedTerminationReason(jobID: jobID) {
                await store.markBootstrapCancelled(
                    jobID: jobID,
                    cancellation: reason,
                    model: initialModel,
                    startedAt: now,
                    endedAt: configuration.dateNow()
                )
            } else {
                await store.failToStart(
                    jobID: jobID,
                    message: error.errorDescription ?? "Failed to start review.",
                    model: initialModel,
                    startedAt: now,
                    endedAt: configuration.dateNow()
                )
            }
        } catch {
            let message = (error as? ReviewError)?.errorDescription ?? error.localizedDescription
            await store.failToStart(
                jobID: jobID,
                message: message,
                model: initialModel,
                startedAt: now,
                endedAt: configuration.dateNow()
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
        await recordRequestedTerminationReasonIfNeeded(jobID: jobID, reason: reason)
    }

    @discardableResult
    private func recordRequestedTerminationReasonIfNeeded(
        jobID: String,
        reason: ReviewTerminationReason,
        notify: Bool = true
    ) async -> ReviewTerminationReason? {
        guard var handle = executions[jobID] else {
            return nil
        }
        if let existingReason = handle.requestedTerminationReason {
            return existingReason
        }
        handle.requestedTerminationReason = reason
        executions[jobID] = handle
        if notify {
            handle.stateChangeContinuation.yield(())
        }
        return reason
    }

    private func notifyTerminationReasonChange(jobID: String) async {
        executions[jobID]?.stateChangeContinuation.yield(())
    }

    private func removeExecution(jobID: String) async {
        guard let handle = executions.removeValue(forKey: jobID) else {
            return
        }
        handle.stateChangeContinuation.finish()
    }

    private func markExecutionRunning(jobID: String) {
        guard var handle = executions[jobID] else {
            return
        }
        handle.phase = .running
        executions[jobID] = handle
    }

    private func interruptExecutionIfNeeded(jobID: String) async {
        guard let handle = executions[jobID] else {
            return
        }
        guard handle.phase == .bootstrapping else {
            return
        }
        let interrupted = await reviewEngine.interruptReview(jobID: jobID)
        if interrupted == false {
            handle.task.cancel()
        }
    }

    private func cancelResolvedJob(
        job: CodexReviewJob,
        sessionID: String,
        cancellation: ReviewCancellation,
        store: CodexReviewStore
    ) async throws -> ReviewCancelOutcome {
        let recordedReason = await recordRequestedTerminationReasonIfNeeded(
            jobID: job.id,
            reason: .cancelled(cancellation),
            notify: false
        )
        let existingCancellation = await job.cancellation
        let effectiveCancellation = recordedReason?.cancellation
            ?? existingCancellation
            ?? cancellation
        let result = try await store.requestCancellation(
            jobID: job.id,
            sessionID: sessionID,
            cancellation: effectiveCancellation
        )
        await notifyTerminationReasonChange(jobID: job.id)
        if result.signalled {
            await interruptExecutionIfNeeded(jobID: job.id)
        }
        let resolvedThreadID = await job.threadID
        let status = await job.status.state
        let resolvedCancellation = await job.cancellation ?? (result.signalled ? effectiveCancellation : nil)
        let cancelled = result.state == .cancelled
            || status == .cancelled
            || (result.signalled && status == .running)
        return ReviewCancelOutcome(
            jobID: job.id,
            threadID: resolvedThreadID,
            cancelled: cancelled,
            status: status,
            cancellation: cancelled ? resolvedCancellation : nil
        )
    }

}

private func makeStateChangeStream() -> (AsyncStream<Void>, AsyncStream<Void>.Continuation) {
    var continuation: AsyncStream<Void>.Continuation!
    let stream = AsyncStream<Void>(bufferingPolicy: .unbounded) {
        continuation = $0
    }
    return (stream, continuation)
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
