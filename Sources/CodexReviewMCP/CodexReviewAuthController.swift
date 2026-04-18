import CodexReviewModel
import Foundation
import ReviewCore
import ReviewHTTPServer
import ReviewJobs

@MainActor
struct CodexAuthRuntimeState {
    var serverIsRunning: Bool
    var runtimeGeneration: Int

    static let stopped = Self(
        serverIsRunning: false,
        runtimeGeneration: 0
    )
}

@MainActor
package final class CodexAuthController: CodexReviewAuthControlling {
    private let configuration: ReviewServerConfiguration
    private let accountRegistryStore: ReviewAccountRegistryStore
    private let sharedAuthSessionFactory: @Sendable ([String: String]) async throws -> any ReviewAuthSession
    private let loginAuthSessionFactory: @Sendable ([String: String]) async throws -> any ReviewAuthSession
    private let probeAppServerManagerFactory: @Sendable ([String: String]) -> any AppServerManaging
    private let accountSessionController: CodexAccountSessionController
    private let runtimeState: @MainActor @Sendable () -> CodexAuthRuntimeState
    private let recycleServerIfRunning: @MainActor @Sendable () async -> Void
    private let cancelRunningJobs: @MainActor @Sendable (String) async throws -> Void
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
        runtimeState: @escaping @MainActor @Sendable () -> CodexAuthRuntimeState,
        recycleServerIfRunning: @escaping @MainActor @Sendable () async -> Void,
        cancelRunningJobs: @escaping @MainActor @Sendable (String) async throws -> Void = { _ in },
        rateLimitObservationClock: any ReviewClock = ContinuousClock(),
        rateLimitStaleRefreshInterval: Duration = .seconds(60)
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
        accountSessionController = CodexAccountSessionController(
            appServerManager: appServerManager,
            accountRegistryStore: accountRegistryStore,
            clock: rateLimitObservationClock,
            staleRefreshInterval: rateLimitStaleRefreshInterval
        )
        self.runtimeState = runtimeState
        self.recycleServerIfRunning = recycleServerIfRunning
        self.cancelRunningJobs = cancelRunningJobs
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

    package func beginAuthentication(auth: CodexReviewAuthModel) async {
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
            let shouldActivateAuthenticatedAccount = shouldActivateAuthenticatedAccount(
                priorSnapshot: priorSnapshot,
                completedAccount: completedAccount
            )
            let priorCurrentAccount = auth.account
            guard let commitProbe = takeAuthenticationProbeForCommit(authenticationAttemptID) else {
                throw ReviewAuthError.cancelled
            }
            auth.updatePhase(.signedOut)
            defer {
                Task {
                    await self.accountRegistryStore.cleanupProbeHome(commitProbe)
                }
            }

            let savedAccount: CodexAccount
            do {
                savedAccount = try accountRegistryStore.saveAuthSnapshot(
                    sourceAuthURL: ReviewHomePaths.reviewAuthURL(environment: commitProbe.environment),
                    makeActive: shouldActivateAuthenticatedAccount
                )
            } catch {
                throw ReviewAuthError.loginFailed(reviewAuthPersistenceFailureMessage)
            }

            if shouldActivateAuthenticatedAccount {
                let warningMessage = await performCommittedJobCleanupIfNeeded(shouldCancelJobs: true)
                await applyCommittedActiveAccount(
                    auth: auth,
                    savedAccount: savedAccount,
                    priorAccount: priorCurrentAccount,
                    forceRecycleServer: runtimeState().serverIsRunning
                )
                if let warningMessage {
                    auth.updateWarning(message: warningMessage)
                }
                return
            }

            await refreshSavedAccounts(auth: auth)
            if let priorAccountKey = priorCurrentAccount?.accountKey,
               let activeAccount = auth.savedAccounts.first(where: { $0.accountKey == priorAccountKey })
            {
                auth.updateAccount(activeAccount)
            } else if let priorCurrentAccount,
                      auth.savedAccounts.contains(where: { $0.accountKey == priorCurrentAccount.accountKey }) == false
            {
                auth.updateAccount(priorCurrentAccount)
            }
            auth.updatePhase(.signedOut)
            auth.updateWarning(message: nil)
            await refreshSavedAccountRateLimits(auth: auth, accountKey: savedAccount.accountKey)
            hasResolvedAuthenticatedAccount = auth.account != nil
            await reconcileAfterResolvedAuthState(
                auth: auth,
                identityChanged: false
            )
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
        guard auth.account?.accountKey != accountKey else {
            return
        }
        let loadedAccounts = try accountRegistryStore.loadAccounts()
        guard loadedAccounts.accounts.contains(where: { $0.accountKey == accountKey }) else {
            throw ReviewAuthError.authenticationRequired("Saved account was not found.")
        }
        let priorAccount = auth.account
        try await accountRegistryStore.activateAccount(accountKey)
        let warningMessage = await performCommittedJobCleanupIfNeeded(shouldCancelJobs: true)
        if runtimeState().serverIsRunning {
            await applyCommittedActiveAccount(
                auth: auth,
                savedAccount: loadedAccounts.accounts.first(where: { $0.accountKey == accountKey }),
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
        let removedActive = auth.account?.accountKey == accountKey
        let priorUnsavedCurrentAccount = auth.account.flatMap { currentAccount in
            auth.savedAccounts.contains(where: { $0.accountKey == currentAccount.accountKey })
                ? nil
                : currentAccount
        }
        _ = try await accountRegistryStore.removeAccount(accountKey)
        if let loaded = try? accountRegistryStore.loadAccounts() {
            auth.updateSavedAccounts(loaded.accounts)
            if let activeAccountKey = loaded.activeAccountKey,
               let activeAccount = loaded.accounts.first(where: { $0.accountKey == activeAccountKey })
            {
                auth.updateAccount(activeAccount)
            } else if let priorUnsavedCurrentAccount,
                      loaded.accounts.contains(where: { $0.accountKey == priorUnsavedCurrentAccount.accountKey }) == false
            {
                auth.updateAccount(priorUnsavedCurrentAccount)
            } else {
                auth.updateAccount(nil)
            }
        }
        if removedActive {
            auth.updatePhase(.signedOut)
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
        } else {
            auth.updateWarning(message: nil)
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
        await refreshSavedAccounts(auth: auth, preserveCurrentWhenEmpty: true)
    }

    package func signOutActiveAccount(auth: CodexReviewAuthModel) async throws {
        guard auth.account != nil else {
            return
        }
        cancelStartupRefresh()
        auth.updateWarning(message: nil)
        if auth.isAuthenticating {
            await cancelAuthentication(auth: auth)
        }
        var didCompleteLogout = false
        let signedOutAccount = auth.account
        let hasSavedSignedOutAccount = signedOutAccount.map { signedOutAccount in
            auth.savedAccounts.contains(where: { $0.accountKey == signedOutAccount.accountKey })
        } ?? false
        do {
            let authManager = makeAuthManager(
                environment: configuration.environment,
                sessionFactory: sharedAuthSessionFactory
            )
            _ = try await authManager.logout()
            didCompleteLogout = true
            if let signedOutAccountKey = signedOutAccount?.accountKey, hasSavedSignedOutAccount {
                _ = try await accountRegistryStore.removeAccount(signedOutAccountKey)
            } else {
                try await accountRegistryStore.clearActiveAccount()
            }
            if let loaded = try? accountRegistryStore.loadAccounts() {
                auth.updateSavedAccounts(loaded.accounts)
            } else {
                auth.updateSavedAccounts([])
            }
            auth.updateAccount(nil)
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
                logoutCompleted: didCompleteLogout
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
                logoutCompleted: didCompleteLogout
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
        let isActiveAccount = auth.account?.accountKey == accountKey
        let priorUnsavedCurrentAccount = auth.account.flatMap { currentAccount in
            auth.savedAccounts.contains(where: { $0.accountKey == currentAccount.accountKey })
                ? nil
                : currentAccount
        }
        if isActiveAccount,
           let activeAccount = auth.account
        {
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
                    applyRateLimits(from: response, to: activeAccount)
                    try? accountRegistryStore.updateCachedRateLimits(from: activeAccount)
                } catch let error as AppServerResponseError where error.isUnsupportedMethod || error.isRateLimitAuthenticationRequired {
                    activeAccount.updateRateLimitFetchMetadata(
                        fetchedAt: Date(),
                        error: error.message
                    )
                    if error.isUnsupportedMethod || error.isRateLimitAuthenticationRequired {
                        activeAccount.clearRateLimits()
                    }
                    try? accountRegistryStore.updateCachedRateLimits(from: activeAccount)
                } catch {
                    activeAccount.updateRateLimitFetchMetadata(
                        fetchedAt: Date(),
                        error: error.localizedDescription
                    )
                    try? accountRegistryStore.updateCachedRateLimits(from: activeAccount)
                }
                await refreshSavedAccounts(auth: auth, preserveCurrentWhenEmpty: true)
                return
            }

            let fetchedAt = Date()
            do {
                let probe: PreparedInactiveAccountProbe
                let sharedAuthURL = ReviewHomePaths.reviewAuthURL(environment: configuration.environment)
                if FileManager.default.fileExists(atPath: sharedAuthURL.path) {
                    probe = try await accountRegistryStore.prepareSharedAuthProbe()
                } else if auth.savedAccounts.contains(where: { $0.accountKey == activeAccount.accountKey }) {
                    probe = try await accountRegistryStore.prepareInactiveAccountProbe(
                        accountKey: activeAccount.accountKey
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
                    applyRateLimits(from: response, to: activeAccount)
                    try? accountRegistryStore.updateCachedRateLimits(from: activeAccount)
                } catch let error as AppServerResponseError where error.isUnsupportedMethod || error.isRateLimitAuthenticationRequired {
                    activeAccount.updateRateLimitFetchMetadata(
                        fetchedAt: fetchedAt,
                        error: error.message
                    )
                    if error.isUnsupportedMethod || error.isRateLimitAuthenticationRequired {
                        activeAccount.clearRateLimits()
                    }
                    try? accountRegistryStore.updateCachedRateLimits(from: activeAccount)
                } catch {
                    activeAccount.updateRateLimitFetchMetadata(
                        fetchedAt: fetchedAt,
                        error: error.localizedDescription
                    )
                    try? accountRegistryStore.updateCachedRateLimits(from: activeAccount)
                }
                if let sharedSession {
                    await sharedSession.close()
                }
                await probeManager.shutdown()
                await accountRegistryStore.cleanupProbeHome(probe)
            } catch {
                activeAccount.updateRateLimitFetchMetadata(
                    fetchedAt: fetchedAt,
                    error: error.localizedDescription
                )
                try? accountRegistryStore.updateCachedRateLimits(from: activeAccount)
            }
            await refreshSavedAccounts(auth: auth, preserveCurrentWhenEmpty: true)
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
        if let priorUnsavedCurrentAccount,
           auth.savedAccounts.contains(where: { $0.accountKey == priorUnsavedCurrentAccount.accountKey }) == false
        {
            auth.updateAccount(priorUnsavedCurrentAccount)
        }
    }

    package func reconcileAuthenticatedSession(
        auth: CodexReviewAuthModel,
        serverIsRunning: Bool,
        runtimeGeneration: Int
        ) async {
        await accountSessionController.reconcile(
            serverIsRunning: serverIsRunning,
            accountKey: auth.account?.accountKey,
            runtimeGeneration: runtimeGeneration,
            accountResolver: { accountKey in
                resolvedAccount(for: accountKey, in: auth)
            }
        )
    }

    private func refreshResolvedState(
        auth: CodexReviewAuthModel,
        forceRestartSession: Bool = false,
        forceRecycleServer: Bool = false,
        allowDuringAuthentication: Bool = false
    ) async {
        do {
            let authManager = makeAuthManager(
                environment: configuration.environment,
                sessionFactory: sharedAuthSessionFactory
            )
            let state = try await authManager.loadState()
            let priorAccount = auth.account
            if auth.isAuthenticating, allowDuringAuthentication == false {
                return
            }
            if state.account != nil {
                _ = try? accountRegistryStore.saveSharedAuthAsSavedAccount(makeActive: true)
            } else if forceRecycleServer == false {
                try? await accountRegistryStore.clearActiveAccount()
            }
            await refreshSavedAccounts(
                auth: auth,
                preserveCurrentWhenEmpty: state.isAuthenticated
            )
            _ = applyResolvedReviewAuthState(
                state,
                activeAccountKey: auth.savedAccounts.first(where: \.isActive)?.accountKey,
                priorResolvedAuthenticatedAccount: hasResolvedAuthenticatedAccount,
                preferActiveAccountSelection: forceRecycleServer,
                to: auth
            )
            auth.updateWarning(message: nil)
            let identityChanged = didAccountIdentityChange(from: priorAccount, to: auth.account)
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
               let activeAccountKey = auth.account?.accountKey,
               runtimeState().serverIsRunning
            {
                await refreshSavedAccountRateLimits(auth: auth, accountKey: activeAccountKey)
            }
            if forceRecycleServer {
                let postRecycleState = try await authManager.loadState()
                if postRecycleState.isAuthenticated == false {
                    try? await accountRegistryStore.clearActiveAccount()
                }
                await refreshSavedAccounts(
                    auth: auth,
                    preserveCurrentWhenEmpty: postRecycleState.isAuthenticated
                )
                _ = applyResolvedReviewAuthState(
                    postRecycleState,
                    activeAccountKey: auth.savedAccounts.first(where: \.isActive)?.accountKey,
                    priorResolvedAuthenticatedAccount: hasResolvedAuthenticatedAccount,
                    preferActiveAccountSelection: false,
                    to: auth
                )
                auth.updateWarning(message: nil)
                hasResolvedAuthenticatedAccount = postRecycleState.isAuthenticated
                let resolvedRuntimeState = runtimeState()
                await accountSessionController.reconcile(
                    serverIsRunning: resolvedRuntimeState.serverIsRunning,
                    accountKey: auth.account?.accountKey,
                    runtimeGeneration: resolvedRuntimeState.runtimeGeneration,
                    accountResolver: { accountKey in
                        resolvedAccount(for: accountKey, in: auth)
                    }
                )
            }
        } catch {
            guard auth.isAuthenticating == false || allowDuringAuthentication else {
                return
            }
            await refreshSavedAccounts(auth: auth, preserveCurrentWhenEmpty: true)
            if auth.account == nil,
               let preservedAccount = auth.savedAccounts.first(where: \.isActive)
            {
                auth.updateAccount(preservedAccount)
            }
            auth.updateWarning(message: nil)
            if auth.isAuthenticated {
                auth.updatePhase(.failed(message: error.localizedDescription))
            } else {
                auth.updatePhase(.signedOut)
                auth.updateAccount(nil)
            }
            await reconcileAfterResolvedAuthState(
                auth: auth,
                identityChanged: false,
                forceRestartSession: forceRestartSession,
                forceRecycleServer: forceRecycleServer
            )
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
            await accountSessionController.reconcile(
                serverIsRunning: false,
                accountKey: auth.account?.accountKey,
                runtimeGeneration: currentRuntimeState.runtimeGeneration,
                accountResolver: { accountKey in
                    resolvedAccount(for: accountKey, in: auth)
                }
            )
            if identityChanged || forceRecycleServer {
                await recycleServerIfRunning()
            }
        }

        if skipFinalAttach {
            return
        }

        let resolvedRuntimeState = runtimeState()
        await accountSessionController.reconcile(
            serverIsRunning: resolvedRuntimeState.serverIsRunning,
            accountKey: auth.account?.accountKey,
            runtimeGeneration: resolvedRuntimeState.runtimeGeneration,
            accountResolver: { accountKey in
                resolvedAccount(for: accountKey, in: auth)
            }
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
        logoutCompleted: Bool = false
    ) async {
        let hadAuthenticatedAccount = auth.account != nil
        let priorAccountKey = priorAccount?.accountKey
        let authManager = makeAuthManager(
            environment: configuration.environment,
            sessionFactory: sharedAuthSessionFactory
        )
        if let resolvedState = try? await authManager.loadState() {
            if resolvedState.isAuthenticated {
                _ = try? accountRegistryStore.saveSharedAuthAsSavedAccount(makeActive: true)
            } else if let priorAccountKey {
                _ = try? await accountRegistryStore.removeAccount(priorAccountKey)
            } else {
                try? await accountRegistryStore.clearActiveAccount()
            }
            await refreshSavedAccounts(
                auth: auth,
                preserveCurrentWhenEmpty: resolvedState.isAuthenticated
            )
            _ = applyResolvedReviewAuthState(
                resolvedState,
                activeAccountKey: auth.savedAccounts.first(where: \.isActive)?.accountKey,
                priorResolvedAuthenticatedAccount: hasResolvedAuthenticatedAccount,
                preferActiveAccountSelection: false,
                to: auth
            )
            let identityChanged = didAccountIdentityChange(from: priorAccount, to: auth.account)
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
            if let priorAccountKey {
                _ = try? await accountRegistryStore.removeAccount(priorAccountKey)
            } else {
                try? await accountRegistryStore.clearActiveAccount()
            }
            if let loaded = try? accountRegistryStore.loadAccounts() {
                auth.updateSavedAccounts(loaded.accounts)
            } else {
                auth.updateSavedAccounts([])
            }
            auth.updateAccount(nil)
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

    private func shouldActivateAuthenticatedAccount(
        priorSnapshot: AuthPresentationSnapshot,
        completedAccount: ReviewAuthAccount
    ) -> Bool {
        guard let currentAccount = priorSnapshot.account else {
            return true
        }
        if case .failed = priorSnapshot.phase {
            return true
        }
        return normalizedReviewAccountEmail(email: currentAccount.email)
            == normalizedReviewAccountEmail(email: completedAccount.email)
    }

    private func applyCommittedActiveAccount(
        auth: CodexReviewAuthModel,
        savedAccount: CodexAccount?,
        priorAccount: CodexAccount?,
        forceRecycleServer: Bool
    ) async {
        if runtimeState().serverIsRunning {
            await refreshResolvedState(
                auth: auth,
                forceRestartSession: true,
                forceRecycleServer: forceRecycleServer,
                allowDuringAuthentication: true
            )
            return
        }

        await refreshSavedAccounts(auth: auth)
        if let activeAccount = auth.savedAccounts.first(where: \.isActive) {
            auth.updateAccount(activeAccount)
        } else if let savedAccountKey = savedAccount?.accountKey,
                  let resolvedSavedAccount = auth.savedAccounts.first(where: { $0.accountKey == savedAccountKey })
        {
            auth.updateAccount(resolvedSavedAccount)
        }
        auth.updatePhase(.signedOut)
        auth.updateWarning(message: nil)
        hasResolvedAuthenticatedAccount = auth.account != nil
        await reconcileAfterResolvedAuthState(
            auth: auth,
            identityChanged: didAccountIdentityChange(from: priorAccount, to: auth.account)
        )
    }

    private func performCommittedJobCleanupIfNeeded(shouldCancelJobs: Bool) async -> String? {
        guard shouldCancelJobs else {
            return nil
        }
        do {
            try await cancelRunningJobs("Account change requested.")
            return nil
        } catch {
            return error.localizedDescription.nilIfEmpty ?? "Failed to cancel running reviews."
        }
    }

    private func refreshSavedAccounts(
        auth: CodexReviewAuthModel,
        preserveCurrentWhenEmpty: Bool = false
    ) async {
        if let loaded = try? accountRegistryStore.loadAccounts() {
            let priorAccount = auth.account
            let loadedAccounts = loaded.accounts.map { loadedAccount in
                guard let priorAccount,
                      priorAccount.accountKey == loadedAccount.accountKey
                else {
                    return loadedAccount
                }
                if shouldPreferInMemoryRateLimitState(
                    priorAccount: priorAccount,
                    loadedAccount: loadedAccount
                ) {
                    loadedAccount.updateRateLimits(
                        priorAccount.rateLimits.map {
                            (
                                windowDurationMinutes: $0.windowDurationMinutes,
                                usedPercent: $0.usedPercent,
                                resetsAt: $0.resetsAt
                            )
                        }
                    )
                    loadedAccount.updateRateLimitFetchMetadata(
                        fetchedAt: priorAccount.lastRateLimitFetchAt,
                        error: priorAccount.lastRateLimitError
                    )
                }
                return loadedAccount
            }
            let priorAccountKey = priorAccount?.accountKey
            auth.updateSavedAccounts(loadedAccounts)
            if let activeAccountKey = loaded.activeAccountKey,
               let loadedActiveAccount = loadedAccounts.first(where: { $0.accountKey == activeAccountKey })
            {
                auth.updateAccount(loadedActiveAccount)
                return
            }

            if let priorAccountKey,
               let resolvedSavedAccount = loadedAccounts.first(where: { $0.accountKey == priorAccountKey })
            {
                auth.updateAccount(resolvedSavedAccount)
            } else if preserveCurrentWhenEmpty, let priorAccount {
                auth.updateAccount(priorAccount)
            } else {
                auth.updateAccount(nil)
            }
        }
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
        loadedAccount: CodexAccount
    ) -> Bool {
        switch (priorAccount.lastRateLimitFetchAt, loadedAccount.lastRateLimitFetchAt) {
        case let (priorFetchedAt?, loadedFetchedAt?):
            return priorFetchedAt > loadedFetchedAt
        case (.some, nil):
            return true
        default:
            return false
        }
    }
}

@MainActor
private final class CodexAccountSessionController {
    typealias AccountResolver = @MainActor @Sendable (String) -> CodexAccount?

    private struct AttachmentTarget: Equatable {
        var accountKey: String
        var runtimeGeneration: Int
    }

    private enum RateLimitsReadCapability {
        case unknown
        case supported
        case unsupported
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

        let shouldAttach = serverIsRunning && desiredTarget != nil
        if shouldAttach == false || desiredTarget != activeTarget {
            await detach()
            activeTarget = shouldAttach ? desiredTarget : nil
        }
        self.accountResolver = shouldAttach ? accountResolver : nil

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

    private func resolveCurrentAccount(for target: AttachmentTarget) -> CodexAccount? {
        accountResolver?(target.accountKey)
    }

    private func attach(
        target: AttachmentTarget
    ) async {
        guard resolveCurrentAccount(for: target) != nil else {
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
        let subscription = await session.notificationStream()
        defer {
            Task {
                await subscription.cancel()
            }
        }

        do {
            let response = try await session.readRateLimits()
            guard isCurrent(target: target),
                  let account = resolveCurrentAccount(for: target)
            else {
                return
            }
            rateLimitsReadCapability = .supported
            applyRateLimits(from: response, to: account)
            try? accountRegistryStore.updateSavedAccountMetadata(from: account)
            try? accountRegistryStore.updateCachedRateLimits(from: account)
            scheduleStaleRefresh(
                target: target,
                session: session
            )
        } catch let error as AppServerResponseError where error.isUnsupportedMethod {
            guard isCurrent(target: target),
                  let account = resolveCurrentAccount(for: target)
            else {
                return
            }
            rateLimitsReadCapability = .unsupported
            account.clearRateLimits()
            account.updateRateLimitFetchMetadata(
                fetchedAt: Date(),
                error: error.message
            )
            try? accountRegistryStore.updateCachedRateLimits(from: account)
        } catch let error as AppServerResponseError where error.isRateLimitAuthenticationRequired {
            guard isCurrent(target: target),
                  let account = resolveCurrentAccount(for: target)
            else {
                return
            }
            account.clearRateLimits()
            account.updateRateLimitFetchMetadata(
                fetchedAt: Date(),
                error: error.message
            )
            try? accountRegistryStore.updateCachedRateLimits(from: account)
            return
        } catch is CancellationError {
            return
        } catch {
            guard isCurrent(target: target),
                  let account = resolveCurrentAccount(for: target)
            else {
                return
            }
            account.updateRateLimitFetchMetadata(
                fetchedAt: Date(),
                error: error.localizedDescription
            )
            try? accountRegistryStore.updateCachedRateLimits(from: account)
            shouldRetry = true
            return
        }

        guard isCurrent(target: target) else {
            return
        }

        do {
            for try await notification in subscription.stream {
                guard case .accountRateLimitsUpdated(let payload) = notification else {
                    continue
                }
                guard isCurrent(target: target),
                      let account = resolveCurrentAccount(for: target)
                else {
                    return
                }
                guard isCodexRateLimit(payload.rateLimits.limitID) else {
                    continue
                }
                applyRateLimits(from: payload.rateLimits, to: account)
                try? accountRegistryStore.updateCachedRateLimits(from: account)
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
        rateLimitsReadCapability = .unknown
        observerTask = nil
        observerTransport = nil
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
                  self.isCurrent(target: target),
                  let account = self.resolveCurrentAccount(for: target)
            else {
                return
            }

            do {
                let response = try await session.readRateLimits()
                guard self.staleRefreshTaskID == taskID,
                      self.isCurrent(target: target),
                      let currentAccount = self.resolveCurrentAccount(for: target)
                else {
                    return
                }
                self.rateLimitsReadCapability = .supported
                applyRateLimits(from: response, to: currentAccount)
                try? self.accountRegistryStore.updateCachedRateLimits(from: currentAccount)
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
                account.clearRateLimits()
                account.updateRateLimitFetchMetadata(
                    fetchedAt: Date(),
                    error: error.message
                )
                try? self.accountRegistryStore.updateCachedRateLimits(from: account)
                self.staleRefreshTask = nil
                self.staleRefreshTaskID = nil
            } catch let error as AppServerResponseError where error.isRateLimitAuthenticationRequired {
                guard self.staleRefreshTaskID == taskID,
                      self.isCurrent(target: target)
                else {
                    return
                }
                account.clearRateLimits()
                account.updateRateLimitFetchMetadata(
                    fetchedAt: Date(),
                    error: error.message
                )
                try? self.accountRegistryStore.updateCachedRateLimits(from: account)
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
                account.updateRateLimitFetchMetadata(
                    fetchedAt: Date(),
                    error: error.localizedDescription
                )
                try? self.accountRegistryStore.updateCachedRateLimits(from: account)
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

private struct AuthPresentationSnapshot {
    var phase: CodexReviewAuthModel.Phase
    var savedAccounts: [SavedAccountPresentationSnapshot]
    var account: ReviewAuthAccount?
    var warningMessage: String?
    var isResolvedAuthenticated: Bool
}

private struct SavedAccountPresentationSnapshot {
    var accountKey: String
    var email: String
    var planType: String?
    var isActive: Bool
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
        account: auth.account.map(makeReviewAuthAccount),
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
    let savedAccounts = snapshot.savedAccounts.map(makeCodexAccount)
    auth.updateSavedAccounts(savedAccounts)
    if let account = snapshot.account {
        _ = applyReviewAuthAccount(
            account,
            activeAccountKey: savedAccounts.first(where: \.isActive)?.accountKey,
            preferActiveAccountSelection: false,
            to: auth
        )
    } else {
        auth.updateAccount(nil)
    }
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
        auth.updateAccount(nil)
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
    let priorAccount = auth.account
    if preferActiveAccountSelection,
       activeAccountKey == nil
    {
        auth.updateAccount(nil)
        return didAccountIdentityChange(from: priorAccount, to: nil)
    }
    let normalizedEmail = normalizedReviewAccountEmail(email: account.email)

    if let activeAccountKey,
       activeAccountKey == normalizedEmail,
       let existingAccount = auth.savedAccounts.first(where: { $0.accountKey == activeAccountKey })
    {
        existingAccount.updateEmail(account.email)
        existingAccount.updatePlanType(account.planType)
        auth.updateAccount(existingAccount)
        return didAccountIdentityChange(from: priorAccount, to: existingAccount)
    }

    if let existingAccount = auth.savedAccounts.first(where: {
        $0.accountKey == normalizedEmail
    }) {
        existingAccount.updateEmail(account.email)
        existingAccount.updatePlanType(account.planType)
        auth.updateAccount(existingAccount)
        return didAccountIdentityChange(from: priorAccount, to: existingAccount)
    }

    let createdAccount = CodexAccount(
        email: account.email,
        planType: account.planType
    )
    auth.updateAccount(createdAccount)
    return didAccountIdentityChange(from: priorAccount, to: createdAccount)
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
        isActive: account.isActive,
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
private func makeCodexAccount(_ snapshot: SavedAccountPresentationSnapshot) -> CodexAccount {
    let account = CodexAccount(
        accountKey: snapshot.accountKey,
        email: snapshot.email,
        planType: snapshot.planType
    )
    account.updateIsActive(snapshot.isActive)
    account.updateRateLimits(
        snapshot.rateLimits.map {
            (
                windowDurationMinutes: $0.windowDurationMinutes,
                usedPercent: $0.usedPercent,
                resetsAt: $0.resetsAt
            )
        }
    )
    account.updateRateLimitFetchMetadata(
        fetchedAt: snapshot.lastRateLimitFetchAt,
        error: snapshot.lastRateLimitError
    )
    return account
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
private func resolvedAccount(
    for accountKey: String,
    in auth: CodexReviewAuthModel
) -> CodexAccount? {
    if let savedAccount = auth.savedAccounts.first(where: { $0.accountKey == accountKey }) {
        return savedAccount
    }
    if auth.account?.accountKey == accountKey {
        return auth.account
    }
    return nil
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
