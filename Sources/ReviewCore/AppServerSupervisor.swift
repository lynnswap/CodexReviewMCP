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
    func makeSessionTransport(sessionID: String) async throws -> any AppServerSessionTransport
    func currentRuntimeState() async -> AppServerRuntimeState?
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
        var websocketURL: URL
        var authToken: String
        var runtimeState: AppServerRuntimeState
        var execution: Execution
        var tokenFileURL: URL
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

    package init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    package func prepare() async throws -> AppServerRuntimeState {
        try await ensureRunning().runtimeState
    }

    package func makeSessionTransport(sessionID: String) async throws -> any AppServerSessionTransport {
        let running = try await ensureRunning()
        _ = sessionID
        return try await AppServerWebSocketSessionTransport.connect(
            websocketURL: running.websocketURL,
            authToken: running.authToken,
            clientName: codexReviewMCPName,
            clientTitle: "Codex Review MCP",
            clientVersion: codexReviewMCPVersion,
            diagnosticsProvider: { [weak self] in
                await self?.diagnosticsTail() ?? ""
            }
        )
    }

    package func currentRuntimeState() async -> AppServerRuntimeState? {
        switch state {
        case .running(let running):
            return running.runtimeState
        case .stopped, .starting:
            return nil
        }
    }

    package func diagnosticsTail() async -> String {
        stderrLines.suffix(100).joined(separator: "\n")
    }

    package func shutdown() async {
        switch state {
        case .running(let current):
            state = .stopped
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
                try? current.execution.send(signal: .kill, toProcessGroup: true)
                signalSupervisorChildGroups(childGroupIdentities, signal: SIGKILL)
            }
            await lifetimeTask?.value
            lifetimeTask = nil
            try? FileManager.default.removeItem(at: current.tokenFileURL)
        case .starting(_, let waiters):
            let task = lifetimeTask
            let startingRuntimeState = self.startingRuntimeState
            state = .stopped
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
            if isMatchingProcessIdentity(identity) {
                return running
            }
            state = .stopped
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
        let tokenFileURL = ReviewHomePaths.appServerWebSocketTokenFileURL(
            filename: "app-server-ws-token-\(launchID.uuidString)",
            environment: configuration.environment
        )

        do {
            let authToken = UUID().uuidString
            var launchedProcessIdentity: ProcessIdentity?
            let websocketURL = try reserveLoopbackWebSocketURL()
            try FileManager.default.createDirectory(
                at: tokenFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try authToken.write(to: tokenFileURL, atomically: true, encoding: .utf8)

            let configuration = try makeAppServerConfiguration(
                codexCommand: self.configuration.codexCommand,
                environment: self.configuration.environment,
                listenAddress: websocketURL.absoluteString,
                tokenFileURL: tokenFileURL
            )

            let outcome = try await Subprocess.run(
                configuration,
                output: .discarded,
                preferredBufferSize: 4096
            ) { execution, errorSequence in
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
                await self.noteStartingRuntimeState(runtimeState)

                let stderrTask = await self.startCapturingStandardError(from: errorSequence)
                do {
                    try await self.waitUntilReady(
                        processIdentity: .init(pid: pid, startTime: startTime),
                        websocketURL: websocketURL
                    )

                    await self.finishStarting(
                        launchID: launchID,
                        .success(
                        RunningProcess(
                            launchID: launchID,
                            websocketURL: websocketURL,
                            authToken: authToken,
                            runtimeState: runtimeState,
                            execution: execution,
                            tokenFileURL: tokenFileURL
                        )
                    ))

                    let identity = ProcessIdentity(pid: pid, startTime: startTime)
                    while isMatchingProcessIdentity(identity) {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    _ = await stderrTask.value
                    return ()
                } catch {
                    stderrTask.cancel()
                    _ = await stderrTask.value
                    throw error
                }
            }

            _ = outcome
            if let launchedProcessIdentity {
                startingRuntimeState = nil
                handleProcessExit(
                    launchID: launchID,
                    processIdentity: launchedProcessIdentity,
                    tokenFileURL: tokenFileURL
                )
            }
        } catch {
            finishStarting(launchID: launchID, .failure(error))
            if currentLaunchID == launchID {
                lifetimeTask = nil
            }
            try? FileManager.default.removeItem(at: tokenFileURL)
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
        if stderrLines.count > 200 {
            stderrLines.removeFirst(stderrLines.count - 200)
        }
    }

    private func waitUntilReady(
        processIdentity: ProcessIdentity,
        websocketURL: URL
    ) async throws {

        let deadline = ContinuousClock.now.advanced(by: configuration.startupTimeout)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let readyURL = try makeReadyURL(from: websocketURL)

        while ContinuousClock.now < deadline {
            try Task.checkCancellation()

            if isMatchingProcessIdentity(processIdentity) == false {
                let diagnostics = await diagnosticsTail()
                let suffix = diagnostics.nilIfEmpty.map { ": \($0)" } ?? ""
                throw ReviewError.spawnFailed("app-server exited before becoming ready\(suffix)")
            }

            var request = URLRequest(url: readyURL)
            request.httpMethod = "GET"
            request.timeoutInterval = 1
            if let (_, response) = try? await session.data(for: request),
               let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode == 200
            {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        throw ReviewError.spawnFailed("timed out waiting for app-server readiness.")
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
        tokenFileURL: URL
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
        try? FileManager.default.removeItem(at: tokenFileURL)
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
            _ = killpg(processGroupIdentity.pid, SIGKILL)
        }
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
    listenAddress: String,
    tokenFileURL: URL
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

    let subprocessEnvironment = Environment.custom(
        environment.reduce(into: [Environment.Key: String]()) { partialResult, entry in
            partialResult[Environment.Key(stringLiteral: entry.key)] = entry.value
        }
    )

    return Configuration(
        executable: .path(FilePath(resolvedExecutable)),
        arguments: [
            "app-server",
            "--listen", listenAddress,
            "--ws-auth", "capability-token",
            "--ws-token-file", tokenFileURL.path
        ],
        environment: subprocessEnvironment,
        workingDirectory: FilePath(FileManager.default.currentDirectoryPath),
        platformOptions: platformOptions
    )
}

private func makeReadyURL(from websocketURL: URL) throws -> URL {
    guard var components = URLComponents(url: websocketURL, resolvingAgainstBaseURL: false) else {
        throw ReviewError.spawnFailed("failed to construct readyz URL for app-server startup.")
    }
    components.scheme = "http"
    components.path = "/readyz"
    guard let url = components.url else {
        throw ReviewError.spawnFailed("failed to construct readyz URL for app-server startup.")
    }
    return url
}

private func stripANSIEscapeCodes(_ text: String) -> String {
    var stripped = String()
    var iterator = text.makeIterator()
    while let character = iterator.next() {
        if character == "\u{1b}", iterator.next() == "[" {
            while let next = iterator.next() {
                if ("@"..."~").contains(next) {
                    break
                }
            }
            continue
        }
        stripped.append(character)
    }
    return stripped
}

private func reserveLoopbackWebSocketURL() throws -> URL {
    let socketFD = socket(AF_INET, SOCK_STREAM, 0)
    guard socketFD >= 0 else {
        throw ReviewError.spawnFailed("failed to create loopback reservation socket.")
    }
    defer { close(socketFD) }

    var value: Int32 = 1
    _ = setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &value, socklen_t(MemoryLayout.size(ofValue: value)))

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(0).bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

    let bindResult = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bindResult == 0 else {
        throw ReviewError.spawnFailed("failed to bind loopback reservation socket: \(String(cString: strerror(errno))).")
    }

    var boundAddress = sockaddr_in()
    var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &boundAddress) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(socketFD, $0, &addressLength)
        }
    }
    guard nameResult == 0 else {
        throw ReviewError.spawnFailed("failed to inspect reserved loopback port: \(String(cString: strerror(errno))).")
    }

    let port = Int(UInt16(bigEndian: boundAddress.sin_port))
    guard let url = URL(string: "ws://127.0.0.1:\(port)") else {
        throw ReviewError.spawnFailed("failed to construct reserved websocket URL.")
    }
    return url
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
