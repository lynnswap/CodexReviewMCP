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
        var controller: AppServerProcessController?
        var requestedTerminationReason: ReviewTerminationReason?
    }

    private let configuration: Configuration
    private var executions: [String: ExecutionHandle] = [:]

    package init(configuration: Configuration = .init()) {
        self.configuration = configuration
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
        let task = Task {
            try await self.runReview(
                jobID: jobID,
                request: requestOptions,
                initialModel: initialResolvedModel,
                store: store
            )
        }
        executions[jobID] = .init(
            sessionID: sessionID,
            task: task,
            controller: nil,
            requestedTerminationReason: nil
        )
        do {
            try await task.value
        } catch {
            executions[jobID] = nil
            throw error
        }
        let result = try await store.readReview(jobID: jobID, sessionID: sessionID)
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
    }

    private func runReview(
        jobID: String,
        request: ReviewRequestOptions,
        initialModel: String?,
        store: CodexReviewStore
    ) async throws {
        let now = Date()
        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                codexCommand: configuration.codexCommand,
                environment: configuration.environment
            )
        )

        do {
            let outcome = try await runner.run(
                request: request,
                defaultTimeoutSeconds: configuration.defaultTimeoutSeconds,
                onStart: { processController, startedAt in
                    await self.markStarted(jobID: jobID, controller: processController)
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

        executions[jobID] = nil
    }

    private func markStarted(jobID: String, controller: AppServerProcessController) {
        guard var handle = executions[jobID] else {
            return
        }
        handle.controller = controller
        executions[jobID] = handle
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
        store: CodexReviewStore
    ) async throws -> ReviewCancelOutcome {
        let normalizedReason = reason.nilIfEmpty ?? "Cancellation requested."
        let terminationReason = ReviewTerminationReason.cancelled(normalizedReason)
        recordRequestedTerminationReason(jobID: job.id, reason: terminationReason)
        let result = try await store.requestCancellation(
            jobID: job.id,
            sessionID: sessionID,
            reason: normalizedReason
        )
        var cancelled = result.state == .cancelled || result.signalled
        if let handle = executions[job.id] {
            if let processController = handle.controller {
                _ = await processController.terminateGracefully(grace: .seconds(2))
            }
        }
        let resolvedReviewThreadID = await job.reviewThreadID
        let resolvedThreadID = await job.threadID
        let status = await job.status.state
        cancelled = result.state == .cancelled
            || status == .cancelled
            || (result.signalled && status == .running)
        return ReviewCancelOutcome(
            reviewThreadID: resolvedReviewThreadID ?? job.id,
            threadID: resolvedThreadID,
            cancelled: cancelled,
            status: status
        )
    }

    private func isBootstrapFailure(_ error: ReviewError) -> Bool {
        switch error {
        case .bootstrapFailed, .spawnFailed:
            true
        case .invalidArguments, .jobNotFound, .accessDenied, .io:
            false
        }
    }
}
