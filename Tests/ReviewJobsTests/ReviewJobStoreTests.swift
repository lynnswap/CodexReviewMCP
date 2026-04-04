import Foundation
import Testing
import ReviewTestSupport
@testable import CodexReviewMCP
@testable import CodexReviewModel
@testable import ReviewCore
@testable import ReviewJobs

@Suite(.serialized)
@MainActor
struct ReviewJobStoreTests {
    @Test func codexReviewStoreStartReviewReturnsTerminalResult() async throws {
        let manager = MockAppServerManager { _ in .success(finalReview: "Review ok") }
        let store = CodexReviewStore(
            configuration: .init(
                port: 0,
                environment: try isolatedHomeEnvironment()
            ),
            appServerManager: manager
        )

        await store.start()
        defer { Task { await store.stop() } }

        let result = try await store.startReview(
            sessionID: "session-1",
            request: .init(
                cwd: FileManager.default.temporaryDirectory.path,
                target: .uncommittedChanges
            )
        )

        #expect(result.status == .succeeded)
        #expect(result.review == "Review ok")
        #expect(await manager.prepareCount() == 1)
    }

    @Test func codexReviewStoreReusesSessionTransportAcrossSequentialReviews() async throws {
        let manager = MockAppServerManager { _ in .success(finalReview: "Review ok") }
        let store = CodexReviewStore(
            configuration: .init(
                port: 0,
                environment: try isolatedHomeEnvironment()
            ),
            appServerManager: manager
        )

        await store.start()
        defer { Task { await store.stop() } }

        let firstResult = try await store.startReview(
            sessionID: "session-reuse",
            request: .init(
                cwd: FileManager.default.temporaryDirectory.path,
                target: .uncommittedChanges
            )
        )
        let transport = await manager.waitForTransport(sessionID: "session-reuse")
        let secondResult = try await store.startReview(
            sessionID: "session-reuse",
            request: .init(
                cwd: FileManager.default.temporaryDirectory.path,
                target: .uncommittedChanges
            )
        )

        #expect(firstResult.status == .succeeded)
        #expect(secondResult.status == .succeeded)
        #expect(await manager.transportCreationCount(for: "session-reuse") == 1)
        #expect(await transport.isClosed() == false)
    }

    @Test func codexReviewStoreCancelsRunningJobBySelector() async throws {
        let manager = MockAppServerManager { _ in .longRunning() }
        let store = CodexReviewStore(
            configuration: .init(
                port: 0,
                environment: try isolatedHomeEnvironment()
            ),
            appServerManager: manager
        )

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
            selector: .init(reviewThreadID: nil, cwd: nil, statuses: [.running], latest: true),
            sessionID: "session-cancel"
        )
        let result = try await reviewTask.value

        #expect(outcome.cancelled)
        #expect(result.status == .cancelled)
        #expect(await transport.isClosed())
    }

    @Test func codexReviewStoreCloseSessionCancelsActiveReviews() async throws {
        let manager = MockAppServerManager { _ in .longRunning() }
        let store = CodexReviewStore(
            configuration: .init(
                port: 0,
                environment: try isolatedHomeEnvironment()
            ),
            appServerManager: manager
        )

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

        #expect(result.status == .cancelled)
        #expect(result.terminalError?.message == "session closed")
    }

    @Test func codexReviewStoreFailsToStartWhenReviewStartFails() async throws {
        let manager = MockAppServerManager { _ in .reviewStartFailure() }
        let store = CodexReviewStore(
            configuration: .init(
                port: 0,
                environment: try isolatedHomeEnvironment()
            ),
            appServerManager: manager
        )

        await store.start()
        defer { Task { await store.stop() } }

        let result = try await store.startReview(
            sessionID: "session-fail",
            request: .init(
                cwd: FileManager.default.temporaryDirectory.path,
                target: .uncommittedChanges
            )
        )

        #expect(result.status == .failed)
        #expect(result.terminalError?.message.contains("Failed to start review") == true)
    }

    @Test func codexReviewStoreClosesSessionLaneAfterBootstrapFailure() async throws {
        let manager = MockAppServerManager { _ in .configReadFailure() }
        let store = CodexReviewStore(
            configuration: .init(
                port: 0,
                environment: try isolatedHomeEnvironment()
            ),
            appServerManager: manager
        )

        await store.start()
        defer { Task { await store.stop() } }

        let result = try await store.startReview(
            sessionID: "session-bootstrap-fail",
            request: .init(
                cwd: FileManager.default.temporaryDirectory.path,
                target: .uncommittedChanges
            )
        )

        #expect(result.status == .failed)
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
