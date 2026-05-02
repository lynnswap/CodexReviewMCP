import Foundation
import ReviewDomain

extension CodexReviewJob {
    @_spi(Testing)
    public static func makeForTesting(
        id: String = UUID().uuidString,
        sessionID: String = "session-1",
        cwd: String = "/tmp/repo",
        targetSummary: String,
        model: String? = "gpt-5",
        threadID: String? = nil,
        turnID: String? = nil,
        status: CodexReviewJobStatus,
        cancellationRequested: Bool = false,
        cancellation: ReviewCancellation? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        summary: String,
        hasFinalReview: Bool = false,
        lastAgentMessage: String? = "",
        logEntries: [ReviewLogEntry] = [],
        errorMessage: String? = nil,
        exitCode: Int? = nil
    ) -> CodexReviewJob {
        CodexReviewJob(
            id: id,
            sessionID: sessionID,
            cwd: cwd,
            reviewThreadID: threadID,
            targetSummary: targetSummary,
            model: model,
            threadID: threadID,
            turnID: turnID,
            status: status,
            cancellationRequested: cancellationRequested,
            cancellation: cancellation,
            startedAt: startedAt,
            endedAt: endedAt,
            summary: summary,
            hasFinalReview: hasFinalReview,
            lastAgentMessage: lastAgentMessage,
            logEntries: logEntries,
            errorMessage: errorMessage,
            exitCode: exitCode
        )
    }
}
