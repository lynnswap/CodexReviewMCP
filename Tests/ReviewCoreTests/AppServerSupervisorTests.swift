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
}
