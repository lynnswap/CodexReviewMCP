import Foundation
import ReviewDomain

package struct ReviewBootstrapFailure: Error, LocalizedError, Sendable {
    package var message: String
    package var model: String?

    package init(message: String, model: String? = nil) {
        self.message = message
        self.model = model
    }

    package var errorDescription: String? {
        message
    }
}

package struct ReviewProcessOutcome: Sendable {
    package var state: ReviewJobState
    package var exitCode: Int
    package var reviewThreadID: String?
    package var threadID: String?
    package var turnID: String?
    package var model: String?
    package var hasFinalReview: Bool
    package var lastAgentMessage: String
    package var errorMessage: String?
    package var summary: String
    package var startedAt: Date
    package var endedAt: Date
    package var content: String

    package init(
        state: ReviewJobState,
        exitCode: Int,
        reviewThreadID: String? = nil,
        threadID: String? = nil,
        turnID: String? = nil,
        model: String? = nil,
        hasFinalReview: Bool,
        lastAgentMessage: String,
        errorMessage: String? = nil,
        summary: String,
        startedAt: Date,
        endedAt: Date,
        content: String
    ) {
        self.state = state
        self.exitCode = exitCode
        self.reviewThreadID = reviewThreadID
        self.threadID = threadID
        self.turnID = turnID
        self.model = model
        self.hasFinalReview = hasFinalReview
        self.lastAgentMessage = lastAgentMessage
        self.errorMessage = errorMessage
        self.summary = summary
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.content = content
    }
}
