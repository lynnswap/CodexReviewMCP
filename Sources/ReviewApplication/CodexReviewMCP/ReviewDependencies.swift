import Foundation
import ReviewDomain

@MainActor
package struct ReviewDependencies {
    package let core: ReviewStoreDependencies
    package let coordinator: ReviewMonitorCoordinator
    package let settingsService: ReviewMonitorSettingsService
    package let diagnosticsURL: URL?

    package init(
        core: ReviewStoreDependencies,
        coordinator: ReviewMonitorCoordinator,
        settingsService: ReviewMonitorSettingsService,
        diagnosticsURL: URL? = nil
    ) {
        self.core = core
        self.coordinator = coordinator
        self.settingsService = settingsService
        self.diagnosticsURL = diagnosticsURL
    }

    package static func preview(
        seed: ReviewMonitorCoordinator.Seed = .init(),
        diagnosticsURL: URL? = nil
    ) -> Self {
        let harness = ReviewMonitorTestingHarness(seed: seed)
        return .init(
            core: .live(),
            coordinator: .init(harness: harness),
            settingsService: .init(
                initialSnapshot: harness.currentSettingsSnapshot,
                backend: harness
            ),
            diagnosticsURL: diagnosticsURL
        )
    }
}

@MainActor
extension CodexReviewStore {
    package convenience init(dependencies: ReviewDependencies) {
        self.init(
            coreDependencies: dependencies.core,
            coordinator: dependencies.coordinator,
            settingsService: dependencies.settingsService,
            diagnosticsURL: dependencies.diagnosticsURL
        )
    }

    public static func makePreviewStore(
        diagnosticsURL: URL? = nil
    ) -> CodexReviewStore {
        makePreviewStore(
            seed: .init(),
            diagnosticsURL: diagnosticsURL
        )
    }

    package static func makePreviewStore(
        seed: ReviewMonitorCoordinator.Seed,
        diagnosticsURL: URL? = nil
    ) -> CodexReviewStore {
        CodexReviewStore(
            dependencies: .preview(
                seed: seed,
                diagnosticsURL: diagnosticsURL
            )
        )
    }

    package static func makeTestingStore(
        harness: ReviewMonitorTestingHarness,
        diagnosticsURL: URL? = nil
    ) -> CodexReviewStore {
        CodexReviewStore(
            coreDependencies: .live(),
            coordinator: .init(harness: harness),
            settingsService: .init(
                initialSnapshot: harness.currentSettingsSnapshot,
                backend: harness
            ),
            diagnosticsURL: diagnosticsURL
        )
    }

    @MainActor
    public static func makeReviewMonitorUITestStore() -> CodexReviewStore {
        let store = makePreviewStore()
        store.serverState = .running
        store.serverURL = URL(string: "http://127.0.0.1:9417/mcp")
        let account = CodexAccount(email: "ui-test@example.com", planType: "unknown")
        store.auth.applyPersistedAccountStates(
            [savedAccountPayload(from: account)],
            activeAccountKey: account.accountKey
        )
        store.auth.selectPersistedAccount(account.id)
        return store
    }
}
