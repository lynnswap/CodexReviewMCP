//
//  ContentView.swift
//  CodexReviewMonitor
//
//  Created by Kazuki Nakashima on 2026/03/28.
//

import Foundation
import SwiftUI
#if DEBUG
@_spi(Testing) import CodexReviewMCP
import ReviewJobs
#else
import CodexReviewMCP
#endif
struct ContentView: View {
    let store: CodexReviewStore

    var body: some View {
        ReviewMonitorSplitViewRepresentable(store: store)
    }
}

#if DEBUG
#Preview {
    ContentView(store: ReviewMonitorPreviewContent.makeStore())
}

@MainActor
private enum ReviewMonitorPreviewContent {
    static func makeStore() -> CodexReviewStore {
        let store = CodexReviewStore()
        store.loadForTesting(
            serverState: .running,
            serverURL: URL(string: "http://localhost:9417/mcp"),
            jobs: makeJobs()
        )
        return store
    }

    private static func makeJobs() -> [CodexReviewJob] {
        [
            makeJob(
                id: "preview-active-job",
                status: .running,
                targetSummary: "Branch: feature/previews",
                summary: "Embedded server is ready. Waiting for a review request from the connected client.",
                logText: """
                Review session opened.

                No active review job is running yet.
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
#endif
