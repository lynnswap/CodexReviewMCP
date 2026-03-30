import Foundation
import Testing
@testable import ReviewCore

@Suite(.serialized) struct ReviewJobStoreTests {
    @Test func reviewJobStoreCancelsRunningProcessGroup() async throws {
        let scriptURL = try makeFakeCodexScript(mode: "long")
        let store = ReviewJobStore(
            configuration: .init(
                codexCommand: scriptURL.path,
                environment: [
                    "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                    "CODEX_FAKE_MODE": "long",
                ]
            )
        )

        let jobID = try await store.enqueueReview(
            sessionID: "session-a",
            request: .init(cwd: FileManager.default.temporaryDirectory.path)
        )
        let reviewTask = Task {
            await store.runReview(jobID: jobID) { _, _ in }
        }

        for _ in 0 ..< 50 {
            if await store.allSnapshots(for: "session-a").first?.state == .running {
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        let cancelResult = try await store.cancel(jobID: jobID, sessionID: "session-a", reason: "test cancel")
        let execution = await reviewTask.value

        #expect(cancelResult.signalled)
        #expect(execution.snapshot.state == .cancelled)
    }

    @Test func reviewJobStoreDoesNotSpawnWhenCancelledBeforeStart() async throws {
        let markerURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let scriptURL = try makeMarkerCodexScript(markerURL: markerURL)
        let store = ReviewJobStore(
            configuration: .init(
                codexCommand: scriptURL.path,
                environment: [
                    "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                ]
            )
        )

        let jobID = try await store.enqueueReview(
            sessionID: "session-b",
            request: .init(cwd: FileManager.default.temporaryDirectory.path)
        )
        _ = try await store.cancel(jobID: jobID, sessionID: "session-b", reason: "cancel before spawn")

        let execution = await store.runReview(jobID: jobID) { _, _ in }

        #expect(execution.snapshot.state == .cancelled)
        #expect(FileManager.default.fileExists(atPath: markerURL.path) == false)
    }

    @Test func reviewJobStorePrunesCancelledQueuedJobAfterSessionClose() async throws {
        let scriptURL = try makeFakeCodexScript(mode: "long")
        let store = ReviewJobStore(
            configuration: .init(
                codexCommand: scriptURL.path,
                environment: [
                    "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                ]
            )
        )

        let jobID = try await store.enqueueReview(
            sessionID: "session-prune",
            request: .init(cwd: FileManager.default.temporaryDirectory.path)
        )
        _ = try await store.cancel(jobID: jobID, sessionID: "session-prune", reason: "cancel before close")

        await store.closeSession("session-prune", reason: "session closed")

        #expect(await store.allSnapshots(for: "session-prune").isEmpty)
    }

    @Test func reviewJobStoreKeepsClosedSessionDeniedAfterPruningJobs() async throws {
        let scriptURL = try makeFakeCodexScript(mode: "long")
        let store = ReviewJobStore(
            configuration: .init(
                codexCommand: scriptURL.path,
                environment: [
                    "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                ]
            )
        )

        let jobID = try await store.enqueueReview(
            sessionID: "session-closed",
            request: .init(cwd: FileManager.default.temporaryDirectory.path)
        )
        _ = try await store.cancel(jobID: jobID, sessionID: "session-closed", reason: "cancel before close")
        await store.closeSession("session-closed", reason: "session closed")

        do {
            _ = try await store.startReview(
                sessionID: "session-closed",
                request: .init(
                    cwd: FileManager.default.temporaryDirectory.path,
                    target: .uncommittedChanges
                )
            )
            throw TestFailure("expected closed session to stay denied")
        } catch is ReviewError {
        }
    }

    @Test func reviewJobStoreReadReviewReturnsLatestAgentMessageWhileRunning() async throws {
        let scriptURL = try makeFakeCodexScript(mode: "progress")
        let store = ReviewJobStore(
            configuration: .init(
                codexCommand: scriptURL.path,
                environment: [
                    "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                ]
            )
        )

        let handle = try await store.startReview(
            sessionID: "session-running",
            request: .init(
                cwd: FileManager.default.temporaryDirectory.path,
                target: .uncommittedChanges
            )
        )

        var observedRunningReview = false
        for _ in 0 ..< 50 {
            let result = try await store.readReview(
                reviewThreadID: handle.reviewThreadID,
                sessionID: "session-running"
            )
            if result.status == .running && result.review == "Still working" {
                observedRunningReview = true
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(observedRunningReview == true)

        _ = try await store.cancel(jobID: handle.reviewThreadID, sessionID: "session-running", reason: "done")
    }

    @Test func reviewJobStoreRejectsMissingWorkingDirectory() async throws {
        let missingCWD = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .path
        let scriptURL = try makeFakeCodexScript(mode: "long")
        let store = ReviewJobStore(
            configuration: .init(
                codexCommand: scriptURL.path,
                environment: [
                    "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                ]
            )
        )

        let jobID = try await store.enqueueReview(
            sessionID: "session-c",
            request: .init(cwd: missingCWD)
        )
        let execution = await store.runReview(jobID: jobID) { _, _ in }

        #expect(execution.snapshot.state == .failed)
        #expect(FileManager.default.fileExists(atPath: missingCWD) == false)
    }

    @Test func reviewJobStoreClearsRecoveredErrorWhenSnapshotHasNoError() {
        var failingSnapshot = ReviewEventSnapshot()
        failingSnapshot.errorMessage = "boom"
        #expect(ReviewJobStore.normalizedErrorMessage(from: failingSnapshot) == "boom")

        var recoveredSnapshot = ReviewEventSnapshot()
        recoveredSnapshot.errorMessage = ""
        #expect(ReviewJobStore.normalizedErrorMessage(from: recoveredSnapshot) == nil)
    }

    @Test func readTailReturnsOnlyRequestedSuffix() throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try "prefix-suffix".write(to: fileURL, atomically: true, encoding: .utf8)

        let tail = readTail(path: fileURL.path, tailBytes: 6)

        #expect(tail == "suffix")
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

    if [[ "$mode" == "progress" ]]; then
      trap 'exit 143' TERM INT
      print '{"type":"thread.started","thread_id":"thread-progress"}'
      print '{"type":"turn.started"}'
      print '{"type":"item.completed","item":{"type":"agent_message","text":"Still working"}}'
      sleep 30
      exit 0
    fi

    print '{"type":"thread.started","thread_id":"thread-success"}'
    print '{"type":"turn.started"}'
    print '{"type":"item.completed","item":{"type":"agent_message","text":"Review ok"}}'
    print '{"type":"turn.completed"}'
    [[ -n "$out" ]] && print -n 'Review ok' > "$out"
    sleep 30
    """.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

private func makeMarkerCodexScript(markerURL: URL) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try """
    #!/bin/zsh
    touch "\(markerURL.path)"
    sleep 5
    """.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

private struct TestFailure: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}
