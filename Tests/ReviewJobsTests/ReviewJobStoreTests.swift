import Foundation
import Testing
@testable import CodexReviewMCP
@testable import ReviewCore
@testable import ReviewJobs

@Suite(.serialized)
@MainActor
struct ReviewRuntimeTests {
    @Test func codexReviewStoreListReviewsFiltersAndSortsBySession() throws {
        let store = CodexReviewStore(configuration: .init())
        let runningID = try store.enqueueReview(
            sessionID: "session-a",
            request: .init(cwd: "/tmp/running", uncommitted: true)
        )
        store.markStarted(
            jobID: runningID,
            artifacts: .init(eventsPath: nil, logPath: nil, lastMessagePath: nil),
            startedAt: Date(timeIntervalSince1970: 200)
        )

        let recentID = try store.enqueueReview(
            sessionID: "session-a",
            request: .init(cwd: "/tmp/recent", uncommitted: true)
        )
        store.failToStart(
            jobID: recentID,
            message: "boom",
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 101)
        )

        _ = try store.enqueueReview(
            sessionID: "session-b",
            request: .init(cwd: "/tmp/foreign", uncommitted: true)
        )

        let listed = store.listReviews(sessionID: "session-a")
        #expect(listed.items.map(\.jobID) == [runningID, recentID])

        let filtered = store.listReviews(
            sessionID: "session-a",
            cwd: "/tmp/running",
            statuses: [ReviewJobState.running],
            limit: 10
        )
        #expect(filtered.items.map(\.jobID) == [runningID])
    }

    @Test func codexReviewStoreStartReviewReturnsTerminalResult() async throws {
        let scriptURL = try makeFakeCodexScript(mode: "success")
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let store = CodexReviewStore(
            configuration: .init(
                codexCommand: scriptURL.path,
                environment: ["HOME": FileManager.default.homeDirectoryForCurrentUser.path]
            )
        )

        let result = try await store.startReview(
            sessionID: "session-success",
            request: .init(
                cwd: FileManager.default.temporaryDirectory.path,
                target: .uncommitted
            )
        )

        #expect(result.status == ReviewJobState.succeeded)
        #expect(result.review == "Review ok")
        #expect(result.reviewThreadID == result.jobID)
        #expect(store.jobs.count == 1)
        #expect(store.jobs.first?.status == .succeeded)
    }

    @Test func codexReviewStoreReturnsCancelledAfterInFlightCancel() async throws {
        let scriptURL = try makeFakeCodexScript(mode: "long")
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let store = CodexReviewStore(
            configuration: .init(
                codexCommand: scriptURL.path,
                environment: [
                    "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                    "CODEX_FAKE_MODE": "long",
                ]
            )
        )

        let reviewTask = Task {
            try await store.startReview(
                sessionID: "session-cancel",
                request: .init(
                    cwd: FileManager.default.temporaryDirectory.path,
                    target: .uncommitted
                )
            )
        }

        let jobID = try await waitUntilRunningJobID(store: store, sessionID: "session-cancel")
        let cancelOutcome = try await store.cancelReview(
            reviewThreadID: jobID,
            sessionID: "session-cancel",
            reason: "test cancel"
        )
        let result = try await reviewTask.value

        #expect(cancelOutcome.status == ReviewJobState.cancelled)
        #expect(result.status == ReviewJobState.cancelled)
        #expect(result.error == "test cancel")
    }
}

private func makeFakeCodexScript(mode: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try """
    #!/bin/zsh
    mode="${CODEX_FAKE_MODE:-\(mode)}"
    out=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --output-last-message)
          out="$2"
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done

    if [[ "$mode" == "long" ]]; then
      trap 'exit 143' TERM INT
      print '{"type":"thread.started","thread_id":"thread-long"}'
      sleep 30
      exit 0
    fi

    print '{"type":"thread.started","thread_id":"thread-success"}'
    print '{"type":"turn.started"}'
    print '{"type":"item.completed","item":{"type":"agent_message","text":"Review ok"}}'
    print '{"type":"turn.completed"}'
    [[ -n "$out" ]] && print -n 'Review ok' > "$out"
    sleep 1
    """.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

private func waitUntilValue<T>(
    timeout: Duration = .seconds(2),
    interval: Duration = .milliseconds(20),
    action: @escaping () async throws -> T?
) async throws -> T {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if let value = try await action() {
            return value
        }
        try await Task.sleep(for: interval)
    }
    throw TestFailure("timed out")
}

private func waitUntilRunningJobID(
    store: CodexReviewStore,
    sessionID: String
) async throws -> String {
    try await waitUntilValue(timeout: .seconds(5), interval: .milliseconds(100)) {
        await MainActor.run {
            store.jobs(sessionID: sessionID).first(where: { $0.status == .running })?.id
        }
    }
}

private struct TestFailure: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}
