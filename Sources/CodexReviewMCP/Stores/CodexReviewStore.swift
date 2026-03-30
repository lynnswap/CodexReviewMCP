import Darwin
import Foundation
import Observation
import ReviewCore
import ReviewHTTPServer
import ReviewJobs
import ReviewRuntime

@MainActor
@Observable
public final class CodexReviewStore {
    public private(set) var serverState: CodexReviewServerState = .stopped
    public private(set) var serverURL: URL?
    public private(set) var jobs: [CodexReviewJob] = []

    public var activeJobs: [CodexReviewJob] {
        jobs.filter { $0.isTerminal == false }
    }

    public var recentJobs: [CodexReviewJob] {
        jobs.filter(\.isTerminal)
    }

    @ObservationIgnored private let configuration: ReviewServerConfiguration
    @ObservationIgnored private let diagnosticsURL: URL?
    @ObservationIgnored private let executionCoordinator: ReviewExecutionCoordinator
    @ObservationIgnored private var server: ReviewMCPHTTPServer?
    @ObservationIgnored private var waitTask: Task<Void, Never>?
    @ObservationIgnored private var closedSessions: Set<String> = []

    public init() {
        let environment = ProcessInfo.processInfo.environment
        let arguments = CommandLine.arguments
        let configuration = Self.makeConfiguration(
            environment: environment,
            arguments: arguments
        )
        self.configuration = configuration
        self.diagnosticsURL = Self.makeDiagnosticsURL(
            environment: environment,
            arguments: arguments
        )
        self.executionCoordinator = ReviewExecutionCoordinator(
            configuration: .init(
                codexCommand: configuration.codexCommand,
                environment: configuration.environment
            )
        )
    }

    package init(
        configuration: ReviewServerConfiguration,
        diagnosticsURL: URL? = nil
    ) {
        self.configuration = configuration
        self.diagnosticsURL = diagnosticsURL
        self.executionCoordinator = ReviewExecutionCoordinator(
            configuration: .init(
                codexCommand: configuration.codexCommand,
                environment: configuration.environment
            )
        )
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

        let server = makeServer()
        do {
            let url: URL
            do {
                url = try await server.start()
            } catch {
                guard forceRestartIfNeeded,
                      isAddressInUse(error),
                      let discovery = ReviewDiscovery.read(),
                      discoveryMatchesListenAddress(
                        discovery,
                        host: configuration.host,
                        port: configuration.port
                      )
                else {
                    throw error
                }
                try await forceRestart(discovery)
                url = try await server.start()
            }

            self.server = server
            serverURL = url
            serverState = .running
            writeDiagnosticsIfNeeded()
            observeServerLifecycle(server: server)
        } catch {
            await server.stop()
            self.server = nil
            serverURL = nil
            serverState = .failed(Self.errorMessage(from: error))
            writeDiagnosticsIfNeeded()
        }
    }

    public func stop() async {
        waitTask?.cancel()
        waitTask = nil

        if let server {
            await server.stop()
        }
        server = nil
        serverURL = nil
        resetReviews()
        serverState = .stopped
        writeDiagnosticsIfNeeded()
    }

    public func restart() async {
        await stop()
        await start(forceRestartIfNeeded: true)
    }

    public func waitUntilStopped() async {
        guard let waitTask else {
            return
        }
        _ = await waitTask.value
    }

    package func startReview(
        sessionID: String,
        request: ReviewStartRequest
    ) async throws -> ReviewReadResult {
        try await executionCoordinator.startReview(
            sessionID: sessionID,
            request: request,
            store: self
        )
    }

    package func readReview(
        reviewThreadID: String,
        sessionID: String
    ) throws -> ReviewReadResult {
        let job = try authorizedJob(id: reviewThreadID, sessionID: sessionID)
        return ReviewReadResult(
            jobID: job.id,
            reviewThreadID: job.id,
            threadID: job.threadID,
            turnID: job.turnID,
            status: job.status.state,
            review: job.isTerminal ? job.reviewText : (job.reviewText.nilIfEmpty ?? job.lastAgentMessage ?? ""),
            lastAgentMessage: job.lastAgentMessage ?? "",
            error: job.errorMessage
        )
    }

    package func listReviews(
        sessionID: String,
        cwd: String? = nil,
        statuses: [ReviewJobState]? = nil,
        limit: Int? = nil
    ) -> ReviewListResult {
        let filtered = filteredJobs(sessionID: sessionID, cwd: cwd, statuses: statuses)
        let clampedLimit = min(max(limit ?? 20, 1), 100)
        return ReviewListResult(items: Array(filtered.prefix(clampedLimit)).map(makeListItem))
    }

    package func cancelReview(
        reviewThreadID: String,
        sessionID: String,
        reason: String = "Cancellation requested."
    ) async throws -> ReviewCancelOutcome {
        try await executionCoordinator.cancelReview(
            reviewThreadID: reviewThreadID,
            sessionID: sessionID,
            reason: reason,
            store: self
        )
    }

    package func cancelReview(
        selector: ReviewJobSelector,
        sessionID: String
    ) async throws -> ReviewCancelOutcome {
        try await executionCoordinator.cancelReview(
            selector: selector,
            sessionID: sessionID,
            store: self
        )
    }

    package func hasActiveJobs(for sessionID: String) -> Bool {
        jobs.contains { $0.sessionID == sessionID && $0.isTerminal == false }
    }

    package func closeSession(_ sessionID: String, reason: String) async {
        await executionCoordinator.closeSession(sessionID, reason: reason, store: self)
    }

    package func enqueueReview(
        sessionID: String,
        request: ReviewRequestOptions
    ) throws -> String {
        if closedSessions.contains(sessionID) {
            throw ReviewError.accessDenied("Session \(sessionID) is already closed.")
        }
        let request = try request.validated()
        let jobID = UUID().uuidString
        appendQueuedJob(
            .init(jobID: jobID, sessionID: sessionID, request: request)
        )
        return jobID
    }

    package func markStarted(
        jobID: String,
        artifacts: ReviewArtifacts,
        startedAt: Date
    ) {
        updateJob(id: jobID, resort: true) { job in
            job.artifacts = artifacts
            job.startedAt = startedAt
            if job.status == .queued {
                job.status = .running
                job.summary = "Running."
            }
        }
    }

    package func handle(jobID: String, event: ReviewProcessEvent) {
        switch event {
        case .progress(_, let message):
            guard let message = message?.nilIfEmpty else {
                return
            }
            updateJob(id: jobID) { job in
                job.summary = message
                job.reviewEntries.append(.init(kind: .progress, text: message))
            }
        case .threadStarted(let threadID):
            updateJob(id: jobID) { job in
                job.threadID = threadID
                job.summary = "Thread started: \(threadID)"
            }
        case .reviewEntry(let entry):
            updateJob(id: jobID) { job in
                job.reviewEntries.append(entry)
            }
        case .reasoningEntry(let entry):
            updateJob(id: jobID) { job in
                job.reasoningEntries.append(entry)
            }
        case .rawLine(let line):
            updateJob(id: jobID) { job in
                job.rawEventLines.append(line)
                trimRawLines(job: job)
            }
        case .agentMessage(let message):
            updateJob(id: jobID) { job in
                job.lastAgentMessage = message
            }
        case .failed(let message):
            updateJob(id: jobID) { job in
                job.errorMessage = message.nilIfEmpty
            }
        }
    }

    package func completeReview(jobID: String, outcome: ReviewProcessOutcome) {
        updateJob(id: jobID, resort: true) { job in
            job.status = .init(state: outcome.state)
            job.summary = outcome.summary
            job.lastAgentMessage = outcome.lastAgentMessage.nilIfEmpty ?? job.lastAgentMessage
            job.errorMessage = outcome.errorMessage
            job.threadID = outcome.threadID ?? job.threadID
            job.startedAt = outcome.startedAt
            job.endedAt = outcome.endedAt
            job.exitCode = outcome.exitCode
            job.artifacts = outcome.artifacts
        }
    }

    package func failToStart(
        jobID: String,
        message: String,
        startedAt: Date,
        endedAt: Date
    ) {
        updateJob(id: jobID, resort: true) { job in
            job.status = .failed
            job.summary = "Failed to start review."
            job.errorMessage = message
            job.startedAt = startedAt
            job.endedAt = endedAt
            if message.isEmpty == false {
                job.reviewEntries.append(.init(kind: .error, text: message))
            }
        }
    }

    package func requestCancellation(
        jobID: String,
        sessionID: String,
        reason: String
    ) throws -> ReviewCancelResult {
        let job = try authorizedJob(id: jobID, sessionID: sessionID)
        if job.isTerminal {
            return ReviewCancelResult(jobID: jobID, state: job.status.state, signalled: false)
        }
        let endedAt = job.startedAt == nil ? Date() : nil
        updateJob(id: jobID, resort: true) { job in
            job.status = .cancelled
            job.summary = "Cancellation requested."
            if reason.isEmpty == false {
                job.errorMessage = reason
            }
            if let endedAt {
                job.endedAt = endedAt
            }
        }
        return ReviewCancelResult(jobID: jobID, state: .cancelled, signalled: false)
    }

    package func closeSessionState(_ sessionID: String) -> [String] {
        closedSessions.insert(sessionID)
        let activeJobIDs = jobs
            .filter { $0.sessionID == sessionID && $0.isTerminal == false }
            .map(\.id)
        jobs.removeAll { $0.sessionID == sessionID && $0.isTerminal }
        writeDiagnosticsIfNeeded()
        return activeJobIDs
    }

    package func pruneClosedJobIfNeeded(jobID: String) {
        guard let job = job(id: jobID),
              closedSessions.contains(job.sessionID),
              job.isTerminal
        else {
            return
        }
        removeJob(id: jobID)
    }

    package func resolveJob(
        sessionID: String,
        selector: ReviewJobSelector
    ) throws -> CodexReviewJob {
        if let reviewThreadID = selector.reviewThreadID?.nilIfEmpty {
            return try authorizedJob(id: reviewThreadID, sessionID: sessionID)
        }

        let effectiveStatuses = selector.statuses ?? [.queued, .running]
        let candidates = filteredJobs(
            sessionID: sessionID,
            cwd: selector.cwd,
            statuses: effectiveStatuses
        )
        guard candidates.isEmpty == false else {
            throw ReviewJobSelectionError.notFound("No matching review jobs were found.")
        }
        if selector.latest {
            return candidates[0]
        }
        guard candidates.count == 1 else {
            throw ReviewJobSelectionError.ambiguous(candidates.map(makeListItem))
        }
        return candidates[0]
    }

    private func appendQueuedJob(_ queued: ReviewQueuedJob) {
        jobs.append(
            CodexReviewJob(
                id: queued.jobID,
                sessionID: queued.sessionID,
                cwd: queued.request.cwd,
                targetSummary: queued.request.targetSummary,
                model: queued.request.model,
                threadID: nil,
                turnID: nil,
                status: .queued,
                startedAt: nil,
                endedAt: nil,
                summary: "Queued.",
                lastAgentMessage: nil,
                reviewEntries: [],
                reasoningEntries: [],
                rawEventLines: [],
                errorMessage: nil,
                exitCode: nil,
                artifacts: .init(eventsPath: nil, logPath: nil, lastMessagePath: nil)
            )
        )
        sortJobs()
        writeDiagnosticsIfNeeded()
    }

    private func updateJob(
        id: String,
        resort: Bool = false,
        _ update: (CodexReviewJob) -> Void
    ) {
        guard let job = job(id: id) else {
            return
        }
        update(job)
        if resort {
            sortJobs()
        }
        writeDiagnosticsIfNeeded()
    }

    private func removeJob(id: String) {
        jobs.removeAll { $0.id == id }
        writeDiagnosticsIfNeeded()
    }

    private func resetReviews() {
        jobs = []
        closedSessions = []
    }

    private func filteredJobs(
        sessionID: String,
        cwd: String?,
        statuses: [ReviewJobState]?
    ) -> [CodexReviewJob] {
        let normalizedCWD = cwd?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let allowedStatuses = statuses.map(Set.init)
        return jobs
            .filter { $0.sessionID == sessionID }
            .filter { job in
                if let normalizedCWD, job.cwd != normalizedCWD {
                    return false
                }
                if let allowedStatuses, allowedStatuses.contains(job.status.state) == false {
                    return false
                }
                return true
            }
            .sorted(by: compareJobs)
    }

    private func authorizedJob(id: String, sessionID: String) throws -> CodexReviewJob {
        guard let job = job(id: id) else {
            throw ReviewError.jobNotFound("Job \(id) was not found.")
        }
        guard job.sessionID == sessionID else {
            throw ReviewError.accessDenied("Job \(id) belongs to another MCP session.")
        }
        return job
    }

    private func makeListItem(_ job: CodexReviewJob) -> ReviewJobListItem {
        ReviewJobListItem(
            jobID: job.id,
            reviewThreadID: job.id,
            cwd: job.cwd,
            targetSummary: job.targetSummary,
            model: job.model,
            status: job.status.state,
            summary: job.summary,
            startedAt: job.startedAt,
            endedAt: job.endedAt,
            elapsedSeconds: elapsedSeconds(for: job),
            threadID: job.threadID,
            lastAgentMessage: job.lastAgentMessage ?? "",
            cancellable: job.isTerminal == false
        )
    }

    private func elapsedSeconds(for job: CodexReviewJob) -> Int? {
        guard let startedAt = job.startedAt else {
            return nil
        }
        let endedAt = job.endedAt ?? (job.isTerminal ? Date() : nil) ?? Date()
        return Int(endedAt.timeIntervalSince(startedAt))
    }

    private func sortJobs() {
        jobs.sort(by: compareJobs)
    }

    private func makeServer() -> ReviewMCPHTTPServer {
        ReviewMCPHTTPServer(
            configuration: configuration,
            startReview: { [weak self] sessionID, request in
                guard let self else {
                    throw ReviewError.io("Review store is unavailable.")
                }
                return try await self.startReview(sessionID: sessionID, request: request)
            },
            readReview: { [weak self] sessionID, reviewThreadID in
                guard let self else {
                    throw ReviewError.io("Review store is unavailable.")
                }
                return try self.readReview(reviewThreadID: reviewThreadID, sessionID: sessionID)
            },
            listReviews: { [weak self] sessionID, cwd, statuses, limit in
                guard let self else {
                    return ReviewListResult(items: [])
                }
                return self.listReviews(
                    sessionID: sessionID,
                    cwd: cwd,
                    statuses: statuses,
                    limit: limit
                )
            },
            cancelReviewByID: { [weak self] sessionID, reviewThreadID in
                guard let self else {
                    throw ReviewError.io("Review store is unavailable.")
                }
                return try await self.cancelReview(
                    reviewThreadID: reviewThreadID,
                    sessionID: sessionID
                )
            },
            cancelReviewBySelector: { [weak self] sessionID, cwd, statuses, latest in
                guard let self else {
                    throw ReviewError.io("Review store is unavailable.")
                }
                return try await self.cancelReview(
                    selector: .init(
                        reviewThreadID: nil,
                        cwd: cwd,
                        statuses: statuses,
                        latest: latest
                    ),
                    sessionID: sessionID
                )
            },
            closeSession: { [weak self] sessionID in
                guard let self else {
                    return
                }
                await self.closeSession(sessionID, reason: "MCP session closed.")
            },
            hasActiveJobs: { [weak self] sessionID in
                guard let self else {
                    return false
                }
                return self.hasActiveJobs(for: sessionID)
            }
        )
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
                self.serverURL = nil
                self.resetReviews()
                self.serverState = .stopped
                self.writeDiagnosticsIfNeeded()
            } catch is CancellationError {
            } catch {
                guard let self, self.server === server else {
                    return
                }
                self.server = nil
                self.serverURL = nil
                self.resetReviews()
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
        let port = environment[CodexReviewStoreTestEnvironment.portKey]
            .flatMap(Int.init)
            ?? argumentValue(
                flag: CodexReviewStoreTestEnvironment.portArgument,
                arguments: arguments
            ).flatMap(Int.init)
            ?? ReviewServerConfiguration().port
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

    private func trimRawLines(job: CodexReviewJob) {
        while job.rawEventLines.joined(separator: "\n").utf8.count > reviewLogLimitBytes,
              job.rawEventLines.isEmpty == false
        {
            job.rawEventLines.removeFirst()
        }
    }

    private func writeDiagnosticsIfNeeded() {
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
                    reviewLogText: $0.activityLogText,
                    reasoningLogText: $0.reasoningSummaryText,
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

private struct ReviewQueuedJob {
    var jobID: String
    var sessionID: String
    var request: ReviewRequestOptions
}

private func forceRestart(_ discovery: ReviewDiscoveryRecord) async throws {
    let pid = pid_t(discovery.pid)
    let signalResult = kill(pid, SIGTERM)
    if signalResult == -1, errno != ESRCH {
        throw ReviewError.io("failed to stop existing server process \(discovery.pid): \(String(cString: strerror(errno)))")
    }

    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while isProcessAlive(pid), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(100))
    }

    if isProcessAlive(pid) {
        _ = kill(pid, SIGKILL)
        let killDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while isProcessAlive(pid), ContinuousClock.now < killDeadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    if isProcessAlive(pid) {
        throw ReviewError.io("existing server process \(discovery.pid) did not stop within 12 seconds")
    }
}

private func discoveryMatchesListenAddress(
    _ discovery: ReviewDiscoveryRecord,
    host: String,
    port: Int
) -> Bool {
    guard discovery.port == port else {
        return false
    }
    return configuredHostCandidates(host).contains(normalizeLoopbackHost(discovery.host))
}

private func isAddressInUse(_ error: Error) -> Bool {
    String(describing: error).localizedCaseInsensitiveContains("address already in use")
}

private func normalizeLoopbackHost(_ host: String) -> String {
    if host == "localhost" || host == "::1" || host.hasPrefix("127.") {
        return "localhost"
    }
    return host
}

private func configuredHostCandidates(_ host: String) -> Set<String> {
    let configuredHost = normalizeLoopbackHost(
        normalizedDiscoveryHost(configuredHost: host, boundHost: host)
    )
    var candidates: Set<String> = [configuredHost]
    for candidate in resolvedHostCandidates(host) {
        candidates.insert(normalizeLoopbackHost(candidate))
    }
    for candidate in resolvedHostCandidates(configuredHost) {
        candidates.insert(normalizeLoopbackHost(candidate))
    }
    return candidates
}

private func resolvedHostCandidates(_ host: String) -> Set<String> {
    var hints = addrinfo(
        ai_flags: AI_ADDRCONFIG,
        ai_family: AF_UNSPEC,
        ai_socktype: SOCK_STREAM,
        ai_protocol: IPPROTO_TCP,
        ai_addrlen: 0,
        ai_canonname: nil,
        ai_addr: nil,
        ai_next: nil
    )
    var results: UnsafeMutablePointer<addrinfo>?
    let status = host.withCString { rawHost in
        getaddrinfo(rawHost, nil, &hints, &results)
    }
    guard status == 0, let results else {
        return []
    }
    defer { freeaddrinfo(results) }

    var candidates: Set<String> = []
    var cursor: UnsafeMutablePointer<addrinfo>? = results
    while let entry = cursor {
        if let address = entry.pointee.ai_addr {
            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let nameStatus = getnameinfo(
                address,
                entry.pointee.ai_addrlen,
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            if nameStatus == 0 {
                candidates.insert(String(cString: hostBuffer))
            }
        }
        cursor = entry.pointee.ai_next
    }
    return candidates
}
