import Foundation

package enum ReviewHomePaths {
    private static let reviewMCPManagedPrefix = "review_mcp_"

    package static func reviewHomeURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let home = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           home.isEmpty == false
        {
            return URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(".codex_review", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex_review", isDirectory: true)
    }

    package static func reviewConfigURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        reviewHomeURL(environment: environment)
            .appendingPathComponent("config.toml")
    }

    package static func reviewAuthURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        reviewHomeURL(environment: environment)
            .appendingPathComponent("auth.json")
    }

    package static func reviewAgentsURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        reviewHomeURL(environment: environment)
            .appendingPathComponent("AGENTS.md")
    }

    package static func discoveryFileURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        reviewHomeURL(environment: environment)
            .appendingPathComponent("review_mcp_endpoint.json")
    }

    package static func runtimeStateFileURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        reviewHomeURL(environment: environment)
            .appendingPathComponent("review_mcp_runtime_state.json")
    }

    package static func appServerWebSocketTokenFileURL(
        launchID: UUID,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        reviewHomeURL(environment: environment)
            .appendingPathComponent("review_mcp_app_server_ws_token-\(launchID.uuidString)")
    }

    package static func appServerCodexHomeURL(
        launchID: UUID,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        reviewHomeURL(environment: environment)
            .appendingPathComponent("review_mcp_app_server_codex_home-\(launchID.uuidString)", isDirectory: true)
    }

    package static func codexHomeURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        reviewHomeURL(environment: environment)
    }

    package static func resolvedCodexHomeURL(
        appServerCodexHome: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        _ = appServerCodexHome
        return codexHomeURL(environment: environment)
    }

    package static func codexConfigURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        codexHome: URL? = nil
    ) -> URL {
        (codexHome ?? codexHomeURL(environment: environment))
            .appendingPathComponent("config.toml")
    }

    package static func modelsCacheURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        codexHome: URL? = nil
    ) -> URL {
        (codexHome ?? codexHomeURL(environment: environment))
            .appendingPathComponent("models_cache.json")
    }

    package static func ensureReviewHomeScaffold(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        let homeURL = reviewHomeURL(environment: environment)
        try ensureReviewHomeScaffold(at: homeURL)
    }

    package static func ensureReviewHomeScaffold(at homeURL: URL) throws {
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        try createEmptyFileIfMissing(at: homeURL.appendingPathComponent("config.toml"))
        try createEmptyFileIfMissing(at: homeURL.appendingPathComponent("AGENTS.md"))
    }

    package static func isReviewMCPManagedHomeItem(name: String) -> Bool {
        name.hasPrefix(reviewMCPManagedPrefix)
    }

    package static func isLegacyReviewMCPHomeItem(name: String) -> Bool {
        name == "endpoint.json"
            || name == "runtime-state.json"
            || name.hasPrefix("app-server-ws-token-")
            || name.hasPrefix("app-server-codex-home-")
    }

    package static func shouldExcludeFromAppServerSeed(name: String) -> Bool {
        isReviewMCPManagedHomeItem(name: name) || isLegacyReviewMCPHomeItem(name: name)
    }

    private static func createEmptyFileIfMissing(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) == false else {
            return
        }
        try Data().write(to: url)
    }
}
