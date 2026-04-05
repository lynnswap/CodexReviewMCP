import Darwin
import Foundation
import ReviewJobs
import Subprocess
#if canImport(System)
import System
#else
import SystemPackage
#endif

package protocol AppServerManaging: Sendable {
    func prepare() async throws -> AppServerRuntimeState
    func checkoutTransport(sessionID: String) async throws -> any AppServerSessionTransport
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

    private struct RunningProcess: Sendable {
        var launchID: UUID
        var runtimeState: AppServerRuntimeState
        var execution: Execution
        var connection: AppServerSharedTransportConnection
        var isolatedCodexHomeURL: URL?
    }

    private enum State {
        case stopped
        case starting(UUID, [CheckedContinuation<RunningProcess, Error>])
        case running(RunningProcess)
    }

    private let configuration: Configuration
    private var state: State = .stopped
    private var stderrLines: [String] = []
    private var pendingStandardErrorBytes = Data()
    private var trailingStandardErrorFragment = ""
    private var startingRuntimeState: AppServerRuntimeState?
    private var lifetimeTask: Task<Void, Never>?
    private var diagnosticSubscribers: [UUID: AsyncStream<String>.Continuation] = [:]

    package init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    package func prepare() async throws -> AppServerRuntimeState {
        try await ensureRunning().runtimeState
    }

    package func checkoutTransport(sessionID _: String) async throws -> any AppServerSessionTransport {
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
        stderrLines.suffix(100).joined(separator: "\n")
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
        pendingStandardErrorBytes.removeAll(keepingCapacity: false)
        trailingStandardErrorFragment = ""

        do {
            var launchedProcessIdentity: ProcessIdentity?
            let isolatedCodexHomeURL = try prepareIsolatedCodexHome(
                launchID: launchID,
                environment: self.configuration.environment
            )

            let configuration = try makeAppServerConfiguration(
                codexCommand: self.configuration.codexCommand,
                environment: self.configuration.environment,
                isolatedCodexHomeURL: isolatedCodexHomeURL
            )

            let outcome = try await Subprocess.run(
                configuration,
                preferredBufferSize: 4096
            ) { execution, inputWriter, outputSequence, errorSequence in
                let pid = execution.processIdentifier.value
                guard let startTime = processStartTime(of: pid) else {
                    throw ReviewError.spawnFailed("app-server started without a readable process start time.")
                }
                launchedProcessIdentity = .init(pid: pid, startTime: startTime)
                let processGroupLeaderPID = currentProcessGroupID(of: pid) ?? pid
                let processGroupLeaderStartTime = processStartTime(of: processGroupLeaderPID) ?? startTime
                let runtimeState = AppServerRuntimeState(
                    pid: Int(pid),
                    startTime: startTime,
                    processGroupLeaderPID: Int(processGroupLeaderPID),
                    processGroupLeaderStartTime: processGroupLeaderStartTime
                )
                self.noteStartingRuntimeState(runtimeState)

                let connection = AppServerSharedTransportConnection(
                    sendMessage: { message in
                        _ = try await inputWriter.write(message, using: UTF8.self)
                    },
                    closeInput: {
                        try? await inputWriter.finish()
                    }
                )
                let stdoutTask = self.startCapturingStandardOutput(
                    from: outputSequence,
                    connection: connection
                )
                let stderrTask = self.startCapturingStandardError(from: errorSequence)
                do {
                    try await self.waitUntilInitialized(
                        connection: connection,
                        processIdentity: .init(pid: pid, startTime: startTime)
                    )

                    self.finishStarting(
                        launchID: launchID,
                        .success(
                            RunningProcess(
                                launchID: launchID,
                                runtimeState: runtimeState,
                                execution: execution,
                                connection: connection,
                                isolatedCodexHomeURL: isolatedCodexHomeURL
                            )
                        )
                    )

                    let identity = ProcessIdentity(pid: pid, startTime: startTime)
                    while isMatchingProcessIdentity(identity) {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    _ = await stdoutTask.value
                    _ = await stderrTask.value
                    return ()
                } catch {
                    await connection.shutdown()
                    stdoutTask.cancel()
                    stderrTask.cancel()
                    _ = await stdoutTask.value
                    _ = await stderrTask.value
                    await self.terminateStartingProcess(runtimeState: runtimeState)
                    throw error
                }
            }

            _ = outcome
            if let launchedProcessIdentity {
                startingRuntimeState = nil
                handleProcessExit(
                    launchID: launchID,
                    processIdentity: launchedProcessIdentity,
                    isolatedCodexHomeURL: isolatedCodexHomeURL
                )
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
        from sequence: AsyncBufferSequence,
        connection: AppServerSharedTransportConnection
    ) -> Task<Void, Never> {
        Task.detached {
            do {
                for try await chunk in sequence {
                    await connection.receive(Data(buffer: chunk))
                }
                await connection.finishReceiving(error: nil)
            } catch {
                await connection.finishReceiving(error: error)
            }
        }
    }

    private func startCapturingStandardError(from sequence: AsyncBufferSequence) -> Task<Void, Never> {
        Task.detached { [weak self] in
            do {
                for try await chunk in sequence {
                    await self?.appendStandardErrorData(Data(buffer: chunk))
                }
                await self?.flushStandardErrorFragment()
            } catch {
                await self?.flushStandardErrorFragment()
                return
            }
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
        if stderrLines.count > 200 {
            stderrLines.removeFirst(stderrLines.count - 200)
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

    private func terminateStartingProcess(runtimeState: AppServerRuntimeState) async {
        let processIdentity = ProcessIdentity(
            pid: pid_t(runtimeState.pid),
            startTime: runtimeState.startTime
        )
        let processGroupIdentity = ProcessIdentity(
            pid: pid_t(runtimeState.processGroupLeaderPID),
            startTime: runtimeState.processGroupLeaderStartTime
        )

        _ = kill(processIdentity.pid, SIGTERM)
        _ = killpg(processGroupIdentity.pid, SIGTERM)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if isMatchingProcessIdentity(processIdentity) == false,
               isSupervisorProcessGroupAlive(processGroupIdentity) == false
            {
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }

        if isMatchingProcessIdentity(processIdentity)
            || isSupervisorProcessGroupAlive(processGroupIdentity)
        {
            _ = kill(processIdentity.pid, SIGKILL)
            _ = killpg(processGroupIdentity.pid, SIGKILL)
        }
    }

    private func terminateRunningProcess(_ current: RunningProcess) async {
        await current.connection.shutdown()
        let processIdentity = ProcessIdentity(
            pid: pid_t(current.runtimeState.pid),
            startTime: current.runtimeState.startTime
        )
        let processGroupIdentity = ProcessIdentity(
            pid: pid_t(current.runtimeState.processGroupLeaderPID),
            startTime: current.runtimeState.processGroupLeaderStartTime
        )
        let childGroupIdentities = descendantProcessGroupIdentities(
            rootPID: processIdentity.pid,
            excludingGroupLeaderPID: processGroupIdentity.pid
        )
        try? current.execution.send(signal: .terminate, toProcessGroup: false)
        try? current.execution.send(signal: .terminate, toProcessGroup: true)
        signalSupervisorChildGroups(childGroupIdentities, signal: SIGTERM)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if isMatchingProcessIdentity(processIdentity) == false,
               isSupervisorProcessGroupAlive(processGroupIdentity) == false,
               hasLiveSupervisorChildGroups(childGroupIdentities) == false
            {
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if isMatchingProcessIdentity(processIdentity)
            || isSupervisorProcessGroupAlive(processGroupIdentity)
            || hasLiveSupervisorChildGroups(childGroupIdentities)
        {
            try? current.execution.send(signal: .kill, toProcessGroup: false)
            try? current.execution.send(signal: .kill, toProcessGroup: true)
            signalSupervisorChildGroups(childGroupIdentities, signal: SIGKILL)
        }
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

private func makeAppServerConfiguration(
    codexCommand: String,
    environment: [String: String],
    isolatedCodexHomeURL: URL?
) throws -> Configuration {
    guard let resolvedExecutable = resolveCodexCommand(
        requestedCommand: codexCommand,
        environment: environment,
        currentDirectory: FileManager.default.currentDirectoryPath
    ) else {
        throw ReviewError.spawnFailed(
            "Unable to locate \(codexCommand) executable. Set --codex-command or ensure PATH contains \(codexCommand)."
        )
    }

    var platformOptions = PlatformOptions()
    platformOptions.processGroupID = 0
    platformOptions.createSession = false

    var effectiveEnvironment = environment
    if let isolatedCodexHomeURL {
        effectiveEnvironment["CODEX_HOME"] = isolatedCodexHomeURL.path
    }

    let subprocessEnvironment = Environment.custom(
        effectiveEnvironment.reduce(into: [Environment.Key: String]()) { partialResult, entry in
            partialResult[Environment.Key(stringLiteral: entry.key)] = entry.value
        }
    )

    return Configuration(
        executable: .path(FilePath(resolvedExecutable)),
        arguments: [
            "app-server",
            "--listen", "stdio://"
        ],
        environment: subprocessEnvironment,
        workingDirectory: FilePath(FileManager.default.currentDirectoryPath),
        platformOptions: platformOptions
    )
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
            let configText = try String(contentsOf: sourceURL, encoding: .utf8)
            let filteredConfigText = isolatedCodexHomeConfigText(from: configText)
            try filteredConfigText.write(
                to: destinationURL,
                atomically: true,
                encoding: .utf8
            )
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
    rootPID: pid_t,
    excludingGroupLeaderPID: pid_t
) -> [ProcessIdentity] {
    var pending = childProcessIDs(of: rootPID)
    var visited: Set<pid_t> = []
    var identities: Set<ProcessIdentity> = []

    while let pid = pending.popLast() {
        if visited.insert(pid).inserted == false {
            continue
        }
        guard isProcessAlive(pid) else {
            continue
        }

        pending.append(contentsOf: childProcessIDs(of: pid))

        let groupLeaderPID = currentProcessGroupID(of: pid) ?? pid
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

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
