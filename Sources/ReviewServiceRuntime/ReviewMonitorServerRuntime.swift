import Foundation
import ObservationBridge
import ReviewApplication
import ReviewAppServerAdapter
import ReviewDomain
import ReviewPlatform
import ReviewMCPAdapter

@MainActor
package final class ReviewMonitorServerRuntime: ReviewMonitorServerCoordinating, ReviewMonitorSettingsBackend, ReviewMonitorAuthRuntimeManaging {
    private struct DeferredAddAccountRuntimeEffect {
        var accountKey: String
        var runtimeGeneration: Int
    }

    let configuration: ReviewServerConfiguration
    let appServerManager: any AppServerManaging
    let accountRegistryStore: ReviewAccountRegistryStore
    let sharedAuthSessionFactory: (@Sendable ([String: String]) async throws -> any ReviewAuthSession)?
    let loginAuthSessionFactory: (@Sendable ([String: String]) async throws -> any ReviewAuthSession)?
    let deferStartupAuthRefreshUntilPrepared: Bool
    let shouldAutoStartEmbeddedServer: Bool
    let initialAccount: CodexAccount?
    let initialAccounts: [CodexAccount]
    let initialActiveAccountKey: String?
    let rateLimitObservationClock: any ReviewClock
    let rateLimitStaleRefreshInterval: Duration
    let inactiveRateLimitRefreshInterval: Duration
    weak var authOrchestrator: ReviewMonitorAuthOrchestrator?
    weak var settingsService: ReviewMonitorSettingsService?
    var executionCoordinator: ReviewExecutionCoordinator?
    lazy var liveSharedAuthSessionFactory: @Sendable ([String: String]) async throws -> any ReviewAuthSession = { [weak self, appServerManager, configuration] environment in
        let makeCLISession = {
            CLIReviewAuthSession(
                configuration: .init(
                    codexCommand: configuration.codexCommand,
                    environment: environment,
                    coreDependencies: configuration.coreDependencies.replacingEnvironment(environment)
                )
            )
        }
        let shouldUseSharedRuntime = await MainActor.run {
            self?.authRuntimeState.serverIsRunning ?? false
        }
        let shouldProbeInjectedManager = (appServerManager is AppServerSupervisor) == false
        guard shouldUseSharedRuntime || shouldProbeInjectedManager else {
            return makeCLISession()
        }
        do {
            let transport = try await appServerManager.checkoutAuthTransport()
            return SharedAppServerReviewAuthSession(transport: transport)
        } catch {
            guard shouldUseSharedRuntime else {
                return makeCLISession()
            }
            throw error
        }
    }
    lazy var liveCLIAuthSessionFactory: @Sendable ([String: String]) async throws -> any ReviewAuthSession = { [configuration] environment in
        CLIReviewAuthSession(
            configuration: .init(
                codexCommand: configuration.codexCommand,
                environment: environment,
                coreDependencies: configuration.coreDependencies.replacingEnvironment(environment)
            )
        )
    }

    private var server: ReviewMCPHTTPServer?
    private var waitTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var startupTaskID: UInt64?
    private var nextStartupTaskID: UInt64 = 0
    private var appServerRuntimeGeneration = 0
    private var deferredAddAccountRuntimeEffect: DeferredAddAccountRuntimeEffect?
    private var deferredAddAccountRuntimeReconcileTask: Task<Void, Never>?
    private weak var attachedStore: CodexReviewStore?
    private var observedHasRunningJobs: Bool?
    private let observationScope = ObservationScope()
    private var discoveryFileURL: URL {
        configuration.coreDependencies.paths.discoveryFileURL()
    }
    private var runtimeStateFileURL: URL {
        configuration.coreDependencies.paths.runtimeStateFileURL()
    }
    private var discoveryClient: ReviewDiscoveryClient {
        ReviewDiscoveryClient(dependencies: configuration.coreDependencies)
    }
    private var runtimeStateClient: ReviewRuntimeStateClient {
        ReviewRuntimeStateClient(dependencies: configuration.coreDependencies)
    }
    private var localConfigClient: ReviewLocalConfigClient {
        ReviewLocalConfigClient(dependencies: configuration.coreDependencies)
    }
    private var codexHomeURL: URL {
        configuration.coreDependencies.paths.codexHomeURL()
    }
    var currentServer: ReviewMCPHTTPServer? {
        server
    }
    package var authRuntimeState: CodexAuthRuntimeState {
        .init(
            serverIsRunning: server != nil,
            runtimeGeneration: appServerRuntimeGeneration
        )
    }

    package func resolveAddAccountRuntimeEffect(
        accountKey: String,
        runtimeGeneration: Int
    ) -> CodexAuthRuntimeEffect {
        if attachedStore?.hasRunningJobs ?? false {
            return .deferRecycleUntilJobsDrain(
                accountKey: accountKey,
                runtimeGeneration: runtimeGeneration
            )
        }
        return .recycleNow(
            accountKey: accountKey,
            runtimeGeneration: runtimeGeneration
        )
    }

    package func applyAddAccountRuntimeEffect(
        _ effect: CodexAuthRuntimeEffect,
        auth: CodexReviewAuthModel
    ) async {
        switch effect {
        case .none:
            scheduleDeferredAddAccountRuntimeReconciliationIfNeeded()
        case .deferRecycleUntilJobsDrain(let accountKey, let runtimeGeneration):
            cancelDeferredAddAccountRuntimeReconcileTask()
            deferredAddAccountRuntimeEffect = .init(
                accountKey: accountKey,
                runtimeGeneration: runtimeGeneration
            )
            scheduleDeferredAddAccountRuntimeReconciliationIfNeeded()
        case .recycleNow(let accountKey, let runtimeGeneration):
            cancelDeferredAddAccountRuntimeReconcileTask()
            guard let store = attachedStore,
                  authRuntimeState.serverIsRunning,
                  authRuntimeState.runtimeGeneration == runtimeGeneration,
                  auth.selectedAccount?.accountKey == accountKey
            else {
                deferredAddAccountRuntimeEffect = nil
                return
            }
            guard store.hasRunningJobs == false else {
                deferredAddAccountRuntimeEffect = .init(
                    accountKey: accountKey,
                    runtimeGeneration: runtimeGeneration
                )
                scheduleDeferredAddAccountRuntimeReconciliationIfNeeded()
                return
            }
            deferredAddAccountRuntimeEffect = nil
            await recycleSharedAppServerAfterAuthChange()
            await authOrchestrator?.reconcileAuthenticatedSession(
                auth: store.auth,
                serverIsRunning: authRuntimeState.serverIsRunning,
                runtimeGeneration: authRuntimeState.runtimeGeneration
            )
            await reconcileDeferredAddAccountRuntimeEffectIfNeeded(store: store)
        }
    }

    fileprivate func scheduleDeferredAddAccountRuntimeReconciliationIfNeeded() {
        guard deferredAddAccountRuntimeEffect != nil,
              deferredAddAccountRuntimeReconcileTask == nil,
              let store = attachedStore,
              authRuntimeState.serverIsRunning,
              store.hasRunningJobs == false
        else {
            return
        }
        deferredAddAccountRuntimeReconcileTask = Task { @MainActor [weak self, weak store] in
            guard let self, let store else {
                return
            }
            defer {
                self.deferredAddAccountRuntimeReconcileTask = nil
            }
            await self.reconcileDeferredAddAccountRuntimeEffectIfNeeded(store: store)
        }
    }

    private func cancelDeferredAddAccountRuntimeReconcileTask() {
        deferredAddAccountRuntimeReconcileTask?.cancel()
        deferredAddAccountRuntimeReconcileTask = nil
    }

    private func reconcileDeferredAddAccountRuntimeEffectIfNeeded(
        store: CodexReviewStore
    ) async {
        guard let deferredAddAccountRuntimeEffect else {
            return
        }
        guard authRuntimeState.serverIsRunning,
              authRuntimeState.runtimeGeneration == deferredAddAccountRuntimeEffect.runtimeGeneration,
              store.auth.selectedAccount?.accountKey == deferredAddAccountRuntimeEffect.accountKey
        else {
            self.deferredAddAccountRuntimeEffect = nil
            return
        }
        guard store.hasRunningJobs == false else {
            return
        }
        self.deferredAddAccountRuntimeEffect = nil
        await recycleSharedAppServerAfterAuthChange()
        await authOrchestrator?.reconcileAuthenticatedSession(
            auth: store.auth,
            serverIsRunning: authRuntimeState.serverIsRunning,
            runtimeGeneration: authRuntimeState.runtimeGeneration
        )
    }

    private func reconcileAuthRuntime(
        store: CodexReviewStore,
        serverIsRunning: Bool,
        runtimeGeneration: Int
    ) async {
        if serverIsRunning {
            await reconcileDeferredAddAccountRuntimeEffectIfNeeded(store: store)
        } else {
            cancelDeferredAddAccountRuntimeReconcileTask()
            deferredAddAccountRuntimeEffect = nil
        }
        await authOrchestrator?.reconcileAuthenticatedSession(
            auth: store.auth,
            serverIsRunning: serverIsRunning,
            runtimeGeneration: runtimeGeneration
        )
    }

    package var initialSettingsSnapshot: CodexReviewSettingsSnapshot {
        let localConfig = (try? localConfigClient.load()) ?? .init()
        let fallbackConfig = loadFallbackAppServerConfig(
            environment: configuration.environment,
            codexHome: codexHomeURL
        )
        let profileClearsReviewModel = activeProfileClearsReviewModel(
            environment: configuration.environment,
            codexHome: codexHomeURL
        )
        let profileClearsReasoningEffort = activeProfileClearsReasoningEffort(
            environment: configuration.environment,
            codexHome: codexHomeURL
        )
        let profileClearsServiceTier = activeProfileClearsServiceTier(
            environment: configuration.environment,
            codexHome: codexHomeURL
        )
        let displayedOverrides = resolveDisplayedSettingsOverrides(
            localConfig: localConfig,
            resolvedConfig: fallbackConfig,
            profileClearsReasoningEffort: profileClearsReasoningEffort,
            profileClearsServiceTier: profileClearsServiceTier
        )
        return .init(
            model: resolveReviewModelOverride(
                localConfig: localConfig,
                resolvedConfig: fallbackConfig,
                profileClearsReviewModel: profileClearsReviewModel
            ),
            fallbackModel: fallbackConfig.model?.nilIfEmpty,
            reasoningEffort: displayedOverrides.reasoningEffort,
            serviceTier: displayedOverrides.serviceTier,
            models: []
        )
    }

    package var isActive: Bool {
        server != nil || waitTask != nil || startupTask != nil
    }

    init(dependencies: ReviewServiceRuntimeDependencies) {
        let configuration = dependencies.configuration
        self.configuration = configuration
        self.appServerManager = dependencies.appServerManager
        self.accountRegistryStore = ReviewAccountRegistryStore(coreDependencies: configuration.coreDependencies)
        self.sharedAuthSessionFactory = dependencies.sharedAuthSessionFactory
        self.loginAuthSessionFactory = dependencies.loginAuthSessionFactory
        self.rateLimitObservationClock = dependencies.rateLimitObservationClock
        self.rateLimitStaleRefreshInterval = dependencies.rateLimitStaleRefreshInterval
        self.inactiveRateLimitRefreshInterval = dependencies.inactiveRateLimitRefreshInterval
        self.deferStartupAuthRefreshUntilPrepared = dependencies.deferStartupAuthRefreshUntilPrepared
        self.shouldAutoStartEmbeddedServer = configuration.shouldAutoStartEmbeddedServer
        var seededAccounts = loadRegisteredReviewAccounts(dependencies: configuration.coreDependencies)
        let sharedInitialAccount = loadSharedReviewAccount(dependencies: configuration.coreDependencies)
        var shouldClearInitialSelection = false
        if let sharedInitialAccount {
            let matchingSavedAccount = seededAccounts.accounts.first {
                $0.accountKey == sharedInitialAccount.accountKey
            }
            let activeSavedAccount = seededAccounts.activeAccountKey.flatMap { activeAccountKey in
                seededAccounts.accounts.first(where: { $0.accountKey == activeAccountKey })
            }
            if matchingSavedAccount == nil || activeSavedAccount?.accountKey != matchingSavedAccount?.accountKey {
                do {
                    try accountRegistryStore.saveSharedAuthAsSavedAccount(
                        makeActive: true
                    )
                } catch {
                    shouldClearInitialSelection = false
                }
                seededAccounts = loadRegisteredReviewAccounts(dependencies: configuration.coreDependencies)
            }
        }

        let initialAccounts = seededAccounts.accounts.map(makeCodexAccount)

        let resolvedInitialAccount: CodexAccount? = {
            guard shouldClearInitialSelection == false else {
                return nil
            }
            if let sharedInitialAccount,
               let persistedSharedAccount = initialAccounts.first(where: {
                   $0.accountKey == sharedInitialAccount.accountKey
               })
            {
                return persistedSharedAccount
            }
            if let sharedInitialAccount {
                return sharedInitialAccount
            }
            if let activeAccountKey = seededAccounts.activeAccountKey {
                return initialAccounts
                    .first(where: { $0.accountKey == activeAccountKey })
            }
            return nil
        }()

        let resolvedInitialActiveAccountKey: String? = {
            guard shouldClearInitialSelection == false else {
                return nil
            }
            if let sharedInitialAccount,
               initialAccounts.contains(where: { $0.accountKey == sharedInitialAccount.accountKey })
            {
                return sharedInitialAccount.accountKey
            }
            return seededAccounts.activeAccountKey
        }()

        self.initialAccounts = initialAccounts
        self.initialActiveAccountKey = resolvedInitialActiveAccountKey
        self.initialAccount = resolvedInitialAccount
    }

    package func attachStore(_ store: CodexReviewStore) {
        attachedStore = store
        observedHasRunningJobs = store.hasRunningJobs
        observationScope.cancelAll()
        observeRunningJobs()
    }

    private func observeRunningJobs() {
        guard let attachedStore else {
            return
        }
        attachedStore.observe(\.hasRunningJobs) { [weak self] hasRunningJobs in
            guard let self else {
                return
            }
            guard hasRunningJobs != self.observedHasRunningJobs else {
                return
            }
            self.observedHasRunningJobs = hasRunningJobs
            self.scheduleDeferredAddAccountRuntimeReconciliationIfNeeded()
        }
        .store(in: observationScope)
    }

    package func start(
        store: CodexReviewStore,
        forceRestartIfNeeded: Bool
    ) async {
        if deferStartupAuthRefreshUntilPrepared == false {
            authOrchestrator?.startStartupRefresh(auth: store.auth)
        }
        let startupID = makeStartupTaskID()
        let task = Task { @MainActor [weak self, weak store] in
            guard let self, let store else {
                return
            }
            await self.performStartup(
                startupID: startupID,
                store: store,
                forceRestartIfNeeded: forceRestartIfNeeded
            )
        }
        startupTaskID = startupID
        startupTask = task
        await task.value
        if startupTaskID == startupID {
            startupTask = nil
            startupTaskID = nil
        }
    }

    package func stop(store: CodexReviewStore) async {
        let startupTask = self.startupTask
        self.startupTask = nil
        startupTaskID = nil
        startupTask?.cancel()
        authOrchestrator?.cancelStartupRefresh()
        if store.auth.isAuthenticating {
            await authOrchestrator?.cancelAuthentication(auth: store.auth)
        }
        await reconcileAuthRuntime(
            store: store,
            serverIsRunning: false,
            runtimeGeneration: appServerRuntimeGeneration
        )
        waitTask?.cancel()
        waitTask = nil
        await executionCoordinator?.shutdown(reason: "Review server stopped.", store: store)
        if let server {
            let endpointRecord = server.currentEndpointRecord()
            self.server = nil
            await server.stop()
            await appServerManager.shutdown()
            removeRuntimeState(endpointRecord: endpointRecord)
        } else {
            await appServerManager.shutdown()
        }
        await startupTask?.value
    }

    package func waitUntilStopped() async {
        if let startupTask {
            await startupTask.value
        }
        if let waitTask {
            await waitTask.value
        }
    }

    package func refreshSettings() async throws -> CodexReviewSettingsSnapshot {
        let transport = try await appServerManager.checkoutAuthTransport()
        let localConfig = (try? localConfigClient.load()) ?? .init()
        let fallbackConfig = loadFallbackAppServerConfig(
            environment: configuration.environment,
            codexHome: codexHomeURL
        )
        let configResponse: AppServerConfigReadResponse = try await transport.request(
            method: "config/read",
            params: AppServerConfigReadParams(
                cwd: nil,
                includeLayers: false
            ),
            responseType: AppServerConfigReadResponse.self
        )
        var models: [CodexReviewModelCatalogItem] = []
        var cursor: String?
        repeat {
            let modelResponse: AppServerModelListResponse = try await transport.request(
                method: "model/list",
                params: AppServerModelListParams(
                    cursor: cursor,
                    limit: nil,
                    includeHidden: true
                ),
                responseType: AppServerModelListResponse.self
            )
            models.append(contentsOf: modelResponse.data)
            cursor = modelResponse.nextCursor?.nilIfEmpty
        } while cursor != nil
        let effectiveConfig = mergeAppServerConfig(
            primary: configResponse.config,
            fallback: fallbackConfig
        )
        let profileClearsReviewModel = activeProfileClearsReviewModel(
            environment: configuration.environment,
            codexHome: codexHomeURL
        )
        let profileClearsReasoningEffort = activeProfileClearsReasoningEffort(
            environment: configuration.environment,
            codexHome: codexHomeURL
        )
        let profileClearsServiceTier = activeProfileClearsServiceTier(
            environment: configuration.environment,
            codexHome: codexHomeURL
        )
        let displayedOverrides = resolveDisplayedSettingsOverrides(
            localConfig: localConfig,
            resolvedConfig: effectiveConfig,
            profileClearsReasoningEffort: profileClearsReasoningEffort,
            profileClearsServiceTier: profileClearsServiceTier
        )
        let modelOverride = resolveReviewModelOverride(
            localConfig: localConfig,
            resolvedConfig: effectiveConfig,
            profileClearsReviewModel: profileClearsReviewModel
        )

        return .init(
            model: modelOverride,
            fallbackModel: effectiveConfig.model?.nilIfEmpty,
            reasoningEffort: displayedOverrides.reasoningEffort,
            serviceTier: displayedOverrides.serviceTier,
            models: models
        )
    }

    package func updateSettingsModel(
        _ model: String?,
        reasoningEffort: CodexReviewReasoningEffort?,
        persistReasoningEffort: Bool,
        serviceTier: CodexReviewServiceTier?,
        persistServiceTier: Bool
    ) async throws {
        let profile = loadActiveReviewProfile(
            environment: configuration.environment,
            codexHome: codexHomeURL
        )
        let localConfigPresence = try localConfigClient.loadPresence()
        let hasRootReviewModel = localConfigPresence.hasReviewModel
        let hasProfileReviewModelOverride = activeProfileHasReviewModelOverride(
            environment: configuration.environment,
            codexHome: codexHomeURL
        )
        let writeModelAtRoot = profile == nil
            || (hasRootReviewModel && hasProfileReviewModelOverride == false)
        let hasRootReasoningEffort = localConfigPresence.hasModelReasoningEffort
        let hasProfileReasoningEffortOverride = activeProfileHasReasoningEffortOverride(
            environment: configuration.environment,
            codexHome: codexHomeURL
        )
        let writeReasoningAtRoot = profile == nil
            || (hasRootReasoningEffort && hasProfileReasoningEffortOverride == false)
        let hasRootServiceTier = localConfigPresence.hasServiceTier
        let hasProfileServiceTierOverride = activeProfileHasServiceTierOverride(
            environment: configuration.environment,
            codexHome: codexHomeURL
        )
        let writeServiceTierAtRoot = profile == nil
            || (hasRootServiceTier && hasProfileServiceTierOverride == false)
        var edits: [AppServerConfigEdit] = [
            .init(
                keyPath: settingsKeyPath(
                    "review_model",
                    profileKeyPath: profile?.keyPathPrefix,
                    forceRoot: writeModelAtRoot
                ),
                value: model.map(AppServerJSONValue.string) ?? .null,
                mergeStrategy: .replace
            ),
        ]
        if persistReasoningEffort {
            edits.append(
                .init(
                    keyPath: settingsKeyPath(
                        "model_reasoning_effort",
                        profileKeyPath: profile?.keyPathPrefix,
                        forceRoot: writeReasoningAtRoot
                    ),
                    value: reasoningEffort.map { .string($0.rawValue) } ?? .null,
                    mergeStrategy: .replace
                )
            )
        }
        if persistServiceTier {
            edits.append(
                .init(
                    keyPath: settingsKeyPath(
                        "service_tier",
                        profileKeyPath: profile?.keyPathPrefix,
                        forceRoot: writeServiceTierAtRoot
                    ),
                    value: serviceTier.map { .string($0.rawValue) } ?? .null,
                    mergeStrategy: .replace
                )
            )
        }
        try await writeSettings(edits: edits)
    }

    package func updateSettingsReasoningEffort(
        _ reasoningEffort: CodexReviewReasoningEffort?
    ) async throws {
        let profile = loadActiveReviewProfile(
            environment: configuration.environment,
            codexHome: codexHomeURL
        )
        let localConfigPresence = try localConfigClient.loadPresence()
        let hasRootReasoningEffort = localConfigPresence.hasModelReasoningEffort
        let hasProfileReasoningEffortOverride = activeProfileHasReasoningEffortOverride(
            environment: configuration.environment,
            codexHome: codexHomeURL
        )
        let forceRoot = profile == nil
            || (hasRootReasoningEffort && hasProfileReasoningEffortOverride == false)
        try await writeSettings(
            edits: [
                .init(
                    keyPath: settingsKeyPath(
                        "model_reasoning_effort",
                        profileKeyPath: profile?.keyPathPrefix,
                        forceRoot: forceRoot
                    ),
                    value: reasoningEffort.map { .string($0.rawValue) } ?? .null,
                    mergeStrategy: .replace
                ),
            ]
        )
    }

    package func updateSettingsServiceTier(
        _ serviceTier: CodexReviewServiceTier?
    ) async throws {
        let profile = loadActiveReviewProfile(
            environment: configuration.environment,
            codexHome: codexHomeURL
        )
        let localConfigPresence = try localConfigClient.loadPresence()
        let hasRootServiceTier = localConfigPresence.hasServiceTier
        let hasProfileServiceTierOverride = activeProfileHasServiceTierOverride(
            environment: configuration.environment,
            codexHome: codexHomeURL
        )
        let forceRoot = profile == nil
            || (hasRootServiceTier && hasProfileServiceTierOverride == false)
        try await writeSettings(
            edits: [
                .init(
                    keyPath: settingsKeyPath(
                        "service_tier",
                        profileKeyPath: profile?.keyPathPrefix,
                        forceRoot: forceRoot
                    ),
                    value: serviceTier.map { .string($0.rawValue) } ?? .null,
                    mergeStrategy: .replace
                ),
            ]
        )
    }

    func cancelReview(
        jobID: String,
        sessionID: String,
        cancellation: ReviewCancellation,
        store: CodexReviewStore
    ) async throws {
        let job = try store.resolveJob(jobID: jobID, sessionID: sessionID)
        _ = try await store.cancelReview(
            selectedJobID: job.id,
            sessionID: sessionID,
            cancellation: cancellation
        )
    }

    private func makeServer(store: CodexReviewStore) -> ReviewMCPHTTPServer {
        ReviewMCPHTTPServer(
            configuration: configuration,
            startReview: { [weak store] sessionID, request in
                guard let store else {
                    throw ReviewError.io("Review store is unavailable.")
                }
                return try await store.startReview(sessionID: sessionID, request: request)
            },
            readReview: { [weak store] sessionID, jobID in
                guard let store else {
                    throw ReviewError.io("Review store is unavailable.")
                }
                return try store.readReview(jobID: jobID, sessionID: sessionID)
            },
            listReviews: { [weak store] sessionID, cwd, statuses, limit in
                guard let store else {
                    return ReviewListResult(items: [])
                }
                return store.listReviews(
                    sessionID: sessionID,
                    cwd: cwd,
                    statuses: statuses,
                    limit: limit
                )
            },
            cancelReviewByID: { [weak store] sessionID, jobID, cancellation in
                guard let store else {
                    throw ReviewError.io("Review store is unavailable.")
                }
                return try await store.cancelReview(
                    selectedJobID: jobID,
                    sessionID: sessionID,
                    cancellation: cancellation
                )
            },
            cancelReviewBySelector: { [weak store] sessionID, cwd, statuses, cancellation in
                guard let store else {
                    throw ReviewError.io("Review store is unavailable.")
                }
                return try await store.cancelReview(
                    selector: .init(
                        jobID: nil,
                        cwd: cwd,
                        statuses: statuses
                    ),
                    sessionID: sessionID,
                    cancellation: cancellation
                )
            },
            closeSession: { [weak store] sessionID in
                guard let store else {
                    return
                }
                await store.closeSession(sessionID, reason: "MCP session closed.")
            },
            hasActiveJobs: { [weak store] sessionID in
                guard let store else {
                    return false
                }
                return store.hasActiveJobs(for: sessionID)
            }
        )
    }

    private func performStartup(
        startupID: UInt64,
        store: CodexReviewStore,
        forceRestartIfNeeded: Bool
    ) async {
        let server = makeServer(store: store)
        do {
            let url = try await startServer(
                server,
                forceRestartIfNeeded: forceRestartIfNeeded
            )
            guard startupTaskID == startupID else {
                await server.stop()
                return
            }

            self.server = server
            runtimeStateClient.remove(at: runtimeStateFileURL)

            let appServerRuntimeState = try await appServerManager.prepare()
            guard startupTaskID == startupID, self.server === server else {
                await server.stop()
                return
            }

            writeRuntimeState(
                endpointRecord: server.currentEndpointRecord(),
                appServerRuntimeState: appServerRuntimeState
            )
            appServerRuntimeGeneration += 1
            store.transitionToRunning(serverURL: url)
            await reconcileAuthRuntime(
                store: store,
                serverIsRunning: true,
                runtimeGeneration: appServerRuntimeGeneration
            )
            if deferStartupAuthRefreshUntilPrepared {
                authOrchestrator?.startStartupRefresh(auth: store.auth)
            }
            observeServerLifecycle(server: server, store: store)
        } catch is CancellationError {
            await server.stop()
            guard startupTaskID == startupID else {
                return
            }
            await appServerManager.shutdown()
            self.server = nil
            await reconcileAuthRuntime(
                store: store,
                serverIsRunning: false,
                runtimeGeneration: appServerRuntimeGeneration
            )
        } catch {
            await server.stop()
            guard startupTaskID == startupID else {
                return
            }
            await appServerManager.shutdown()
            self.server = nil
            await reconcileAuthRuntime(
                store: store,
                serverIsRunning: false,
                runtimeGeneration: appServerRuntimeGeneration
            )
            store.transitionToFailed(CodexReviewStore.errorMessage(from: error))
            if deferStartupAuthRefreshUntilPrepared {
                authOrchestrator?.startStartupRefresh(auth: store.auth)
            }
        }
    }

    private func makeStartupTaskID() -> UInt64 {
        nextStartupTaskID += 1
        return nextStartupTaskID
    }

    private func startServer(
        _ server: ReviewMCPHTTPServer,
        forceRestartIfNeeded: Bool
    ) async throws -> URL {
        do {
            return try await server.start()
        } catch {
            guard forceRestartIfNeeded,
                  isAddressInUse(error)
            else {
                throw error
            }
            try await replayAddressInUseCleanup()
            return try await server.start()
        }
    }

    private func replayAddressInUseCleanup() async throws {
        let runtimeState = runtimeStateClient.read(from: runtimeStateFileURL)
        if let endpointRecord = addressInUseCleanupRecord(runtimeState: runtimeState) {
            try await forceRestart(
                endpointRecord: endpointRecord,
                runtimeState: runtimeState
            )
            discoveryClient.removeIfOwned(
                pid: endpointRecord.pid,
                url: URL(string: endpointRecord.url),
                serverStartTime: endpointRecord.serverStartTime,
                at: discoveryFileURL
            )
            runtimeStateClient.removeIfOwned(
                serverPID: endpointRecord.pid,
                serverStartTime: endpointRecord.serverStartTime,
                at: runtimeStateFileURL
            )
        }
    }

    private func addressInUseCleanupRecord(
        runtimeState: ReviewRuntimeStateRecord?
    ) -> LiveEndpointRecord? {
        if let endpointRecord = discoveryClient.readPersisted(from: discoveryFileURL),
           discoveryMatchesListenAddress(
            endpointRecord,
            host: configuration.host,
            port: configuration.port
           )
        {
            return endpointRecord
        }

        guard let runtimeState,
              let url = discoveryClient.makeURL(
                host: configuration.host,
                port: configuration.port,
                endpointPath: configuration.endpoint
              )
        else {
            return nil
        }

        return LiveEndpointRecord(
            url: url.absoluteString,
            host: configuration.host,
            port: configuration.port,
            pid: runtimeState.serverPID,
            serverStartTime: runtimeState.serverStartTime,
            updatedAt: runtimeState.updatedAt,
            executableName: nil
        )
    }

    private func observeServerLifecycle(
        server: ReviewMCPHTTPServer,
        store: CodexReviewStore
    ) {
        waitTask?.cancel()
        waitTask = Task { @MainActor [weak self, weak store] in
            do {
                try await server.waitUntilShutdown()
                guard let self, let store, self.server === server else {
                    return
                }
                await self.executionCoordinator?.shutdown(reason: "Review server stopped.", store: store)
                let endpointRecord = server.currentEndpointRecord()
                await server.stop()
                await self.appServerManager.shutdown()
                self.removeRuntimeState(endpointRecord: endpointRecord)
                self.server = nil
                self.authOrchestrator?.cancelStartupRefresh()
                await reconcileAuthRuntime(
                    store: store,
                    serverIsRunning: false,
                    runtimeGeneration: self.appServerRuntimeGeneration
                )
                store.transitionToStopped()
            } catch is CancellationError {
            } catch {
                guard let self, let store, self.server === server else {
                    return
                }
                await self.executionCoordinator?.shutdown(reason: "Review server failed.", store: store)
                let endpointRecord = server.currentEndpointRecord()
                await server.stop()
                await self.appServerManager.shutdown()
                self.removeRuntimeState(endpointRecord: endpointRecord)
                self.server = nil
                self.authOrchestrator?.cancelStartupRefresh()
                await reconcileAuthRuntime(
                    store: store,
                    serverIsRunning: false,
                    runtimeGeneration: self.appServerRuntimeGeneration
                )
                store.transitionToFailed(
                    CodexReviewStore.errorMessage(from: error),
                    resetJobs: true
                )
            }
        }
    }

    package func cancelRunningJobs(reason: String) async throws {
        guard let store = attachedStore else {
            return
        }
        do {
            try await store.cancelAllRunningJobs(reason: reason)
        } catch {
            store.terminateAllRunningJobsLocally(
                reason: reason,
                failureMessage: error.localizedDescription
            )
            throw error
        }
    }

    package func recycleSharedAppServerAfterAuthChange() async {
        guard let server else {
            return
        }

        await appServerManager.shutdown()
        do {
            let runtimeState = try await appServerManager.prepare()
            writeRuntimeState(
                endpointRecord: server.currentEndpointRecord(),
                appServerRuntimeState: runtimeState
            )
            appServerRuntimeGeneration += 1
            if let store = attachedStore {
                await settingsService?.refreshIfRunning(serverState: store.serverState)
            }
        } catch {
            let endpointRecord = server.currentEndpointRecord()
            removeRuntimeState(endpointRecord: endpointRecord)
            await server.stop()
            self.server = nil
            if let store = attachedStore {
                await self.executionCoordinator?.shutdown(reason: "Review server failed.", store: store)
                store.terminateAllRunningJobsLocally(
                    reason: "Review server failed.",
                    failureMessage: CodexReviewStore.errorMessage(from: error)
                )
                authOrchestrator?.cancelStartupRefresh()
                await reconcileAuthRuntime(
                    store: store,
                    serverIsRunning: false,
                    runtimeGeneration: self.appServerRuntimeGeneration
                )
                store.transitionToFailed(
                    CodexReviewStore.errorMessage(from: error),
                    resetJobs: false
                )
            }
        }
    }

    func writeRuntimeState(
        endpointRecord: LiveEndpointRecord?,
        appServerRuntimeState: AppServerRuntimeState
    ) {
        guard let endpointRecord else {
            return
        }
        let runtimeState = ReviewRuntimeStateRecord(
            serverPID: endpointRecord.pid,
            serverStartTime: endpointRecord.serverStartTime,
            appServerPID: appServerRuntimeState.pid,
            appServerStartTime: appServerRuntimeState.startTime,
            appServerProcessGroupLeaderPID: appServerRuntimeState.processGroupLeaderPID,
            appServerProcessGroupLeaderStartTime: appServerRuntimeState.processGroupLeaderStartTime,
            updatedAt: configuration.coreDependencies.dateNow()
        )
        try? runtimeStateClient.write(runtimeState, to: runtimeStateFileURL)
    }

    private func removeRuntimeState(endpointRecord: LiveEndpointRecord?) {
        guard let endpointRecord else {
            return
        }
        runtimeStateClient.removeIfOwned(
            serverPID: endpointRecord.pid,
            serverStartTime: endpointRecord.serverStartTime,
            at: runtimeStateFileURL
        )
    }

    private func writeSettings(
        edits: [AppServerConfigEdit]
    ) async throws {
        let transport = try await appServerManager.checkoutAuthTransport()
        let _: AppServerConfigWriteResponse = try await transport.request(
            method: "config/batchWrite",
            params: AppServerConfigBatchWriteParams(
                edits: edits,
                filePath: nil,
                expectedVersion: nil,
                reloadUserConfig: true
            ),
            responseType: AppServerConfigWriteResponse.self
        )
    }

}
