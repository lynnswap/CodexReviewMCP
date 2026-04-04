import Foundation

package enum ReviewHomePaths {
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

    package static func discoveryFileURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        reviewHomeURL(environment: environment)
            .appendingPathComponent("endpoint.json")
    }

    package static func runtimeStateFileURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        reviewHomeURL(environment: environment)
            .appendingPathComponent("runtime-state.json")
    }

    package static func appServerWebSocketTokenFileURL(
        filename: String = "app-server-ws-token",
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        reviewHomeURL(environment: environment)
            .appendingPathComponent(filename)
    }

    package static func codexHomeURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        if let codexHome = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           codexHome.isEmpty == false
        {
            return URL(fileURLWithPath: codexHome, isDirectory: true)
        }
        if let home = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           home.isEmpty == false
        {
            return URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(".codex", isDirectory: true)
        }
        return nil
    }

    package static func resolvedCodexHomeURL(
        appServerCodexHome: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        if let appServerCodexHomeURL = validatedAppServerCodexHomeURL(appServerCodexHome) {
            return appServerCodexHomeURL
        }
        return codexHomeURL(environment: environment)
    }

    package static func codexConfigURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        codexHome: URL? = nil
    ) -> URL? {
        (codexHome ?? codexHomeURL(environment: environment))?
            .appendingPathComponent("config.toml")
    }

    package static func modelsCacheURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        codexHome: URL? = nil
    ) -> URL? {
        (codexHome ?? codexHomeURL(environment: environment))?
            .appendingPathComponent("models_cache.json")
    }

    private static func validatedAppServerCodexHomeURL(_ rawPath: String?) -> URL? {
        guard let rawPath = rawPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              rawPath.isEmpty == false,
              rawPath.hasPrefix("/")
        else {
            return nil
        }
        return URL(fileURLWithPath: rawPath, isDirectory: true)
    }
}
