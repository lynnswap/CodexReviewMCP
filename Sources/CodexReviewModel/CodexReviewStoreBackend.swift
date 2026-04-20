import Foundation

@MainActor
package protocol CodexReviewStoreBackend: AnyObject {
    var isActive: Bool { get }
    var shouldAutoStartEmbeddedServer: Bool { get }
    var initialAccount: CodexAccount? { get }
    var initialAccounts: [CodexAccount] { get }
    var initialActiveAccountKey: String? { get }
    var initialSettingsSnapshot: CodexReviewSettingsSnapshot { get }

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

    func refreshSettings() async throws -> CodexReviewSettingsSnapshot

    func updateSettingsModel(
        _ model: String?,
        reasoningEffort: CodexReviewReasoningEffort?,
        persistReasoningEffort: Bool,
        serviceTier: CodexReviewServiceTier?,
        persistServiceTier: Bool
    ) async throws

    func updateSettingsReasoningEffort(
        _ reasoningEffort: CodexReviewReasoningEffort?
    ) async throws

    func updateSettingsServiceTier(
        _ serviceTier: CodexReviewServiceTier?
    ) async throws

    func attachStore(_ store: CodexReviewStore)
}

extension CodexReviewStoreBackend {
    package var initialAccounts: [CodexAccount] {
        initialAccount.map { [$0] } ?? []
    }

    package var initialActiveAccountKey: String? {
        initialAccount?.accountKey
    }

    package var initialSettingsSnapshot: CodexReviewSettingsSnapshot {
        .init()
    }

    package func attachStore(_ store: CodexReviewStore) {
        _ = store
    }

    package func refreshSettings() async throws -> CodexReviewSettingsSnapshot {
        initialSettingsSnapshot
    }

    package func updateSettingsModel(
        _ model: String?,
        reasoningEffort: CodexReviewReasoningEffort?,
        persistReasoningEffort: Bool,
        serviceTier: CodexReviewServiceTier?,
        persistServiceTier: Bool
    ) async throws {
        _ = model
        _ = reasoningEffort
        _ = persistReasoningEffort
        _ = serviceTier
        _ = persistServiceTier
    }

    package func updateSettingsReasoningEffort(
        _ reasoningEffort: CodexReviewReasoningEffort?
    ) async throws {
        _ = reasoningEffort
    }

    package func updateSettingsServiceTier(
        _ serviceTier: CodexReviewServiceTier?
    ) async throws {
        _ = serviceTier
    }
}

@MainActor
package final class CodexReviewPreviewStoreBackend: CodexReviewStoreBackend {
    package private(set) var isActive = false
    package let shouldAutoStartEmbeddedServer = false
    package let initialAccount: CodexAccount? = nil
    package let initialAccounts: [CodexAccount] = []
    package let initialActiveAccountKey: String? = nil
    package var initialSettingsSnapshot: CodexReviewSettingsSnapshot = .init()

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
