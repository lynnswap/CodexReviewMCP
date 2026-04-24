import Foundation
import ReviewDomain
import ReviewInfra

@MainActor
package struct CodexAuthRuntimeState {
    var serverIsRunning: Bool
    var runtimeGeneration: Int

    static let stopped = Self(
        serverIsRunning: false,
        runtimeGeneration: 0
    )
}

@MainActor
package enum CodexAuthRuntimeEffect {
    case none
    case recycleNow(accountKey: String, runtimeGeneration: Int)
    case deferRecycleUntilJobsDrain(accountKey: String, runtimeGeneration: Int)
}

@MainActor
package class ReviewMonitorAuthRuntimeDriver {
    package var applyAddAccountRuntimeEffectHandler: (@MainActor @Sendable (
        CodexAuthRuntimeEffect,
        CodexReviewAuthModel
    ) async -> Void)?
    package var cancelRunningJobsHandler: (@MainActor @Sendable (String) async throws -> Void)?

    package init() {}

    package func runtimeState() -> CodexAuthRuntimeState {
        .stopped
    }

    package func recycleServerIfRunning() async {}

    package func resolveAddAccountRuntimeEffect(
        accountKey: String,
        runtimeGeneration: Int
    ) -> CodexAuthRuntimeEffect {
        .recycleNow(accountKey: accountKey, runtimeGeneration: runtimeGeneration)
    }
}

@MainActor
package final class ReviewMonitorAuthOrchestrator {
    package enum RuntimeBridge {
        case live(ReviewMonitorServerRuntime)
        case testing(ReviewMonitorAuthRuntimeDriver)
    }

    private enum AuthenticationIntent {
        case signIn
        case addAccount
    }

    private enum AuthenticationPresentationEffect {
        case activateCommittedAccount(forceRecycleServer: Bool)
        case preserveCurrentSession

        var activatesCommittedAccount: Bool {
            switch self {
            case .activateCommittedAccount:
                true
            case .preserveCurrentSession:
                false
            }
        }

        var forceRecycleServer: Bool {
            switch self {
            case .activateCommittedAccount(let forceRecycleServer):
                forceRecycleServer
            case .preserveCurrentSession:
                false
            }
        }
    }

    private enum SharedAuthUpdate {
        case none
        case refreshCurrentAccountSnapshot

        var shouldRefreshSharedAuthSnapshot: Bool {
            switch self {
            case .none:
                false
            case .refreshCurrentAccountSnapshot:
                true
            }
        }
    }

    private struct AuthCommitOutcome {
        var presentationEffect: AuthenticationPresentationEffect
        var sharedAuthUpdate: SharedAuthUpdate
        var runtimeEffect: CodexAuthRuntimeEffect
        var shouldMarkCommittedSavedAccountActive: Bool
        var shouldCancelRunningJobs: Bool
    }

    private let configuration: ReviewServerConfiguration
    private let accountRegistryStore: ReviewAccountRegistryStore
    private let sharedAuthSessionFactory: @Sendable ([String: String]) async throws -> any ReviewAuthSession
    private let loginAuthSessionFactory: @Sendable ([String: String]) async throws -> any ReviewAuthSession
    private let probeAppServerManagerFactory: @Sendable ([String: String]) -> any AppServerManaging
    private let accountSessionController: ActiveAccountRateLimitObserver
    private let inactiveAccountRateLimitController: InactiveSavedAccountRateLimitScheduler
    private let runtimeBridge: RuntimeBridge
    private var refreshTask: Task<Void, Never>?
    private var refreshTaskID: UUID?
    private var authenticationCancellationRestoreState: AuthPresentationSnapshot?
    private var activeAuthenticationAttemptID: UUID?
    private var activeAuthenticationManager: ReviewAuthManager?
    private var activeAuthenticationProbe: PreparedInactiveAccountProbe?
    private var hasResolvedAuthenticatedAccount = false

    init(
        configuration: ReviewServerConfiguration,
        accountRegistryStore: ReviewAccountRegistryStore,
        appServerManager: any AppServerManaging,
        sharedAuthSessionFactory: @escaping @Sendable ([String: String]) async throws -> any ReviewAuthSession,
        loginAuthSessionFactory: @escaping @Sendable ([String: String]) async throws -> any ReviewAuthSession,
        probeAppServerManagerFactory: (@Sendable ([String: String]) -> any AppServerManaging)? = nil,
        runtimeBridge: RuntimeBridge,
        rateLimitObservationClock: any ReviewClock = ContinuousClock(),
        rateLimitStaleRefreshInterval: Duration = .seconds(60),
        inactiveRateLimitRefreshInterval: Duration = .seconds(15 * 60)
    ) {
        self.configuration = configuration
        self.accountRegistryStore = accountRegistryStore
        self.sharedAuthSessionFactory = sharedAuthSessionFactory
        self.loginAuthSessionFactory = loginAuthSessionFactory
        let codexCommand = configuration.codexCommand
        self.probeAppServerManagerFactory = probeAppServerManagerFactory ?? { environment in
            AppServerSupervisor(
                configuration: .init(
                    codexCommand: codexCommand,
                    environment: environment
                )
            )
        }
        accountSessionController = ActiveAccountRateLimitObserver(
            appServerManager: appServerManager,
            accountRegistryStore: accountRegistryStore,
            clock: rateLimitObservationClock,
            staleRefreshInterval: rateLimitStaleRefreshInterval
        )
        inactiveAccountRateLimitController = InactiveSavedAccountRateLimitScheduler(
            clock: rateLimitObservationClock,
            refreshInterval: inactiveRateLimitRefreshInterval
        )
        self.runtimeBridge = runtimeBridge
    }

    private func runtimeState() -> CodexAuthRuntimeState {
        switch runtimeBridge {
        case .live(let serverRuntime):
            serverRuntime.authRuntimeState
        case .testing(let runtimeDriver):
            runtimeDriver.runtimeState()
        }
    }

    private func recycleServerIfRunning() async {
        switch runtimeBridge {
        case .live(let serverRuntime):
            await serverRuntime.recycleSharedAppServerAfterAuthChange()
        case .testing(let runtimeDriver):
            await runtimeDriver.recycleServerIfRunning()
        }
    }

    private func resolveAddAccountRuntimeEffect(
        accountKey: String,
        runtimeGeneration: Int
    ) -> CodexAuthRuntimeEffect {
        switch runtimeBridge {
        case .live(let serverRuntime):
            serverRuntime.resolveAddAccountRuntimeEffect(
                accountKey: accountKey,
                runtimeGeneration: runtimeGeneration
            )
        case .testing(let runtimeDriver):
            runtimeDriver.resolveAddAccountRuntimeEffect(
                accountKey: accountKey,
                runtimeGeneration: runtimeGeneration
            )
        }
    }

    private func applyAddAccountRuntimeEffect(
        _ effect: CodexAuthRuntimeEffect,
        auth: CodexReviewAuthModel
    ) async {
        switch runtimeBridge {
        case .live(let serverRuntime):
            await serverRuntime.applyAddAccountRuntimeEffect(effect, auth: auth)
        case .testing(let runtimeDriver):
            if let applyAddAccountRuntimeEffectHandler = runtimeDriver.applyAddAccountRuntimeEffectHandler {
                await applyAddAccountRuntimeEffectHandler(effect, auth)
            }
        }
    }

    private func cancelRunningJobs(reason: String) async throws {
        switch runtimeBridge {
        case .live(let serverRuntime):
            try await serverRuntime.cancelRunningJobs(reason: reason)
        case .testing(let runtimeDriver):
            if let cancelRunningJobsHandler = runtimeDriver.cancelRunningJobsHandler {
                try await cancelRunningJobsHandler(reason)
            }
        }
    }

    package func startStartupRefresh(auth: CodexReviewAuthModel) {
        cancelStartupRefresh()
        let refreshID = UUID()
        refreshTaskID = refreshID
        refreshTask = Task { @MainActor [weak self, weak auth] in
            guard let self, let auth else {
                return
            }
            await self.refreshResolvedState(auth: auth)
            if self.refreshTaskID == refreshID {
                self.refreshTask = nil
                self.refreshTaskID = nil
            }
        }
    }

    package func cancelStartupRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
        refreshTaskID = nil
    }

    package func refresh(auth: CodexReviewAuthModel) async {
        cancelStartupRefresh()
        await refreshResolvedState(auth: auth)
    }

    package func signIn(auth: CodexReviewAuthModel) async {
        await performAuthentication(
            auth: auth,
            intent: .signIn
        )
    }

    package func addAccount(auth: CodexReviewAuthModel) async {
        await performAuthentication(
            auth: auth,
            intent: .addAccount
        )
    }

    private func performAuthentication(
        auth: CodexReviewAuthModel,
        intent: AuthenticationIntent
    ) async {
        cancelStartupRefresh()
        guard auth.isAuthenticating == false else {
            return
        }
        let priorSnapshot = snapshot(
            from: auth,
            isResolvedAuthenticated: hasResolvedAuthenticatedAccount
        )
        let authenticationAttemptID = UUID()
        activeAuthenticationAttemptID = authenticationAttemptID
        authenticationCancellationRestoreState = priorSnapshot
        defer {
            cleanupAuthenticationAttemptIfCurrent(authenticationAttemptID)
        }

        do {
            let loginProbe = try await accountRegistryStore.prepareAuthenticationLoginProbe()
            do {
                try ensureAuthenticationAttemptIsCurrent(authenticationAttemptID)
            } catch {
                await accountRegistryStore.cleanupProbeHome(loginProbe)
                throw error
            }
            activeAuthenticationProbe = loginProbe
            let authManager = makeAuthManager(
                environment: loginProbe.environment,
                sessionFactory: loginAuthSessionFactory
            )
            activeAuthenticationManager = authManager
            var completedAccount: ReviewAuthAccount?
            try await authManager.beginAuthentication { state in
                await MainActor.run {
                    if case .signedIn(let account) = state {
                        completedAccount = account
                    }
                    self.applyAuthenticationProgressState(state, to: auth)
                }
            }
            try ensureAuthenticationAttemptIsCurrent(authenticationAttemptID)
            guard let completedAccount else {
                throw ReviewAuthError.loginFailed(reviewAuthPersistenceFailureMessage)
            }
            let priorCurrentAccount = auth.selectedAccount
            let commitOutcome = makeAuthenticationCommitOutcome(
                intent: intent,
                priorSnapshot: priorSnapshot,
                priorCurrentAccount: priorCurrentAccount,
                completedAccount: completedAccount
            )
            guard let commitProbe = takeAuthenticationProbeForCommit(authenticationAttemptID) else {
                throw ReviewAuthError.cancelled
            }
            auth.updatePhase(.signedOut)
            defer {
                Task {
                    await self.accountRegistryStore.cleanupProbeHome(commitProbe)
                }
            }

            let savedAccount: CodexSavedAccountPayload
            do {
                savedAccount = try accountRegistryStore.saveAuthSnapshot(
                    sourceAuthURL: ReviewHomePaths.reviewAuthURL(environment: commitProbe.environment),
                    makeActive: commitOutcome.presentationEffect.activatesCommittedAccount
                        || commitOutcome.shouldMarkCommittedSavedAccountActive,
                    refreshSharedAuth: commitOutcome.sharedAuthUpdate.shouldRefreshSharedAuthSnapshot
                )
            } catch {
                throw ReviewAuthError.loginFailed(reviewAuthPersistenceFailureMessage)
            }

            if commitOutcome.presentationEffect.activatesCommittedAccount {
                let warningMessage = await performCommittedJobCleanupIfNeeded(
                    shouldCancelJobs: commitOutcome.shouldCancelRunningJobs
                )
                await applyCommittedActiveAccount(
                    auth: auth,
                    savedAccountKey: savedAccount.accountKey,
                    priorAccount: priorCurrentAccount,
                    forceRecycleServer: commitOutcome.presentationEffect.forceRecycleServer
                )
                if let warningMessage {
                    auth.updateWarning(message: warningMessage)
                }
                return
            }

            await refreshSavedAccounts(auth: auth)
            switch commitOutcome.runtimeEffect {
            case .none:
                await refreshSavedAccountRateLimits(auth: auth, accountKey: savedAccount.accountKey)
            case .recycleNow, .deferRecycleUntilJobsDrain:
                break
            }
            restoreNonActivatingAccountAdditionState(
                auth: auth,
                priorCurrentAccount: priorCurrentAccount
            )
            if commitOutcome.sharedAuthUpdate.shouldRefreshSharedAuthSnapshot,
               runtimeState().serverIsRunning == false,
               auth.selectedAccount != nil,
               didAccountIdentityChange(from: priorCurrentAccount, to: auth.selectedAccount) == false
            {
                accountSessionController.resetAuthenticationRequiredCapabilityForAuthRecovery()
            }
            auth.updatePhase(.signedOut)
            auth.updateWarning(message: nil)
            hasResolvedAuthenticatedAccount = auth.selectedAccount != nil
            await reconcileAfterResolvedAuthState(
                auth: auth,
                identityChanged: false
            )
            await applyAddAccountRuntimeEffect(
                commitOutcome.runtimeEffect,
                auth: auth
            )
            if case .recycleNow = commitOutcome.runtimeEffect {
                await refreshSavedAccountRateLimits(auth: auth, accountKey: savedAccount.accountKey)
            }
        } catch ReviewAuthError.cancelled {
            if let restoreState = authenticationCancellationRestoreState {
                hasResolvedAuthenticatedAccount = restoreState.isResolvedAuthenticated
                restore(auth: auth, from: restoreState)
            }
            await reconcileAfterResolvedAuthState(
                auth: auth,
                identityChanged: false
            )
        } catch {
            auth.updateWarning(message: nil)
            updateAuthenticationFailureState(error, auth: auth)
            await reconcileAfterResolvedAuthState(
                auth: auth,
                identityChanged: false
            )
        }
    }

    package func cancelAuthentication(auth: CodexReviewAuthModel) async {
        guard activeAuthenticationAttemptID != nil
            || activeAuthenticationManager != nil
            || authenticationCancellationRestoreState != nil
        else {
            return
        }
        let restoreState = authenticationCancellationRestoreState ?? snapshot(
            from: auth,
            isResolvedAuthenticated: hasResolvedAuthenticatedAccount
        )
        let authenticationManager = activeAuthenticationManager
        let authenticationProbe = activeAuthenticationProbe
        activeAuthenticationAttemptID = nil
        authenticationCancellationRestoreState = nil
        activeAuthenticationManager = nil
        activeAuthenticationProbe = nil
        await authenticationManager?.cancelAuthentication()
        hasResolvedAuthenticatedAccount = restoreState.isResolvedAuthenticated
        restore(auth: auth, from: restoreState)
        auth.updateWarning(message: restoreState.warningMessage)
        await reconcileAfterResolvedAuthState(
            auth: auth,
            identityChanged: false
        )
        if let authenticationProbe {
            await accountRegistryStore.cleanupProbeHome(authenticationProbe)
        }
    }

    package func switchAccount(
        auth: CodexReviewAuthModel,
        accountKey: String
    ) async throws {
        cancelStartupRefresh()
        auth.updateWarning(message: nil)
        if auth.isAuthenticating {
            await cancelAuthentication(auth: auth)
        }
        let loadedAccounts = try accountRegistryStore.loadAccounts()
        guard loadedAccounts.accounts.contains(where: { $0.accountKey == accountKey }) else {
            throw ReviewAuthError.authenticationRequired("Saved account was not found.")
        }
        let targetSavedAccount = loadedAccounts.accounts.first(where: { $0.accountKey == accountKey })
        let priorAccount = auth.selectedAccount
        let isCurrentSessionTarget = priorAccount?.accountKey == accountKey
        let isPersistedActiveTarget = loadedAccounts.activeAccountKey == accountKey
        let shouldRecoverCurrentSessionFromSavedSnapshot =
            isCurrentSessionTarget && accountSessionController.requiresAuthenticationRecoveryForCurrentSession()
        let shouldHydratePersistedActiveTarget =
            isPersistedActiveTarget && isCurrentSessionTarget == false
        if shouldRecoverCurrentSessionFromSavedSnapshot || shouldHydratePersistedActiveTarget {
            try await accountRegistryStore.restoreSharedAuthFromSavedAccount(accountKey)
        } else if isCurrentSessionTarget == false && isPersistedActiveTarget == false {
            try await accountRegistryStore.activateAccount(accountKey)
        }
        if shouldRecoverCurrentSessionFromSavedSnapshot || shouldHydratePersistedActiveTarget {
            let warningMessage = await performCommittedJobCleanupIfNeeded(shouldCancelJobs: true)
            if runtimeState().serverIsRunning {
                await applyCommittedActiveAccount(
                    auth: auth,
                    savedAccountKey: targetSavedAccount?.accountKey,
                    priorAccount: priorAccount,
                    forceRecycleServer: true
                )
            } else {
                await refreshResolvedState(auth: auth)
            }
            if let warningMessage {
                auth.updateWarning(message: warningMessage)
            }
            return
        }
        if isCurrentSessionTarget {
            if isPersistedActiveTarget == false {
                try accountRegistryStore.saveSharedAuthAsSavedAccount(makeActive: true)
            }
            await refreshSavedAccounts(auth: auth)
            if auth.savedAccounts.contains(where: { $0.accountKey == accountKey }) {
                auth.updateSelectedAccount(
                    auth.savedAccounts.first(where: { $0.accountKey == accountKey })?.id
                )
            }
            accountSessionController.resetAuthenticationRequiredCapabilityForAuthRecovery()
            auth.updatePhase(.signedOut)
            auth.updateWarning(message: nil)
            hasResolvedAuthenticatedAccount = auth.selectedAccount != nil
            await reconcileAfterResolvedAuthState(
                auth: auth,
                identityChanged: false,
                forceRestartSession: runtimeState().serverIsRunning
            )
            return
        }
        let warningMessage = await performCommittedJobCleanupIfNeeded(shouldCancelJobs: true)
        if runtimeState().serverIsRunning {
            await applyCommittedActiveAccount(
                auth: auth,
                savedAccountKey: targetSavedAccount?.accountKey,
                priorAccount: priorAccount,
                forceRecycleServer: true
            )
        } else {
            await refreshResolvedState(auth: auth)
        }
        if let warningMessage {
            auth.updateWarning(message: warningMessage)
        }
    }

    package func removeAccount(
        auth: CodexReviewAuthModel,
        accountKey: String
    ) async throws {
        cancelStartupRefresh()
        auth.updateWarning(message: nil)
        if auth.isAuthenticating {
            await cancelAuthentication(auth: auth)
        }
        let priorAccount = auth.selectedAccount
        let removedCurrentSession = priorAccount?.accountKey == accountKey
        let startedWithoutCurrentSession = priorAccount == nil
        try await accountRegistryStore.removeAccount(accountKey)
        var replacementSavedAccount: CodexAccount?
        if let loaded = try? accountRegistryStore.loadAccounts() {
            auth.applySavedAccountStates(
                loaded.accounts,
                activeAccountKey: loaded.activeAccountKey
            )
            if let priorAccount,
               auth.savedAccounts.contains(where: { $0.accountKey == priorAccount.accountKey })
            {
                auth.updateSelectedAccount(
                    auth.savedAccounts.first(where: { $0.accountKey == priorAccount.accountKey })?.id
                )
                replacementSavedAccount = auth.selectedAccount
            } else if startedWithoutCurrentSession {
                auth.updateSelectedAccount(nil)
            } else if removedCurrentSession {
                if let activeAccountKey = loaded.activeAccountKey,
                   auth.savedAccounts.contains(where: { $0.accountKey == activeAccountKey })
                {
                    auth.updateSelectedAccount(
                        auth.savedAccounts.first(where: { $0.accountKey == activeAccountKey })?.id
                    )
                    replacementSavedAccount = auth.selectedAccount
                } else {
                    auth.updateSelectedAccount(nil)
                }
            } else if let priorAccount {
                auth.updateDetachedAccount(priorAccount)
            } else {
                auth.updateSelectedAccount(nil)
            }
        }
        if removedCurrentSession {
            if let replacementSavedAccount {
                try? await accountRegistryStore.restoreSharedAuthFromSavedAccount(
                    replacementSavedAccount.accountKey
                )
            } else {
                try? FileManager.default.removeItem(
                    at: ReviewHomePaths.reviewAuthURL(environment: configuration.environment)
                )
            }
            auth.updatePhase(.signedOut)
            hasResolvedAuthenticatedAccount = replacementSavedAccount != nil
            let warningMessage = await performCommittedJobCleanupIfNeeded(shouldCancelJobs: true)
            await reconcileAfterResolvedAuthState(
                auth: auth,
                identityChanged: didAccountIdentityChange(from: priorAccount, to: auth.selectedAccount),
                forceRestartSession: true,
                forceRecycleServer: runtimeState().serverIsRunning
            )
            if let warningMessage {
                auth.updateWarning(message: warningMessage)
            }
        } else {
            auth.updateWarning(message: nil)
            let resolvedRuntimeState = runtimeState()
            await reconcileRateLimitControllers(
                auth: auth,
                serverIsRunning: resolvedRuntimeState.serverIsRunning,
                runtimeGeneration: resolvedRuntimeState.runtimeGeneration
            )
        }
    }

    package func reorderSavedAccount(
        auth: CodexReviewAuthModel,
        accountKey: String,
        toIndex: Int
    ) async throws {
        try await accountRegistryStore.reorderAccount(
            accountKey: accountKey,
            toIndex: toIndex
        )
        await refreshSavedAccounts(auth: auth)
        let resolvedRuntimeState = runtimeState()
        await reconcileRateLimitControllers(
            auth: auth,
            serverIsRunning: resolvedRuntimeState.serverIsRunning,
            runtimeGeneration: resolvedRuntimeState.runtimeGeneration
        )
    }

    package func signOutActiveAccount(auth: CodexReviewAuthModel) async throws {
        guard auth.selectedAccount != nil else {
            return
        }
        cancelStartupRefresh()
        auth.updateWarning(message: nil)
        if auth.isAuthenticating {
            await cancelAuthentication(auth: auth)
        }
        var didCompleteLogout = false
        let signedOutAccount = auth.selectedAccount
        let removesSavedSignedOutAccount = signedOutAccount.map { signedOutAccount in
            persistedActiveAccountKey() == signedOutAccount.accountKey
        } ?? false
        do {
            let authManager = makeAuthManager(
                environment: configuration.environment,
                sessionFactory: sharedAuthSessionFactory
            )
            try await authManager.logout()
            didCompleteLogout = true
            if let signedOutAccountKey = signedOutAccount?.accountKey, removesSavedSignedOutAccount {
                try await accountRegistryStore.clearActiveAccount(accountKey: signedOutAccountKey)
            } else {
                let sharedAuthURL = ReviewHomePaths.reviewAuthURL(environment: configuration.environment)
                if FileManager.default.fileExists(atPath: sharedAuthURL.path) {
                    try FileManager.default.removeItem(at: sharedAuthURL)
                }
            }
            if let loaded = try? accountRegistryStore.loadAccounts() {
                auth.applySavedAccountStates(
                    loaded.accounts,
                    activeAccountKey: loaded.activeAccountKey
                )
            } else {
                auth.applySavedAccountStates([], activeAccountKey: nil)
            }
            auth.updateSelectedAccount(nil)
            auth.updatePhase(.signedOut)
            auth.updateWarning(message: nil)
            hasResolvedAuthenticatedAccount = false
            let warningMessage = await performCommittedJobCleanupIfNeeded(shouldCancelJobs: true)
            await reconcileAfterResolvedAuthState(
                auth: auth,
                identityChanged: true,
                forceRestartSession: true,
                forceRecycleServer: true
            )
            if let warningMessage {
                auth.updateWarning(message: warningMessage)
            }
        } catch let error as ReviewAuthError {
            let message = error.errorDescription ?? "Failed to sign out."
            await resolveLogoutFailureState(
                auth: auth,
                priorAccount: signedOutAccount,
                message: message,
                logoutCompleted: didCompleteLogout,
                removesSavedSignedOutAccount: removesSavedSignedOutAccount
            )
            if auth.isAuthenticated == false, auth.errorMessage == nil {
                if let warningMessage = await performCommittedJobCleanupIfNeeded(shouldCancelJobs: true) {
                    auth.updateWarning(message: warningMessage)
                }
                return
            }
            if auth.isAuthenticated || auth.errorMessage != nil {
                throw error
            }
        } catch {
            let message = error.localizedDescription
            await resolveLogoutFailureState(
                auth: auth,
                priorAccount: signedOutAccount,
                message: message,
                logoutCompleted: didCompleteLogout,
                removesSavedSignedOutAccount: removesSavedSignedOutAccount
            )
            if auth.isAuthenticated == false, auth.errorMessage == nil {
                if let warningMessage = await performCommittedJobCleanupIfNeeded(shouldCancelJobs: true) {
                    auth.updateWarning(message: warningMessage)
                }
                return
            }
            if auth.isAuthenticated || auth.errorMessage != nil {
                throw error
            }
        }
    }

    package func refreshSavedAccountRateLimits(
        auth: CodexReviewAuthModel,
        accountKey: String
    ) async {
        let isActiveAccount = auth.selectedAccount?.accountKey == accountKey
        if isActiveAccount,
           auth.selectedAccount != nil
        {
            let activeAccountKey = accountKey
            let applyActiveRateLimitRefreshSuccess: (AppServerAccountRateLimitsResponse) async -> Void = { [self] response in
                for resolvedAccount in resolvedAccounts(for: accountKey, in: auth) {
                    applyRateLimits(from: response, to: resolvedAccount)
                }
                try? await self.accountRegistryStore.updateCachedRateLimits(
                    accountKey: accountKey,
                    rateLimits: rateLimitWindowRecords(from: resolvedCodexSnapshot(from: response)),
                    fetchedAt: Date(),
                    error: nil
                )
            }
            let applyActiveRateLimitRefreshFailure: (Date, String, Bool) async -> Void = { [self] fetchedAt, message, shouldClear in
                for resolvedAccount in resolvedAccounts(for: accountKey, in: auth) {
                    resolvedAccount.updateRateLimitFetchMetadata(
                        fetchedAt: fetchedAt,
                        error: message
                    )
                    if shouldClear {
                        resolvedAccount.clearRateLimits()
                    }
                }
                if shouldClear {
                    try? await self.accountRegistryStore.updateCachedRateLimits(
                        accountKey: accountKey,
                        rateLimits: [],
                        fetchedAt: fetchedAt,
                        error: message
                    )
                } else {
                    try? await self.accountRegistryStore.updateRateLimitFetchStatus(
                        accountKey: accountKey,
                        fetchedAt: fetchedAt,
                        error: message
                    )
                }
            }
            if runtimeState().serverIsRunning {
                do {
                    let transport = try await accountSessionController.checkoutActiveRateLimitTransport()
                    let sharedSession = SharedAppServerReviewAuthSession(transport: transport)
                    defer {
                        Task {
                            await sharedSession.close()
                        }
                    }
                    let response = try await sharedSession.readRateLimits()
                    await applyActiveRateLimitRefreshSuccess(response)
                } catch let error as AppServerResponseError where error.isUnsupportedMethod || error.isRateLimitAuthenticationRequired {
                    await applyActiveRateLimitRefreshFailure(Date(), error.message, true)
                } catch {
                    await applyActiveRateLimitRefreshFailure(Date(), error.localizedDescription, false)
                }
                await refreshSavedAccounts(auth: auth)
                return
            }

            let fetchedAt = Date()
            do {
                let probe: PreparedInactiveAccountProbe
                let sharedAuthURL = ReviewHomePaths.reviewAuthURL(environment: configuration.environment)
                let persistedActiveAccountKey = persistedActiveAccountKey()
                let selectedSavedAccountKey = auth.savedAccounts.contains(where: {
                    $0.accountKey == activeAccountKey
                }) ? activeAccountKey : nil
                if let selectedSavedAccountKey,
                   selectedSavedAccountKey != persistedActiveAccountKey
                {
                    probe = try await accountRegistryStore.prepareInactiveAccountProbe(
                        accountKey: selectedSavedAccountKey
                    )
                } else if FileManager.default.fileExists(atPath: sharedAuthURL.path) {
                    probe = try await accountRegistryStore.prepareSharedAuthProbe()
                } else if let selectedSavedAccountKey {
                    probe = try await accountRegistryStore.prepareInactiveAccountProbe(
                        accountKey: selectedSavedAccountKey
                    )
                } else {
                    probe = try await accountRegistryStore.prepareSharedAuthProbe()
                }
                let probeManager = probeAppServerManagerFactory(probe.environment)
                var sharedSession: SharedAppServerReviewAuthSession?
                do {
                    let transport = try await probeManager.checkoutAuthTransport()
                    let session = SharedAppServerReviewAuthSession(transport: transport)
                    sharedSession = session
                    let response = try await session.readRateLimits()
                    await applyActiveRateLimitRefreshSuccess(response)
                } catch let error as AppServerResponseError where error.isUnsupportedMethod || error.isRateLimitAuthenticationRequired {
                    await applyActiveRateLimitRefreshFailure(fetchedAt, error.message, true)
                } catch {
                    await applyActiveRateLimitRefreshFailure(fetchedAt, error.localizedDescription, false)
                }
                if let sharedSession {
                    await sharedSession.close()
                }
                await probeManager.shutdown()
                await accountRegistryStore.cleanupProbeHome(probe)
            } catch {
                await applyActiveRateLimitRefreshFailure(fetchedAt, error.localizedDescription, false)
            }
            await refreshSavedAccounts(auth: auth)
            return
        }

        let fetchedAt = Date()
        do {
            let probe = try await accountRegistryStore.prepareInactiveAccountProbe(accountKey: accountKey)
            let probeManager = probeAppServerManagerFactory(probe.environment)
            var sharedSession: SharedAppServerReviewAuthSession?
            do {
                let transport = try await probeManager.checkoutAuthTransport()
                let session = SharedAppServerReviewAuthSession(transport: transport)
                sharedSession = session
                let rateLimits = try await session.readRateLimits()
                if let savedAccount = resolvedSavedAccount(for: accountKey, in: auth) {
                    applyRateLimits(from: rateLimits, to: savedAccount)
                }
                try await accountRegistryStore.updateCachedRateLimits(
                    accountKey: accountKey,
                    rateLimits: rateLimitWindowRecords(from: resolvedCodexSnapshot(from: rateLimits)),
                    fetchedAt: fetchedAt,
                    error: nil
                )
            } catch let error as AppServerResponseError where error.isUnsupportedMethod {
                if let savedAccount = resolvedSavedAccount(for: accountKey, in: auth) {
                    savedAccount.clearRateLimits()
                    savedAccount.updateRateLimitFetchMetadata(
                        fetchedAt: fetchedAt,
                        error: error.message
                    )
                }
                try? await accountRegistryStore.updateCachedRateLimits(
                    accountKey: accountKey,
                    rateLimits: [],
                    fetchedAt: fetchedAt,
                    error: error.message
                )
            } catch let error as AppServerResponseError where error.isRateLimitAuthenticationRequired {
                if let savedAccount = resolvedSavedAccount(for: accountKey, in: auth) {
                    savedAccount.clearRateLimits()
                    savedAccount.updateRateLimitFetchMetadata(
                        fetchedAt: fetchedAt,
                        error: error.message
                    )
                }
                try? await accountRegistryStore.updateCachedRateLimits(
                    accountKey: accountKey,
                    rateLimits: [],
                    fetchedAt: fetchedAt,
                    error: error.message
                )
            } catch {
                if let savedAccount = resolvedSavedAccount(for: accountKey, in: auth) {
                    savedAccount.updateRateLimitFetchMetadata(
                        fetchedAt: fetchedAt,
                        error: error.localizedDescription
                    )
                }
                try? await accountRegistryStore.updateRateLimitFetchStatus(
                    accountKey: accountKey,
                    fetchedAt: fetchedAt,
                    error: error.localizedDescription
                )
            }
            if let sharedSession {
                await sharedSession.close()
            }
            await probeManager.shutdown()
            await accountRegistryStore.cleanupProbeHome(probe)
        } catch {
            if let savedAccount = resolvedSavedAccount(for: accountKey, in: auth) {
                savedAccount.updateRateLimitFetchMetadata(
                    fetchedAt: fetchedAt,
                    error: error.localizedDescription
                )
            }
            try? await accountRegistryStore.updateRateLimitFetchStatus(
                accountKey: accountKey,
                fetchedAt: fetchedAt,
                error: error.localizedDescription
            )
        }
        await refreshSavedAccounts(auth: auth)
    }

    package func requiresCurrentSessionRecovery(
        auth: CodexReviewAuthModel,
        accountKey: String
    ) -> Bool {
        accountSessionController.requiresAuthenticationRecoveryForCurrentSession()
            && runtimeState().serverIsRunning
            && auth.selectedAccount?.accountKey == accountKey
            && auth.savedAccounts.contains(where: { $0.accountKey == accountKey })
    }

    package func reconcileAuthenticatedSession(
        auth: CodexReviewAuthModel,
        serverIsRunning: Bool,
        runtimeGeneration: Int
        ) async {
        await reconcileRateLimitControllers(
            auth: auth,
            serverIsRunning: serverIsRunning,
            runtimeGeneration: runtimeGeneration
        )
    }

    private func reconcileRateLimitControllers(
        auth: CodexReviewAuthModel,
        serverIsRunning: Bool,
        runtimeGeneration: Int
    ) async {
        await accountSessionController.reconcile(
            serverIsRunning: serverIsRunning,
            accountKey: auth.selectedAccount?.accountKey,
            runtimeGeneration: runtimeGeneration,
            accountResolver: { accountKey in
                resolvedAccounts(for: accountKey, in: auth)
            }
        )
        await inactiveAccountRateLimitController.reconcile(
            serverIsRunning: serverIsRunning,
            activeAccountKey: auth.selectedAccount?.accountKey,
            runtimeGeneration: runtimeGeneration,
            savedAccountsProvider: {
                auth.savedAccounts
            },
            refreshRateLimits: { [weak self, weak auth] accountKey in
                guard let self, let auth else {
                    return
                }
                await self.refreshSavedAccountRateLimits(
                    auth: auth,
                    accountKey: accountKey
                )
            }
        )
    }

    private func refreshResolvedState(
        auth: CodexReviewAuthModel,
        forceRestartSession: Bool = false,
        forceRecycleServer: Bool = false,
        allowDuringAuthentication: Bool = false,
        preserveRuntimeOnIdentityChange: Bool = false
    ) async {
        var resolvedAuthenticatedState = false
        do {
            let authManager = makeAuthManager(
                environment: configuration.environment,
                sessionFactory: sharedAuthSessionFactory
            )
            let state = try await authManager.loadState()
            resolvedAuthenticatedState = state.isAuthenticated
            let priorAccount = auth.selectedAccount
            if auth.isAuthenticating, allowDuringAuthentication == false {
                return
            }
            if state.account != nil {
                let refreshedAccountKey = normalizedReviewAccountEmail(email: state.account?.email ?? "")
                let persistedActiveAccountKey = persistedActiveAccountKey()
                let shouldPreservePersistedActiveSelection =
                    persistedActiveAccountKey != nil && persistedActiveAccountKey != refreshedAccountKey
                do {
                    try accountRegistryStore.saveSharedAuthAsSavedAccount(
                        makeActive: shouldPreservePersistedActiveSelection == false
                    )
                } catch {}
            } else if forceRecycleServer == false {
                let sharedAuthURL = ReviewHomePaths.reviewAuthURL(environment: configuration.environment)
                if FileManager.default.fileExists(atPath: sharedAuthURL.path) {
                    try? FileManager.default.removeItem(at: sharedAuthURL)
                    try? await accountRegistryStore.clearActiveAccount()
                }
            }
            let activeAccountKey = await refreshSavedAccounts(
                auth: auth,
                preserveSelectedAccountIfMissing: state.account != nil
            )
            applyResolvedReviewAuthState(
                state,
                activeAccountKey: activeAccountKey,
                priorResolvedAuthenticatedAccount: hasResolvedAuthenticatedAccount,
                preferActiveAccountSelection: forceRecycleServer,
                to: auth
            )
            auth.updateWarning(message: nil)
            let actualIdentityChanged = didAccountIdentityChange(from: priorAccount, to: auth.selectedAccount)
            if state.isAuthenticated,
               actualIdentityChanged == false,
               forceRecycleServer == false
            {
                accountSessionController.resetAuthenticationRequiredCapabilityForAuthRecovery()
            }
            let identityChanged = preserveRuntimeOnIdentityChange ? false : actualIdentityChanged
            hasResolvedAuthenticatedAccount = state.isAuthenticated
            let shouldRestartSameIdentitySession = state.isAuthenticated
                && identityChanged == false
                && forceRecycleServer == false
                && runtimeState().serverIsRunning
            await reconcileAfterResolvedAuthState(
                auth: auth,
                identityChanged: identityChanged,
                forceRestartSession: forceRestartSession || shouldRestartSameIdentitySession,
                forceRecycleServer: forceRecycleServer,
                skipFinalAttach: forceRecycleServer
            )
            if state.isAuthenticated,
               identityChanged == false,
               forceRecycleServer == false,
               let activeAccountKey = auth.selectedAccount?.accountKey,
               runtimeState().serverIsRunning
            {
                await refreshSavedAccountRateLimits(auth: auth, accountKey: activeAccountKey)
            }
            if forceRecycleServer {
                let postRecycleState = try await authManager.loadState()
                resolvedAuthenticatedState = postRecycleState.isAuthenticated
                if postRecycleState.isAuthenticated == false {
                    try? await accountRegistryStore.clearActiveAccount()
                }
                let postRecycleActiveAccountKey = await refreshSavedAccounts(
                    auth: auth
                )
                applyResolvedReviewAuthState(
                    postRecycleState,
                    activeAccountKey: postRecycleActiveAccountKey,
                    priorResolvedAuthenticatedAccount: hasResolvedAuthenticatedAccount,
                    preferActiveAccountSelection: false,
                    to: auth
                )
                auth.updateWarning(message: nil)
                hasResolvedAuthenticatedAccount = postRecycleState.isAuthenticated
                let resolvedRuntimeState = runtimeState()
                await reconcileRateLimitControllers(
                    auth: auth,
                    serverIsRunning: resolvedRuntimeState.serverIsRunning,
                    runtimeGeneration: resolvedRuntimeState.runtimeGeneration
                )
            }
        } catch {
            guard auth.isAuthenticating == false || allowDuringAuthentication else {
                return
            }
            await refreshSavedAccounts(auth: auth)
            if auth.selectedAccount == nil {
                auth.updateSelectedAccount(persistedActiveAccountKey())
            }
            auth.updateWarning(message: nil)
            if resolvedAuthenticatedState || auth.isAuthenticated {
                auth.updatePhase(.failed(message: error.localizedDescription))
            } else {
                auth.updatePhase(.signedOut)
                auth.updateSelectedAccount(nil)
            }
            await reconcileAfterResolvedAuthState(
                auth: auth,
                identityChanged: false,
                forceRestartSession: forceRestartSession,
                forceRecycleServer: forceRecycleServer
            )
            let postRecycleAuthManager = makeAuthManager(
                environment: configuration.environment,
                sessionFactory: sharedAuthSessionFactory
            )
            if forceRecycleServer,
               let postRecycleState = try? await postRecycleAuthManager.loadState()
            {
                resolvedAuthenticatedState = postRecycleState.isAuthenticated
                if postRecycleState.isAuthenticated == false {
                    try? await accountRegistryStore.clearActiveAccount()
                }
                let postRecycleActiveAccountKey = await refreshSavedAccounts(
                    auth: auth
                )
                applyResolvedReviewAuthState(
                    postRecycleState,
                    activeAccountKey: postRecycleActiveAccountKey,
                    priorResolvedAuthenticatedAccount: hasResolvedAuthenticatedAccount,
                    preferActiveAccountSelection: false,
                    to: auth
                )
                auth.updateWarning(message: nil)
                hasResolvedAuthenticatedAccount = postRecycleState.isAuthenticated
                let resolvedRuntimeState = runtimeState()
                await reconcileRateLimitControllers(
                    auth: auth,
                    serverIsRunning: resolvedRuntimeState.serverIsRunning,
                    runtimeGeneration: resolvedRuntimeState.runtimeGeneration
                )
            }
        }
    }

    private func reconcileAfterResolvedAuthState(
        auth: CodexReviewAuthModel,
        identityChanged: Bool,
        forceRestartSession: Bool = false,
        forceRecycleServer: Bool = false,
        skipFinalAttach: Bool = false
    ) async {
        let currentRuntimeState = runtimeState()
        if currentRuntimeState.serverIsRunning,
           identityChanged || forceRestartSession
        {
            await reconcileRateLimitControllers(
                auth: auth,
                serverIsRunning: false,
                runtimeGeneration: currentRuntimeState.runtimeGeneration
            )
            if identityChanged || forceRecycleServer {
                await recycleServerIfRunning()
            }
        }

        if skipFinalAttach {
            return
        }

        let resolvedRuntimeState = runtimeState()
        await reconcileRateLimitControllers(
            auth: auth,
            serverIsRunning: resolvedRuntimeState.serverIsRunning,
            runtimeGeneration: resolvedRuntimeState.runtimeGeneration
        )
    }

    private func updateAuthenticationFailureState(
        _ error: Error,
        auth: CodexReviewAuthModel
    ) {
        let message: String
        if let error = error as? ReviewAuthError {
            message = error.errorDescription ?? "Authentication failed."
        } else {
            message = error.localizedDescription
        }
        auth.recordAuthenticationFailure(message: message)
    }

    private func resolveLogoutFailureState(
        auth: CodexReviewAuthModel,
        priorAccount: CodexAccount?,
        message: String,
        logoutCompleted: Bool = false,
        removesSavedSignedOutAccount: Bool = false
    ) async {
        let hadAuthenticatedAccount = auth.selectedAccount != nil
        let priorAccountKey = priorAccount?.accountKey
        let authManager = makeAuthManager(
            environment: configuration.environment,
            sessionFactory: sharedAuthSessionFactory
        )
        if let resolvedState = try? await authManager.loadState() {
            if resolvedState.isAuthenticated {
                do {
                    try accountRegistryStore.saveSharedAuthAsSavedAccount(makeActive: true)
                } catch {}
            } else if removesSavedSignedOutAccount, let priorAccountKey {
                try? await accountRegistryStore.clearActiveAccount(accountKey: priorAccountKey)
            } else {
                try? FileManager.default.removeItem(
                    at: ReviewHomePaths.reviewAuthURL(environment: configuration.environment)
                )
            }
            let activeAccountKey = await refreshSavedAccounts(
                auth: auth,
                preserveSelectedAccountIfMissing: removesSavedSignedOutAccount == false
            )
            applyResolvedReviewAuthState(
                resolvedState,
                activeAccountKey: activeAccountKey,
                priorResolvedAuthenticatedAccount: hasResolvedAuthenticatedAccount,
                preferActiveAccountSelection: false,
                to: auth
            )
            let identityChanged = didAccountIdentityChange(from: priorAccount, to: auth.selectedAccount)
            hasResolvedAuthenticatedAccount = resolvedState.isAuthenticated
            auth.updateWarning(message: nil)
            if auth.isAuthenticated {
                auth.updatePhase(.failed(message: message))
            }
            await reconcileAfterResolvedAuthState(
                auth: auth,
                identityChanged: identityChanged,
                forceRestartSession: identityChanged || (hadAuthenticatedAccount && resolvedState.isAuthenticated == false),
                forceRecycleServer: hadAuthenticatedAccount && resolvedState.isAuthenticated == false
            )
            return
        }
        if logoutCompleted {
            if removesSavedSignedOutAccount, let priorAccountKey {
                try? await accountRegistryStore.clearActiveAccount(accountKey: priorAccountKey)
            } else {
                try? FileManager.default.removeItem(
                    at: ReviewHomePaths.reviewAuthURL(environment: configuration.environment)
                )
            }
            if let loaded = try? accountRegistryStore.loadAccounts() {
                auth.applySavedAccountStates(
                    loaded.accounts,
                    activeAccountKey: loaded.activeAccountKey
                )
            } else {
                auth.applySavedAccountStates([], activeAccountKey: nil)
            }
            auth.updateSelectedAccount(nil)
            auth.updatePhase(.signedOut)
            auth.updateWarning(message: nil)
            hasResolvedAuthenticatedAccount = false
            await reconcileAfterResolvedAuthState(
                auth: auth,
                identityChanged: true,
                forceRestartSession: true,
                forceRecycleServer: true
            )
            return
        }
        auth.updateWarning(message: nil)
        auth.updatePhase(.failed(message: message))
        await reconcileAfterResolvedAuthState(
            auth: auth,
            identityChanged: false
        )
    }

    private func makeAuthManager(
        environment: [String: String],
        sessionFactory: @escaping @Sendable ([String: String]) async throws -> any ReviewAuthSession
    ) -> ReviewAuthManager {
        ReviewAuthManager(
            configuration: .init(
                codexCommand: configuration.codexCommand,
                environment: environment
            ),
            sessionFactory: {
                try await sessionFactory(environment)
            }
        )
    }

    private func ensureAuthenticationAttemptIsCurrent(_ attemptID: UUID) throws {
        guard activeAuthenticationAttemptID == attemptID else {
            throw ReviewAuthError.cancelled
        }
    }

    private func cleanupAuthenticationAttemptIfCurrent(_ attemptID: UUID) {
        guard activeAuthenticationAttemptID == attemptID else {
            return
        }
        let probe = activeAuthenticationProbe
        activeAuthenticationAttemptID = nil
        authenticationCancellationRestoreState = nil
        activeAuthenticationManager = nil
        activeAuthenticationProbe = nil
        if let probe {
            Task {
                await self.accountRegistryStore.cleanupProbeHome(probe)
            }
        }
    }

    private func takeAuthenticationProbeForCommit(_ attemptID: UUID) -> PreparedInactiveAccountProbe? {
        guard activeAuthenticationAttemptID == attemptID,
              let probe = activeAuthenticationProbe
        else {
            return nil
        }
        activeAuthenticationAttemptID = nil
        authenticationCancellationRestoreState = nil
        activeAuthenticationManager = nil
        activeAuthenticationProbe = nil
        return probe
    }

    private func makeAuthenticationCommitOutcome(
        intent: AuthenticationIntent,
        priorSnapshot: AuthPresentationSnapshot,
        priorCurrentAccount: CodexAccount?,
        completedAccount: ReviewAuthAccount
    ) -> AuthCommitOutcome {
        switch intent {
        case .signIn:
            return .init(
                presentationEffect: .activateCommittedAccount(
                    forceRecycleServer: runtimeState().serverIsRunning
                ),
                sharedAuthUpdate: .none,
                runtimeEffect: .none,
                shouldMarkCommittedSavedAccountActive: true,
                shouldCancelRunningJobs: true
            )
        case .addAccount:
            let sharedAuthUpdate = sharedAuthUpdateForAddAccount(
                priorSnapshot: priorSnapshot,
                priorCurrentAccount: priorCurrentAccount,
                completedAccount: completedAccount
            )
            return .init(
                presentationEffect: .preserveCurrentSession,
                sharedAuthUpdate: sharedAuthUpdate,
                runtimeEffect: addAccountRuntimeEffect(
                    sharedAuthUpdate: sharedAuthUpdate,
                    priorCurrentAccount: priorCurrentAccount
                ),
                shouldMarkCommittedSavedAccountActive: shouldMarkCommittedSavedAccountActiveForAddAccount(
                    priorSnapshot: priorSnapshot,
                    priorCurrentAccount: priorCurrentAccount
                ),
                shouldCancelRunningJobs: false
            )
        }
    }

    private func sharedAuthUpdateForAddAccount(
        priorSnapshot: AuthPresentationSnapshot,
        priorCurrentAccount: CodexAccount?,
        completedAccount: ReviewAuthAccount
    ) -> SharedAuthUpdate {
        guard let priorCurrentAccount else {
            return .none
        }
        guard normalizedReviewAccountEmail(email: priorCurrentAccount.email)
            == normalizedReviewAccountEmail(email: completedAccount.email),
            currentSessionOwnsSameAccountAddAccountRefresh(
                priorSnapshot: priorSnapshot,
                priorCurrentAccount: priorCurrentAccount
            )
        else {
            return .none
        }
        return .refreshCurrentAccountSnapshot
    }

    private func shouldMarkCommittedSavedAccountActiveForAddAccount(
        priorSnapshot: AuthPresentationSnapshot,
        priorCurrentAccount: CodexAccount?
    ) -> Bool {
        guard priorCurrentAccount == nil else {
            return false
        }
        return priorSnapshot.selectedAccountKey == nil && persistedActiveAccountKey() == nil
    }

    private func addAccountRuntimeEffect(
        sharedAuthUpdate: SharedAuthUpdate,
        priorCurrentAccount: CodexAccount?
    ) -> CodexAuthRuntimeEffect {
        guard sharedAuthUpdate.shouldRefreshSharedAuthSnapshot,
              let accountKey = priorCurrentAccount?.accountKey
        else {
            return .none
        }
        let currentRuntimeState = runtimeState()
        guard currentRuntimeState.serverIsRunning else {
            return .none
        }
        return resolveAddAccountRuntimeEffect(
            accountKey: accountKey,
            runtimeGeneration: currentRuntimeState.runtimeGeneration
        )
    }

    private func currentSessionOwnsSameAccountAddAccountRefresh(
        priorSnapshot: AuthPresentationSnapshot,
        priorCurrentAccount: CodexAccount?
    ) -> Bool {
        guard let priorCurrentAccount else {
            return false
        }
        return priorSnapshot.selectedAccountKey == priorCurrentAccount.accountKey
    }

    private func applyCommittedActiveAccount(
        auth: CodexReviewAuthModel,
        savedAccountKey: String?,
        priorAccount: CodexAccount?,
        forceRecycleServer: Bool,
        preserveRuntimeOnIdentityChange: Bool = false
    ) async {
        if runtimeState().serverIsRunning {
            await refreshResolvedState(
                auth: auth,
                forceRestartSession: true,
                forceRecycleServer: forceRecycleServer,
                allowDuringAuthentication: true,
                preserveRuntimeOnIdentityChange: preserveRuntimeOnIdentityChange
            )
            return
        }

        let activeAccountKey = await refreshSavedAccounts(auth: auth)
        if let activeAccountKey,
           auth.savedAccounts.contains(where: { $0.accountKey == activeAccountKey })
        {
            auth.updateSelectedAccount(
                auth.savedAccounts.first(where: { $0.accountKey == activeAccountKey })?.id
            )
        } else if let savedAccountKey,
                  auth.savedAccounts.contains(where: { $0.accountKey == savedAccountKey })
        {
            auth.updateSelectedAccount(
                auth.savedAccounts.first(where: { $0.accountKey == savedAccountKey })?.id
            )
        } else {
            auth.updateSelectedAccount(nil)
        }
        auth.updatePhase(.signedOut)
        auth.updateWarning(message: nil)
        hasResolvedAuthenticatedAccount = auth.selectedAccount != nil
        await reconcileAfterResolvedAuthState(
            auth: auth,
            identityChanged: didAccountIdentityChange(from: priorAccount, to: auth.selectedAccount)
        )
    }

    private func performCommittedJobCleanupIfNeeded(shouldCancelJobs: Bool) async -> String? {
        guard shouldCancelJobs else {
            return nil
        }
        do {
            try await cancelRunningJobs(reason: "Account change requested.")
            return nil
        } catch {
            return error.localizedDescription.nilIfEmpty ?? "Failed to cancel running reviews."
        }
    }

    private func restoreNonActivatingAccountAdditionState(
        auth: CodexReviewAuthModel,
        priorCurrentAccount: CodexAccount?
    ) {
        guard let priorCurrentAccount else {
            auth.updateSelectedAccount(nil)
            return
        }
        if let currentSavedAccount = auth.savedAccounts.first(where: {
            $0.accountKey == priorCurrentAccount.accountKey
        }) {
            auth.updateSelectedAccount(currentSavedAccount.id)
            return
        }
        var updatedSavedAccounts = auth.savedAccounts.map(savedAccountPayload(from:))
        updatedSavedAccounts.append(savedAccountPayload(from: priorCurrentAccount))
        auth.applySavedAccountStates(updatedSavedAccounts)
        auth.updateSelectedAccount(priorCurrentAccount.id)
    }

    private func syncCurrentAccountMetadata(
        from sourceAccount: CodexAccount,
        to currentAccount: CodexAccount
    ) {
        guard sourceAccount !== currentAccount else {
            return
        }
        currentAccount.updateEmail(sourceAccount.email)
        currentAccount.updatePlanType(sourceAccount.planType)
        currentAccount.updateRateLimits(
            sourceAccount.rateLimits.map {
                (
                    windowDurationMinutes: $0.windowDurationMinutes,
                    usedPercent: $0.usedPercent,
                    resetsAt: $0.resetsAt
                )
            }
        )
        currentAccount.updateRateLimitFetchMetadata(
            fetchedAt: sourceAccount.lastRateLimitFetchAt,
            error: sourceAccount.lastRateLimitError
        )
    }

    @discardableResult
    private func refreshSavedAccounts(
        auth: CodexReviewAuthModel,
        preserveSelectedAccountIfMissing: Bool = true
    ) async -> String? {
        if let loaded = try? accountRegistryStore.loadAccounts() {
            let priorAccount = auth.selectedAccount
            let priorAccountsByKey = Dictionary(
                uniqueKeysWithValues: auth.savedAccounts.map { ($0.accountKey, $0) }
            )
            let loadedAccounts = loaded.accounts.map { loadedPayload in
                let inMemoryAccount = priorAccount?.accountKey == loadedPayload.accountKey
                    ? priorAccount
                    : priorAccountsByKey[loadedPayload.accountKey]
                if let inMemoryAccount,
                   shouldPreferInMemoryRateLimitState(
                       priorAccount: inMemoryAccount,
                       loadedPayload: loadedPayload
                   )
                {
                    return CodexSavedAccountPayload(
                        accountKey: loadedPayload.accountKey,
                        email: loadedPayload.email,
                        planType: loadedPayload.planType,
                        rateLimits: inMemoryAccount.rateLimits.map {
                            (
                                windowDurationMinutes: $0.windowDurationMinutes,
                                usedPercent: $0.usedPercent,
                                resetsAt: $0.resetsAt
                            )
                        },
                        lastRateLimitFetchAt: inMemoryAccount.lastRateLimitFetchAt,
                        lastRateLimitError: inMemoryAccount.lastRateLimitError
                    )
                }
                return loadedPayload
            }
            let reconciledAccounts = loadedAccounts
            let shouldPreserveMissingPriorAccount = preserveSelectedAccountIfMissing
                && priorAccount != nil
                && reconciledAccounts.contains(where: { $0.accountKey == priorAccount?.accountKey }) == false
            auth.applySavedAccountStates(
                reconciledAccounts,
                activeAccountKey: loaded.activeAccountKey
            )
            if let priorAccount,
               let currentSavedAccount = auth.savedAccounts.first(where: {
                   $0.accountKey == priorAccount.accountKey
               })
            {
                auth.updateSelectedAccount(currentSavedAccount.id)
            } else if shouldPreserveMissingPriorAccount {
                auth.updateDetachedAccount(priorAccount)
            } else if preserveSelectedAccountIfMissing == false {
                auth.updateSelectedAccount(nil)
            }
            return loaded.activeAccountKey
        }
        return nil
    }

    private func applyAuthenticationProgressState(
        _ state: ReviewAuthState,
        to auth: CodexReviewAuthModel
    ) {
        switch state {
        case .signingIn(let progress):
            auth.updatePhase(.signingIn(makeAuthProgress(progress)))
        case .failed(let message):
            auth.updatePhase(.failed(message: message))
        case .signedOut:
            auth.updatePhase(.signedOut)
        case .signedIn:
            return
        }
    }

    private func shouldPreferInMemoryRateLimitState(
        priorAccount: CodexAccount,
        loadedPayload: CodexSavedAccountPayload
    ) -> Bool {
        switch (priorAccount.lastRateLimitFetchAt, loadedPayload.lastRateLimitFetchAt) {
        case let (priorFetchedAt?, loadedFetchedAt?):
            return priorFetchedAt > loadedFetchedAt
        case (.some, nil):
            return true
        default:
            return false
        }
    }

    private func persistedActiveAccountKey() -> String? {
        guard let loaded = try? accountRegistryStore.loadAccounts() else {
            return nil
        }
        return loaded.activeAccountKey
    }
}

@MainActor
private final class ActiveAccountRateLimitObserver {
    typealias AccountResolver = @MainActor @Sendable (String) -> [CodexAccount]

    private struct AttachmentTarget: Equatable {
        var accountKey: String
        var runtimeGeneration: Int
    }

    private enum RateLimitsReadCapability {
        case unknown
        case supported
        case unsupported
        case authenticationRequired
    }

    private let appServerManager: any AppServerManaging
    private let accountRegistryStore: ReviewAccountRegistryStore
    private let clock: any ReviewClock
    private let staleRefreshInterval: Duration
    private var activeTarget: AttachmentTarget?
    private var observerTask: Task<Void, Never>?
    private var observerTransport: (any AppServerSessionTransport)?
    private var retryTask: Task<Void, Never>?
    private var staleRefreshTask: Task<Void, Never>?
    private var staleRefreshTaskID: UUID?
    private var rateLimitsReadCapability: RateLimitsReadCapability = .unknown
    private var accountResolver: AccountResolver?

    init(
        appServerManager: any AppServerManaging,
        accountRegistryStore: ReviewAccountRegistryStore,
        clock: any ReviewClock = ContinuousClock(),
        staleRefreshInterval: Duration = .seconds(60)
    ) {
        self.appServerManager = appServerManager
        self.accountRegistryStore = accountRegistryStore
        self.clock = clock
        self.staleRefreshInterval = staleRefreshInterval
    }

    func reconcile(
        serverIsRunning: Bool,
        accountKey: String?,
        runtimeGeneration: Int,
        accountResolver: @escaping AccountResolver
    ) async {
        let desiredTarget = accountKey.map {
            AttachmentTarget(
                accountKey: $0,
                runtimeGeneration: runtimeGeneration
            )
        }
        let targetChanged = desiredTarget != activeTarget

        let shouldAttach = serverIsRunning && desiredTarget != nil
        if shouldAttach == false || targetChanged {
            await detach()
            activeTarget = shouldAttach ? desiredTarget : nil
            if targetChanged {
                rateLimitsReadCapability = .unknown
            }
        }
        self.accountResolver = shouldAttach ? accountResolver : nil

        if desiredTarget == activeTarget,
           rateLimitsReadCapability == .authenticationRequired
        {
            return
        }

        guard shouldAttach,
              let target = activeTarget,
              observerTask == nil,
              observerTransport == nil,
              retryTask == nil
        else {
            return
        }

        await attach(target: target)
    }

    private func resolveCurrentAccounts(for target: AttachmentTarget) -> [CodexAccount] {
        accountResolver?(target.accountKey) ?? []
    }

    private func attach(
        target: AttachmentTarget
    ) async {
        guard resolveCurrentAccounts(for: target).isEmpty == false else {
            return
        }
        do {
            let transport = try await appServerManager.checkoutAuthTransport()
            guard isCurrent(target: target) else {
                await transport.close()
                return
            }
            observerTransport = transport
            observerTask = Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                await self.runObservation(
                    target: target,
                    transport: transport
                )
            }
        } catch {
            scheduleRetry(target: target)
        }
    }

    private func runObservation(
        target: AttachmentTarget,
        transport: any AppServerSessionTransport
    ) async {
        var shouldRetry = false
        defer {
            Task {
                await transport.close()
            }
            finishObservation(target: target)
            if shouldRetry {
                scheduleRetry(target: target)
            }
        }

        let session = SharedAppServerReviewAuthSession(transport: transport)
        let notificationStream = await session.notificationStream()

        do {
            let response = try await session.readRateLimits()
            guard isCurrent(target: target) else {
                return
            }
            let accounts = resolveCurrentAccounts(for: target)
            guard let persistedAccount = accounts.first
            else {
                return
            }
            rateLimitsReadCapability = .supported
            for account in accounts {
                applyRateLimits(from: response, to: account)
            }
            try? accountRegistryStore.updateSavedAccountMetadata(from: persistedAccount)
            try? accountRegistryStore.updateCachedRateLimits(from: persistedAccount)
            scheduleStaleRefresh(
                target: target,
                session: session
            )
        } catch let error as AppServerResponseError where error.isUnsupportedMethod {
            guard isCurrent(target: target) else {
                return
            }
            let accounts = resolveCurrentAccounts(for: target)
            guard let persistedAccount = accounts.first
            else {
                return
            }
            rateLimitsReadCapability = .unsupported
            for account in accounts {
                account.clearRateLimits()
                account.updateRateLimitFetchMetadata(
                    fetchedAt: Date(),
                    error: error.message
                )
            }
            try? accountRegistryStore.updateCachedRateLimits(from: persistedAccount)
        } catch let error as AppServerResponseError where error.isRateLimitAuthenticationRequired {
            guard isCurrent(target: target) else {
                return
            }
            let accounts = resolveCurrentAccounts(for: target)
            guard let persistedAccount = accounts.first
            else {
                return
            }
            rateLimitsReadCapability = .authenticationRequired
            for account in accounts {
                account.clearRateLimits()
                account.updateRateLimitFetchMetadata(
                    fetchedAt: Date(),
                    error: error.message
                )
            }
            try? accountRegistryStore.updateCachedRateLimits(from: persistedAccount)
            return
        } catch is CancellationError {
            return
        } catch {
            guard isCurrent(target: target) else {
                return
            }
            let accounts = resolveCurrentAccounts(for: target)
            guard let persistedAccount = accounts.first
            else {
                return
            }
            for account in accounts {
                account.updateRateLimitFetchMetadata(
                    fetchedAt: Date(),
                    error: error.localizedDescription
                )
            }
            try? accountRegistryStore.updateCachedRateLimits(from: persistedAccount)
            shouldRetry = true
            return
        }

        guard isCurrent(target: target) else {
            return
        }

        do {
            for try await notification in notificationStream {
                guard case .accountRateLimitsUpdated(let payload) = notification else {
                    continue
                }
                guard isCurrent(target: target) else {
                    return
                }
                let accounts = resolveCurrentAccounts(for: target)
                guard let persistedAccount = accounts.first
                else {
                    return
                }
                guard isCodexRateLimit(payload.rateLimits.limitID) else {
                    continue
                }
                for account in accounts {
                    applyRateLimits(from: payload.rateLimits, to: account)
                }
                try? accountRegistryStore.updateCachedRateLimits(from: persistedAccount)
                if rateLimitsReadCapability != .unsupported {
                    scheduleStaleRefresh(
                        target: target,
                        session: session
                    )
                }
            }
            guard isCurrent(target: target) else {
                return
            }
            shouldRetry = true
        } catch is CancellationError {
            return
        } catch {
            guard isCurrent(target: target),
                  shouldRetryRateLimitObservation(after: error)
            else {
                return
            }
            shouldRetry = true
        }
    }

    private func finishObservation(target: AttachmentTarget) {
        guard activeTarget == target else {
            return
        }
        staleRefreshTask?.cancel()
        staleRefreshTask = nil
        staleRefreshTaskID = nil
        observerTask = nil
        observerTransport = nil
    }

    func resetAuthenticationRequiredCapabilityForAuthRecovery() {
        guard rateLimitsReadCapability == .authenticationRequired else {
            return
        }
        rateLimitsReadCapability = .unknown
    }

    func requiresAuthenticationRecoveryForCurrentSession() -> Bool {
        rateLimitsReadCapability == .authenticationRequired
    }

    private func scheduleStaleRefresh(
        target: AttachmentTarget,
        session: SharedAppServerReviewAuthSession
    ) {
        guard rateLimitsReadCapability != .unsupported else {
            return
        }
        staleRefreshTask?.cancel()
        let taskID = UUID()
        staleRefreshTaskID = taskID
        staleRefreshTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            do {
                try await self.clock.sleep(for: self.staleRefreshInterval)
            } catch {
                return
            }

            guard self.staleRefreshTaskID == taskID,
                  self.isCurrent(target: target)
            else {
                return
            }
            let accounts = self.resolveCurrentAccounts(for: target)
            guard let persistedAccount = accounts.first else {
                return
            }

            do {
                let response = try await session.readRateLimits()
                guard self.staleRefreshTaskID == taskID,
                      self.isCurrent(target: target)
                else {
                    return
                }
                let currentAccounts = self.resolveCurrentAccounts(for: target)
                guard let currentPersistedAccount = currentAccounts.first else {
                    return
                }
                self.rateLimitsReadCapability = .supported
                for account in currentAccounts {
                    applyRateLimits(from: response, to: account)
                }
                try? self.accountRegistryStore.updateCachedRateLimits(from: currentPersistedAccount)
                self.staleRefreshTask = nil
                self.staleRefreshTaskID = nil
                self.scheduleStaleRefresh(
                    target: target,
                    session: session
                )
            } catch let error as AppServerResponseError where error.isUnsupportedMethod {
                guard self.staleRefreshTaskID == taskID,
                      self.isCurrent(target: target)
                else {
                    return
                }
                self.rateLimitsReadCapability = .unsupported
                for account in accounts {
                    account.clearRateLimits()
                    account.updateRateLimitFetchMetadata(
                        fetchedAt: Date(),
                        error: error.message
                    )
                }
                try? self.accountRegistryStore.updateCachedRateLimits(from: persistedAccount)
                self.staleRefreshTask = nil
                self.staleRefreshTaskID = nil
            } catch let error as AppServerResponseError where error.isRateLimitAuthenticationRequired {
                guard self.staleRefreshTaskID == taskID,
                      self.isCurrent(target: target)
                else {
                    return
                }
                self.rateLimitsReadCapability = .authenticationRequired
                for account in accounts {
                    account.clearRateLimits()
                    account.updateRateLimitFetchMetadata(
                        fetchedAt: Date(),
                        error: error.message
                    )
                }
                try? self.accountRegistryStore.updateCachedRateLimits(from: persistedAccount)
                self.staleRefreshTask = nil
                self.staleRefreshTaskID = nil
            } catch is CancellationError {
                return
            } catch {
                guard self.staleRefreshTaskID == taskID,
                      self.isCurrent(target: target)
                else {
                    return
                }
                for account in accounts {
                    account.updateRateLimitFetchMetadata(
                        fetchedAt: Date(),
                        error: error.localizedDescription
                    )
                }
                try? self.accountRegistryStore.updateCachedRateLimits(from: persistedAccount)
                self.staleRefreshTask = nil
                self.staleRefreshTaskID = nil
                self.scheduleStaleRefresh(
                    target: target,
                    session: session
                )
            }
        }
    }

    private func scheduleRetry(
        target: AttachmentTarget
    ) {
        guard activeTarget == target,
              retryTask == nil
        else {
            return
        }

        retryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard let self else {
                return
            }
            self.retryTask = nil
            guard self.isCurrent(target: target) else {
                return
            }
            await self.attach(target: target)
        }
    }

    private func isCurrent(
        target: AttachmentTarget
    ) -> Bool {
        activeTarget == target
    }

    private func detach() async {
        retryTask?.cancel()
        retryTask = nil
        staleRefreshTask?.cancel()
        staleRefreshTask = nil
        staleRefreshTaskID = nil
        rateLimitsReadCapability = .unknown
        accountResolver = nil
        let task = observerTask
        observerTask = nil
        let transport = observerTransport
        observerTransport = nil
        task?.cancel()
        if let transport {
            await transport.close()
        }
    }

    func checkoutActiveRateLimitTransport() async throws -> any AppServerSessionTransport {
        try await appServerManager.checkoutAuthTransport()
    }
}

@MainActor
private final class InactiveSavedAccountRateLimitScheduler {
    typealias SavedAccountsProvider = @MainActor @Sendable () -> [CodexAccount]
    typealias RefreshRateLimitsAction = @MainActor @Sendable (String) async -> Void

    private struct RefreshTarget: Equatable {
        var runtimeGeneration: Int
        var activeAccountKey: String?
        var savedAccountKeys: [String]
    }

    private let clock: any ReviewClock
    private let refreshInterval: Duration
    private let clockReferenceInstant: ContinuousClock.Instant
    private let clockReferenceDate: Date
    private var activeTarget: RefreshTarget?
    private var savedAccountsProvider: SavedAccountsProvider?
    private var refreshRateLimitsAction: RefreshRateLimitsAction?
    private var refreshTask: Task<Void, Never>?

    init(
        clock: any ReviewClock = ContinuousClock(),
        refreshInterval: Duration = .seconds(15 * 60)
    ) {
        self.clock = clock
        self.refreshInterval = refreshInterval
        clockReferenceInstant = clock.now
        clockReferenceDate = Date()
    }

    func reconcile(
        serverIsRunning: Bool,
        activeAccountKey: String?,
        runtimeGeneration: Int,
        savedAccountsProvider: @escaping SavedAccountsProvider,
        refreshRateLimits: @escaping RefreshRateLimitsAction
    ) async {
        let desiredTarget = serverIsRunning
            ? makeTarget(
                savedAccountsProvider: savedAccountsProvider,
                activeAccountKey: activeAccountKey,
                runtimeGeneration: runtimeGeneration
            )
            : nil

        if desiredTarget != activeTarget {
            await detach()
            activeTarget = desiredTarget
        }

        self.savedAccountsProvider = desiredTarget == nil ? nil : savedAccountsProvider
        refreshRateLimitsAction = desiredTarget == nil ? nil : refreshRateLimits

        guard let target = activeTarget,
              refreshTask == nil,
              currentInactiveAccounts(for: target).isEmpty == false
        else {
            return
        }

        refreshTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            await self.runRefreshLoop(target: target)
        }
    }

    private func makeTarget(
        savedAccountsProvider: SavedAccountsProvider,
        activeAccountKey: String?,
        runtimeGeneration: Int
    ) -> RefreshTarget {
        RefreshTarget(
            runtimeGeneration: runtimeGeneration,
            activeAccountKey: activeAccountKey,
            savedAccountKeys: savedAccountsProvider().map(\.accountKey)
        )
    }

    private func runRefreshLoop(
        target: RefreshTarget
    ) async {
        defer {
            finishRefreshLoop(target: target)
        }

        await refreshInactiveAccounts(
            for: target,
            shouldRefresh: { [weak self] account in
                guard let self else {
                    return false
                }
                return self.shouldImmediatelyCatchUp(account)
            }
        )

        while isCurrent(target: target) {
            do {
                try await clock.sleep(for: refreshInterval)
            } catch {
                return
            }

            await refreshInactiveAccounts(
                for: target,
                shouldRefresh: { _ in true }
            )
        }
    }

    private func refreshInactiveAccounts(
        for target: RefreshTarget,
        shouldRefresh: (CodexAccount) -> Bool
    ) async {
        let inactiveAccounts = currentInactiveAccounts(for: target)

        for account in inactiveAccounts where shouldRefresh(account) {
            guard isCurrent(target: target),
                  let refreshRateLimitsAction
            else {
                return
            }
            await refreshRateLimitsAction(account.accountKey)
        }
    }

    private func currentInactiveAccounts(
        for target: RefreshTarget
    ) -> [CodexAccount] {
        guard isCurrent(target: target),
              let savedAccountsProvider
        else {
            return []
        }

        return savedAccountsProvider().filter {
            $0.accountKey != target.activeAccountKey
        }
    }

    private func shouldImmediatelyCatchUp(
        _ account: CodexAccount
    ) -> Bool {
        guard let lastFetchAt = account.lastRateLimitFetchAt else {
            return true
        }
        return currentDate().timeIntervalSince(lastFetchAt) > timeInterval(for: refreshInterval)
    }

    private func currentDate() -> Date {
        let elapsed = clockReferenceInstant.duration(to: clock.now)
        return clockReferenceDate.addingTimeInterval(timeInterval(for: elapsed))
    }

    private func timeInterval(
        for duration: Duration
    ) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private func finishRefreshLoop(
        target: RefreshTarget
    ) {
        guard activeTarget == target else {
            return
        }

        refreshTask = nil
    }

    private func isCurrent(
        target: RefreshTarget
    ) -> Bool {
        activeTarget == target
    }

    private func detach() async {
        let task = refreshTask
        refreshTask = nil
        activeTarget = nil
        savedAccountsProvider = nil
        refreshRateLimitsAction = nil
        task?.cancel()
        if let task {
            await task.value
        }
    }
}

private struct AuthPresentationSnapshot {
    var phase: CodexReviewAuthModel.Phase
    var savedAccounts: [SavedAccountPresentationSnapshot]
    var selectedAccountKey: CodexAccount.ID?
    var selectedAccount: SavedAccountPresentationSnapshot?
    var persistedActiveAccountKey: String?
    var warningMessage: String?
    var isResolvedAuthenticated: Bool
}

private struct SavedAccountPresentationSnapshot {
    var accountKey: String
    var email: String
    var planType: String?
    var rateLimits: [ReviewSavedRateLimitWindowRecord]
    var lastRateLimitFetchAt: Date?
    var lastRateLimitError: String?
}

@MainActor
private func snapshot(
    from auth: CodexReviewAuthModel,
    isResolvedAuthenticated: Bool
) -> AuthPresentationSnapshot {
    .init(
        phase: auth.phase,
        savedAccounts: auth.savedAccounts.map(makeSavedAccountPresentationSnapshot),
        selectedAccountKey: auth.selectedAccount?.id,
        selectedAccount: auth.selectedAccount.map(makeSavedAccountPresentationSnapshot),
        persistedActiveAccountKey: auth.persistedActiveAccountKey,
        warningMessage: auth.warningMessage,
        isResolvedAuthenticated: isResolvedAuthenticated
    )
}

@MainActor
private func restore(
    auth: CodexReviewAuthModel,
    from snapshot: AuthPresentationSnapshot
) {
    auth.updatePhase(snapshot.phase)
    auth.updateWarning(message: snapshot.warningMessage)
    auth.applySavedAccountStates(
        snapshot.savedAccounts.map(makeSavedAccountPayload),
        activeAccountKey: snapshot.persistedActiveAccountKey
    )
    if let selectedAccountKey = snapshot.selectedAccountKey,
       let savedAccount = auth.savedAccounts.first(where: { $0.id == selectedAccountKey })
    {
        auth.updateSelectedAccount(savedAccount.id)
    } else {
        auth.updateDetachedAccount(
            snapshot.selectedAccount.map(makeDetachedAccount)
        )
    }
}

@MainActor
private func makeDetachedAccount(from snapshot: SavedAccountPresentationSnapshot) -> CodexAccount {
    let payload = makeSavedAccountPayload(snapshot)
    let account = CodexAccount(
        accountKey: payload.accountKey,
        email: payload.email,
        planType: payload.planType
    )
    account.apply(payload)
    return account
}

@MainActor
private func makeReviewAuthAccount(_ account: CodexAccount) -> ReviewAuthAccount {
    .init(
        email: account.email,
        planType: account.planType
    )
}

@MainActor
private func makeSavedAccountPresentationSnapshot(_ account: CodexAccount) -> SavedAccountPresentationSnapshot {
    .init(
        accountKey: account.accountKey,
        email: account.email,
        planType: account.planType,
        rateLimits: account.rateLimits.map {
            .init(
                windowDurationMinutes: $0.windowDurationMinutes,
                usedPercent: $0.usedPercent,
                resetsAt: $0.resetsAt
            )
        },
        lastRateLimitFetchAt: account.lastRateLimitFetchAt,
        lastRateLimitError: account.lastRateLimitError
    )
}

@MainActor
private func makeSavedAccountPayload(_ snapshot: SavedAccountPresentationSnapshot) -> CodexSavedAccountPayload {
    .init(
        accountKey: snapshot.accountKey,
        email: snapshot.email,
        planType: snapshot.planType,
        rateLimits: snapshot.rateLimits.map {
            (
                windowDurationMinutes: $0.windowDurationMinutes,
                usedPercent: $0.usedPercent,
                resetsAt: $0.resetsAt
            )
        },
        lastRateLimitFetchAt: snapshot.lastRateLimitFetchAt,
        lastRateLimitError: snapshot.lastRateLimitError
    )
}

@MainActor
@discardableResult
private func applyResolvedReviewAuthState(
    _ state: ReviewAuthState,
    activeAccountKey: String?,
    priorResolvedAuthenticatedAccount: Bool,
    preferActiveAccountSelection: Bool,
    to auth: CodexReviewAuthModel
) -> Bool {
    switch state {
    case .signedOut:
        auth.updatePhase(.signedOut)
        auth.updateSelectedAccount(nil)
        return priorResolvedAuthenticatedAccount
    case .signingIn(let progress):
        auth.updatePhase(.signingIn(makeAuthProgress(progress)))
        return false
    case .failed(let message):
        auth.updatePhase(.failed(message: message))
        return false
    case .signedIn(let account):
        let identityChanged = applyReviewAuthAccount(
            account,
            activeAccountKey: activeAccountKey,
            preferActiveAccountSelection: preferActiveAccountSelection,
            to: auth
        )
        auth.updatePhase(.signedOut)
        return identityChanged
    }
}

@MainActor
@discardableResult
private func applyReviewAuthAccount(
    _ account: ReviewAuthAccount,
    activeAccountKey: String?,
    preferActiveAccountSelection: Bool,
    to auth: CodexReviewAuthModel
) -> Bool {
    let priorAccount = auth.selectedAccount
    if preferActiveAccountSelection,
       activeAccountKey == nil
    {
        auth.updateSelectedAccount(nil)
        return didAccountIdentityChange(from: priorAccount, to: nil)
    }
    let normalizedEmail = normalizedReviewAccountEmail(email: account.email)

    if let activeAccountKey,
       activeAccountKey == normalizedEmail,
       let existingAccount = auth.savedAccounts.first(where: { $0.accountKey == activeAccountKey })
    {
        existingAccount.updateEmail(account.email)
        existingAccount.updatePlanType(account.planType)
        auth.updateSelectedAccount(existingAccount.id)
        return didAccountIdentityChange(from: priorAccount, to: existingAccount)
    }

    if let existingAccount = auth.savedAccounts.first(where: {
        $0.accountKey == normalizedEmail
    }) {
        existingAccount.updateEmail(account.email)
        existingAccount.updatePlanType(account.planType)
        auth.updateSelectedAccount(existingAccount.id)
        return didAccountIdentityChange(from: priorAccount, to: existingAccount)
    }

    let normalizedCurrentAccount = CodexAccount(
        accountKey: normalizedEmail,
        email: account.email,
        planType: account.planType
    )
    auth.updateDetachedAccount(normalizedCurrentAccount)
    return didAccountIdentityChange(from: priorAccount, to: normalizedCurrentAccount)
}

@MainActor
private func didAccountIdentityChange(
    from previousAccount: CodexAccount?,
    to currentAccount: CodexAccount?
) -> Bool {
    switch (previousAccount, currentAccount) {
    case (.none, .none):
        return false
    case (.some, .none), (.none, .some):
        return true
    case let (previousAccount?, currentAccount?):
        return previousAccount.accountKey != currentAccount.accountKey
    }
}

@MainActor
private func resolvedAccounts(
    for accountKey: String,
    in auth: CodexReviewAuthModel
) -> [CodexAccount] {
    auth.savedAccounts.filter { $0.accountKey == accountKey }
}

@MainActor
private func resolvedSavedAccount(
    for accountKey: String,
    in auth: CodexReviewAuthModel
) -> CodexAccount? {
    auth.savedAccounts.first(where: { $0.accountKey == accountKey })
}

private func rateLimitWindowRecords(
    from snapshot: AppServerRateLimitSnapshotPayload?
) -> [ReviewSavedRateLimitWindowRecord] {
    rateLimits(from: snapshot).map {
        .init(
            windowDurationMinutes: $0.windowDurationMinutes,
            usedPercent: $0.usedPercent,
            resetsAt: $0.resetsAt
        )
    }
}

private func makeAuthProgress(_ progress: ReviewAuthProgress) -> CodexReviewAuthModel.Progress {
    .init(
        title: progress.title,
        detail: progress.detail,
        browserURL: progress.browserURL
    )
}

private func normalizedRateLimitID(_ limitID: String?) -> String {
    guard let limitID, limitID.isEmpty == false else {
        return "codex"
    }
    return limitID
}

private func isCodexRateLimit(_ limitID: String?) -> Bool {
    normalizedRateLimitID(limitID) == "codex"
}

@MainActor
private func applyRateLimits(
    from response: AppServerAccountRateLimitsResponse,
    to account: CodexAccount
) {
    applyRateLimits(
        from: resolvedCodexSnapshot(from: response),
        to: account
    )
}

@MainActor
private func applyRateLimits(
    from snapshot: AppServerRateLimitSnapshotPayload?,
    to account: CodexAccount
) {
    account.updateRateLimits(rateLimits(from: snapshot))
    account.updateRateLimitFetchMetadata(
        fetchedAt: Date(),
        error: nil
    )
}

private func resolvedCodexSnapshot(
    from response: AppServerAccountRateLimitsResponse
) -> AppServerRateLimitSnapshotPayload? {
    if isCodexRateLimit(response.rateLimits.limitID) {
        return response.rateLimits
    }

    guard let rateLimitsByLimitID = response.rateLimitsByLimitID else {
        return nil
    }

    if let codexSnapshot = rateLimitsByLimitID["codex"] {
        return codexSnapshot
    }

    for (limitID, snapshot) in rateLimitsByLimitID {
        if isCodexRateLimit(limitID) || isCodexRateLimit(snapshot.limitID) {
            return snapshot
        }
    }

    return nil
}

private func rateLimits(
    from snapshot: AppServerRateLimitSnapshotPayload?
) -> [(windowDurationMinutes: Int, usedPercent: Int, resetsAt: Date?)] {
    var resolved: [(windowDurationMinutes: Int, usedPercent: Int, resetsAt: Date?)] = []

    if let primary = snapshot?.primary,
       let duration = primary.windowDurationMins
    {
        resolved.append((
            windowDurationMinutes: duration,
            usedPercent: primary.usedPercent,
            resetsAt: primary.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        ))
    }

    if let secondary = snapshot?.secondary,
       let duration = secondary.windowDurationMins
    {
        resolved.append((
            windowDurationMinutes: duration,
            usedPercent: secondary.usedPercent,
            resetsAt: secondary.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        ))
    }

    return resolved
}

private func shouldRetryRateLimitObservation(after error: Error) -> Bool {
    let message = error.localizedDescription.lowercased()
    return message.contains("disconnected") || message.contains("closed")
}

private extension AppServerResponseError {
    var isRateLimitAuthenticationRequired: Bool {
        message.range(
            of: "authentication required to read rate limits",
            options: [.caseInsensitive]
        ) != nil
    }
}
