import Foundation
import MCP

package struct ReviewReadResult: Sendable, Hashable {
    package var jobID: String
    package var threadID: String?
    package var turnID: String?
    package var model: String?
    package var status: ReviewJobState
    package var review: String
    package var lastAgentMessage: String
    package var logs: [ReviewLogEntry]
    package var rawLogText: String
    package var error: String?

    package init(
        jobID: String,
        threadID: String? = nil,
        turnID: String? = nil,
        model: String? = nil,
        status: ReviewJobState,
        review: String,
        lastAgentMessage: String,
        logs: [ReviewLogEntry],
        rawLogText: String,
        error: String? = nil
    ) {
        self.jobID = jobID
        self.threadID = threadID
        self.turnID = turnID
        self.model = model
        self.status = status
        self.review = review
        self.lastAgentMessage = lastAgentMessage
        self.logs = logs
        self.rawLogText = rawLogText
        self.error = error
    }

    package func structuredContentForStart() -> Value {
        structuredContent(includeDetails: false)
    }

    package func structuredContentForRead() -> Value {
        structuredContent(includeDetails: true)
    }

    private func structuredContent(includeDetails: Bool) -> Value {
        var object: [String: Value] = [
            "jobId": .string(jobID),
            "status": .string(status.rawValue),
            "review": .string(review),
        ]
        if let threadID {
            object["threadId"] = .string(threadID)
        }
        object["turnId"] = turnID.map(Value.string) ?? .null
        object["model"] = model.map(Value.string) ?? .null
        if includeDetails {
            object["logs"] = .array(logs.map { $0.structuredContent() })
            object["rawLogText"] = .string(rawLogText)
            if lastAgentMessage.isEmpty == false {
                object["lastAgentMessage"] = .string(lastAgentMessage)
            }
        }
        if let error {
            object["error"] = .string(error)
        }
        return .object(object)
    }
}

package struct ReviewJobListItem: Sendable, Hashable {
    package var jobID: String
    package var cwd: String
    package var targetSummary: String
    package var model: String?
    package var status: ReviewJobState
    package var summary: String
    package var startedAt: Date?
    package var endedAt: Date?
    package var elapsedSeconds: Int?
    package var threadID: String?
    package var lastAgentMessage: String
    package var cancellable: Bool

    package init(
        jobID: String,
        cwd: String,
        targetSummary: String,
        model: String?,
        status: ReviewJobState,
        summary: String,
        startedAt: Date?,
        endedAt: Date?,
        elapsedSeconds: Int?,
        threadID: String?,
        lastAgentMessage: String,
        cancellable: Bool
    ) {
        self.jobID = jobID
        self.cwd = cwd
        self.targetSummary = targetSummary
        self.model = model
        self.status = status
        self.summary = summary
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.elapsedSeconds = elapsedSeconds
        self.threadID = threadID
        self.lastAgentMessage = lastAgentMessage
        self.cancellable = cancellable
    }

    package func structuredContent() -> Value {
        var object: [String: Value] = [
            "jobId": .string(jobID),
            "cwd": .string(cwd),
            "targetSummary": .string(targetSummary),
            "status": .string(status.rawValue),
            "summary": .string(summary),
            "cancellable": .bool(cancellable),
        ]
        object["model"] = model.map(Value.string) ?? .null
        if let startedAt {
            object["startedAt"] = .string(startedAt.ISO8601Format())
        }
        if let endedAt {
            object["endedAt"] = .string(endedAt.ISO8601Format())
        }
        if let elapsedSeconds {
            object["elapsedSeconds"] = .int(elapsedSeconds)
        }
        if let threadID {
            object["threadId"] = .string(threadID)
        }
        if lastAgentMessage.isEmpty == false {
            object["lastAgentMessage"] = .string(lastAgentMessage)
        }
        return .object(object)
    }
}

package struct ReviewListResult: Sendable, Hashable {
    package var items: [ReviewJobListItem]

    package init(items: [ReviewJobListItem]) {
        self.items = items
    }

    package func structuredContent() -> Value {
        .object([
            "items": .array(items.map { $0.structuredContent() })
        ])
    }
}

package struct ReviewJobSelector: Sendable, Hashable {
    package var jobID: String?
    package var cwd: String?
    package var statuses: [ReviewJobState]?

    package init(
        jobID: String? = nil,
        cwd: String? = nil,
        statuses: [ReviewJobState]? = nil
    ) {
        self.jobID = jobID
        self.cwd = cwd?.nilIfEmpty
        self.statuses = statuses
    }
}

package enum ReviewJobSelectionError: Error, Sendable {
    case notFound(String)
    case ambiguous([ReviewJobListItem])
}

package struct ReviewCancelOutcome: Sendable, Hashable {
    package var jobID: String
    package var threadID: String?
    package var cancelled: Bool
    package var status: ReviewJobState

    package init(
        jobID: String,
        threadID: String? = nil,
        cancelled: Bool,
        status: ReviewJobState
    ) {
        self.jobID = jobID
        self.threadID = threadID
        self.cancelled = cancelled
        self.status = status
    }

    package func structuredContent() -> Value {
        var object: [String: Value] = [
            "jobId": .string(jobID),
            "cancelled": .bool(cancelled),
            "status": .string(status.rawValue),
            "turnId": .null,
        ]
        if let threadID {
            object["threadId"] = .string(threadID)
        }
        return .object(object)
    }

    package var turnID: String? {
        nil
    }
}

package struct ReviewCancelResult: Sendable {
    package var jobID: String
    package var state: ReviewJobState
    package var signalled: Bool

    package init(jobID: String, state: ReviewJobState, signalled: Bool) {
        self.jobID = jobID
        self.state = state
        self.signalled = signalled
    }

    package func structuredContent() -> Value {
        .object([
            "jobId": .string(jobID),
            "status": .string(state.rawValue),
            "signalled": .bool(signalled),
        ])
    }
}
