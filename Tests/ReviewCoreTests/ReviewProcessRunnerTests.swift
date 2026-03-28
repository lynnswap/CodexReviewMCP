import Foundation
import Testing
@testable import ReviewCore

@Suite(.serialized) struct ReviewProcessRunnerTests {
    @Test func reviewProcessRunnerPrefersTerminalSuccessOverTimeoutBoundary() async throws {
        let cwd = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)

        let scriptURL = try makeNearTimeoutSuccessScript()
        var runner = CodexReviewProcessRunner(
            commandBuilder: ReviewCommandBuilder(
                codexCommand: scriptURL.path,
                environment: [
                    "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                ]
            )
        )
        runner.gracefulTerminationWait = Duration.milliseconds(100)
        runner.failureFlushWait = Duration.milliseconds(100)
        runner.pollInterval = Duration.milliseconds(1200)

        let result = try await runner.run(
            request: ReviewRequestOptions(
                cwd: cwd.path,
                timeoutSeconds: 1
            ),
            defaultTimeoutSeconds: nil as Int?,
            onStart: { _, _, _ in },
            onSnapshot: { _ in },
            requestedTerminationReason: { nil as ReviewTerminationReason? },
            onProgress: { _, _ in }
        )

        #expect(result.state == ReviewJobState.succeeded)
        #expect(result.summary == "Review completed successfully.")
        #expect(result.content == "Review ok")
        #expect(result.threadID == "thread-timeout")
    }

    @Test func reviewProcessRunnerCancelsChildWhenTaskIsCancelled() async throws {
        let cwd = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)

        var runner = CodexReviewProcessRunner(
            commandBuilder: ReviewCommandBuilder(
                codexCommand: try makeLongRunningScript().path,
                environment: [
                    "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                ]
            )
        )
        runner.gracefulTerminationWait = .milliseconds(100)
        runner.pollInterval = .milliseconds(50)

        let task = Task {
            try await runner.run(
                request: ReviewRequestOptions(cwd: cwd.path),
                defaultTimeoutSeconds: nil as Int?,
                onStart: { _, _, _ in },
                onSnapshot: { _ in },
                requestedTerminationReason: { nil as ReviewTerminationReason? },
                onProgress: { _, _ in }
            )
        }

        try await Task.sleep(for: .milliseconds(150))
        task.cancel()

        let result = try await task.value
        #expect(result.state == .cancelled)
        #expect(result.summary == "Review cancelled.")
    }

    @Test func reviewProcessRunnerDoesNotSpawnWhenCancellationWasAlreadyRequested() async throws {
        let cwd = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)

        let markerURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let scriptURL = try makeMarkerCodexScript(markerURL: markerURL)
        let runner = CodexReviewProcessRunner(
            commandBuilder: ReviewCommandBuilder(
                codexCommand: scriptURL.path,
                environment: [
                    "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                ]
            )
        )

        let startRecorder = StartRecorder()
        let result = try await runner.run(
            request: ReviewRequestOptions(cwd: cwd.path),
            defaultTimeoutSeconds: nil as Int?,
            onStart: { _, _, _ in
                await startRecorder.markStarted()
            },
            onSnapshot: { _ in },
            requestedTerminationReason: { .cancelled("Cancelled before spawn.") },
            onProgress: { _, _ in }
        )

        #expect(result.state == .cancelled)
        #expect(result.summary == "Review cancelled.")
        #expect(result.errorMessage == "Cancelled before spawn.")
        #expect(await startRecorder.didStart == false)
        #expect(FileManager.default.fileExists(atPath: markerURL.path) == false)
    }
}

private func makeNearTimeoutSuccessScript() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try """
    #!/bin/zsh
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

    print '{"type":"thread.started","thread_id":"thread-timeout"}'
    sleep 0.9
    print '{"type":"turn.started"}'
    print '{"type":"item.completed","item":{"type":"agent_message","text":"Review ok"}}'
    print '{"type":"turn.completed"}'
    [[ -n "$out" ]] && print -n 'Review ok' > "$out"
    sleep 3
    exit 0
    """.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

private func makeLongRunningScript() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try """
    #!/bin/zsh
    print '{"type":"thread.started","thread_id":"thread-cancel"}'
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

private actor StartRecorder {
    private(set) var didStart = false

    func markStarted() {
        didStart = true
    }
}
