import Foundation
import ReviewDomain
import ReviewInfra

@MainActor
package class ReviewMonitorTestingHarness {
    package let seed: ReviewMonitorCoordinator.Seed
    package var isActive = false
    package var currentSettingsSnapshot: CodexReviewSettingsSnapshot

    package init(seed: ReviewMonitorCoordinator.Seed = .init()) {
        self.seed = seed
        currentSettingsSnapshot = seed.initialSettingsSnapshot
    }

    package var shouldAutoStartEmbeddedServer: Bool {
        seed.shouldAutoStartEmbeddedServer
    }

    package var initialAccount: CodexAccount? {
        seed.initialAccount
    }

    package var initialAccounts: [CodexAccount] {
        seed.initialAccounts
    }

    package func attachStore(_: CodexReviewStore) {}

    package func start(
        store: CodexReviewStore,
        forceRestartIfNeeded _: Bool
    ) async {
        isActive = true
        store.transitionToFailed(Self.previewUnavailableMessage)
    }

    package func stop(store _: CodexReviewStore) async {
        isActive = false
    }

    package func waitUntilStopped() async {}

    package func refreshSettings() async throws -> CodexReviewSettingsSnapshot {
        currentSettingsSnapshot
    }

    package func updateSettingsModel(
        _ model: String?,
        reasoningEffort: CodexReviewReasoningEffort?,
        persistReasoningEffort: Bool,
        serviceTier: CodexReviewServiceTier?,
        persistServiceTier: Bool
    ) async throws {
        currentSettingsSnapshot.model = model
        if persistReasoningEffort {
            currentSettingsSnapshot.reasoningEffort = reasoningEffort
        }
        if persistServiceTier {
            currentSettingsSnapshot.serviceTier = serviceTier
        }
    }

    package func updateSettingsReasoningEffort(
        _ reasoningEffort: CodexReviewReasoningEffort?
    ) async throws {
        currentSettingsSnapshot.reasoningEffort = reasoningEffort
    }

    package func updateSettingsServiceTier(
        _ serviceTier: CodexReviewServiceTier?
    ) async throws {
        currentSettingsSnapshot.serviceTier = serviceTier
    }

    package func startStartupRefresh(auth: CodexReviewAuthModel) {
        if auth.selectedAccount == nil {
            auth.updatePhase(.signedOut)
        }
    }

    package func cancelStartupRefresh() {}

    package func refreshAuth(auth: CodexReviewAuthModel) async {
        if auth.selectedAccount == nil {
            auth.updatePhase(.signedOut)
        }
    }

    package func signIn(auth: CodexReviewAuthModel) async {
        auth.updatePhase(.failed(message: Self.previewAuthenticationFailureMessage))
    }

    package func addAccount(auth: CodexReviewAuthModel) async {
        auth.updatePhase(.failed(message: Self.previewAuthenticationFailureMessage))
    }

    package func cancelAuthentication(auth: CodexReviewAuthModel) async {
        if auth.selectedAccount == nil {
            auth.updatePhase(.signedOut)
        }
    }

    package func switchAccount(
        auth: CodexReviewAuthModel,
        accountKey: String
    ) async throws {
        guard auth.persistedAccounts.contains(where: { $0.accountKey == accountKey }) else {
            return
        }
        auth.applyPersistedAccountStates(
            auth.persistedAccounts.map(savedAccountPayload(from:)),
            activeAccountKey: accountKey
        )
        auth.selectPersistedAccount(
            auth.persistedAccounts.first(where: { $0.accountKey == accountKey })?.id
        )
        auth.updatePhase(.signedOut)
    }

    package func removeAccount(
        auth: CodexReviewAuthModel,
        accountKey: String
    ) async throws {
        let filteredAccounts = auth.persistedAccounts.filter { $0.accountKey != accountKey }
        auth.applyPersistedAccountStates(filteredAccounts.map(savedAccountPayload(from:)))
        if auth.selectedAccount?.accountKey == accountKey {
            auth.selectPersistedAccount(nil)
            auth.updatePhase(.signedOut)
        }
    }

    package func reorderPersistedAccount(
        auth: CodexReviewAuthModel,
        accountKey: String,
        toIndex: Int
    ) async throws {
        var reorderedAccounts = auth.persistedAccounts
        guard let sourceIndex = reorderedAccounts.firstIndex(where: { $0.accountKey == accountKey }) else {
            return
        }
        let destinationIndex = max(0, min(toIndex, reorderedAccounts.count - 1))
        guard sourceIndex != destinationIndex else {
            return
        }
        let account = reorderedAccounts.remove(at: sourceIndex)
        reorderedAccounts.insert(account, at: destinationIndex)
        auth.applyPersistedAccountStates(reorderedAccounts.map(savedAccountPayload(from:)))
    }

    package func signOutActiveAccount(auth: CodexReviewAuthModel) async throws {
        auth.updatePhase(.signedOut)
        auth.selectPersistedAccount(nil)
        auth.applyPersistedAccountStates([])
    }

    package func refreshAccountRateLimits(
        auth _: CodexReviewAuthModel,
        accountKey _: String
    ) async {}

    package func reconcileAuthenticatedSession(
        auth _: CodexReviewAuthModel,
        serverIsRunning _: Bool,
        runtimeGeneration _: Int
    ) async {}

    package func requiresCurrentSessionRecovery(
        auth _: CodexReviewAuthModel,
        accountKey _: String
    ) -> Bool {
        return false
    }

    package func startReview(
        sessionID _: String,
        request _: ReviewStartRequest,
        store _: CodexReviewStore
    ) async throws -> ReviewReadResult {
        throw ReviewError.io("CodexReviewStore live runtime is unavailable.")
    }

    package func cancelReviewByID(
        jobID: String,
        sessionID: String,
        cancellation: ReviewCancellation,
        store: CodexReviewStore
    ) async throws -> ReviewCancelOutcome {
        let job = try store.resolveJob(jobID: jobID, sessionID: sessionID)
        try store.completeCancellationLocally(
            jobID: job.id,
            sessionID: sessionID,
            cancellation: cancellation
        )
        return .init(
            jobID: job.id,
            threadID: job.threadID,
            cancelled: true,
            status: .cancelled,
            cancellation: cancellation
        )
    }

    package func cancelReviewBySelector(
        selector: ReviewJobSelector,
        sessionID: String,
        cancellation: ReviewCancellation,
        store: CodexReviewStore
    ) async throws -> ReviewCancelOutcome {
        let job = try store.resolveJob(sessionID: sessionID, selector: selector)
        try store.completeCancellationLocally(
            jobID: job.id,
            sessionID: sessionID,
            cancellation: cancellation
        )
        return .init(
            jobID: job.id,
            threadID: job.threadID,
            cancelled: true,
            status: .cancelled,
            cancellation: cancellation
        )
    }

    package func closeSession(
        _: String,
        reason _: String,
        store _: CodexReviewStore
    ) async {}

    fileprivate static let previewUnavailableMessage = "Embedded server is unavailable in preview mode."
    fileprivate static let previewAuthenticationFailureMessage = "Authentication is unavailable in preview mode."
}

@MainActor
package final class ReviewMonitorCoordinator {
    package struct Seed {
        package var shouldAutoStartEmbeddedServer: Bool
        package var initialAccount: CodexAccount?
        package var initialAccounts: [CodexAccount]
        package var initialActiveAccountKey: String?
        package var initialSettingsSnapshot: CodexReviewSettingsSnapshot

        package init(
            shouldAutoStartEmbeddedServer: Bool = false,
            initialAccount: CodexAccount? = nil,
            initialAccounts: [CodexAccount] = [],
            initialActiveAccountKey: String? = nil,
            initialSettingsSnapshot: CodexReviewSettingsSnapshot = .init()
        ) {
            self.shouldAutoStartEmbeddedServer = shouldAutoStartEmbeddedServer
            self.initialAccount = initialAccount
            self.initialAccounts = initialAccounts
            self.initialActiveAccountKey = initialActiveAccountKey
            self.initialSettingsSnapshot = initialSettingsSnapshot
        }
    }

    private struct LiveMode {
        let serverRuntime: ReviewMonitorServerRuntime
        let authOrchestrator: ReviewMonitorAuthOrchestrator
        let executionCoordinator: ReviewExecutionCoordinator
    }

    private enum Mode {
        case live(LiveMode)
        case harness(ReviewMonitorTestingHarness)
    }

    package let seed: Seed

    private let mode: Mode
    private weak var attachedStore: CodexReviewStore?
    private var closedSessions: Set<String> = []

    package init(
        seed: Seed,
        serverRuntime: ReviewMonitorServerRuntime,
        authOrchestrator: ReviewMonitorAuthOrchestrator,
        executionCoordinator: ReviewExecutionCoordinator
    ) {
        self.seed = seed
        mode = .live(
            .init(
                serverRuntime: serverRuntime,
                authOrchestrator: authOrchestrator,
                executionCoordinator: executionCoordinator
            )
        )
    }

    package init(harness: ReviewMonitorTestingHarness) {
        seed = harness.seed
        mode = .harness(harness)
    }

    package var shouldAutoStartEmbeddedServer: Bool {
        seed.shouldAutoStartEmbeddedServer
    }

    package var isActive: Bool {
        switch mode {
        case .live(let live):
            live.serverRuntime.isActive
        case .harness(let harness):
            harness.isActive
        }
    }

    package func attachStore(_ store: CodexReviewStore) {
        attachedStore = store
        switch mode {
        case .live(let live):
            live.serverRuntime.attachStore(store)
        case .harness(let harness):
            harness.attachStore(store)
        }
    }

    package func start(
        store: CodexReviewStore,
        forceRestartIfNeeded: Bool
    ) async {
        closedSessions = []
        switch mode {
        case .live(let live):
            await live.serverRuntime.start(
                store: store,
                forceRestartIfNeeded: forceRestartIfNeeded
            )
        case .harness(let harness):
            await harness.start(
                store: store,
                forceRestartIfNeeded: forceRestartIfNeeded
            )
        }
    }

    package func stop(store: CodexReviewStore) async {
        switch mode {
        case .live(let live):
            await live.serverRuntime.stop(store: store)
        case .harness(let harness):
            await harness.stop(store: store)
        }
        closedSessions = []
    }

    package func waitUntilStopped() async {
        switch mode {
        case .live(let live):
            await live.serverRuntime.waitUntilStopped()
        case .harness(let harness):
            await harness.waitUntilStopped()
        }
    }

    package func refreshAuth(auth: CodexReviewAuthModel) async {
        switch mode {
        case .live(let live):
            await live.authOrchestrator.refresh(auth: auth)
        case .harness(let harness):
            await harness.refreshAuth(auth: auth)
        }
    }

    package func signIn(auth: CodexReviewAuthModel) async {
        switch mode {
        case .live(let live):
            await live.authOrchestrator.signIn(auth: auth)
        case .harness(let harness):
            await harness.signIn(auth: auth)
        }
    }

    package func addAccount(auth: CodexReviewAuthModel) async {
        switch mode {
        case .live(let live):
            await live.authOrchestrator.addAccount(auth: auth)
        case .harness(let harness):
            await harness.addAccount(auth: auth)
        }
    }

    package func cancelAuthentication(auth: CodexReviewAuthModel) async {
        switch mode {
        case .live(let live):
            await live.authOrchestrator.cancelAuthentication(auth: auth)
        case .harness(let harness):
            await harness.cancelAuthentication(auth: auth)
        }
    }

    package func switchAccount(
        auth: CodexReviewAuthModel,
        accountKey: String
    ) async throws {
        switch mode {
        case .live(let live):
            try await live.authOrchestrator.switchAccount(
                auth: auth,
                accountKey: accountKey
            )
        case .harness(let harness):
            try await harness.switchAccount(
                auth: auth,
                accountKey: accountKey
            )
        }
    }

    package func removeAccount(
        auth: CodexReviewAuthModel,
        accountKey: String
    ) async throws {
        switch mode {
        case .live(let live):
            try await live.authOrchestrator.removeAccount(
                auth: auth,
                accountKey: accountKey
            )
        case .harness(let harness):
            try await harness.removeAccount(
                auth: auth,
                accountKey: accountKey
            )
        }
    }

    package func reorderPersistedAccount(
        auth: CodexReviewAuthModel,
        accountKey: String,
        toIndex: Int
    ) async throws {
        switch mode {
        case .live(let live):
            try await live.authOrchestrator.reorderPersistedAccount(
                auth: auth,
                accountKey: accountKey,
                toIndex: toIndex
            )
        case .harness(let harness):
            try await harness.reorderPersistedAccount(
                auth: auth,
                accountKey: accountKey,
                toIndex: toIndex
            )
        }
    }

    package func signOutActiveAccount(auth: CodexReviewAuthModel) async throws {
        switch mode {
        case .live(let live):
            try await live.authOrchestrator.signOutActiveAccount(auth: auth)
        case .harness(let harness):
            try await harness.signOutActiveAccount(auth: auth)
        }
    }

    package func refreshAccountRateLimits(
        auth: CodexReviewAuthModel,
        accountKey: String
    ) async {
        switch mode {
        case .live(let live):
            await live.authOrchestrator.refreshAccountRateLimits(
                auth: auth,
                accountKey: accountKey
            )
        case .harness(let harness):
            await harness.refreshAccountRateLimits(
                auth: auth,
                accountKey: accountKey
            )
        }
    }

    package func startStartupRefresh(auth: CodexReviewAuthModel) {
        switch mode {
        case .live(let live):
            live.authOrchestrator.startStartupRefresh(auth: auth)
        case .harness(let harness):
            harness.startStartupRefresh(auth: auth)
        }
    }

    package func cancelStartupRefresh() {
        switch mode {
        case .live(let live):
            live.authOrchestrator.cancelStartupRefresh()
        case .harness(let harness):
            harness.cancelStartupRefresh()
        }
    }

    package func reconcileAuthenticatedSession(
        auth: CodexReviewAuthModel,
        serverIsRunning: Bool,
        runtimeGeneration: Int
    ) async {
        switch mode {
        case .live(let live):
            await live.authOrchestrator.reconcileAuthenticatedSession(
                auth: auth,
                serverIsRunning: serverIsRunning,
                runtimeGeneration: runtimeGeneration
            )
        case .harness(let harness):
            await harness.reconcileAuthenticatedSession(
                auth: auth,
                serverIsRunning: serverIsRunning,
                runtimeGeneration: runtimeGeneration
            )
        }
    }

    package func requiresCurrentSessionRecovery(
        auth: CodexReviewAuthModel,
        accountKey: String
    ) -> Bool {
        switch mode {
        case .live(let live):
            live.authOrchestrator.requiresCurrentSessionRecovery(
                auth: auth,
                accountKey: accountKey
            )
        case .harness(let harness):
            harness.requiresCurrentSessionRecovery(
                auth: auth,
                accountKey: accountKey
            )
        }
    }

    package func startReview(
        sessionID: String,
        request: ReviewStartRequest,
        store: CodexReviewStore
    ) async throws -> ReviewReadResult {
        switch mode {
        case .live(let live):
            return try await live.executionCoordinator.startReview(
                sessionID: sessionID,
                request: request,
                store: store
            )
        case .harness(let harness):
            return try await harness.startReview(
                sessionID: sessionID,
                request: request,
                store: store
            )
        }
    }

    package func cancelReviewByID(
        jobID: String,
        sessionID: String,
        cancellation: ReviewCancellation,
        store: CodexReviewStore
    ) async throws -> ReviewCancelOutcome {
        switch mode {
        case .live(let live):
            return try await live.executionCoordinator.cancelReview(
                jobID: jobID,
                sessionID: sessionID,
                cancellation: cancellation,
                store: store
            )
        case .harness(let harness):
            return try await harness.cancelReviewByID(
                jobID: jobID,
                sessionID: sessionID,
                cancellation: cancellation,
                store: store
            )
        }
    }

    package func cancelReviewBySelector(
        selector: ReviewJobSelector,
        sessionID: String,
        cancellation: ReviewCancellation,
        store: CodexReviewStore
    ) async throws -> ReviewCancelOutcome {
        switch mode {
        case .live(let live):
            return try await live.executionCoordinator.cancelReview(
                selector: selector,
                sessionID: sessionID,
                cancellation: cancellation,
                store: store
            )
        case .harness(let harness):
            return try await harness.cancelReviewBySelector(
                selector: selector,
                sessionID: sessionID,
                cancellation: cancellation,
                store: store
            )
        }
    }

    package func closeSession(
        _ sessionID: String,
        reason: String,
        store: CodexReviewStore
    ) async {
        closedSessions.insert(sessionID)
        switch mode {
        case .live(let live):
            await live.executionCoordinator.closeSession(
                sessionID,
                reason: reason,
                store: store
            )
        case .harness(let harness):
            await harness.closeSession(sessionID, reason: reason, store: store)
        }
    }

    package func closeSessionState(_ sessionID: String) -> [String] {
        closedSessions.insert(sessionID)
        guard let attachedStore else {
            return []
        }
        return attachedStore.activeJobIDs(for: sessionID)
    }

    package func isSessionClosed(_ sessionID: String) -> Bool {
        closedSessions.contains(sessionID)
    }
}
