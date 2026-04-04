import Foundation
import CodexAppServerProtocol
import ReviewCore
import ReviewJobs

package struct CodexAppServerCommand: Sendable {
    package var executable: String
    package var arguments: [String]
    package var environment: [String: String]
    package var currentDirectory: String
}

package struct ReviewRunnerOverrides: Sendable, Equatable {
    package var approvalPolicy: String
    package var sandbox: String
    package var personality: String
    package var ephemeral: Bool

    package static let reviewRunner = Self(
        approvalPolicy: "never",
        sandbox: "danger-full-access",
        personality: "none",
        ephemeral: true
    )
}

package struct ReviewExecutionSettings: Sendable {
    package var command: CodexAppServerCommand
    package var request: ReviewRequestOptions
    package var overrides: ReviewRunnerOverrides
}

package struct ResolvedReviewModelSelection: Sendable, Equatable {
    package var reportedModelBeforeThreadStart: String?
    package var threadStartModelHint: String?
    package var clampModel: String?
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
        return ReviewExecutionSettings(
            command: CodexAppServerCommand(
                executable: codexCommand,
                arguments: ["app-server", "--listen", "stdio://"],
                environment: environment,
                currentDirectory: request.cwd
            ),
            request: request,
            overrides: .reviewRunner
        )
    }
}

package func makeReviewThreadStartConfig(
    reviewSpecificModel: String?,
    localConfig: ReviewLocalConfig,
    resolvedConfig: CodexAppServerConfigReadResponse.Config,
    clampModel: String?,
    environment: [String: String],
    codexHome: URL? = nil
) -> [String: CodexAppServerJSONValue]? {
    let modelsCache = loadModelsCache(environment: environment, codexHome: codexHome)
    var config: [String: CodexAppServerJSONValue] = [:]

    if let reviewSpecificModel = reviewSpecificModel?.nilIfEmpty {
        config["review_model"] = .string(reviewSpecificModel)
    }
    if let localReasoningEffort = localConfig.modelReasoningEffort?.nilIfEmpty {
        config["model_reasoning_effort"] = .string(localReasoningEffort)
    }

    let baselineContextWindow = localConfig.modelContextWindow ?? resolvedConfig.modelContextWindow
    let baselineAutoCompactTokenLimit = localConfig.modelAutoCompactTokenLimit ?? resolvedConfig.modelAutoCompactTokenLimit

    if let clampModel = clampModel?.nilIfEmpty {
        if let clampedContextWindow = computeForcedIntegerOverride(
            modelSlug: clampModel,
            key: "model_context_window",
            configuredValue: baselineContextWindow,
            modelsCache: modelsCache
        ) {
            config["model_context_window"] = .int(clampedContextWindow)
        } else if let baselineContextWindow {
            config["model_context_window"] = .int(baselineContextWindow)
        }

        if let clampedAutoCompactLimit = computeForcedIntegerOverride(
            modelSlug: clampModel,
            key: "model_auto_compact_token_limit",
            configuredValue: baselineAutoCompactTokenLimit,
            modelsCache: modelsCache
        ) {
            config["model_auto_compact_token_limit"] = .int(clampedAutoCompactLimit)
        } else if let baselineAutoCompactTokenLimit {
            config["model_auto_compact_token_limit"] = .int(baselineAutoCompactTokenLimit)
        }
    }

    return config.isEmpty ? nil : config
}

package func resolveInitialReviewModel(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    codexHome: URL? = nil
) -> String? {
    let localConfig = (try? loadReviewLocalConfig(environment: environment)) ?? .init()
    let fallbackConfig = loadFallbackAppServerConfig(environment: environment, codexHome: codexHome)
    return resolveReviewModelSelection(
        localConfig: localConfig,
        resolvedConfig: fallbackConfig
    ).reportedModelBeforeThreadStart
}

package func resolveReviewModelSelection(
    localConfig: ReviewLocalConfig,
    resolvedConfig: CodexAppServerConfigReadResponse.Config
) -> ResolvedReviewModelSelection {
    let reviewSpecificModel = localConfig.reviewModel?.nilIfEmpty
        ?? resolvedConfig.reviewModel?.nilIfEmpty
    let reportedModel = reviewSpecificModel
        ?? resolvedConfig.model?.nilIfEmpty
    return .init(
        reportedModelBeforeThreadStart: reportedModel,
        threadStartModelHint: reportedModel,
        clampModel: reportedModel
    )
}

package func loadFallbackAppServerConfig(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    codexHome: URL? = nil
) -> CodexAppServerConfigReadResponse.Config {
    let configPath = ReviewHomePaths.codexConfigURL(environment: environment, codexHome: codexHome)
    let profile = readTopLevelString(from: configPath, key: "profile")

    return .init(
        model: readProfileString(from: configPath, profile: profile, key: "model")
            ?? readTopLevelString(from: configPath, key: "model"),
        reviewModel: readProfileString(from: configPath, profile: profile, key: "review_model")
            ?? readTopLevelString(from: configPath, key: "review_model"),
        modelContextWindow: readProfileInteger(from: configPath, profile: profile, key: "model_context_window")
            ?? readTopLevelInteger(from: configPath, key: "model_context_window"),
        modelAutoCompactTokenLimit: readProfileInteger(
            from: configPath,
            profile: profile,
            key: "model_auto_compact_token_limit"
        ) ?? readTopLevelInteger(from: configPath, key: "model_auto_compact_token_limit")
    )
}

package func mergeAppServerConfig(
    primary: CodexAppServerConfigReadResponse.Config,
    fallback: CodexAppServerConfigReadResponse.Config
) -> CodexAppServerConfigReadResponse.Config {
    .init(
        model: primary.model?.nilIfEmpty ?? fallback.model?.nilIfEmpty,
        reviewModel: primary.reviewModel?.nilIfEmpty ?? fallback.reviewModel?.nilIfEmpty,
        modelContextWindow: primary.modelContextWindow ?? fallback.modelContextWindow,
        modelAutoCompactTokenLimit: primary.modelAutoCompactTokenLimit ?? fallback.modelAutoCompactTokenLimit
    )
}

private func resolveModelsCachePath(
    environment: [String: String],
    codexHome: URL?
) -> URL? {
    ReviewHomePaths.modelsCacheURL(environment: environment, codexHome: codexHome)
}

private func loadModelsCache(
    environment: [String: String],
    codexHome: URL?
) -> [String: Any] {
    loadJSONDictionary(at: resolveModelsCachePath(environment: environment, codexHome: codexHome))
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
    configuredValue: Int?,
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
        if character == "\"", isInsideSingleQuotes == false, previousWasEscape == false {
            isInsideDoubleQuotes.toggle()
        } else if character == "'", isInsideDoubleQuotes == false {
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

private func readTopLevelString(from configPath: URL?, key: String) -> String? {
    readTopLevelValue(from: configPath, key: key)
        .map(trimMatchingQuotes)
        .flatMap { $0.nilIfEmpty }
}

private func readTopLevelInteger(from configPath: URL?, key: String) -> Int? {
    normalizeIntegerLiteral(readTopLevelValue(from: configPath, key: key))
}

private func readProfileString(from configPath: URL?, profile: String?, key: String) -> String? {
    guard let profile else {
        return nil
    }
    return readProfileValue(from: configPath, profile: profile, key: key)
        .map(trimMatchingQuotes)
        .flatMap { $0.nilIfEmpty }
}

private func readProfileInteger(from configPath: URL?, profile: String?, key: String) -> Int? {
    guard let profile else {
        return nil
    }
    return normalizeIntegerLiteral(readProfileValue(from: configPath, profile: profile, key: key))
}

private func normalizeIntegerLiteral(_ rawValue: String?) -> Int? {
    guard let rawValue else {
        return nil
    }
    let normalized = trimMatchingQuotes(rawValue)
        .replacingOccurrences(of: "_", with: "")
        .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    guard normalized.isEmpty == false, normalized.allSatisfy({ $0.isNumber }) else {
        return nil
    }
    return Int(normalized)
}

private func trimMatchingQuotes(_ value: String) -> String {
    guard value.count >= 2 else {
        return value
    }
    if value.hasPrefix("\""), value.hasSuffix("\"") {
        return String(value.dropFirst().dropLast())
    }
    if value.hasPrefix("'"), value.hasSuffix("'") {
        return String(value.dropFirst().dropLast())
    }
    return value
}
