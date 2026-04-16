import Foundation

@MainActor
package protocol CodexReviewStoreBackend: AnyObject {
    var isActive: Bool { get }
    var shouldAutoStartEmbeddedServer: Bool { get }
    var initialAccount: CodexAccount? { get }
    var initialAccounts: [CodexAccount] { get }
    var initialActiveAccountKey: String? { get }

    func start(
        store: CodexReviewStore,
        forceRestartIfNeeded: Bool
    ) async

    func stop(store: CodexReviewStore) async

    func waitUntilStopped() async

    func cancelReview(
        jobID: String,
        sessionID: String,
        reason: String,
        store: CodexReviewStore
    ) async throws
}

extension CodexReviewStoreBackend {
    package var initialAccounts: [CodexAccount] {
        initialAccount.map { [$0] } ?? []
    }

    package var initialActiveAccountKey: String? {
        initialAccount?.accountKey
    }
}

@MainActor
package final class CodexReviewPreviewStoreBackend: CodexReviewStoreBackend {
    package private(set) var isActive = false
    package let shouldAutoStartEmbeddedServer = false
    package let initialAccount: CodexAccount? = nil
    package let initialAccounts: [CodexAccount] = []
    package let initialActiveAccountKey: String? = nil

    package init() {}

    package func start(
        store: CodexReviewStore,
        forceRestartIfNeeded: Bool
    ) async {
        _ = forceRestartIfNeeded
        store.transitionToFailed("Embedded server is unavailable in preview mode.")
    }

    package func stop(store: CodexReviewStore) async {
        _ = store
        isActive = false
    }

    package func waitUntilStopped() async {}

    package func cancelReview(
        jobID: String,
        sessionID: String,
        reason: String,
        store: CodexReviewStore
    ) async throws {
        try store.completeCancellationLocally(
            jobID: jobID,
            sessionID: sessionID,
            reason: reason
        )
    }
}
