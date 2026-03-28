import Foundation
import Testing
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
        let discovery = ReviewDiscoveryRecord(
            url: "http://localhost:9417/mcp",
            host: "localhost",
            port: 9417,
            pid: 1,
            updatedAt: Date(),
            executableName: "codex-review-mcp-server"
        )

        #expect(discoveryMatchesListenAddress(discovery, host: "0.0.0.0", port: 9417))
        #expect(discoveryMatchesListenAddress(discovery, host: "127.0.0.1", port: 9417))
        #expect(discoveryMatchesListenAddress(discovery, host: "::1", port: 9417))
        #expect(discoveryMatchesListenAddress(discovery, host: "0.0.0.0", port: 9999) == false)
    }

    @Test func discoveryMatchesListenAddressResolvesConfiguredHostname() {
        let discovery = ReviewDiscoveryRecord(
            url: "http://192.0.2.15:9417/mcp",
            host: "192.0.2.15",
            port: 9417,
            pid: 1,
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
}
