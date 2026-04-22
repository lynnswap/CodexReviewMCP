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

    package init(
        runtime: ReviewMonitorRuntime,
        diagnosticsURL: URL? = nil
    ) {
        self.runtime = runtime
        self.diagnosticsURL = diagnosticsURL
        self.auth = CodexReviewAuthModel(
            runtime: runtime
        )
        self.settings = SettingsStore(
            runtime: runtime,
            snapshot: runtime.initialSettingsSnapshot
        )
        self.auth.onAccountDidChange = { [weak self] in
            self?.scheduleSettingsRefreshIfNeeded()
        }
        self.auth.updateSavedAccounts(runtime.initialAccounts)
        self.auth.updateAccount(runtime.initialAccount)
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
        await auth.refresh()
    }

    public func signIn() async {
        await auth.signIn()
    }

    public func addAccount() async {
        await auth.addAccount()
    }

    public func cancelAuthentication() async {
        await auth.cancelAuthentication()
    }

    public func logout() async {
        await auth.logout()
    }

    public func signOutActiveAccount() async throws {
        try await auth.signOutActiveAccount()
    }

    package func switchAccount(_ account: CodexAccount) async throws {
        try await auth.switchAccount(account)
    }

    package func requestSwitchAccount(
        _ account: CodexAccount,
        requiresConfirmation: Bool
    ) {
        auth.requestSwitchAccount(account, requiresConfirmation: requiresConfirmation)
    }

    package func requestSignOutActiveAccount(requiresConfirmation: Bool) {
        auth.requestSignOutActiveAccount(requiresConfirmation: requiresConfirmation)
    }

    package func requestRemoveAccount(
        _ account: CodexAccount,
        requiresConfirmation: Bool
    ) {
        auth.requestRemoveAccount(account, requiresConfirmation: requiresConfirmation)
    }

    package func confirmPendingAccountAction() {
        auth.confirmPendingAccountAction()
    }

    package func cancelPendingAccountAction() {
        auth.cancelPendingAccountAction()
    }

    package func reorderSavedAccount(accountKey: String, toIndex: Int) async throws {
        try await auth.reorderSavedAccount(accountKey: accountKey, toIndex: toIndex)
    }

    package func refreshSavedAccountRateLimits(accountKey: String) async {
        await auth.refreshSavedAccountRateLimits(accountKey: accountKey)
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
        _ reasoningEffort: CodexReviewReasoningEffort
    ) async {
        await settings.updateReasoningEffort(reasoningEffort)
    }

    package func clearSettingsReasoningEffort() async {
        await settings.updateReasoningEffort(nil)
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

    private func scheduleSettingsRefreshIfNeeded() {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            await self.settings.refreshIfRunning(serverState: self.serverState)
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
