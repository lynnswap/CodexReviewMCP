import Foundation
import Observation
import ReviewCore
import ReviewHTTPServer

public enum CodexReviewMonitorServerState: Sendable, Equatable {
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

public enum CodexReviewMonitorJobStatus: String, Sendable, Hashable {
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

public struct CodexReviewMonitorJob: Identifiable, Sendable, Hashable {
    public let id: String
    public let sessionID: String
    public let cwd: String
    public let targetSummary: String
    public let model: String?
    public let threadID: String?
    public let turnID: String?
    public let status: CodexReviewMonitorJobStatus
    public let startedAt: Date
    public let endedAt: Date?
    public let summary: String
    public let reviewLogText: String
    public let reasoningLogText: String
    public let rawLogText: String

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
        status: CodexReviewMonitorJobStatus,
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
}

private enum CodexReviewMonitorTestEnvironment {
    static let portKey = "CODEX_REVIEW_MONITOR_TEST_PORT"
    static let codexCommandKey = "CODEX_REVIEW_MONITOR_TEST_CODEX_COMMAND"
    static let diagnosticsPathKey = "CODEX_REVIEW_MONITOR_TEST_DIAGNOSTICS_PATH"
    static let portArgument = "--codex-review-monitor-test-port"
    static let codexCommandArgument = "--codex-review-monitor-test-codex-command"
    static let diagnosticsPathArgument = "--codex-review-monitor-test-diagnostics-path"
}

private struct CodexReviewMonitorDiagnosticsSnapshot: Encodable {
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
public final class CodexReviewMonitorStore {
    public private(set) var serverState: CodexReviewMonitorServerState = .stopped
    public private(set) var endpointURL: URL?
    public private(set) var jobs: [CodexReviewMonitorJob] = []

    private let configuration: ReviewServerConfiguration
    private let diagnosticsURL: URL?
    private var server: ReviewMCPHTTPServer?
    private var monitorTask: Task<Void, Never>?
    private var waitTask: Task<Void, Never>?

    public init() {
        let environment = ProcessInfo.processInfo.environment
        let arguments = CommandLine.arguments
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
        self.configuration = configuration
        self.diagnosticsURL = diagnosticsURL
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
        monitorTask?.cancel()
        monitorTask = nil
        waitTask?.cancel()
        waitTask = nil

        if let server {
            await server.stop()
        }
        server = nil
        endpointURL = nil
        jobs = []
        serverState = .stopped
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
        jobs = []
        endpointURL = nil
        writeDiagnosticsIfNeeded()

        let server = ReviewMCPHTTPServer(configuration: configuration)
        do {
            let url = try await server.start()
            self.server = server
            endpointURL = url
            serverState = .running
            writeDiagnosticsIfNeeded()
            startMonitoring(server: server)
            observeServerLifecycle(server: server)
        } catch {
            await server.stop()
            self.server = nil
            endpointURL = nil
            jobs = []
            serverState = .failed(Self.errorMessage(from: error))
            writeDiagnosticsIfNeeded()
        }
    }

    private func startMonitoring(server: ReviewMCPHTTPServer) {
        monitorTask?.cancel()
        monitorTask = Task { @MainActor [weak self] in
            let stream = await server.reviewJobStore.snapshots()
            for await snapshots in stream {
                guard Task.isCancelled == false else {
                    return
                }
                let jobs = snapshots.map(CodexReviewMonitorJob.init)
                guard let self, self.server === server else {
                    return
                }
                self.jobs = jobs
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
                self.jobs = []
                self.serverState = .stopped
                self.writeDiagnosticsIfNeeded()
            } catch is CancellationError {
            } catch {
                guard let self, self.server === server else {
                    return
                }
                self.server = nil
                self.endpointURL = nil
                self.jobs = []
                self.serverState = .failed(Self.errorMessage(from: error))
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
        let port = environment[CodexReviewMonitorTestEnvironment.portKey]
            .flatMap(Int.init)
            ?? argumentValue(
                flag: CodexReviewMonitorTestEnvironment.portArgument,
                arguments: arguments
            ).flatMap(Int.init)
            ?? codexReviewDefaultPort
        let codexCommand = environment[CodexReviewMonitorTestEnvironment.codexCommandKey]
            ?? argumentValue(
                flag: CodexReviewMonitorTestEnvironment.codexCommandArgument,
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
        guard let path = environment[CodexReviewMonitorTestEnvironment.diagnosticsPathKey]
            ?? argumentValue(
                flag: CodexReviewMonitorTestEnvironment.diagnosticsPathArgument,
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

    private func writeDiagnosticsIfNeeded() {
        guard let diagnosticsURL else {
            return
        }
        let snapshot = CodexReviewMonitorDiagnosticsSnapshot(
            serverState: serverState.displayText,
            failureMessage: serverState.failureMessage,
            endpointURL: endpointURL?.absoluteString,
            childRuntimePath: nil,
            jobs: jobs.map {
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

private extension CodexReviewMonitorJob {
    init(snapshot: ReviewJobSnapshot) {
        self.id = snapshot.jobID
        self.sessionID = snapshot.sessionID
        self.cwd = snapshot.cwd
        self.targetSummary = snapshot.targetSummary
        self.model = snapshot.model
        self.threadID = snapshot.threadID
        self.turnID = nil
        self.status = switch snapshot.state {
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
        self.startedAt = snapshot.startedAt ?? .distantPast
        self.endedAt = snapshot.endedAt
        self.summary = snapshot.summary
        self.reviewLogText = snapshot.reviewLogText
        self.reasoningLogText = snapshot.reasoningLogText
        self.rawLogText = snapshot.rawLogText
    }
}
