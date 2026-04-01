import Foundation
import Testing
@testable import ReviewCore
@testable import ReviewJobs

@Suite(.serialized) struct AppServerReviewRunnerTests {
    @Test func appServerReviewRunnerSucceedsAndCapturesLogs() async throws {
        let cwd = try makeTemporaryDirectory()
        let scriptURL = try makeFakeAppServerScript(mode: .success)
        let recorder = EventRecorder()
        var runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                codexCommand: scriptURL.path,
                environment: [
                    "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                ]
            )
        )
        runner.gracefulTerminationWait = .milliseconds(100)

        let result = try await runner.run(
            request: .init(cwd: cwd.path, target: .uncommittedChanges),
            defaultTimeoutSeconds: nil as Int?,
            onStart: { _, _ in },
            onEvent: { event in
                await recorder.record(event)
            },
            requestedTerminationReason: { nil as ReviewTerminationReason? }
        )

        #expect(result.state == .succeeded)
        #expect(result.reviewThreadID == "thr-review")
        #expect(result.turnID == "turn-review")
        #expect(result.content == "Looks solid overall.")
        #expect(await recorder.reviewThreadID == "thr-review")
        #expect(await recorder.rawLines.contains("diagnostic: success path"))
        #expect(await recorder.logTexts.contains("$ git diff --stat"))
        #expect(await recorder.logTexts.contains("README.md | 1 +"))
        #expect(await recorder.agentMessages.contains("Looks solid overall."))
    }

    @Test func appServerReviewRunnerCancelsViaTurnInterrupt() async throws {
        let cwd = try makeTemporaryDirectory()
        let scriptURL = try makeFakeAppServerScript(mode: .longRunning)
        let recorder = EventRecorder()
        let cancellation = CancellationFlag()
        var runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                codexCommand: scriptURL.path,
                environment: [
                    "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                ]
            )
        )
        runner.gracefulTerminationWait = .milliseconds(100)
        runner.pollInterval = .milliseconds(50)

        let task = Task {
            try await runner.run(
                request: .init(cwd: cwd.path, target: .uncommittedChanges),
                defaultTimeoutSeconds: nil as Int?,
                onStart: { _, _ in },
                onEvent: { event in
                    await recorder.record(event)
                },
                requestedTerminationReason: {
                    await cancellation.reason
                }
            )
        }

        try await waitUntil(timeout: .seconds(2), interval: .milliseconds(20)) {
            await recorder.reviewThreadID != nil
        }
        await cancellation.cancel("Cancelled from test.")

        let result = try await task.value
        #expect(result.state == .cancelled)
        #expect(result.errorMessage == "Cancelled from test.")
    }

    @Test func appServerReviewRunnerDoesNotSpawnWhenCancellationWasAlreadyRequested() async throws {
        let cwd = try makeTemporaryDirectory()
        let markerURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let scriptURL = try makeMarkerScript(markerURL: markerURL)
        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                codexCommand: scriptURL.path,
                environment: [
                    "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                ]
            )
        )

        let result = try await runner.run(
            request: .init(cwd: cwd.path, target: .custom(instructions: "Inspect API changes")),
            defaultTimeoutSeconds: nil as Int?,
            onStart: { _, _ in
                Issue.record("should not start")
            },
            onEvent: { _ in },
            requestedTerminationReason: {
                .cancelled("Cancelled before spawn.")
            }
        )

        #expect(result.state == .cancelled)
        #expect(result.errorMessage == "Cancelled before spawn.")
        #expect(FileManager.default.fileExists(atPath: markerURL.path) == false)
    }

    @Test func appServerReviewRunnerResolvesCodexFromPATHAtSpawnTime() async throws {
        let cwd = try makeTemporaryDirectory()
        let binDirectory = cwd.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        let executableURL = try makeFakeAppServerScript(mode: .success, at: binDirectory.appendingPathComponent("codex"))

        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                codexCommand: "codex",
                environment: [
                    "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                    "PATH": "\(binDirectory.path):/usr/bin:/bin",
                ]
            )
        )

        let result = try await runner.run(
            request: .init(cwd: cwd.path, target: .uncommittedChanges),
            defaultTimeoutSeconds: nil as Int?,
            onStart: { _, _ in },
            onEvent: { _ in },
            requestedTerminationReason: { nil as ReviewTerminationReason? }
        )

        #expect(result.state == .succeeded)
        #expect(FileManager.default.fileExists(atPath: executableURL.path))
    }

    @Test func appServerReviewRunnerFailsWithReadableErrorWhenCodexIsMissing() async throws {
        let cwd = try makeTemporaryDirectory()
        let missingCommand = "codex-missing"

        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                codexCommand: missingCommand,
                environment: [
                    "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                    "PATH": cwd.path,
                ]
            )
        )

        await #expect(throws: ReviewError.self) {
            _ = try await runner.run(
                request: .init(cwd: cwd.path, target: .uncommittedChanges),
                defaultTimeoutSeconds: nil as Int?,
                onStart: { _, _ in },
                onEvent: { _ in },
                requestedTerminationReason: { nil as ReviewTerminationReason? }
            )
        }
    }

    @Test func appServerReviewRunnerThrowsWhenBootstrapFailsBeforeReviewStarts() async throws {
        let cwd = try makeTemporaryDirectory()
        let scriptURL = try makeFakeAppServerScript(mode: .bootstrapFailureBeforeThreadStart)
        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                codexCommand: scriptURL.path,
                environment: [
                    "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                ]
            )
        )

        await #expect(throws: ReviewError.self) {
            _ = try await runner.run(
                request: .init(cwd: cwd.path, target: .uncommittedChanges),
                defaultTimeoutSeconds: nil as Int?,
                onStart: { _, _ in },
                onEvent: { _ in },
                requestedTerminationReason: { nil as ReviewTerminationReason? }
            )
        }
    }

    @Test func appServerReviewRunnerReturnsFailureWhenAppServerCrashesAfterReviewStart() async throws {
        let cwd = try makeTemporaryDirectory()
        let scriptURL = try makeFakeAppServerScript(mode: .postReviewCrash)
        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                codexCommand: scriptURL.path,
                environment: [
                    "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                ]
            )
        )

        let result = try await runner.run(
            request: .init(cwd: cwd.path, target: .uncommittedChanges),
            defaultTimeoutSeconds: nil as Int?,
            onStart: { _, _ in },
            onEvent: { _ in },
            requestedTerminationReason: { nil as ReviewTerminationReason? }
        )

        #expect(result.state == .failed)
        #expect(result.reviewThreadID == "thr-review")
    }

    @Test func appServerReviewRunnerFailsWhenExitedReviewModeIsMissing() async throws {
        let cwd = try makeTemporaryDirectory()
        let scriptURL = try makeFakeAppServerScript(mode: .missingExitedReviewMode)
        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                codexCommand: scriptURL.path,
                environment: [
                    "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                ]
            )
        )

        let result = try await runner.run(
            request: .init(cwd: cwd.path, target: .uncommittedChanges),
            defaultTimeoutSeconds: nil as Int?,
            onStart: { _, _ in },
            onEvent: { _ in },
            requestedTerminationReason: { nil as ReviewTerminationReason? }
        )

        #expect(result.state == .failed)
        #expect(result.errorMessage == "Review completed without an `exitedReviewMode` item.")
    }

    @Test func appServerReviewRunnerWaitsForExitedReviewModeAfterTurnCompletion() async throws {
        let cwd = try makeTemporaryDirectory()
        let scriptURL = try makeFakeAppServerScript(mode: .outOfOrderTurnCompletion)
        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                codexCommand: scriptURL.path,
                environment: [
                    "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                ]
            )
        )

        let result = try await runner.run(
            request: .init(cwd: cwd.path, target: .uncommittedChanges),
            defaultTimeoutSeconds: nil as Int?,
            onStart: { _, _ in },
            onEvent: { _ in },
            requestedTerminationReason: { nil as ReviewTerminationReason? }
        )

        #expect(result.state == .succeeded)
        #expect(result.content == "Looks solid overall.")
    }

    @Test func appServerReviewRunnerPreservesParentThreadIDWhenReviewThreadDiffers() async throws {
        let cwd = try makeTemporaryDirectory()
        let scriptURL = try makeFakeAppServerScript(mode: .detachedReviewLike)
        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                codexCommand: scriptURL.path,
                environment: [
                    "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                ]
            )
        )

        let result = try await runner.run(
            request: .init(cwd: cwd.path, target: .uncommittedChanges),
            defaultTimeoutSeconds: nil as Int?,
            onStart: { _, _ in },
            onEvent: { _ in },
            requestedTerminationReason: { nil as ReviewTerminationReason? }
        )

        #expect(result.reviewThreadID == "thr-review")
        #expect(result.threadID == "thr-parent")
    }

    @Test func appServerReviewRunnerKeepsTurnFailureMessageWhenStderrContainsErrorWord() async throws {
        let cwd = try makeTemporaryDirectory()
        let scriptURL = try makeFakeAppServerScript(mode: .stderrNoiseAfterFailure)
        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                codexCommand: scriptURL.path,
                environment: [
                    "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                ]
            )
        )

        let result = try await runner.run(
            request: .init(cwd: cwd.path, target: .uncommittedChanges),
            defaultTimeoutSeconds: nil as Int?,
            onStart: { _, _ in },
            onEvent: { _ in },
            requestedTerminationReason: { nil as ReviewTerminationReason? }
        )

        #expect(result.state == .failed)
        #expect(result.errorMessage == "turn failed")
    }

    @Test func appServerReviewRunnerReturnsBeforeReviewStartWhenCancelledDuringBootstrap() async throws {
        let cwd = try makeTemporaryDirectory()
        let markerURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let scriptURL = try makeFakeAppServerScript(mode: .slowThreadStart, markerURL: markerURL)
        defer {
            try? FileManager.default.removeItem(at: scriptURL)
            try? FileManager.default.removeItem(at: markerURL)
        }

        let cancellation = CancellationFlag()
        var runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                codexCommand: scriptURL.path,
                environment: [
                    "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                ]
            )
        )
        runner.pollInterval = .milliseconds(50)

        let task = Task {
            try await runner.run(
                request: .init(cwd: cwd.path, target: .uncommittedChanges),
                defaultTimeoutSeconds: nil as Int?,
                onStart: { _, _ in },
                onEvent: { _ in },
                requestedTerminationReason: {
                    await cancellation.reason
                }
            )
        }

        try await Task.sleep(for: .milliseconds(100))
        await cancellation.cancel("Cancelled during bootstrap.")

        let result = try await task.value
        #expect(result.state == .cancelled)
        #expect(result.reviewThreadID == nil)
        #expect(result.errorMessage == "Cancelled during bootstrap.")
        #expect(FileManager.default.fileExists(atPath: markerURL.path) == false)
    }
}

private enum FakeAppServerMode: String {
    case success
    case longRunning
    case bootstrapFailureBeforeThreadStart
    case postReviewCrash
    case missingExitedReviewMode
    case outOfOrderTurnCompletion
    case detachedReviewLike
    case stderrNoiseAfterFailure
    case slowThreadStart
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeFakeAppServerScript(
    mode: FakeAppServerMode,
    at url: URL? = nil,
    markerURL: URL? = nil
) throws -> URL {
    let destination = url ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let script = """
    #!/usr/bin/env python3
    import json
    import sys
    import time

    mode = "\(mode.rawValue)"
    thread_id = "thr-review"
    parent_thread_id = "thr-parent"
    turn_id = "turn-review"

    def send(obj, stream=sys.stdout):
        stream.write(json.dumps(obj) + "\\n")
        stream.flush()

    for raw in sys.stdin:
        if not raw.strip():
            continue
        message = json.loads(raw)
        method = message.get("method")

        if method == "initialize":
            send({"id": message["id"], "result": {"platformFamily": "macOS", "platformOs": "Darwin"}})
        elif method == "initialized":
            continue
        elif method == "thread/start":
            if mode == "bootstrapFailureBeforeThreadStart":
                sys.stderr.write("bootstrap failed before thread/start\\n")
                sys.stderr.flush()
                sys.exit(9)
            if mode == "slowThreadStart":
                time.sleep(1)
            send({"id": message["id"], "result": {"thread": {"id": parent_thread_id if mode == "detachedReviewLike" else thread_id}}})
        elif method == "review/start":
            if mode == "slowThreadStart":
                open("\(markerURL?.path ?? "/tmp/review-start-marker")", "w").close()
            send({
                "id": message["id"],
                "result": {
                    "turn": {"id": turn_id, "status": "inProgress", "error": None},
                    "reviewThreadId": thread_id
                }
            })
            send({"method": "turn/started", "params": {"threadId": thread_id, "turn": {"id": turn_id, "status": "inProgress", "error": None}}})
            send({"method": "item/started", "params": {"threadId": thread_id, "turnId": turn_id, "item": {"type": "enteredReviewMode", "id": turn_id, "review": "current changes"}}})

            if mode == "longRunning":
                continue

            if mode == "postReviewCrash":
                sys.stderr.write("crashed after review/start\\n")
                sys.stderr.flush()
                sys.exit(7)

            if mode == "stderrNoiseAfterFailure":
                send({"method": "turn/completed", "params": {"threadId": thread_id, "turn": {"id": turn_id, "status": "failed", "error": {"message": "turn failed"}}}})
                sys.stderr.write("0 errors found during cleanup\\n")
                sys.stderr.flush()
                time.sleep(0.2)
                sys.exit(1)

            send({"method": "item/started", "params": {"threadId": thread_id, "turnId": turn_id, "item": {"type": "commandExecution", "id": "cmd_1", "command": "git diff --stat", "status": "inProgress", "aggregatedOutput": None, "exitCode": None}}})
            send({"method": "item/commandExecution/outputDelta", "params": {"threadId": thread_id, "turnId": turn_id, "itemId": "cmd_1", "delta": "README.md | 1 +"}})
            send({"method": "item/completed", "params": {"threadId": thread_id, "turnId": turn_id, "item": {"type": "commandExecution", "id": "cmd_1", "command": "git diff --stat", "status": "completed", "aggregatedOutput": "README.md | 1 +", "exitCode": 0}}})
            send({"method": "item/agentMessage/delta", "params": {"threadId": thread_id, "turnId": turn_id, "itemId": "msg_1", "delta": "Looks solid"}})
            sys.stderr.write("diagnostic: success path\\n")
            sys.stderr.flush()

            if mode == "outOfOrderTurnCompletion":
                send({"method": "turn/completed", "params": {"threadId": thread_id, "turn": {"id": turn_id, "status": "completed", "error": None}}})
                time.sleep(0.05)
                send({"method": "item/completed", "params": {"threadId": thread_id, "turnId": turn_id, "item": {"type": "exitedReviewMode", "id": turn_id, "review": "Looks solid overall."}}})
                time.sleep(0.5)
                sys.exit(0)

            if mode != "missingExitedReviewMode":
                send({"method": "item/completed", "params": {"threadId": thread_id, "turnId": turn_id, "item": {"type": "exitedReviewMode", "id": turn_id, "review": "Looks solid overall."}}})

            send({"method": "turn/completed", "params": {"threadId": thread_id, "turn": {"id": turn_id, "status": "completed", "error": None}}})
            time.sleep(0.5)
            sys.exit(0)
        elif method == "turn/interrupt":
            send({"id": message["id"], "result": {}})
            send({"method": "turn/completed", "params": {"threadId": thread_id, "turn": {"id": turn_id, "status": "interrupted", "error": {"message": "Cancelled from test."}}}})
            time.sleep(0.2)
            sys.exit(0)
    """.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"

    try script.write(to: destination, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
    return destination
}

private func makeMarkerScript(markerURL: URL) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try """
    #!/bin/zsh
    touch "\(markerURL.path)"
    exit 0
    """.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

private actor EventRecorder {
    private(set) var reviewThreadID: String?
    private(set) var rawLines: [String] = []
    private(set) var logTexts: [String] = []
    private(set) var agentMessages: [String] = []

    func record(_ event: ReviewProcessEvent) {
        switch event {
        case .reviewStarted(let reviewThreadID, _, _):
            self.reviewThreadID = reviewThreadID
        case .rawLine(let line):
            rawLines.append(line)
        case .logEntry(let entry):
            logTexts.append(entry.text)
        case .agentMessage(let message):
            agentMessages.append(message)
        case .progress, .failed:
            break
        }
    }
}

private actor CancellationFlag {
    private var cancellationReason: ReviewTerminationReason?

    var reason: ReviewTerminationReason? {
        cancellationReason
    }

    func cancel(_ reason: String) {
        cancellationReason = .cancelled(reason)
    }
}

private func waitUntil(
    timeout: Duration,
    interval: Duration,
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() {
            return
        }
        try await Task.sleep(for: interval)
    }
    throw TimeoutError()
}

private struct TimeoutError: Error {}
