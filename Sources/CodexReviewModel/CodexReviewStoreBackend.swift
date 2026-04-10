import Foundation

@MainActor
package protocol CodexReviewStoreBackend: AnyObject {
    var isActive: Bool { get }
    var shouldAutoStartEmbeddedServer: Bool { get }
    var initialAuthState: CodexReviewAuthModel.State { get }

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

    func refreshAuthState(auth: CodexReviewAuthModel) async

    func beginAuthentication(auth: CodexReviewAuthModel) async

    func cancelAuthentication(auth: CodexReviewAuthModel) async

    func logout(auth: CodexReviewAuthModel) async
}

@MainActor
package final class CodexReviewPreviewStoreBackend: CodexReviewStoreBackend {
    package private(set) var isActive = false
    package let shouldAutoStartEmbeddedServer = false
    package let initialAuthState: CodexReviewAuthModel.State = .signedOut

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

    package func refreshAuthState(auth: CodexReviewAuthModel) async {
        auth.updateState(.signedOut)
    }

    package func beginAuthentication(auth: CodexReviewAuthModel) async {
        auth.updateState(.failed("Authentication is unavailable in preview mode."))
    }

    package func cancelAuthentication(auth: CodexReviewAuthModel) async {
        auth.updateState(.signedOut)
    }

    package func logout(auth: CodexReviewAuthModel) async {
        auth.updateState(.signedOut)
    }
}
