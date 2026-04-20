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

package struct ActiveReviewProfile: Sendable, Equatable {
    package var name: String
    package var keyPathPrefix: String
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
    if let reasoningEffort = resolvedConfig.modelReasoningEffort
        ?? localConfig.modelReasoningEffort?.nilIfEmpty.flatMap(CodexReviewReasoningEffort.init(rawValue:))
    {
        config["model_reasoning_effort"] = .string(reasoningEffort.rawValue)
    }
    if let serviceTier = resolvedConfig.serviceTier
        ?? localConfig.serviceTier?.nilIfEmpty.flatMap(CodexReviewServiceTier.init(rawValue:))
    {
        config["service_tier"] = .string(serviceTier.rawValue)
    }

    let baselineContextWindow = resolvedConfig.modelContextWindow ?? localConfig.modelContextWindow
    let baselineAutoCompactTokenLimit = resolvedConfig.modelAutoCompactTokenLimit
        ?? localConfig.modelAutoCompactTokenLimit

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
    let reviewSpecificModel = resolvedConfig.reviewModel?.nilIfEmpty
        ?? localConfig.reviewModel?.nilIfEmpty
    let reportedModel = reviewSpecificModel
        ?? resolvedConfig.model?.nilIfEmpty
    return .init(
        reportedModelBeforeThreadStart: reportedModel,
        threadStartModelHint: reportedModel,
        clampModel: reportedModel
    )
}

package func resolveReviewModelOverride(
    localConfig: ReviewLocalConfig,
    resolvedConfig: AppServerConfigReadResponse.Config
) -> String? {
    resolvedConfig.reviewModel?.nilIfEmpty
        ?? localConfig.reviewModel?.nilIfEmpty
}

package func resolveDisplayedSettingsOverrides(
    localConfig: ReviewLocalConfig,
    resolvedConfig: AppServerConfigReadResponse.Config
) -> ResolvedReviewSettingsOverrides {
    .init(
        reasoningEffort: resolvedConfig.modelReasoningEffort
            ?? localConfig.modelReasoningEffort?
                .nilIfEmpty
                .flatMap(CodexReviewReasoningEffort.init(rawValue:)),
        serviceTier: resolvedConfig.serviceTier
            ?? localConfig.serviceTier?
                .nilIfEmpty
                .flatMap(CodexReviewServiceTier.init(rawValue:))
    )
}

package func loadActiveReviewProfile(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    codexHome: URL? = nil
) -> ActiveReviewProfile? {
    if codexHome == nil {
        try? ReviewHomePaths.ensureReviewHomeScaffold(environment: environment)
    }
    let configPath = ReviewHomePaths.codexConfigURL(environment: environment, codexHome: codexHome)
    guard let profile = loadFallbackAppServerConfigDocument(at: configPath)?.profile,
          let content = try? String(contentsOf: configPath, encoding: .utf8),
          let keyPathPrefix = findActiveProfileKeyPathPrefix(content: content, profile: profile)
    else {
        return nil
    }
    return .init(name: profile, keyPathPrefix: keyPathPrefix)
}

package func loadActiveReviewProfileConfig(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    codexHome: URL? = nil
) -> ReviewLocalConfig {
    if codexHome == nil {
        try? ReviewHomePaths.ensureReviewHomeScaffold(environment: environment)
    }
    let configPath = ReviewHomePaths.codexConfigURL(environment: environment, codexHome: codexHome)
    guard let activeProfile = loadFallbackAppServerConfigDocument(at: configPath)?.activeProfile else {
        return .init()
    }
    return .init(
        reviewModel: activeProfile.reviewModel,
        modelReasoningEffort: activeProfile.modelReasoningEffort,
        serviceTier: activeProfile.serviceTier,
        modelContextWindow: activeProfile.modelContextWindow,
        modelAutoCompactTokenLimit: activeProfile.modelAutoCompactTokenLimit
    )
}

package func settingsKeyPath(
    _ key: String,
    profileKeyPath: String?,
    forceRoot: Bool
) -> String {
    if forceRoot {
        return key
    }
    guard let profileKeyPath else {
        return key
    }
    return "\(profileKeyPath).\(key)"
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
    let resolvedModel = resolveProfileOverride(profileOverrides?.modelOverride, inherited: document?.model)
    let resolvedReviewModel = resolveProfileOverride(
        profileOverrides?.reviewModelOverride,
        inherited: document?.reviewModel
    )
    let resolvedReasoningEffort = resolveProfileOverride(
        profileOverrides?.modelReasoningEffortOverride,
        inherited: document?.modelReasoningEffort
    )
    let resolvedServiceTier = resolveProfileOverride(
        profileOverrides?.serviceTierOverride,
        inherited: document?.serviceTier
    )
    let resolvedModelContextWindow = resolveProfileOverride(
        profileOverrides?.modelContextWindowOverride,
        inherited: document?.modelContextWindow
    )
    let resolvedModelAutoCompactTokenLimit = resolveProfileOverride(
        profileOverrides?.modelAutoCompactTokenLimitOverride,
        inherited: document?.modelAutoCompactTokenLimit
    )

    return .init(
        model: resolvedModel,
        reviewModel: resolvedReviewModel,
        modelReasoningEffort: resolvedReasoningEffort
            .flatMap(CodexReviewReasoningEffort.init(rawValue:)),
        serviceTier: resolvedServiceTier
            .flatMap(CodexReviewServiceTier.init(rawValue:)),
        modelContextWindow: resolvedModelContextWindow,
        modelAutoCompactTokenLimit: resolvedModelAutoCompactTokenLimit
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

private enum ParsedProfileOverride<Value: Equatable & Sendable>: Equatable, Sendable {
    case missing
    case value(Value?)

    var isPresent: Bool {
        switch self {
        case .missing:
            false
        case .value:
            true
        }
    }

    var value: Value? {
        switch self {
        case .missing:
            nil
        case .value(let value):
            value
        }
    }

    func resolved(over inherited: Value?) -> Value? {
        switch self {
        case .missing:
            inherited
        case .value(let value):
            value
        }
    }
}

private struct FallbackAppServerConfigDocument: Decodable {
    struct ProfileOverrides: Equatable, Sendable {
        let modelOverride: ParsedProfileOverride<String>
        let reviewModelOverride: ParsedProfileOverride<String>
        let modelReasoningEffortOverride: ParsedProfileOverride<String>
        let serviceTierOverride: ParsedProfileOverride<String>
        let modelContextWindowOverride: ParsedProfileOverride<Int>
        let modelAutoCompactTokenLimitOverride: ParsedProfileOverride<Int>

        var model: String? {
            modelOverride.value
        }

        var reviewModel: String? {
            reviewModelOverride.value
        }

        var modelReasoningEffort: String? {
            modelReasoningEffortOverride.value
        }

        var serviceTier: String? {
            serviceTierOverride.value
        }

        var modelContextWindow: Int? {
            modelContextWindowOverride.value
        }

        var modelAutoCompactTokenLimit: Int? {
            modelAutoCompactTokenLimitOverride.value
        }

        var isEmpty: Bool {
            modelOverride.isPresent == false
                && reviewModelOverride.isPresent == false
                && modelReasoningEffortOverride.isPresent == false
                && serviceTierOverride.isPresent == false
                && modelContextWindowOverride.isPresent == false
                && modelAutoCompactTokenLimitOverride.isPresent == false
        }
    }

    struct ResolvedActiveProfile: Equatable, Sendable {
        let profile: ActiveReviewProfile
        let overrides: ProfileOverrides
    }

    let profile: String?
    let model: String?
    let reviewModel: String?
    let modelReasoningEffort: String?
    let serviceTier: String?
    let modelContextWindow: Int?
    let modelAutoCompactTokenLimit: Int?
    let resolvedActiveProfile: ResolvedActiveProfile?

    var activeProfileInfo: ActiveReviewProfile? {
        resolvedActiveProfile?.profile
    }

    var activeProfile: ProfileOverrides? {
        resolvedActiveProfile?.overrides
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
        resolvedActiveProfile = nil
    }
}

private func quotedProfileKeyPathComponent(_ profile: String) -> String {
    let escapedProfile = profile
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escapedProfile)\""
}

private func profileKeyPathComponent(forDirectKey profile: String) -> String {
    if profile.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil {
        return profile
    }
    return quotedProfileKeyPathComponent(profile)
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
    let decoder = TOMLDecoder()
    guard var document = try? decoder.decode(FallbackAppServerConfigDocument.self, from: data) else {
        return nil
    }
    document = .init(
        profile: document.profile,
        model: document.model,
        reviewModel: document.reviewModel,
        modelReasoningEffort: document.modelReasoningEffort,
        serviceTier: document.serviceTier,
        modelContextWindow: document.modelContextWindow,
        modelAutoCompactTokenLimit: document.modelAutoCompactTokenLimit,
        resolvedActiveProfile: resolveActiveProfile(
            content: String(data: data, encoding: .utf8),
            profile: document.profile
        )
    )
    return document
}

private extension FallbackAppServerConfigDocument {
    init(
        profile: String?,
        model: String?,
        reviewModel: String?,
        modelReasoningEffort: String?,
        serviceTier: String?,
        modelContextWindow: Int?,
        modelAutoCompactTokenLimit: Int?,
        resolvedActiveProfile: ResolvedActiveProfile?
    ) {
        self.profile = profile
        self.model = model
        self.reviewModel = reviewModel
        self.modelReasoningEffort = modelReasoningEffort
        self.serviceTier = serviceTier
        self.modelContextWindow = modelContextWindow
        self.modelAutoCompactTokenLimit = modelAutoCompactTokenLimit
        self.resolvedActiveProfile = resolvedActiveProfile
    }
}

private func resolveActiveProfile(
    content: String?,
    profile: String?
) -> FallbackAppServerConfigDocument.ResolvedActiveProfile? {
    guard let profile,
          let content,
          let keyPathPrefix = findActiveProfileKeyPathPrefix(
            content: content,
            profile: profile
          )
    else {
        return nil
    }
    return .init(
        profile: .init(name: profile, keyPathPrefix: keyPathPrefix),
        overrides: readProfileOverrides(
            content: content,
            keyPathPrefix: keyPathPrefix
        )
    )
}

private func findActiveProfileKeyPathPrefix(
    content: String?,
    profile: String
) -> String? {
    guard let content else {
        return nil
    }
    let directCandidate = "profiles.\(profileKeyPathComponent(forDirectKey: profile))"
    let dottedCandidate = "profiles.\(profile.split(separator: ".").map(String.init).joined(separator: "."))"
    for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = stripTOMLComment(String(rawLine)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("["),
              line.hasSuffix("]")
        else {
            continue
        }
        let section = String(line.dropFirst().dropLast())
        if section == directCandidate {
            return directCandidate
        }
        if section == dottedCandidate {
            return dottedCandidate
        }
    }
    return nil
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

private func readProfileOverrides(
    content: String,
    keyPathPrefix: String
) -> FallbackAppServerConfigDocument.ProfileOverrides {
    var isInsideTargetSection = false
    var modelOverride: ParsedProfileOverride<String> = .missing
    var reviewModelOverride: ParsedProfileOverride<String> = .missing
    var modelReasoningEffortOverride: ParsedProfileOverride<String> = .missing
    var serviceTierOverride: ParsedProfileOverride<String> = .missing
    var modelContextWindowOverride: ParsedProfileOverride<Int> = .missing
    var modelAutoCompactTokenLimitOverride: ParsedProfileOverride<Int> = .missing

    for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = stripTOMLComment(String(rawLine)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.isEmpty == false else {
            continue
        }
        if line.hasPrefix("["),
           line.hasSuffix("]")
        {
            let section = String(line.dropFirst().dropLast())
            isInsideTargetSection = section == keyPathPrefix
            continue
        }
        guard isInsideTargetSection,
              let separator = line.range(of: "=")
        else {
            continue
        }
        let key = line[..<separator.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let rawValue = String(line[separator.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines))

        switch key {
        case "model":
            modelOverride = parseNullableProfileStringOverride(rawValue)
        case "review_model":
            reviewModelOverride = parseNullableProfileStringOverride(rawValue)
        case "model_reasoning_effort":
            modelReasoningEffortOverride = parseNullableProfileStringOverride(rawValue)
        case "service_tier":
            serviceTierOverride = parseNullableProfileStringOverride(rawValue)
        case "model_context_window":
            modelContextWindowOverride = parseNullableProfileIntegerOverride(rawValue)
        case "model_auto_compact_token_limit":
            modelAutoCompactTokenLimitOverride = parseNullableProfileIntegerOverride(rawValue)
        default:
            continue
        }
    }

    return .init(
        modelOverride: modelOverride,
        reviewModelOverride: reviewModelOverride,
        modelReasoningEffortOverride: modelReasoningEffortOverride,
        serviceTierOverride: serviceTierOverride,
        modelContextWindowOverride: modelContextWindowOverride,
        modelAutoCompactTokenLimitOverride: modelAutoCompactTokenLimitOverride
    )
}

private func parseNullableProfileStringOverride(_ rawValue: String) -> ParsedProfileOverride<String> {
    let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmedValue == "null" {
        return .value(nil)
    }
    return .value(trimMatchingQuotes(trimmedValue).nilIfEmpty)
}

private func parseNullableProfileIntegerOverride(_ rawValue: String) -> ParsedProfileOverride<Int> {
    let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmedValue == "null" {
        return .value(nil)
    }
    return .value(normalizeIntegerLiteral(trimmedValue))
}

private func resolveProfileOverride<Value>(
    _ override: ParsedProfileOverride<Value>?,
    inherited: Value?
) -> Value? where Value: Equatable & Sendable {
    guard let override else {
        return inherited
    }
    return override.resolved(over: inherited)
}
