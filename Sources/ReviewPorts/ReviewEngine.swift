import Foundation
import ReviewDomain

package protocol ReviewEngine: Sendable {
    func initialReviewModel() async -> String?

    func runReview(
        jobID: String,
        sessionID: String,
        request: ReviewRequestOptions,
        resolvedModelHint: String?,
        stateChangeStream: AsyncStream<Void>,
        onStart: @escaping @Sendable (Date) async -> Void,
        onReviewStarted: @escaping @Sendable () async -> Void,
        onEvent: @escaping @Sendable (ReviewProcessEvent) async -> Void,
        requestedTerminationReason: @escaping @Sendable () async -> ReviewTerminationReason?
    ) async throws -> ReviewProcessOutcome

    @discardableResult
    func interruptReview(jobID: String) async -> Bool
}
