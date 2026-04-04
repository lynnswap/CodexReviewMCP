import Foundation
import Testing
@_spi(Testing) @testable import CodexReviewMCP
@_spi(Testing) @testable import CodexReviewModel
@testable import ReviewCore
@testable import ReviewJobs
@testable import ReviewRuntime

@Suite
@MainActor
struct CodexReviewStoreRuntimeLogTrimmingTests {
    @Test func storeCountsDiagnosticSeparatorsTowardLimit() throws {
        let store = CodexReviewStore(configuration: .init())
        let job = CodexReviewJob.makeForTesting(
            id: "job-1",
            cwd: "/tmp/repo",
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running."
        )
        store.loadForTesting(
            serverState: .running,
            workspaces: [
                CodexReviewWorkspace(cwd: "/tmp/repo", sortOrder: 1, jobs: [job]),
            ]
        )

        let halfLimit = reviewLogLimitBytes / 2
        store.handle(jobID: job.id, event: .rawLine(String(repeating: "a", count: halfLimit)))
        store.handle(jobID: job.id, event: .rawLine(String(repeating: "b", count: halfLimit)))

        let updatedJob = try #require(findJob(id: job.id, in: store))
        #expect(updatedJob.rawLogText == String(repeating: "b", count: halfLimit))
    }

    @Test func storeTruncatesOversizedRawReasoningWhenItIsTheOnlyCappedEntry() throws {
        let store = CodexReviewStore(configuration: .init())
        let job = CodexReviewJob.makeForTesting(
            id: "job-2",
            cwd: "/tmp/repo",
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running."
        )
        store.loadForTesting(
            serverState: .running,
            workspaces: [
                CodexReviewWorkspace(cwd: "/tmp/repo", sortOrder: 1, jobs: [job]),
            ]
        )

        store.handle(
            jobID: job.id,
            event: .logEntry(.init(
                kind: .rawReasoning,
                text: String(repeating: "r", count: reviewLogLimitBytes + 1)
            ))
        )

        let updatedJob = try #require(findJob(id: job.id, in: store))
        #expect(updatedJob.logEntries.contains { $0.kind == .rawReasoning } == true)
        #expect(updatedJob.reviewOutputText.utf8.count <= reviewLogLimitBytes)
        #expect(updatedJob.diagnosticText.isEmpty)
    }

    @Test func diagnosticTextExcludesUnderLimitRawReasoningEntries() throws {
        let store = CodexReviewStore(configuration: .init())
        let job = CodexReviewJob.makeForTesting(
            id: "job-2a",
            cwd: "/tmp/repo",
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running."
        )
        store.loadForTesting(
            serverState: .running,
            workspaces: [
                CodexReviewWorkspace(cwd: "/tmp/repo", sortOrder: 1, jobs: [job]),
            ]
        )

        store.handle(
            jobID: job.id,
            event: .logEntry(.init(
                kind: .rawReasoning,
                text: "thinking out loud"
            ))
        )

        let updatedJob = try #require(findJob(id: job.id, in: store))
        #expect(updatedJob.logEntries.contains { $0.kind == .rawReasoning && $0.text == "thinking out loud" })
        #expect(updatedJob.diagnosticText.isEmpty)
    }

    @Test func storeKeepsErrorEntriesWhenTrimmingDiagnostics() throws {
        let store = CodexReviewStore(configuration: .init())
        let job = CodexReviewJob.makeForTesting(
            id: "job-3",
            cwd: "/tmp/repo",
            targetSummary: "Uncommitted changes",
            status: .failed,
            summary: "Failed.",
            logEntries: [
                .init(kind: .error, text: "bootstrap failed"),
            ]
        )
        store.loadForTesting(
            serverState: .running,
            workspaces: [
                CodexReviewWorkspace(cwd: "/tmp/repo", sortOrder: 1, jobs: [job]),
            ]
        )

        store.handle(
            jobID: job.id,
            event: .logEntry(.init(
                kind: .rawReasoning,
                text: String(repeating: "r", count: reviewLogLimitBytes + 1)
            ))
        )

        let updatedJob = try #require(findJob(id: job.id, in: store))
        #expect(updatedJob.logEntries.contains { $0.kind == .error && $0.text == "bootstrap failed" })
        #expect(updatedJob.logEntries.contains { $0.kind == .rawReasoning } == true)
        #expect(updatedJob.logText.utf8.count <= reviewLogLimitBytes)
    }

    @Test func storeDropsDiagnosticsBeforeTruncatingRawReasoning() throws {
        let store = CodexReviewStore(configuration: .init())
        let job = CodexReviewJob.makeForTesting(
            id: "job-3a",
            cwd: "/tmp/repo",
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running."
        )
        store.loadForTesting(
            serverState: .running,
            workspaces: [
                CodexReviewWorkspace(cwd: "/tmp/repo", sortOrder: 1, jobs: [job]),
            ]
        )

        let halfLimit = reviewLogLimitBytes / 2
        store.handle(jobID: job.id, event: .rawLine(String(repeating: "d", count: halfLimit)))
        store.handle(
            jobID: job.id,
            event: .logEntry(.init(
                kind: .rawReasoning,
                text: String(repeating: "r", count: halfLimit)
            ))
        )

        let updatedJob = try #require(findJob(id: job.id, in: store))
        let rawReasoning = try #require(updatedJob.logEntries.first(where: { $0.kind == .rawReasoning }))
        #expect(updatedJob.logEntries.contains { $0.kind == .diagnostic } == false)
        #expect(rawReasoning.text == String(repeating: "r", count: halfLimit))
    }

    @Test func storeTruncatesOversizedErrorEntriesToRespectDiagnosticCap() throws {
        let store = CodexReviewStore(configuration: .init())
        let oversizedError = String(repeating: "a", count: reviewLogLimitBytes) + " FINAL CAUSE"
        let job = CodexReviewJob.makeForTesting(
            id: "job-4",
            cwd: "/tmp/repo",
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running."
        )
        store.loadForTesting(
            serverState: .running,
            workspaces: [
                CodexReviewWorkspace(cwd: "/tmp/repo", sortOrder: 1, jobs: [job]),
            ]
        )

        store.handle(jobID: job.id, event: .logEntry(.init(kind: .error, text: oversizedError)))

        let updatedJob = try #require(findJob(id: job.id, in: store))
        #expect(updatedJob.diagnosticText.utf8.count <= reviewLogLimitBytes)
        #expect(updatedJob.logEntries.contains { $0.kind == .error } == true)
        #expect(updatedJob.logEntries.contains { $0.kind == .error && $0.text.hasSuffix("FINAL CAUSE") })
    }

    @Test func failToStartAlsoTrimsOversizedErrorEntries() throws {
        let store = CodexReviewStore(configuration: .init())
        let jobID = try store.enqueueReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/repo", target: .uncommittedChanges)
        )
        let oversizedError = String(repeating: "b", count: reviewLogLimitBytes) + " BOOTSTRAP TAIL"
        store.failToStart(
            jobID: jobID,
            message: oversizedError,
            startedAt: Date(timeIntervalSince1970: 1),
            endedAt: Date(timeIntervalSince1970: 2)
        )

        let updatedJob = try #require(findJob(id: jobID, in: store))
        #expect(updatedJob.diagnosticText.utf8.count <= reviewLogLimitBytes)
        #expect(updatedJob.logEntries.contains { $0.kind == .error } == true)
        #expect(updatedJob.logEntries.contains { $0.kind == .error && $0.text.hasSuffix("BOOTSTRAP TAIL") })
    }

    @Test func storeTrimsOversizedReasoningSummaryEntries() throws {
        let store = CodexReviewStore(configuration: .init())
        let job = CodexReviewJob.makeForTesting(
            id: "job-5",
            cwd: "/tmp/repo",
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running."
        )
        store.loadForTesting(
            serverState: .running,
            workspaces: [
                CodexReviewWorkspace(cwd: "/tmp/repo", sortOrder: 1, jobs: [job]),
            ]
        )

        store.handle(
            jobID: job.id,
            event: .logEntry(.init(
                kind: .reasoningSummary,
                groupID: "rsn_1:summary:0",
                text: String(repeating: "s", count: reviewLogLimitBytes + 1)
            ))
        )

        let updatedJob = try #require(findJob(id: job.id, in: store))
        #expect(updatedJob.logText.utf8.count <= reviewLogLimitBytes)
    }

    @Test func storeTrimsOversizedToolCallEntries() throws {
        let store = CodexReviewStore(configuration: .init())
        let job = CodexReviewJob.makeForTesting(
            id: "job-6",
            cwd: "/tmp/repo",
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running."
        )
        store.loadForTesting(
            serverState: .running,
            workspaces: [
                CodexReviewWorkspace(cwd: "/tmp/repo", sortOrder: 1, jobs: [job]),
            ]
        )

        store.handle(
            jobID: job.id,
            event: .logEntry(.init(
                kind: .toolCall,
                text: String(repeating: "t", count: reviewLogLimitBytes + 1)
            ))
        )

        let updatedJob = try #require(findJob(id: job.id, in: store))
        #expect(updatedJob.logText.utf8.count <= reviewLogLimitBytes)
        #expect(updatedJob.logEntries.contains { $0.kind == .toolCall && $0.text.isEmpty == false })
    }

    @Test func storeTruncatesOversizedAgentMessagesInsteadOfDroppingThem() throws {
        let store = CodexReviewStore(configuration: .init())
        let job = CodexReviewJob.makeForTesting(
            id: "job-7",
            cwd: "/tmp/repo",
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running."
        )
        store.loadForTesting(
            serverState: .running,
            workspaces: [
                CodexReviewWorkspace(cwd: "/tmp/repo", sortOrder: 1, jobs: [job]),
            ]
        )

        let text = String(repeating: "m", count: reviewLogLimitBytes + 32)
        store.handle(
            jobID: job.id,
            event: .logEntry(.init(
                kind: .agentMessage,
                groupID: "msg_1",
                text: text
            ))
        )

        let updatedJob = try #require(findJob(id: job.id, in: store))
        #expect(updatedJob.logText.utf8.count <= reviewLogLimitBytes)
        #expect(updatedJob.logEntries.contains { $0.kind == .agentMessage && $0.text.isEmpty == false })
    }
}

@MainActor
private func findJob(id: String, in store: CodexReviewStore) -> CodexReviewJob? {
    store.workspaces
        .flatMap(\.jobs)
        .first { $0.id == id }
}
