import Foundation
import ReviewApplication
import ReviewAppServerAdapter
import ReviewDomain
import ReviewPlatform
import ReviewMCPAdapter

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
package final class ReviewMonitorAuthOrchestrator: ReviewMonitorAuthCoordinating {
    package enum RuntimeBridge {
        case live(any ReviewMonitorAuthRuntimeManaging)
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
        let coreDependencies = configuration.coreDependencies
        self.probeAppServerManagerFactory = probeAppServerManagerFactory ?? { environment in
            AppServerSupervisor(
                configuration: .init(
                    codexCommand: codexCommand,
                    environment: environment,
                    coreDependencies: coreDependencies.replacingEnvironment(environment)
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
                    sourceAuthURL: reviewAuthURL(environment: commitProbe.environment),
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
                await refreshAccountRateLimits(auth: auth, accountKey: savedAccount.accountKey)
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
                await refreshAccountRateLimits(auth: auth, accountKey: savedAccount.accountKey)
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
            if auth.persistedAccounts.contains(where: { $0.accountKey == accountKey }) {
                auth.selectPersistedAccount(
                    auth.persistedAccounts.first(where: { $0.accountKey == accountKey })?.id
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
            auth.applyPersistedAccountStates(
                loaded.accounts,
                activeAccountKey: loaded.activeAccountKey
            )
            if let priorAccount,
               auth.persistedAccounts.contains(where: { $0.accountKey == priorAccount.accountKey })
            {
                auth.selectPersistedAccount(
                    auth.persistedAccounts.first(where: { $0.accountKey == priorAccount.accountKey })?.id
                )
                replacementSavedAccount = auth.selectedAccount
            } else if startedWithoutCurrentSession {
                auth.selectPersistedAccount(nil)
            } else if removedCurrentSession {
                if let activeAccountKey = loaded.activeAccountKey,
                   auth.persistedAccounts.contains(where: { $0.accountKey == activeAccountKey })
                {
                    auth.selectPersistedAccount(
                        auth.persistedAccounts.first(where: { $0.accountKey == activeAccountKey })?.id
                    )
                    replacementSavedAccount = auth.selectedAccount
                } else {
                    auth.selectPersistedAccount(nil)
                }
            } else if let priorAccount {
                auth.updateCurrentAccount(priorAccount)
            } else {
                auth.selectPersistedAccount(nil)
            }
        }
        if removedCurrentSession {
            if let replacementSavedAccount {
                try? await accountRegistryStore.restoreSharedAuthFromSavedAccount(
                    replacementSavedAccount.accountKey
                )
            } else {
                try? configuration.coreDependencies.fileSystem.removeItem(
                    configuration.coreDependencies.paths.reviewAuthURL()
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

    package func reorderPersistedAccount(
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
                let sharedAuthURL = configuration.coreDependencies.paths.reviewAuthURL()
                if configuration.coreDependencies.fileSystem.fileExists(sharedAuthURL.path) {
                    try configuration.coreDependencies.fileSystem.removeItem(sharedAuthURL)
                }
            }
            if let loaded = try? accountRegistryStore.loadAccounts() {
                auth.applyPersistedAccountStates(
                    loaded.accounts,
                    activeAccountKey: loaded.activeAccountKey
                )
            } else {
                auth.applyPersistedAccountStates([], activeAccountKey: nil)
            }
            auth.selectPersistedAccount(nil)
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

    package func refreshAccountRateLimits(
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
                let sharedAuthURL = configuration.coreDependencies.paths.reviewAuthURL()
                let persistedActiveAccountKey = persistedActiveAccountKey()
                let selectedSavedAccountKey = auth.persistedAccounts.contains(where: {
                    $0.accountKey == activeAccountKey
                }) ? activeAccountKey : nil
                if let selectedSavedAccountKey,
                   selectedSavedAccountKey != persistedActiveAccountKey
                {
                    probe = try await accountRegistryStore.prepareInactiveAccountProbe(
                        accountKey: selectedSavedAccountKey
                    )
                } else if configuration.coreDependencies.fileSystem.fileExists(sharedAuthURL.path) {
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
            && auth.persistedAccounts.contains(where: { $0.accountKey == accountKey })
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
                auth.persistedAccounts
            },
            refreshRateLimits: { [weak self, weak auth] accountKey in
                guard let self, let auth else {
                    return
                }
                await self.refreshAccountRateLimits(
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
                let sharedAuthURL = configuration.coreDependencies.paths.reviewAuthURL()
                if configuration.coreDependencies.fileSystem.fileExists(sharedAuthURL.path) {
                    try? configuration.coreDependencies.fileSystem.removeItem(sharedAuthURL)
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
                await refreshAccountRateLimits(auth: auth, accountKey: activeAccountKey)
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
                auth.selectPersistedAccount(persistedActiveAccountKey())
            }
            auth.updateWarning(message: nil)
            if resolvedAuthenticatedState || auth.isAuthenticated {
                auth.updatePhase(.failed(message: error.localizedDescription))
            } else {
                auth.updatePhase(.signedOut)
                auth.selectPersistedAccount(nil)
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
                try? configuration.coreDependencies.fileSystem.removeItem(
                    configuration.coreDependencies.paths.reviewAuthURL()
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
                try? configuration.coreDependencies.fileSystem.removeItem(
                    configuration.coreDependencies.paths.reviewAuthURL()
                )
            }
            if let loaded = try? accountRegistryStore.loadAccounts() {
                auth.applyPersistedAccountStates(
                    loaded.accounts,
                    activeAccountKey: loaded.activeAccountKey
                )
            } else {
                auth.applyPersistedAccountStates([], activeAccountKey: nil)
            }
            auth.selectPersistedAccount(nil)
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
        let coreDependencies = configuration.coreDependencies.replacingEnvironment(environment)
        return ReviewAuthManager(
            configuration: .init(
                codexCommand: configuration.codexCommand,
                environment: environment,
                coreDependencies: coreDependencies
            ),
            sessionFactory: {
                try await sessionFactory(environment)
            }
        )
    }

    private func reviewAuthURL(environment: [String: String]) -> URL {
        configuration.coreDependencies
            .replacingEnvironment(environment)
            .paths
            .reviewAuthURL()
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
        if priorSnapshot.persistedAccounts.contains(where: {
            $0.accountKey == priorCurrentAccount.accountKey
        }) {
            return true
        }
        let activeAccountKey = priorSnapshot.persistedActiveAccountKey
            ?? persistedActiveAccountKey()
        return activeAccountKey == nil
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
           auth.persistedAccounts.contains(where: { $0.accountKey == activeAccountKey })
        {
            auth.selectPersistedAccount(
                auth.persistedAccounts.first(where: { $0.accountKey == activeAccountKey })?.id
            )
        } else if let savedAccountKey,
                  auth.persistedAccounts.contains(where: { $0.accountKey == savedAccountKey })
        {
            auth.selectPersistedAccount(
                auth.persistedAccounts.first(where: { $0.accountKey == savedAccountKey })?.id
            )
        } else {
            auth.selectPersistedAccount(nil)
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
            auth.selectPersistedAccount(nil)
            return
        }
        if let currentSavedAccount = auth.persistedAccounts.first(where: {
            $0.accountKey == priorCurrentAccount.accountKey
        }) {
            auth.selectPersistedAccount(currentSavedAccount.id)
            return
        }
        auth.updateCurrentAccount(priorCurrentAccount)
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
                uniqueKeysWithValues: auth.persistedAccounts.map { ($0.accountKey, $0) }
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
            auth.applyPersistedAccountStates(
                reconciledAccounts,
                activeAccountKey: loaded.activeAccountKey
            )
            if let priorAccount,
               let currentSavedAccount = auth.persistedAccounts.first(where: {
                   $0.accountKey == priorAccount.accountKey
               })
            {
                auth.selectPersistedAccount(currentSavedAccount.id)
            } else if shouldPreserveMissingPriorAccount {
                auth.updateCurrentAccount(priorAccount)
            } else if preserveSelectedAccountIfMissing == false {
                auth.selectPersistedAccount(nil)
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
