import Foundation
import MCP
import Testing
@_spi(Testing) @testable import CodexReviewMCP
@testable import ReviewCore
@testable import ReviewJobs

@Suite(.serialized)
struct ReviewRuntimeTests {
    @MainActor
    @Test func codexReviewStoreListReviewsFiltersAndSortsBySession() throws {
        let store = CodexReviewStore(configuration: .init())
        let runningID = try store.enqueueReview(
            sessionID: "session-a",
            request: .init(cwd: "/tmp/running", target: .uncommittedChanges),
            initialModel: "gpt-5.4-mini"
        )
        store.markStarted(
            jobID: runningID,
            startedAt: Date(timeIntervalSince1970: 200)
        )
        store.handle(
            jobID: runningID,
            event: .reviewStarted(
                reviewThreadID: "thr-running",
                threadID: "thr-running",
                turnID: "turn-running",
                model: "gpt-5.4-mini"
            )
        )

        let recentID = try store.enqueueReview(
            sessionID: "session-a",
            request: .init(cwd: "/tmp/recent", target: .uncommittedChanges)
        )
        store.failToStart(
            jobID: recentID,
            message: "boom",
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 101)
        )

        _ = try store.enqueueReview(
            sessionID: "session-b",
            request: .init(cwd: "/tmp/foreign", target: .uncommittedChanges)
        )

        let listed = store.listReviews(sessionID: "session-a")
        #expect(listed.items.map(\.reviewThreadID) == ["thr-running", recentID])
        #expect(listed.items.first?.model == "gpt-5.4-mini")

        let filtered = store.listReviews(
            sessionID: "session-a",
            cwd: "/tmp/running",
            statuses: [ReviewJobState.running],
            limit: 10
        )
        #expect(filtered.items.map(\.reviewThreadID) == ["thr-running"])
    }

    @MainActor
    @Test func codexReviewStoreListReviewsStructuredContentAlwaysIncludesModelField() throws {
        let store = CodexReviewStore(configuration: .init())
        let queuedID = try store.enqueueReview(
            sessionID: "session-shape",
            request: .init(cwd: "/tmp/queued-shape", target: .uncommittedChanges),
            initialModel: "gpt-5.4-mini"
        )
        let failedID = try store.enqueueReview(
            sessionID: "session-shape",
            request: .init(cwd: "/tmp/failed-shape", target: .uncommittedChanges)
        )
        store.failToStart(
            jobID: failedID,
            message: "boom",
            startedAt: Date(timeIntervalSince1970: 10),
            endedAt: Date(timeIntervalSince1970: 11)
        )

        let structuredContent = store.listReviews(sessionID: "session-shape").structuredContent()
        guard case .object(let root) = structuredContent,
              case .some(.array(let items)) = root["items"]
        else {
            Issue.record("expected object/array structured content")
            return
        }

        let listedItems = items.compactMap { value -> [String: Value]? in
            guard case .object(let item) = value else {
                return nil
            }
            return item
        }

        let queuedItem = try #require(listedItems.first(where: { item in
            if case .some(.string(let reviewThreadID)) = item["reviewThreadId"] {
                return reviewThreadID == queuedID
            }
            return false
        }))
        let failedItem = try #require(listedItems.first(where: { item in
            if case .some(.string(let reviewThreadID)) = item["reviewThreadId"] {
                return reviewThreadID == failedID
            }
            return false
        }))

        #expect(queuedItem["model"] == .some(.string("gpt-5.4-mini")))
        #expect(failedItem["model"] == .some(.null))
    }

    @MainActor
    @Test func codexReviewStoreStartReviewReturnsTerminalResult() async throws {
        let scriptURL = try makeFakeAppServerScript(mode: .success)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let store = CodexReviewStore(
            configuration: .init(
                codexCommand: scriptURL.path,
                environment: try isolatedHomeEnvironment()
            )
        )

        let result = try await store.startReview(
            sessionID: "session-success",
            request: .init(
                cwd: FileManager.default.temporaryDirectory.path,
                target: .uncommittedChanges
            )
        )

        #expect(result.status == ReviewJobState.succeeded)
        #expect(result.review == "Review ok")
        #expect(result.reviewThreadID == "thr-store")
        #expect(result.model == "gpt-5.4-mini")
        #expect(store.workspaces.count == 1)
        #expect(store.workspaces.first?.jobs.count == 1)
        #expect(store.workspaces.first?.jobs.first?.reviewThreadID == "thr-store")
        #expect(store.workspaces.first?.jobs.first?.status == .succeeded)
        #expect(store.workspaces.first?.jobs.first?.model == "gpt-5.4-mini")
    }

    @MainActor
    @Test func codexReviewStorePreservesResolvedModelOnFailedStart() async throws {
        let scriptURL = try makeFakeAppServerScript(mode: .reviewStartFailureAfterThreadStart)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let store = CodexReviewStore(
            configuration: .init(
                codexCommand: scriptURL.path,
                environment: try isolatedHomeEnvironment()
            )
        )

        let result = try await store.startReview(
            sessionID: "session-failed-start-model",
            request: .init(
                cwd: FileManager.default.temporaryDirectory.path,
                target: .uncommittedChanges
            )
        )

        #expect(result.status == .failed)
        #expect(result.model == "gpt-5.4-mini")
        #expect(result.error == "Failed to start review: review start failed")
        #expect(store.workspaces.first?.jobs.first?.model == "gpt-5.4-mini")
    }

    @MainActor
    @Test func codexReviewStoreReturnsCancelledAfterInFlightCancel() async throws {
        let scriptURL = try makeFakeAppServerScript(mode: .longRunning)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let store = CodexReviewStore(
            configuration: .init(
                codexCommand: scriptURL.path,
                environment: try isolatedHomeEnvironment()
            )
        )

        let reviewTask = Task {
            try await store.startReview(
                sessionID: "session-cancel",
                request: .init(
                    cwd: FileManager.default.temporaryDirectory.path,
                    target: .uncommittedChanges
                )
            )
        }

        let reviewThreadID = try await waitUntilReviewThreadID(store: store, sessionID: "session-cancel")

        let cancelOutcome = try await store.cancelReview(
            reviewThreadID: reviewThreadID,
            sessionID: "session-cancel",
            reason: "test cancel"
        )
        let result = try await reviewTask.value

        #expect(cancelOutcome.status == ReviewJobState.cancelled)
        #expect(cancelOutcome.reviewThreadID == reviewThreadID)
        #expect(result.status == ReviewJobState.cancelled)
        #expect(result.error == "test cancel")
    }

    @MainActor
    @Test func codexReviewStoreCancelsRunningJobBySelector() async throws {
        let scriptURL = try makeFakeAppServerScript(mode: .longRunning)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let store = CodexReviewStore(
            configuration: .init(
                codexCommand: scriptURL.path,
                environment: try isolatedHomeEnvironment()
            )
        )

        let reviewTask = Task {
            try await store.startReview(
                sessionID: "session-selector",
                request: .init(
                    cwd: FileManager.default.temporaryDirectory.path,
                    target: .uncommittedChanges
                )
            )
        }

        let reviewThreadID = try await waitUntilReviewThreadID(store: store, sessionID: "session-selector")
        let cancelOutcome = try await store.cancelReview(
            selector: .init(cwd: FileManager.default.temporaryDirectory.path, latest: true),
            sessionID: "session-selector"
        )
        let result = try await reviewTask.value

        #expect(cancelOutcome.reviewThreadID == reviewThreadID)
        #expect(cancelOutcome.status == .cancelled)
        #expect(result.status == .cancelled)
    }

    @MainActor
    @Test func codexReviewStoreCloseSessionCancelsActiveReviews() async throws {
        let scriptURL = try makeFakeAppServerScript(mode: .longRunning)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let store = CodexReviewStore(
            configuration: .init(
                codexCommand: scriptURL.path,
                environment: try isolatedHomeEnvironment()
            )
        )

        let reviewTask = Task {
            try await store.startReview(
                sessionID: "session-close",
                request: .init(
                    cwd: FileManager.default.temporaryDirectory.path,
                    target: .uncommittedChanges
                )
            )
        }

        _ = try await waitUntilReviewThreadID(store: store, sessionID: "session-close")
        await store.closeSession("session-close", reason: "session closed")
        let result = try await reviewTask.value

        #expect(result.status == .cancelled)
        #expect(result.error == "session closed")
    }

    @MainActor
    @Test func codexReviewStoreCanReadCancelledJobWithoutReviewThreadID() throws {
        let store = CodexReviewStore(configuration: .init())
        let jobID = try store.enqueueReview(
            sessionID: "session-pre-close",
            request: .init(
                cwd: FileManager.default.temporaryDirectory.path,
                target: .uncommittedChanges
            )
        )
        #expect(store.workspaces.first?.jobs.first?.model == nil)

        _ = try store.requestCancellation(
            jobID: jobID,
            sessionID: "session-pre-close",
            reason: "closed before spawn"
        )
        let result = try store.readReview(jobID: jobID, sessionID: "session-pre-close")

        #expect(result.status == .cancelled)
        #expect(result.reviewThreadID == jobID)
        #expect(result.error == "closed before spawn")
    }

    @MainActor
    @Test func codexReviewStorePreservesCancelledBootstrapJobs() async throws {
        let store = CodexReviewStore(configuration: .init())
        let jobID = try store.enqueueReview(
            sessionID: "session-bootstrap-cancel",
            request: .init(
                cwd: FileManager.default.temporaryDirectory.path,
                target: .uncommittedChanges
            )
        )
        store.markStarted(
            jobID: jobID,
            startedAt: Date(timeIntervalSince1970: 10)
        )
        store.markBootstrapCancelled(
            jobID: jobID,
            reason: "cancel during bootstrap",
            model: "gpt-5.4-mini",
            startedAt: Date(timeIntervalSince1970: 10),
            endedAt: Date(timeIntervalSince1970: 11)
        )
        let result = try store.readReview(jobID: jobID, sessionID: "session-bootstrap-cancel")

        #expect(result.status == .cancelled)
        #expect(result.reviewThreadID == jobID)
        #expect(result.error == "cancel during bootstrap")
        #expect(result.model == "gpt-5.4-mini")
    }

    @MainActor
    @Test func codexReviewStoreCancelReturnsUnderlyingThreadIDWhenReviewThreadDiffers() async throws {
        let scriptURL = try makeFakeAppServerScript(mode: .detachedLikeLongRunning)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let store = CodexReviewStore(
            configuration: .init(
                codexCommand: scriptURL.path,
                environment: try isolatedHomeEnvironment()
            )
        )

        let reviewTask = Task {
            try await store.startReview(
                sessionID: "session-detached",
                request: .init(
                    cwd: FileManager.default.temporaryDirectory.path,
                    target: .uncommittedChanges
                )
            )
        }

        let reviewThreadID = try await waitUntilReviewThreadID(store: store, sessionID: "session-detached")
        let cancelOutcome = try await store.cancelReview(
            reviewThreadID: reviewThreadID,
            sessionID: "session-detached",
            reason: "test cancel"
        )
        let result = try await reviewTask.value

        #expect(cancelOutcome.reviewThreadID == "thr-store")
        #expect(cancelOutcome.threadID == "thr-parent")
        #expect(result.threadID == "thr-parent")
    }

    @MainActor
    @Test func codexReviewStoreKeepsBootstrapFailuresReadableByFallbackIdentifier() async throws {
        let scriptURL = try makeFakeAppServerScript(mode: .bootstrapFailureBeforeThreadStart)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let store = CodexReviewStore(
            configuration: .init(
                codexCommand: scriptURL.path,
                environment: try isolatedHomeEnvironment()
            )
        )

        let result = try await store.startReview(
            sessionID: "session-bootstrap-failure",
            request: .init(
                cwd: FileManager.default.temporaryDirectory.path,
                target: .uncommittedChanges
            )
        )

        #expect(result.status == .failed)
        let reviewThreadID = try #require(result.reviewThreadID)
        let reread = try store.readReview(reviewThreadID: reviewThreadID, sessionID: "session-bootstrap-failure")
        #expect(reread.status == .failed)
        #expect(reread.reviewThreadID == reviewThreadID)
    }

    @MainActor
    @Test func codexReviewStorePreservesResolvedModelOnConfigBootstrapFailure() async throws {
        let tempHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try writeReviewLocalConfig(
            homeURL: tempHome,
            content: #"review_model = "gpt-5.4-mini""#
        )
        let scriptURL = try makeFakeAppServerScript(mode: .configReadFailure)
        defer {
            try? FileManager.default.removeItem(at: scriptURL)
            try? FileManager.default.removeItem(at: tempHome)
        }

        let store = CodexReviewStore(
            configuration: .init(
                codexCommand: scriptURL.path,
                environment: [
                    "HOME": tempHome.path,
                ]
            )
        )

        let result = try await store.startReview(
            sessionID: "session-config-bootstrap-failure",
            request: .init(
                cwd: FileManager.default.temporaryDirectory.path,
                target: .uncommittedChanges
            )
        )

        #expect(result.status == .failed)
        #expect(result.model == "gpt-5.4-mini")
        #expect(result.error?.contains("Failed to read app-server config") == true)
    }

    @MainActor
    @Test func codexReviewStoreTreatsBootstrapFailureAsCancelledWhenSessionCloses() async throws {
        let scriptURL = try makeFakeAppServerScript(mode: .delayedBootstrapFailureBeforeThreadStart)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let store = CodexReviewStore(
            configuration: .init(
                codexCommand: scriptURL.path,
                environment: try isolatedHomeEnvironment()
            )
        )
        CodexReviewStore.requestCancellationDelayForTesting = 0.2
        defer { CodexReviewStore.requestCancellationDelayForTesting = 0 }

        let reviewTask = Task {
            try await store.startReview(
                sessionID: "session-bootstrap-close",
                request: .init(
                    cwd: FileManager.default.temporaryDirectory.path,
                    target: .uncommittedChanges
                )
            )
        }

        try await waitUntilBootstrapRunning(store: store, sessionID: "session-bootstrap-close")
        await store.closeSession("session-bootstrap-close", reason: "session closed")
        let result = try await reviewTask.value

        #expect(result.status == .cancelled)
        #expect(result.error == "session closed")
        #expect(result.reviewThreadID != nil)
    }
}

private enum FakeStoreAppServerMode: String {
    case success
    case longRunning
    case detachedLikeLongRunning
    case bootstrapFailureBeforeThreadStart
    case delayedBootstrapFailureBeforeThreadStart
    case reviewStartFailureAfterThreadStart
    case configReadFailure
}

private func makeFakeAppServerScript(mode: FakeStoreAppServerMode) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let script = """
    #!/usr/bin/env python3
    import json
    import sys
    import time

    thread_id = "thr-store"
    parent_thread_id = "thr-parent"
    turn_id = "turn-store"
    mode = "\(mode.rawValue)"

    def send(obj):
        sys.stdout.write(json.dumps(obj) + "\\n")
        sys.stdout.flush()

    for raw in sys.stdin:
        if not raw.strip():
            continue
        message = json.loads(raw)
        method = message.get("method")
        if method == "initialize":
            send({"id": message["id"], "result": {"platformFamily": "macOS"}})
        elif method == "initialized":
            continue
        elif method == "config/read":
            if mode == "configReadFailure":
                send({"id": message["id"], "error": {"code": -32001, "message": "config read failed"}})
                continue
            send({"id": message["id"], "result": {"config": {"model": "gpt-5.4-mini"}}})
        elif method == "thread/start":
            if mode == "bootstrapFailureBeforeThreadStart":
                sys.stderr.write("bootstrap failed before thread/start\\n")
                sys.stderr.flush()
                sys.exit(9)
            if mode == "delayedBootstrapFailureBeforeThreadStart":
                time.sleep(0.05)
                sys.stderr.write("bootstrap failed before thread/start\\n")
                sys.stderr.flush()
                sys.exit(9)
            send({
                "id": message["id"],
                "result": {
                    "thread": {"id": parent_thread_id if mode == "detachedLikeLongRunning" else thread_id},
                    "model": "gpt-5.4-mini"
                }
            })
        elif method == "review/start":
            if mode == "reviewStartFailureAfterThreadStart":
                send({"id": message["id"], "error": {"code": -32002, "message": "review start failed"}})
                continue
            send({"id": message["id"], "result": {"turn": {"id": turn_id, "status": "inProgress", "error": None}, "reviewThreadId": thread_id}})
            send({"method": "turn/started", "params": {"threadId": thread_id, "turn": {"id": turn_id, "status": "inProgress", "error": None}}})
            send({"method": "item/started", "params": {"threadId": thread_id, "turnId": turn_id, "item": {"type": "enteredReviewMode", "id": turn_id, "review": "current changes"}}})
            if mode == "longRunning" or mode == "detachedLikeLongRunning":
                continue
            send({"method": "item/completed", "params": {"threadId": thread_id, "turnId": turn_id, "item": {"type": "exitedReviewMode", "id": turn_id, "review": "Review ok"}}})
            send({"method": "turn/completed", "params": {"threadId": thread_id, "turn": {"id": turn_id, "status": "completed", "error": None}}})
            time.sleep(0.5)
            sys.exit(0)
        elif method == "turn/interrupt":
            send({"id": message["id"], "result": {}})
            send({"method": "turn/completed", "params": {"threadId": thread_id, "turn": {"id": turn_id, "status": "interrupted", "error": {"message": "test cancel"}}}})
            time.sleep(0.2)
            sys.exit(0)
    """.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    try script.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

private func writeReviewLocalConfig(homeURL: URL, content: String) throws {
    let configDirectory = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
    try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
    try content.write(
        to: configDirectory.appendingPathComponent("config.toml"),
        atomically: true,
        encoding: .utf8
    )
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func isolatedHomeEnvironment(extra: [String: String] = [:]) throws -> [String: String] {
    var environment = ["HOME": try makeTemporaryDirectory().path]
    for (key, value) in extra {
        environment[key] = value
    }
    return environment
}

@MainActor
private func waitUntilBootstrapRunning(
    store: CodexReviewStore,
    sessionID: String
) async throws {
    let timeout: Duration = .seconds(5)
    let interval: Duration = .milliseconds(20)
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        for workspace in store.workspaces {
            if workspace.jobs.contains(where: {
                $0.sessionID == sessionID && $0.status == .running && $0.reviewThreadID == nil
            }) {
                return
            }
        }
        try await Task.sleep(for: interval)
    }
    throw TestFailure("timed out waiting for bootstrap")
}

@MainActor
private func waitUntilReviewThreadID(
    store: CodexReviewStore,
    sessionID: String
) async throws -> String {
    let timeout: Duration = .seconds(5)
    let interval: Duration = .milliseconds(100)
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        for workspace in store.workspaces {
            if let job = workspace.jobs.first(where: { $0.sessionID == sessionID && $0.status == .running }),
               let reviewThreadID = job.reviewThreadID
            {
                return reviewThreadID
            }
        }
        try await Task.sleep(for: interval)
    }
    throw TestFailure("timed out")
}


private struct TestFailure: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}
