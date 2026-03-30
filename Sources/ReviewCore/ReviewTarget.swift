import Foundation
import MCP
import ReviewJobs

package enum ReviewTarget: Hashable, Sendable {
    case uncommitted
    case branch(String)
    case commit(sha: String, title: String?)
    case custom(instructions: String)

    package func validated() throws -> Self {
        switch self {
        case .uncommitted:
            return self
        case .branch(let branch):
            guard branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw ReviewError.invalidArguments("`target.branch` is required.")
            }
            return .branch(branch.trimmingCharacters(in: .whitespacesAndNewlines))
        case .commit(let sha, let title):
            let trimmedSHA = sha.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedSHA.isEmpty == false else {
                throw ReviewError.invalidArguments("`target.sha` is required.")
            }
            return .commit(sha: trimmedSHA, title: title?.nilIfEmpty)
        case .custom(let instructions):
            let trimmedInstructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedInstructions.isEmpty == false else {
                throw ReviewError.invalidArguments("`target.instructions` is required.")
            }
            return .custom(instructions: trimmedInstructions)
        }
    }

    package func appServerValue() -> Value {
        switch self {
        case .uncommitted:
            return [
                "type": .string("uncommitted"),
            ]
        case .branch(let branch):
            return [
                "type": .string("branch"),
                "branch": .string(branch),
            ]
        case .commit(let sha, let title):
            var object: [String: Value] = [
                "type": .string("commit"),
                "sha": .string(sha),
            ]
            if let title {
                object["title"] = .string(title)
            }
            return .object(object)
        case .custom(let instructions):
            return [
                "type": .string("custom"),
                "instructions": .string(instructions),
            ]
        }
    }
}

extension ReviewTarget: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case branch
        case sha
        case title
        case instructions
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "uncommitted":
            self = .uncommitted
        case "branch":
            self = .branch(try container.decode(String.self, forKey: .branch))
        case "commit":
            self = .commit(
                sha: try container.decode(String.self, forKey: .sha),
                title: try container.decodeIfPresent(String.self, forKey: .title)
            )
        case "custom":
            self = .custom(instructions: try container.decode(String.self, forKey: .instructions))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown review target type: \(type)"
            )
        }
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .uncommitted:
            try container.encode("uncommitted", forKey: .type)
        case .branch(let branch):
            try container.encode("branch", forKey: .type)
            try container.encode(branch, forKey: .branch)
        case .commit(let sha, let title):
            try container.encode("commit", forKey: .type)
            try container.encode(sha, forKey: .sha)
            try container.encodeIfPresent(title, forKey: .title)
        case .custom(let instructions):
            try container.encode("custom", forKey: .type)
            try container.encode(instructions, forKey: .instructions)
        }
    }
}
