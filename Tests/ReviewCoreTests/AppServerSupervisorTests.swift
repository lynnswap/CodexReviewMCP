import Foundation
import Testing
@testable import CodexAppServer

@Suite
struct CodexAppServerSupervisorTests {
    @Test func loopbackWebSocketListenURLUsesEphemeralPort() throws {
        let url = try makeLoopbackWebSocketListenURL()

        #expect(url.absoluteString == "ws://127.0.0.1:0")
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

    @Test func prepareSucceedsWithoutStartupBannerByInspectingListeningSocket() async throws {
        let scriptURL = try makeEmbeddedAppServerScript(mode: "silent-ready")
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let supervisor = CodexAppServerSupervisor(
            configuration: .init(
                codexCommand: scriptURL.path,
                environment: try isolatedHomeEnvironment(),
                startupTimeout: .seconds(2)
            )
        )

        let runtimeState = try await withTestTimeout(seconds: 5) {
            try await supervisor.prepare()
        }
        defer { Task { await supervisor.shutdown() } }

        #expect(runtimeState.pid > 0)
        #expect(await supervisor.currentRuntimeState() == runtimeState)
        #expect(await supervisor.diagnosticsTail().isEmpty)
    }

    @Test func prepareTimeoutFailsWithoutLeavingSupervisorStuck() async throws {
        let scriptURL = try makeEmbeddedAppServerScript(mode: "silent-hang")
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let supervisor = CodexAppServerSupervisor(
            configuration: .init(
                codexCommand: scriptURL.path,
                environment: try isolatedHomeEnvironment(),
                startupTimeout: .milliseconds(200)
            )
        )
        defer { Task { await supervisor.shutdown() } }

        do {
            _ = try await withTestTimeout(seconds: 5) {
                try await supervisor.prepare()
            }
            throw TestFailure("expected startup timeout")
        } catch {
            let message = String(describing: error)
            #expect(message.contains("timed out waiting for app-server readiness"))
        }

        #expect(await supervisor.currentRuntimeState() == nil)

        do {
            _ = try await withTestTimeout(seconds: 5) {
                try await supervisor.prepare()
            }
            throw TestFailure("expected second startup timeout")
        } catch {
            let message = String(describing: error)
            #expect(message.contains("timed out waiting for app-server readiness"))
        }
    }
}

private func makeEmbeddedAppServerScript(mode: String) throws -> URL {
    let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let modeLiteral = try pythonLiteral(mode)
    let script = """
    #!/usr/bin/env python3
    import http.server
    import signal
    import socketserver
    import sys
    import threading
    import time

    mode = \(modeLiteral)

    if len(sys.argv) < 4 or sys.argv[1] != "app-server" or sys.argv[2] != "--listen":
        sys.stderr.write("unexpected args: " + " ".join(sys.argv[1:]) + "\\n")
        sys.stderr.flush()
        sys.exit(2)

    def exit_now(signum, frame):
        raise SystemExit(0)

    if mode == "silent-hang":
        signal.signal(signal.SIGTERM, exit_now)
        signal.signal(signal.SIGINT, exit_now)
        while True:
            time.sleep(1)

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path in ("/readyz", "/healthz"):
                self.send_response(200)
                self.send_header("Content-Length", "0")
                self.end_headers()
            else:
                self.send_response(404)
                self.send_header("Content-Length", "0")
                self.end_headers()

        def log_message(self, format, *args):
            pass

    class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
        daemon_threads = True

    server = Server(("127.0.0.1", 0), Handler)

    def shutdown(signum, frame):
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    try:
        server.serve_forever(poll_interval=0.05)
    finally:
        server.server_close()
    """.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"

    try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    return scriptURL
}

private func pythonLiteral(_ value: String) throws -> String {
    let escaped = value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
    return "\"\(escaped)\""
}

private func isolatedHomeEnvironment(extra: [String: String] = [:]) throws -> [String: String] {
    var environment = ["HOME": try makeTemporaryDirectory().path]
    for (key, value) in extra {
        environment[key] = value
    }
    return environment
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func withTestTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw TestFailure("timed out after \(seconds) seconds")
        }
        let result = try await group.next()
        group.cancelAll()
        return try #require(result)
    }
}

private struct TestFailure: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}
