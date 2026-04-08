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

        #expect(result.status == .succeeded)
        #expect(result.review == "Review ok")
        #expect(await manager.prepareCount() == 1)
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

        #expect(firstResult.status == .succeeded)
        #expect(secondResult.status == .succeeded)
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

        #expect(firstResult.status == .cancelled)
        #expect(secondResult.status == .cancelled)
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
        #expect(result.status == .cancelled)
        #expect(await transport.isClosed())
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

        #expect(result.status == .cancelled)
        #expect(result.error == "session closed")
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

        #expect(result.status == .failed)
        #expect(result.error?.contains("Failed to start review") == true)
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
