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

    private final class RunningProcess: @unchecked Sendable {
        var launchID: UUID
        var runtimeState: AppServerRuntimeState
        var connection: AppServerSharedTransportConnection
        var waitTask: Task<Void, Never>
        var stdoutTask: Task<Void, Never>
        var stderrTask: Task<Void, Never>
        var isolatedCodexHomeURL: URL?

        init(
            launchID: UUID,
            runtimeState: AppServerRuntimeState,
            connection: AppServerSharedTransportConnection,
            waitTask: Task<Void, Never>,
            stdoutTask: Task<Void, Never>,
            stderrTask: Task<Void, Never>,
            isolatedCodexHomeURL: URL?
        ) {
            self.launchID = launchID
            self.runtimeState = runtimeState
            self.connection = connection
            self.waitTask = waitTask
            self.stdoutTask = stdoutTask
            self.stderrTask = stderrTask
            self.isolatedCodexHomeURL = isolatedCodexHomeURL
        }
    }

    private enum State {
        case stopped
        case starting(UUID, [CheckedContinuation<RunningProcess, Error>])
        case running(RunningProcess)
    }

    private let configuration: Configuration
    private var state: State = .stopped
    private var stderrLines: [String] = []
    private var diagnosticTailLines: [String] = []
    private var pendingStandardErrorBytes = Data()
    private var trailingStandardErrorFragment = ""
    private var startingRuntimeState: AppServerRuntimeState?
    private var lifetimeTask: Task<Void, Never>?
    private var diagnosticSubscribers: [UUID: AsyncStream<String>.Continuation] = [:]

    package init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    package func prepare() async throws -> AppServerRuntimeState {
        return try await ensureRunning().runtimeState
    }

    package func checkoutTransport(sessionID _: String) async throws -> any AppServerSessionTransport {
        let running = try await ensureRunning()
        return await running.connection.checkoutTransport()
    }

    package func checkoutAuthTransport() async throws -> any AppServerSessionTransport {
        let running = try await ensureRunning()
        return await running.connection.checkoutTransport()
    }

    package func currentRuntimeState() async -> AppServerRuntimeState? {
        switch state {
        case .running(let running):
            return running.runtimeState
        case .stopped, .starting:
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
        case .running(let current):
            state = .stopped
            finishDiagnosticSubscribers()
            await terminateRunningProcess(current)
            lifetimeTask = nil
            if let isolatedCodexHomeURL = current.isolatedCodexHomeURL {
                try? FileManager.default.removeItem(at: isolatedCodexHomeURL)
            }
        case .starting(_, let waiters):
            let task = lifetimeTask
            let startingRuntimeState = self.startingRuntimeState
            state = .stopped
            finishDiagnosticSubscribers()
            task?.cancel()
            if let startingRuntimeState {
                await terminateStartingProcess(runtimeState: startingRuntimeState)
            }
            let error = ReviewError.io("app-server supervisor stopped during startup.")
            for continuation in waiters {
                continuation.resume(throwing: error)
            }
            await task?.value
            self.startingRuntimeState = nil
            if lifetimeTask == task {
                lifetimeTask = nil
            }
        case .stopped:
            finishDiagnosticSubscribers()
            return
        }
    }

    private func ensureRunning() async throws -> RunningProcess {
        switch state {
        case .running(let running):
            let identity = ProcessIdentity(
                pid: pid_t(running.runtimeState.pid),
                startTime: running.runtimeState.startTime
            )
            if isMatchingProcessIdentity(identity),
               await running.connection.isClosed() == false
            {
                return running
            }
            state = .stopped
            finishDiagnosticSubscribers()
            await terminateRunningProcess(running)
            return try await ensureRunning()
        case .starting:
            return try await waitForRunning()
        case .stopped:
            let launchID = UUID()
            state = .starting(launchID, [])
            lifetimeTask = Task.detached { [weak self] in
                await self?.launchProcessBackground(launchID: launchID)
            }
            return try await waitForRunning()
        }
    }

    private func waitForRunning() async throws -> RunningProcess {
        try await withCheckedThrowingContinuation { continuation in
            switch state {
            case .running(let running):
                continuation.resume(returning: running)
            case .starting(let launchID, var waiters):
                waiters.append(continuation)
                state = .starting(launchID, waiters)
            case .stopped:
                continuation.resume(throwing: ReviewError.io("app-server supervisor is stopped."))
            }
        }
    }

    private func finishStarting(
        launchID: UUID,
        _ result: Result<RunningProcess, Error>
    ) {
        guard case .starting(let currentLaunchID, let waiters) = state,
              currentLaunchID == launchID
        else {
            return
        }
        startingRuntimeState = nil
        switch result {
        case .success(let running):
            state = .running(running)
        case .failure:
            state = .stopped
            lifetimeTask = nil
        }
        for continuation in waiters {
            continuation.resume(with: result)
        }
    }

    private func launchProcessBackground(launchID: UUID) async {
        stderrLines.removeAll(keepingCapacity: false)
        diagnosticTailLines.removeAll(keepingCapacity: false)
        pendingStandardErrorBytes.removeAll(keepingCapacity: false)
        trailingStandardErrorFragment = ""

        do {
            let isolatedCodexHomeURL = try prepareIsolatedCodexHome(
                launchID: launchID,
                environment: self.configuration.environment
            )

            let launchCommand = try makeAppServerLaunchCommand(
                codexCommand: self.configuration.codexCommand,
                environment: self.configuration.environment,
                isolatedCodexHomeURL: isolatedCodexHomeURL
            )
            let spawnedProcess = try spawnAppServerProcess(launchCommand)
            let stdinPipe = spawnedProcess.stdinPipe
            let stdoutPipe = spawnedProcess.stdoutPipe
            let stderrPipe = spawnedProcess.stderrPipe
            let pid = spawnedProcess.pid
            guard let startTime = processStartTime(of: pid_t(pid)) else {
                await terminateSpawnedProcessWithoutIdentity(pid: pid_t(pid))
                throw ReviewError.spawnFailed("app-server started without a readable process start time.")
            }
            let processIdentity = ProcessIdentity(pid: pid_t(pid), startTime: startTime)
            let startupDescendantIdentities = descendantProcessIdentities(rootIdentity: processIdentity)
            let startupProcessGroupLeaderPID = currentProcessGroupID(of: pid_t(pid)) ?? pid_t(pid)
            let startupChildGroupIdentities = descendantProcessGroupIdentities(
                rootIdentity: processIdentity,
                excludingGroupLeaderPID: startupProcessGroupLeaderPID
            )
            guard startupProcessGroupLeaderPID == pid_t(pid) else {
                await terminateStartingProcess(
                    runtimeState: .init(
                        pid: Int(pid),
                        startTime: startTime,
                        processGroupLeaderPID: Int(pid),
                        processGroupLeaderStartTime: startTime
                    ),
                    signalProcessGroup: false,
                    seedDescendantIdentities: startupDescendantIdentities,
                    seedChildGroupIdentities: startupChildGroupIdentities
                )
                await reapSpawnedProcessAsync(pid: pid_t(pid))
                throw ReviewError.spawnFailed("app-server did not enter its dedicated process group.")
            }
            let waitTask = Task.detached { @Sendable in
                reapSpawnedProcess(pid: pid_t(pid))
            }

            let runtimeState = AppServerRuntimeState(
                pid: Int(pid),
                startTime: startTime,
                processGroupLeaderPID: Int(pid),
                processGroupLeaderStartTime: startTime
            )
            self.noteStartingRuntimeState(runtimeState)

            let connection = AppServerSharedTransportConnection(
                sendMessage: { message in
                    guard let data = message.data(using: .utf8) else {
                        throw ReviewError.io("failed to encode stdio payload as UTF-8.")
                    }
                    try stdinPipe.fileHandleForWriting.write(contentsOf: data)
                },
                closeInput: {
                    try? stdinPipe.fileHandleForWriting.close()
                }
            )
            let stdoutTask = self.startCapturingStandardOutput(
                handle: stdoutPipe.fileHandleForReading,
                connection: connection
            )
            let stderrTask = self.startCapturingStandardError(
                handle: stderrPipe.fileHandleForReading
            )

            do {
                try await self.waitUntilInitialized(
                    connection: connection,
                    processIdentity: .init(pid: pid_t(pid), startTime: startTime)
                )

                self.finishStarting(
                    launchID: launchID,
                    .success(
                        RunningProcess(
                            launchID: launchID,
                            runtimeState: runtimeState,
                            connection: connection,
                            waitTask: waitTask,
                            stdoutTask: stdoutTask,
                            stderrTask: stderrTask,
                            isolatedCodexHomeURL: isolatedCodexHomeURL
                        )
                    )
                )

                let identity = ProcessIdentity(pid: pid_t(pid), startTime: startTime)
                while isMatchingProcessIdentity(identity) {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                _ = await waitTask.result
                _ = await stdoutTask.value
                _ = await stderrTask.value
                startingRuntimeState = nil
                handleProcessExit(
                    launchID: launchID,
                    processIdentity: identity,
                    isolatedCodexHomeURL: isolatedCodexHomeURL
                )
            } catch {
                await connection.shutdown()
                await self.terminateStartingProcess(
                    runtimeState: runtimeState,
                    seedDescendantIdentities: startupDescendantIdentities,
                    seedChildGroupIdentities: startupChildGroupIdentities
                )
                _ = await waitTask.result
                _ = await stdoutTask.value
                _ = await stderrTask.value
                throw error
            }
        } catch {
            let startingRuntimeState = self.startingRuntimeState
            if let startingRuntimeState {
                await terminateStartingProcess(runtimeState: startingRuntimeState)
            }
            finishStarting(launchID: launchID, .failure(error))
            if currentLaunchID == launchID {
                lifetimeTask = nil
            }
            try? FileManager.default.removeItem(
                at: ReviewHomePaths.appServerCodexHomeURL(
                    launchID: launchID,
                    environment: configuration.environment
                )
            )
        }
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

    private var currentLaunchID: UUID? {
        switch state {
        case .stopped:
            nil
        case .starting(let launchID, _):
            launchID
        case .running(let running):
            running.launchID
        }
    }

    private func handleProcessExit(
        launchID: UUID,
        processIdentity: ProcessIdentity,
        isolatedCodexHomeURL: URL?
    ) {
        startingRuntimeState = nil
        if case .running(let running) = state,
           running.launchID == launchID,
           running.runtimeState.pid == Int(processIdentity.pid),
           running.runtimeState.startTime == processIdentity.startTime
        {
            state = .stopped
            lifetimeTask = nil
        }
        finishDiagnosticSubscribers()
        if let isolatedCodexHomeURL {
            try? FileManager.default.removeItem(at: isolatedCodexHomeURL)
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

    private func noteStartingRuntimeState(_ runtimeState: AppServerRuntimeState) {
        guard case .starting = state else {
            return
        }
        startingRuntimeState = runtimeState
    }

    private func terminateStartingProcess(
        runtimeState: AppServerRuntimeState,
        signalProcessGroup: Bool = true,
        seedDescendantIdentities: [ProcessIdentity] = [],
        seedChildGroupIdentities: [ProcessIdentity] = []
    ) async {
        let processIdentity = ProcessIdentity(
            pid: pid_t(runtimeState.pid),
            startTime: runtimeState.startTime
        )
        let currentProcessGroupLeaderPID = currentProcessGroupID(of: processIdentity.pid) ?? processIdentity.pid
        let processGroupIdentity = ProcessIdentity(
            pid: pid_t(runtimeState.processGroupLeaderPID),
            startTime: runtimeState.processGroupLeaderStartTime
        )
        let initialDescendantIdentities = mergeProcessIdentities(
            seedDescendantIdentities,
            descendantProcessIdentities(rootIdentity: processIdentity)
        )
        let initialChildGroupIdentities = signalProcessGroup
            ? mergeProcessIdentities(
                seedChildGroupIdentities,
                descendantProcessGroupIdentities(
                    rootIdentity: processIdentity,
                    excludingGroupLeaderPID: processGroupIdentity.pid
                )
            )
            : seedChildGroupIdentities.filter { $0.pid != currentProcessGroupLeaderPID }

        let shouldSignalChildGroups = initialChildGroupIdentities.isEmpty == false

        _ = kill(processIdentity.pid, SIGTERM)
        if signalProcessGroup {
            _ = killpg(processGroupIdentity.pid, SIGTERM)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            let descendantIdentities = mergeProcessIdentities(
                initialDescendantIdentities,
                descendantProcessIdentities(rootIdentity: processIdentity)
            )
            let childGroupIdentities = mergeProcessIdentities(
                initialChildGroupIdentities,
                shouldSignalChildGroups
                    ? descendantProcessGroupIdentities(
                        rootIdentity: processIdentity,
                        excludingGroupLeaderPID: signalProcessGroup ? processGroupIdentity.pid : currentProcessGroupLeaderPID
                    )
                    : []
            )
            signalProcesses(descendantIdentities, signal: SIGTERM)
            if shouldSignalChildGroups {
                signalSupervisorChildGroups(childGroupIdentities, signal: SIGTERM)
            }
            if isMatchingProcessIdentity(processIdentity) == false,
               (signalProcessGroup == false || isSupervisorProcessGroupAlive(processGroupIdentity) == false),
               hasLiveProcesses(descendantIdentities) == false,
               (shouldSignalChildGroups == false || hasLiveSupervisorChildGroups(childGroupIdentities) == false)
            {
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }

        let descendantIdentities = mergeProcessIdentities(
            initialDescendantIdentities,
            descendantProcessIdentities(rootIdentity: processIdentity)
        )
        let childGroupIdentities = mergeProcessIdentities(
            initialChildGroupIdentities,
            shouldSignalChildGroups
                ? descendantProcessGroupIdentities(
                    rootIdentity: processIdentity,
                    excludingGroupLeaderPID: signalProcessGroup ? processGroupIdentity.pid : currentProcessGroupLeaderPID
                )
                : []
        )
        if isMatchingProcessIdentity(processIdentity)
            || (signalProcessGroup && isSupervisorProcessGroupAlive(processGroupIdentity))
            || hasLiveProcesses(descendantIdentities)
            || (shouldSignalChildGroups && hasLiveSupervisorChildGroups(childGroupIdentities))
        {
            _ = kill(processIdentity.pid, SIGKILL)
            if signalProcessGroup {
                _ = killpg(processGroupIdentity.pid, SIGKILL)
            }
            if shouldSignalChildGroups {
                signalSupervisorChildGroups(childGroupIdentities, signal: SIGKILL)
            }
            signalProcesses(descendantIdentities, signal: SIGKILL)
        }
    }

    private func terminateRunningProcess(_ current: RunningProcess) async {
        let processIdentity = ProcessIdentity(
            pid: pid_t(current.runtimeState.pid),
            startTime: current.runtimeState.startTime
        )
        let processGroupIdentity = ProcessIdentity(
            pid: pid_t(current.runtimeState.processGroupLeaderPID),
            startTime: current.runtimeState.processGroupLeaderStartTime
        )
        let preShutdownDescendantIdentities = descendantProcessIdentities(rootIdentity: processIdentity)
        let preShutdownChildGroupIdentities = descendantProcessGroupIdentities(
            rootIdentity: processIdentity,
            excludingGroupLeaderPID: processGroupIdentity.pid
        )
        await current.connection.shutdown()
        let trackedDescendantIdentities = mergeProcessIdentities(
            preShutdownDescendantIdentities,
            descendantProcessIdentities(rootIdentity: processIdentity)
        )
        let trackedChildGroupIdentities = mergeProcessIdentities(
            preShutdownChildGroupIdentities,
            descendantProcessGroupIdentities(
                rootIdentity: processIdentity,
                excludingGroupLeaderPID: processGroupIdentity.pid
            )
        )
        _ = kill(processIdentity.pid, SIGTERM)
        _ = killpg(processGroupIdentity.pid, SIGTERM)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            let descendantIdentities = mergeProcessIdentities(
                trackedDescendantIdentities,
                descendantProcessIdentities(rootIdentity: processIdentity)
            )
            let childGroupIdentities = mergeProcessIdentities(
                trackedChildGroupIdentities,
                descendantProcessGroupIdentities(
                    rootIdentity: processIdentity,
                    excludingGroupLeaderPID: processGroupIdentity.pid
                )
            )
            signalProcesses(descendantIdentities, signal: SIGTERM)
            signalSupervisorChildGroups(childGroupIdentities, signal: SIGTERM)
            if isMatchingProcessIdentity(processIdentity) == false,
               isSupervisorProcessGroupAlive(processGroupIdentity) == false,
               hasLiveProcesses(descendantIdentities) == false,
               hasLiveSupervisorChildGroups(childGroupIdentities) == false
            {
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let descendantIdentities = mergeProcessIdentities(
            trackedDescendantIdentities,
            descendantProcessIdentities(rootIdentity: processIdentity)
        )
        let childGroupIdentities = mergeProcessIdentities(
            trackedChildGroupIdentities,
            descendantProcessGroupIdentities(
                rootIdentity: processIdentity,
                excludingGroupLeaderPID: processGroupIdentity.pid
            )
        )
        if isMatchingProcessIdentity(processIdentity)
            || isSupervisorProcessGroupAlive(processGroupIdentity)
            || hasLiveProcesses(descendantIdentities)
            || hasLiveSupervisorChildGroups(childGroupIdentities)
        {
            _ = kill(processIdentity.pid, SIGKILL)
            _ = killpg(processGroupIdentity.pid, SIGKILL)
            signalProcesses(descendantIdentities, signal: SIGKILL)
            signalSupervisorChildGroups(childGroupIdentities, signal: SIGKILL)
        }
        _ = await current.stdoutTask.result
        _ = await current.stderrTask.result
        await lifetimeTask?.value
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
    isolatedCodexHomeURL: URL?
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
    if let isolatedCodexHomeURL {
        effectiveEnvironment["CODEX_HOME"] = isolatedCodexHomeURL.path
    }

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

    let stdioMappings: [(source: Int32, destination: Int32)] = [
        (stdinReadFD, STDIN_FILENO),
        (stdoutWriteFD, STDOUT_FILENO),
        (stderrWriteFD, STDERR_FILENO),
    ]

    for fileDescriptor in [
        stdinWriteFD,
        stdoutReadFD,
        stderrReadFD,
    ] {
        let status = posix_spawn_file_actions_addclose(&fileActions, fileDescriptor)
        guard status == 0 else {
            throw ReviewError.spawnFailed("failed to configure app-server stdio cleanup.")
        }
    }

    for mapping in stdioMappings where mapping.source != mapping.destination {
        let status = posix_spawn_file_actions_adddup2(
            &fileActions,
            mapping.source,
            mapping.destination
        )
        guard status == 0 else {
            throw ReviewError.spawnFailed("failed to configure app-server stdio redirection.")
        }
    }

    for mapping in stdioMappings where mapping.source != mapping.destination {
        let status = posix_spawn_file_actions_addclose(&fileActions, mapping.source)
        guard status == 0 else {
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
    let spawnedPID = pid

    try? stdinPipe.fileHandleForReading.close()
    try? stdoutPipe.fileHandleForWriting.close()
    try? stderrPipe.fileHandleForWriting.close()

    return SpawnedAppServerProcess(
        pid: spawnedPID,
        stdinPipe: stdinPipe,
        stdoutPipe: stdoutPipe,
        stderrPipe: stderrPipe
    )
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

private func reapSpawnedProcessAsync(pid: pid_t) async {
    await Task.detached { @Sendable in
        reapSpawnedProcess(pid: pid)
    }.value
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

package func prepareIsolatedCodexHome(
    launchID: UUID,
    environment: [String: String]
) throws -> URL {
    try ReviewHomePaths.ensureReviewHomeScaffold(environment: environment)
    let isolatedCodexHomeURL = ReviewHomePaths.appServerCodexHomeURL(
        launchID: launchID,
        environment: environment
    )
    let sourceCodexHomeURL = ReviewHomePaths.codexHomeURL(environment: environment)
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: isolatedCodexHomeURL.path) {
        try fileManager.removeItem(at: isolatedCodexHomeURL)
    }
    try fileManager.createDirectory(at: isolatedCodexHomeURL, withIntermediateDirectories: true)

    let sourceConfigURL = ReviewHomePaths.codexConfigURL(
        environment: environment,
        codexHome: sourceCodexHomeURL
    )
    let isolatedConfigURL = isolatedCodexHomeURL.appendingPathComponent("config.toml")
    let configText = try String(contentsOf: sourceConfigURL, encoding: .utf8)
    let filteredConfigText = isolatedCodexHomeConfigText(from: configText)
    try filteredConfigText.write(
        to: isolatedConfigURL,
        atomically: true,
        encoding: .utf8
    )
    guard fileManager.fileExists(atPath: isolatedConfigURL.path) else {
        throw ReviewError.io("failed to materialize config.toml in isolated Codex home.")
    }

    for sourceURL in try fileManager.contentsOfDirectory(
        at: sourceCodexHomeURL,
        includingPropertiesForKeys: nil,
        options: []
    ) {
        let filename = sourceURL.lastPathComponent
        guard ReviewHomePaths.shouldExcludeFromAppServerSeed(name: filename) == false else {
            continue
        }
        let destinationURL = isolatedCodexHomeURL.appendingPathComponent(filename)
        if filename == "config.toml" {
            continue
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }

    return isolatedCodexHomeURL
}

package func isolatedCodexHomeConfigText(from configText: String) -> String {
    let lines = configText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var keptLines: [String] = []
    var inCodexReviewSection = false

    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("["),
           let closingBracketIndex = trimmed.firstIndex(of: "]")
        {
            let sectionName = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closingBracketIndex])
            inCodexReviewSection = sectionName == "mcp_servers.codex_review"
                || sectionName == "mcp_servers.\"codex_review\""
                || sectionName == "mcp_servers.'codex_review'"
            if inCodexReviewSection {
                continue
            }
        }

        if inCodexReviewSection {
            continue
        }
        keptLines.append(line)
    }

    return keptLines.joined(separator: "\n")
}

private func isSupervisorProcessGroupAlive(_ identity: ProcessIdentity) -> Bool {
    let probe = killpg(identity.pid, 0)
    guard probe == 0 || errno == EPERM else {
        return false
    }
    if let currentStartTime = processStartTime(of: identity.pid) {
        return currentStartTime == identity.startTime
    }
    return true
}

private func descendantProcessGroupIdentities(
    rootIdentity: ProcessIdentity,
    excludingGroupLeaderPID: pid_t
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
              groupLeaderPID != excludingGroupLeaderPID,
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

private func mergeProcessIdentities(
    _ lhs: [ProcessIdentity],
    _ rhs: [ProcessIdentity]
) -> [ProcessIdentity] {
    Array(Set(lhs).union(rhs))
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
        return .init(pid: childPID, startTime: startTime)
    }
}

private func signalSupervisorChildGroups(
    _ identities: [ProcessIdentity],
    signal: Int32
) {
    for identity in Set(identities) where isSupervisorProcessGroupAlive(identity) {
        _ = killpg(identity.pid, signal)
    }
}

private func hasLiveSupervisorChildGroups(_ identities: [ProcessIdentity]) -> Bool {
    Set(identities).contains { identity in
        isSupervisorProcessGroupAlive(identity)
    }
}

private func signalProcesses(
    _ identities: [ProcessIdentity],
    signal: Int32
) {
    for identity in Set(identities) where isMatchingProcessIdentity(identity) {
        _ = kill(identity.pid, signal)
    }
}

private func hasLiveProcesses(_ identities: [ProcessIdentity]) -> Bool {
    Set(identities).contains { identity in
        isMatchingProcessIdentity(identity)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
