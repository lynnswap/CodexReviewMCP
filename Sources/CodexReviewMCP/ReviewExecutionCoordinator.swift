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
        var task: Task<Void, Never>
        var controller: ReviewProcessController?
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
        let jobID = try await store.enqueueReview(
            sessionID: sessionID,
            request: requestOptions
        )
        let task = Task {
            await self.runReview(
                jobID: jobID,
                request: requestOptions,
                store: store
            )
        }
        executions[jobID] = .init(
            sessionID: sessionID,
            task: task,
            controller: nil,
            requestedTerminationReason: nil
        )
        _ = await task.value
        let result = try await store.readReview(
            reviewThreadID: jobID,
            sessionID: sessionID
        )
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
        let result = try await store.requestCancellation(
            jobID: reviewThreadID,
            sessionID: sessionID,
            reason: normalizedReason
        )
        var cancelled = result.state == .cancelled
        if var handle = executions[reviewThreadID] {
            handle.requestedTerminationReason = .cancelled(normalizedReason)
            executions[reviewThreadID] = handle
            if let processController = handle.controller {
                cancelled = await processController.terminateGracefully(grace: .seconds(2)) || cancelled
            }
        }
        let job = try await store.resolveJob(
            sessionID: sessionID,
            selector: .init(reviewThreadID: reviewThreadID)
        )
        let threadID = await job.threadID
        let status = await job.status.state
        return ReviewCancelOutcome(
            jobID: result.jobID,
            reviewThreadID: result.jobID,
            threadID: threadID,
            cancelled: cancelled,
            status: status
        )
    }

    package func cancelReview(
        selector: ReviewJobSelector,
        sessionID: String,
        store: CodexReviewStore
    ) async throws -> ReviewCancelOutcome {
        let job = try await store.resolveJob(sessionID: sessionID, selector: selector)
        return try await cancelReview(
            reviewThreadID: job.id,
            sessionID: sessionID,
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
            _ = try? await cancelReview(
                reviewThreadID: jobID,
                sessionID: sessionID,
                reason: reason,
                store: store
            )
        }
    }

    private func runReview(
        jobID: String,
        request: ReviewRequestOptions,
        store: CodexReviewStore
    ) async {
        let now = Date()
        let runner = CodexReviewProcessRunner(
            commandBuilder: ReviewCommandBuilder(
                codexCommand: configuration.codexCommand,
                environment: configuration.environment
            )
        )

        do {
            let outcome = try await runner.run(
                request: request,
                defaultTimeoutSeconds: configuration.defaultTimeoutSeconds,
                onStart: { artifacts, processController, startedAt in
                    await self.markStarted(jobID: jobID, controller: processController)
                    await store.markStarted(
                        jobID: jobID,
                        artifacts: artifacts,
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
        } catch {
            let message = (error as? ReviewError)?.errorDescription ?? error.localizedDescription
            await store.failToStart(
                jobID: jobID,
                message: message,
                startedAt: now,
                endedAt: Date()
            )
        }

        executions[jobID] = nil
        await store.pruneClosedJobIfNeeded(jobID: jobID)
    }

    private func markStarted(jobID: String, controller: ReviewProcessController) {
        guard var handle = executions[jobID] else {
            return
        }
        handle.controller = controller
        executions[jobID] = handle
    }

    private func requestedTerminationReason(jobID: String) -> ReviewTerminationReason? {
        executions[jobID]?.requestedTerminationReason
    }
}
