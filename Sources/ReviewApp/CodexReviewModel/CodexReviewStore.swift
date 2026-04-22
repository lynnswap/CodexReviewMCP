import Foundation
import Observation
import ReviewDomain

@MainActor
@Observable
public final class CodexReviewStore {
    public package(set) var serverState: CodexReviewServerState = .stopped {
        didSet {
            guard serverState != oldValue else {
                return
            }
            scheduleSettingsRefreshIfNeeded()
        }
    }
    public let auth: CodexReviewAuthModel
    package let settings: SettingsStore
    public package(set) var serverURL: URL?
    public package(set) var workspaces: [CodexReviewWorkspace] = []
    package var shouldAutoStartEmbeddedServer: Bool {
        runtime.shouldAutoStartEmbeddedServer
    }

    @ObservationIgnored package let diagnosticsURL: URL?
    @ObservationIgnored package let runtime: ReviewMonitorRuntime
    @ObservationIgnored package var previewSupportRetainer: AnyObject?
    @ObservationIgnored package var onJobsDidMutate: (@MainActor () -> Void)?
    @ObservationIgnored private var observedAuthAccountKey: String?

    package init(
        runtime: ReviewMonitorRuntime,
        diagnosticsURL: URL? = nil
    ) {
        self.runtime = runtime
        self.diagnosticsURL = diagnosticsURL
        self.auth = CodexReviewAuthModel()
        self.settings = SettingsStore(
            runtime: runtime,
            snapshot: runtime.initialSettingsSnapshot
        )
        self.auth.updateSavedAccounts(runtime.initialAccounts)
        self.auth.updateAccount(runtime.initialAccount)
        observedAuthAccountKey = auth.account?.accountKey
        observeAuthAccountChanges()
        runtime.attachStore(self)
    }

    public func start(forceRestartIfNeeded: Bool = false) async {
        switch serverState {
        case .stopped, .failed:
            break
        case .starting, .running:
            return
        }

        serverState = .starting
        serverURL = nil
        resetReviews()
        writeDiagnosticsIfNeeded()
        await runtime.start(
            store: self,
            forceRestartIfNeeded: forceRestartIfNeeded
        )
    }

    public func stop() async {
        await runtime.stop(store: self)
        transitionToStopped()
    }

    public func restart() async {
        await stop()
        await start(forceRestartIfNeeded: true)
    }

    public func waitUntilStopped() async {
        await runtime.waitUntilStopped()
    }

    public func refreshAuthentication() async {
        await runtime.refreshAuth(auth: auth)
        scheduleSettingsRefreshIfNeeded()
    }

    public func signIn() async {
        await runtime.signIn(auth: auth)
        scheduleSettingsRefreshIfNeeded()
    }

    public func addAccount() async {
        await runtime.addAccount(auth: auth)
        scheduleSettingsRefreshIfNeeded()
    }

    public func cancelAuthentication() async {
        await runtime.cancelAuthentication(auth: auth)
        scheduleSettingsRefreshIfNeeded()
    }

    public func logout() async {
        if auth.isAuthenticating, auth.account == nil {
            await cancelAuthentication()
            return
        }
        do {
            try await signOutActiveAccount()
        } catch {
            if auth.errorMessage == nil, auth.isAuthenticated {
                auth.updatePhase(.failed(message: error.localizedDescription))
            }
        }
    }

    public func signOutActiveAccount() async throws {
        try await runtime.signOutActiveAccount(auth: auth)
        scheduleSettingsRefreshIfNeeded()
    }

    package func switchAccount(_ account: CodexAccount) async throws {
        guard canSwitchAccount(account) else {
            return
        }
        let targetAccount = auth.savedAccounts.first(where: { $0.accountKey == account.accountKey })
        if auth.savedAccounts.contains(where: { $0.isSwitching }) {
            return
        }
        if let currentAccount = auth.account,
           currentAccount.isSwitching,
           auth.savedAccounts.contains(where: { $0 === currentAccount }) == false
        {
            return
        }
        targetAccount?.updateIsSwitching(true)
        defer {
            targetAccount?.updateIsSwitching(false)
        }
        try await runtime.switchAccount(auth: auth, accountKey: account.accountKey)
        scheduleSettingsRefreshIfNeeded()
    }

    package func requestSwitchAccount(
        _ account: CodexAccount,
        requiresConfirmation: Bool
    ) {
        auth.requestSwitchAccount(account, requiresConfirmation: requiresConfirmation)
        guard requiresConfirmation == false else {
            return
        }
        confirmPendingAccountAction()
    }

    package func requestSignOutActiveAccount(requiresConfirmation: Bool) {
        auth.requestSignOutActiveAccount(requiresConfirmation: requiresConfirmation)
        guard requiresConfirmation == false else {
            return
        }
        confirmPendingAccountAction()
    }

    package func requestRemoveAccount(
        _ account: CodexAccount,
        requiresConfirmation: Bool
    ) {
        auth.requestRemoveAccount(account, requiresConfirmation: requiresConfirmation)
        guard requiresConfirmation == false else {
            return
        }
        confirmPendingAccountAction()
    }

    package func confirmPendingAccountAction() {
        guard let action = auth.consumePendingAccountAction() else {
            return
        }
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            do {
                try await self.executePendingAccountAction(action)
                if let warningMessage = self.auth.warningMessage {
                    self.auth.presentAccountActionAlert(
                        title: "Account Updated With Warning",
                        message: warningMessage
                    )
                }
            } catch {
                self.auth.presentAccountActionAlert(
                    title: action.failureTitle,
                    message: error.localizedDescription
                )
            }
        }
    }

    package func cancelPendingAccountAction() {
        auth.cancelPendingAccountAction()
    }

    package func dismissAccountActionAlert() {
        auth.dismissAccountActionAlert()
    }

    package func removeAccount(accountKey: String) async throws {
        try await runtime.removeAccount(auth: auth, accountKey: accountKey)
        scheduleSettingsRefreshIfNeeded()
    }

    package func reorderSavedAccount(accountKey: String, toIndex: Int) async throws {
        try await runtime.reorderSavedAccount(
            auth: auth,
            accountKey: accountKey,
            toIndex: toIndex
        )
    }

    package func refreshSavedAccountRateLimits(accountKey: String) async {
        await runtime.refreshSavedAccountRateLimits(
            auth: auth,
            accountKey: accountKey
        )
    }

    package func startStartupAuthRefresh() {
        runtime.startStartupRefresh(auth: auth)
    }

    package func cancelStartupAuthRefresh() {
        runtime.cancelStartupRefresh()
    }

    package func reconcileAuthenticatedSession(
        serverIsRunning: Bool,
        runtimeGeneration: Int
    ) async {
        await runtime.reconcileAuthenticatedSession(
            auth: auth,
            serverIsRunning: serverIsRunning,
            runtimeGeneration: runtimeGeneration
        )
        scheduleSettingsRefreshIfNeeded()
    }

    package func switchActionIsDisabled(for account: CodexAccount) -> Bool {
        canSwitchAccount(account) == false
    }

    package func switchActionRequiresRunningJobsConfirmation(
        for account: CodexAccount
    ) -> Bool {
        if account.accountKey != auth.account?.accountKey {
            return true
        }
        return runtime.requiresCurrentSessionRecovery(
            auth: auth,
            accountKey: account.accountKey
        )
    }

    package func refreshSettings() async {
        await settings.refresh()
    }

    package func updateSettingsModel(_ model: String) async {
        await settings.updateModel(model)
    }

    package func clearSettingsModelOverride() async {
        await settings.clearModelOverride()
    }

    package func updateSettingsReasoningEffort(
        _ reasoningEffort: CodexReviewReasoningEffort?
    ) async {
        await settings.updateReasoningEffort(reasoningEffort)
    }

    package func clearSettingsReasoningEffort() async {
        await updateSettingsReasoningEffort(nil)
    }

    package func updateSettingsServiceTier(
        _ serviceTier: CodexReviewServiceTier?
    ) async {
        await settings.updateServiceTier(serviceTier)
    }

    package func transitionToRunning(serverURL: URL) {
        self.serverURL = serverURL
        serverState = .running
        writeDiagnosticsIfNeeded()
    }

    package func transitionToFailed(
        _ message: String,
        resetJobs: Bool = false
    ) {
        serverURL = nil
        if resetJobs {
            resetReviews()
        }
        serverState = .failed(message)
        writeDiagnosticsIfNeeded()
    }

    package func transitionToStopped(resetJobs: Bool = true) {
        serverURL = nil
        if resetJobs {
            resetReviews()
        }
        serverState = .stopped
        writeDiagnosticsIfNeeded()
    }

    package func writeDiagnosticsIfNeeded() {
        guard let diagnosticsURL else {
            return
        }
        var jobs: [CodexReviewStoreDiagnosticsSnapshot.Job] = []
        for workspace in workspaces {
            for job in workspace.jobs {
                jobs.append(
                    .init(
                        status: job.status.rawValue,
                        summary: job.summary,
                        logText: job.logText,
                        rawLogText: job.rawLogText
                    )
                )
            }
        }
        let snapshot = CodexReviewStoreDiagnosticsSnapshot(
            serverState: serverState.displayText,
            failureMessage: serverState.failureMessage,
            serverURL: serverURL?.absoluteString,
            childRuntimePath: nil,
            jobs: jobs
        )

        do {
            try FileManager.default.createDirectory(
                at: diagnosticsURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: diagnosticsURL, options: .atomic)
        } catch {
        }
    }

    package func noteJobMutation() {
        writeDiagnosticsIfNeeded()
        onJobsDidMutate?()
    }

    private func resetReviews() {
        workspaces = []
    }

    private var persistedActiveAccountKey: String? {
        auth.savedAccounts.first(where: \.isActive)?.accountKey
    }

    private func isAlreadyUsingPersistedActiveAccount(
        _ accountKey: String
    ) -> Bool {
        persistedActiveAccountKey == accountKey && auth.account?.accountKey == accountKey
    }

    private func canSwitchAccount(_ account: CodexAccount) -> Bool {
        guard auth.savedAccounts.contains(where: { $0.accountKey == account.accountKey }) else {
            return false
        }
        if isAlreadyUsingPersistedActiveAccount(account.accountKey) {
            return runtime.requiresCurrentSessionRecovery(
                auth: auth,
                accountKey: account.accountKey
            )
        }
        return true
    }

    private func executePendingAccountAction(
        _ action: CodexReviewAuthModel.PendingAccountAction
    ) async throws {
        switch action {
        case .switchAccount(let accountKey):
            guard let account = auth.savedAccounts.first(where: { $0.accountKey == accountKey }) else {
                return
            }
            try await switchAccount(account)
        case .signOutActiveAccount:
            try await signOutActiveAccount()
        case .removeAccount(let accountKey):
            try await removeAccount(accountKey: accountKey)
        }
    }

    private func scheduleSettingsRefreshIfNeeded() {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            await self.settings.refreshIfRunning(serverState: self.serverState)
        }
    }

    private func observeAuthAccountChanges() {
        withObservationTracking {
            _ = auth.account?.accountKey
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                let accountKey = self.auth.account?.accountKey
                if accountKey != self.observedAuthAccountKey {
                    self.observedAuthAccountKey = accountKey
                    self.scheduleSettingsRefreshIfNeeded()
                }
                self.observeAuthAccountChanges()
            }
        }
    }

    public var hasRunningJobs: Bool {
        workspaces.contains { workspace in
            workspace.jobs.contains(where: { $0.isTerminal == false })
        }
    }

    public var runningJobCount: Int {
        workspaces.reduce(into: 0) { count, workspace in
            count += workspace.jobs.filter { $0.isTerminal == false }.count
        }
    }

    package func activeJobIDs(for sessionID: String) -> [String] {
        workspaces.flatMap { workspace in
            workspace.jobs
                .filter { $0.sessionID == sessionID && $0.isTerminal == false }
                .map(\.id)
        }
    }
}
