import Foundation
import Testing
@testable import ReviewCore

@Suite(.serialized)
struct AppServerSupervisorTests {
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

    @Test func isolatedCodexHomeConfigRemovesCodexReviewServerSection() {
        let original = """
        model = "gpt-5.4"

        [mcp_servers.github]
        url = "https://example.com/github"

        [mcp_servers.codex_review]
        url = "http://localhost:9417/mcp"
        startup_timeout_sec = 2400.0
        tool_timeout_sec = 2400.0

        [notice]
        hide_full_access_warning = true
        """

        let filtered = isolatedCodexHomeConfigText(from: original)

        #expect(filtered.contains("[mcp_servers.github]"))
        #expect(filtered.contains("https://example.com/github"))
        #expect(filtered.contains("[notice]"))
        #expect(filtered.contains("hide_full_access_warning = true"))
        #expect(filtered.contains("[mcp_servers.codex_review]") == false)
        #expect(filtered.contains("startup_timeout_sec = 2400.0") == false)
        #expect(filtered.contains("tool_timeout_sec = 2400.0") == false)
    }

    @Test func isolatedCodexHomeConfigLeavesConfigUntouchedWhenCodexReviewSectionIsMissing() {
        let original = """
        model = "gpt-5.4"

        [mcp_servers.github]
        url = "https://example.com/github"
        """

        let filtered = isolatedCodexHomeConfigText(from: original)

        #expect(filtered.contains("[mcp_servers.github]"))
        #expect(filtered.contains("[mcp_servers.codex_review]") == false)
        #expect(filtered.contains("enabled = false") == false)
    }

    @Test func isolatedCodexHomeConfigRemovesLiteralQuotedCodexReviewSection() {
        let original = """
        model = "gpt-5.4"

        [mcp_servers.'codex_review']
        url = "http://localhost:9417/mcp"

        [mcp_servers.github]
        url = "https://example.com/github"
        """

        let filtered = isolatedCodexHomeConfigText(from: original)

        #expect(filtered.contains("[mcp_servers.'codex_review']") == false)
        #expect(filtered.contains("http://localhost:9417/mcp") == false)
        #expect(filtered.contains("[mcp_servers.github]"))
    }

    @Test func isolatedCodexHomeConfigRemovesCodexReviewSectionWithTrailingComment() {
        let original = """
        [mcp_servers.codex_review] # local review bridge
        url = "http://localhost:9417/mcp"

        [mcp_servers.github]
        url = "https://example.com/github"
        """

        let filtered = isolatedCodexHomeConfigText(from: original)

        #expect(filtered.contains("[mcp_servers.codex_review]") == false)
        #expect(filtered.contains("http://localhost:9417/mcp") == false)
        #expect(filtered.contains("[mcp_servers.github]"))
    }

    @Test func prepareIsolatedCodexHomeCopiesDedicatedHomeAndSkipsManagedFiles() throws {
        let homeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppServerSupervisorSeed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        let reviewHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        try FileManager.default.createDirectory(at: reviewHomeURL, withIntermediateDirectories: true)

        try """
        model = "gpt-5.4"

        [mcp_servers.codex_review]
        url = "http://localhost:9417/mcp"
        """.write(
            to: reviewHomeURL.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
        try "review instructions".write(
            to: reviewHomeURL.appendingPathComponent("AGENTS.md"),
            atomically: true,
            encoding: .utf8
        )
        try "auth".write(
            to: reviewHomeURL.appendingPathComponent("auth.json"),
            atomically: true,
            encoding: .utf8
        )
        try "cache".write(
            to: reviewHomeURL.appendingPathComponent("models_cache.json"),
            atomically: true,
            encoding: .utf8
        )
        try "managed".write(
            to: reviewHomeURL.appendingPathComponent("review_mcp_endpoint.json"),
            atomically: true,
            encoding: .utf8
        )
        try "legacy".write(
            to: reviewHomeURL.appendingPathComponent("endpoint.json"),
            atomically: true,
            encoding: .utf8
        )
        try "legacy token".write(
            to: reviewHomeURL.appendingPathComponent("app-server-ws-token-legacy"),
            atomically: true,
            encoding: .utf8
        )

        let isolatedURL = try prepareIsolatedCodexHome(
            launchID: UUID(),
            environment: ["HOME": homeURL.path]
        )
        defer { try? FileManager.default.removeItem(at: homeURL) }

        #expect(FileManager.default.fileExists(atPath: isolatedURL.appendingPathComponent("AGENTS.md").path))
        #expect(FileManager.default.fileExists(atPath: isolatedURL.appendingPathComponent("auth.json").path))
        #expect(FileManager.default.fileExists(atPath: isolatedURL.appendingPathComponent("models_cache.json").path))
        #expect(
            FileManager.default.fileExists(
                atPath: isolatedURL.appendingPathComponent("review_mcp_endpoint.json").path
            ) == false
        )
        #expect(
            FileManager.default.fileExists(atPath: isolatedURL.appendingPathComponent("endpoint.json").path)
                == false
        )
        #expect(
            FileManager.default.fileExists(
                atPath: isolatedURL.appendingPathComponent("app-server-ws-token-legacy").path
            ) == false
        )

        let configText = try String(
            contentsOf: isolatedURL.appendingPathComponent("config.toml"),
            encoding: .utf8
        )
        #expect(configText.contains("[mcp_servers.codex_review]") == false)
        #expect(configText.contains("model = \"gpt-5.4\""))
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

    @Test func prepareTimeoutStopsStartingProcess() async throws {
        let environment = try makeSupervisorEnvironment()
        let pidFileURL = URL(fileURLWithPath: environment["HOME"]!)
            .appendingPathComponent("fake-app-server.pid")
        let commandURL = try makeFakeSupervisorCommand(
            respondsToInitialize: false,
            pidFileURL: pidFileURL,
            autoExitSeconds: 1
        )
        defer { try? FileManager.default.removeItem(at: commandURL) }

        let supervisor = AppServerSupervisor(
            configuration: .init(
                codexCommand: commandURL.path,
                environment: environment,
                startupTimeout: .milliseconds(300)
            )
        )

        do {
            _ = try await supervisor.prepare()
            Issue.record("prepare() unexpectedly succeeded without an initialize response.")
        } catch {
            #expect(error.localizedDescription.contains("timed out waiting for app-server initialization"))
        }

        let pidText = try String(contentsOf: pidFileURL, encoding: .utf8)
        let pid = try #require(Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)))
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if isProcessAlive(pid) == false {
                await supervisor.shutdown()
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        await supervisor.shutdown()
        Issue.record("starting app-server child was still alive after prepare timed out.")
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

private func makeFakeSupervisorCommand(
    respondsToInitialize: Bool,
    pidFileURL: URL? = nil,
    autoExitSeconds: Double? = nil
) throws -> URL {
    let scriptURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: false)
    let pidFileLiteral = pythonLiteral(pidFileURL?.path)
    let respondsToInitializeLiteral = respondsToInitialize ? "True" : "False"
    let autoExitSecondsLiteral = autoExitSeconds.map { String(describing: $0) } ?? "None"
    let script = """
    #!/usr/bin/env python3
    import json
    import os
    import sys
    import time

    pid_file = \(pidFileLiteral)
    responds_to_initialize = \(respondsToInitializeLiteral)
    auto_exit_seconds = \(autoExitSecondsLiteral)

    if pid_file is not None:
        with open(pid_file, "w", encoding="utf-8") as handle:
            handle.write(str(os.getpid()))

    args = sys.argv[1:]
    if len(args) < 3 or args[0] != "app-server":
        sys.exit(2)

    deadline = None if auto_exit_seconds is None else time.monotonic() + float(auto_exit_seconds)

    while True:
        if deadline is not None and time.monotonic() >= deadline:
            os._exit(0)
        line = sys.stdin.buffer.readline()
        if line == b"":
            time.sleep(0.05)
            continue
        message = json.loads(line.decode("utf-8"))
        if message.get("method") == "initialize" and responds_to_initialize:
            response = {
                "id": message.get("id"),
                "result": {
                    "platformFamily": "macOS",
                    "platformOs": "Darwin"
                }
            }
            sys.stdout.buffer.write((json.dumps(response) + "\\n").encode("utf-8"))
            sys.stdout.buffer.flush()
    """

    try script.write(to: scriptURL, atomically: true, encoding: String.Encoding.utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    return scriptURL
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

private actor ConnectionBox {
    private var storedConnection: AppServerSharedTransportConnection?

    func setConnection(_ connection: AppServerSharedTransportConnection) {
        storedConnection = connection
    }

    func connection() -> AppServerSharedTransportConnection? {
        storedConnection
    }
}
