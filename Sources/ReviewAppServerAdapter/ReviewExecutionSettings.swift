import Foundation
import ReviewDomain
import ReviewPlatform
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
    environment: [String: String],
    codexHome: URL? = nil
) -> [String: AppServerJSONValue]? {
    let profileClearsReasoningEffort = activeProfileClearsReasoningEffort(
        environment: environment,
        codexHome: codexHome
    )
    let profileClearsServiceTier = activeProfileClearsServiceTier(
        environment: environment,
        codexHome: codexHome
    )
    var config: [String: AppServerJSONValue] = [:]

    if let reviewSpecificModel = reviewSpecificModel?.nilIfEmpty {
        config["review_model"] = .string(reviewSpecificModel)
    }
    if let reasoningEffort = resolvedConfig.modelReasoningEffort
        ?? (
            profileClearsReasoningEffort
                ? nil
                : localConfig.modelReasoningEffort?
                    .nilIfEmpty
                    .flatMap(CodexReviewReasoningEffort.init(rawValue:))
        )
    {
        config["model_reasoning_effort"] = .string(reasoningEffort.rawValue)
    }
    if let serviceTier = resolvedConfig.serviceTier
        ?? (
            profileClearsServiceTier
                ? nil
                : localConfig.serviceTier?.nilIfEmpty.flatMap(CodexReviewServiceTier.init(rawValue:))
        )
    {
        config["service_tier"] = .string(serviceTier.rawValue)
    }

    return config.isEmpty ? nil : config
}

package func resolveInitialReviewModel(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    codexHome: URL? = nil
) -> String? {
    let localConfig = (try? loadReviewLocalConfig(environment: environment)) ?? .init()
    let fallbackConfig = loadFallbackAppServerConfig(environment: environment, codexHome: codexHome)
    let profileClearsReviewModel = activeProfileClearsReviewModel(
        environment: environment,
        codexHome: codexHome
    )
    return resolveReviewModelSelection(
        localConfig: localConfig,
        resolvedConfig: fallbackConfig,
        profileClearsReviewModel: profileClearsReviewModel
    ).reportedModelBeforeThreadStart
}

package func resolveReviewModelSelection(
    localConfig: ReviewLocalConfig,
    resolvedConfig: AppServerConfigReadResponse.Config,
    profileClearsReviewModel: Bool = false
) -> ResolvedReviewModelSelection {
    let reviewSpecificModel = (
        profileClearsReviewModel
            ? nil
            : localConfig.reviewModel?.nilIfEmpty
    ) ?? resolvedConfig.reviewModel?.nilIfEmpty
    let reportedModel = reviewSpecificModel
        ?? resolvedConfig.model?.nilIfEmpty
    return .init(
        reportedModelBeforeThreadStart: reportedModel,
        threadStartModelHint: reportedModel
    )
}

package func resolveReviewModelOverride(
    localConfig: ReviewLocalConfig,
    resolvedConfig: AppServerConfigReadResponse.Config,
    profileClearsReviewModel: Bool = false
) -> String? {
    (
        profileClearsReviewModel
            ? nil
            : localConfig.reviewModel?.nilIfEmpty
    ) ?? resolvedConfig.reviewModel?.nilIfEmpty
}

package func resolveDisplayedSettingsOverrides(
    localConfig: ReviewLocalConfig,
    resolvedConfig: AppServerConfigReadResponse.Config,
    profileClearsReasoningEffort: Bool = false,
    profileClearsServiceTier: Bool = false
) -> ResolvedReviewSettingsOverrides {
    .init(
        reasoningEffort: resolvedConfig.modelReasoningEffort
            ?? (
                profileClearsReasoningEffort
                    ? nil
                    : localConfig.modelReasoningEffort?
                        .nilIfEmpty
                        .flatMap(CodexReviewReasoningEffort.init(rawValue:))
            ),
        serviceTier: resolvedConfig.serviceTier
            ?? (
                profileClearsServiceTier
                    ? nil
                    : localConfig.serviceTier?
                        .nilIfEmpty
                        .flatMap(CodexReviewServiceTier.init(rawValue:))
            )
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
    guard let profile = loadFallbackAppServerConfigDocument(at: configPath)?.profile
    else {
        return nil
    }
    let content = try? String(contentsOf: configPath, encoding: .utf8)
    let keyPathPrefix = findActiveProfileKeyPathPrefix(content: content, profile: profile)
        ?? profileWriteKeyPathPrefix(for: profile)
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
        serviceTier: activeProfile.serviceTier
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

    return .init(
        model: resolvedModel,
        reviewModel: resolvedReviewModel,
        modelReasoningEffort: resolvedReasoningEffort
            .flatMap(CodexReviewReasoningEffort.init(rawValue:)),
        serviceTier: resolvedServiceTier
            .flatMap(CodexReviewServiceTier.init(rawValue:))
    )
}

package func mergeAppServerConfig(
    primary: AppServerConfigReadResponse.Config,
    fallback: AppServerConfigReadResponse.Config
) -> AppServerConfigReadResponse.Config {
    .init(
        model: primary.model?.nilIfEmpty ?? fallback.model?.nilIfEmpty,
        reviewModel: primary.reviewModel?.nilIfEmpty ?? fallback.reviewModel?.nilIfEmpty,
        modelReasoningEffort: primary.hasModelReasoningEffort
            ? primary.modelReasoningEffort
            : fallback.modelReasoningEffort,
        serviceTier: primary.hasServiceTier
            ? primary.serviceTier
            : fallback.serviceTier,
        hasModelReasoningEffort: primary.hasModelReasoningEffort || fallback.hasModelReasoningEffort,
        hasServiceTier: primary.hasServiceTier || fallback.hasServiceTier
    )
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

        var isEmpty: Bool {
            modelOverride.isPresent == false
                && reviewModelOverride.isPresent == false
                && modelReasoningEffortOverride.isPresent == false
                && serviceTierOverride.isPresent == false
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

private func profileWriteKeyPathPrefix(for profile: String) -> String {
    return "profiles.\(profileKeyPathComponent(forDirectKey: profile))"
}

private func loadFallbackAppServerConfigDocument(at configPath: URL) -> FallbackAppServerConfigDocument? {
    guard let data = try? Data(contentsOf: configPath) else {
        return nil
    }
    let originalContent = String(data: data, encoding: .utf8)
    let decoderContent = originalContent.map(sanitizeNullAssignmentsForTOMLDecoder)
    let decoder = TOMLDecoder()
    guard let decoderData = decoderContent?.data(using: .utf8),
          var document = try? decoder.decode(FallbackAppServerConfigDocument.self, from: decoderData)
    else {
        return nil
    }
    document = .init(
        profile: document.profile,
        model: document.model,
        reviewModel: document.reviewModel,
        modelReasoningEffort: document.modelReasoningEffort,
        serviceTier: document.serviceTier,
        resolvedActiveProfile: resolveActiveProfile(
            content: originalContent,
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
        resolvedActiveProfile: ResolvedActiveProfile?
    ) {
        self.profile = profile
        self.model = model
        self.reviewModel = reviewModel
        self.modelReasoningEffort = modelReasoningEffort
        self.serviceTier = serviceTier
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
    let quotedCandidate = "profiles.\(quotedProfileKeyPathComponent(profile))"
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
        if section == quotedCandidate {
            return quotedCandidate
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
        default:
            continue
        }
    }

    return .init(
        modelOverride: modelOverride,
        reviewModelOverride: reviewModelOverride,
        modelReasoningEffortOverride: modelReasoningEffortOverride,
        serviceTierOverride: serviceTierOverride
    )
}

private func parseNullableProfileStringOverride(_ rawValue: String) -> ParsedProfileOverride<String> {
    let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmedValue == "null" {
        return .value(nil)
    }
    return .value(trimMatchingQuotes(trimmedValue).nilIfEmpty)
}

private func sanitizeNullAssignmentsForTOMLDecoder(_ content: String) -> String {
    content
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { rawLine in
            let line = String(rawLine)
            let trimmed = stripTOMLComment(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = trimmed.range(of: "=") else {
                return line
            }
            let rawValue = trimmed[separator.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if rawValue == "null" {
                return ""
            }
            return line
        }
        .joined(separator: "\n")
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

package func activeProfileClearsReasoningEffort(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    codexHome: URL? = nil
) -> Bool {
    if codexHome == nil {
        try? ReviewHomePaths.ensureReviewHomeScaffold(environment: environment)
    }
    let configPath = ReviewHomePaths.codexConfigURL(environment: environment, codexHome: codexHome)
    guard let profileOverrides = loadFallbackAppServerConfigDocument(at: configPath)?.activeProfile else {
        return false
    }
    return profileOverrides.modelReasoningEffortOverride.isPresent
        && profileOverrides.modelReasoningEffort == nil
}

package func activeProfileHasReasoningEffortOverride(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    codexHome: URL? = nil
) -> Bool {
    if codexHome == nil {
        try? ReviewHomePaths.ensureReviewHomeScaffold(environment: environment)
    }
    let configPath = ReviewHomePaths.codexConfigURL(environment: environment, codexHome: codexHome)
    guard let profileOverrides = loadFallbackAppServerConfigDocument(at: configPath)?.activeProfile else {
        return false
    }
    return profileOverrides.modelReasoningEffortOverride.isPresent
}

package func activeProfileClearsReviewModel(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    codexHome: URL? = nil
) -> Bool {
    if codexHome == nil {
        try? ReviewHomePaths.ensureReviewHomeScaffold(environment: environment)
    }
    let configPath = ReviewHomePaths.codexConfigURL(environment: environment, codexHome: codexHome)
    guard let profileOverrides = loadFallbackAppServerConfigDocument(at: configPath)?.activeProfile else {
        return false
    }
    return profileOverrides.reviewModelOverride.isPresent
        && profileOverrides.reviewModel == nil
}

package func activeProfileHasReviewModelOverride(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    codexHome: URL? = nil
) -> Bool {
    if codexHome == nil {
        try? ReviewHomePaths.ensureReviewHomeScaffold(environment: environment)
    }
    let configPath = ReviewHomePaths.codexConfigURL(environment: environment, codexHome: codexHome)
    guard let profileOverrides = loadFallbackAppServerConfigDocument(at: configPath)?.activeProfile else {
        return false
    }
    return profileOverrides.reviewModelOverride.isPresent
}

package func activeProfileClearsServiceTier(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    codexHome: URL? = nil
) -> Bool {
    if codexHome == nil {
        try? ReviewHomePaths.ensureReviewHomeScaffold(environment: environment)
    }
    let configPath = ReviewHomePaths.codexConfigURL(environment: environment, codexHome: codexHome)
    guard let profileOverrides = loadFallbackAppServerConfigDocument(at: configPath)?.activeProfile else {
        return false
    }
    return profileOverrides.serviceTierOverride.isPresent
        && profileOverrides.serviceTier == nil
}

package func activeProfileHasServiceTierOverride(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    codexHome: URL? = nil
) -> Bool {
    if codexHome == nil {
        try? ReviewHomePaths.ensureReviewHomeScaffold(environment: environment)
    }
    let configPath = ReviewHomePaths.codexConfigURL(environment: environment, codexHome: codexHome)
    guard let profileOverrides = loadFallbackAppServerConfigDocument(at: configPath)?.activeProfile else {
        return false
    }
    return profileOverrides.serviceTierOverride.isPresent
}
