import Foundation
import Observation

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
        backend.shouldAutoStartEmbeddedServer
    }

    @ObservationIgnored package let diagnosticsURL: URL?
    @ObservationIgnored package let backend: any CodexReviewStoreBackend
    @ObservationIgnored package var previewSupportRetainer: AnyObject?
    @ObservationIgnored package var onJobsDidMutate: (@MainActor () -> Void)?

    package init(
        backend: any CodexReviewStoreBackend,
        authController: (any CodexReviewAuthControlling)? = nil,
        diagnosticsURL: URL? = nil
    ) {
        self.backend = backend
        self.diagnosticsURL = diagnosticsURL
        self.auth = CodexReviewAuthModel(
            controller: authController ?? CodexReviewPreviewAuthController()
        )
        self.settings = SettingsStore(
            backend: backend,
            snapshot: backend.initialSettingsSnapshot
        )
        self.auth.onAccountDidChange = { [weak self] in
            self?.scheduleSettingsRefreshIfNeeded()
        }
        self.auth.updateSavedAccounts(backend.initialAccounts)
        self.auth.updateAccount(backend.initialAccount)
        backend.attachStore(self)
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
        await backend.start(
            store: self,
            forceRestartIfNeeded: forceRestartIfNeeded
        )
    }

    public func stop() async {
        await backend.stop(store: self)
        transitionToStopped()
    }

    public func restart() async {
        await stop()
        await start(forceRestartIfNeeded: true)
    }

    public func waitUntilStopped() async {
        await backend.waitUntilStopped()
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
}
