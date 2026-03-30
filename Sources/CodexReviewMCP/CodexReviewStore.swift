import Foundation
import Observation
import ReviewCore
import ReviewHTTPServer

public enum CodexReviewServerState: Sendable, Equatable {
    case stopped
    case starting
    case running
    case failed(String)

    public var isRestartAvailable: Bool {
        switch self {
        case .stopped, .failed:
            true
        case .starting, .running:
            false
        }
    }

    public var displayText: String {
        switch self {
        case .stopped:
            "Stopped"
        case .starting:
            "Starting"
        case .running:
            "Running"
        case .failed:
            "Failed"
        }
    }

    public var failureMessage: String? {
        guard case .failed(let message) = self else {
            return nil
        }
        return message
    }
}

public enum CodexReviewJobStatus: String, Sendable, Hashable {
    case queued
    case running
    case succeeded
    case failed
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .queued, .running:
            false
        case .succeeded, .failed, .cancelled:
            true
        }
    }

    public var displayText: String {
        switch self {
        case .queued:
            "Queued"
        case .running:
            "Running"
        case .succeeded:
            "Succeeded"
        case .failed:
            "Failed"
        case .cancelled:
            "Cancelled"
        }
    }
}

@MainActor
@Observable
public final class CodexReviewJob: Identifiable {
    public let id: String
    public let sessionID: String
    public var cwd: String
    public var targetSummary: String
    public var model: String?
    public var threadID: String?
    public var turnID: String?
    public var status: CodexReviewJobStatus
    public var startedAt: Date
    public var endedAt: Date?
    public var summary: String
    public var reviewLogText: String
    public var reasoningLogText: String
    public var rawLogText: String

    public var isTerminal: Bool {
        status.isTerminal
    }

    public var displayTitle: String {
        targetSummary
    }

    public var activityLogText: String {
        reviewLogText
    }

    public var reasoningSummaryText: String {
        reasoningLogText
    }

    public var reviewThreadID: String {
        id
    }

    public var parentThreadID: String? {
        threadID
    }

    public init(
        id: String,
        sessionID: String,
        cwd: String,
        targetSummary: String,
        model: String?,
        threadID: String?,
        turnID: String?,
        status: CodexReviewJobStatus,
        startedAt: Date,
        endedAt: Date?,
        summary: String,
        reviewLogText: String,
        reasoningLogText: String,
        rawLogText: String
    ) {
        self.id = id
        self.sessionID = sessionID
        self.cwd = cwd
        self.targetSummary = targetSummary
        self.model = model
        self.threadID = threadID
        self.turnID = turnID
        self.status = status
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.summary = summary
        self.reviewLogText = reviewLogText
        self.reasoningLogText = reasoningLogText
        self.rawLogText = rawLogText
    }

    convenience init(snapshot: ReviewJobSnapshot) {
        self.init(
            id: snapshot.jobID,
            sessionID: snapshot.sessionID,
            cwd: snapshot.cwd,
            targetSummary: snapshot.targetSummary,
            model: snapshot.model,
            threadID: snapshot.threadID,
            turnID: nil,
            status: Self.status(for: snapshot.state),
            startedAt: snapshot.startedAt ?? .distantPast,
            endedAt: snapshot.endedAt,
            summary: snapshot.summary,
            reviewLogText: snapshot.reviewLogText,
            reasoningLogText: snapshot.reasoningLogText,
            rawLogText: snapshot.rawLogText
        )
    }

    func apply(snapshot: ReviewJobSnapshot) {
        cwd = snapshot.cwd
        targetSummary = snapshot.targetSummary
        model = snapshot.model
        threadID = snapshot.threadID
        turnID = nil
        status = Self.status(for: snapshot.state)
        startedAt = snapshot.startedAt ?? .distantPast
        endedAt = snapshot.endedAt
        summary = snapshot.summary
        reviewLogText = snapshot.reviewLogText
        reasoningLogText = snapshot.reasoningLogText
        rawLogText = snapshot.rawLogText
    }

    private static func status(for state: ReviewJobState) -> CodexReviewJobStatus {
        switch state {
        case .queued:
            .queued
        case .running:
            .running
        case .succeeded:
            .succeeded
        case .failed:
            .failed
        case .cancelled:
            .cancelled
        }
    }
}

@MainActor
@Observable
public final class CodexReviewJobStore {
    public private(set) var jobs: [CodexReviewJob] = []

    private var changeContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    public init() {}

    public var activeJobs: [CodexReviewJob] {
        jobs.filter { $0.isTerminal == false }
    }

    public var recentJobs: [CodexReviewJob] {
        jobs.filter(\.isTerminal)
    }

    public func changes() -> AsyncStream<Void> {
        let streamID = UUID()
        return AsyncStream { continuation in
            changeContinuations[streamID] = continuation
            continuation.yield(())
            continuation.onTermination = { _ in
                Task { @MainActor [weak self] in
                    self?.changeContinuations[streamID] = nil
                }
            }
        }
    }

    func apply(snapshots: [ReviewJobSnapshot]) {
        let existingJobsByID = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0) })
        var updatedJobs: [CodexReviewJob] = []
        updatedJobs.reserveCapacity(snapshots.count)
        for snapshot in snapshots {
            if let job = existingJobsByID[snapshot.jobID] {
                job.apply(snapshot: snapshot)
                updatedJobs.append(job)
            } else {
                updatedJobs.append(CodexReviewJob(snapshot: snapshot))
            }
        }
        jobs = updatedJobs
        broadcastChanges()
    }

    func reset() {
        jobs = []
        broadcastChanges()
    }

    private func broadcastChanges() {
        for continuation in changeContinuations.values {
            continuation.yield(())
        }
    }
}

private enum CodexReviewStoreTestEnvironment {
    static let portKey = "CODEX_REVIEW_MONITOR_TEST_PORT"
    static let codexCommandKey = "CODEX_REVIEW_MONITOR_TEST_CODEX_COMMAND"
    static let diagnosticsPathKey = "CODEX_REVIEW_MONITOR_TEST_DIAGNOSTICS_PATH"
    static let portArgument = "--codex-review-monitor-test-port"
    static let codexCommandArgument = "--codex-review-monitor-test-codex-command"
    static let diagnosticsPathArgument = "--codex-review-monitor-test-diagnostics-path"
}

private struct CodexReviewStoreDiagnosticsSnapshot: Encodable {
    struct Job: Encodable {
        var status: String
        var summary: String
        var reviewLogText: String
        var reasoningLogText: String
        var rawLogText: String
    }

    var serverState: String
    var failureMessage: String?
    var endpointURL: String?
    var childRuntimePath: String?
    var jobs: [Job]
}

@MainActor
@Observable
public final class CodexReviewStore {
    public private(set) var serverState: CodexReviewServerState = .stopped
    public private(set) var endpointURL: URL?
    public let jobStore: CodexReviewJobStore

    private let configuration: ReviewServerConfiguration
    private let diagnosticsURL: URL?
    private var server: ReviewMCPHTTPServer?
    private var snapshotObservationTask: Task<Void, Never>?
    private var waitTask: Task<Void, Never>?
    private var stateContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    public init() {
        let environment = ProcessInfo.processInfo.environment
        let arguments = CommandLine.arguments
        self.jobStore = CodexReviewJobStore()
        self.configuration = Self.makeConfiguration(
            environment: environment,
            arguments: arguments
        )
        self.diagnosticsURL = Self.makeDiagnosticsURL(
            environment: environment,
            arguments: arguments
        )
    }

    init(
        configuration: ReviewServerConfiguration,
        diagnosticsURL: URL? = nil
    ) {
        self.jobStore = CodexReviewJobStore()
        self.configuration = configuration
        self.diagnosticsURL = diagnosticsURL
    }

    public func changes() -> AsyncStream<Void> {
        let streamID = UUID()
        return AsyncStream { continuation in
            stateContinuations[streamID] = continuation
            continuation.yield(())
            continuation.onTermination = { _ in
                Task { @MainActor [weak self] in
                    self?.stateContinuations[streamID] = nil
                }
            }
        }
    }

    public func start() async {
        switch serverState {
        case .stopped, .failed:
            break
        case .starting, .running:
            return
        }
        await startEmbeddedServer()
    }

    public func stop() async {
        snapshotObservationTask?.cancel()
        snapshotObservationTask = nil
        waitTask?.cancel()
        waitTask = nil

        if let server {
            await server.stop()
        }
        server = nil
        endpointURL = nil
        jobStore.reset()
        serverState = .stopped
        broadcastStateChanges()
        writeDiagnosticsIfNeeded()
    }

    public func restart() async {
        await stop()
        await startEmbeddedServer()
    }

    var reviewJobStoreForTesting: ReviewJobStore? {
        server?.reviewJobStore
    }

    var serverForTesting: ReviewMCPHTTPServer? {
        server
    }

    private func startEmbeddedServer() async {
        serverState = .starting
        endpointURL = nil
        jobStore.reset()
        broadcastStateChanges()
        writeDiagnosticsIfNeeded()

        let server = ReviewMCPHTTPServer(configuration: configuration)
        do {
            let url = try await server.start()
            self.server = server
            endpointURL = url
            serverState = .running
            broadcastStateChanges()
            writeDiagnosticsIfNeeded()
            startObservingJobs(server: server)
            observeServerLifecycle(server: server)
        } catch {
            await server.stop()
            self.server = nil
            endpointURL = nil
            jobStore.reset()
            serverState = .failed(Self.errorMessage(from: error))
            broadcastStateChanges()
            writeDiagnosticsIfNeeded()
        }
    }

    private func startObservingJobs(server: ReviewMCPHTTPServer) {
        snapshotObservationTask?.cancel()
        snapshotObservationTask = Task { @MainActor [weak self] in
            let stream = await server.reviewJobStore.snapshots()
            for await snapshots in stream {
                guard Task.isCancelled == false else {
                    return
                }
                guard let self, self.server === server else {
                    return
                }
                self.jobStore.apply(snapshots: snapshots)
                self.writeDiagnosticsIfNeeded()
            }
        }
    }

    private func observeServerLifecycle(server: ReviewMCPHTTPServer) {
        waitTask?.cancel()
        waitTask = Task { @MainActor [weak self] in
            do {
                try await server.waitUntilShutdown()
                guard let self, self.server === server else {
                    return
                }
                self.server = nil
                self.endpointURL = nil
                self.jobStore.reset()
                self.serverState = .stopped
                self.broadcastStateChanges()
                self.writeDiagnosticsIfNeeded()
            } catch is CancellationError {
            } catch {
                guard let self, self.server === server else {
                    return
                }
                self.server = nil
                self.endpointURL = nil
                self.jobStore.reset()
                self.serverState = .failed(Self.errorMessage(from: error))
                self.broadcastStateChanges()
                self.writeDiagnosticsIfNeeded()
            }
        }
    }

    private static func errorMessage(from error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription, localized.isEmpty == false {
            return localized
        }
        return error.localizedDescription
    }

    private static func makeConfiguration(
        environment: [String: String],
        arguments: [String]
    ) -> ReviewServerConfiguration {
        let port = environment[CodexReviewStoreTestEnvironment.portKey]
            .flatMap(Int.init)
            ?? argumentValue(
                flag: CodexReviewStoreTestEnvironment.portArgument,
                arguments: arguments
            ).flatMap(Int.init)
            ?? codexReviewDefaultPort
        let codexCommand = environment[CodexReviewStoreTestEnvironment.codexCommandKey]
            ?? argumentValue(
                flag: CodexReviewStoreTestEnvironment.codexCommandArgument,
                arguments: arguments
            )
            ?? "codex"
        return .init(
            port: port,
            codexCommand: codexCommand,
            environment: environment
        )
    }

    private static func makeDiagnosticsURL(
        environment: [String: String],
        arguments: [String]
    ) -> URL? {
        guard let path = environment[CodexReviewStoreTestEnvironment.diagnosticsPathKey]
            ?? argumentValue(
                flag: CodexReviewStoreTestEnvironment.diagnosticsPathArgument,
                arguments: arguments
            ),
            path.isEmpty == false
        else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    private static func argumentValue(
        flag: String,
        arguments: [String]
    ) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(arguments.index(after: index))
        else {
            return nil
        }
        return arguments[arguments.index(after: index)]
    }

    private func broadcastStateChanges() {
        for continuation in stateContinuations.values {
            continuation.yield(())
        }
    }

    private func writeDiagnosticsIfNeeded() {
        guard let diagnosticsURL else {
            return
        }
        let snapshot = CodexReviewStoreDiagnosticsSnapshot(
            serverState: serverState.displayText,
            failureMessage: serverState.failureMessage,
            endpointURL: endpointURL?.absoluteString,
            childRuntimePath: nil,
            jobs: jobStore.jobs.map {
                .init(
                    status: $0.status.rawValue,
                    summary: $0.summary,
                    reviewLogText: $0.reviewLogText,
                    reasoningLogText: $0.reasoningLogText,
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
}
