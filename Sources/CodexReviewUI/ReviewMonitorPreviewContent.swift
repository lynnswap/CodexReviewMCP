import Foundation
@_spi(Testing) import CodexReviewModel
import ReviewJobs
import ReviewRuntime

@MainActor
enum ReviewMonitorPreviewContent {
    static func makeStore() -> CodexReviewStore {
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        store.loadForTesting(
            serverState: .running,
            serverURL: URL(string: "http://localhost:9417/mcp"),
            workspaces: makeWorkspaces()
        )
        return store
    }

    private static func makeWorkspaces() -> [CodexReviewWorkspace] {
        [
            CodexReviewWorkspace(
                cwd: "/path/to/CodexReviewMCP",
                sortOrder: 1,
                jobs: [
                    makeJob(
                        id: "preview-active-job",
                        status: .running,
                        targetSummary: "Branch: feature/previews",
                        summary: "Embedded server is ready. Waiting for a review request from the connected client.",
                        logText: """
                        Review session opened.

                        No review job is running yet.
                        """
                    ),
                    makeJob(
                        id: "preview-recent-job",
                        status: .succeeded,
                        targetSummary: "Commit: 8d3c7c2",
                        summary: "No correctness issues found in the latest review.",
                        logText: """
                        Review completed successfully.

                        Result: no findings.
                        """
                    ),
                ]
            ),
        ]
    }

    private static func makeJob(
        id: String,
        status: CodexReviewJobStatus,
        targetSummary: String,
        summary: String,
        logText: String
    ) -> CodexReviewJob {
        CodexReviewJob.makeForTesting(
            id: id,
            cwd: "/path/to/CodexReviewMCP",
            targetSummary: targetSummary,
            model: "gpt-5.1",
            threadID: UUID().uuidString,
            turnID: UUID().uuidString,
            status: status,
            startedAt: Date().addingTimeInterval(-90),
            endedAt: status.isTerminal ? Date().addingTimeInterval(-15) : nil,
            summary: summary,
            lastAgentMessage: "",
            logEntries: [
                ReviewLogEntry(
                    kind: .agentMessage,
                    text: logText
                )
            ],
            rawLogLines: logText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        )
    }
}
