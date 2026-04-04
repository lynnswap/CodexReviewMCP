import Foundation
import Observation
import ReviewRuntime

@MainActor
@Observable
public final class CodexReviewStore {
    public package(set) var serverState: CodexReviewServerState = .stopped
    public package(set) var serverURL: URL?
    public package(set) var workspaces: [CodexReviewWorkspace] = []

    @ObservationIgnored package let diagnosticsURL: URL?
    @ObservationIgnored package let backend: any CodexReviewStoreBackend
    @ObservationIgnored private var startupAttemptID: UUID?
    @ObservationIgnored private var restartInFlight = false

    package init(
        backend: any CodexReviewStoreBackend,
        diagnosticsURL: URL? = nil
    ) {
        self.backend = backend
        self.diagnosticsURL = diagnosticsURL
    }

    public func start(forceRestartIfNeeded: Bool = false) async {
        switch serverState {
        case .stopped, .failed:
            break
        case .starting, .running:
            return
        }

        serverState = .starting
        let startupAttemptID = UUID()
        self.startupAttemptID = startupAttemptID
        serverURL = nil
        resetReviews()
        writeDiagnosticsIfNeeded()
        await backend.start(
            store: self,
            forceRestartIfNeeded: forceRestartIfNeeded,
            startupAttemptID: startupAttemptID
        )
    }

    public func stop() async {
        startupAttemptID = nil
        await backend.stop(store: self)
        transitionToStopped()
    }

    public func restart() async {
        guard restartInFlight == false else {
            return
        }
        restartInFlight = true
        defer { restartInFlight = false }
        await stop()
        await start(forceRestartIfNeeded: true)
    }

    public func waitUntilStopped() async {
        await backend.waitUntilStopped()
    }

    package func transitionToRunning(
        serverURL: URL,
        startupAttemptID: UUID? = nil
    ) {
        guard matchesCurrentStartupAttempt(startupAttemptID) else {
            return
        }
        self.serverURL = serverURL
        serverState = .running
        writeDiagnosticsIfNeeded()
    }

    package func transitionToFailed(
        _ message: String,
        resetJobs: Bool = false,
        startupAttemptID: UUID? = nil
    ) {
        guard matchesCurrentStartupAttempt(startupAttemptID) else {
            return
        }
        self.startupAttemptID = nil
        serverURL = nil
        if resetJobs {
            resetReviews()
        }
        serverState = .failed(message)
        writeDiagnosticsIfNeeded()
    }

    package func transitionToStopped(
        resetJobs: Bool = true,
        startupAttemptID: UUID? = nil
    ) {
        guard matchesCurrentStartupAttempt(startupAttemptID) else {
            return
        }
        self.startupAttemptID = nil
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

    private func resetReviews() {
        workspaces = []
    }

    private func matchesCurrentStartupAttempt(_ startupAttemptID: UUID?) -> Bool {
        guard let startupAttemptID else {
            return true
        }
        return self.startupAttemptID == startupAttemptID
    }
}
