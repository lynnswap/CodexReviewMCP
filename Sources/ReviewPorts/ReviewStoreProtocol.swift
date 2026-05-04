import ReviewDomain

@MainActor
package protocol ReviewStoreProtocol: AnyObject, Sendable {
    func startReview(
        sessionID: String,
        request: ReviewStartRequest
    ) async throws -> ReviewReadResult

    func readReview(
        jobID: String,
        sessionID: String
    ) async throws -> ReviewReadResult

    func listReviews(
        sessionID: String,
        cwd: String?,
        statuses: [ReviewJobState]?,
        limit: Int?
    ) async -> ReviewListResult

    func cancelReview(
        selectedJobID jobID: String,
        sessionID: String,
        cancellation: ReviewCancellation
    ) async throws -> ReviewCancelOutcome

    func cancelReview(
        selector: ReviewJobSelector,
        sessionID: String,
        cancellation: ReviewCancellation
    ) async throws -> ReviewCancelOutcome

    func closeSession(_ sessionID: String, reason: String) async

    func hasActiveJobs(for sessionID: String) async -> Bool
}
