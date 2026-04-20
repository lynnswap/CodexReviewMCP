import Foundation
import CodexReviewModel
import ReviewJobs
import TOMLDecoder

package struct AppServerCommand: Sendable {
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
    package var command: AppServerCommand
    package var request: ReviewRequestOptions
    package var overrides: ReviewRunnerOverrides
}

package struct ResolvedReviewModelSelection: Sendable, Equatable {
    package var reportedModelBeforeThreadStart: String?
    package var threadStartModelHint: String?
    package var clampModel: String?
}

package struct ResolvedReviewSettingsOverrides: Sendable, Equatable {
    package var reasoningEffort: CodexReviewReasoningEffort?
    package var serviceTier: CodexReviewServiceTier?
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
            command: AppServerCommand(
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
    resolvedConfig: AppServerConfigReadResponse.Config,
    clampModel: String?,
    environment: [String: String],
    codexHome: URL? = nil
) -> [String: AppServerJSONValue]? {
    let modelsCache = loadModelsCache(environment: environment, codexHome: codexHome)
    var config: [String: AppServerJSONValue] = [:]

    if let reviewSpecificModel = reviewSpecificModel?.nilIfEmpty {
        config["review_model"] = .string(reviewSpecificModel)
    }
    if let localReasoningEffort = localConfig.modelReasoningEffort?.nilIfEmpty {
        config["model_reasoning_effort"] = .string(localReasoningEffort)
    }
    if let localServiceTier = localConfig.serviceTier?.nilIfEmpty {
        config["service_tier"] = .string(localServiceTier)
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
    resolvedConfig: AppServerConfigReadResponse.Config
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

package func resolveDisplayedSettingsOverrides(
    localConfig: ReviewLocalConfig,
    resolvedConfig: AppServerConfigReadResponse.Config
) -> ResolvedReviewSettingsOverrides {
    .init(
        reasoningEffort: localConfig.modelReasoningEffort?
            .nilIfEmpty
            .flatMap(CodexReviewReasoningEffort.init(rawValue:))
            ?? resolvedConfig.modelReasoningEffort,
        serviceTier: localConfig.serviceTier?
            .nilIfEmpty
            .flatMap(CodexReviewServiceTier.init(rawValue:))
            ?? resolvedConfig.serviceTier
    )
}

package func loadActiveReviewProfile(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    codexHome: URL? = nil
) -> String? {
    if codexHome == nil {
        try? ReviewHomePaths.ensureReviewHomeScaffold(environment: environment)
    }
    let configPath = ReviewHomePaths.codexConfigURL(environment: environment, codexHome: codexHome)
    return loadFallbackAppServerConfigDocument(at: configPath)?.profile?.nilIfEmpty
}

package func settingsKeyPath(
    _ key: String,
    profile: String?,
    forceRoot: Bool
) -> String {
    if forceRoot {
        return key
    }
    guard let profile else {
        return key
    }
    return "profiles.\(profile).\(key)"
}

package func loadFallbackAppServerConfig(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    codexHome: URL? = nil
) -> AppServerConfigReadResponse.Config {
    if codexHome == nil {
        try? ReviewHomePaths.ensureReviewHomeScaffold(environment: environment)
    }
    let configPath = ReviewHomePaths.codexConfigURL(environment: environment, codexHome: codexHome)
    let document = loadFallbackAppServerConfigDocument(at: configPath)
    let profileOverrides = document?.activeProfile

    return .init(
        model: profileOverrides?.model ?? document?.model,
        reviewModel: profileOverrides?.reviewModel ?? document?.reviewModel,
        modelReasoningEffort: profileOverrides?.modelReasoningEffort
            .flatMap(CodexReviewReasoningEffort.init(rawValue:))
            ?? document?.modelReasoningEffort
            .flatMap(CodexReviewReasoningEffort.init(rawValue:)),
        serviceTier: profileOverrides?.serviceTier
            .flatMap(CodexReviewServiceTier.init(rawValue:))
            ?? document?.serviceTier
            .flatMap(CodexReviewServiceTier.init(rawValue:)),
        modelContextWindow: profileOverrides?.modelContextWindow ?? document?.modelContextWindow,
        modelAutoCompactTokenLimit: profileOverrides?.modelAutoCompactTokenLimit
            ?? document?.modelAutoCompactTokenLimit
    )
}

package func mergeAppServerConfig(
    primary: AppServerConfigReadResponse.Config,
    fallback: AppServerConfigReadResponse.Config
) -> AppServerConfigReadResponse.Config {
    .init(
        model: primary.model?.nilIfEmpty ?? fallback.model?.nilIfEmpty,
        reviewModel: primary.reviewModel?.nilIfEmpty ?? fallback.reviewModel?.nilIfEmpty,
        modelReasoningEffort: primary.modelReasoningEffort ?? fallback.modelReasoningEffort,
        serviceTier: primary.serviceTier ?? fallback.serviceTier,
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

private struct FallbackAppServerConfigDocument: Decodable {
    struct ProfileOverrides: Equatable, Sendable {
        let model: String?
        let reviewModel: String?
        let modelReasoningEffort: String?
        let serviceTier: String?
        let modelContextWindow: Int?
        let modelAutoCompactTokenLimit: Int?

        var isEmpty: Bool {
            model == nil
                && reviewModel == nil
                && modelReasoningEffort == nil
                && serviceTier == nil
                && modelContextWindow == nil
                && modelAutoCompactTokenLimit == nil
        }
    }

    let profile: String?
    let model: String?
    let reviewModel: String?
    let modelReasoningEffort: String?
    let serviceTier: String?
    let modelContextWindow: Int?
    let modelAutoCompactTokenLimit: Int?
    let profiles: FallbackProfileNode?

    var activeProfile: ProfileOverrides? {
        guard let profile, let profiles else {
            return nil
        }
        if let directNode = profiles.children[profile],
           directNode.overrides.isEmpty == false
        {
            return directNode.overrides
        }

        var currentNode: FallbackProfileNode? = profiles
        for component in profile.split(separator: ".").map(String.init) {
            currentNode = currentNode?.children[component]
            if currentNode == nil {
                return nil
            }
        }
        guard let currentNode,
              currentNode.overrides.isEmpty == false
        else {
            return nil
        }
        return currentNode.overrides
    }

    private enum CodingKeys: String, CodingKey {
        case profile
        case model
        case reviewModel = "review_model"
        case modelReasoningEffort = "model_reasoning_effort"
        case serviceTier = "service_tier"
        case modelContextWindow = "model_context_window"
        case modelAutoCompactTokenLimit = "model_auto_compact_token_limit"
        case profiles
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profile = try container.decodeIfPresent(String.self, forKey: .profile)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        reviewModel = try container.decodeIfPresent(String.self, forKey: .reviewModel)
        modelReasoningEffort = try container.decodeIfPresent(
            String.self,
            forKey: .modelReasoningEffort
        )
        serviceTier = try container.decodeIfPresent(String.self, forKey: .serviceTier)
        modelContextWindow = try container.decodeIfPresent(
            TOMLIntegerLiteral.self,
            forKey: .modelContextWindow
        )?.value
        modelAutoCompactTokenLimit = try container.decodeIfPresent(
            TOMLIntegerLiteral.self,
            forKey: .modelAutoCompactTokenLimit
        )?.value
        profiles = try container.decodeIfPresent(FallbackProfileNode.self, forKey: .profiles)
    }
}

private struct FallbackProfileNode: Decodable {
    let overrides: FallbackAppServerConfigDocument.ProfileOverrides
    let children: [String: FallbackProfileNode]

    private enum OverrideCodingKeys: String, CodingKey, CaseIterable {
        case model
        case reviewModel = "review_model"
        case modelReasoningEffort = "model_reasoning_effort"
        case serviceTier = "service_tier"
        case modelContextWindow = "model_context_window"
        case modelAutoCompactTokenLimit = "model_auto_compact_token_limit"
    }

    init(from decoder: Decoder) throws {
        let overrideContainer = try decoder.container(keyedBy: OverrideCodingKeys.self)
        overrides = .init(
            model: try overrideContainer.decodeIfPresent(String.self, forKey: .model)?.nilIfEmpty,
            reviewModel: try overrideContainer.decodeIfPresent(String.self, forKey: .reviewModel)?.nilIfEmpty,
            modelReasoningEffort: try overrideContainer.decodeIfPresent(
                String.self,
                forKey: .modelReasoningEffort
            )?.nilIfEmpty,
            serviceTier: try overrideContainer.decodeIfPresent(String.self, forKey: .serviceTier)?.nilIfEmpty,
            modelContextWindow: try overrideContainer.decodeIfPresent(
                TOMLIntegerLiteral.self,
                forKey: .modelContextWindow
            )?.value,
            modelAutoCompactTokenLimit: try overrideContainer.decodeIfPresent(
                TOMLIntegerLiteral.self,
                forKey: .modelAutoCompactTokenLimit
            )?.value
        )

        let dynamicContainer = try decoder.container(keyedBy: DynamicCodingKey.self)
        var children: [String: FallbackProfileNode] = [:]
        let overrideKeys = Set(OverrideCodingKeys.allCases.map(\.stringValue))
        for key in dynamicContainer.allKeys where overrideKeys.contains(key.stringValue) == false {
            if let child = try? dynamicContainer.decode(
                FallbackProfileNode.self,
                forKey: key
            ) {
                children[key.stringValue] = child
            }
        }
        self.children = children
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}

private enum TOMLIntegerLiteral: Decodable {
    case int(Int)
    case string(String)

    var value: Int? {
        switch self {
        case .int(let value):
            return value
        case .string(let value):
            return normalizeIntegerLiteral(value)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .int(value)
            return
        }
        self = .string(try container.decode(String.self))
    }
}

private func loadFallbackAppServerConfigDocument(at configPath: URL) -> FallbackAppServerConfigDocument? {
    guard let data = try? Data(contentsOf: configPath) else {
        return nil
    }
    return try? TOMLDecoder().decode(FallbackAppServerConfigDocument.self, from: data)
}
