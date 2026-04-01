import Foundation
import ReviewJobs

package struct AppServerCommand: Sendable {
    package var executable: String
    package var arguments: [String]
    package var environment: [String: String]
    package var currentDirectory: String
}

package struct ReviewExecutionSettings: Sendable {
    package var command: AppServerCommand
    package var threadStart: AppServerThreadStartParams
    package var reviewStart: AppServerReviewStartParams
}

package struct ReviewExecutionSettingsBuilder: Sendable {
    package var codexCommand: String
    package var environment: [String: String]

    package init(
        codexCommand: String = "codex",
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.codexCommand = codexCommand
        self.environment = environment
    }

    package func build(request: ReviewRequestOptions) throws -> ReviewExecutionSettings {
        let request = try request.validated()
        let configPath = resolveConfigPath()
        let modelsCache = loadJSONDictionary(at: resolveModelsCachePath())
        let model = request.model?.nilIfEmpty ?? ReviewDefaults.shared.review.defaultModel
        let profileKey = readTopLevelString(from: configPath, key: "profile")

        var config: [String: AppServerJSONValue] = [
            "hide_agent_reasoning": .bool(ReviewDefaults.shared.review.hideAgentReasoning),
            "model_reasoning_effort": .string(ReviewDefaults.shared.review.reasoningEffort),
            "model_reasoning_summary": .string(ReviewDefaults.shared.review.reasoningSummary),
        ]

        if let clampedContextWindow = computeForcedIntegerOverride(
            modelSlug: model,
            key: "model_context_window",
            configPath: configPath,
            profileKey: profileKey,
            modelsCache: modelsCache
        ) {
            config["model_context_window"] = .int(clampedContextWindow)
        }

        if let clampedAutoCompactLimit = computeForcedIntegerOverride(
            modelSlug: model,
            key: "model_auto_compact_token_limit",
            configPath: configPath,
            profileKey: profileKey,
            modelsCache: modelsCache
        ) {
            config["model_auto_compact_token_limit"] = .int(clampedAutoCompactLimit)
        }

        return ReviewExecutionSettings(
            command: AppServerCommand(
                executable: codexCommand,
                arguments: ["app-server", "--listen", "stdio://"],
                environment: environment,
                currentDirectory: request.cwd
            ),
            threadStart: AppServerThreadStartParams(
                model: model,
                cwd: request.cwd,
                approvalPolicy: "never",
                sandbox: "danger-full-access",
                config: config,
                personality: "none",
                ephemeral: true
            ),
            reviewStart: AppServerReviewStartParams(
                threadID: "",
                target: request.target,
                delivery: "inline"
            )
        )
    }

    private func resolveCodexHome() -> URL? {
        if let codexHome = environment["CODEX_HOME"]?.nilIfEmpty {
            return URL(fileURLWithPath: codexHome, isDirectory: true)
        }
        if let home = environment["HOME"]?.nilIfEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(".codex", isDirectory: true)
        }
        return nil
    }

    private func resolveConfigPath() -> URL? {
        resolveCodexHome()?.appendingPathComponent("config.toml")
    }

    private func resolveModelsCachePath() -> URL? {
        resolveCodexHome()?.appendingPathComponent("models_cache.json")
    }
}

private func loadJSONDictionary(at path: URL?) -> [String: Any] {
    guard let path, let data = try? Data(contentsOf: path) else {
        return [:]
    }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

private func lookupModelContextWindow(modelSlug: String, modelsCache: [String: Any]) -> Int? {
    if let models = modelsCache["models"] as? [[String: Any]] {
        for model in models where (model["slug"] as? String) == modelSlug {
            if let contextWindow = normalizeIntegerLiteral(model["context_window"] as? String)
                ?? model["context_window"] as? Int,
               contextWindow > 0
            {
                return contextWindow
            }
        }
    }
    return ReviewDefaults.shared.models.fallbackContextWindows[modelSlug]
}

private func lookupModelContextWindowClampLimit(modelSlug: String, modelsCache: [String: Any]) -> Int? {
    let normalized = modelSlug.split(separator: "/").last.map(String.init) ?? modelSlug
    if normalized == "gpt-5.4-mini" || normalized.hasPrefix("gpt-5.4-mini-") {
        return ReviewDefaults.shared.models.defaultWideContextClampLimit
    }
    if let match = normalized.wholeMatch(of: /^gpt-5\.(\d+)(?:$|-).*/), let minor = Int(match.1), minor >= 4 {
        return ReviewDefaults.shared.models.gpt54AndAboveClampLimit
    }
    if normalized == "gpt-5.3-codex-spark" || normalized.hasPrefix("gpt-5.3-codex-spark-") {
        return ReviewDefaults.shared.models.sparkClampLimit
    }
    for prefix in ReviewDefaults.shared.models.wideContextPrefixes {
        if normalized == prefix || normalized.hasPrefix("\(prefix)-") {
            return ReviewDefaults.shared.models.defaultWideContextClampLimit
        }
    }
    return lookupModelContextWindow(modelSlug: modelSlug, modelsCache: modelsCache)
}

private func lookupAutoCompactClampLimit(modelSlug: String, modelsCache: [String: Any]) -> Int? {
    guard let contextWindowClampLimit = lookupModelContextWindowClampLimit(modelSlug: modelSlug, modelsCache: modelsCache) else {
        return nil
    }
    return Int((Double(contextWindowClampLimit) * ReviewDefaults.shared.review.autoCompactRatio).rounded(.down))
}

private func computeForcedIntegerOverride(
    modelSlug: String,
    key: String,
    configPath: URL?,
    profileKey: String?,
    modelsCache: [String: Any]
) -> Int? {
    let clampLimit: Int?
    switch key {
    case "model_context_window":
        clampLimit = lookupModelContextWindowClampLimit(modelSlug: modelSlug, modelsCache: modelsCache)
    case "model_auto_compact_token_limit":
        clampLimit = lookupAutoCompactClampLimit(modelSlug: modelSlug, modelsCache: modelsCache)
    default:
        clampLimit = nil
    }

    let configuredValue = profileKey.flatMap { readProfileInteger(from: configPath, profile: $0, key: key) }
        ?? readTopLevelInteger(from: configPath, key: key)
    guard let clampLimit, clampLimit > 0, let configuredValue, configuredValue > clampLimit else {
        return nil
    }
    return clampLimit
}

private func stripTOMLComment(_ line: String) -> String {
    var isInsideSingleQuotes = false
    var isInsideDoubleQuotes = false
    var previousWasEscape = false

    for index in line.indices {
        let character = line[index]
        if character == "\"" && isInsideSingleQuotes == false && previousWasEscape == false {
            isInsideDoubleQuotes.toggle()
        } else if character == "'" && isInsideDoubleQuotes == false {
            isInsideSingleQuotes.toggle()
        } else if character == "#", isInsideSingleQuotes == false, isInsideDoubleQuotes == false {
            return String(line[..<index])
        }
        previousWasEscape = character == "\\" && isInsideDoubleQuotes && previousWasEscape == false
    }
    return line
}

private func readTopLevelValue(from configPath: URL?, key: String) -> String? {
    guard let configPath, let content = try? String(contentsOf: configPath, encoding: .utf8) else {
        return nil
    }
    var inRoot = true
    for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(rawLine)
        if line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[") {
            inRoot = false
            continue
        }
        guard inRoot else {
            continue
        }
        let stripped = stripTOMLComment(line)
        guard let range = stripped.range(of: "=") else {
            continue
        }
        let currentKey = stripped[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        if currentKey == key {
            return stripped[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    return nil
}

private func readProfileValue(from configPath: URL?, profile: String, key: String) -> String? {
    guard let configPath, let content = try? String(contentsOf: configPath, encoding: .utf8) else {
        return nil
    }
    let bareSection = "profiles.\(profile)"
    let quotedSection = "profiles.\"\(profile)\""
    var inTarget = false

    for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
        let stripped = stripTOMLComment(String(rawLine)).trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.hasPrefix("[") && stripped.hasSuffix("]") {
            let sectionName = stripped.dropFirst().dropLast()
            inTarget = sectionName == bareSection || sectionName == quotedSection
            continue
        }
        guard inTarget, let range = stripped.range(of: "=") else {
            continue
        }
        let currentKey = stripped[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        if currentKey == key {
            return stripped[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    return nil
}

private func normalizeIntegerLiteral(_ rawValue: String?) -> Int? {
    guard let rawValue else {
        return nil
    }
    let normalized = trimMatchingQuotes(rawValue)
        .replacingOccurrences(of: "_", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalized.isEmpty == false, normalized.allSatisfy(\.isNumber) else {
        return nil
    }
    return Int(normalized)
}

private func trimMatchingQuotes(_ value: String) -> String {
    guard value.count >= 2, let first = value.first, let last = value.last, first == last else {
        return value
    }
    if first == "\"" || first == "'" {
        return String(value.dropFirst().dropLast())
    }
    return value
}

private func readTopLevelInteger(from configPath: URL?, key: String) -> Int? {
    normalizeIntegerLiteral(readTopLevelValue(from: configPath, key: key))
}

private func readProfileInteger(from configPath: URL?, profile: String, key: String) -> Int? {
    normalizeIntegerLiteral(readProfileValue(from: configPath, profile: profile, key: key))
}

private func readTopLevelString(from configPath: URL?, key: String) -> String? {
    readTopLevelValue(from: configPath, key: key).map(trimMatchingQuotes).flatMap(\.nilIfEmpty)
}
