import Foundation
import ReviewJobs
import ReviewRuntime

extension CodexReviewJob {
    @_spi(Testing)
    public static func makeForTesting(
        id: String = UUID().uuidString,
        sortOrder: Int = 0,
        sessionID: String = "session-1",
        cwd: String = "/tmp/repo",
        targetSummary: String,
        model: String? = "gpt-5",
        threadID: String? = nil,
        turnID: String? = nil,
        status: CodexReviewJobStatus,
        cancellationRequested: Bool = false,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        summary: String,
        hasFinalReview: Bool = false,
        lastAgentMessage: String? = "",
        logEntries: [ReviewLogEntry] = [],
        terminalError: CodexReviewTerminalError? = nil,
        exitCode: Int? = nil
    ) -> CodexReviewJob {
        CodexReviewJob(
            id: id,
            sortOrder: sortOrder,
            sessionID: sessionID,
            cwd: cwd,
            reviewThreadID: threadID,
            targetSummary: targetSummary,
            model: model,
            threadID: threadID,
            turnID: turnID,
            status: status,
            cancellationRequested: cancellationRequested,
            startedAt: startedAt,
            endedAt: endedAt,
            summary: summary,
            hasFinalReview: hasFinalReview,
            lastAgentMessage: lastAgentMessage,
            logEntries: logEntries,
            terminalError: terminalError,
            exitCode: exitCode
        )
    }
}
