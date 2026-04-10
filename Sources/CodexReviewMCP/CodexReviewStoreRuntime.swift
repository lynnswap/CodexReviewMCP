import Darwin
import CodexReviewModel
import Foundation
import ReviewCore
import ReviewHTTPServer
import ReviewJobs
import ReviewRuntime

extension CodexReviewStore {
    public convenience init() {
        let environment = ProcessInfo.processInfo.environment
        let arguments = CommandLine.arguments
        let configuration = Self.makeConfiguration(
            environment: environment,
            arguments: arguments
        )
        self.init(
            backend: CodexReviewEmbeddedServerBackend(configuration: configuration),
            diagnosticsURL: Self.makeDiagnosticsURL(
                environment: environment,
                arguments: arguments
            )
        )
    }

    package convenience init(
        configuration: ReviewServerConfiguration,
        diagnosticsURL: URL? = nil,
        appServerManager: (any AppServerManaging)? = nil,
        authSessionFactory: (@Sendable () async throws -> any ReviewAuthSession)? = nil
    ) {
        self.init(
            backend: CodexReviewEmbeddedServerBackend(
                configuration: configuration,
                appServerManager: appServerManager,
                authSessionFactory: authSessionFactory
            ),
            diagnosticsURL: diagnosticsURL
        )
    }

    package func startReview(
        sessionID: String,
        request: ReviewStartRequest
    ) async throws -> ReviewReadResult {
        try await liveBackend().executionCoordinator.startReview(
            sessionID: sessionID,
            request: request,
            store: self
        )
    }

    package func readReview(
        jobID: String,
        sessionID: String
    ) throws -> ReviewReadResult {
        let job = try authorizedJob(jobID: jobID, sessionID: sessionID)
        return ReviewReadResult(
            jobID: job.id,
            threadID: job.threadID,
            turnID: job.turnID,
            model: job.model,
            status: job.status.state,
            review: job.isTerminal ? job.reviewText : (job.reviewText.nilIfEmpty ?? job.lastAgentMessage ?? ""),
            lastAgentMessage: job.lastAgentMessage ?? "",
            logs: job.logEntries,
            rawLogText: job.rawLogText,
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
        selectedJobID jobID: String,
        sessionID: String,
        reason: String = "Cancellation requested."
    ) async throws -> ReviewCancelOutcome {
        try await liveBackend().executionCoordinator.cancelReview(
            jobID: jobID,
            sessionID: sessionID,
            reason: reason,
            store: self
        )
    }

    package func cancelReview(
        selector: ReviewJobSelector,
        sessionID: String
    ) async throws -> ReviewCancelOutcome {
        try await liveBackend().executionCoordinator.cancelReview(
            selector: selector,
            sessionID: sessionID,
            store: self
        )
    }

    package func hasActiveJobs(for sessionID: String) -> Bool {
        for workspace in workspaces {
            if workspace.jobs.contains(where: { $0.sessionID == sessionID && $0.isTerminal == false }) {
                return true
            }
        }
        return false
    }

    package func closeSession(_ sessionID: String, reason: String) async {
        guard let backend = backend as? CodexReviewEmbeddedServerBackend else {
            return
        }
        await backend.executionCoordinator.closeSession(sessionID, reason: reason, store: self)
    }

    package func enqueueReview(
        sessionID: String,
        request: ReviewRequestOptions,
        initialModel: String? = nil
    ) throws -> String {
        let backend = try liveBackend()
        if backend.closedSessions.contains(sessionID) {
            throw ReviewError.accessDenied("Session \(sessionID) is already closed.")
        }
        let request = try request.validated()
        let jobID = UUID().uuidString
        appendQueuedJob(
            .init(jobID: jobID, sessionID: sessionID, request: request, initialModel: initialModel)
        )
        return jobID
    }

    package func markStarted(
        jobID: String,
        startedAt: Date
    ) {
        updateJob(id: jobID) { job in
            job.startedAt = startedAt
            job.cancellationRequested = false
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
                job.appendLogEntry(.init(kind: .progress, text: message))
            }
        case .reviewStarted(let reviewThreadID, let threadID, let turnID, let model):
            updateJob(id: jobID) { job in
                job.reviewThreadID = reviewThreadID
                job.threadID = threadID
                job.turnID = turnID
                job.model = model
                job.summary = "Review started: \(reviewThreadID)"
            }
        case .logEntry(let entry):
            updateJob(id: jobID) { job in
                job.appendLogEntry(entry)
            }
        case .rawLine(let line):
            updateJob(id: jobID) { job in
                job.appendLogEntry(.init(kind: .diagnostic, text: line))
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
        updateJob(id: jobID) { job in
            job.status = .init(state: outcome.state)
            job.cancellationRequested = false
            job.summary = outcome.summary
            job.model = outcome.model ?? job.model
            job.hasFinalReview = outcome.hasFinalReview
            if outcome.hasFinalReview {
                job.lastAgentMessage = outcome.content.nilIfEmpty
                    ?? outcome.lastAgentMessage.nilIfEmpty
                    ?? job.lastAgentMessage
            } else if outcome.state == .cancelled {
                let preservedContent = outcome.content.nilIfEmpty
                let preservedMessage = outcome.lastAgentMessage.nilIfEmpty
                let cancellationMessage = outcome.errorMessage?.nilIfEmpty
                if let preservedContent,
                   preservedContent != cancellationMessage
                {
                    job.lastAgentMessage = preservedContent
                } else if let preservedMessage,
                          preservedMessage != cancellationMessage
                {
                    job.lastAgentMessage = preservedMessage
                }
            } else {
                job.lastAgentMessage = outcome.lastAgentMessage.nilIfEmpty ?? job.lastAgentMessage
            }
            job.errorMessage = reviewAuthDisplayMessage(from: outcome.errorMessage)
            job.reviewThreadID = outcome.reviewThreadID ?? job.reviewThreadID
            job.threadID = outcome.threadID ?? job.threadID
            job.turnID = outcome.turnID ?? job.turnID
            job.startedAt = outcome.startedAt
            job.endedAt = outcome.endedAt
            job.exitCode = outcome.exitCode
        }
    }

    package func failToStart(
        jobID: String,
        message: String,
        model: String? = nil,
        startedAt: Date,
        endedAt: Date
    ) {
        updateJob(id: jobID) { job in
            job.cancellationRequested = false
            job.status = .failed
            job.summary = "Failed to start review."
            job.model = model ?? job.model
            job.errorMessage = reviewAuthDisplayMessage(from: message)
            job.startedAt = startedAt
            job.endedAt = endedAt
            if message.isEmpty == false {
                job.appendLogEntry(.init(kind: .error, text: message))
            }
        }
    }

    package func markBootstrapCancelled(
        jobID: String,
        reason: String,
        model: String? = nil,
        startedAt: Date,
        endedAt: Date
    ) {
        updateJob(id: jobID) { job in
            job.cancellationRequested = false
            job.status = .cancelled
            job.summary = "Review cancelled."
            job.model = model ?? job.model
            job.hasFinalReview = false
            job.errorMessage = reason.nilIfEmpty ?? job.errorMessage
            if job.startedAt == nil {
                job.startedAt = startedAt
            }
            job.endedAt = endedAt
        }
    }

    package func requestCancellation(
        jobID: String,
        sessionID: String,
        reason: String
    ) throws -> ReviewCancelResult {
        let requestCancellationDelay = Self.requestCancellationDelay
        if requestCancellationDelay > 0 {
            Thread.sleep(forTimeInterval: requestCancellationDelay)
        }
        guard let location = jobLocation(id: jobID) else {
            throw ReviewError.jobNotFound("Job \(jobID) was not found.")
        }
        let job = workspaces[location.workspaceIndex].jobs[location.jobIndex]
        guard job.sessionID == sessionID else {
            throw ReviewError.accessDenied("Job \(jobID) belongs to another MCP session.")
        }
        if job.isTerminal {
            return ReviewCancelResult(jobID: jobID, state: job.status.state, signalled: false)
        }

        if job.cancellationRequested {
            return ReviewCancelResult(jobID: jobID, state: job.status.state, signalled: true)
        }

        switch job.status {
        case .queued:
            let endedAt = Date()
            updateJob(id: jobID) { job in
                job.cancellationRequested = false
                job.status = .cancelled
                job.summary = "Review cancelled."
                job.hasFinalReview = false
                if reason.isEmpty == false {
                    job.errorMessage = reason
                }
                job.endedAt = endedAt
            }
            return ReviewCancelResult(jobID: jobID, state: .cancelled, signalled: false)
        case .running:
            updateJob(id: jobID) { job in
                job.cancellationRequested = true
                job.summary = "Cancellation requested."
                job.hasFinalReview = false
                if reason.isEmpty == false {
                    job.errorMessage = reason
                }
            }
            return ReviewCancelResult(jobID: jobID, state: .running, signalled: true)
        case .succeeded, .failed, .cancelled:
            return ReviewCancelResult(jobID: jobID, state: job.status.state, signalled: false)
        }
    }

    package func discardQueuedOrRunningJob(jobID: String) {
        removeJob(id: jobID)
    }

    package func resolveJob(
        jobID: String,
        sessionID: String
    ) throws -> CodexReviewJob {
        try authorizedJob(jobID: jobID, sessionID: sessionID)
    }

    package func pendingTerminationReason(
        jobID: String,
        sessionID: String
    ) -> ReviewTerminationReason? {
        let defaultReason = "Cancellation requested."
        let closedSessionReason: ReviewTerminationReason? = {
            guard let backend = backend as? CodexReviewEmbeddedServerBackend,
                  backend.closedSessions.contains(sessionID)
            else {
                return nil
            }
            return .cancelled(defaultReason)
        }()

        guard let location = jobLocation(id: jobID) else {
            return closedSessionReason
        }
        let job = workspaces[location.workspaceIndex].jobs[location.jobIndex]
        guard job.sessionID == sessionID else {
            return .cancelled(defaultReason)
        }
        if job.status == .cancelled || job.cancellationRequested {
            return .cancelled(job.errorMessage?.nilIfEmpty ?? defaultReason)
        }
        return closedSessionReason
    }

    package func closeSessionState(_ sessionID: String) -> [String] {
        guard let backend = backend as? CodexReviewEmbeddedServerBackend else {
            return []
        }
        backend.closedSessions.insert(sessionID)
        var activeJobIDs: [String] = []
        for workspace in workspaces {
            activeJobIDs.append(
                contentsOf: workspace.jobs
                    .filter { $0.sessionID == sessionID && $0.isTerminal == false }
                    .map(\.id)
            )
        }
        return activeJobIDs
    }

    package func pruneClosedJobIfNeeded(jobID: String) {
        guard let backend = backend as? CodexReviewEmbeddedServerBackend,
              let location = jobLocation(id: jobID)
        else {
            return
        }
        let job = workspaces[location.workspaceIndex].jobs[location.jobIndex]
        guard backend.closedSessions.contains(job.sessionID),
              job.isTerminal
        else {
            return
        }
        removeJob(id: jobID)
    }

    package func pruneClosedSessionJobs(
        sessionID: String,
        excludingJobIDs: Set<String> = []
    ) {
        guard let backend = backend as? CodexReviewEmbeddedServerBackend,
              backend.closedSessions.contains(sessionID)
        else {
            return
        }

        for workspace in workspaces.reversed() {
            workspace.jobs.removeAll { job in
                job.sessionID == sessionID
                    && job.isTerminal
                    && excludingJobIDs.contains(job.id) == false
            }
        }
        workspaces.removeAll { $0.jobs.isEmpty }
        writeDiagnosticsIfNeeded()
    }

    package func resolveJob(
        sessionID: String,
        selector: ReviewJobSelector
    ) throws -> CodexReviewJob {
        if let jobID = selector.jobID?.nilIfEmpty {
            return try authorizedJob(jobID: jobID, sessionID: sessionID)
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
        guard candidates.count == 1 else {
            throw ReviewJobSelectionError.ambiguous(candidates.map(makeListItem))
        }
        return candidates[0]
    }

    private func liveBackend() throws -> CodexReviewEmbeddedServerBackend {
        guard let backend = backend as? CodexReviewEmbeddedServerBackend else {
            throw ReviewError.io("CodexReviewStore live runtime is unavailable.")
        }
        return backend
    }

    fileprivate static func errorMessage(from error: Error) -> String {
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
            shouldAutoStartEmbeddedServer: CodexReviewStoreLaunchPolicy.shouldAutoStartEmbeddedServer(
                environment: environment,
                arguments: arguments
            ),
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

    private func appendQueuedJob(_ queued: ReviewQueuedJob) {
        let job = CodexReviewJob(
            id: queued.jobID,
            sessionID: queued.sessionID,
            cwd: queued.request.cwd,
            reviewThreadID: nil,
            targetSummary: queued.request.targetSummary,
            model: queued.initialModel,
            threadID: nil,
            turnID: nil,
            status: .queued,
            cancellationRequested: false,
            startedAt: nil,
            endedAt: nil,
            summary: "Queued.",
            hasFinalReview: false,
            lastAgentMessage: nil,
            logEntries: [],
            errorMessage: nil,
            exitCode: nil
        )

        if let workspaceIndex = workspaces.firstIndex(where: { $0.cwd == queued.request.cwd }) {
            let workspace = workspaces[workspaceIndex]
            workspace.jobs = [job] + workspace.jobs
        } else {
            let workspace = CodexReviewWorkspace(
                cwd: queued.request.cwd,
                jobs: [job]
            )
            workspaces = [workspace] + workspaces
        }
        writeDiagnosticsIfNeeded()
    }

    private func updateJob(
        id: String,
        _ update: (CodexReviewJob) -> Void
    ) {
        guard let location = jobLocation(id: id) else {
            return
        }
        let job = workspaces[location.workspaceIndex].jobs[location.jobIndex]
        update(job)
        writeDiagnosticsIfNeeded()
    }

    private func removeJob(id: String) {
        guard let location = jobLocation(id: id) else {
            return
        }

        let workspace = workspaces[location.workspaceIndex]
        workspace.jobs.remove(at: location.jobIndex)
        if workspace.jobs.isEmpty {
            workspaces.remove(at: location.workspaceIndex)
        }
        writeDiagnosticsIfNeeded()
    }

    private func filteredJobs(
        sessionID: String,
        cwd: String?,
        statuses: [ReviewJobState]?
    ) -> [CodexReviewJob] {
        let normalizedCWD = cwd?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let allowedStatuses = statuses.map(Set.init)
        var matches: [CodexReviewJob] = []
        for workspace in workspaces {
            for job in workspace.jobs where job.sessionID == sessionID {
                if let normalizedCWD, job.cwd != normalizedCWD {
                    continue
                }
                if let allowedStatuses, allowedStatuses.contains(job.status.state) == false {
                    continue
                }
                matches.append(job)
            }
        }
        return matches
    }

    private func jobLocation(id: String) -> (workspaceIndex: Int, jobIndex: Int)? {
        for (workspaceIndex, workspace) in workspaces.enumerated() {
            guard let jobIndex = workspace.jobs.firstIndex(where: { $0.id == id }) else {
                continue
            }
            return (workspaceIndex, jobIndex)
        }
        return nil
    }

    private func authorizedJob(jobID: String, sessionID: String) throws -> CodexReviewJob {
        guard let location = jobLocation(id: jobID) else {
            throw ReviewError.jobNotFound("Job \(jobID) was not found.")
        }
        let job = workspaces[location.workspaceIndex].jobs[location.jobIndex]
        guard job.sessionID == sessionID else {
            throw ReviewError.accessDenied("Job \(jobID) belongs to another MCP session.")
        }
        return job
    }

    private func makeListItem(_ job: CodexReviewJob) -> ReviewJobListItem {
        ReviewJobListItem(
            jobID: job.id,
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
            cancellable: job.isTerminal == false && job.cancellationRequested == false
        )
    }

    private func elapsedSeconds(for job: CodexReviewJob) -> Int? {
        guard let startedAt = job.startedAt else {
            return nil
        }
        let endedAt = job.endedAt ?? (job.isTerminal ? Date() : nil) ?? Date()
        return Int(endedAt.timeIntervalSince(startedAt))
    }

}

@MainActor
private final class CodexReviewEmbeddedServerBackend: CodexReviewStoreBackend {
    let configuration: ReviewServerConfiguration
    let appServerManager: any AppServerManaging
    let authSessionFactory: (@Sendable () async throws -> any ReviewAuthSession)?
    let shouldAutoStartEmbeddedServer: Bool
    let initialAuthState: CodexReviewAuthModel.State
    lazy var liveAuthSessionFactory: @Sendable () async throws -> any ReviewAuthSession = { [configuration] in
        CLIReviewAuthSession(
            configuration: .init(
                codexCommand: configuration.codexCommand,
                environment: configuration.environment
            )
        )
    }
    lazy var authManager = ReviewAuthManager(
        configuration: .init(
            codexCommand: configuration.codexCommand,
            environment: configuration.environment
        ),
        sessionFactory: authSessionFactory ?? liveAuthSessionFactory
    )
    lazy var executionCoordinator: ReviewExecutionCoordinator = {
        ReviewExecutionCoordinator(
            configuration: .init(
                codexCommand: configuration.codexCommand,
                environment: configuration.environment
            ),
            appServerManager: appServerManager,
            runtimeStateDidChange: { [weak self] runtimeState in
                await MainActor.run { [weak self] in
                    guard let self, let server = self.server else {
                        return
                    }
                    self.writeRuntimeState(
                        endpointRecord: server.currentEndpointRecord(),
                        appServerRuntimeState: runtimeState
                    )
                }
            }
        )
    }()

    private var server: ReviewMCPHTTPServer?
    private var waitTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var authRefreshTask: Task<Void, Never>?
    private var startupTaskID: UUID?
    var closedSessions: Set<String> = []
    private var discoveryFileURL: URL {
        ReviewHomePaths.discoveryFileURL(environment: configuration.environment)
    }
    private var runtimeStateFileURL: URL {
        ReviewHomePaths.runtimeStateFileURL(environment: configuration.environment)
    }

    var isActive: Bool {
        server != nil || waitTask != nil || startupTask != nil
    }

    init(
        configuration: ReviewServerConfiguration,
        appServerManager: (any AppServerManaging)? = nil,
        authSessionFactory: (@Sendable () async throws -> any ReviewAuthSession)? = nil
    ) {
        self.configuration = configuration
        self.appServerManager = appServerManager ?? AppServerSupervisor(
            configuration: .init(
                codexCommand: configuration.codexCommand,
                environment: configuration.environment
            )
        )
        self.authSessionFactory = authSessionFactory
        self.shouldAutoStartEmbeddedServer = configuration.shouldAutoStartEmbeddedServer
        self.initialAuthState = loadStoredReviewAuthState(environment: configuration.environment) ?? .signedOut
    }

    func start(
        store: CodexReviewStore,
        forceRestartIfNeeded: Bool
    ) async {
        closedSessions = []
        let startupID = UUID()
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

    func stop(store: CodexReviewStore) async {
        let startupTask = self.startupTask
        self.startupTask = nil
        startupTaskID = nil
        startupTask?.cancel()
        authRefreshTask?.cancel()
        authRefreshTask = nil
        waitTask?.cancel()
        waitTask = nil
        await executionCoordinator.shutdown(reason: "Review server stopped.", store: store)
        if let server {
            let endpointRecord = server.currentEndpointRecord()
            self.server = nil
            await server.stop()
            await appServerManager.shutdown()
            removeRuntimeState(endpointRecord: endpointRecord)
        } else {
            await appServerManager.shutdown()
        }
        closedSessions = []
        await startupTask?.value
    }

    func waitUntilStopped() async {
        if let startupTask {
            await startupTask.value
        }
        if let waitTask {
            _ = await waitTask.value
        }
    }

    func cancelReview(
        jobID: String,
        sessionID: String,
        reason: String,
        store: CodexReviewStore
    ) async throws {
        let job = try store.resolveJob(jobID: jobID, sessionID: sessionID)
        _ = try await store.cancelReview(
            selectedJobID: job.id,
            sessionID: sessionID,
            reason: reason
        )
    }

    func refreshAuthState(auth: CodexReviewAuthModel) async {
        do {
            let state = try await authManager.loadState()
            if auth.isAuthenticating {
                return
            }
            auth.updateState(state)
        } catch {
            if auth.isAuthenticating == false {
                auth.updateState(.signedOut)
            }
        }
    }

    func beginAuthentication(auth: CodexReviewAuthModel) async {
        authRefreshTask?.cancel()
        authRefreshTask = nil
        do {
            try await authManager.beginAuthentication { state in
                await MainActor.run {
                    auth.updateState(state)
                }
            }
            await recycleSharedAppServerAfterAuthChange()
        } catch ReviewAuthError.cancelled {
            auth.updateState(.signedOut)
        } catch let error as ReviewAuthError {
            auth.updateState(.failed(error.errorDescription ?? "Authentication failed."))
        } catch {
            auth.updateState(.failed(error.localizedDescription))
        }
    }

    func cancelAuthentication(auth: CodexReviewAuthModel) async {
        await authManager.cancelAuthentication()
        auth.updateState(.signedOut)
    }

    func logout(auth: CodexReviewAuthModel) async {
        authRefreshTask?.cancel()
        authRefreshTask = nil
        do {
            let state = try await authManager.logout()
            auth.updateState(state)
            await recycleSharedAppServerAfterAuthChange()
        } catch let error as ReviewAuthError {
            auth.updateState(
                .failed(
                    error.errorDescription ?? "Failed to sign out.",
                    isAuthenticated: auth.isAuthenticated,
                    accountID: auth.accountID
                )
            )
        } catch {
            auth.updateState(
                .failed(
                    error.localizedDescription,
                    isAuthenticated: auth.isAuthenticated,
                    accountID: auth.accountID
                )
            )
        }
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
            cancelReviewByID: { [weak store] sessionID, jobID in
                guard let store else {
                    throw ReviewError.io("Review store is unavailable.")
                }
                return try await store.cancelReview(
                    selectedJobID: jobID,
                    sessionID: sessionID
                )
            },
            cancelReviewBySelector: { [weak store] sessionID, cwd, statuses in
                guard let store else {
                    throw ReviewError.io("Review store is unavailable.")
                }
                return try await store.cancelReview(
                    selector: .init(
                        jobID: nil,
                        cwd: cwd,
                        statuses: statuses
                    ),
                    sessionID: sessionID
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
        startupID: UUID,
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
            ReviewRuntimeStateStore.remove(at: runtimeStateFileURL)

            let appServerRuntimeState = try await appServerManager.prepare()
            guard startupTaskID == startupID, self.server === server else {
                return
            }

            writeRuntimeState(
                endpointRecord: server.currentEndpointRecord(),
                appServerRuntimeState: appServerRuntimeState
            )
            store.transitionToRunning(serverURL: url)
            startAuthRefreshTask(auth: store.auth)
            observeServerLifecycle(server: server, store: store)
        } catch is CancellationError {
            guard startupTaskID == startupID else {
                return
            }
            await server.stop()
            await appServerManager.shutdown()
            self.server = nil
        } catch {
            guard startupTaskID == startupID else {
                return
            }
            await server.stop()
            await appServerManager.shutdown()
            self.server = nil
            store.transitionToFailed(CodexReviewStore.errorMessage(from: error))
        }
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
        let runtimeState = ReviewRuntimeStateStore.read(from: runtimeStateFileURL)
        if let endpointRecord = addressInUseCleanupRecord(runtimeState: runtimeState) {
            try await forceRestart(
                endpointRecord: endpointRecord,
                runtimeState: runtimeState
            )
            ReviewDiscovery.removeIfOwned(
                pid: endpointRecord.pid,
                url: URL(string: endpointRecord.url),
                serverStartTime: endpointRecord.serverStartTime,
                at: discoveryFileURL
            )
            ReviewRuntimeStateStore.removeIfOwned(
                serverPID: endpointRecord.pid,
                serverStartTime: endpointRecord.serverStartTime,
                at: runtimeStateFileURL
            )
        }
    }

    private func addressInUseCleanupRecord(
        runtimeState: ReviewRuntimeStateRecord?
    ) -> LiveEndpointRecord? {
        if let endpointRecord = ReviewDiscovery.readPersisted(from: discoveryFileURL),
           discoveryMatchesListenAddress(
            endpointRecord,
            host: configuration.host,
            port: configuration.port
           )
        {
            return endpointRecord
        }

        guard let runtimeState,
              let url = ReviewDiscovery.makeURL(
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
                await self.executionCoordinator.shutdown(reason: "Review server stopped.", store: store)
                let endpointRecord = server.currentEndpointRecord()
                await server.stop()
                await self.appServerManager.shutdown()
                self.removeRuntimeState(endpointRecord: endpointRecord)
                self.server = nil
                self.authRefreshTask?.cancel()
                self.authRefreshTask = nil
                self.closedSessions = []
                store.transitionToStopped()
            } catch is CancellationError {
            } catch {
                guard let self, let store, self.server === server else {
                    return
                }
                await self.executionCoordinator.shutdown(reason: "Review server failed.", store: store)
                let endpointRecord = server.currentEndpointRecord()
                await server.stop()
                await self.appServerManager.shutdown()
                self.removeRuntimeState(endpointRecord: endpointRecord)
                self.server = nil
                self.authRefreshTask?.cancel()
                self.authRefreshTask = nil
                self.closedSessions = []
                store.transitionToFailed(
                    CodexReviewStore.errorMessage(from: error),
                    resetJobs: true
                )
            }
        }
    }

    private func startAuthRefreshTask(auth: CodexReviewAuthModel) {
        authRefreshTask?.cancel()
        authRefreshTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            await self.refreshAuthState(auth: auth)
        }
    }

    private func recycleSharedAppServerAfterAuthChange() async {
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
        } catch {
        }
    }

    private func writeRuntimeState(
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
            updatedAt: Date()
        )
        try? ReviewRuntimeStateStore.write(runtimeState, to: runtimeStateFileURL)
    }

    private func removeRuntimeState(endpointRecord: LiveEndpointRecord?) {
        guard let endpointRecord else {
            return
        }
        ReviewRuntimeStateStore.removeIfOwned(
            serverPID: endpointRecord.pid,
            serverStartTime: endpointRecord.serverStartTime,
            at: runtimeStateFileURL
        )
    }
}

private struct ReviewQueuedJob {
    var jobID: String
    var sessionID: String
    var request: ReviewRequestOptions
    var initialModel: String?
}

package func forceRestart(
    _ discovery: LiveEndpointRecord,
    runtimeState: ReviewRuntimeStateRecord? = nil,
    terminateGracePeriod: Duration = .seconds(10),
    killGracePeriod: Duration = .seconds(2)
) async throws {
    try await forceRestart(
        discovery,
        runtimeState: runtimeState,
        terminateGracePeriod: terminateGracePeriod,
        killGracePeriod: killGracePeriod,
        clock: ContinuousClock()
    )
}

package func forceRestart<C: Clock>(
    _ discovery: LiveEndpointRecord,
    runtimeState: ReviewRuntimeStateRecord? = nil,
    terminateGracePeriod: Duration = .seconds(10),
    killGracePeriod: Duration = .seconds(2),
    clock: C
) async throws where C.Duration == Duration {
    do {
        try await forceStopDiscoveredServerProcess(
            discovery,
            terminateGracePeriod: terminateGracePeriod,
            killGracePeriod: killGracePeriod,
            runtimeState: runtimeState,
            clock: clock
        )
    } catch let error as ForcedRestartError {
        throw ReviewError.io(error.message)
    }
}

private func discoveryMatchesListenAddress(
    _ discovery: LiveEndpointRecord,
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
                let length = hostBuffer.firstIndex(of: 0) ?? hostBuffer.count
                let numericHost = String(
                    decoding: hostBuffer[..<length].map { UInt8(bitPattern: $0) },
                    as: UTF8.self
                )
                candidates.insert(numericHost)
            }
        }
        cursor = entry.pointee.ai_next
    }
    return candidates
}
