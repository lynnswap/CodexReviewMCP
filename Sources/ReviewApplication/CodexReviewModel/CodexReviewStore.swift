import Foundation
import Observation
import ReviewDomain

@MainActor
@Observable
public final class CodexReviewStore {
    public package(set) var serverState: CodexReviewServerState = .stopped
    public let auth: CodexReviewAuthModel
    package let settings: SettingsStore
    public package(set) var serverURL: URL?
    public package(set) var workspaces: [CodexReviewWorkspace] = []
    package var shouldAutoStartEmbeddedServer: Bool {
        coordinator.shouldAutoStartEmbeddedServer
    }

    @ObservationIgnored package let diagnosticsURL: URL?
    @ObservationIgnored package let coreDependencies: ReviewStoreDependencies
    @ObservationIgnored package let coordinator: ReviewMonitorCoordinator
    @ObservationIgnored package let settingsService: ReviewMonitorSettingsService
    @ObservationIgnored package var previewSupportRetainer: AnyObject?

    package init(
        coreDependencies: ReviewStoreDependencies = .live(),
        coordinator: ReviewMonitorCoordinator,
        settingsService: ReviewMonitorSettingsService,
        diagnosticsURL: URL? = nil
    ) {
        self.coreDependencies = coreDependencies
        self.coordinator = coordinator
        self.settingsService = settingsService
        self.diagnosticsURL = diagnosticsURL
        self.auth = CodexReviewAuthModel()
        self.settings = SettingsStore(
            snapshot: settingsService.initialSnapshot
        )
        self.auth.applyPersistedAccountStates(
            coordinator.seed.initialAccounts.map(savedAccountPayload(from:)),
            activeAccountKey: coordinator.seed.initialActiveAccountKey
        )
        if let initialAccount = coordinator.seed.initialAccount {
            if auth.persistedAccounts.contains(where: { $0.accountKey == initialAccount.accountKey }) {
                self.auth.selectPersistedAccount(initialAccount.id)
            } else {
                self.auth.updateCurrentAccount(initialAccount)
            }
        }
        coordinator.attachStore(self)
        settingsService.attach(settings: settings)
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
        writeDiagnosticsIfNeeded()
        await coordinator.start(
            store: self,
            forceRestartIfNeeded: forceRestartIfNeeded
        )
        await refreshSettingsAfterServerStart()
    }

    public func stop() async {
        await coordinator.stop(store: self)
        transitionToStopped()
    }

    public func restart() async {
        await stop()
        await start(forceRestartIfNeeded: true)
    }

    public func waitUntilStopped() async {
        await coordinator.waitUntilStopped()
    }

    public func refreshAuthentication() async {
        await coordinator.refreshAuth(auth: auth)
    }

    public func signIn() async {
        await coordinator.signIn(auth: auth)
    }

    public func addAccount() async {
        await coordinator.addAccount(auth: auth)
    }

    public func cancelAuthentication() async {
        await coordinator.cancelAuthentication(auth: auth)
    }

    package func performPrimaryAuthenticationAction() async {
        if auth.isAuthenticating {
            await cancelAuthentication()
            return
        }

        guard auth.isAuthenticated == false else {
            return
        }

        switch serverState {
        case .failed, .stopped:
            await restart()
        case .running, .starting:
            break
        }

        guard auth.isAuthenticated == false,
              auth.isAuthenticating == false
        else {
            return
        }
        await signIn()
    }

    public func logout() async {
        if auth.isAuthenticating, auth.selectedAccount == nil {
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
        try await coordinator.signOutActiveAccount(auth: auth)
    }

    package func switchAccount(_ account: CodexAccount) async throws {
        guard canSwitchAccount(account) else {
            return
        }
        let targetAccount = auth.persistedAccounts.first(where: { $0.accountKey == account.accountKey })
        if auth.persistedAccounts.contains(where: { $0.isSwitching }) {
            return
        }
        if auth.selectedAccount?.isSwitching == true {
            return
        }
        targetAccount?.updateIsSwitching(true)
        defer {
            targetAccount?.updateIsSwitching(false)
        }
        try await coordinator.switchAccount(auth: auth, accountKey: account.accountKey)
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

    package func requestSwitchAccountFromUserAction(_ account: CodexAccount) {
        requestSwitchAccount(
            account,
            requiresConfirmation: hasRunningJobs
                && switchActionRequiresRunningJobsConfirmation(for: account)
        )
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
        try await coordinator.removeAccount(auth: auth, accountKey: accountKey)
    }

    package func reorderPersistedAccount(accountKey: String, toIndex: Int) async throws {
        try await coordinator.reorderPersistedAccount(
            auth: auth,
            accountKey: accountKey,
            toIndex: toIndex
        )
    }

    package func refreshAccountRateLimits(accountKey: String) async {
        await coordinator.refreshAccountRateLimits(
            auth: auth,
            accountKey: accountKey
        )
    }

    package func startStartupAuthRefresh() {
        coordinator.startStartupRefresh(auth: auth)
    }

    package func cancelStartupAuthRefresh() {
        coordinator.cancelStartupRefresh()
    }

    package func reconcileAuthenticatedSession(
        serverIsRunning: Bool,
        runtimeGeneration: Int
    ) async {
        await coordinator.reconcileAuthenticatedSession(
            auth: auth,
            serverIsRunning: serverIsRunning,
            runtimeGeneration: runtimeGeneration
        )
    }

    package func switchActionIsDisabled(for account: CodexAccount) -> Bool {
        canSwitchAccount(account) == false
    }

    package func switchActionRequiresRunningJobsConfirmation(
        for account: CodexAccount
    ) -> Bool {
        if account.accountKey != auth.selectedAccount?.accountKey {
            return true
        }
        return coordinator.requiresCurrentSessionRecovery(
            auth: auth,
            accountKey: account.accountKey
        )
    }

    package func refreshSettings() async {
        await settingsService.refresh()
    }

    package func updateSettingsModel(_ model: String) async {
        await settingsService.updateModel(model)
    }

    package func clearSettingsModelOverride() async {
        await settingsService.clearModelOverride()
    }

    package func updateSettingsReasoningEffort(
        _ reasoningEffort: CodexReviewReasoningEffort?
    ) async {
        await settingsService.updateReasoningEffort(reasoningEffort)
    }

    package func clearSettingsReasoningEffort() async {
        await updateSettingsReasoningEffort(nil)
    }

    package func updateSettingsServiceTier(
        _ serviceTier: CodexReviewServiceTier?
    ) async {
        await settingsService.updateServiceTier(serviceTier)
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

    package func transitionToStopped(resetJobs: Bool = false) {
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
                        status: job.core.lifecycle.status.rawValue,
                        summary: job.core.output.summary,
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
    }

    private func resetReviews() {
        workspaces = []
    }

    private func isAlreadyUsingPersistedActiveAccount(
        _ accountKey: String
    ) -> Bool {
        auth.selectedAccount?.accountKey == accountKey
            && auth.isPersistedActiveAccount(accountKey)
    }

    private func canSwitchAccount(_ account: CodexAccount) -> Bool {
        guard auth.persistedAccounts.contains(where: { $0.accountKey == account.accountKey }) else {
            return false
        }
        if isAlreadyUsingPersistedActiveAccount(account.accountKey) {
            return coordinator.requiresCurrentSessionRecovery(
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
            guard let account = auth.persistedAccounts.first(where: { $0.accountKey == accountKey }) else {
                return
            }
            try await switchAccount(account)
        case .signOutActiveAccount:
            try await signOutActiveAccount()
        case .removeAccount(let accountKey):
            try await removeAccount(accountKey: accountKey)
        }
    }

    private func refreshSettingsAfterServerStart() async {
        await settingsService.refreshIfRunning(serverState: serverState)
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
