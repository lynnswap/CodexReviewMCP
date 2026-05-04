import Foundation
import Testing
import ReviewTestSupport
@testable import ReviewAppServerAdapter
@testable import ReviewPlatform
@testable import ReviewMCPAdapter
@_spi(Testing) @testable import ReviewApplication
@testable import ReviewDomain

@Suite(.serialized)
@MainActor
struct ReviewJobStoreTests {
    @Test func codexReviewStoreStartReviewReturnsTerminalResult() async throws {
        let manager = MockAppServerManager { _ in .success(finalReview: "Review ok") }
        let store = try makeTestStore(manager: manager)

        await store.start()
        defer { Task { await store.stop() } }

        let result = try await store.startReview(
            sessionID: "session-1",
            request: .init(
                cwd: FileManager.default.temporaryDirectory.path,
                target: .uncommittedChanges
            )
        )

        #expect(result.core.lifecycle.status == .succeeded)
        #expect(result.core.reviewText == "Review ok")
        #expect(await manager.prepareCount() == 1)
    }

    @Test func completedReviewRemainsAfterSessionCloses() async throws {
        let manager = MockAppServerManager { _ in .success(finalReview: "Review ok") }
        let store = try makeTestStore(manager: manager)

        await store.start()
        defer { Task { await store.stop() } }

        let result = try await store.startReview(
            sessionID: "session-completed",
            request: .init(
                cwd: FileManager.default.temporaryDirectory.path,
                target: .uncommittedChanges
            )
        )

        await store.closeSession("session-completed", reason: "MCP session closed.")

        let listed = store.listReviews(statuses: [.succeeded])
        let reread = try store.readReview(jobID: result.jobID)
        #expect(store.workspaces.flatMap(\.jobs).map(\.id) == [result.jobID])
        #expect(listed.items.map(\.jobID) == [result.jobID])
        #expect(reread.core.lifecycle.status == .succeeded)
        #expect(reread.core.reviewText == "Review ok")
    }

    @Test func codexReviewStoreStoresParsedReviewResult() async throws {
        let dash = "\u{2014}"
        let cwd = FileManager.default.temporaryDirectory.path
        let finalReview = """
        The changes introduce one issue.

        Review comment:

        - [P1] Preserve structured finding state \(dash) \(cwd)/Sources/Store.swift:20-20
          The store currently returns only the rendered review text to MCP clients.
        """
        let manager = MockAppServerManager { _ in .success(finalReview: finalReview) }
        let store = try makeTestStore(manager: manager)

        await store.start()
        defer { Task { await store.stop() } }

        let result = try await store.startReview(
            sessionID: "session-structured",
            request: .init(
                cwd: cwd,
                target: .uncommittedChanges
            )
        )

        let returnedResult = try #require(result.core.output.reviewResult)
        let storedResult = try #require(store.workspaces.first?.jobs.first?.core.output.reviewResult)
        #expect(returnedResult == storedResult)
        #expect(storedResult.state == .hasFindings)
        #expect(storedResult.findings.first?.title == "[P1] Preserve structured finding state")
        #expect(storedResult.findings.first?.body == "The store currently returns only the rendered review text to MCP clients.")
    }

    @Test func codexReviewStoreChecksOutFreshTransportForSequentialReviews() async throws {
        let manager = MockAppServerManager { _ in .success(finalReview: "Review ok") }
        let store = try makeTestStore(manager: manager)

        await store.start()
        defer { Task { await store.stop() } }

        let firstReview = Task {
            try await store.startReview(
                sessionID: "session-reuse",
                request: .init(
                    cwd: FileManager.default.temporaryDirectory.path,
                    target: .uncommittedChanges
                )
            )
        }
        let firstTransport = await manager.waitForTransport(sessionID: "session-reuse", at: 0)
        let firstResult = try await firstReview.value

        let secondReview = Task {
            try await store.startReview(
                sessionID: "session-reuse",
                request: .init(
                    cwd: FileManager.default.temporaryDirectory.path,
                    target: .uncommittedChanges
                )
            )
        }
        let secondTransport = await manager.waitForTransport(sessionID: "session-reuse", at: 1)
        let secondResult = try await secondReview.value

        #expect(firstResult.core.lifecycle.status == .succeeded)
        #expect(secondResult.core.lifecycle.status == .succeeded)
        #expect(await manager.transportCreationCount(for: "session-reuse") == 2)
        #expect(await firstTransport.isClosed())
        #expect(await secondTransport.isClosed())
    }

    @Test func codexReviewStoreAllowsConcurrentReviewsWithinSameSession() async throws {
        let manager = MockAppServerManager { _ in
            let id = UUID().uuidString
            return .longRunning(
                reviewThreadID: "thr-review-\(id)",
                threadID: "thr-thread-\(id)",
                turnID: "turn-review-\(id)"
            )
        }
        let store = try makeTestStore(manager: manager)

        await store.start()
        defer { Task { await store.stop() } }

        let firstReview = Task {
            try await store.startReview(
                sessionID: "session-concurrent",
                request: .init(
                    cwd: FileManager.default.temporaryDirectory.path,
                    target: .uncommittedChanges
                )
            )
        }
        let secondReview = Task {
            try await store.startReview(
                sessionID: "session-concurrent",
                request: .init(
                    cwd: FileManager.default.temporaryDirectory.path,
                    target: .uncommittedChanges
                )
            )
        }

        let firstTransport = await manager.waitForTransport(sessionID: "session-concurrent", at: 0)
        let secondTransport = await manager.waitForTransport(sessionID: "session-concurrent", at: 1)
        await firstTransport.waitForRequest("review/start")
        await secondTransport.waitForRequest("review/start")

        await store.closeSession("session-concurrent", reason: "session closed")
        let firstResult = try await firstReview.value
        let secondResult = try await secondReview.value

        #expect(firstResult.core.lifecycle.status == .cancelled)
        #expect(secondResult.core.lifecycle.status == .cancelled)
        #expect(await manager.transportCreationCount(for: "session-concurrent") == 2)
    }

    @Test func codexReviewStoreCancelsRunningJobBySelector() async throws {
        let manager = MockAppServerManager { _ in .longRunning() }
        let store = try makeTestStore(manager: manager)

        await store.start()
        defer { Task { await store.stop() } }

        let reviewTask = Task {
            try await store.startReview(
                sessionID: "session-cancel",
                request: .init(
                    cwd: FileManager.default.temporaryDirectory.path,
                    target: .uncommittedChanges
                )
            )
        }

        let transport = await manager.waitForTransport(sessionID: "session-cancel")
        await transport.waitForRequest("review/start")
        let outcome = try await store.cancelReview(
            selector: .init(cwd: nil, statuses: [.running]),
            sessionID: "session-cancel"
        )
        let result = try await reviewTask.value

        #expect(outcome.cancelled)
        #expect(result.core.lifecycle.status == .cancelled)
        #expect(await transport.isClosed())
    }

    @Test func cancelCanTargetReviewFromAnotherSession() async throws {
        let manager = MockAppServerManager { _ in .longRunning() }
        let store = try makeTestStore(manager: manager)

        await store.start()
        defer { Task { await store.stop() } }

        let reviewTask = Task {
            try await store.startReview(
                sessionID: "session-owner",
                request: .init(
                    cwd: FileManager.default.temporaryDirectory.path,
                    target: .uncommittedChanges
                )
            )
        }

        let transport = await manager.waitForTransport(sessionID: "session-owner")
        await transport.waitForRequest("review/start")
        let jobID = try #require(store.workspaces.first?.jobs.first?.id)
        let outcome = try await store.cancelReview(
            selectedJobID: jobID,
            sessionID: "session-other",
            cancellation: .mcpClient()
        )
        let result = try await reviewTask.value

        #expect(outcome.cancelled)
        #expect(result.core.lifecycle.status == .cancelled)
        #expect(result.core.lifecycle.cancellation?.source == .mcpClient)
        #expect(await transport.isClosed())
    }

    @Test func runningCancellationKeepsPendingMessageUntilTerminalOutcome() throws {
        let store = CodexReviewStore.makePreviewStore()
        let job = CodexReviewJob.makeForTesting(
            id: "job-running-pending-cancel",
            sessionID: "session-pending-cancel",
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running."
        )
        store.workspaces = [
            CodexReviewWorkspace(
                cwd: "/tmp/repo",
                jobs: [job]
            )
        ]

        let outcome = try store.requestCancellation(
            jobID: job.id,
            sessionID: "session-pending-cancel",
            cancellation: .userInterface()
        )
        let pendingResult = try store.readReview(
            jobID: job.id,
            sessionID: "session-pending-cancel"
        )
        let pendingListItem = try #require(store.listReviews().items.first)

        #expect(outcome.state == .running)
        #expect(outcome.signalled)
        #expect(job.core.lifecycle.status == .running)
        #expect(job.cancellationRequested)
        #expect(job.core.lifecycle.cancellation?.source == .userInterface)
        #expect(job.core.lifecycle.cancellation?.message == "Cancelled by user from Review Monitor.")
        #expect(pendingResult.core.lifecycle.status == .running)
        #expect(pendingResult.core.lifecycle.cancellation?.source == .userInterface)
        #expect(pendingResult.core.reviewText == "Cancellation requested.")
        #expect(pendingResult.core.lifecycle.errorMessage == "Cancellation requested.")
        #expect(pendingListItem.core.lifecycle.status == .running)
        #expect(pendingListItem.core.output.summary == "Cancellation requested.")
        #expect(pendingListItem.core.lifecycle.cancellation?.source == .userInterface)
    }

    @Test func repeatedCancellationKeepsOriginalCancellationMetadata() async throws {
        let manager = MockAppServerManager { _ in .interruptIgnoredLongRunning() }
        let store = try makeTestStore(manager: manager)

        await store.start()
        defer { Task { await store.stop() } }

        let reviewTask = Task {
            try await store.startReview(
                sessionID: "session-repeat-cancel",
                request: .init(
                    cwd: FileManager.default.temporaryDirectory.path,
                    target: .uncommittedChanges
                )
            )
        }

        let transport = await manager.waitForTransport(sessionID: "session-repeat-cancel")
        await transport.waitForRequest("review/start")
        let firstOutcome = try await store.cancelReview(
            selector: .init(cwd: nil, statuses: [.running]),
            sessionID: "session-repeat-cancel",
            cancellation: .userInterface()
        )
        let secondOutcome = try await store.cancelReview(
            selector: .init(cwd: nil, statuses: [.running, .cancelled]),
            sessionID: "session-repeat-cancel",
            cancellation: .mcpClient()
        )
        await store.closeSession("session-repeat-cancel", reason: "MCP session closed.")
        let result = try await reviewTask.value

        #expect(firstOutcome.core.lifecycle.cancellation?.source == .userInterface)
        #expect(secondOutcome.core.lifecycle.cancellation?.source == .userInterface)
        #expect(result.core.lifecycle.status == .cancelled)
        #expect(result.core.lifecycle.cancellation?.source == .userInterface)
        #expect(result.core.lifecycle.errorMessage == "Cancelled by user from Review Monitor.")
        #expect(result.core.reviewText == "Cancelled by user from Review Monitor.")
    }

    @Test func cancellingAlreadyCancelledJobWithoutMetadataDoesNotInventCancellation() async throws {
        let manager = MockAppServerManager { _ in .longRunning() }
        let store = try makeTestStore(manager: manager)
        let job = CodexReviewJob.makeForTesting(
            id: "job-legacy-cancelled",
            sessionID: "session-legacy-cancelled",
            targetSummary: "target-legacy-cancelled",
            status: .cancelled,
            summary: "Cancelled.",
            errorMessage: "Cancelled."
        )
        store.workspaces = [
            CodexReviewWorkspace(
                cwd: "/tmp/repo",
                jobs: [job]
            )
        ]

        let outcome = try await store.cancelReview(
            selectedJobID: job.id,
            sessionID: "session-legacy-cancelled",
            cancellation: .mcpClient()
        )
        let result = try store.readReview(
            jobID: job.id,
            sessionID: "session-legacy-cancelled"
        )

        #expect(outcome.cancelled)
        #expect(outcome.core.lifecycle.cancellation == nil)
        #expect(result.core.lifecycle.status == .cancelled)
        #expect(result.core.lifecycle.cancellation == nil)
        #expect(job.core.lifecycle.cancellation == nil)
    }

    @Test func codexReviewStoreCloseSessionCancelsActiveReviews() async throws {
        let manager = MockAppServerManager { _ in .longRunning() }
        let store = try makeTestStore(manager: manager)

        await store.start()
        defer { Task { await store.stop() } }

        let reviewTask = Task {
            try await store.startReview(
                sessionID: "session-close",
                request: .init(
                    cwd: FileManager.default.temporaryDirectory.path,
                    target: .uncommittedChanges
                )
            )
        }

        let transport = await manager.waitForTransport(sessionID: "session-close")
        await transport.waitForRequest("review/start")
        await store.closeSession("session-close", reason: "session closed")
        let result = try await reviewTask.value

        #expect(result.core.lifecycle.status == .cancelled)
        #expect(result.core.lifecycle.errorMessage == "session closed")
        #expect(store.workspaces.flatMap(\.jobs).map(\.id) == [result.jobID])
        #expect(store.listReviews(statuses: [.cancelled]).items.map(\.jobID) == [result.jobID])
    }

    @Test func terminalReviewsRemainAcrossStopAndRestart() async throws {
        let manager = MockAppServerManager { _ in .success(finalReview: "Review ok") }
        let store = try makeTestStore(manager: manager)

        await store.start()
        let result = try await store.startReview(
            sessionID: "session-retained",
            request: .init(
                cwd: FileManager.default.temporaryDirectory.path,
                target: .uncommittedChanges
            )
        )

        await store.stop()
        #expect(store.workspaces.flatMap(\.jobs).map(\.id) == [result.jobID])

        await store.start()
        defer { Task { await store.stop() } }

        #expect(store.workspaces.flatMap(\.jobs).map(\.id) == [result.jobID])
        #expect(store.listReviews(statuses: [.succeeded]).items.map(\.jobID) == [result.jobID])
    }

    @Test func codexReviewStoreFailsToStartWhenReviewStartFails() async throws {
        let manager = MockAppServerManager { _ in .reviewStartFailure() }
        let store = try makeTestStore(manager: manager)

        await store.start()
        defer { Task { await store.stop() } }

        let result = try await store.startReview(
            sessionID: "session-fail",
            request: .init(
                cwd: FileManager.default.temporaryDirectory.path,
                target: .uncommittedChanges
            )
        )

        #expect(result.core.lifecycle.status == .failed)
        #expect(result.core.lifecycle.errorMessage?.contains("Failed to start review") == true)
    }

    @Test func codexReviewStoreClosesTransportAfterBootstrapFailure() async throws {
        let manager = MockAppServerManager { _ in .configReadFailure() }
        let store = try makeTestStore(manager: manager)

        await store.start()
        defer { Task { await store.stop() } }

        let result = try await store.startReview(
            sessionID: "session-bootstrap-fail",
            request: .init(
                cwd: FileManager.default.temporaryDirectory.path,
                target: .uncommittedChanges
            )
        )

        #expect(result.core.lifecycle.status == .failed)
        let transport = try #require(await manager.transport(for: "session-bootstrap-fail"))
        #expect(await transport.isClosed())
    }
}

private func isolatedHomeEnvironment(extra: [String: String] = [:]) throws -> [String: String] {
    var environment = ["HOME": try makeTemporaryDirectory().path]
    for (key, value) in extra {
        environment[key] = value
    }
    return environment
}

@MainActor
private func makeTestStore(manager: any AppServerManaging) throws -> CodexReviewStore {
    CodexReviewStore(
        configuration: .init(
            port: 0,
            environment: try isolatedHomeEnvironment()
        ),
        appServerManager: manager,
        authSessionFactory: makeStubReviewAuthSessionFactory()
    )
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private struct TestFailure: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}
