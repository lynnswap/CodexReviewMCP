import Foundation
import ReviewJobs

package struct ReviewLocalConfig: Sendable, Equatable {
    package var reviewModel: String?
    package var modelReasoningEffort: String?
    package var serviceTier: String?
    package var modelContextWindow: Int?
    package var modelAutoCompactTokenLimit: Int?

    package init(
        reviewModel: String? = nil,
        modelReasoningEffort: String? = nil,
        serviceTier: String? = nil,
        modelContextWindow: Int? = nil,
        modelAutoCompactTokenLimit: Int? = nil
    ) {
        self.reviewModel = reviewModel
        self.modelReasoningEffort = modelReasoningEffort
        self.serviceTier = serviceTier
        self.modelContextWindow = modelContextWindow
        self.modelAutoCompactTokenLimit = modelAutoCompactTokenLimit
    }
}

package enum ReviewLocalConfigError: LocalizedError {
    case unreadable(path: String, message: String)
    case invalidValue(path: String, key: String, expected: String)

    package var errorDescription: String? {
        switch self {
        case .unreadable(let path, let message):
            return "Could not read \(path): \(message)"
        case .invalidValue(let path, let key, let expected):
            return "Invalid `\(key)` in \(path): expected \(expected)"
        }
    }
}

package func loadReviewLocalConfig(
    environment: [String: String] = ProcessInfo.processInfo.environment
) throws -> ReviewLocalConfig {
    let fileURL = ReviewHomePaths.reviewConfigURL(environment: environment)
    do {
        try ReviewHomePaths.ensureReviewHomeScaffold(environment: environment)
    } catch {
        throw ReviewLocalConfigError.unreadable(path: fileURL.path, message: error.localizedDescription)
    }

    let content: String
    do {
        content = try String(contentsOf: fileURL, encoding: .utf8)
    } catch {
        throw ReviewLocalConfigError.unreadable(path: fileURL.path, message: error.localizedDescription)
    }

    return try parseReviewLocalConfig(content, sourcePath: fileURL.path)
}

package func parseReviewLocalConfig(
    _ content: String,
    sourcePath: String = ReviewHomePaths.reviewConfigURL().path
) throws -> ReviewLocalConfig {
    var config = ReviewLocalConfig()
    var inRoot = true

    for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
        let trimmed = stripReviewConfigComment(String(rawLine)).trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            continue
        }
        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
            inRoot = false
            continue
        }
        guard inRoot, let separator = trimmed.range(of: "=") else {
            continue
        }

        let key = trimmed[..<separator.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let rawValue = trimmed[separator.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)

        switch key {
        case "review_model":
            config.reviewModel = try parseReviewConfigString(
                rawValue,
                key: key,
                sourcePath: sourcePath
            )
        case "model_reasoning_effort":
            config.modelReasoningEffort = try parseReviewConfigString(
                rawValue,
                key: key,
                sourcePath: sourcePath
            )
        case "service_tier":
            config.serviceTier = try parseReviewConfigString(
                rawValue,
                key: key,
                sourcePath: sourcePath
            )
        case "model_context_window":
            config.modelContextWindow = try parseReviewConfigInteger(
                rawValue,
                key: key,
                sourcePath: sourcePath
            )
        case "model_auto_compact_token_limit":
            config.modelAutoCompactTokenLimit = try parseReviewConfigInteger(
                rawValue,
                key: key,
                sourcePath: sourcePath
            )
        default:
            continue
        }
    }

    return config
}

private func parseReviewConfigString(
    _ rawValue: String,
    key: String,
    sourcePath: String
) throws -> String? {
    guard rawValue.hasPrefix("\"") && rawValue.hasSuffix("\"")
            || rawValue.hasPrefix("'") && rawValue.hasSuffix("'")
    else {
        throw ReviewLocalConfigError.invalidValue(
            path: sourcePath,
            key: key,
            expected: "a TOML string"
        )
    }
    return trimReviewConfigMatchingQuotes(rawValue).nilIfEmpty
}

private func parseReviewConfigInteger(
    _ rawValue: String,
    key: String,
    sourcePath: String
) throws -> Int? {
    let normalized = trimReviewConfigMatchingQuotes(rawValue)
        .replacingOccurrences(of: "_", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalized.isEmpty == false,
          normalized.allSatisfy({ $0.isNumber }),
          let value = Int(normalized)
    else {
        throw ReviewLocalConfigError.invalidValue(
            path: sourcePath,
            key: key,
            expected: "an integer"
        )
    }
    return value
}

private func stripReviewConfigComment(_ line: String) -> String {
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

private func trimReviewConfigMatchingQuotes(_ value: String) -> String {
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
