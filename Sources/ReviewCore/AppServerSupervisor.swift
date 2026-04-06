import Darwin
import Foundation
import ReviewJobs

package protocol AppServerManaging: Sendable {
    func prepare() async throws -> AppServerRuntimeState
    func checkoutTransport(sessionID: String) async throws -> any AppServerSessionTransport
    func checkoutAuthTransport() async throws -> any AppServerSessionTransport
    func currentRuntimeState() async -> AppServerRuntimeState?
    func diagnosticLineStream() async -> AsyncStreamSubscription<String>
    func diagnosticsTail() async -> String
    func shutdown() async
}

package actor AppServerSupervisor: AppServerManaging {
    package struct Configuration: Sendable {
        package var codexCommand: String
        package var environment: [String: String]
        package var startupTimeout: Duration

        package init(
            codexCommand: String = "codex",
            environment: [String: String] = ProcessInfo.processInfo.environment,
            startupTimeout: Duration = .seconds(30)
        ) {
            self.codexCommand = codexCommand
            self.environment = environment
            self.startupTimeout = startupTimeout
        }
    }

    private final class StartContext: @unchecked Sendable {
        let launchID: UUID
        let processIdentity: ProcessIdentity
        let processGroupIdentity: ProcessIdentity
        let runtimeState: AppServerRuntimeState
        let stdinPipe: Pipe
        let stdoutPipe: Pipe
        let stderrPipe: Pipe
        let connection: AppServerSharedTransportConnection
        let waitTask: Task<Void, Never>
        let stdoutTask: Task<Void, Never>
        let stderrTask: Task<Void, Never>
        let dedicatedProcessGroupEstablished: Bool
        var startupTask: Task<Void, Never>?

        init(
            launchID: UUID,
            processIdentity: ProcessIdentity,
            processGroupIdentity: ProcessIdentity,
            runtimeState: AppServerRuntimeState,
            stdinPipe: Pipe,
            stdoutPipe: Pipe,
            stderrPipe: Pipe,
            connection: AppServerSharedTransportConnection,
            waitTask: Task<Void, Never>,
            stdoutTask: Task<Void, Never>,
            stderrTask: Task<Void, Never>,
            dedicatedProcessGroupEstablished: Bool
        ) {
            self.launchID = launchID
            self.processIdentity = processIdentity
            self.processGroupIdentity = processGroupIdentity
            self.runtimeState = runtimeState
            self.stdinPipe = stdinPipe
            self.stdoutPipe = stdoutPipe
            self.stderrPipe = stderrPipe
            self.connection = connection
            self.waitTask = waitTask
            self.stdoutTask = stdoutTask
            self.stderrTask = stderrTask
            self.dedicatedProcessGroupEstablished = dedicatedProcessGroupEstablished
        }
    }

    private final class LaunchContext: @unchecked Sendable {
        let launchID: UUID
        var launchTask: Task<Void, Never>?

        init(launchID: UUID) {
            self.launchID = launchID
        }
    }

    private final class RuntimeContext: @unchecked Sendable {
        let launchID: UUID
        let processIdentity: ProcessIdentity
        let processGroupIdentity: ProcessIdentity
        let runtimeState: AppServerRuntimeState
        let connection: AppServerSharedTransportConnection
        let waitTask: Task<Void, Never>
        let stdoutTask: Task<Void, Never>
        let stderrTask: Task<Void, Never>
        let dedicatedProcessGroupEstablished: Bool
        var exitMonitorTask: Task<Void, Never>?

        init(startContext: StartContext) {
            self.launchID = startContext.launchID
            self.processIdentity = startContext.processIdentity
            self.processGroupIdentity = startContext.processGroupIdentity
            self.runtimeState = startContext.runtimeState
            self.connection = startContext.connection
            self.waitTask = startContext.waitTask
            self.stdoutTask = startContext.stdoutTask
            self.stderrTask = startContext.stderrTask
            self.dedicatedProcessGroupEstablished = startContext.dedicatedProcessGroupEstablished
        }
    }

    private enum State {
        case stopped
        case launching(LaunchContext, [CheckedContinuation<RuntimeContext, Error>])
        case starting(StartContext, [CheckedContinuation<RuntimeContext, Error>])
        case running(RuntimeContext)
    }

    private let configuration: Configuration
    private var state: State = .stopped
    private var stderrLines: [String] = []
    private var diagnosticTailLines: [String] = []
    private var pendingStandardErrorBytes = Data()
    private var trailingStandardErrorFragment = ""
    private var diagnosticSubscribers: [UUID: AsyncStream<String>.Continuation] = [:]

    package init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    package func prepare() async throws -> AppServerRuntimeState {
        try await ensureRunning().runtimeState
    }

    package func checkoutTransport(sessionID _: String) async throws -> any AppServerSessionTransport {
        let runtimeContext = try await ensureRunning()
        return await runtimeContext.connection.checkoutTransport()
    }

    package func checkoutAuthTransport() async throws -> any AppServerSessionTransport {
        let runtimeContext = try await ensureRunning()
        return await runtimeContext.connection.checkoutTransport()
    }

    package func currentRuntimeState() async -> AppServerRuntimeState? {
        switch state {
        case .running(let runtimeContext):
            return runtimeContext.runtimeState
        case .stopped, .launching, .starting:
            return nil
        }
    }

    package func diagnosticLineStream() async -> AsyncStreamSubscription<String> {
        var continuation: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String>(bufferingPolicy: .unbounded) {
            continuation = $0
        }
        let subscriberID = UUID()
        diagnosticSubscribers[subscriberID] = continuation
        continuation.onTermination = { _ in
            Task {
                await self.removeDiagnosticSubscriber(id: subscriberID)
            }
        }
        return .init(
            stream: stream,
            cancel: { [weak self] in
                await self?.cancelDiagnosticSubscriber(id: subscriberID)
            }
        )
    }

    package func diagnosticsTail() async -> String {
        diagnosticTailLines.suffix(100).joined(separator: "\n")
    }

    package func shutdown() async {
        switch state {
        case .running(let runtimeContext):
            state = .stopped
            finishDiagnosticSubscribers()
            await terminateRuntimeContext(runtimeContext)
            await runtimeContext.exitMonitorTask?.value
        case .launching(let launchContext, let waiters):
            state = .stopped
            finishDiagnosticSubscribers()
            await launchContext.launchTask?.value
            let error = ReviewError.io("app-server supervisor stopped during startup.")
            for continuation in waiters {
                continuation.resume(throwing: error)
            }
        case .starting(let startContext, let waiters):
            state = .stopped
            finishDiagnosticSubscribers()
            startContext.startupTask?.cancel()
            await startContext.connection.shutdown()
            await terminateStartContext(startContext)
            let error = ReviewError.io("app-server supervisor stopped during startup.")
            for continuation in waiters {
                continuation.resume(throwing: error)
            }
            await startContext.startupTask?.value
        case .stopped:
            finishDiagnosticSubscribers()
        }
    }

    private func ensureRunning() async throws -> RuntimeContext {
        switch state {
        case .running(let runtimeContext):
            if isMatchingProcessIdentity(runtimeContext.processIdentity),
               await runtimeContext.connection.isClosed() == false
            {
                return runtimeContext
            }
            state = .stopped
            finishDiagnosticSubscribers()
            await terminateRuntimeContext(runtimeContext)
            await runtimeContext.exitMonitorTask?.value
            return try await ensureRunning()
        case .launching, .starting:
            return try await waitForRunning()
        case .stopped:
            resetDiagnostics()
            let launchContext = LaunchContext(launchID: UUID())
            state = .launching(launchContext, [])
            launchContext.launchTask = Task.detached { [weak self] in
                guard let self else {
                    return
                }
                await self.beginLaunch(for: launchContext)
            }
            return try await waitForRunning()
        }
    }

    private func waitForRunning() async throws -> RuntimeContext {
        try await withCheckedThrowingContinuation { continuation in
            switch state {
            case .running(let runtimeContext):
                continuation.resume(returning: runtimeContext)
            case .launching(let launchContext, var waiters):
                waiters.append(continuation)
                state = .launching(launchContext, waiters)
            case .starting(let startContext, var waiters):
                waiters.append(continuation)
                state = .starting(startContext, waiters)
            case .stopped:
                continuation.resume(throwing: ReviewError.io("app-server supervisor is stopped."))
            }
        }
    }

    private func beginLaunch(for launchContext: LaunchContext) async {
        do {
            let startContext = try await makeStartContext(launchID: launchContext.launchID)
            guard case .launching(let currentLaunchContext, let waiters) = state,
                  currentLaunchContext.launchID == launchContext.launchID
            else {
                await startContext.connection.shutdown()
                await terminateStartContext(startContext)
                return
            }

            state = .starting(startContext, waiters)
            let startupTask = Task.detached { [weak self] in
                guard let self else {
                    return
                }
                await self.completeStartup(for: startContext)
            }
            startContext.startupTask = startupTask
        } catch {
            guard case .launching(let currentLaunchContext, let waiters) = state,
                  currentLaunchContext.launchID == launchContext.launchID
            else {
                return
            }

            state = .stopped
            for continuation in waiters {
                continuation.resume(throwing: error)
            }
        }
    }

    private func completeStartup(for startContext: StartContext) async {
        do {
            try await waitUntilInitialized(
                connection: startContext.connection,
                processIdentity: startContext.processIdentity
            )
            try validateDedicatedProcessGroup(for: startContext)

            let runtimeContext = RuntimeContext(startContext: startContext)
            guard transitionToRunning(
                startContext: startContext,
                runtimeContext: runtimeContext
            ) else {
                await runtimeContext.connection.shutdown()
                await terminateRuntimeContext(runtimeContext)
                return
            }

            let exitMonitorTask = Task { [weak self] in
                guard let self else {
                    return
                }
                await self.monitorRuntimeExit(for: runtimeContext)
            }
            runtimeContext.exitMonitorTask = exitMonitorTask
        } catch {
            await failStartup(for: startContext, error: error)
        }
    }

    private func transitionToRunning(
        startContext: StartContext,
        runtimeContext: RuntimeContext
    ) -> Bool {
        guard case .starting(let currentContext, let waiters) = state,
              currentContext.launchID == startContext.launchID
        else {
            return false
        }

        state = .running(runtimeContext)
        for continuation in waiters {
            continuation.resume(returning: runtimeContext)
        }
        return true
    }

    private func failStartup(for startContext: StartContext, error: Error) async {
        guard case .starting(let currentContext, let waiters) = state,
              currentContext.launchID == startContext.launchID
        else {
            return
        }

        state = .stopped
        finishDiagnosticSubscribers()
        await startContext.connection.shutdown()
        await terminateStartContext(startContext)
        for continuation in waiters {
            continuation.resume(throwing: error)
        }
    }

    private func monitorRuntimeExit(for runtimeContext: RuntimeContext) async {
        _ = await runtimeContext.waitTask.result
        _ = await runtimeContext.stdoutTask.value
        _ = await runtimeContext.stderrTask.value
        await handleRuntimeExit(runtimeContext)
    }

    private func handleRuntimeExit(_ runtimeContext: RuntimeContext) async {
        if case .running(let currentContext) = state,
           currentContext.launchID == runtimeContext.launchID
        {
            state = .stopped
            finishDiagnosticSubscribers()
        }
        await runtimeContext.connection.shutdown()
    }

    private func makeStartContext(launchID: UUID) async throws -> StartContext {
        try ReviewHomePaths.ensureReviewHomeScaffold(environment: configuration.environment)
        // Intentionally use ~/.codex_review directly for app-server.
        // We no longer create a per-launch isolated CODEX_HOME or strip codex_review from config.
        let codexHomeURL = ReviewHomePaths.codexHomeURL(
            environment: configuration.environment
        )

        let launchCommand = try makeAppServerLaunchCommand(
            codexCommand: configuration.codexCommand,
            environment: configuration.environment,
            codexHomeURL: codexHomeURL
        )
        let spawnedProcess = try spawnAppServerProcess(launchCommand)
        let pid = spawnedProcess.pid

        guard let startTime = processStartTime(of: pid) else {
            await terminateSpawnedProcessWithoutIdentity(pid: pid)
            throw ReviewError.spawnFailed("app-server started without a readable process start time.")
        }

        let processIdentity = ProcessIdentity(pid: pid, startTime: startTime)
        guard currentProcessGroupID(of: pid) == pid else {
            await terminateFailedSpawnedProcess(
                processIdentity: processIdentity,
                processGroupLeaderPID: pid,
                signalDedicatedProcessGroup: false
            )
            throw ReviewError.spawnFailed("app-server did not enter its dedicated process group.")
        }

        let waitTask = Task.detached { @Sendable in
            reapSpawnedProcess(pid: pid)
        }
        let runtimeState = AppServerRuntimeState(
            pid: Int(pid),
            startTime: startTime,
            processGroupLeaderPID: Int(pid),
            processGroupLeaderStartTime: startTime
        )
        let processGroupIdentity = ProcessIdentity(pid: pid, startTime: startTime)
        let connection = AppServerSharedTransportConnection(
            sendMessage: { message in
                guard let data = message.data(using: .utf8) else {
                    throw ReviewError.io("failed to encode stdio payload as UTF-8.")
                }
                try spawnedProcess.stdinPipe.fileHandleForWriting.write(contentsOf: data)
            },
            closeInput: {
                try? spawnedProcess.stdinPipe.fileHandleForWriting.close()
            }
        )
        let stdoutTask = startCapturingStandardOutput(
            handle: spawnedProcess.stdoutPipe.fileHandleForReading,
            connection: connection
        )
        let stderrTask = startCapturingStandardError(
            handle: spawnedProcess.stderrPipe.fileHandleForReading
        )

        return StartContext(
            launchID: launchID,
            processIdentity: processIdentity,
            processGroupIdentity: processGroupIdentity,
            runtimeState: runtimeState,
            stdinPipe: spawnedProcess.stdinPipe,
            stdoutPipe: spawnedProcess.stdoutPipe,
            stderrPipe: spawnedProcess.stderrPipe,
            connection: connection,
            waitTask: waitTask,
            stdoutTask: stdoutTask,
            stderrTask: stderrTask,
            dedicatedProcessGroupEstablished: true
        )
    }

    private func startCapturingStandardOutput(
        handle: FileHandle,
        connection: AppServerSharedTransportConnection
    ) -> Task<Void, Never> {
        Task.detached { [weak self] in
            var trailingFragment = ""
            while true {
                let data = handle.availableData
                if data.isEmpty {
                    break
                }

                let chunk = String(decoding: data, as: UTF8.self)
                let split = splitStandardErrorChunk(
                    existingFragment: trailingFragment,
                    chunk: chunk
                )
                trailingFragment = split.trailingFragment
                if split.completeLines.isEmpty == false {
                    await self?.appendStandardOutputLines(split.completeLines)
                }
                await connection.receive(data)
            }

            if trailingFragment.isEmpty == false {
                await self?.appendStandardOutputLines([trailingFragment])
            }
            await connection.finishReceiving(error: nil)
        }
    }

    private func startCapturingStandardError(handle: FileHandle) -> Task<Void, Never> {
        Task.detached { [weak self] in
            while true {
                let data = handle.availableData
                if data.isEmpty {
                    break
                }
                await self?.appendStandardErrorData(data)
            }
            await self?.flushStandardErrorFragment()
        }
    }

    private func appendStandardErrorData(_ data: Data) {
        pendingStandardErrorBytes.append(data)

        for trailingCount in 0 ... min(3, pendingStandardErrorBytes.count) {
            let candidateCount = pendingStandardErrorBytes.count - trailingCount
            let candidate = pendingStandardErrorBytes.prefix(candidateCount)
            guard let text = String(data: candidate, encoding: .utf8) else {
                continue
            }

            pendingStandardErrorBytes = Data(pendingStandardErrorBytes.suffix(trailingCount))
            appendStandardErrorChunk(text)
            return
        }

        let text = String(decoding: pendingStandardErrorBytes, as: UTF8.self)
        pendingStandardErrorBytes.removeAll(keepingCapacity: false)
        appendStandardErrorChunk(text)
    }

    private func appendStandardErrorChunk(_ chunk: String) {
        let split = splitStandardErrorChunk(
            existingFragment: trailingStandardErrorFragment,
            chunk: chunk
        )
        trailingStandardErrorFragment = split.trailingFragment
        appendStandardErrorLines(split.completeLines)
    }

    private func flushStandardErrorFragment() {
        if pendingStandardErrorBytes.isEmpty == false {
            let text = String(decoding: pendingStandardErrorBytes, as: UTF8.self)
            pendingStandardErrorBytes.removeAll(keepingCapacity: false)
            appendStandardErrorChunk(text)
        }
        guard trailingStandardErrorFragment.isEmpty == false else {
            return
        }
        let fragment = trailingStandardErrorFragment
        trailingStandardErrorFragment = ""
        appendStandardErrorLines([fragment])
    }

    private func appendStandardErrorLines(_ lines: [String]) {
        stderrLines.append(contentsOf: lines)
        for line in lines {
            for continuation in diagnosticSubscribers.values {
                continuation.yield(line)
            }
        }
        appendDiagnosticTailLines(lines.map { "stderr: \($0)" })
        if stderrLines.count > 200 {
            stderrLines.removeFirst(stderrLines.count - 200)
        }
    }

    private func appendStandardOutputLines(_ lines: [String]) {
        let normalizedLines = lines.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { $0.isEmpty == false }
        guard normalizedLines.isEmpty == false else {
            return
        }
        appendDiagnosticTailLines(normalizedLines.map { "stdout: \($0)" })
    }

    private func appendDiagnosticTailLines(_ lines: [String]) {
        diagnosticTailLines.append(contentsOf: lines)
        if diagnosticTailLines.count > 200 {
            diagnosticTailLines.removeFirst(diagnosticTailLines.count - 200)
        }
    }

    private func waitUntilInitialized(
        connection: AppServerSharedTransportConnection,
        processIdentity: ProcessIdentity
    ) async throws {
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    _ = try await connection.initialize(
                        clientName: codexReviewMCPName,
                        clientTitle: "Codex Review MCP",
                        clientVersion: codexReviewMCPVersion
                    )
                }
                group.addTask {
                    try await Task.sleep(for: self.configuration.startupTimeout)
                    throw ReviewError.spawnFailed("timed out waiting for app-server initialization.")
                }
                defer { group.cancelAll() }
                _ = try await group.next()
            }
        } catch let error as ReviewError {
            if isMatchingProcessIdentity(processIdentity) == false {
                let diagnostics = await diagnosticsTail()
                let suffix = diagnostics.nilIfEmpty.map { ": \($0)" } ?? ""
                throw ReviewError.spawnFailed("app-server exited before becoming ready\(suffix)")
            }
            throw error
        } catch {
            if isMatchingProcessIdentity(processIdentity) == false {
                let diagnostics = await diagnosticsTail()
                let suffix = diagnostics.nilIfEmpty.map { ": \($0)" } ?? ""
                throw ReviewError.spawnFailed("app-server exited before becoming ready\(suffix)")
            }
            throw ReviewError.spawnFailed(error.localizedDescription)
        }
    }

    private func resetDiagnostics() {
        stderrLines.removeAll(keepingCapacity: false)
        diagnosticTailLines.removeAll(keepingCapacity: false)
        pendingStandardErrorBytes.removeAll(keepingCapacity: false)
        trailingStandardErrorFragment = ""
    }

    private func validateDedicatedProcessGroup(for startContext: StartContext) throws {
        guard isMatchingProcessIdentity(startContext.processIdentity),
              currentProcessGroupID(of: startContext.processIdentity.pid) == startContext.processGroupIdentity.pid
        else {
            throw ReviewError.spawnFailed("app-server did not remain in its dedicated process group.")
        }
    }

    private func finishDiagnosticSubscribers() {
        let continuations = diagnosticSubscribers.values
        diagnosticSubscribers.removeAll()
        for continuation in continuations {
            continuation.finish()
        }
    }

    private func removeDiagnosticSubscriber(id: UUID) {
        diagnosticSubscribers[id] = nil
    }

    private func cancelDiagnosticSubscriber(id: UUID) {
        guard let continuation = diagnosticSubscribers.removeValue(forKey: id) else {
            return
        }
        continuation.finish()
    }

    private func terminateStartContext(_ startContext: StartContext) async {
        await terminateManagedRuntime(
            processIdentity: startContext.processIdentity,
            processGroupIdentity: startContext.processGroupIdentity,
            signalDedicatedProcessGroup: startContext.dedicatedProcessGroupEstablished,
            connection: startContext.connection,
            waitTask: startContext.waitTask,
            stdoutTask: startContext.stdoutTask,
            stderrTask: startContext.stderrTask
        )
    }

    private func terminateRuntimeContext(_ runtimeContext: RuntimeContext) async {
        await terminateManagedRuntime(
            processIdentity: runtimeContext.processIdentity,
            processGroupIdentity: runtimeContext.processGroupIdentity,
            signalDedicatedProcessGroup: runtimeContext.dedicatedProcessGroupEstablished,
            connection: runtimeContext.connection,
            waitTask: runtimeContext.waitTask,
            stdoutTask: runtimeContext.stdoutTask,
            stderrTask: runtimeContext.stderrTask
        )
    }
}

package func splitStandardErrorChunk(
    existingFragment: String,
    chunk: String
) -> (completeLines: [String], trailingFragment: String) {
    let combined = existingFragment + chunk
    let segments = combined.split(
        omittingEmptySubsequences: false,
        whereSeparator: \.isNewline
    ).map(String.init)

    if combined.last?.isNewline == true {
        return (segments, "")
    }

    return (Array(segments.dropLast()), segments.last ?? combined)
}

private struct AppServerLaunchCommand {
    var executable: String
    var arguments: [String]
    var environment: [String: String]
}

private struct SpawnedAppServerProcess {
    var pid: pid_t
    var stdinPipe: Pipe
    var stdoutPipe: Pipe
    var stderrPipe: Pipe
}

private func makeAppServerLaunchCommand(
    codexCommand: String,
    environment: [String: String],
    codexHomeURL: URL
) throws -> AppServerLaunchCommand {
    guard let resolvedExecutable = resolveCodexCommand(
        requestedCommand: codexCommand,
        environment: environment,
        currentDirectory: FileManager.default.currentDirectoryPath
    ) else {
        throw ReviewError.spawnFailed(
            "Unable to locate \(codexCommand) executable. Set --codex-command or ensure PATH contains \(codexCommand)."
        )
    }

    var effectiveEnvironment = environment
    effectiveEnvironment["CODEX_HOME"] = codexHomeURL.path

    return AppServerLaunchCommand(
        executable: resolvedExecutable,
        arguments: reviewMCPCodexCommandArguments([
            "app-server",
            "--listen", "stdio://"
        ]),
        environment: effectiveEnvironment
    )
}

private func spawnAppServerProcess(
    _ command: AppServerLaunchCommand
) throws -> SpawnedAppServerProcess {
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()

    var fileActions: posix_spawn_file_actions_t? = nil
    guard posix_spawn_file_actions_init(&fileActions) == 0 else {
        throw ReviewError.spawnFailed("failed to initialize app-server spawn file actions.")
    }
    defer { posix_spawn_file_actions_destroy(&fileActions) }

    let stdinReadFD = stdinPipe.fileHandleForReading.fileDescriptor
    let stdinWriteFD = stdinPipe.fileHandleForWriting.fileDescriptor
    let stdoutReadFD = stdoutPipe.fileHandleForReading.fileDescriptor
    let stdoutWriteFD = stdoutPipe.fileHandleForWriting.fileDescriptor
    let stderrReadFD = stderrPipe.fileHandleForReading.fileDescriptor
    let stderrWriteFD = stderrPipe.fileHandleForWriting.fileDescriptor

    for fileDescriptor in [stdinWriteFD, stdoutReadFD, stderrReadFD] {
        guard posix_spawn_file_actions_addclose(&fileActions, fileDescriptor) == 0 else {
            throw ReviewError.spawnFailed("failed to configure app-server stdio cleanup.")
        }
    }

    for (source, destination) in [
        (stdinReadFD, STDIN_FILENO),
        (stdoutWriteFD, STDOUT_FILENO),
        (stderrWriteFD, STDERR_FILENO),
    ] where source != destination {
        guard posix_spawn_file_actions_adddup2(&fileActions, source, destination) == 0 else {
            throw ReviewError.spawnFailed("failed to configure app-server stdio redirection.")
        }
        guard posix_spawn_file_actions_addclose(&fileActions, source) == 0 else {
            throw ReviewError.spawnFailed("failed to configure app-server stdio source cleanup.")
        }
    }

    var spawnAttributes: posix_spawnattr_t? = nil
    guard posix_spawnattr_init(&spawnAttributes) == 0 else {
        throw ReviewError.spawnFailed("failed to initialize app-server spawn attributes.")
    }
    defer { posix_spawnattr_destroy(&spawnAttributes) }

    let spawnFlags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
    guard posix_spawnattr_setflags(&spawnAttributes, spawnFlags) == 0,
          posix_spawnattr_setpgroup(&spawnAttributes, 0) == 0
    else {
        throw ReviewError.spawnFailed("failed to configure app-server process group.")
    }

    let argv = try allocateCStringArray([command.executable] + command.arguments)
    let envp = try allocateCStringArray(command.environment.map { "\($0.key)=\($0.value)" })
    defer {
        for pointer in argv where pointer != nil {
            free(pointer)
        }
        for pointer in envp where pointer != nil {
            free(pointer)
        }
    }

    var pid: pid_t = 0
    let spawnStatus = posix_spawn(
        &pid,
        command.executable,
        &fileActions,
        &spawnAttributes,
        argv,
        envp
    )
    guard spawnStatus == 0 else {
        let message = String(cString: strerror(spawnStatus))
        throw ReviewError.spawnFailed("failed to start app-server: \(message)")
    }

    try? stdinPipe.fileHandleForReading.close()
    try? stdoutPipe.fileHandleForWriting.close()
    try? stderrPipe.fileHandleForWriting.close()

    return SpawnedAppServerProcess(
        pid: pid,
        stdinPipe: stdinPipe,
        stdoutPipe: stdoutPipe,
        stderrPipe: stderrPipe
    )
}

private func terminateManagedRuntime(
    processIdentity: ProcessIdentity,
    processGroupIdentity: ProcessIdentity,
    signalDedicatedProcessGroup: Bool,
    connection: AppServerSharedTransportConnection,
    waitTask: Task<Void, Never>,
    stdoutTask: Task<Void, Never>,
    stderrTask: Task<Void, Never>
) async {
    await connection.shutdown()
    let excludedGroupLeaderPIDs = trackedGroupExclusionSet(
        processIdentity: processIdentity,
        processGroupIdentity: processGroupIdentity,
        signalDedicatedProcessGroup: signalDedicatedProcessGroup
    )
    let individuallyTrackedGroupLeaderPID = individuallyTrackedProcessGroupLeaderPID(
        processIdentity: processIdentity,
        processGroupIdentity: processGroupIdentity,
        signalDedicatedProcessGroup: signalDedicatedProcessGroup
    )
    var trackedChildGroupIdentities = descendantProcessGroupIdentities(
        rootIdentity: processIdentity,
        excludingGroupLeaderPIDs: excludedGroupLeaderPIDs
    )
    var trackedExcludedGroupProcessIdentities = individuallyTrackedGroupLeaderPID.map {
        descendantProcessIdentities(rootIdentity: processIdentity, inProcessGroup: $0)
    } ?? []
    signalManagedRuntime(
        processIdentity: processIdentity,
        processGroupLeaderPID: processGroupIdentity.pid,
        signalDedicatedProcessGroup: signalDedicatedProcessGroup,
        signal: SIGTERM
    )
    signalTrackedProcessGroups(trackedChildGroupIdentities, signal: SIGTERM)
    signalTrackedProcesses(trackedExcludedGroupProcessIdentities, signal: SIGTERM)

    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while ContinuousClock.now < deadline {
        trackedChildGroupIdentities = mergeProcessIdentities(
            trackedChildGroupIdentities,
            descendantProcessGroupIdentities(
                rootIdentity: processIdentity,
                excludingGroupLeaderPIDs: excludedGroupLeaderPIDs
            )
        )
        if let individuallyTrackedGroupLeaderPID {
            trackedExcludedGroupProcessIdentities = mergeProcessIdentities(
                trackedExcludedGroupProcessIdentities,
                descendantProcessIdentities(
                    rootIdentity: processIdentity,
                    inProcessGroup: individuallyTrackedGroupLeaderPID
                )
            )
        }
        if managedRuntimeStopped(
            processIdentity: processIdentity,
            processGroupLeaderPID: processGroupIdentity.pid,
            signalDedicatedProcessGroup: signalDedicatedProcessGroup
        ) && hasLiveTrackedProcessGroups(trackedChildGroupIdentities) == false
            && hasLiveTrackedProcesses(trackedExcludedGroupProcessIdentities) == false
        {
            break
        }
        signalTrackedProcessGroups(trackedChildGroupIdentities, signal: SIGTERM)
        signalTrackedProcesses(trackedExcludedGroupProcessIdentities, signal: SIGTERM)
        try? await Task.sleep(for: .milliseconds(100))
    }

    trackedChildGroupIdentities = mergeProcessIdentities(
        trackedChildGroupIdentities,
        descendantProcessGroupIdentities(
            rootIdentity: processIdentity,
            excludingGroupLeaderPIDs: excludedGroupLeaderPIDs
        )
    )
    if let individuallyTrackedGroupLeaderPID {
        trackedExcludedGroupProcessIdentities = mergeProcessIdentities(
            trackedExcludedGroupProcessIdentities,
            descendantProcessIdentities(
                rootIdentity: processIdentity,
                inProcessGroup: individuallyTrackedGroupLeaderPID
            )
        )
    }
    if managedRuntimeStopped(
        processIdentity: processIdentity,
        processGroupLeaderPID: processGroupIdentity.pid,
        signalDedicatedProcessGroup: signalDedicatedProcessGroup
    ) == false
        || hasLiveTrackedProcessGroups(trackedChildGroupIdentities)
        || hasLiveTrackedProcesses(trackedExcludedGroupProcessIdentities)
    {
        signalManagedRuntime(
            processIdentity: processIdentity,
            processGroupLeaderPID: processGroupIdentity.pid,
            signalDedicatedProcessGroup: signalDedicatedProcessGroup,
            signal: SIGKILL
        )
        signalTrackedProcessGroups(trackedChildGroupIdentities, signal: SIGKILL)
        signalTrackedProcesses(trackedExcludedGroupProcessIdentities, signal: SIGKILL)
    }

    _ = await waitTask.result
    _ = await stdoutTask.value
    _ = await stderrTask.value
}

private func terminateFailedSpawnedProcess(
    processIdentity: ProcessIdentity,
    processGroupLeaderPID: pid_t,
    signalDedicatedProcessGroup: Bool
) async {
    let excludedGroupLeaderPIDs: Set<pid_t> =
        signalDedicatedProcessGroup && processGroupLeaderPID > 0 ? [processGroupLeaderPID] : []
    let individuallyTrackedGroupLeaderPID = currentProcessGroupID(of: processIdentity.pid)
    var trackedChildGroupIdentities = descendantProcessGroupIdentities(
        rootIdentity: processIdentity,
        excludingGroupLeaderPIDs: excludedGroupLeaderPIDs
    )
    var trackedExcludedGroupProcessIdentities = individuallyTrackedGroupLeaderPID.map {
        descendantProcessIdentities(rootIdentity: processIdentity, inProcessGroup: $0)
    } ?? []
    signalManagedRuntime(
        processIdentity: processIdentity,
        processGroupLeaderPID: processGroupLeaderPID,
        signalDedicatedProcessGroup: signalDedicatedProcessGroup,
        signal: SIGTERM
    )
    signalTrackedProcessGroups(trackedChildGroupIdentities, signal: SIGTERM)
    signalTrackedProcesses(trackedExcludedGroupProcessIdentities, signal: SIGTERM)

    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while ContinuousClock.now < deadline {
        trackedChildGroupIdentities = mergeProcessIdentities(
            trackedChildGroupIdentities,
            descendantProcessGroupIdentities(
                rootIdentity: processIdentity,
                excludingGroupLeaderPIDs: excludedGroupLeaderPIDs
            )
        )
        if let individuallyTrackedGroupLeaderPID {
            trackedExcludedGroupProcessIdentities = mergeProcessIdentities(
                trackedExcludedGroupProcessIdentities,
                descendantProcessIdentities(
                    rootIdentity: processIdentity,
                    inProcessGroup: individuallyTrackedGroupLeaderPID
                )
            )
        }
        let result = waitpid(processIdentity.pid, nil, WNOHANG)
        if (result == processIdentity.pid || (result == -1 && errno == ECHILD)),
           hasLiveTrackedProcessGroups(trackedChildGroupIdentities) == false,
           hasLiveTrackedProcesses(trackedExcludedGroupProcessIdentities) == false
        {
            return
        }
        signalTrackedProcessGroups(trackedChildGroupIdentities, signal: SIGTERM)
        signalTrackedProcesses(trackedExcludedGroupProcessIdentities, signal: SIGTERM)
        try? await Task.sleep(for: .milliseconds(100))
    }

    trackedChildGroupIdentities = mergeProcessIdentities(
        trackedChildGroupIdentities,
        descendantProcessGroupIdentities(
            rootIdentity: processIdentity,
            excludingGroupLeaderPIDs: excludedGroupLeaderPIDs
        )
    )
    if let individuallyTrackedGroupLeaderPID {
        trackedExcludedGroupProcessIdentities = mergeProcessIdentities(
            trackedExcludedGroupProcessIdentities,
            descendantProcessIdentities(
                rootIdentity: processIdentity,
                inProcessGroup: individuallyTrackedGroupLeaderPID
            )
        )
    }
    signalManagedRuntime(
        processIdentity: processIdentity,
        processGroupLeaderPID: processGroupLeaderPID,
        signalDedicatedProcessGroup: signalDedicatedProcessGroup,
        signal: SIGKILL
    )
    signalTrackedProcessGroups(trackedChildGroupIdentities, signal: SIGKILL)
    signalTrackedProcesses(trackedExcludedGroupProcessIdentities, signal: SIGKILL)
    reapSpawnedProcess(pid: processIdentity.pid)
}

private func signalManagedRuntime(
    processIdentity: ProcessIdentity,
    processGroupLeaderPID: pid_t,
    signalDedicatedProcessGroup: Bool,
    signal: Int32
) {
    if isMatchingProcessIdentity(processIdentity) {
        _ = kill(processIdentity.pid, signal)
    }
    if signalDedicatedProcessGroup, processGroupLeaderPID > 0 {
        _ = killpg(processGroupLeaderPID, signal)
    }
}

private func managedRuntimeStopped(
    processIdentity: ProcessIdentity,
    processGroupLeaderPID: pid_t,
    signalDedicatedProcessGroup: Bool
) -> Bool {
    let processStopped = isMatchingProcessIdentity(processIdentity) == false
    guard signalDedicatedProcessGroup else {
        return processStopped
    }
    return processStopped && isProcessGroupGone(processGroupLeaderPID)
}

private func trackedGroupExclusionSet(
    processIdentity: ProcessIdentity,
    processGroupIdentity: ProcessIdentity,
    signalDedicatedProcessGroup: Bool
) -> Set<pid_t> {
    var excluded: Set<pid_t> = []
    if signalDedicatedProcessGroup {
        excluded.insert(processGroupIdentity.pid)
    }
    if let currentProcessGroupID = currentProcessGroupID(of: processIdentity.pid) {
        excluded.insert(currentProcessGroupID)
    }
    return excluded.filter { $0 > 0 }
}

private func individuallyTrackedProcessGroupLeaderPID(
    processIdentity: ProcessIdentity,
    processGroupIdentity: ProcessIdentity,
    signalDedicatedProcessGroup: Bool
) -> pid_t? {
    guard let currentProcessGroupID = currentProcessGroupID(of: processIdentity.pid),
          currentProcessGroupID > 0
    else {
        return nil
    }
    if signalDedicatedProcessGroup, currentProcessGroupID == processGroupIdentity.pid {
        return nil
    }
    return currentProcessGroupID
}

private func descendantProcessGroupIdentities(
    rootIdentity: ProcessIdentity,
    excludingGroupLeaderPIDs: Set<pid_t>
) -> [ProcessIdentity] {
    guard canTraverseDescendants(of: rootIdentity) else {
        return []
    }

    var pending = snapshotChildProcessIdentities(of: rootIdentity)
    var visited: Set<ProcessIdentity> = []
    var identities: Set<ProcessIdentity> = []

    while let identity = pending.popLast() {
        if visited.insert(identity).inserted == false {
            continue
        }
        pending.append(contentsOf: snapshotChildProcessIdentities(of: identity))

        let groupLeaderPID = currentProcessGroupID(of: identity.pid) ?? identity.pid
        guard groupLeaderPID > 0,
              excludingGroupLeaderPIDs.contains(groupLeaderPID) == false,
              let groupLeaderStartTime = processStartTime(of: groupLeaderPID)
        else {
            continue
        }

        identities.insert(
            ProcessIdentity(
                pid: groupLeaderPID,
                startTime: groupLeaderStartTime
            )
        )
    }

    return Array(identities)
}

private func descendantProcessIdentities(rootIdentity: ProcessIdentity) -> [ProcessIdentity] {
    guard canTraverseDescendants(of: rootIdentity) else {
        return []
    }

    var pending = snapshotChildProcessIdentities(of: rootIdentity)
    var visited: Set<ProcessIdentity> = []
    var identities: [ProcessIdentity] = []

    while let identity = pending.popLast() {
        if visited.insert(identity).inserted == false {
            continue
        }
        identities.append(identity)
        pending.append(contentsOf: snapshotChildProcessIdentities(of: identity))
    }

    return identities
}

private func descendantProcessIdentities(
    rootIdentity: ProcessIdentity,
    inProcessGroup processGroupLeaderPID: pid_t
) -> [ProcessIdentity] {
    guard processGroupLeaderPID > 0 else {
        return []
    }

    return descendantProcessIdentities(rootIdentity: rootIdentity).filter { identity in
        currentProcessGroupID(of: identity.pid) == processGroupLeaderPID
    }
}

private func canTraverseDescendants(of identity: ProcessIdentity) -> Bool {
    processStartTime(of: identity.pid) == identity.startTime
}

private func snapshotChildProcessIdentities(of parentIdentity: ProcessIdentity) -> [ProcessIdentity] {
    guard canTraverseDescendants(of: parentIdentity) else {
        return []
    }

    return childProcessIDs(of: parentIdentity.pid).compactMap { childPID in
        guard let startTime = processStartTime(of: childPID) else {
            return nil
        }
        return ProcessIdentity(pid: childPID, startTime: startTime)
    }
}

private func mergeProcessIdentities(
    _ lhs: [ProcessIdentity],
    _ rhs: [ProcessIdentity]
) -> [ProcessIdentity] {
    Array(Set(lhs).union(rhs))
}

private func signalTrackedProcessGroups(
    _ identities: [ProcessIdentity],
    signal: Int32
) {
    for identity in Set(identities) where isTrackedProcessGroupAlive(identity) {
        _ = killpg(identity.pid, signal)
    }
}

private func hasLiveTrackedProcessGroups(_ identities: [ProcessIdentity]) -> Bool {
    Set(identities).contains { identity in
        isTrackedProcessGroupAlive(identity)
    }
}

private func signalTrackedProcesses(
    _ identities: [ProcessIdentity],
    signal: Int32
) {
    for identity in Set(identities) where isMatchingProcessIdentity(identity) {
        _ = kill(identity.pid, signal)
    }
}

private func hasLiveTrackedProcesses(_ identities: [ProcessIdentity]) -> Bool {
    Set(identities).contains { identity in
        isMatchingProcessIdentity(identity)
    }
}

private func isTrackedProcessGroupAlive(_ identity: ProcessIdentity) -> Bool {
    let probe = killpg(identity.pid, 0)
    guard probe == 0 || errno == EPERM else {
        return false
    }
    if let currentStartTime = processStartTime(of: identity.pid) {
        return currentStartTime == identity.startTime
    }
    return true
}

private func isProcessGroupGone(_ groupLeaderPID: pid_t) -> Bool {
    guard groupLeaderPID > 0 else {
        return true
    }
    errno = 0
    let result = killpg(groupLeaderPID, 0)
    return result == -1 && errno == ESRCH
}

private func reapSpawnedProcess(pid: pid_t) {
    var status: Int32 = 0
    while true {
        let result = waitpid(pid, &status, 0)
        if result == pid || (result == -1 && errno == ECHILD) {
            return
        }
        if result == -1 && errno == EINTR {
            continue
        }
        return
    }
}

private func terminateSpawnedProcessWithoutIdentity(pid: pid_t) async {
    var status: Int32 = 0
    _ = kill(pid, SIGTERM)
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while ContinuousClock.now < deadline {
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid || (result == -1 && errno == ECHILD) {
            return
        }
        try? await Task.sleep(for: .milliseconds(100))
    }
    _ = kill(pid, SIGKILL)
    reapSpawnedProcess(pid: pid)
}

private func allocateCStringArray(
    _ strings: [String]
) throws -> [UnsafeMutablePointer<CChar>?] {
    var pointers: [UnsafeMutablePointer<CChar>?] = []
    pointers.reserveCapacity(strings.count + 1)
    do {
        for string in strings {
            guard let pointer = strdup(string) else {
                throw ReviewError.spawnFailed("failed to allocate app-server spawn arguments.")
            }
            pointers.append(pointer)
        }
        pointers.append(nil)
        return pointers
    } catch {
        for pointer in pointers where pointer != nil {
            free(pointer)
        }
        throw error
    }
}
