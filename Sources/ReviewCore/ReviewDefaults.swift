import Foundation

package struct ReviewDefaults: Codable, Sendable {
    package struct Server: Codable, Sendable {
        package var defaultPort: Int
        package var endpointPath: String
        package var sessionTimeoutSeconds: Double
    }

    package struct Review: Codable, Sendable {
        package var defaultModel: String
        package var hideAgentReasoning: Bool
        package var reasoningEffort: String
        package var reasoningSummary: String
        package var autoCompactRatio: Double
    }

    package struct Models: Codable, Sendable {
        package var fallbackContextWindows: [String: Int]
        package var wideContextPrefixes: [String]
        package var gpt54AndAboveClampLimit: Int
        package var defaultWideContextClampLimit: Int
        package var sparkClampLimit: Int
    }

    package var server: Server
    package var review: Review
    package var models: Models

    package static let shared: ReviewDefaults = {
        guard let url = Bundle.module.url(forResource: "defaults", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(ReviewDefaults.self, from: data)
        else {
            return ReviewDefaults(
                server: .init(defaultPort: 9417, endpointPath: "/mcp", sessionTimeoutSeconds: 3600),
                review: .init(
                    defaultModel: "gpt-5.4-mini",
                    hideAgentReasoning: false,
                    reasoningEffort: "xhigh",
                    reasoningSummary: "detailed",
                    autoCompactRatio: 0.9
                ),
                models: .init(
                    fallbackContextWindows: [
                        "gpt-5.4-mini": 272_000,
                        "gpt-5.3-codex-spark": 128_000,
                    ],
                    wideContextPrefixes: [
                        "gpt-5.3-codex",
                        "gpt-5.2-codex",
                        "gpt-5.2",
                        "gpt-5.1-codex-max",
                        "gpt-5.1-codex-mini",
                        "gpt-5.1-codex",
                    ],
                    gpt54AndAboveClampLimit: 1_000_000,
                    defaultWideContextClampLimit: 272_000,
                    sparkClampLimit: 128_000
                )
            )
        }
        return decoded
    }()
}
