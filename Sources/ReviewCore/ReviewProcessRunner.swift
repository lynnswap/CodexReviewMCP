import Darwin
import Foundation

package struct ReviewProcessOutcome: Sendable {
    package var state: ReviewJobState
    package var exitCode: Int
    package var threadID: String?
    package var lastAgentMessage: String
    package var errorMessage: String?
    package var summary: String
    package var artifacts: ReviewArtifacts
    package var startedAt: Date
    package var endedAt: Date
    package var content: String
}

package struct CodexReviewProcessRunner: Sendable {
    package var commandBuilder: ReviewCommandBuilder
    package var gracefulTerminationWait: Duration = .seconds(2)
    package var failureFlushWait: Duration = .seconds(2)
    package var pollInterval: Duration = .milliseconds(250)

    package init(
        commandBuilder: ReviewCommandBuilder = .init()
    ) {
        self.commandBuilder = commandBuilder
    }

    package func run(
        request: ReviewRequestOptions,
        defaultTimeoutSeconds: Int?,
        onStart: @escaping @Sendable (ReviewArtifacts, ReviewProcessController, Date) async -> Void,
        onSnapshot: @escaping @Sendable (ReviewEventSnapshot) async -> Void,
        requestedTerminationReason: @escaping @Sendable () async -> ReviewTerminationReason?,
        onProgress: @escaping @Sendable (ReviewProgressStage, String?) async -> Void
    ) async throws -> ReviewProcessOutcome {
        let command = try commandBuilder.build(request: request)
        if let cancelledOutcome = await cancelledOutcomeBeforeStart(
            command: command,
            request: request,
            requestedTerminationReason: requestedTerminationReason,
            onProgress: onProgress
        ) {
            return cancelledOutcome
        }
        let controller = try ReviewProcessController.start(command: command)
        let startedAt = Date()
        await onStart(command.artifacts, controller, startedAt)
        await onProgress(.started, "Review started.")

        let eventsURL = URL(fileURLWithPath: command.artifacts.eventsPath!)
        let lastMessageURL = URL(fileURLWithPath: command.artifacts.lastMessagePath!)
        var snapshot = ReviewEventSnapshot()
        var didEmitThreadProgress = false
        var cancellationReason: String?
        let timeoutSeconds = request.timeoutSeconds ?? defaultTimeoutSeconds

        while true {
            _ = snapshot.refresh(fileURL: eventsURL)
            await onSnapshot(snapshot)

            if snapshot.terminalState == .none,
               let terminationReason = await requestedTerminationReason()
            {
                switch terminationReason {
                case .cancelled(let reason):
                    cancellationReason = reason
                }
            }

            if didEmitThreadProgress == false, let threadID = snapshot.threadID {
                didEmitThreadProgress = true
                await onProgress(.threadStarted, "Thread started: \(threadID)")
            }

            if snapshot.terminalState == .success {
                _ = await controller.terminateGracefully(grace: gracefulTerminationWait)
                let exitCode = (await controller.pollExitStatus()) ?? 0
                let endedAt = Date()
                let content = readText(from: lastMessageURL)?.nilIfEmpty
                    ?? snapshot.lastAgentMessage.nilIfEmpty
                    ?? "Review completed."
                let finalState: ReviewJobState = cancellationReason == nil ? .succeeded : .cancelled
                let summary = cancellationReason == nil ? "Review completed successfully." : "Review cancelled."
                let artifacts = finalizeArtifacts(
                    command.artifacts,
                    keepArtifacts: request.keepArtifacts,
                    state: finalState
                )
                await onProgress(.completed, summary)
                return ReviewProcessOutcome(
                    state: finalState,
                    exitCode: exitCode,
                    threadID: snapshot.threadID,
                    lastAgentMessage: snapshot.lastAgentMessage,
                    errorMessage: cancellationReason,
                    summary: summary,
                    artifacts: artifacts,
                    startedAt: startedAt,
                    endedAt: endedAt,
                    content: content
                )
            }

            if snapshot.terminalState == .failure {
                if await controller.waitForExit(timeout: failureFlushWait) == nil {
                    _ = await controller.terminateGracefully(grace: gracefulTerminationWait)
                }
                let exitCode = (await controller.pollExitStatus()) ?? 1
                let endedAt = Date()
                let content = readText(from: lastMessageURL)?.nilIfEmpty
                    ?? snapshot.lastAgentMessage.nilIfEmpty
                    ?? snapshot.errorMessage.nilIfEmpty
                    ?? "Review failed."
                let finalState: ReviewJobState = cancellationReason == nil ? .failed : .cancelled
                let errorMessage = cancellationReason ?? snapshot.errorMessage.nilIfEmpty ?? "codex review failed (exit=\(exitCode))"
                let summary = cancellationReason == nil ? "Review failed." : "Review cancelled."
                let artifacts = finalizeArtifacts(
                    command.artifacts,
                    keepArtifacts: request.keepArtifacts,
                    state: finalState
                )
                await onProgress(.completed, summary)
                return ReviewProcessOutcome(
                    state: finalState,
                    exitCode: exitCode,
                    threadID: snapshot.threadID,
                    lastAgentMessage: snapshot.lastAgentMessage,
                    errorMessage: errorMessage,
                    summary: summary,
                    artifacts: artifacts,
                    startedAt: startedAt,
                    endedAt: endedAt,
                    content: content
                )
            }

            if let exitCode = await controller.pollExitStatus() {
                let endedAt = Date()
                let state: ReviewJobState = cancellationReason == nil ? (exitCode == 0 ? .succeeded : .failed) : .cancelled
                let errorMessage = cancellationReason ?? (exitCode == 0 ? nil : "codex review failed (exit=\(exitCode))")
                let summary: String
                switch state {
                case .succeeded:
                    summary = "Review completed successfully."
                case .failed:
                    summary = "Review failed."
                case .cancelled:
                    summary = "Review cancelled."
                case .queued, .running:
                    summary = "Review finished."
                }
                let content = readText(from: lastMessageURL)?.nilIfEmpty
                    ?? snapshot.lastAgentMessage.nilIfEmpty
                    ?? errorMessage
                    ?? summary
                let artifacts = finalizeArtifacts(
                    command.artifacts,
                    keepArtifacts: request.keepArtifacts,
                    state: state
                )
                await onProgress(.completed, summary)
                return ReviewProcessOutcome(
                    state: state,
                    exitCode: exitCode,
                    threadID: snapshot.threadID,
                    lastAgentMessage: snapshot.lastAgentMessage,
                    errorMessage: errorMessage,
                    summary: summary,
                    artifacts: artifacts,
                    startedAt: startedAt,
                    endedAt: endedAt,
                    content: content
                )
            }

            if let timeoutSeconds,
               Date().timeIntervalSince(startedAt) >= Double(timeoutSeconds)
            {
                cancellationReason = nil
                _ = await controller.terminateGracefully(grace: gracefulTerminationWait)
                let endedAt = Date()
                let content = readText(from: lastMessageURL)?.nilIfEmpty
                    ?? snapshot.lastAgentMessage.nilIfEmpty
                    ?? "Review timed out."
                let artifacts = finalizeArtifacts(
                    command.artifacts,
                    keepArtifacts: request.keepArtifacts,
                    state: .failed
                )
                await onProgress(.completed, "Review timed out.")
                return ReviewProcessOutcome(
                    state: .failed,
                    exitCode: (await controller.pollExitStatus()) ?? 124,
                    threadID: snapshot.threadID,
                    lastAgentMessage: snapshot.lastAgentMessage,
                    errorMessage: "Review timed out after \(timeoutSeconds) seconds.",
                    summary: "Review timed out after \(timeoutSeconds) seconds.",
                    artifacts: artifacts,
                    startedAt: startedAt,
                    endedAt: endedAt,
                    content: content
                )
            }

            if Task.isCancelled {
                let reason = cancellationReason ?? "Review cancelled."
                _ = await controller.terminateGracefully(grace: gracefulTerminationWait)
                let endedAt = Date()
                let content = readText(from: lastMessageURL)?.nilIfEmpty
                    ?? snapshot.lastAgentMessage.nilIfEmpty
                    ?? reason
                let artifacts = finalizeArtifacts(
                    command.artifacts,
                    keepArtifacts: request.keepArtifacts,
                    state: .cancelled
                )
                await onProgress(.completed, "Review cancelled.")
                return ReviewProcessOutcome(
                    state: .cancelled,
                    exitCode: (await controller.pollExitStatus()) ?? 130,
                    threadID: snapshot.threadID,
                    lastAgentMessage: snapshot.lastAgentMessage,
                    errorMessage: reason,
                    summary: "Review cancelled.",
                    artifacts: artifacts,
                    startedAt: startedAt,
                    endedAt: endedAt,
                    content: content
                )
            }

            try? await Task.sleep(for: pollInterval)
        }
    }

    private func cancelledOutcomeBeforeStart(
        command: ReviewCommand,
        request: ReviewRequestOptions,
        requestedTerminationReason: @escaping @Sendable () async -> ReviewTerminationReason?,
        onProgress: @escaping @Sendable (ReviewProgressStage, String?) async -> Void
    ) async -> ReviewProcessOutcome? {
        let cancellationReason: String?
        if Task.isCancelled {
            cancellationReason = "Review cancelled."
        } else if case .cancelled(let reason)? = await requestedTerminationReason() {
            cancellationReason = reason
        } else {
            cancellationReason = nil
        }
        guard let cancellationReason else {
            return nil
        }

        let startedAt = Date()
        let artifacts = finalizeArtifacts(
            command.artifacts,
            keepArtifacts: request.keepArtifacts,
            state: .cancelled
        )
        await onProgress(.completed, "Review cancelled.")
        return ReviewProcessOutcome(
            state: .cancelled,
            exitCode: 130,
            threadID: nil,
            lastAgentMessage: "",
            errorMessage: cancellationReason,
            summary: "Review cancelled.",
            artifacts: artifacts,
            startedAt: startedAt,
            endedAt: startedAt,
            content: cancellationReason
        )
    }
}

package actor ReviewProcessController {
    private let pid: pid_t
    private var cachedExitCode: Int?

    private init(pid: pid_t) {
        self.pid = pid
    }

    package static func start(command: ReviewCommand) throws -> ReviewProcessController {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: command.currentDirectory, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw ReviewError.spawnFailed("Working directory does not exist or is not a directory: \(command.currentDirectory)")
        }
        let executable = try resolveExecutable(for: command)
        let stdinFD = open("/dev/null", O_RDONLY)
        guard stdinFD >= 0 else {
            throw ReviewError.spawnFailed("Failed to open /dev/null for stdin.")
        }
        defer { close(stdinFD) }

        let stdoutFD = open(command.artifacts.eventsPath!, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard stdoutFD >= 0 else {
            throw ReviewError.spawnFailed("Failed to open events output file.")
        }
        defer { close(stdoutFD) }

        let stderrFD = open(command.artifacts.logPath!, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard stderrFD >= 0 else {
            throw ReviewError.spawnFailed("Failed to open log output file.")
        }
        defer { close(stderrFD) }

        var fileActions: posix_spawn_file_actions_t? = nil
        try throwOnPOSIX(posix_spawn_file_actions_init(&fileActions), context: "posix_spawn_file_actions_init")
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        try throwOnPOSIX(posix_spawn_file_actions_adddup2(&fileActions, stdinFD, STDIN_FILENO), context: "stdin dup2")
        try throwOnPOSIX(posix_spawn_file_actions_adddup2(&fileActions, stdoutFD, STDOUT_FILENO), context: "stdout dup2")
        try throwOnPOSIX(posix_spawn_file_actions_adddup2(&fileActions, stderrFD, STDERR_FILENO), context: "stderr dup2")
        try command.currentDirectory.withCString { path in
            if #available(macOS 26.0, *) {
                try throwOnPOSIX(posix_spawn_file_actions_addchdir(&fileActions, path), context: "chdir")
            } else {
                try throwOnPOSIX(posix_spawn_file_actions_addchdir_np(&fileActions, path), context: "chdir")
            }
        }

        var attributes: posix_spawnattr_t? = nil
        try throwOnPOSIX(posix_spawnattr_init(&attributes), context: "posix_spawnattr_init")
        defer { posix_spawnattr_destroy(&attributes) }

        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        sigaddset(&defaultSignals, SIGTERM)
        sigaddset(&defaultSignals, SIGINT)

        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF)
        try throwOnPOSIX(posix_spawnattr_setflags(&attributes, flags), context: "posix_spawnattr_setflags")
        try throwOnPOSIX(posix_spawnattr_setpgroup(&attributes, 0), context: "posix_spawnattr_setpgroup")
        try throwOnPOSIX(posix_spawnattr_setsigdefault(&attributes, &defaultSignals), context: "posix_spawnattr_setsigdefault")

        let argv = [executable] + command.arguments
        let envp = command.environment.map { "\($0.key)=\($0.value)" }

        let result = try withCStringArray(argv) { argvPointers in
            try withCStringArray(envp) { envPointers in
                var pid: pid_t = 0
                let status = executable.withCString { executablePointer in
                    posix_spawn(&pid, executablePointer, &fileActions, &attributes, argvPointers, envPointers)
                }
                try throwOnPOSIX(status, context: "posix_spawn")
                return pid
            }
        }

        return ReviewProcessController(pid: result)
    }

    package func pollExitStatus() -> Int? {
        if let cachedExitCode {
            return cachedExitCode
        }
        var status: Int32 = 0
        let waitResult = waitpid(pid, &status, WNOHANG)
        if waitResult == 0 {
            return nil
        }
        if waitResult == pid {
            let exitCode = normalizeWaitStatus(status)
            cachedExitCode = exitCode
            return exitCode
        }
        if waitResult == -1, errno == ECHILD {
            return cachedExitCode
        }
        return nil
    }

    package func waitForExit(timeout: Duration) async -> Int? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let exitCode = pollExitStatus() {
                return exitCode
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return pollExitStatus()
    }

    package func terminateGracefully(grace: Duration) async -> Bool {
        guard pollExitStatus() == nil else {
            return false
        }
        killpg(pid, SIGTERM)
        let deadline = ContinuousClock.now.advanced(by: grace)
        while ContinuousClock.now < deadline {
            if pollExitStatus() != nil {
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        killpg(pid, SIGKILL)
        _ = await waitForExit(timeout: .seconds(2))
        return true
    }
}

private func resolveExecutable(for command: ReviewCommand) throws -> String {
    if command.executable.contains("/") {
        return command.executable
    }

    guard let resolved = resolveCodexCommand(
        requestedCommand: command.executable,
        environment: command.environment,
        currentDirectory: command.currentDirectory
    ) else {
        throw ReviewError.spawnFailed(
            "Unable to locate \(command.executable) executable. Set --codex-command or ensure PATH contains \(command.executable)."
        )
    }
    return resolved
}

private func normalizeWaitStatus(_ status: Int32) -> Int {
    if wifsignaled(status) {
        return 128 + Int(wtermsig(status))
    }
    if wifexited(status) {
        return Int(wexitstatus(status))
    }
    return Int(status)
}

private func throwOnPOSIX(_ result: Int32, context: String) throws {
    guard result == 0 else {
        let message = String(cString: strerror(result))
        throw ReviewError.spawnFailed("\(context): \(message)")
    }
}

private func withCStringArray<Result>(
    _ values: [String],
    body: ([UnsafeMutablePointer<CChar>?]) throws -> Result
) throws -> Result {
    var pointers: [UnsafeMutablePointer<CChar>?] = values.map { strdup($0) }
    pointers.append(nil)
    defer {
        for pointer in pointers where pointer != nil {
            free(pointer)
        }
    }
    return try body(pointers)
}

private func wifexited(_ status: Int32) -> Bool {
    (status & 0x7f) == 0
}

private func wexitstatus(_ status: Int32) -> Int32 {
    (status >> 8) & 0xff
}

private func wifsignaled(_ status: Int32) -> Bool {
    let signal = status & 0x7f
    return signal != 0 && signal != 0x7f
}

private func wtermsig(_ status: Int32) -> Int32 {
    status & 0x7f
}

private func readText(from url: URL) -> String? {
    try? String(contentsOf: url, encoding: .utf8)
}

private func finalizeArtifacts(
    _ artifacts: ReviewArtifacts,
    keepArtifacts: Bool,
    state: ReviewJobState
) -> ReviewArtifacts {
    guard state == .succeeded, keepArtifacts == false else {
        return artifacts
    }
    for path in [artifacts.eventsPath, artifacts.logPath, artifacts.lastMessagePath].compactMap({ $0 }) {
        try? FileManager.default.removeItem(atPath: path)
    }
    return ReviewArtifacts(eventsPath: nil, logPath: nil, lastMessagePath: nil)
}
