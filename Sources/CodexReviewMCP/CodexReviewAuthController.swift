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
    private let accountSessionController: CodexAccountSessionController
    private let runtimeState: @MainActor @Sendable () -> CodexAuthRuntimeState
    private let recycleServerIfRunning: @MainActor @Sendable () async -> Void
    private var refreshTask: Task<Void, Never>?
    private var refreshTaskID: UUID?
    private var authenticationCancellationRestoreState: AuthPresentationSnapshot?
    private var activeAuthenticationManager: ReviewAuthManager?
    private var activeAuthenticationProbe: PreparedInactiveAccountProbe?
    private var hasResolvedAuthenticatedAccount = false

    init(
        configuration: ReviewServerConfiguration,
        accountRegistryStore: ReviewAccountRegistryStore,
        appServerManager: any AppServerManaging,
        sharedAuthSessionFactory: @escaping @Sendable ([String: String]) async throws -> any ReviewAuthSession,
        loginAuthSessionFactory: @escaping @Sendable ([String: String]) async throws -> any ReviewAuthSession,
        runtimeState: @escaping @MainActor @Sendable () -> CodexAuthRuntimeState,
        recycleServerIfRunning: @escaping @MainActor @Sendable () async -> Void,
        rateLimitObservationClock: any ReviewClock = ContinuousClock(),
        rateLimitStaleRefreshInterval: Duration = .seconds(60)
    ) {
        self.configuration = configuration
        self.accountRegistryStore = accountRegistryStore
        self.sharedAuthSessionFactory = sharedAuthSessionFactory
        self.loginAuthSessionFactory = loginAuthSessionFactory
        accountSessionController = CodexAccountSessionController(
            appServerManager: appServerManager,
            accountRegistryStore: accountRegistryStore,
            clock: rateLimitObservationClock,
            staleRefreshInterval: rateLimitStaleRefreshInterval
        )
        self.runtimeState = runtimeState
        self.recycleServerIfRunning = recycleServerIfRunning
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
        let priorSnapshot = snapshot(
            from: auth,
            isResolvedAuthenticated: hasResolvedAuthenticatedAccount
        )
        authenticationCancellationRestoreState = priorSnapshot
        defer {
            authenticationCancellationRestoreState = nil
            activeAuthenticationManager = nil
            if let activeAuthenticationProbe {
                Task {
                    await self.accountRegistryStore.cleanupProbeHome(activeAuthenticationProbe)
                }
                self.activeAuthenticationProbe = nil
            }
        }

        do {
            let loginProbe = try await accountRegistryStore.prepareAuthenticationLoginProbe()
            activeAuthenticationProbe = loginProbe
            let authManager = makeAuthManager(
                environment: loginProbe.environment,
                sessionFactory: loginAuthSessionFactory
            )
            activeAuthenticationManager = authManager
            let runtimeGenerationBeforeAuthentication = runtimeState().runtimeGeneration
            var completedAccount: ReviewAuthAccount?
            try await authManager.beginAuthentication { state in
                await MainActor.run {
                    if case .signedIn(let account) = state {
                        completedAccount = account
                    }
                    self.applyAuthenticationProgressState(state, to: auth)
                }
            }
            let savedAccount: CodexAccount
            let persistedSavedAccount: Bool
            do {
                savedAccount = try accountRegistryStore.saveAuthSnapshot(
                    sourceAuthURL: ReviewHomePaths.reviewAuthURL(environment: loginProbe.environment),
                    makeActive: hasResolvedAuthenticatedAccount == false
                        && (auth.account == nil || auth.errorMessage != nil)
                )
                persistedSavedAccount = true
            } catch {
                guard let completedAccount else {
                    throw error
                }
                savedAccount = CodexAccount(
                    email: completedAccount.email,
                    planType: completedAccount.planType
                )
                let existing = auth.savedAccounts.filter { $0.accountKey != savedAccount.accountKey }
                auth.updateSavedAccounts(existing + [savedAccount])
                if auth.account == nil || auth.account?.accountKey == savedAccount.accountKey {
                    auth.updateAccount(savedAccount)
                }
                persistedSavedAccount = false
            }
            if persistedSavedAccount, auth.account?.accountKey == savedAccount.accountKey {
                try await accountRegistryStore.activateAccount(savedAccount.accountKey)
            }
            let priorAccountKey = priorSnapshot.account.map { normalizedReviewAccountKey(email: $0.email) }
            let identityChanged = priorAccountKey != auth.account?.accountKey
            await refreshSavedAccounts(
                auth: auth,
                preserveCurrentWhenEmpty: persistedSavedAccount == false
            )
            if auth.account == nil || auth.account?.accountKey == savedAccount.accountKey {
                await refreshResolvedState(
                    auth: auth,
                    forceRestartSession: true,
                    forceRecycleServer: auth.hasSavedAccounts
                )
                let resolvedRuntimeState = runtimeState()
                if resolvedRuntimeState.serverIsRunning,
                   resolvedRuntimeState.runtimeGeneration == runtimeGenerationBeforeAuthentication
                {
                    await recycleServerIfRunning()
                    let postRecycleRuntimeState = runtimeState()
                    await accountSessionController.reconcile(
                        serverIsRunning: postRecycleRuntimeState.serverIsRunning,
                        account: auth.account,
                        runtimeGeneration: postRecycleRuntimeState.runtimeGeneration
                    )
                }
                return
            }
            auth.updatePhase(.signedOut)
            await reconcileAfterResolvedAuthState(
                auth: auth,
                identityChanged: identityChanged,
                forceRestartSession: false,
                forceRecycleServer: false
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
            updateAuthenticationFailureState(error, auth: auth)
            await reconcileAfterResolvedAuthState(
                auth: auth,
                identityChanged: false
            )
        }
    }

    package func cancelAuthentication(auth: CodexReviewAuthModel) async {
        let restoreState = authenticationCancellationRestoreState ?? snapshot(
            from: auth,
            isResolvedAuthenticated: hasResolvedAuthenticatedAccount
        )
        await activeAuthenticationManager?.cancelAuthentication()
        hasResolvedAuthenticatedAccount = restoreState.isResolvedAuthenticated
        restore(auth: auth, from: restoreState)
        await reconcileAfterResolvedAuthState(
            auth: auth,
            identityChanged: false
        )
        activeAuthenticationManager = nil
        if let activeAuthenticationProbe {
            await accountRegistryStore.cleanupProbeHome(activeAuthenticationProbe)
            self.activeAuthenticationProbe = nil
        }
    }

    package func switchAccount(
        auth: CodexReviewAuthModel,
        accountKey: String
    ) async throws {
        cancelStartupRefresh()
        if auth.isAuthenticating {
            await cancelAuthentication(auth: auth)
        }
        guard auth.account?.accountKey != accountKey else {
            return
        }
        try await accountRegistryStore.activateAccount(accountKey)
        await refreshSavedAccounts(auth: auth)
        await refreshResolvedState(
            auth: auth,
            forceRestartSession: true,
            forceRecycleServer: true
        )
    }

    package func removeAccount(
        auth: CodexReviewAuthModel,
        accountKey: String
    ) async throws {
        cancelStartupRefresh()
        if auth.isAuthenticating {
            await cancelAuthentication(auth: auth)
        }
        let removedActive = auth.account?.accountKey == accountKey
        _ = try await accountRegistryStore.removeAccount(accountKey)
        if let loaded = try? accountRegistryStore.loadAccounts() {
            auth.updateSavedAccounts(loaded.accounts)
            if let activeAccountKey = loaded.activeAccountKey,
               let activeAccount = loaded.accounts.first(where: { $0.accountKey == activeAccountKey })
            {
                auth.updateAccount(activeAccount)
            } else if loaded.accounts.isEmpty {
                auth.updateSavedAccounts([])
                auth.updateAccount(nil)
            }
        }
        await refreshResolvedState(
            auth: auth,
            forceRestartSession: removedActive,
            forceRecycleServer: removedActive
        )
    }

    package func signOutActiveAccount(auth: CodexReviewAuthModel) async throws {
        guard let activeAccountKey = auth.account?.accountKey else {
            return
        }
        cancelStartupRefresh()
        if auth.isAuthenticating {
            authenticationCancellationRestoreState = nil
            await activeAuthenticationManager?.cancelAuthentication()
            activeAuthenticationManager = nil
            auth.updatePhase(.signedOut)
        }
        do {
            let authManager = makeAuthManager(
                environment: configuration.environment,
                sessionFactory: sharedAuthSessionFactory
            )
            _ = try await authManager.logout()
            try await accountRegistryStore.clearActiveAccount()
            if let loaded = try? accountRegistryStore.loadAccounts() {
                auth.updateSavedAccounts(loaded.accounts)
                auth.updateAccount(nil)
                auth.updatePhase(.signedOut)
                hasResolvedAuthenticatedAccount = false
                await reconcileAfterResolvedAuthState(
                    auth: auth,
                    identityChanged: true,
                    forceRestartSession: true,
                    forceRecycleServer: true
                )
            } else {
                auth.updateAccount(nil)
                auth.updatePhase(.signedOut)
                hasResolvedAuthenticatedAccount = false
                await reconcileAfterResolvedAuthState(
                    auth: auth,
                    identityChanged: true,
                    forceRestartSession: true,
                    forceRecycleServer: true
                )
            }
        } catch let error as ReviewAuthError {
            let message = error.errorDescription ?? "Failed to sign out."
            await resolveLogoutFailureState(
                auth: auth,
                message: message
            )
            throw error
        } catch {
            let message = error.localizedDescription
            await resolveLogoutFailureState(
                auth: auth,
                message: message
            )
            throw error
        }
    }

    package func refreshSavedAccountRateLimits(
        auth: CodexReviewAuthModel,
        accountKey: String
    ) async {
        if auth.account?.accountKey == accountKey {
            if let activeAccount = auth.account {
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
                    if error.isRateLimitAuthenticationRequired {
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
                await refreshSavedAccounts(auth: auth)
            }
            return
        }

        let fetchedAt = Date()
        do {
            let probe = try await accountRegistryStore.prepareInactiveAccountProbe(accountKey: accountKey)
            defer {
                Task {
                    await self.accountRegistryStore.cleanupProbeHome(probe)
                }
            }
            let supervisor = AppServerSupervisor(
                configuration: .init(
                    codexCommand: configuration.codexCommand,
                    environment: probe.environment
                )
            )
            defer {
                Task {
                    await supervisor.shutdown()
                }
            }
            let transport = try await supervisor.checkoutAuthTransport()
            let sharedSession = SharedAppServerReviewAuthSession(transport: transport)
            defer {
                Task {
                    await sharedSession.close()
                }
            }
            let rateLimits = try await sharedSession.readRateLimits()
            try await accountRegistryStore.updateCachedRateLimits(
                accountKey: accountKey,
                rateLimits: rateLimitWindowRecords(from: resolvedCodexSnapshot(from: rateLimits)),
                fetchedAt: fetchedAt,
                error: nil
            )
        } catch let error as AppServerResponseError where error.isUnsupportedMethod {
            try? await accountRegistryStore.updateRateLimitFetchStatus(
                accountKey: accountKey,
                fetchedAt: fetchedAt,
                error: error.message
            )
        } catch let error as AppServerResponseError where error.isRateLimitAuthenticationRequired {
            try? await accountRegistryStore.updateCachedRateLimits(
                accountKey: accountKey,
                rateLimits: [],
                fetchedAt: fetchedAt,
                error: error.message
            )
        } catch {
            try? await accountRegistryStore.updateRateLimitFetchStatus(
                accountKey: accountKey,
                fetchedAt: fetchedAt,
                error: error.localizedDescription
            )
        }
        await refreshSavedAccounts(auth: auth)
    }

    package func reconcileAuthenticatedSession(
        auth: CodexReviewAuthModel,
        serverIsRunning: Bool,
        runtimeGeneration: Int
        ) async {
        await accountSessionController.reconcile(
            serverIsRunning: serverIsRunning,
            account: auth.account,
            runtimeGeneration: runtimeGeneration
        )
    }

    private func refreshResolvedState(
        auth: CodexReviewAuthModel,
        forceRestartSession: Bool = false,
        forceRecycleServer: Bool = false
    ) async {
        do {
            let authManager = makeAuthManager(
                environment: configuration.environment,
                sessionFactory: sharedAuthSessionFactory
            )
            let state = try await authManager.loadState()
            if auth.isAuthenticating {
                return
            }
            if state.account != nil {
                _ = try? accountRegistryStore.saveSharedAuthAsSavedAccount(makeActive: true)
            }
            await refreshSavedAccounts(
                auth: auth,
                preserveCurrentWhenEmpty: state.isAuthenticated
            )
            let identityChanged = applyResolvedReviewAuthState(
                state,
                activeAccountKey: auth.savedAccounts.first(where: \.isActive)?.accountKey,
                priorResolvedAuthenticatedAccount: hasResolvedAuthenticatedAccount,
                to: auth
            )
            hasResolvedAuthenticatedAccount = state.isAuthenticated
            await reconcileAfterResolvedAuthState(
                auth: auth,
                identityChanged: identityChanged,
                forceRestartSession: forceRestartSession || state.isAuthenticated,
                forceRecycleServer: forceRecycleServer
            )
            if forceRecycleServer {
                let postRecycleState = try await authManager.loadState()
                await refreshSavedAccounts(
                    auth: auth,
                    preserveCurrentWhenEmpty: postRecycleState.isAuthenticated
                )
                _ = applyResolvedReviewAuthState(
                    postRecycleState,
                    activeAccountKey: auth.savedAccounts.first(where: \.isActive)?.accountKey,
                    priorResolvedAuthenticatedAccount: hasResolvedAuthenticatedAccount,
                    to: auth
                )
                hasResolvedAuthenticatedAccount = postRecycleState.isAuthenticated
                let resolvedRuntimeState = runtimeState()
                await accountSessionController.reconcile(
                    serverIsRunning: resolvedRuntimeState.serverIsRunning,
                    account: auth.account,
                    runtimeGeneration: resolvedRuntimeState.runtimeGeneration
                )
            }
        } catch {
            guard auth.isAuthenticating == false else {
                return
            }
            await refreshSavedAccounts(auth: auth, preserveCurrentWhenEmpty: true)
            if auth.account == nil,
               let preservedAccount = auth.savedAccounts.first(where: \.isActive) ?? auth.savedAccounts.first
            {
                auth.updateAccount(preservedAccount)
            }
            if auth.isAuthenticated {
                auth.updatePhase(.failed(message: error.localizedDescription))
            } else {
                auth.updatePhase(.signedOut)
                auth.updateAccount(nil)
            }
            await reconcileAfterResolvedAuthState(
                auth: auth,
                identityChanged: false
            )
        }
    }

    private func reconcileAfterResolvedAuthState(
        auth: CodexReviewAuthModel,
        identityChanged: Bool,
        forceRestartSession: Bool = false,
        forceRecycleServer: Bool = false
    ) async {
        let currentRuntimeState = runtimeState()
        if currentRuntimeState.serverIsRunning,
           identityChanged || forceRestartSession
        {
            await accountSessionController.reconcile(
                serverIsRunning: false,
                account: auth.account,
                runtimeGeneration: currentRuntimeState.runtimeGeneration
            )
            if identityChanged || forceRecycleServer {
                await recycleServerIfRunning()
            }
        }

        let resolvedRuntimeState = runtimeState()
        await accountSessionController.reconcile(
            serverIsRunning: resolvedRuntimeState.serverIsRunning,
            account: auth.account,
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
        auth.updatePhase(.failed(message: message))
    }

    private func resolveLogoutFailureState(
        auth: CodexReviewAuthModel,
        message: String
    ) async {
        let hadAuthenticatedAccount = auth.account != nil
        let authManager = makeAuthManager(
            environment: configuration.environment,
            sessionFactory: sharedAuthSessionFactory
        )
        if let resolvedState = try? await authManager.loadState() {
            await refreshSavedAccounts(
                auth: auth,
                preserveCurrentWhenEmpty: resolvedState.isAuthenticated
            )
            let identityChanged = applyResolvedReviewAuthState(
                resolvedState,
                activeAccountKey: auth.savedAccounts.first(where: \.isActive)?.accountKey,
                priorResolvedAuthenticatedAccount: hasResolvedAuthenticatedAccount,
                to: auth
            )
            hasResolvedAuthenticatedAccount = resolvedState.isAuthenticated
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

    private func refreshSavedAccounts(
        auth: CodexReviewAuthModel,
        preserveCurrentWhenEmpty: Bool = false
    ) async {
        if let loaded = try? accountRegistryStore.loadAccounts() {
            if loaded.accounts.isEmpty, preserveCurrentWhenEmpty {
                return
            }
            if let activeAccountKey = loaded.activeAccountKey,
               let loadedActiveAccount = loaded.accounts.first(where: { $0.accountKey == activeAccountKey })
            {
                if let currentAccount = auth.account,
                   currentAccount.accountKey == activeAccountKey
                {
                    currentAccount.updatePlanType(loadedActiveAccount.planType)
                    currentAccount.updateRateLimits(
                        loadedActiveAccount.rateLimits.map {
                            (
                                windowDurationMinutes: $0.windowDurationMinutes,
                                usedPercent: $0.usedPercent,
                                resetsAt: $0.resetsAt
                            )
                        }
                    )
                    currentAccount.updateRateLimitFetchMetadata(
                        fetchedAt: loadedActiveAccount.lastRateLimitFetchAt,
                        error: loadedActiveAccount.lastRateLimitError
                    )
                    let reconciledAccounts = loaded.accounts.map { account in
                        account.accountKey == currentAccount.accountKey ? currentAccount : account
                    }
                    auth.updateSavedAccounts(reconciledAccounts)
                    auth.updateAccount(currentAccount)
                    return
                }
                auth.updateSavedAccounts(loaded.accounts)
                auth.updateAccount(loadedActiveAccount)
            } else if auth.savedAccounts.contains(where: { $0.accountKey == auth.account?.accountKey }) == false {
                auth.updateSavedAccounts(loaded.accounts)
                auth.updateAccount(nil)
            } else {
                auth.updateSavedAccounts(loaded.accounts)
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
            auth.updatePhase(.signedOut)
        }
    }
}

@MainActor
private final class CodexAccountSessionController {
    private struct AttachmentTarget: Equatable {
        var accountID: ObjectIdentifier
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
        account: CodexAccount?,
        runtimeGeneration: Int
    ) async {
        let desiredTarget = account.map {
            AttachmentTarget(
                accountID: ObjectIdentifier($0),
                runtimeGeneration: runtimeGeneration
            )
        }

        let shouldAttach = serverIsRunning && desiredTarget != nil
        if shouldAttach == false || desiredTarget != activeTarget {
            await detach()
            activeTarget = shouldAttach ? desiredTarget : nil
        }

        guard shouldAttach,
              let account,
              let target = activeTarget,
              observerTask == nil,
              observerTransport == nil,
              retryTask == nil
        else {
            return
        }

        await attach(account: account, target: target)
    }

    private func detach() async {
        retryTask?.cancel()
        retryTask = nil
        staleRefreshTask?.cancel()
        staleRefreshTask = nil
        staleRefreshTaskID = nil
        rateLimitsReadCapability = .unknown
        let task = observerTask
        observerTask = nil
        let transport = observerTransport
        observerTransport = nil
        task?.cancel()
        if let transport {
            await transport.close()
        }
    }

    private func attach(
        account: CodexAccount,
        target: AttachmentTarget
    ) async {
        do {
            let transport = try await appServerManager.checkoutAuthTransport()
            guard isCurrent(target: target, account: account) else {
                await transport.close()
                return
            }
            observerTransport = transport
            observerTask = Task { @MainActor [weak self, weak account] in
                guard let self, let account else {
                    return
                }
                await self.runObservation(
                    account: account,
                    target: target,
                    transport: transport
                )
            }
        } catch {
            scheduleRetry(account: account, target: target)
        }
    }

    private func runObservation(
        account: CodexAccount,
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
                scheduleRetry(account: account, target: target)
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
            guard isCurrent(target: target, account: account) else {
                return
            }
            rateLimitsReadCapability = .supported
            applyRateLimits(from: response, to: account)
            try? accountRegistryStore.updateSavedAccountMetadata(from: account)
            try? accountRegistryStore.updateCachedRateLimits(from: account)
            scheduleStaleRefresh(
                account: account,
                target: target,
                session: session
            )
        } catch let error as AppServerResponseError where error.isUnsupportedMethod {
            guard isCurrent(target: target, account: account) else {
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
            guard isCurrent(target: target, account: account) else {
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
            guard isCurrent(target: target, account: account) else {
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

        guard isCurrent(target: target, account: account) else {
            return
        }

        do {
            for try await notification in subscription.stream {
                guard case .accountRateLimitsUpdated(let payload) = notification else {
                    continue
                }
                guard isCurrent(target: target, account: account) else {
                    return
                }
                guard isCodexRateLimit(payload.rateLimits.limitID) else {
                    continue
                }
                applyRateLimits(from: payload.rateLimits, to: account)
                try? accountRegistryStore.updateCachedRateLimits(from: account)
                if rateLimitsReadCapability != .unsupported {
                    scheduleStaleRefresh(
                        account: account,
                        target: target,
                        session: session
                    )
                }
            }
            guard isCurrent(target: target, account: account) else {
                return
            }
            shouldRetry = true
        } catch is CancellationError {
            return
        } catch {
            guard isCurrent(target: target, account: account),
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
        account: CodexAccount,
        target: AttachmentTarget,
        session: SharedAppServerReviewAuthSession
    ) {
        guard rateLimitsReadCapability != .unsupported else {
            return
        }
        staleRefreshTask?.cancel()
        let taskID = UUID()
        staleRefreshTaskID = taskID
        staleRefreshTask = Task { @MainActor [weak self, weak account] in
            guard let self else {
                return
            }
            do {
                try await self.clock.sleep(for: self.staleRefreshInterval)
            } catch {
                return
            }
            guard let account else {
                return
            }

            guard self.staleRefreshTaskID == taskID,
                  self.isCurrent(target: target, account: account)
            else {
                return
            }

            do {
                let response = try await session.readRateLimits()
                guard self.staleRefreshTaskID == taskID,
                      self.isCurrent(target: target, account: account)
                else {
                    return
                }
                self.rateLimitsReadCapability = .supported
                applyRateLimits(from: response, to: account)
                try? self.accountRegistryStore.updateCachedRateLimits(from: account)
                self.staleRefreshTask = nil
                self.staleRefreshTaskID = nil
                self.scheduleStaleRefresh(
                    account: account,
                    target: target,
                    session: session
                )
            } catch let error as AppServerResponseError where error.isUnsupportedMethod {
                guard self.staleRefreshTaskID == taskID,
                      self.isCurrent(target: target, account: account)
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
                      self.isCurrent(target: target, account: account)
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
                      self.isCurrent(target: target, account: account)
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
                    account: account,
                    target: target,
                    session: session
                )
            }
        }
    }

    private func scheduleRetry(
        account: CodexAccount,
        target: AttachmentTarget
    ) {
        guard activeTarget == target,
              retryTask == nil
        else {
            return
        }

        retryTask = Task { @MainActor [weak self, weak account] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard let self, let account else {
                return
            }
            self.retryTask = nil
            guard self.isCurrent(target: target, account: account) else {
                return
            }
            await self.attach(account: account, target: target)
        }
    }

    private func isCurrent(
        target: AttachmentTarget,
        account: CodexAccount
    ) -> Bool {
        activeTarget == target && ObjectIdentifier(account) == target.accountID
    }

    func checkoutActiveRateLimitTransport() async throws -> any AppServerSessionTransport {
        try await appServerManager.checkoutAuthTransport()
    }
}

private struct AuthPresentationSnapshot {
    var phase: CodexReviewAuthModel.Phase
    var account: ReviewAuthAccount?
    var isResolvedAuthenticated: Bool
}

@MainActor
private func snapshot(
    from auth: CodexReviewAuthModel,
    isResolvedAuthenticated: Bool
) -> AuthPresentationSnapshot {
    .init(
        phase: auth.phase,
        account: auth.account.map(makeReviewAuthAccount),
        isResolvedAuthenticated: isResolvedAuthenticated
    )
}

@MainActor
private func restore(
    auth: CodexReviewAuthModel,
    from snapshot: AuthPresentationSnapshot
) {
    auth.updatePhase(snapshot.phase)
    if let account = snapshot.account {
        _ = applyReviewAuthAccount(
            account,
            activeAccountKey: auth.savedAccounts.first(where: \.isActive)?.accountKey,
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
    to auth: CodexReviewAuthModel
) -> Bool {
    let resolvedAccountKey = normalizedReviewAccountKey(email: account.email)
    let targetAccountKey = activeAccountKey == resolvedAccountKey ? activeAccountKey : resolvedAccountKey
    let priorAccountKey = auth.account?.accountKey
    if let existingAccount = auth.savedAccounts.first(where: { $0.accountKey == targetAccountKey }) {
        if existingAccount.email != account.email {
            let replacementAccount = CodexAccount(
                email: account.email,
                planType: account.planType
            )
            let otherAccounts = auth.savedAccounts.filter { $0.accountKey != existingAccount.accountKey }
            auth.updateSavedAccounts(otherAccounts + [replacementAccount])
            auth.updateAccount(replacementAccount)
            return priorAccountKey != replacementAccount.accountKey
        }
        existingAccount.updatePlanType(account.planType)
        auth.updateAccount(existingAccount)
        return priorAccountKey != existingAccount.accountKey
    }
    let createdAccount = CodexAccount(
        email: account.email,
        planType: account.planType
    )
    auth.updateSavedAccounts(auth.savedAccounts + [createdAccount])
    auth.updateAccount(createdAccount)
    return priorAccountKey != createdAccount.accountKey
}

@MainActor
private func makeReviewAuthAccount(_ account: CodexAccount) -> ReviewAuthAccount {
    .init(
        email: account.email,
        planType: account.planType
    )
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
