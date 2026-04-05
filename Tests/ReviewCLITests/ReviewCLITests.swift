import Foundation
import Testing
import CodexReviewModel
@testable import ReviewCore
@testable import ReviewCLI

@Suite struct ReviewCLITests {
    @Test func parseListenAddressAcceptsBracketedIPv6() throws {
        let (host, port) = try parseListenAddress("[::1]:9417")

        #expect(host == "::1")
        #expect(port == 9417)
    }

    @Test func parseListenAddressRejectsEmptyHost() {
        #expect(throws: Error.self) {
            _ = try parseListenAddress(":9417")
        }
    }

    @Test func adapterURLFromEnvironmentRejectsInvalidValue() {
        #expect(throws: Error.self) {
            _ = try adapterURLFromEnvironment(["CODEX_REVIEW_MCP_ENDPOINT": "://bad-url"])
        }
    }

    @Test func parseAdapterOptionsPrefersExplicitURLOverInvalidEnvironment() throws {
        let options = try parseAdapterOptions(
            args: ["codex-review-mcp", "--url", "http://localhost:9417/mcp"],
            environment: ["CODEX_REVIEW_MCP_ENDPOINT": "://bad-url"]
        )

        #expect(options.url.absoluteString == "http://localhost:9417/mcp")
    }

    @Test func discoveryMatchesListenAddressRequiresMatchingPort() {
        let discovery = LiveEndpointRecord(
            url: "http://localhost:9417/mcp",
            host: "localhost",
            port: 9417,
            pid: 1,
            serverStartTime: .init(seconds: 1, microseconds: 0),
            updatedAt: Date(),
            executableName: "codex-review-mcp-server"
        )

        #expect(discoveryMatchesListenAddress(discovery, host: "0.0.0.0", port: 9417))
        #expect(discoveryMatchesListenAddress(discovery, host: "127.0.0.1", port: 9417))
        #expect(discoveryMatchesListenAddress(discovery, host: "::1", port: 9417))
        #expect(discoveryMatchesListenAddress(discovery, host: "0.0.0.0", port: 9999) == false)
    }

    @Test func discoveryMatchesListenAddressResolvesConfiguredHostname() {
        let discovery = LiveEndpointRecord(
            url: "http://192.0.2.15:9417/mcp",
            host: "192.0.2.15",
            port: 9417,
            pid: 1,
            serverStartTime: .init(seconds: 1, microseconds: 0),
            updatedAt: Date(),
            executableName: "codex-review-mcp-server"
        )

        let resolver: (String) -> Set<String> = { host in
            switch host {
            case "review-box.local":
                ["192.0.2.15", "fe80::1"]
            default:
                []
            }
        }

        #expect(discoveryMatchesListenAddress(discovery, host: "review-box.local", port: 9417, resolver: resolver))
        #expect(discoveryMatchesListenAddress(discovery, host: "review-box.local", port: 9999, resolver: resolver) == false)
    }

    @Test func parseLoginOptionsSeparatesWrapperFlagsFromCodexLoginArgs() throws {
        let options = try parseLoginOptions(
            args: [
                "codex-review-mcp-login",
                "--codex-command", "/opt/homebrew/bin/codex",
            ]
        )

        #expect(options.codexCommand == "/opt/homebrew/bin/codex")
        #expect(options.action == .login)
    }

    @Test func parseLoginOptionsRejectsDeviceAuthFlag() {
        #expect(throws: Error.self) {
            _ = try parseLoginOptions(
                args: [
                    "codex-review-mcp-login",
                    "--device-auth",
                ]
            )
        }
    }

    @Test func parseLoginOptionsRejectsAPIKeyFlag() {
        #expect(throws: Error.self) {
            _ = try parseLoginOptions(
                args: [
                    "codex-review-mcp-login",
                    "--with-api-key",
                ]
            )
        }
    }

    @Test func parseLoginOptionsSupportsStatusAndLogout() throws {
        let status = try parseLoginOptions(args: ["codex-review-mcp-login", "status"])
        let logout = try parseLoginOptions(args: ["codex-review-mcp-login", "logout"])

        #expect(status.action == .status)
        #expect(logout.action == .logout)
    }

    @Test func loginStatusMessageReflectsAuthenticationState() {
        #expect(loginStatusMessage(.signedOut) == "Not logged in")
        #expect(loginStatusMessage(.signedIn(accountID: "review@example.com")) == "Logged in using ChatGPT")
    }

    @Test func renderLoginUpdateIncludesBrowserFallbackURL() {
        let rendered = renderLoginUpdate(
            .signingIn(
                .init(
                    title: "Sign in with ChatGPT",
                    detail: "Finish signing in via your browser.",
                    browserURL: "https://auth.openai.com/oauth/authorize?fake=1"
                )
            )
        )

        #expect(rendered.contains("If your browser did not open"))
        #expect(rendered.contains("https://auth.openai.com/oauth/authorize?fake=1"))
    }

}
