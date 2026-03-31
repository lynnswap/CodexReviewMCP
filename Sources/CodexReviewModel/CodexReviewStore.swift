import Foundation
import Observation
import ReviewRuntime

@MainActor
@Observable
public final class CodexReviewStore {
    public package(set) var serverState: CodexReviewServerState = .stopped
    public package(set) var serverURL: URL?
    public package(set) var jobs: [CodexReviewJob] = []

    public var activeJobs: [CodexReviewJob] {
        jobs.filter { $0.isTerminal == false }
    }

    public var recentJobs: [CodexReviewJob] {
        jobs.filter(\.isTerminal)
    }

    @ObservationIgnored package let diagnosticsURL: URL?
    @ObservationIgnored package let backend: any CodexReviewStoreBackend

    package init(
        backend: any CodexReviewStoreBackend,
        diagnosticsURL: URL? = nil
    ) {
        self.backend = backend
        self.diagnosticsURL = diagnosticsURL
    }

    public func job(id: String) -> CodexReviewJob? {
        jobs.first { $0.id == id }
    }

    public func jobs(sessionID: String) -> [CodexReviewJob] {
        jobs.filter { $0.sessionID == sessionID }
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

    @_spi(Testing)
    public func loadForTesting(
        serverState: CodexReviewServerState,
        serverURL: URL? = nil,
        jobs: [CodexReviewJob]
    ) {
        precondition(
            backend.isActive == false,
            "loadForTesting must be called before the embedded server starts."
        )
        self.serverState = serverState
        self.serverURL = serverURL
        self.jobs = jobs
        sortJobs()
        writeDiagnosticsIfNeeded()
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

    package func sortJobs() {
        jobs.sort(by: compareJobs)
    }

    package func writeDiagnosticsIfNeeded() {
        guard let diagnosticsURL else {
            return
        }
        let snapshot = CodexReviewStoreDiagnosticsSnapshot(
            serverState: serverState.displayText,
            failureMessage: serverState.failureMessage,
            serverURL: serverURL?.absoluteString,
            childRuntimePath: nil,
            jobs: jobs.map {
                .init(
                    status: $0.status.rawValue,
                    summary: $0.summary,
                    logText: $0.logText,
                    rawLogText: $0.rawLogText
                )
            }
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
        jobs = []
    }
}

@MainActor
private func compareJobs(_ left: CodexReviewJob, _ right: CodexReviewJob) -> Bool {
    switch (left.isTerminal, right.isTerminal) {
    case (false, true):
        return true
    case (true, false):
        return false
    default:
        switch (left.startedAt, right.startedAt) {
        case let (lhs?, rhs?):
            return lhs > rhs
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            return left.id > right.id
        }
    }
}
