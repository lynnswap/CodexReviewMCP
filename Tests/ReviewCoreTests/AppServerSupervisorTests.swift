import Foundation
import Testing
import ReviewTestSupport
@testable import ReviewCore

@Suite(.serialized)
struct AppServerSupervisorTests {
    @Test func reviewMCPCodexCommandArgumentsForceFileAuthStore() {
        #expect(
            reviewMCPCodexCommandArguments(["login", "status"])
                == ["-c", reviewMCPPersistentAuthCLIOverride, "login", "status"]
        )
    }

    @Test func splitStandardErrorChunkSeparatesCompleteLines() {
        let result = splitStandardErrorChunk(
            existingFragment: "",
            chunk: "first\nsecond\n"
        )

        #expect(result.completeLines == ["first", "second", ""])
        #expect(result.trailingFragment.isEmpty)
    }

    @Test func splitStandardErrorChunkPreservesTrailingFragment() {
        let result = splitStandardErrorChunk(
            existingFragment: "pre",
            chunk: "fix\npartial"
        )

        #expect(result.completeLines == ["prefix"])
        #expect(result.trailingFragment == "partial")
    }

    @Test func prepareUsesReviewHomeDirectlyWithoutCreatingIsolatedCopy() async throws {
        let environment = try makeSupervisorEnvironment()
        let homeURL = URL(fileURLWithPath: try #require(environment["HOME"]))
        let reviewHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        let capturedCodexHomeURL = homeURL.appendingPathComponent("captured-codex-home.txt")
        try FileManager.default.createDirectory(at: reviewHomeURL, withIntermediateDirectories: true)

        try """
        model = "gpt-5.4"

        [mcp_servers.codex_review]
        url = "http://localhost:9417/mcp"
        startup_timeout_sec = 2400.0
        tool_timeout_sec = 2400.0
        """.write(
            to: reviewHomeURL.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )

        let commandURL = try makeFakeSupervisorCommand(
            respondsToInitialize: true,
            codexHomeCaptureURL: capturedCodexHomeURL
        )
        let supervisor = AppServerSupervisor(
            configuration: .init(
                codexCommand: commandURL.path,
                environment: environment,
                startupTimeout: .seconds(1)
            )
        )
        do {
            _ = try await supervisor.prepare()

            let capturedCodexHome = try String(contentsOf: capturedCodexHomeURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(capturedCodexHome == reviewHomeURL.path)

            let configText = try String(
                contentsOf: reviewHomeURL.appendingPathComponent("config.toml"),
                encoding: .utf8
            )
            #expect(configText.contains("[mcp_servers.codex_review]"))
            #expect(configText.contains("startup_timeout_sec = 2400.0"))
            #expect(configText.contains("tool_timeout_sec = 2400.0"))

            let reviewHomeContents = try FileManager.default.contentsOfDirectory(atPath: reviewHomeURL.path)
            #expect(reviewHomeContents.contains("config.toml"))
            #expect(reviewHomeContents.contains("AGENTS.md"))
            #expect(reviewHomeContents.contains { $0.hasPrefix("review_mcp_app_server_codex_home-") } == false)
        } catch {
            await supervisor.shutdown()
            try? FileManager.default.removeItem(at: commandURL)
            throw error
        }

        await supervisor.shutdown()
        try? FileManager.default.removeItem(at: commandURL)
    }

    @Test func prepareResolvesCodexCommandFromPATH() async throws {
        var environment = try makeSupervisorEnvironment()
        let commandURL = try makeFakeSupervisorCommand(
            respondsToInitialize: true,
            configResponseCharacterCount: 4_096
        )
        let executableDirectoryURL = try makeExecutableDirectory(named: "codex", from: commandURL)
        environment["PATH"] = "\(executableDirectoryURL.path):\(try #require(environment["PATH"]))"

        let supervisor = AppServerSupervisor(
            configuration: .init(
                codexCommand: "codex",
                environment: environment,
                startupTimeout: .seconds(1)
            )
        )
        do {
            _ = try await supervisor.prepare()
            let transport = try await supervisor.checkoutAuthTransport()
            let response: AppServerConfigReadResponse = try await transport.request(
                method: "config/read",
                params: AppServerConfigReadParams(
                    cwd: FileManager.default.currentDirectoryPath,
                    includeLayers: false
                ),
                responseType: AppServerConfigReadResponse.self
            )

            #expect(response.config.model == "gpt-5.4-mini")
            #expect(response.config.reviewModel == "gpt-5.4-mini")
        } catch {
            await supervisor.shutdown()
            try? FileManager.default.removeItem(at: executableDirectoryURL)
            try? FileManager.default.removeItem(at: commandURL)
            throw error
        }

        await supervisor.shutdown()
        try? FileManager.default.removeItem(at: executableDirectoryURL)
        try? FileManager.default.removeItem(at: commandURL)
    }

    @Test func sharedTransportInitializeCompletesOverMockedStdio() async throws {
        let box = ConnectionBox()
        let connection = AppServerSharedTransportConnection(
            sendMessage: { message in
                guard let data = message.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let jsonrpc = object["jsonrpc"] as? String,
                      jsonrpc == "2.0",
                      let method = object["method"] as? String,
                      method == "initialize",
                      let id = object["id"]
                else {
                    return
                }
                let response = try JSONSerialization.data(
                    withJSONObject: [
                        "id": id,
                        "result": [
                            "platformFamily": "macOS",
                            "platformOs": "Darwin",
                        ],
                    ]
                )
                if let connection = await box.connection() {
                    await connection.receive(response + Data([0x0A]))
                }
            },
            closeInput: {}
        )
        await box.setConnection(connection)

        let response = try await connection.initialize(
            clientName: "test-client",
            clientTitle: "Test Client",
            clientVersion: "0.1"
        )

        #expect(response.platformFamily == "macOS")
        #expect(response.platformOs == "Darwin")
    }

    @Test func sharedTransportDecodesAccountRateLimitsUpdatedNotification() async throws {
        let connection = AppServerSharedTransportConnection(
            sendMessage: { _ in },
            closeInput: {}
        )
        let subscription = await connection.notificationStream()
        defer {
            Task {
                await subscription.cancel()
            }
        }

        let payload = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "method": "account/rateLimits/updated",
                "params": [
                    "rateLimits": [
                        "limitId": "codex",
                        "primary": [
                            "usedPercent": 72,
                            "windowDurationMins": 300,
                            "resetsAt": 1_735_689_600,
                        ],
                        "secondary": NSNull(),
                    ],
                ],
            ]
        )
        await connection.receive(payload + Data([0x0A]))

        let receivedNotification = try await withTestTimeout {
            var iterator = subscription.stream.makeAsyncIterator()
            return try await iterator.next()
        }
        let notification = try #require(receivedNotification)

        guard case .accountRateLimitsUpdated(let updated) = notification else {
            Issue.record("Expected account/rateLimits/updated notification.")
            return
        }

        #expect(updated.rateLimits.limitID == "codex")
        #expect(updated.rateLimits.primary?.usedPercent == 72)
        #expect(updated.rateLimits.primary?.windowDurationMins == 300)
        #expect(updated.rateLimits.secondary == nil)
    }

    @Test func supervisorStreamsLargeConfigResponseOverChunkedStdout() async throws {
        let environment = try makeSupervisorEnvironment()
        let commandURL = try makeFakeSupervisorCommand(
            respondsToInitialize: true,
            configResponseCharacterCount: 64_000,
            responseChunkSize: 113
        )
        let supervisor = AppServerSupervisor(
            configuration: .init(
                codexCommand: commandURL.path,
                environment: environment,
                startupTimeout: .seconds(1)
            )
        )
        defer {
            Task {
                await supervisor.shutdown()
            }
            try? FileManager.default.removeItem(at: commandURL)
        }

        _ = try await supervisor.prepare()
        let transport = try await supervisor.checkoutTransport(sessionID: "session-a")
        let response: AppServerConfigReadResponse = try await withTestTimeout {
            try await transport.request(
                method: "config/read",
                params: AppServerConfigReadParams(
                    cwd: FileManager.default.currentDirectoryPath,
                    includeLayers: false
                ),
                responseType: AppServerConfigReadResponse.self
            )
        }

        #expect(response.config.model == "gpt-5.4-mini")
        #expect(response.config.reviewModel == "gpt-5.4-mini")
    }

    @Test func checkoutAuthTransportUsesSharedConnection() async throws {
        let environment = try makeSupervisorEnvironment()
        let commandURL = try makeFakeSupervisorCommand(
            respondsToInitialize: true,
            configResponseCharacterCount: 4_096
        )
        let supervisor = AppServerSupervisor(
            configuration: .init(
                codexCommand: commandURL.path,
                environment: environment,
                startupTimeout: .seconds(1)
            )
        )
        defer {
            Task {
                await supervisor.shutdown()
            }
            try? FileManager.default.removeItem(at: commandURL)
        }

        _ = try await supervisor.prepare()
        let transport = try await supervisor.checkoutAuthTransport()
        let response: AppServerConfigReadResponse = try await transport.request(
            method: "config/read",
            params: AppServerConfigReadParams(
                cwd: FileManager.default.currentDirectoryPath,
                includeLayers: false
            ),
            responseType: AppServerConfigReadResponse.self
        )

        #expect(response.config.model == "gpt-5.4-mini")
        #expect(response.config.reviewModel == "gpt-5.4-mini")
    }

    @Test func prepareTimeoutStopsStartingProcess() async throws {
        let environment = try makeSupervisorEnvironment()
        let processControl = try makeSupervisorProcessControlFiles(
            environment: environment,
            basename: "fake-app-server"
        )
        let commandURL = try makeFakeSupervisorCommand(
            respondsToInitialize: false,
            pidFileURL: processControl.pidFileURL,
            exitRequestFileURL: processControl.exitRequestFileURL,
            exitLogURL: processControl.exitLogURL
        )
        defer { try? FileManager.default.removeItem(at: commandURL) }
        let clock = ManualTestClock()

        let supervisor = AppServerSupervisor(
            configuration: .init(
                codexCommand: commandURL.path,
                environment: environment,
                startupTimeout: .seconds(1),
                clock: clock
            )
        )

        let completionSignal = AsyncSignal()
        let prepareTask = Task<Result<AppServerRuntimeState, Error>, Never> {
            let result: Result<AppServerRuntimeState, Error>
            do {
                result = .success(try await supervisor.prepare())
            } catch {
                result = .failure(error)
            }
            await completionSignal.signal()
            return result
        }
        let pid = try await waitForPID(at: processControl.pidFileURL)
        let identity = try #require(processIdentity(pid: pid))
        await clock.sleepUntilSuspendedBy(1)
        clock.advance(by: .seconds(1))
        try await driveClockUntilSignal(completionSignal, clock: clock)

        guard await completionSignal.count() == 1 else {
            prepareTask.cancel()
            try? requestSupervisorProcessExit(at: processControl.exitRequestFileURL)
            Issue.record("prepare() did not complete after driving startup timeout and cleanup.")
            return
        }
        switch await prepareTask.value {
        case .success:
            Issue.record("prepare() unexpectedly succeeded without an initialize response.")
        case .failure(let error):
            #expect(error.localizedDescription.contains("timed out waiting for app-server initialization"))
        }
        try await waitForProcessExit(identity)
    }

    @Test func shutdownDuringStartupStopsStartingProcess() async throws {
        let environment = try makeSupervisorEnvironment()
        let processControl = try makeSupervisorProcessControlFiles(
            environment: environment,
            basename: "fake-app-server-starting"
        )
        let commandURL = try makeFakeSupervisorCommand(
            respondsToInitialize: false,
            pidFileURL: processControl.pidFileURL,
            exitRequestFileURL: processControl.exitRequestFileURL,
            exitLogURL: processControl.exitLogURL
        )
        defer { try? FileManager.default.removeItem(at: commandURL) }

        let supervisor = AppServerSupervisor(
            configuration: .init(
                codexCommand: commandURL.path,
                environment: environment,
                startupTimeout: .seconds(30)
            )
        )

        let prepareTask = Task {
            try await supervisor.prepare()
        }
        let pid = try await waitForPID(at: processControl.pidFileURL)
        let identity = try #require(processIdentity(pid: pid))

        await supervisor.shutdown()

        do {
            _ = try await withTestTimeout {
                try await prepareTask.value
            }
            Issue.record("prepare() unexpectedly succeeded after shutdown during startup.")
        } catch {
            #expect(error.localizedDescription.contains("stopped during startup"))
        }

        try await waitForProcessExit(identity)
    }

    @Test func preparePlacesAppServerInDedicatedProcessGroup() async throws {
        let environment = try makeSupervisorEnvironment()
        let commandURL = try makeFakeSupervisorCommand(
            respondsToInitialize: true
        )
        defer { try? FileManager.default.removeItem(at: commandURL) }

        let supervisor = AppServerSupervisor(
            configuration: .init(
                codexCommand: commandURL.path,
                environment: environment,
                startupTimeout: .seconds(1)
            )
        )

        let runtimeState = try await supervisor.prepare()
        let expectedGroupLeaderPID = try #require(currentProcessGroupID(of: pid_t(runtimeState.pid)))

        #expect(expectedGroupLeaderPID == pid_t(runtimeState.pid))
        #expect(runtimeState.processGroupLeaderPID == runtimeState.pid)
        #expect(runtimeState.processGroupLeaderStartTime == runtimeState.startTime)
        await supervisor.shutdown()
    }

    @Test func shutdownStopsRunningProcess() async throws {
        let environment = try makeSupervisorEnvironment()
        let processControl = try makeSupervisorProcessControlFiles(
            environment: environment,
            basename: "fake-app-server-running"
        )
        let commandURL = try makeFakeSupervisorCommand(
            respondsToInitialize: true,
            pidFileURL: processControl.pidFileURL,
            exitRequestFileURL: processControl.exitRequestFileURL,
            exitLogURL: processControl.exitLogURL
        )
        defer { try? FileManager.default.removeItem(at: commandURL) }

        let supervisor = AppServerSupervisor(
            configuration: .init(
                codexCommand: commandURL.path,
                environment: environment,
                startupTimeout: .seconds(1)
            )
        )

        let runtimeState = try await supervisor.prepare()
        let identity = ProcessIdentity(
            pid: pid_t(runtimeState.pid),
            startTime: runtimeState.startTime
        )

        await supervisor.shutdown()
        try await waitForProcessExit(identity)
    }

    @Test func prepareRelaunchesAfterProcessExit() async throws {
        let environment = try makeSupervisorEnvironment()
        let processControl = try makeSupervisorProcessControlFiles(
            environment: environment,
            basename: "fake-app-server-relaunch"
        )
        let commandURL = try makeFakeSupervisorCommand(
            respondsToInitialize: true,
            exitRequestFileURL: processControl.exitRequestFileURL,
            exitLogURL: processControl.exitLogURL
        )
        defer { try? FileManager.default.removeItem(at: commandURL) }

        let supervisor = AppServerSupervisor(
            configuration: .init(
                codexCommand: commandURL.path,
                environment: environment,
                startupTimeout: .seconds(1)
            )
        )
        defer {
            Task {
                await supervisor.shutdown()
            }
        }

        let firstRuntimeState = try await supervisor.prepare()
        let firstIdentity = ProcessIdentity(
            pid: pid_t(firstRuntimeState.pid),
            startTime: firstRuntimeState.startTime
        )
        try requestSupervisorProcessExit(at: processControl.exitRequestFileURL)
        try await waitForProcessExit(firstIdentity)

        let secondRuntimeState = try await supervisor.prepare()
        #expect(secondRuntimeState.pid != firstRuntimeState.pid)
        #expect(secondRuntimeState.processGroupLeaderPID == secondRuntimeState.pid)
    }

    @Test func prepareSucceedsWhenParentStandardIOIsRedirected() async throws {
        let devNullForInput = try #require(FileHandle(forReadingAtPath: "/dev/null"))
        let devNullForOutput = try #require(FileHandle(forWritingAtPath: "/dev/null"))
        let testExecutableURL = try #require(Bundle.main.executableURL)
        let process = Process()
        process.executableURL = URL(
            fileURLWithPath:
                "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper"
        )
        process.arguments = [
            "--test-bundle-path",
            testExecutableURL.path,
            "--filter",
            "appServerSupervisorStdioProbeRunsUnderRedirectedParentDescriptors",
            testExecutableURL.path,
            "--testing-library",
            "swift-testing",
        ]
        process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        var environment = ProcessInfo.processInfo.environment
        environment["APP_SERVER_STDIO_REDIRECTION_PROBE"] = "1"
        process.environment = environment
        process.standardInput = devNullForInput
        process.standardOutput = devNullForOutput
        process.standardError = devNullForOutput

        try process.run()
        process.waitUntilExit()

        #expect(process.terminationReason == .exit)
        #expect(process.terminationStatus == 0)
    }

    @Test func appServerSupervisorStdioProbeRunsUnderRedirectedParentDescriptors() async throws {
        guard ProcessInfo.processInfo.environment["APP_SERVER_STDIO_REDIRECTION_PROBE"] == "1" else {
            return
        }

        let environment = try makeSupervisorEnvironment()
        let commandURL = try makeFakeSupervisorCommand(
            respondsToInitialize: true,
            configResponseCharacterCount: 1_024
        )
        defer { try? FileManager.default.removeItem(at: commandURL) }

        let supervisor = AppServerSupervisor(
            configuration: .init(
                codexCommand: commandURL.path,
                environment: environment,
                startupTimeout: .seconds(1)
            )
        )
        defer {
            Task {
                await supervisor.shutdown()
            }
        }

        _ = try await supervisor.prepare()
        let transport = try await supervisor.checkoutTransport(sessionID: "stdio-redirect")
        let response: AppServerConfigReadResponse = try await transport.request(
            method: "config/read",
            params: AppServerConfigReadParams(
                cwd: FileManager.default.currentDirectoryPath,
                includeLayers: false
            ),
            responseType: AppServerConfigReadResponse.self
        )
        #expect(response.config.model == "gpt-5.4-mini")
    }

    @Test func prepareFailsWhenProcessLeavesDedicatedGroupBeforeReady() async throws {
        let environment = try makeSupervisorEnvironment()
        let processControl = try makeSupervisorProcessControlFiles(
            environment: environment,
            basename: "fake-app-server-group-change"
        )
        let commandURL = try makeFakeSupervisorCommand(
            respondsToInitialize: true,
            pidFileURL: processControl.pidFileURL,
            exitRequestFileURL: processControl.exitRequestFileURL,
            exitLogURL: processControl.exitLogURL,
            joinParentProcessGroupBeforeInitialize: true
        )
        defer { try? FileManager.default.removeItem(at: commandURL) }

        let supervisor = AppServerSupervisor(
            configuration: .init(
                codexCommand: commandURL.path,
                environment: environment,
                startupTimeout: .seconds(1)
            )
        )

        do {
            _ = try await supervisor.prepare()
            Issue.record("prepare() unexpectedly succeeded after the child left its dedicated process group.")
        } catch {
            #expect(error.localizedDescription.contains("did not remain in its dedicated process group"))
        }

        let pid = try await waitForPID(at: processControl.pidFileURL)
        if let identity = processIdentity(pid: pid) {
            try? requestSupervisorProcessExit(at: processControl.exitRequestFileURL)
            try await waitForProcessExit(identity)
        }
        await supervisor.shutdown()
    }
}

private func makeSupervisorEnvironment() throws -> [String: String] {
    let homeURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("AppServerSupervisorTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
    return [
        "HOME": homeURL.path,
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    ]
}

private struct SupervisorProcessControlFiles {
    let pidFileURL: URL
    let exitRequestFileURL: URL
    let exitLogURL: URL
}

private func makeSupervisorProcessControlFiles(
    environment: [String: String],
    basename: String
) throws -> SupervisorProcessControlFiles {
    guard let homePath = environment["HOME"] else {
        throw TimeoutError()
    }
    let homeURL = URL(fileURLWithPath: homePath)
    let reviewHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
    try FileManager.default.createDirectory(at: reviewHomeURL, withIntermediateDirectories: true)
    return .init(
        pidFileURL: reviewHomeURL.appendingPathComponent("\(basename).pid"),
        exitRequestFileURL: reviewHomeURL.appendingPathComponent("\(basename).exit-request"),
        exitLogURL: reviewHomeURL.appendingPathComponent("\(basename).exit-log")
    )
}

private func makeFakeSupervisorCommand(
    respondsToInitialize: Bool,
    pidFileURL: URL? = nil,
    exitRequestFileURL: URL? = nil,
    exitLogURL: URL? = nil,
    codexHomeCaptureURL: URL? = nil,
    configResponseCharacterCount: Int? = nil,
    responseChunkSize: Int? = nil,
    joinParentProcessGroupBeforeInitialize: Bool = false
) throws -> URL {
    let scriptURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: false)
    let pidFileLiteral = pythonLiteral(pidFileURL?.path)
    let exitRequestLiteral = pythonLiteral(exitRequestFileURL?.path)
    let exitLogLiteral = pythonLiteral(exitLogURL?.path)
    let codexHomeCaptureLiteral = pythonLiteral(codexHomeCaptureURL?.path)
    let respondsToInitializeLiteral = respondsToInitialize ? "True" : "False"
    let configResponseCharacterCountLiteral = configResponseCharacterCount.map(String.init) ?? "None"
    let responseChunkSizeLiteral = responseChunkSize.map(String.init) ?? "None"
    let joinParentProcessGroupLiteral = joinParentProcessGroupBeforeInitialize ? "True" : "False"
    let script = """
    #!/usr/bin/env python3
    import atexit
    import json
    import os
    import select
    import signal
    import sys

    pid_file = \(pidFileLiteral)
    exit_request_file = \(exitRequestLiteral)
    exit_log_file = \(exitLogLiteral)
    codex_home_capture_file = \(codexHomeCaptureLiteral)
    responds_to_initialize = \(respondsToInitializeLiteral)
    config_response_character_count = \(configResponseCharacterCountLiteral)
    response_chunk_size = \(responseChunkSizeLiteral)
    join_parent_process_group_before_initialize = \(joinParentProcessGroupLiteral)

    def record_exit():
        if exit_log_file is None:
            return
        with open(exit_log_file, "a", encoding="utf-8") as handle:
            handle.write(str(os.getpid()) + "\\n")

    def handle_termination(_signum, _frame):
        raise SystemExit(0)

    atexit.register(record_exit)
    signal.signal(signal.SIGTERM, handle_termination)
    signal.signal(signal.SIGINT, handle_termination)

    if pid_file is not None:
        with open(pid_file, "w", encoding="utf-8") as handle:
            handle.write(str(os.getpid()))

    if codex_home_capture_file is not None:
        with open(codex_home_capture_file, "w", encoding="utf-8") as handle:
            handle.write(os.environ.get("CODEX_HOME", ""))

    args = sys.argv[1:]
    while len(args) >= 2 and args[0] == "-c":
        if args[1] != 'cli_auth_credentials_store="file"':
            sys.exit(3)
        args = args[2:]

    if len(args) < 3 or args[0] != "app-server":
        sys.exit(2)

    def write_json_line(message):
        payload = (json.dumps(message) + "\\n").encode("utf-8")
        if response_chunk_size is None:
            sys.stdout.buffer.write(payload)
            sys.stdout.buffer.flush()
            return

        chunk_size = int(response_chunk_size)
        for index in range(0, len(payload), chunk_size):
            sys.stdout.buffer.write(payload[index:index + chunk_size])
            sys.stdout.buffer.flush()

    while True:
        if exit_request_file is not None and os.path.exists(exit_request_file):
            os.unlink(exit_request_file)
            raise SystemExit(0)
        readable, _, _ = select.select([sys.stdin.buffer], [], [], 0.05)
        if not readable:
            continue
        line = sys.stdin.buffer.readline()
        if line == b"":
            continue
        message = json.loads(line.decode("utf-8"))
        if message.get("method") == "initialize" and responds_to_initialize:
            if join_parent_process_group_before_initialize:
                os.setpgid(0, os.getpgid(os.getppid()))
            response = {
                "id": message.get("id"),
                "result": {
                    "platformFamily": "macOS",
                    "platformOs": "Darwin"
                }
            }
            write_json_line(response)
        elif message.get("method") == "config/read" and config_response_character_count is not None:
            response = {
                "id": message.get("id"),
                "result": {
                    "config": {
                        "model": "gpt-5.4-mini",
                        "review_model": "gpt-5.4-mini",
                        "padding": "x" * int(config_response_character_count)
                    }
                }
            }
            write_json_line(response)
    """

    try script.write(to: scriptURL, atomically: true, encoding: String.Encoding.utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    return scriptURL
}

private func waitForPID(
    at fileURL: URL,
    timeout: Duration = .seconds(2)
) async throws -> pid_t {
    try await withTestTimeout(timeout) {
        if let pid = try readPID(from: fileURL) {
            return pid
        }

        let monitor = try DirectoryChangeMonitor(directoryURL: fileURL.deletingLastPathComponent())
        defer { monitor.cancel() }

        var observedEventCount = await monitor.eventCount()
        while true {
            if let pid = try readPID(from: fileURL) {
                return pid
            }
            await monitor.waitForChange(after: observedEventCount)
            observedEventCount = await monitor.eventCount()
        }
    }
}

private func readPID(from fileURL: URL) throws -> pid_t? {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
        return nil
    }
    let text = try String(contentsOf: fileURL, encoding: .utf8)
    return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
}

private func processIdentity(pid: pid_t) -> ProcessIdentity? {
    guard let startTime = processStartTime(of: pid) else {
        return nil
    }
    return ProcessIdentity(pid: pid, startTime: startTime)
}

private func waitForProcessExit(
    _ identity: ProcessIdentity,
    timeout: Duration = .seconds(2)
) async throws {
    try await withTestTimeout(timeout) {
        while isMatchingProcessIdentity(identity) {
            await Task.yield()
        }
    }
}

private func requestSupervisorProcessExit(at fileURL: URL) throws {
    if FileManager.default.fileExists(atPath: fileURL.path) == false {
        FileManager.default.createFile(atPath: fileURL.path, contents: Data())
    }
}

private func withTestTimeout<T: Sendable>(
    _ timeout: Duration = .seconds(2),
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw TimeoutError()
        }
        defer { group.cancelAll() }
        return try await #require(group.next())
    }
}

private func pythonLiteral(_ value: String?) -> String {
    guard let value else {
        return "None"
    }
    let escaped = value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
    return "\"\(escaped)\""
}

private func makeExecutableDirectory(named name: String, from executableURL: URL) throws -> URL {
    let directoryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("AppServerSupervisorExec-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    let linkedURL = directoryURL.appendingPathComponent(name)
    try FileManager.default.copyItem(at: executableURL, to: linkedURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: linkedURL.path)
    return directoryURL
}

private actor ConnectionBox {
    private var storedConnection: AppServerSharedTransportConnection?

    func setConnection(_ connection: AppServerSharedTransportConnection) {
        storedConnection = connection
    }

    func connection() -> AppServerSharedTransportConnection? {
        storedConnection
    }
}

private func driveClockUntilSignal(
    _ signal: AsyncSignal,
    clock: ManualTestClock,
    step: Duration = .milliseconds(100),
    timeout: Duration = .seconds(2)
) async throws {
    try await withTestTimeout(timeout) {
        while await signal.count() == 0 {
            if clock.hasSleepers {
                await clock.sleepUntilSuspendedBy(1)
                clock.advance(by: step)
            } else {
                await Task.yield()
            }
        }
    }
}

private struct TimeoutError: Error {}
