import Foundation
import Testing
@testable import ReviewCore

@Suite(.serialized)
struct AppServerSupervisorTests {
    @Test func loopbackWebSocketListenURLUsesReservedPort() throws {
        let url = try makeLoopbackWebSocketListenURL()

        #expect(url.host == "127.0.0.1")
        #expect((url.port ?? 0) > 0)
    }

    @Test func discoveredWebSocketURLParsesStartupBannerLine() throws {
        let url = discoveredWebSocketURL(from: [
            "codex app-server (WebSockets)",
            "  listening on: ws://127.0.0.1:60421",
            "  readyz: http://127.0.0.1:60421/readyz",
        ])

        #expect(url?.absoluteString == "ws://127.0.0.1:60421")
    }

    @Test func discoveredWebSocketURLStripsANSIEscapeCodes() throws {
        let url = discoveredWebSocketURL(from: [
            "\u{1b}[2m  listening on:\u{1b}[0m \u{1b}[32mws://127.0.0.1:60422\u{1b}[0m"
        ])

        #expect(url?.absoluteString == "ws://127.0.0.1:60422")
    }

    @Test func discoveredWebSocketURLIgnoresEphemeralPlaceholderPort() {
        let url = discoveredWebSocketURL(from: [
            "ws://127.0.0.1:0"
        ])

        #expect(url == nil)
    }

    @Test func discoveredWebSocketURLIgnoresNonBannerWebSocketLines() {
        let url = discoveredWebSocketURL(from: [
            "debug: retrying ws://127.0.0.1:60424 after auth failure"
        ])

        #expect(url == nil)
    }

    @Test func nextDiscoveredWebSocketURLKeepsCachedURLAfterBannerEviction() throws {
        let cached = URL(string: "ws://127.0.0.1:60423")

        let url = nextDiscoveredWebSocketURL(
            cached: cached,
            stderrLines: Array(repeating: "other stderr", count: 400)
        )

        #expect(url?.absoluteString == "ws://127.0.0.1:60423")
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

    @Test func prepareUsesRequestedReadyURLWithoutStartupBanner() async throws {
        let environment = try makeSupervisorEnvironment()
        let commandURL = try makeFakeSupervisorCommand(
            servesReadyz: true,
            writesStartupBanner: false,
            autoExitSeconds: 1
        )
        defer { try? FileManager.default.removeItem(at: commandURL) }

        let supervisor = AppServerSupervisor(
            configuration: .init(
                codexCommand: commandURL.path,
                environment: environment,
                startupTimeout: .seconds(2)
            )
        )

        let runtimeState = try await supervisor.prepare()

        #expect(runtimeState.pid > 0)
        await supervisor.shutdown()
    }

    @Test func prepareTimeoutStopsStartingProcess() async throws {
        let environment = try makeSupervisorEnvironment()
        let pidFileURL = URL(fileURLWithPath: environment["HOME"]!)
            .appendingPathComponent("fake-app-server.pid")
        let commandURL = try makeFakeSupervisorCommand(
            servesReadyz: false,
            writesStartupBanner: false,
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
            Issue.record("prepare() unexpectedly succeeded without a ready endpoint.")
        } catch {
            #expect(error.localizedDescription.contains("timed out waiting for app-server readiness"))
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
    servesReadyz: Bool,
    writesStartupBanner: Bool,
    pidFileURL: URL? = nil,
    autoExitSeconds: Double? = nil
) throws -> URL {
    let scriptURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: false)
    let pidFileLiteral = pythonLiteral(pidFileURL?.path)
    let servesReadyzLiteral = servesReadyz ? "True" : "False"
    let writesStartupBannerLiteral = writesStartupBanner ? "True" : "False"
    let autoExitSecondsLiteral = autoExitSeconds.map { String(describing: $0) } ?? "None"
    let script = """
    #!/usr/bin/env python3
    import http.server
    import os
    import socketserver
    import sys
    import time
    import urllib.parse

    pid_file = \(pidFileLiteral)
    serves_readyz = \(servesReadyzLiteral)
    writes_startup_banner = \(writesStartupBannerLiteral)
    auto_exit_seconds = \(autoExitSecondsLiteral)

    if pid_file is not None:
        with open(pid_file, "w", encoding="utf-8") as handle:
            handle.write(str(os.getpid()))

    args = sys.argv[1:]
    if len(args) < 5 or args[0] != "app-server":
        sys.exit(2)

    listen_index = args.index("--listen")
    listen_url = urllib.parse.urlparse(args[listen_index + 1])
    port = listen_url.port
    host = listen_url.hostname or "127.0.0.1"
    deadline = None if auto_exit_seconds is None else time.monotonic() + float(auto_exit_seconds)

    if serves_readyz:
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path in ("/readyz", "/healthz"):
                    self.send_response(200)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                self.send_response(404)
                self.send_header("Content-Length", "0")
                self.end_headers()

            def log_message(self, format, *args):
                return

        class TCPServer(socketserver.TCPServer):
            allow_reuse_address = True

        httpd = TCPServer((host, port), Handler)
        if writes_startup_banner:
            sys.stderr.write(f"codex app-server (WebSockets)\\n  listening on: ws://{host}:{port}\\n")
            sys.stderr.flush()
        while True:
            if deadline is not None and time.monotonic() >= deadline:
                os._exit(0)
            httpd.handle_request()
    else:
        while True:
            if deadline is not None and time.monotonic() >= deadline:
                os._exit(0)
            time.sleep(0.05)
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
