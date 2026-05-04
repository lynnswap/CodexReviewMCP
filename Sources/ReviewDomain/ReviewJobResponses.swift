import Foundation

package struct ReviewReadResult: Sendable, Hashable {
    package var jobID: String
    package var threadID: String?
    package var turnID: String?
    package var model: String?
    package var status: ReviewJobState
    package var review: String
    package var reviewResult: ParsedReviewResult?
    package var lastAgentMessage: String
    package var logs: [ReviewLogEntry]
    package var rawLogText: String
    package var cancellation: ReviewCancellation?
    package var error: String?

    package init(
        jobID: String,
        threadID: String? = nil,
        turnID: String? = nil,
        model: String? = nil,
        status: ReviewJobState,
        review: String,
        reviewResult: ParsedReviewResult? = nil,
        lastAgentMessage: String,
        logs: [ReviewLogEntry],
        rawLogText: String,
        cancellation: ReviewCancellation? = nil,
        error: String? = nil
    ) {
        self.jobID = jobID
        self.threadID = threadID
        self.turnID = turnID
        self.model = model
        self.status = status
        self.review = review
        self.reviewResult = reviewResult
        self.lastAgentMessage = lastAgentMessage
        self.logs = logs
        self.rawLogText = rawLogText
        self.cancellation = cancellation
        self.error = error
    }

}

package struct ReviewJobListItem: Sendable, Hashable {
    package var jobID: String
    package var cwd: String
    package var targetSummary: String
    package var model: String?
    package var status: ReviewJobState
    package var summary: String
    package var reviewResult: ParsedReviewResult?
    package var startedAt: Date?
    package var endedAt: Date?
    package var elapsedSeconds: Int?
    package var threadID: String?
    package var lastAgentMessage: String
    package var cancellable: Bool
    package var cancellation: ReviewCancellation?

    package init(
        jobID: String,
        cwd: String,
        targetSummary: String,
        model: String?,
        status: ReviewJobState,
        summary: String,
        reviewResult: ParsedReviewResult? = nil,
        startedAt: Date?,
        endedAt: Date?,
        elapsedSeconds: Int?,
        threadID: String?,
        lastAgentMessage: String,
        cancellable: Bool,
        cancellation: ReviewCancellation? = nil
    ) {
        self.jobID = jobID
        self.cwd = cwd
        self.targetSummary = targetSummary
        self.model = model
        self.status = status
        self.summary = summary
        self.reviewResult = reviewResult
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.elapsedSeconds = elapsedSeconds
        self.threadID = threadID
        self.lastAgentMessage = lastAgentMessage
        self.cancellable = cancellable
        self.cancellation = cancellation
    }

}

package struct ReviewListResult: Sendable, Hashable {
    package var items: [ReviewJobListItem]

    package init(items: [ReviewJobListItem]) {
        self.items = items
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
    package var cancellation: ReviewCancellation?

    package init(
        jobID: String,
        threadID: String? = nil,
        cancelled: Bool,
        status: ReviewJobState,
        cancellation: ReviewCancellation? = nil
    ) {
        self.jobID = jobID
        self.threadID = threadID
        self.cancelled = cancelled
        self.status = status
        self.cancellation = cancellation
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

}
