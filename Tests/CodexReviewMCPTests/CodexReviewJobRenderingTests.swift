import Testing
import ReviewDomain
@_spi(Testing) @testable import ReviewApp
@testable import ReviewDomain
@testable import ReviewRuntime

@Suite
@MainActor
struct CodexReviewJobRenderingTests {
    @Test func rawLogTextPreservesDiagnosticSpacing() {
        let job = CodexReviewJob.makeForTesting(
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running.",
            logEntries: [
                .init(kind: .diagnostic, text: "Traceback (most recent call last):"),
                .init(kind: .diagnostic, text: ""),
                .init(kind: .diagnostic, text: "  File \"main.py\", line 1"),
            ]
        )

        #expect(job.rawLogText == """
        Traceback (most recent call last):

          File "main.py", line 1
        """)
    }

    @Test func activityLogTextPreservesGroupedWhitespace() {
        let job = CodexReviewJob.makeForTesting(
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running.",
            logEntries: [
                .init(kind: .commandOutput, groupID: "cmd_1", text: " first line\n"),
                .init(kind: .commandOutput, groupID: "cmd_1", text: "  second line\n"),
                .init(kind: .commandOutput, groupID: "cmd_2", text: "third line"),
            ]
        )

        #expect(job.activityLogText == """
         first line
          second line

        third line
        """)
    }

    @Test func logTextPreservesChronologicalOrder() {
        let job = CodexReviewJob.makeForTesting(
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running.",
            logEntries: [
                .init(kind: .command, text: "$ git status"),
                .init(kind: .commandOutput, groupID: "cmd_1", text: "M file.swift"),
                .init(kind: .agentMessage, text: "Review complete"),
            ]
        )

        #expect(job.logText == """
        $ git status

        M file.swift

        Review complete
        """)
    }

    @Test func logTextPreservesEmptyDiagnosticLines() {
        let job = CodexReviewJob.makeForTesting(
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running.",
            logEntries: [
                .init(kind: .diagnostic, text: "Traceback"),
                .init(kind: .diagnostic, text: ""),
                .init(kind: .diagnostic, text: "  line 2"),
            ]
        )

        #expect(job.logText == """
        Traceback

          line 2
        """)
    }

    @Test func reviewOutputTextIncludesRawReasoningEntries() {
        let job = CodexReviewJob.makeForTesting(
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running.",
            logEntries: [
                .init(kind: .agentMessage, text: "Reviewing"),
                .init(kind: .rawReasoning, groupID: "rsn_1:0", text: "chain of thought"),
            ]
        )

        #expect(job.reviewOutputText == """
        Reviewing

        chain of thought
        """)
    }

    @Test func logTextCoalescesGroupedEntriesAcrossInterleavedLogs() {
        let job = CodexReviewJob.makeForTesting(
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running.",
            logEntries: [
                .init(kind: .agentMessage, groupID: "msg_1", text: "Hello"),
                .init(kind: .progress, text: "Still working"),
                .init(kind: .agentMessage, groupID: "msg_1", text: " world"),
            ]
        )

        #expect(job.logText == """
        Hello world

        Still working
        """)
    }

    @Test func logTextReplacesGroupedEntryWhenCompletionRewritesText() {
        let job = CodexReviewJob.makeForTesting(
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running.",
            logEntries: [
                .init(kind: .plan, groupID: "plan_1", text: "- step"),
                .init(kind: .event, text: "Turn started"),
                .init(kind: .plan, groupID: "plan_1", replacesGroup: true, text: "- corrected step"),
            ]
        )

        #expect(job.logText == """
        - corrected step

        Turn started
        """)
    }

    @Test func tailGroupedAppendEmitsIncrementalMonitorUpdate() {
        let job = CodexReviewJob.makeForTesting(
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running.",
            logEntries: [
                .init(kind: .agentMessage, groupID: "msg_1", text: "Hello")
            ]
        )

        job.appendLogEntry(.init(kind: .agentMessage, groupID: "msg_1", text: " world"))

        #expect(job.reviewMonitorLogText == "Hello world")
        #expect(job.reviewMonitorRevision == 1)
        #expect(job.lastMonitorUpdate == .append(" world"))
    }

    @Test func groupedReplacementFallsBackToReloadMonitorUpdate() {
        let job = CodexReviewJob.makeForTesting(
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running.",
            logEntries: [
                .init(kind: .plan, groupID: "plan_1", text: "- step")
            ]
        )

        job.appendLogEntry(.init(kind: .plan, groupID: "plan_1", replacesGroup: true, text: "- corrected"))

        #expect(job.reviewMonitorLogText == "- corrected")
        #expect(job.reviewMonitorRevision == 1)
        #expect(job.lastMonitorUpdate == .reload("- corrected"))
    }

    @Test func commandOutputUpdatesDoNotAdvanceReviewMonitorRevision() {
        let job = CodexReviewJob.makeForTesting(
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running.",
            logEntries: [
                .init(kind: .command, text: "$ git status")
            ]
        )

        job.appendLogEntry(.init(kind: .commandOutput, groupID: "cmd_1", text: "M file.swift"))

        #expect(job.reviewMonitorLogText == "$ git status")
        #expect(job.reviewMonitorRevision == 0)
    }
}
