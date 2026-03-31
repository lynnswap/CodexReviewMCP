import Foundation
import ReviewJobs
import ReviewRuntime

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
            sessionID: sessionID,
            cwd: cwd,
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
            exitCode: exitCode,
            artifacts: .init(eventsPath: nil, logPath: nil, lastMessagePath: nil)
        )
    }
}
