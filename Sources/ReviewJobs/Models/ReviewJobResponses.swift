import Foundation
import MCP

package struct ReviewReadResult: Sendable, Hashable {
    package var jobID: String
    package var reviewThreadID: String
    package var threadID: String?
    package var turnID: String?
    package var status: ReviewJobState
    package var review: String
    package var lastAgentMessage: String
    package var error: String?

    package init(
        jobID: String,
        reviewThreadID: String,
        threadID: String? = nil,
        turnID: String? = nil,
        status: ReviewJobState,
        review: String,
        lastAgentMessage: String,
        error: String? = nil
    ) {
        self.jobID = jobID
        self.reviewThreadID = reviewThreadID
        self.threadID = threadID
        self.turnID = turnID
        self.status = status
        self.review = review
        self.lastAgentMessage = lastAgentMessage
        self.error = error
    }

    package func structuredContent() -> Value {
        var object: [String: Value] = [
            "jobId": .string(jobID),
            "parentThreadId": .string(parentThreadID),
            "reviewThreadId": .string(reviewThreadID),
            "status": .string(status.rawValue),
            "review": .string(review),
        ]
        if let threadID {
            object["threadId"] = .string(threadID)
        }
        object["turnId"] = turnID.map(Value.string) ?? .null
        if lastAgentMessage.isEmpty == false {
            object["lastAgentMessage"] = .string(lastAgentMessage)
        }
        if let error {
            object["error"] = .string(error)
        }
        return .object(object)
    }

    package var parentThreadID: String {
        threadID ?? reviewThreadID
    }
}

package struct ReviewJobListItem: Sendable, Hashable {
    package var jobID: String
    package var reviewThreadID: String
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
        reviewThreadID: String,
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
        self.reviewThreadID = reviewThreadID
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
            "reviewThreadId": .string(reviewThreadID),
            "cwd": .string(cwd),
            "targetSummary": .string(targetSummary),
            "status": .string(status.rawValue),
            "summary": .string(summary),
            "cancellable": .bool(cancellable),
        ]
        if let model {
            object["model"] = .string(model)
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
    package var reviewThreadID: String?
    package var cwd: String?
    package var statuses: [ReviewJobState]?
    package var latest: Bool

    package init(
        reviewThreadID: String? = nil,
        cwd: String? = nil,
        statuses: [ReviewJobState]? = nil,
        latest: Bool = false
    ) {
        self.reviewThreadID = reviewThreadID
        self.cwd = cwd?.nilIfEmpty
        self.statuses = statuses
        self.latest = latest
    }
}

package enum ReviewJobSelectionError: Error, Sendable {
    case notFound(String)
    case ambiguous([ReviewJobListItem])
}

package struct ReviewCancelOutcome: Sendable, Hashable {
    package var jobID: String
    package var reviewThreadID: String
    package var threadID: String?
    package var cancelled: Bool
    package var status: ReviewJobState

    package init(
        jobID: String,
        reviewThreadID: String,
        threadID: String? = nil,
        cancelled: Bool,
        status: ReviewJobState
    ) {
        self.jobID = jobID
        self.reviewThreadID = reviewThreadID
        self.threadID = threadID
        self.cancelled = cancelled
        self.status = status
    }

    package func structuredContent() -> Value {
        var object: [String: Value] = [
            "jobId": .string(jobID),
            "parentThreadId": .string(threadID ?? reviewThreadID),
            "reviewThreadId": .string(reviewThreadID),
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

package struct ReviewLogResult: Sendable {
    package var jobID: String
    package var source: ReviewLogSource
    package var text: String
    package var tailBytes: Int
    package var path: String?

    package init(jobID: String, source: ReviewLogSource, text: String, tailBytes: Int, path: String? = nil) {
        self.jobID = jobID
        self.source = source
        self.text = text
        self.tailBytes = tailBytes
        self.path = path
    }

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
