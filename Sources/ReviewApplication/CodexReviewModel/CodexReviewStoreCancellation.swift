import Foundation
import ReviewDomain

extension CodexReviewStore {
    package func cancelReview(
        jobID: String,
        sessionID: String,
        cancellation: ReviewCancellation = .system()
    ) async throws {
        _ = try await coordinator.cancelReviewByID(
            jobID: jobID,
            sessionID: sessionID,
            cancellation: cancellation,
            store: self
        )
    }

    package func completeCancellationLocally(
        jobID: String,
        sessionID: String,
        cancellation: ReviewCancellation = .system()
    ) throws {
        guard let job = workspaces
            .lazy
            .flatMap(\.jobs)
            .first(where: { $0.id == jobID })
        else {
            throw ReviewError.jobNotFound("Job \(jobID) was not found.")
        }
        guard job.sessionID == sessionID else {
            throw ReviewError.accessDenied("Job \(jobID) belongs to another MCP session.")
        }
        guard job.isTerminal == false else {
            return
        }

        job.cancellationRequested = false
        job.cancellation = cancellation
        job.status = .cancelled
        job.summary = cancellation.message
        job.hasFinalReview = false
        job.errorMessage = cancellation.message.nilIfEmpty ?? job.errorMessage
        job.endedAt = Date()
        noteJobMutation()
    }

    package func recordCancellationFailure(
        jobID: String,
        sessionID: String,
        message: String
    ) throws {
        guard let job = workspaces
            .lazy
            .flatMap(\.jobs)
            .first(where: { $0.id == jobID })
        else {
            throw ReviewError.jobNotFound("Job \(jobID) was not found.")
        }
        guard job.sessionID == sessionID else {
            throw ReviewError.accessDenied("Job \(jobID) belongs to another MCP session.")
        }

        if let message = message.nilIfEmpty {
            if message == "Failed to cancel review." {
                job.summary = message
            } else {
                job.summary = "Failed to cancel review: \(message)"
            }
            job.errorMessage = message
        } else {
            job.summary = "Failed to cancel review."
        }
        writeDiagnosticsIfNeeded()
    }

    public func cancelAllRunningJobs(
        reason: String = "Cancellation requested."
    ) async throws {
        let cancellation = ReviewCancellation.system(
            message: reason.nilIfEmpty ?? "Cancellation requested."
        )
        let jobs = workspaces
            .flatMap(\.jobs)
            .filter { $0.isTerminal == false }
        var firstError: (any Error)?
        for job in jobs {
            do {
                try await cancelReview(
                    jobID: job.id,
                    sessionID: job.sessionID,
                    cancellation: cancellation
                )
            } catch {
                let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                try? recordCancellationFailure(
                    jobID: job.id,
                    sessionID: job.sessionID,
                    message: message.isEmpty ? "Failed to cancel review." : message
                )
                if firstError == nil {
                    firstError = error
                }
            }
        }
        if let firstError {
            throw firstError
        }
    }

    package func terminateAllRunningJobsLocally(
        reason: String = "Cancellation requested.",
        failureMessage: String
    ) {
        let resolvedError = failureMessage.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        for job in workspaces.flatMap(\.jobs) where job.isTerminal == false {
            job.cancellationRequested = false
            job.cancellation = nil
            job.status = .failed
            if let resolvedError {
                job.summary = "Failed to cancel review: \(resolvedError)"
            } else {
                job.summary = "Failed to cancel review."
            }
            job.hasFinalReview = false
            job.errorMessage = resolvedError ?? reason.nilIfEmpty ?? job.errorMessage
            job.endedAt = Date()
        }
        noteJobMutation()
    }
}
