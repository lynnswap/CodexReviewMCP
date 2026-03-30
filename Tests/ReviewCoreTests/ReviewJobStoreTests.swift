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

    @Test func reviewJobStoreStartReviewReturnsTerminalResult() async throws {
        let scriptURL = try makeFakeCodexScript(mode: "success")
        defer { try? FileManager.default.removeItem(at: scriptURL) }
        let store = ReviewJobStore(
            configuration: .init(
                codexCommand: scriptURL.path,
                environment: [
                    "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                ]
            )
        )

        let result = try await store.startReview(
            sessionID: "session-success",
            request: .init(
                cwd: FileManager.default.temporaryDirectory.path,
                target: .uncommittedChanges
            )
        )

        #expect(result.status == .succeeded)
        #expect(result.review == "Review ok")
        #expect(result.reviewThreadID == result.jobID)
    }

    @Test func reviewJobStoreStartReviewReturnsCancelledAfterInFlightCancel() async throws {
        let scriptURL = try makeFakeCodexScript(mode: "long")
        defer { try? FileManager.default.removeItem(at: scriptURL) }
        let store = ReviewJobStore(
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
                sessionID: "session-start-cancel",
                request: .init(
                    cwd: FileManager.default.temporaryDirectory.path,
                    target: .uncommittedChanges
                )
            )
        }

        let jobID: String = try await waitUntilValue(timeout: .seconds(5), interval: .milliseconds(100)) {
            let snapshots = await store.allSnapshots(for: "session-start-cancel")
            guard let snapshot = snapshots.first, snapshot.state == .running else {
                return nil
            }
            return snapshot.jobID
        }

        _ = try await store.cancel(jobID: jobID, sessionID: "session-start-cancel", reason: "test cancel")
        let result = try await reviewTask.value

        #expect(result.status == .cancelled)
        #expect(result.error == "test cancel")
    }

    @Test func reviewJobStoreReadReviewReturnsLatestAgentMessageWhileRunning() async throws {
        let scriptURL = try makeFakeCodexScript(mode: "progress")
        defer { try? FileManager.default.removeItem(at: scriptURL) }
        let store = ReviewJobStore(
            configuration: .init(
                codexCommand: scriptURL.path,
                environment: [
                    "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                ]
            )
        )

        let jobID = try await store.enqueueReview(
            sessionID: "session-running",
            request: .init(
                cwd: FileManager.default.temporaryDirectory.path,
                uncommitted: true
            )
        )
        let reviewTask = Task {
            await store.runReview(jobID: jobID) { _, _ in }
        }

        var observedRunningReview = false
        for _ in 0 ..< 50 {
            let result = try await store.readReview(
                reviewThreadID: jobID,
                sessionID: "session-running"
            )
            if result.status == .running && result.review == "Still working" {
                observedRunningReview = true
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(observedRunningReview == true)

        _ = try await store.cancel(jobID: jobID, sessionID: "session-running", reason: "done")
        _ = await reviewTask.value
    }

    @Test func reviewJobStoreListReviewsFiltersAndSortsBySession() async throws {
        let scriptURL = try makeFakeCodexScript(mode: "long")
        defer { try? FileManager.default.removeItem(at: scriptURL) }
        let runningDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let recentDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let foreignDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: runningDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recentDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: foreignDirectory, withIntermediateDirectories: true)
        let store = ReviewJobStore(
            configuration: .init(
                codexCommand: scriptURL.path,
                environment: [
                    "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                    "CODEX_FAKE_MODE": "long",
                ]
            )
        )

        let runningJobID = try await store.enqueueReview(
            sessionID: "session-list",
            request: .init(cwd: runningDirectory.path, uncommitted: true)
        )
        let recentJobID = try await store.enqueueReview(
            sessionID: "session-list",
            request: .init(cwd: recentDirectory.path, uncommitted: true)
        )
        let foreignJobID = try await store.enqueueReview(
            sessionID: "session-foreign",
            request: .init(cwd: foreignDirectory.path, uncommitted: true)
        )

        let runningTask = Task { await store.runReview(jobID: runningJobID) { _, _ in } }
        let recentTask = Task { await store.runReview(jobID: recentJobID) { _, _ in } }
        let foreignTask = Task { await store.runReview(jobID: foreignJobID) { _, _ in } }

        let runningSnapshot: ReviewJobSnapshot = try await waitUntilValue(timeout: .seconds(5), interval: .milliseconds(100)) {
            await store.allSnapshots(for: "session-list").first(where: { $0.jobID == runningJobID && $0.state == .running })
        }
        _ = runningSnapshot
        _ = try await store.cancel(jobID: recentJobID, sessionID: "session-list", reason: "done")
        _ = await recentTask.value

        let listed = await store.listReviews(sessionID: "session-list")
        #expect(listed.items.map(\.jobID) == [runningJobID, recentJobID])

        let filtered = await store.listReviews(sessionID: "session-list", cwd: runningDirectory.path, statuses: [.running], limit: 10)
        #expect(filtered.items.map(\.jobID) == [runningJobID])

        _ = try await store.cancel(jobID: runningJobID, sessionID: "session-list", reason: "done")
        _ = try await store.cancel(jobID: foreignJobID, sessionID: "session-foreign", reason: "done")
        _ = await runningTask.value
        _ = await foreignTask.value
    }

    @Test func reviewJobStoreResolveSelectorSupportsLatestAndAmbiguous() async throws {
        let scriptURL = try makeFakeCodexScript(mode: "long")
        defer { try? FileManager.default.removeItem(at: scriptURL) }
        let sharedDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sharedDirectory, withIntermediateDirectories: true)
        let store = ReviewJobStore(
            configuration: .init(
                codexCommand: scriptURL.path,
                environment: [
                    "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                    "CODEX_FAKE_MODE": "long",
                ]
            )
        )

        let firstJobID = try await store.enqueueReview(
            sessionID: "session-selector",
            request: .init(cwd: sharedDirectory.path, uncommitted: true)
        )
        let firstTask = Task { await store.runReview(jobID: firstJobID) { _, _ in } }
        try await waitUntil(timeout: .seconds(5), interval: .milliseconds(100)) {
            await store.allSnapshots(for: "session-selector").contains(where: { $0.jobID == firstJobID && $0.state == .running })
        }
        try await Task.sleep(for: .milliseconds(50))

        let secondJobID = try await store.enqueueReview(
            sessionID: "session-selector",
            request: .init(cwd: sharedDirectory.path, uncommitted: true)
        )
        let secondTask = Task { await store.runReview(jobID: secondJobID) { _, _ in } }
        try await waitUntil(timeout: .seconds(5), interval: .milliseconds(100)) {
            let snapshots = await store.allSnapshots(for: "session-selector")
            return snapshots.contains(where: { $0.jobID == secondJobID && $0.state == .running })
        }

        do {
            _ = try await store.cancelReview(
                selector: .init(cwd: sharedDirectory.path),
                sessionID: "session-selector"
            )
            Issue.record("expected ambiguous selector")
        } catch let error as ReviewJobSelectionError {
            switch error {
            case .ambiguous(let candidates):
                #expect(candidates.map(\.jobID).sorted() == [firstJobID, secondJobID].sorted())
            case .notFound:
                Issue.record("expected ambiguous selector")
            }
        }

        let cancelOutcome = try await store.cancelReview(
            selector: .init(cwd: sharedDirectory.path, latest: true),
            sessionID: "session-selector"
        )
        #expect(cancelOutcome.jobID == secondJobID)

        _ = try await store.cancel(jobID: firstJobID, sessionID: "session-selector", reason: "done")
        _ = await firstTask.value
        _ = await secondTask.value
    }

    @Test func reviewJobStoreListReviewsDefaultsToTwentyItems() async throws {
        let store = ReviewJobStore()

        for index in 0 ..< 25 {
            _ = try await store.enqueueReview(
                sessionID: "session-limit",
                request: .init(
                    cwd: FileManager.default.temporaryDirectory
                        .appendingPathComponent("review-limit-\(index)-\(UUID().uuidString)", isDirectory: true)
                        .path,
                    uncommitted: true
                )
            )
        }

        let defaultListed = await store.listReviews(sessionID: "session-limit")
        #expect(defaultListed.items.count == 20)

        let expandedListed = await store.listReviews(sessionID: "session-limit", limit: 999)
        #expect(expandedListed.items.count == 25)
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

private func waitUntil(
    timeout: Duration = .seconds(2),
    interval: Duration = .milliseconds(20),
    condition: @escaping () async throws -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if try await condition() {
            return
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
