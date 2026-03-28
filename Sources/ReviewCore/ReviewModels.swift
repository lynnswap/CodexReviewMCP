import Foundation
import MCP

package let codexReviewMCPName = "codex-review-mcp"
package let codexReviewMCPVersion = "0.1.0"
package var codexReviewDefaultPort: Int { ReviewDefaults.shared.server.defaultPort }

package enum ReviewJobState: String, Codable, Sendable {
    case queued
    case running
    case succeeded
    case failed
    case cancelled

    package var isTerminal: Bool {
        switch self {
        case .queued, .running:
            false
        case .succeeded, .failed, .cancelled:
            true
        }
    }
}

package enum ReviewLogSource: String, Codable, Sendable {
    case log
    case events
}

package enum ReviewProgressStage: String, Sendable {
    case queued
    case started
    case threadStarted = "thread_started"
    case completed
}

package enum ReviewTerminationReason: Sendable, Equatable {
    case cancelled(String)
}

package struct ReviewRequestOptions: Codable, Hashable, Sendable {
    package var cwd: String
    package var prompt: String?
    package var base: String?
    package var commit: String?
    package var uncommitted: Bool
    package var title: String?
    package var model: String?
    package var ephemeral: Bool
    package var configOverrides: [String]
    package var extraArgs: [String]
    package var timeoutSeconds: Int?
    package var keepArtifacts: Bool

    package init(
        cwd: String,
        prompt: String? = nil,
        base: String? = nil,
        commit: String? = nil,
        uncommitted: Bool = false,
        title: String? = nil,
        model: String? = nil,
        ephemeral: Bool = false,
        configOverrides: [String] = [],
        extraArgs: [String] = [],
        timeoutSeconds: Int? = nil,
        keepArtifacts: Bool = false
    ) {
        self.cwd = cwd
        self.prompt = prompt
        self.base = base
        self.commit = commit
        self.uncommitted = uncommitted
        self.title = title
        self.model = model
        self.ephemeral = ephemeral
        self.configOverrides = configOverrides
        self.extraArgs = extraArgs
        self.timeoutSeconds = timeoutSeconds
        self.keepArtifacts = keepArtifacts
    }

    package func validated() throws -> Self {
        let trimmedCWD = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedCWD.isEmpty == false else {
            throw ReviewError.invalidArguments("`cwd` is required.")
        }
        if commit != nil, base != nil || uncommitted {
            throw ReviewError.invalidArguments("`commit` cannot be combined with `base` or `uncommitted`.")
        }
        if base != nil, uncommitted {
            throw ReviewError.invalidArguments("`base` cannot be combined with `uncommitted`.")
        }
        if let timeoutSeconds, timeoutSeconds <= 0 {
            throw ReviewError.invalidArguments("`timeoutSeconds` must be a positive integer.")
        }
        var copy = self
        copy.cwd = trimmedCWD
        return copy
    }
}

package struct ReviewArtifacts: Codable, Hashable, Sendable {
    package var eventsPath: String?
    package var logPath: String?
    package var lastMessagePath: String?

    package init(eventsPath: String?, logPath: String?, lastMessagePath: String?) {
        self.eventsPath = eventsPath
        self.logPath = logPath
        self.lastMessagePath = lastMessagePath
    }
}

package struct ReviewJobSnapshot: Codable, Hashable, Sendable {
    package var jobID: String
    package var sessionID: String
    package var state: ReviewJobState
    package var threadID: String?
    package var lastAgentMessage: String
    package var errorMessage: String?
    package var startedAt: Date?
    package var endedAt: Date?
    package var exitCode: Int?
    package var summary: String
    package var artifacts: ReviewArtifacts
    package var elapsedSeconds: Int?

    package init(
        jobID: String,
        sessionID: String,
        state: ReviewJobState,
        threadID: String? = nil,
        lastAgentMessage: String = "",
        errorMessage: String? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        exitCode: Int? = nil,
        summary: String,
        artifacts: ReviewArtifacts = .init(eventsPath: nil, logPath: nil, lastMessagePath: nil),
        elapsedSeconds: Int? = nil
    ) {
        self.jobID = jobID
        self.sessionID = sessionID
        self.state = state
        self.threadID = threadID
        self.lastAgentMessage = lastAgentMessage
        self.errorMessage = errorMessage
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.exitCode = exitCode
        self.summary = summary
        self.artifacts = artifacts
        self.elapsedSeconds = elapsedSeconds
    }

    package func structuredContent(includeArtifacts: Bool = true) -> Value {
        var object: [String: Value] = [
            "jobId": .string(jobID),
            "status": .string(state.rawValue),
            "summary": .string(summary),
        ]
        if let threadID {
            object["threadId"] = .string(threadID)
        }
        if let exitCode {
            object["exitCode"] = .int(exitCode)
        }
        if let startedAt {
            object["startedAt"] = .string(startedAt.ISO8601Format())
        }
        if let endedAt {
            object["endedAt"] = .string(endedAt.ISO8601Format())
        }
        if let elapsedSeconds {
            object["elapsedSeconds"] = .int(elapsedSeconds)
        }
        if lastAgentMessage.isEmpty == false {
            object["lastAgentMessage"] = .string(lastAgentMessage)
        }
        if let errorMessage {
            object["errorMessage"] = .string(errorMessage)
        }
        if includeArtifacts {
            var artifactsObject: [String: Value] = [:]
            if let path = artifacts.eventsPath {
                artifactsObject["eventsPath"] = .string(path)
            }
            if let path = artifacts.logPath {
                artifactsObject["logPath"] = .string(path)
            }
            if let path = artifacts.lastMessagePath {
                artifactsObject["lastMessagePath"] = .string(path)
            }
            object["artifacts"] = .object(artifactsObject)
            if let path = artifacts.eventsPath {
                object["eventsPath"] = .string(path)
            }
            if let path = artifacts.logPath {
                object["logPath"] = .string(path)
            }
        }
        return .object(object)
    }
}

package struct ReviewExecutionResult: Sendable {
    package var snapshot: ReviewJobSnapshot
    package var content: String
    package var isError: Bool
}

package enum ReviewTarget: Hashable, Sendable {
    case uncommittedChanges
    case baseBranch(branch: String)
    case commit(sha: String, title: String?)
    case custom(instructions: String)

    package func validated() throws -> Self {
        switch self {
        case .uncommittedChanges:
            return self
        case .baseBranch(let branch):
            guard branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw ReviewError.invalidArguments("`target.branch` is required.")
            }
            return .baseBranch(branch: branch.trimmingCharacters(in: .whitespacesAndNewlines))
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
        case .uncommittedChanges:
            return [
                "type": .string("uncommittedChanges"),
            ]
        case .baseBranch(let branch):
            return [
                "type": .string("baseBranch"),
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
        case "uncommittedChanges":
            self = .uncommittedChanges
        case "baseBranch":
            self = .baseBranch(branch: try container.decode(String.self, forKey: .branch))
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
        case .uncommittedChanges:
            try container.encode("uncommittedChanges", forKey: .type)
        case .baseBranch(let branch):
            try container.encode("baseBranch", forKey: .type)
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

package struct ReviewStartRequest: Codable, Hashable, Sendable {
    package var cwd: String
    package var target: ReviewTarget
    package var model: String?

    package init(cwd: String, target: ReviewTarget, model: String? = nil) {
        self.cwd = cwd
        self.target = target
        self.model = model
    }

    package func validated() throws -> Self {
        let trimmedCWD = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedCWD.isEmpty == false else {
            throw ReviewError.invalidArguments("`cwd` is required.")
        }
        var copy = self
        copy.cwd = trimmedCWD
        copy.target = try target.validated()
        copy.model = model?.nilIfEmpty
        return copy
    }
}

package struct ReviewHandle: Sendable, Hashable {
    package var parentThreadID: String
    package var reviewThreadID: String
    package var turnID: String
    package var status: ReviewJobState

    package func structuredContent() -> Value {
        .object([
            "parentThreadId": .string(parentThreadID),
            "reviewThreadId": .string(reviewThreadID),
            "turnId": .string(turnID),
            "status": .string(status.rawValue),
        ])
    }
}

package struct ReviewReadResult: Sendable, Hashable {
    package var parentThreadID: String
    package var reviewThreadID: String
    package var turnID: String
    package var status: ReviewJobState
    package var review: String
    package var error: String?

    package func structuredContent() -> Value {
        var object: [String: Value] = [
            "parentThreadId": .string(parentThreadID),
            "reviewThreadId": .string(reviewThreadID),
            "turnId": .string(turnID),
            "status": .string(status.rawValue),
            "review": .string(review),
        ]
        if let error {
            object["error"] = .string(error)
        }
        return .object(object)
    }
}

package struct ReviewCancelOutcome: Sendable, Hashable {
    package var reviewThreadID: String
    package var turnID: String
    package var cancelled: Bool

    package func structuredContent() -> Value {
        .object([
            "reviewThreadId": .string(reviewThreadID),
            "turnId": .string(turnID),
            "cancelled": .bool(cancelled),
        ])
    }
}

package struct ReviewCancelResult: Sendable {
    package var jobID: String
    package var state: ReviewJobState
    package var signalled: Bool

    package func structuredContent() -> Value {
        .object([
            "jobId": .string(jobID),
            "status": .string(state.rawValue),
            "signalled": .bool(signalled),
        ])
    }
}

package struct ReviewLogResult: Sendable {
    package var jobID: String
    package var source: ReviewLogSource
    package var text: String
    package var tailBytes: Int
    package var path: String?

    package func structuredContent() -> Value {
        var object: [String: Value] = [
            "jobId": .string(jobID),
            "source": .string(source.rawValue),
            "tailBytes": .int(tailBytes),
        ]
        if let path {
            object["path"] = .string(path)
        }
        return .object(object)
    }
}

package enum ReviewError: LocalizedError, Sendable {
    case invalidArguments(String)
    case jobNotFound(String)
    case accessDenied(String)
    case spawnFailed(String)
    case io(String)

    package var errorDescription: String? {
        switch self {
        case .invalidArguments(let message),
             .jobNotFound(let message),
             .accessDenied(let message),
             .spawnFailed(let message),
             .io(let message):
            message
        }
    }
}

extension String {
    package var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
