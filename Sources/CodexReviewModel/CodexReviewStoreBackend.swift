import Foundation

@MainActor
package protocol CodexReviewStoreBackend: AnyObject {
    var isActive: Bool { get }

    func start(
        store: CodexReviewStore,
        forceRestartIfNeeded: Bool
    ) async

    func stop(store: CodexReviewStore) async

    func waitUntilStopped() async
}

@MainActor
package final class CodexReviewPreviewStoreBackend: CodexReviewStoreBackend {
    package private(set) var isActive = false

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
}
