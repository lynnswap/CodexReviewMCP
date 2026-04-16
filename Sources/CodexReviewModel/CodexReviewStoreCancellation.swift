import Foundation
import ReviewJobs

extension CodexReviewStore {
    package func cancelReview(
        jobID: String,
        sessionID: String,
        reason: String = "Cancellation requested."
    ) async throws {
        try await backend.cancelReview(
            jobID: jobID,
            sessionID: sessionID,
            reason: reason,
            store: self
        )
    }

    package func completeCancellationLocally(
        jobID: String,
        sessionID: String,
        reason: String = "Cancellation requested."
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
        job.status = .cancelled
        job.summary = "Review cancelled."
        job.hasFinalReview = false
        job.errorMessage = reason.nilIfEmpty ?? job.errorMessage
        job.endedAt = Date()
        writeDiagnosticsIfNeeded()
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
        let jobs = workspaces
            .flatMap(\.jobs)
            .filter { $0.isTerminal == false }
        var firstError: (any Error)?
        for job in jobs {
            do {
                try await cancelReview(
                    jobID: job.id,
                    sessionID: job.sessionID,
                    reason: reason
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
}
