import Foundation
import Observation
import ReviewDomain
import ReviewInfra

@MainActor
package final class ReviewMonitorRuntime {
    package struct Seed {
        package var shouldAutoStartEmbeddedServer: Bool
        package var initialAccount: CodexAccount?
        package var initialAccounts: [CodexAccount]
        package var initialSettingsSnapshot: CodexReviewSettingsSnapshot

        package init(
            shouldAutoStartEmbeddedServer: Bool = false,
            initialAccount: CodexAccount? = nil,
            initialAccounts: [CodexAccount] = [],
            initialSettingsSnapshot: CodexReviewSettingsSnapshot = .init()
        ) {
            self.shouldAutoStartEmbeddedServer = shouldAutoStartEmbeddedServer
            self.initialAccount = initialAccount
            self.initialAccounts = initialAccounts
            self.initialSettingsSnapshot = initialSettingsSnapshot
        }
    }

    package struct Handlers {
        package var attachStore: @MainActor (CodexReviewStore) -> Void
        package var isActive: @MainActor () -> Bool
        package var start: @MainActor (CodexReviewStore, Bool) async -> Void
        package var stop: @MainActor (CodexReviewStore) async -> Void
        package var waitUntilStopped: @MainActor () async -> Void
        package var refreshSettings: @MainActor () async throws -> CodexReviewSettingsSnapshot
        package var updateSettingsModel: @MainActor (
            String?,
            CodexReviewReasoningEffort?,
            Bool,
            CodexReviewServiceTier?,
            Bool
        ) async throws -> Void
        package var updateSettingsReasoningEffort: @MainActor (CodexReviewReasoningEffort?) async throws -> Void
        package var updateSettingsServiceTier: @MainActor (CodexReviewServiceTier?) async throws -> Void
        package var startStartupRefresh: @MainActor (CodexReviewAuthModel) -> Void
        package var cancelStartupRefresh: @MainActor () -> Void
        package var refreshAuth: @MainActor (CodexReviewAuthModel) async -> Void
        package var signIn: @MainActor (CodexReviewAuthModel) async -> Void
        package var addAccount: @MainActor (CodexReviewAuthModel) async -> Void
        package var cancelAuthentication: @MainActor (CodexReviewAuthModel) async -> Void
        package var switchAccount: @MainActor (CodexReviewAuthModel, String) async throws -> Void
        package var removeAccount: @MainActor (CodexReviewAuthModel, String) async throws -> Void
        package var reorderSavedAccount: @MainActor (CodexReviewAuthModel, String, Int) async throws -> Void
        package var signOutActiveAccount: @MainActor (CodexReviewAuthModel) async throws -> Void
        package var refreshSavedAccountRateLimits: @MainActor (CodexReviewAuthModel, String) async -> Void
        package var reconcileAuthenticatedSession: @MainActor (CodexReviewAuthModel, Bool, Int) async -> Void
        package var requiresCurrentSessionRecovery: @MainActor (CodexReviewAuthModel, String) -> Bool
        package var startReview: @MainActor (String, ReviewStartRequest, CodexReviewStore) async throws -> ReviewReadResult
        package var cancelReviewByID: @MainActor (String, String, String, CodexReviewStore) async throws -> ReviewCancelOutcome
        package var cancelReviewBySelector: @MainActor (ReviewJobSelector, String, CodexReviewStore) async throws -> ReviewCancelOutcome
        package var closeSession: @MainActor (String, String, CodexReviewStore) async -> Void

        package init(
            attachStore: @escaping @MainActor (CodexReviewStore) -> Void,
            isActive: @escaping @MainActor () -> Bool,
            start: @escaping @MainActor (CodexReviewStore, Bool) async -> Void,
            stop: @escaping @MainActor (CodexReviewStore) async -> Void,
            waitUntilStopped: @escaping @MainActor () async -> Void,
            refreshSettings: @escaping @MainActor () async throws -> CodexReviewSettingsSnapshot,
            updateSettingsModel: @escaping @MainActor (
                String?,
                CodexReviewReasoningEffort?,
                Bool,
                CodexReviewServiceTier?,
                Bool
            ) async throws -> Void,
            updateSettingsReasoningEffort: @escaping @MainActor (CodexReviewReasoningEffort?) async throws -> Void,
            updateSettingsServiceTier: @escaping @MainActor (CodexReviewServiceTier?) async throws -> Void,
            startStartupRefresh: @escaping @MainActor (CodexReviewAuthModel) -> Void,
            cancelStartupRefresh: @escaping @MainActor () -> Void,
            refreshAuth: @escaping @MainActor (CodexReviewAuthModel) async -> Void,
            signIn: @escaping @MainActor (CodexReviewAuthModel) async -> Void,
            addAccount: @escaping @MainActor (CodexReviewAuthModel) async -> Void,
            cancelAuthentication: @escaping @MainActor (CodexReviewAuthModel) async -> Void,
            switchAccount: @escaping @MainActor (CodexReviewAuthModel, String) async throws -> Void,
            removeAccount: @escaping @MainActor (CodexReviewAuthModel, String) async throws -> Void,
            reorderSavedAccount: @escaping @MainActor (CodexReviewAuthModel, String, Int) async throws -> Void,
            signOutActiveAccount: @escaping @MainActor (CodexReviewAuthModel) async throws -> Void,
            refreshSavedAccountRateLimits: @escaping @MainActor (CodexReviewAuthModel, String) async -> Void,
            reconcileAuthenticatedSession: @escaping @MainActor (CodexReviewAuthModel, Bool, Int) async -> Void,
            requiresCurrentSessionRecovery: @escaping @MainActor (CodexReviewAuthModel, String) -> Bool,
            startReview: @escaping @MainActor (String, ReviewStartRequest, CodexReviewStore) async throws -> ReviewReadResult,
            cancelReviewByID: @escaping @MainActor (String, String, String, CodexReviewStore) async throws -> ReviewCancelOutcome,
            cancelReviewBySelector: @escaping @MainActor (ReviewJobSelector, String, CodexReviewStore) async throws -> ReviewCancelOutcome,
            closeSession: @escaping @MainActor (String, String, CodexReviewStore) async -> Void
        ) {
            self.attachStore = attachStore
            self.isActive = isActive
            self.start = start
            self.stop = stop
            self.waitUntilStopped = waitUntilStopped
            self.refreshSettings = refreshSettings
            self.updateSettingsModel = updateSettingsModel
            self.updateSettingsReasoningEffort = updateSettingsReasoningEffort
            self.updateSettingsServiceTier = updateSettingsServiceTier
            self.startStartupRefresh = startStartupRefresh
            self.cancelStartupRefresh = cancelStartupRefresh
            self.refreshAuth = refreshAuth
            self.signIn = signIn
            self.addAccount = addAccount
            self.cancelAuthentication = cancelAuthentication
            self.switchAccount = switchAccount
            self.removeAccount = removeAccount
            self.reorderSavedAccount = reorderSavedAccount
            self.signOutActiveAccount = signOutActiveAccount
            self.refreshSavedAccountRateLimits = refreshSavedAccountRateLimits
            self.reconcileAuthenticatedSession = reconcileAuthenticatedSession
            self.requiresCurrentSessionRecovery = requiresCurrentSessionRecovery
            self.startReview = startReview
            self.cancelReviewByID = cancelReviewByID
            self.cancelReviewBySelector = cancelReviewBySelector
            self.closeSession = closeSession
        }

        fileprivate init(previewState: PreviewState) {
            attachStore = { _ in }
            isActive = { previewState.isActive }
            start = { store, _ in
                previewState.isActive = true
                store.transitionToFailed(Self.previewUnavailableMessage)
            }
            stop = { _ in
                previewState.isActive = false
            }
            waitUntilStopped = {}
            refreshSettings = {
                previewState.settingsSnapshot
            }
            updateSettingsModel = { model, reasoningEffort, persistReasoningEffort, serviceTier, persistServiceTier in
                previewState.settingsSnapshot.model = model
                if persistReasoningEffort {
                    previewState.settingsSnapshot.reasoningEffort = reasoningEffort
                }
                if persistServiceTier {
                    previewState.settingsSnapshot.serviceTier = serviceTier
                }
            }
            updateSettingsReasoningEffort = { reasoningEffort in
                previewState.settingsSnapshot.reasoningEffort = reasoningEffort
            }
            updateSettingsServiceTier = { serviceTier in
                previewState.settingsSnapshot.serviceTier = serviceTier
            }
            startStartupRefresh = { auth in
                if auth.account == nil {
                    auth.updatePhase(.signedOut)
                }
            }
            cancelStartupRefresh = {}
            refreshAuth = { auth in
                if auth.account == nil {
                    auth.updatePhase(.signedOut)
                }
            }
            signIn = { auth in
                auth.updatePhase(.failed(message: Self.previewAuthenticationFailureMessage))
            }
            addAccount = { auth in
                auth.updatePhase(.failed(message: Self.previewAuthenticationFailureMessage))
            }
            cancelAuthentication = { auth in
                if auth.account == nil {
                    auth.updatePhase(.signedOut)
                }
            }
            switchAccount = { auth, accountKey in
                guard let target = auth.savedAccounts.first(where: { $0.accountKey == accountKey }) else {
                    return
                }
                for account in auth.savedAccounts {
                    account.updateIsActive(account.accountKey == accountKey)
                }
                auth.updateAccount(target)
                auth.updatePhase(.signedOut)
            }
            removeAccount = { auth, accountKey in
                let filtered = auth.savedAccounts.filter { $0.accountKey != accountKey }
                auth.updateSavedAccounts(filtered)
                if auth.account?.accountKey == accountKey {
                    auth.updateAccount(nil)
                    auth.updatePhase(.signedOut)
                }
            }
            reorderSavedAccount = { auth, accountKey, toIndex in
                var reorderedAccounts = auth.savedAccounts
                guard let sourceIndex = reorderedAccounts.firstIndex(where: { $0.accountKey == accountKey }) else {
                    return
                }
                let destinationIndex = max(0, min(toIndex, reorderedAccounts.count - 1))
                guard sourceIndex != destinationIndex else {
                    return
                }
                let account = reorderedAccounts.remove(at: sourceIndex)
                reorderedAccounts.insert(account, at: destinationIndex)
                auth.updateSavedAccounts(reorderedAccounts)
            }
            signOutActiveAccount = { auth in
                auth.updatePhase(.signedOut)
                auth.updateAccount(nil)
                auth.updateSavedAccounts([])
            }
            refreshSavedAccountRateLimits = { _, _ in }
            reconcileAuthenticatedSession = { _, _, _ in }
            requiresCurrentSessionRecovery = { _, _ in false }
            startReview = { _, _, _ in
                throw ReviewError.io("CodexReviewStore live runtime is unavailable.")
            }
            cancelReviewByID = { jobID, sessionID, reason, store in
                let job = try store.resolveJob(jobID: jobID, sessionID: sessionID)
                try store.completeCancellationLocally(
                    jobID: job.id,
                    sessionID: sessionID,
                    reason: reason
                )
                return .init(
                    jobID: job.id,
                    threadID: job.threadID,
                    cancelled: true,
                    status: .cancelled
                )
            }
            cancelReviewBySelector = { selector, sessionID, store in
                let job = try store.resolveJob(sessionID: sessionID, selector: selector)
                try store.completeCancellationLocally(
                    jobID: job.id,
                    sessionID: sessionID,
                    reason: "Cancellation requested."
                )
                return .init(
                    jobID: job.id,
                    threadID: job.threadID,
                    cancelled: true,
                    status: .cancelled
                )
            }
            closeSession = { _, _, _ in }
        }

        fileprivate static let previewUnavailableMessage = "Embedded server is unavailable in preview mode."
        fileprivate static let previewAuthenticationFailureMessage = "Authentication is unavailable in preview mode."
    }

    @MainActor
    fileprivate final class PreviewState {
        var isActive = false
        var settingsSnapshot: CodexReviewSettingsSnapshot

        init(seed: Seed) {
            settingsSnapshot = seed.initialSettingsSnapshot
        }
    }

    package let shouldAutoStartEmbeddedServer: Bool
    package let initialAccount: CodexAccount?
    package let initialAccounts: [CodexAccount]
    package let initialSettingsSnapshot: CodexReviewSettingsSnapshot

    @ObservationIgnored
    private let handlers: Handlers
    @ObservationIgnored
    private weak var attachedStore: CodexReviewStore?

    package private(set) var closedSessions: Set<String> = []

    package init(
        seed: Seed,
        handlers: Handlers
    ) {
        shouldAutoStartEmbeddedServer = seed.shouldAutoStartEmbeddedServer
        initialAccount = seed.initialAccount
        initialAccounts = seed.initialAccounts
        initialSettingsSnapshot = seed.initialSettingsSnapshot
        self.handlers = handlers
    }

    package static func preview(seed: Seed = .init()) -> ReviewMonitorRuntime {
        let previewState = PreviewState(seed: seed)
        return .init(
            seed: seed,
            handlers: .init(previewState: previewState)
        )
    }

    package static func testing(
        seed: Seed = .init(),
        customize: (inout Handlers) -> Void
    ) -> ReviewMonitorRuntime {
        let previewState = PreviewState(seed: seed)
        var handlers = Handlers(previewState: previewState)
        customize(&handlers)
        return .init(seed: seed, handlers: handlers)
    }

    package var isActive: Bool {
        handlers.isActive()
    }

    package func attachStore(_ store: CodexReviewStore) {
        attachedStore = store
        handlers.attachStore(store)
    }

    package func start(
        store: CodexReviewStore,
        forceRestartIfNeeded: Bool
    ) async {
        closedSessions = []
        await handlers.start(store, forceRestartIfNeeded)
    }

    package func stop(store: CodexReviewStore) async {
        await handlers.stop(store)
        closedSessions = []
    }

    package func waitUntilStopped() async {
        await handlers.waitUntilStopped()
    }

    package func refreshSettings() async throws -> CodexReviewSettingsSnapshot {
        try await handlers.refreshSettings()
    }

    package func updateSettingsModel(
        _ model: String?,
        reasoningEffort: CodexReviewReasoningEffort?,
        persistReasoningEffort: Bool,
        serviceTier: CodexReviewServiceTier?,
        persistServiceTier: Bool
    ) async throws {
        try await handlers.updateSettingsModel(
            model,
            reasoningEffort,
            persistReasoningEffort,
            serviceTier,
            persistServiceTier
        )
    }

    package func updateSettingsReasoningEffort(
        _ reasoningEffort: CodexReviewReasoningEffort?
    ) async throws {
        try await handlers.updateSettingsReasoningEffort(reasoningEffort)
    }

    package func updateSettingsServiceTier(
        _ serviceTier: CodexReviewServiceTier?
    ) async throws {
        try await handlers.updateSettingsServiceTier(serviceTier)
    }

    package func startStartupRefresh(auth: CodexReviewAuthModel) {
        handlers.startStartupRefresh(auth)
    }

    package func cancelStartupRefresh() {
        handlers.cancelStartupRefresh()
    }

    package func refreshAuth(auth: CodexReviewAuthModel) async {
        await handlers.refreshAuth(auth)
    }

    package func signIn(auth: CodexReviewAuthModel) async {
        await handlers.signIn(auth)
    }

    package func addAccount(auth: CodexReviewAuthModel) async {
        await handlers.addAccount(auth)
    }

    package func cancelAuthentication(auth: CodexReviewAuthModel) async {
        await handlers.cancelAuthentication(auth)
    }

    package func switchAccount(
        auth: CodexReviewAuthModel,
        accountKey: String
    ) async throws {
        try await handlers.switchAccount(auth, accountKey)
    }

    package func removeAccount(
        auth: CodexReviewAuthModel,
        accountKey: String
    ) async throws {
        try await handlers.removeAccount(auth, accountKey)
    }

    package func reorderSavedAccount(
        auth: CodexReviewAuthModel,
        accountKey: String,
        toIndex: Int
    ) async throws {
        try await handlers.reorderSavedAccount(auth, accountKey, toIndex)
    }

    package func signOutActiveAccount(auth: CodexReviewAuthModel) async throws {
        try await handlers.signOutActiveAccount(auth)
    }

    package func refreshSavedAccountRateLimits(
        auth: CodexReviewAuthModel,
        accountKey: String
    ) async {
        await handlers.refreshSavedAccountRateLimits(auth, accountKey)
    }

    package func reconcileAuthenticatedSession(
        auth: CodexReviewAuthModel,
        serverIsRunning: Bool,
        runtimeGeneration: Int
    ) async {
        await handlers.reconcileAuthenticatedSession(
            auth,
            serverIsRunning,
            runtimeGeneration
        )
    }

    package func requiresCurrentSessionRecovery(
        auth: CodexReviewAuthModel,
        accountKey: String
    ) -> Bool {
        handlers.requiresCurrentSessionRecovery(auth, accountKey)
    }

    package func startReview(
        sessionID: String,
        request: ReviewStartRequest,
        store: CodexReviewStore
    ) async throws -> ReviewReadResult {
        try await handlers.startReview(sessionID, request, store)
    }

    package func cancelReviewByID(
        jobID: String,
        sessionID: String,
        reason: String,
        store: CodexReviewStore
    ) async throws -> ReviewCancelOutcome {
        try await handlers.cancelReviewByID(jobID, sessionID, reason, store)
    }

    package func cancelReviewBySelector(
        selector: ReviewJobSelector,
        sessionID: String,
        store: CodexReviewStore
    ) async throws -> ReviewCancelOutcome {
        try await handlers.cancelReviewBySelector(selector, sessionID, store)
    }

    package func closeSession(
        _ sessionID: String,
        reason: String,
        store: CodexReviewStore
    ) async {
        closedSessions.insert(sessionID)
        await handlers.closeSession(sessionID, reason, store)
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
