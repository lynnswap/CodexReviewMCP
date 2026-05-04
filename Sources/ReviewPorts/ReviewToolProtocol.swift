import ReviewDomain

@MainActor
package protocol ReviewToolProtocol: Sendable {
    func startReview(_ request: ReviewStartRequest) async throws -> ReviewReadResult

    func readReview(jobID: String) async throws -> ReviewReadResult

    func listReviews(
        cwd: String?,
        statuses: [ReviewJobState]?,
        limit: Int?
    ) async -> ReviewListResult

    func cancelReview(
        jobID: String,
        cancellation: ReviewCancellation
    ) async throws -> ReviewCancelOutcome

    func cancelReview(
        selector: ReviewJobSelector,
        cancellation: ReviewCancellation
    ) async throws -> ReviewCancelOutcome
}
