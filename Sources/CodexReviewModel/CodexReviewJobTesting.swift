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
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        summary: String,
        lastAgentMessage: String? = "",
        logEntries: [ReviewLogEntry] = [],
        rawLogLines: [String] = [],
        errorMessage: String? = nil,
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
            startedAt: startedAt,
            endedAt: endedAt,
            summary: summary,
            lastAgentMessage: lastAgentMessage,
            logEntries: logEntries,
            rawLogLines: rawLogLines,
            errorMessage: errorMessage,
            exitCode: exitCode
        )
    }
}
