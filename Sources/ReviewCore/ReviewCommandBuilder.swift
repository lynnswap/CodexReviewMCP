import Foundation

package struct ReviewCommand: Sendable {
    package var executable: String
    package var arguments: [String]
    package var environment: [String: String]
    package var currentDirectory: String
    package var artifacts: ReviewArtifacts
}

package struct ReviewCommandBuilder: Sendable {
    package static var defaultReviewModel: String { ReviewDefaults.shared.review.defaultModel }

    package var codexCommand: String
    package var environment: [String: String]

    package init(
        codexCommand: String = "codex",
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.codexCommand = codexCommand
        self.environment = environment
    }

    package func build(request: ReviewRequestOptions) throws -> ReviewCommand {
        let request = try request.validated()
        let resolvedCodexCommand = try resolveExecutable()
        let artifacts = makeArtifacts()
        let configPath = resolveConfigPath()
        let modelsCache = loadJSONDictionary(at: resolveModelsCachePath())
        var forwardedArgs: [String] = []

        if let model = request.model?.nilIfEmpty {
            forwardedArgs += ["-c", "review_model=\(model)"]
        }
        if let base = request.base?.nilIfEmpty {
            forwardedArgs += ["--base", base]
        }
        if let commit = request.commit?.nilIfEmpty {
            forwardedArgs += ["--commit", commit]
        }
        if request.uncommitted {
            forwardedArgs.append("--uncommitted")
        }
        if let title = request.title?.nilIfEmpty {
            forwardedArgs += ["--title", title]
        }
        if request.ephemeral {
            forwardedArgs.append("--ephemeral")
        }
        for override in request.configOverrides {
            forwardedArgs += ["-c", override]
        }
        try validateExtraArgs(request.extraArgs)
        forwardedArgs += request.extraArgs

        let inspection = inspectForwardedArgs(forwardedArgs)
        let configuredProfileKey = inspection.explicitProfileKey
            ?? inspection.overrideProfileKey
            ?? readTopLevelString(from: configPath, key: "profile")
        let configuredPersonality = resolveConfiguredPersonality(
            explicitProfileKey: inspection.explicitProfileKey,
            overrideProfileKey: inspection.overrideProfileKey,
            configPath: configPath
        )

        var defaultConfigArgs: [String] = []
        var forcedConfigArgs: [String] = []

        if !inspection.foundHideReasoning {
            defaultConfigArgs += ["-c", "hide_agent_reasoning=\(ReviewDefaults.shared.review.hideAgentReasoning ? "true" : "false")"]
        }
        if !inspection.foundReviewModel {
            defaultConfigArgs += ["-c", "review_model=\(Self.defaultReviewModel)"]
        }
        if !inspection.foundPersonality, configuredPersonality == "friendly" {
            forcedConfigArgs += ["-c", "personality=none"]
        }
        if !inspection.foundReasoningEffort, !inspection.foundReviewModel {
            defaultConfigArgs += ["-c", "model_reasoning_effort=\(ReviewDefaults.shared.review.reasoningEffort)"]
        }
        if !inspection.foundReasoningSummary, !inspection.foundReviewModel {
            defaultConfigArgs += ["-c", "model_reasoning_summary=\(ReviewDefaults.shared.review.reasoningSummary)"]
        }

        let targetReviewModel = inspection.explicitReviewModel ?? Self.defaultReviewModel
        if let clampedContextWindow = computeForcedIntegerOverride(
            modelSlug: targetReviewModel,
            explicitValue: inspection.explicitModelContextWindow,
            key: "model_context_window",
            configPath: configPath,
            profileKey: configuredProfileKey,
            modelsCache: modelsCache
        ) {
            forcedConfigArgs += ["-c", "model_context_window=\(clampedContextWindow)"]
        }
        if let clampedAutoCompactLimit = computeForcedIntegerOverride(
            modelSlug: targetReviewModel,
            explicitValue: inspection.explicitModelAutoCompactTokenLimit,
            key: "model_auto_compact_token_limit",
            configPath: configPath,
            profileKey: configuredProfileKey,
            modelsCache: modelsCache
        ) {
            forcedConfigArgs += ["-c", "model_auto_compact_token_limit=\(clampedAutoCompactLimit)"]
        }

        var arguments = [
            "exec",
            "review",
            "--json",
            "--output-last-message",
            artifacts.lastMessagePath!,
        ]
        arguments += defaultConfigArgs
        arguments += forwardedArgs
        arguments += forcedConfigArgs
        if let prompt = request.prompt?.nilIfEmpty {
            arguments += ["--", prompt]
        }

        return ReviewCommand(
            executable: resolvedCodexCommand,
            arguments: arguments,
            environment: environment,
            currentDirectory: request.cwd,
            artifacts: artifacts
        )
    }

    private func makeArtifacts() -> ReviewArtifacts {
        let base = FileManager.default.temporaryDirectory
        let token = UUID().uuidString
        return ReviewArtifacts(
            eventsPath: base.appendingPathComponent("codex-review.events.\(token).jsonl").path,
            logPath: base.appendingPathComponent("codex-review.log.\(token)").path,
            lastMessagePath: base.appendingPathComponent("codex-review.last.\(token).txt").path
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

    private func validateExtraArgs(_ extraArgs: [String]) throws {
        for arg in extraArgs {
            if arg == "--"
                || arg == "--json"
                || arg == "--output-last-message"
                || arg.hasPrefix("--output-last-message=")
            {
                throw ReviewError.invalidArguments("`extraArgs` cannot override reserved review flag `\(arg)`.")
            }
        }
    }

    private func resolveExecutable() throws -> String {
        if codexCommand.contains("/") {
            return codexCommand
        }

        let resolvedCommand = resolveCodexCommand(
            requestedCommand: codexCommand,
            environment: environment
        )
        if resolvedCommand.contains("/") {
            return resolvedCommand
        }

        throw ReviewError.spawnFailed(
            "Unable to locate \(codexCommand) executable. Set --codex-command or ensure PATH contains \(codexCommand)."
        )
    }
}

private struct ForwardedArgsInspection: Sendable {
    var foundHideReasoning = false
    var foundReviewModel = false
    var foundReasoningEffort = false
    var foundReasoningSummary = false
    var foundPersonality = false
    var explicitReviewModel: String?
    var explicitModelContextWindow: Int?
    var explicitModelAutoCompactTokenLimit: Int?
    var explicitProfileKey: String?
    var overrideProfileKey: String?
}

private func inspectForwardedArgs(_ args: [String]) -> ForwardedArgsInspection {
    var inspection = ForwardedArgsInspection()
    var index = 0

    while index < args.count {
        let current = args[index]
        let next = index + 1 < args.count ? args[index + 1] : nil

        if let profileValue = extractFlagValue(current, next: next, short: "-p", long: "--profile") {
            inspection.explicitProfileKey = trimMatchingQuotes(profileValue)
            index += current == "-p" || current == "--profile" ? 2 : 1
            continue
        }
        if let modelValue = extractFlagValue(current, next: next, short: "-m", long: "--model") {
            inspection.foundReviewModel = true
            inspection.explicitReviewModel = trimMatchingQuotes(modelValue)
            index += current == "-m" || current == "--model" ? 2 : 1
            continue
        }
        guard let configOverride = extractFlagValue(current, next: next, short: "-c", long: "--config") else {
            index += 1
            continue
        }

        if let assignment = parseConfigAssignment(configOverride) {
            switch assignment.key {
            case "hide_agent_reasoning":
                inspection.foundHideReasoning = true
            case "review_model":
                inspection.foundReviewModel = true
                inspection.explicitReviewModel = trimMatchingQuotes(assignment.value)
            case "model_reasoning_effort":
                inspection.foundReasoningEffort = true
            case "model_reasoning_summary":
                inspection.foundReasoningSummary = true
            case "personality":
                inspection.foundPersonality = true
            case "profile":
                inspection.overrideProfileKey = trimMatchingQuotes(assignment.value)
            case "model_context_window":
                inspection.explicitModelContextWindow = normalizeIntegerLiteral(assignment.value)
            case "model_auto_compact_token_limit":
                inspection.explicitModelAutoCompactTokenLimit = normalizeIntegerLiteral(assignment.value)
            default:
                break
            }
        }
        index += current == "-c" || current == "--config" ? 2 : 1
    }

    return inspection
}

private func parseConfigAssignment(_ rawValue: String) -> (key: String, value: String)? {
    guard let separator = rawValue.firstIndex(of: "=") else {
        return nil
    }
    let key = rawValue[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
    let value = rawValue[rawValue.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
    guard key.isEmpty == false else {
        return nil
    }
    return (key, value)
}

private func extractFlagValue(
    _ current: String,
    next: String?,
    short: String,
    long: String
) -> String? {
    if current == short || current == long {
        return next
    }
    if current.hasPrefix("\(short)=") {
        return String(current.dropFirst(short.count + 1))
    }
    if current.hasPrefix("\(long)=") {
        return String(current.dropFirst(long.count + 1))
    }
    return nil
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

private func normalizeIntegerLiteral(_ rawValue: String?) -> Int? {
    guard let rawValue else {
        return nil
    }
    let normalized = trimMatchingQuotes(rawValue).replacingOccurrences(of: "_", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalized.isEmpty == false, normalized.allSatisfy(\.isNumber) else {
        return nil
    }
    return Int(normalized)
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
    switch modelSlug {
    case _:
        return ReviewDefaults.shared.models.fallbackContextWindows[modelSlug]
    }
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
    explicitValue: Int?,
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
    let configuredValue = explicitValue
        ?? profileKey.flatMap { readProfileInteger(from: configPath, profile: $0, key: key) }
        ?? readTopLevelInteger(from: configPath, key: key)
    guard let clampLimit, clampLimit > 0, let configuredValue, configuredValue > clampLimit else {
        return nil
    }
    return clampLimit
}

private func resolveConfiguredPersonality(
    explicitProfileKey: String?,
    overrideProfileKey: String?,
    configPath: URL?
) -> String? {
    let profileKey = explicitProfileKey
        ?? overrideProfileKey
        ?? readTopLevelString(from: configPath, key: "profile")
    if let profileKey, let value = readProfileString(from: configPath, profile: profileKey, key: "personality") {
        return value
    }
    return readTopLevelString(from: configPath, key: "personality")
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

private func readTopLevelInteger(from configPath: URL?, key: String) -> Int? {
    normalizeIntegerLiteral(readTopLevelValue(from: configPath, key: key))
}

private func readProfileInteger(from configPath: URL?, profile: String, key: String) -> Int? {
    normalizeIntegerLiteral(readProfileValue(from: configPath, profile: profile, key: key))
}

private func readTopLevelString(from configPath: URL?, key: String) -> String? {
    readTopLevelValue(from: configPath, key: key).map(trimMatchingQuotes).flatMap(\.nilIfEmpty)
}

private func readProfileString(from configPath: URL?, profile: String, key: String) -> String? {
    readProfileValue(from: configPath, profile: profile, key: key)
        .map(trimMatchingQuotes)
        .flatMap(\.nilIfEmpty)
}
