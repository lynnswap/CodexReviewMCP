import Foundation

package struct ReviewReadResult: Sendable, Hashable {
    package var jobID: String
    package var core: ReviewJobCore
    package var elapsedSeconds: Int?
    package var cancellable: Bool
    package var logs: [ReviewLogEntry]
    package var rawLogText: String

    package init(
        jobID: String,
        core: ReviewJobCore,
        elapsedSeconds: Int? = nil,
        cancellable: Bool,
        logs: [ReviewLogEntry],
        rawLogText: String
    ) {
        self.jobID = jobID
        self.core = core
        self.elapsedSeconds = elapsedSeconds
        self.cancellable = cancellable
        self.logs = logs
        self.rawLogText = rawLogText
    }

}

package struct ReviewJobListItem: Sendable, Hashable {
    package var jobID: String
    package var cwd: String
    package var targetSummary: String
    package var core: ReviewJobCore
    package var elapsedSeconds: Int?
    package var cancellable: Bool

    package init(
        jobID: String,
        cwd: String,
        targetSummary: String,
        core: ReviewJobCore,
        elapsedSeconds: Int?,
        cancellable: Bool
    ) {
        self.jobID = jobID
        self.cwd = cwd
        self.targetSummary = targetSummary
        self.core = core
        self.elapsedSeconds = elapsedSeconds
        self.cancellable = cancellable
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
    package var cancelled: Bool
    package var core: ReviewJobCore

    package init(
        jobID: String,
        cancelled: Bool,
        core: ReviewJobCore
    ) {
        self.jobID = jobID
        self.cancelled = cancelled
        self.core = core
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
