import Darwin
import Foundation
import ReviewDomain
import ReviewInfrastructure

package protocol AppServerManaging: Sendable {
    func prepare() async throws -> AppServerRuntimeState
    func checkoutTransport(sessionID: String) async throws -> any AppServerSessionTransport
    func checkoutAuthTransport() async throws -> any AppServerSessionTransport
    func currentRuntimeState() async -> AppServerRuntimeState?
    func diagnosticLineStream() async -> AsyncStream<String>
    func diagnosticsTail() async -> String
    func shutdown() async
}

package actor AppServerSupervisor: AppServerManaging {
    package struct Configuration: Sendable {
        package var codexCommand: String
        package var environment: [String: String]
        package var coreDependencies: ReviewCoreDependencies
        package var startupTimeout: Duration
        package var clock: any ReviewClock

        package init(
            codexCommand: String = "codex",
            environment: [String: String] = ProcessInfo.processInfo.environment,
            startupTimeout: Duration = .seconds(30),
            clock: (any ReviewClock)? = nil,
            coreDependencies: ReviewCoreDependencies? = nil
        ) {
            let resolvedCoreDependencies = coreDependencies ?? .live(environment: environment)
            self.codexCommand = codexCommand
            self.environment = resolvedCoreDependencies.environment
            self.coreDependencies = resolvedCoreDependencies
            self.startupTimeout = startupTimeout
            self.clock = clock ?? resolvedCoreDependencies.clock
        }

        package init(
            codexCommand: String = "codex",
            environment: [String: String] = ProcessInfo.processInfo.environment,
            startupTimeout: Duration = .seconds(30),
            coreDependencies: ReviewCoreDependencies? = nil
        ) {
            self.init(
                codexCommand: codexCommand,
                environment: environment,
                startupTimeout: startupTimeout,
                clock: nil,
                coreDependencies: coreDependencies
            )
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

    package func diagnosticLineStream() async -> AsyncStream<String> {
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
        return stream
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
        try configuration.coreDependencies.ensureReviewHomeScaffold()
        // Intentionally use ~/.codex_review directly for app-server.
        // We no longer create a per-launch isolated CODEX_HOME or strip codex_review from config.
        let codexHomeURL = configuration.coreDependencies.paths.codexHomeURL()

        let launchCommand = try makeAppServerLaunchCommand(
            codexCommand: configuration.codexCommand,
            environment: configuration.environment,
            codexHomeURL: codexHomeURL
        )
        let spawnedProcess = try spawnAppServerProcess(launchCommand)
        let pid = spawnedProcess.pid

        guard let startTime = processStartTime(of: pid) else {
            await terminateSpawnedProcessWithoutIdentity(pid: pid, clock: configuration.clock)
            throw ReviewError.spawnFailed("app-server started without a readable process start time.")
        }

        let processIdentity = ProcessIdentity(pid: pid, startTime: startTime)
        guard currentProcessGroupID(of: pid) == pid else {
            await terminateFailedSpawnedProcess(
                processIdentity: processIdentity,
                processGroupLeaderPID: pid,
                signalDedicatedProcessGroup: false,
                clock: configuration.clock
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
                    try await self.configuration.clock.sleep(for: self.configuration.startupTimeout)
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

    private func terminateStartContext(_ startContext: StartContext) async {
        await terminateManagedRuntime(
            processIdentity: startContext.processIdentity,
            processGroupIdentity: startContext.processGroupIdentity,
            signalDedicatedProcessGroup: startContext.dedicatedProcessGroupEstablished,
            connection: startContext.connection,
            waitTask: startContext.waitTask,
            stdoutTask: startContext.stdoutTask,
            stderrTask: startContext.stderrTask,
            clock: configuration.clock
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
            stderrTask: runtimeContext.stderrTask,
            clock: configuration.clock
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
