import AppKit
import AuthenticationServices
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
        self.init(
            configuration: Self.makeConfiguration(
                environment: environment,
                arguments: arguments
            ),
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
        authSessionFactory: (@Sendable () async throws -> any ReviewAuthSession)? = nil,
        rateLimitObservationClock: any ReviewClock = ContinuousClock(),
        rateLimitStaleRefreshInterval: Duration = .seconds(60),
        inactiveRateLimitRefreshInterval: Duration = .seconds(15 * 60),
        deferStartupAuthRefreshUntilPrepared: Bool = false
    ) {
        let sharedFactory: (@Sendable ([String: String]) async throws -> any ReviewAuthSession)?
        let loginFactory: (@Sendable ([String: String]) async throws -> any ReviewAuthSession)?
        if let authSessionFactory {
            sharedFactory = { (_: [String: String]) async throws -> any ReviewAuthSession in
                try await authSessionFactory()
            }
            loginFactory = { environment in
                let baseSession = try await authSessionFactory()
                return try await LegacyProbeScopedReviewAuthSession(
                    base: baseSession,
                    sharedEnvironment: configuration.environment,
                    probeEnvironment: environment
                )
            }
        } else {
            sharedFactory = nil
            loginFactory = nil
        }
        self.init(
            configuration: configuration,
            diagnosticsURL: diagnosticsURL,
            appServerManager: appServerManager,
            sharedAuthSessionFactory: sharedFactory,
            loginAuthSessionFactory: loginFactory,
            rateLimitObservationClock: rateLimitObservationClock,
            rateLimitStaleRefreshInterval: rateLimitStaleRefreshInterval,
            inactiveRateLimitRefreshInterval: inactiveRateLimitRefreshInterval,
            deferStartupAuthRefreshUntilPrepared: deferStartupAuthRefreshUntilPrepared
        )
    }

    package convenience init(
        configuration: ReviewServerConfiguration,
        diagnosticsURL: URL? = nil,
        appServerManager: (any AppServerManaging)? = nil,
        sharedAuthSessionFactory: (@Sendable ([String: String]) async throws -> any ReviewAuthSession)? = nil,
        loginAuthSessionFactory: (@Sendable ([String: String]) async throws -> any ReviewAuthSession)? = nil,
        rateLimitObservationClock: any ReviewClock = ContinuousClock(),
        rateLimitStaleRefreshInterval: Duration = .seconds(60),
        inactiveRateLimitRefreshInterval: Duration = .seconds(15 * 60),
        deferStartupAuthRefreshUntilPrepared: Bool = false
    ) {
        let backend = CodexReviewEmbeddedServerBackend(
            configuration: configuration,
            appServerManager: appServerManager,
            sharedAuthSessionFactory: sharedAuthSessionFactory,
            loginAuthSessionFactory: loginAuthSessionFactory,
            rateLimitObservationClock: rateLimitObservationClock,
            rateLimitStaleRefreshInterval: rateLimitStaleRefreshInterval,
            inactiveRateLimitRefreshInterval: inactiveRateLimitRefreshInterval,
            deferStartupAuthRefreshUntilPrepared: deferStartupAuthRefreshUntilPrepared
        )
        self.init(
            backend: backend,
            authController: backend.authController,
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
public struct ReviewMonitorNativeAuthenticationConfiguration: Sendable {
    public enum BrowserSessionPolicy: Sendable {
        case ephemeral
    }

    public var callbackScheme: String
    public var browserSessionPolicy: BrowserSessionPolicy
    public var presentationAnchorProvider: @MainActor @Sendable () -> ASPresentationAnchor?

    public init(
        callbackScheme: String,
        browserSessionPolicy: BrowserSessionPolicy,
        presentationAnchorProvider: @escaping @MainActor @Sendable () -> ASPresentationAnchor?
    ) {
        self.callbackScheme = callbackScheme
        self.browserSessionPolicy = browserSessionPolicy
        self.presentationAnchorProvider = presentationAnchorProvider
    }
}

@MainActor
extension CodexReviewStore {
    @MainActor
    public static func makeReviewMonitorUITestStore() -> CodexReviewStore {
        let store = CodexReviewStore(backend: CodexReviewPreviewStoreBackend())
        store.serverState = .running
        store.serverURL = URL(string: "http://127.0.0.1:9417/mcp")
        let account = CodexAccount(email: "ui-test@example.com", planType: "unknown")
        store.auth.updateSavedAccounts([account])
        store.auth.updateAccount(account)
        return store
    }

    public static func makeReviewMonitorStore(
        nativeAuthenticationConfiguration: ReviewMonitorNativeAuthenticationConfiguration
    ) -> CodexReviewStore {
        let environment = ProcessInfo.processInfo.environment
        let arguments = CommandLine.arguments
        let configuration = makeConfiguration(
            environment: environment,
            arguments: arguments
        )
        let diagnosticsURL = makeDiagnosticsURL(
            environment: environment,
            arguments: arguments
        )
        let appServerManager = AppServerSupervisor(
            configuration: .init(
                codexCommand: configuration.codexCommand,
                environment: configuration.environment
            )
        )
        return makeReviewMonitorStore(
            configuration: configuration,
            diagnosticsURL: diagnosticsURL,
            appServerManager: appServerManager,
            nativeAuthenticationConfiguration: nativeAuthenticationConfiguration,
            webAuthenticationSessionFactory: ReviewMonitorWebAuthenticationSession.startSystem
        )
    }

    static func makeReviewMonitorStore(
        configuration: ReviewServerConfiguration,
        diagnosticsURL: URL? = nil,
        appServerManager: any AppServerManaging,
        nativeAuthenticationConfiguration: ReviewMonitorNativeAuthenticationConfiguration,
        webAuthenticationSessionFactory: @escaping ReviewMonitorWebAuthenticationSessionFactory,
        loginAuthSessionFactoryOverride: (@Sendable ([String: String]) async throws -> any ReviewAuthSession)? = nil
    ) -> CodexReviewStore {
        let loginAuthSessionFactory = makeReviewMonitorLoginAuthSessionFactory(
            configuration: configuration,
            nativeAuthenticationConfiguration: nativeAuthenticationConfiguration,
            webAuthenticationSessionFactory: webAuthenticationSessionFactory
        )

        return CodexReviewStore(
            configuration: configuration,
            diagnosticsURL: diagnosticsURL,
            appServerManager: appServerManager,
            loginAuthSessionFactory: loginAuthSessionFactoryOverride ?? loginAuthSessionFactory,
            deferStartupAuthRefreshUntilPrepared: true
        )
    }

    static func makeReviewMonitorLoginAuthSessionFactory(
        configuration: ReviewServerConfiguration,
        nativeAuthenticationConfiguration: ReviewMonitorNativeAuthenticationConfiguration,
        webAuthenticationSessionFactory: @escaping ReviewMonitorWebAuthenticationSessionFactory,
        runtimeManagerFactory: (@Sendable ([String: String]) -> any AppServerManaging)? = nil
    ) -> @Sendable ([String: String]) async throws -> any ReviewAuthSession {
        { environment in
            let runtimeManager = runtimeManagerFactory?(environment) ?? AppServerSupervisor(
                configuration: .init(
                    codexCommand: configuration.codexCommand,
                    environment: environment
                )
            )
            do {
                let transport = try await runtimeManager.checkoutAuthTransport()
                return await MainActor.run {
                    NativeWebAuthenticationReviewSession(
                        sharedSession: SharedAppServerReviewAuthSession(transport: transport),
                        nativeAuthenticationConfiguration: nativeAuthenticationConfiguration,
                        webAuthenticationSessionFactory: webAuthenticationSessionFactory,
                        onClose: { [runtimeManager] in
                            await runtimeManager.shutdown()
                        }
                    )
                }
            } catch {
                await runtimeManager.shutdown()
                throw error
            }
        }
    }
}

private actor LegacyProbeScopedReviewAuthSession: ReviewAuthSession {
    private let base: any ReviewAuthSession
    private let sharedAuthURL: URL
    private let probeAuthURL: URL
    private let originalSharedAuthData: Data?
    private let originalSharedAuthEmail: String?
    private var restoredSharedAuth = false

    init(
        base: any ReviewAuthSession,
        sharedEnvironment: [String: String],
        probeEnvironment: [String: String]
    ) async throws {
        self.base = base
        sharedAuthURL = ReviewHomePaths.reviewAuthURL(environment: sharedEnvironment)
        probeAuthURL = ReviewHomePaths.reviewAuthURL(environment: probeEnvironment)
        originalSharedAuthData = try? Data(contentsOf: sharedAuthURL)
        originalSharedAuthEmail = extractedAuthSnapshotEmail(from: originalSharedAuthData)
    }

    func readAccount(refreshToken: Bool) async throws -> AppServerAccountReadResponse {
        let response = try await base.readAccount(refreshToken: refreshToken)
        if case .chatGPT(let email, _)? = response.account,
           let email = email.nilIfEmpty
        {
            let currentSharedAuthData = try? Data(contentsOf: sharedAuthURL)
            if currentSharedAuthData != nil,
               (
                   currentSharedAuthData != originalSharedAuthData
                       || originalSharedAuthEmail == email
               )
            {
                copySharedAuthToProbe()
            }
        } else if response.requiresOpenAIAuth {
            removeProbeAuth()
        }
        return response
    }

    func startLogin(_ params: AppServerLoginAccountParams) async throws -> AppServerLoginAccountResponse {
        try await base.startLogin(params)
    }

    func cancelLogin(loginID: String) async throws {
        try await base.cancelLogin(loginID: loginID)
    }

    func logout() async throws {
        try await base.logout()
        removeProbeAuth()
        restoreSharedAuthIfNeeded()
    }

    func notificationStream() async -> AsyncThrowingStreamSubscription<AppServerServerNotification> {
        await base.notificationStream()
    }

    func close() async {
        await base.close()
        restoreSharedAuthIfNeeded()
    }

    private func copySharedAuthToProbe() {
        guard let data = try? Data(contentsOf: sharedAuthURL) else {
            return
        }
        try? FileManager.default.createDirectory(
            at: probeAuthURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: probeAuthURL, options: .atomic)
    }

    private func removeProbeAuth() {
        try? FileManager.default.removeItem(at: probeAuthURL)
    }

    private func restoreSharedAuthIfNeeded() {
        guard restoredSharedAuth == false else {
            return
        }
        restoredSharedAuth = true
        if let originalSharedAuthData {
            try? FileManager.default.createDirectory(
                at: sharedAuthURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? originalSharedAuthData.write(to: sharedAuthURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: sharedAuthURL)
        }
    }
}

private func makeReviewAuthToken(payload: [String: Any]) -> String {
    let header = ["alg": "none", "typ": "JWT"]
    let headerData = try? JSONSerialization.data(withJSONObject: header)
    let payloadData = try? JSONSerialization.data(withJSONObject: payload)
    return "\(makeReviewAuthTokenComponent(headerData ?? Data())).\(makeReviewAuthTokenComponent(payloadData ?? Data()))."
}

private func makeReviewAuthTokenComponent(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func extractedAuthSnapshotEmail(from authData: Data?) -> String? {
    guard let authData,
          let object = try? JSONSerialization.jsonObject(with: authData) as? [String: Any],
          let tokens = object["tokens"] as? [String: Any],
          let idToken = tokens["id_token"] as? String
    else {
        return nil
    }
    let components = idToken.split(separator: ".", omittingEmptySubsequences: false)
    guard components.count >= 2,
          let payloadData = decodeBase64URL(String(components[1])),
          let payloadObject = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
          let email = payloadObject["email"] as? String
    else {
        return nil
    }
    return email.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
}

private func decodeBase64URL(_ value: String) -> Data? {
    var normalized = value
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    let remainder = normalized.count % 4
    if remainder != 0 {
        normalized.append(String(repeating: "=", count: 4 - remainder))
    }
    return Data(base64Encoded: normalized)
}

typealias ReviewMonitorWebAuthenticationSessionFactory = @MainActor @Sendable (
    URL,
    String,
    ReviewMonitorNativeAuthenticationConfiguration.BrowserSessionPolicy,
    @escaping @MainActor @Sendable () -> ASPresentationAnchor?
) async throws -> ReviewMonitorWebAuthenticationSession

@MainActor
final class ReviewMonitorWebAuthenticationSession: Sendable {
    private final class PresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
        let anchor: ASPresentationAnchor

        init(anchor: ASPresentationAnchor) {
            self.anchor = anchor
        }

        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            _ = session
            return anchor
        }
    }

    private var session: ASWebAuthenticationSession?
    private var provider: PresentationContextProvider?
    private var continuation: CheckedContinuation<URL, Error>?
    private var result: Result<URL, ReviewAuthError>?
    private let onWaitStart: (@Sendable () async -> Void)?
    private let onCancel: (@Sendable () async -> Void)?

    init(
        onWaitStart: (@Sendable () async -> Void)? = nil,
        onCancel: (@Sendable () async -> Void)? = nil
    ) {
        self.onWaitStart = onWaitStart
        self.onCancel = onCancel
    }

    static func startSystem(
        using url: URL,
        callbackScheme: String,
        browserSessionPolicy: ReviewMonitorNativeAuthenticationConfiguration.BrowserSessionPolicy,
        presentationAnchorProvider: @escaping @MainActor @Sendable () -> ASPresentationAnchor?
    ) async throws -> ReviewMonitorWebAuthenticationSession {
        guard let anchor = presentationAnchorProvider() else {
            throw ReviewAuthError.loginFailed("Unable to present authentication session.")
        }

        let activeSession = ReviewMonitorWebAuthenticationSession()
        let provider = PresentationContextProvider(anchor: anchor)
        let session = ASWebAuthenticationSession(
            url: url,
            callback: .customScheme(callbackScheme),
            completionHandler: makeReviewMonitorWebAuthenticationCompletionHandler(activeSession)
        )
        session.prefersEphemeralWebBrowserSession = {
            switch browserSessionPolicy {
            case .ephemeral:
                true
            }
        }()
        session.presentationContextProvider = provider

        activeSession.install(
            session: session,
            provider: provider
        )
        let didStart = session.start()
        guard didStart else {
            activeSession.finish(
                callbackURL: nil,
                error: .loginFailed("Unable to start authentication session.")
            )
            throw ReviewAuthError.loginFailed("Unable to start authentication session.")
        }

        return activeSession
    }

    func waitForCallbackURL() async throws -> URL {
        await onWaitStart?()
        if let result {
            return try result.get()
        }
        return try await withCheckedThrowingContinuation { continuation in
            if let result {
                continuation.resume(with: result)
                return
            }
            self.continuation = continuation
        }
    }

    func cancel() async {
        await onCancel?()
        session?.cancel()
    }

    func finish(callbackURL: URL?, error: ReviewAuthError?) {
        guard result == nil else {
            return
        }
        let terminalResult: Result<URL, ReviewAuthError>
        if let callbackURL {
            terminalResult = .success(callbackURL)
        } else if let error {
            terminalResult = .failure(error)
        } else {
            terminalResult = .failure(.cancelled)
        }
        result = terminalResult
        session = nil
        provider = nil
        continuation?.resume(with: terminalResult)
        continuation = nil
    }

    func finishForTesting(_ result: Result<URL, ReviewAuthError>) {
        switch result {
        case .success(let callbackURL):
            finish(callbackURL: callbackURL, error: nil)
        case .failure(let error):
            finish(callbackURL: nil, error: error)
        }
    }

    private func install(
        session: ASWebAuthenticationSession,
        provider: PresentationContextProvider
    ) {
        self.session = session
        self.provider = provider
    }
}

private func mapAuthenticationError(_ error: Error?) -> ReviewAuthError? {
    guard let error else {
        return nil
    }
    if let reviewAuthError = error as? ReviewAuthError {
        return reviewAuthError
    }
    let nsError = error as NSError
    if nsError.domain == ASWebAuthenticationSessionErrorDomain,
       nsError.code == 1 {
        return .cancelled
    }
    return .loginFailed(error.localizedDescription)
}

private func makeReviewMonitorWebAuthenticationCompletionHandler(
    _ activeSession: ReviewMonitorWebAuthenticationSession
) -> @Sendable (URL?, Error?) -> Void {
    { [weak activeSession] callbackURL, error in
        let mappedError = mapAuthenticationError(error)
        Task { @MainActor [weak activeSession] in
            activeSession?.finish(callbackURL: callbackURL, error: mappedError)
        }
    }
}

actor NativeWebAuthenticationReviewSession: ReviewAuthSession {
    private enum NotificationTerminalState {
        case finished
        case failed(any Error)
    }

    private let sharedSession: SharedAppServerReviewAuthSession
    private let nativeAuthenticationConfiguration: ReviewMonitorNativeAuthenticationConfiguration
    private let webAuthenticationSessionFactory: ReviewMonitorWebAuthenticationSessionFactory
    private var notificationSubscribers: [UUID: AsyncThrowingStream<AppServerServerNotification, Error>.Continuation] = [:]
    private var bufferedNotifications: [AppServerServerNotification] = []
    private var notificationTerminalState: NotificationTerminalState?
    private var relayTask: Task<Void, Never>?
    private var relayCancellation: (@Sendable () async -> Void)?
    private var activeLoginID: String?
    private var activeAuthenticationSession: ReviewMonitorWebAuthenticationSession?
    private var authenticationTask: Task<Void, Never>?
    private var isClosed = false
    private let onClose: (@Sendable () async -> Void)?

    init(
        sharedSession: SharedAppServerReviewAuthSession,
        nativeAuthenticationConfiguration: ReviewMonitorNativeAuthenticationConfiguration,
        webAuthenticationSessionFactory: @escaping ReviewMonitorWebAuthenticationSessionFactory,
        onClose: (@Sendable () async -> Void)? = nil
    ) {
        self.sharedSession = sharedSession
        self.nativeAuthenticationConfiguration = nativeAuthenticationConfiguration
        self.webAuthenticationSessionFactory = webAuthenticationSessionFactory
        self.onClose = onClose
    }

    func readAccount(refreshToken: Bool) async throws -> AppServerAccountReadResponse {
        try await sharedSession.readAccount(refreshToken: refreshToken)
    }

    func startLogin(_ params: AppServerLoginAccountParams) async throws -> AppServerLoginAccountResponse {
        _ = params
        try throwIfClosed()
        try await startRelayIfNeeded()

        let response = try await sharedSession.startLogin(
            .chatGPT(
                nativeWebAuthentication: .init(
                    callbackURLScheme: nativeAuthenticationConfiguration.callbackScheme
                )
            )
        )

        guard case .chatGPT(let loginID, let authURL, let nativeWebAuthentication) = response,
              let authURL = URL(string: authURL)
        else {
            throw ReviewAuthError.loginFailed("Authentication did not provide a valid authorization URL.")
        }
        if isClosed {
            do {
                try await sharedSession.cancelLogin(loginID: loginID)
            } catch {
            }
            throw ReviewAuthError.cancelled
        }
        let callbackScheme = nativeWebAuthentication?.callbackURLScheme.nilIfEmpty
            ?? nativeAuthenticationConfiguration.callbackScheme
        if let serverCallbackScheme = nativeWebAuthentication?.callbackURLScheme.nilIfEmpty,
           serverCallbackScheme != nativeAuthenticationConfiguration.callbackScheme {
            do {
                try await sharedSession.cancelLogin(loginID: loginID)
            } catch {
            }
            throw ReviewAuthError.loginFailed(
                "Authentication callback is misconfigured. Update the app-server and try again."
            )
        }

        activeLoginID = loginID
        let activeAuthenticationSession: ReviewMonitorWebAuthenticationSession
        do {
            activeAuthenticationSession = try await webAuthenticationSessionFactory(
                authURL,
                callbackScheme,
                nativeAuthenticationConfiguration.browserSessionPolicy,
                nativeAuthenticationConfiguration.presentationAnchorProvider
            )
        } catch {
            activeLoginID = nil
            do {
                try await sharedSession.cancelLogin(loginID: loginID)
            } catch {
            }
            throw error
        }
        guard activeLoginID == loginID, isClosed == false else {
            await activeAuthenticationSession.cancel()
            if activeLoginID == loginID {
                activeLoginID = nil
            }
            throw ReviewAuthError.cancelled
        }
        self.activeAuthenticationSession = activeAuthenticationSession
        authenticationTask = Task {
            do {
                let callbackURL = try await activeAuthenticationSession.waitForCallbackURL()
                try await self.completeLogin(loginID: loginID, callbackURL: callbackURL)
            } catch ReviewAuthError.cancelled {
                await self.handleAuthenticationCancellation(for: loginID)
            } catch {
                await self.handleAuthenticationFailure(for: loginID, error: error)
            }
        }

        return response
    }

    func cancelLogin(loginID: String) async throws {
        guard activeLoginID == loginID else {
            return
        }
        let activeAuthenticationSession = self.activeAuthenticationSession
        self.activeAuthenticationSession = nil
        authenticationTask?.cancel()
        await activeAuthenticationSession?.cancel()
        activeLoginID = nil
        finishNotificationSubscribers(failing: nil, discardBufferedNotifications: true)
        authenticationTask = nil
        do {
            try await sharedSession.cancelLogin(loginID: loginID)
        } catch {
        }
    }

    func logout() async throws {
        try await sharedSession.logout()
    }

    func notificationStream() async -> AsyncThrowingStreamSubscription<AppServerServerNotification> {
        let (stream, continuation) = AsyncThrowingStream<AppServerServerNotification, Error>.makeStream()
        if let notificationTerminalState {
            for notification in bufferedNotifications {
                continuation.yield(notification)
            }
            finishNotificationContinuation(continuation, with: notificationTerminalState)
            return .init(stream: stream, cancel: {})
        }

        let subscriberID = UUID()
        notificationSubscribers[subscriberID] = continuation
        for notification in bufferedNotifications {
            continuation.yield(notification)
        }
        continuation.onTermination = { _ in
            Task {
                await self.removeNotificationSubscriber(id: subscriberID)
            }
        }
        return .init(
            stream: stream,
            cancel: { [weak self] in
                await self?.removeNotificationSubscriber(id: subscriberID)
            }
        )
    }

    func waitForAuthenticationTaskCompletion() async {
        _ = await authenticationTask?.result
    }

    func close() async {
        guard isClosed == false else {
            return
        }
        isClosed = true
        let activeLoginIDToCancel = activeLoginID
        let activeAuthenticationSession = self.activeAuthenticationSession
        activeLoginID = nil
        self.activeAuthenticationSession = nil
        authenticationTask?.cancel()
        finishNotificationSubscribers(failing: nil, discardBufferedNotifications: true)
        authenticationTask = nil
        await activeAuthenticationSession?.cancel()
        if let activeLoginIDToCancel {
            do {
                try await sharedSession.cancelLogin(loginID: activeLoginIDToCancel)
            } catch {
            }
        }
        if let relayCancellation {
            await relayCancellation()
            self.relayCancellation = nil
        }
        relayTask?.cancel()
        relayTask = nil
        await sharedSession.close()
        if let onClose {
            await onClose()
        }
    }

    private func startRelayIfNeeded() async throws {
        guard relayTask == nil else {
            return
        }
        let subscription = await sharedSession.notificationStream()
        relayCancellation = subscription.cancel
        relayTask = Task {
            do {
                for try await notification in subscription.stream {
                    await self.handleNotification(notification)
                }
                self.finishRelay(error: nil)
            } catch {
                self.finishRelay(error: error)
            }
        }
    }

    private func handleNotification(_ notification: AppServerServerNotification) async {
        guard notificationTerminalState == nil else {
            return
        }
        bufferedNotifications.append(notification)
        switch notification {
        case .accountLoginCompleted(let completed):
            let completedLoginID = completed.loginID?.nilIfEmpty
            if completedLoginID == nil || completedLoginID == activeLoginID {
                let activeAuthenticationSession = self.activeAuthenticationSession
                let authenticationTask = self.authenticationTask
                activeLoginID = nil
                self.activeAuthenticationSession = nil
                self.authenticationTask = nil
                authenticationTask?.cancel()
                await activeAuthenticationSession?.cancel()
            }
        default:
            break
        }
        for continuation in notificationSubscribers.values {
            continuation.yield(notification)
        }
    }

    private func completeLogin(loginID: String, callbackURL: URL) async throws {
        guard activeLoginID == loginID else {
            return
        }
        do {
            try await sharedSession.completeLogin(
                loginID: loginID,
                callbackURL: callbackURL.absoluteString
            )
            try await ensureAuthenticationCompletionDelivered(loginID: loginID)
        } catch let error as AppServerResponseError where error.isUnsupportedMethod {
            throw ReviewAuthError.loginFailed(
                "Authentication completion is unavailable. Update the app-server and try again."
            )
        }
    }

    private func ensureAuthenticationCompletionDelivered(loginID: String) async throws {
        if hasBufferedAuthenticationCompletion(loginID: loginID) {
            return
        }

        let shouldSynthesizeAccountUpdate = hasBufferedAuthenticationUpdate == false
        let synthesizedPlanType: String?
        if shouldSynthesizeAccountUpdate,
           let account = try? await sharedSession.readAccount(refreshToken: true),
           case .chatGPT(_, let planType) = account.account {
            synthesizedPlanType = planType
        } else {
            synthesizedPlanType = nil
        }

        if hasBufferedAuthenticationCompletion(loginID: loginID) {
            return
        }

        if hasBufferedAuthenticationUpdate == false,
           let synthesizedPlanType {
            await handleNotification(
                .accountUpdated(
                    try makeSyntheticAccountUpdatedNotification(planType: synthesizedPlanType)
                )
            )
        }

        if hasBufferedAuthenticationCompletion(loginID: loginID) {
            return
        }

        await handleNotification(
            .accountLoginCompleted(
                try makeSyntheticAccountLoginCompletedNotification(loginID: loginID)
            )
        )
    }

    private var hasBufferedAuthenticationUpdate: Bool {
        bufferedNotifications.contains { notification in
            if case .accountUpdated = notification {
                return true
            }
            return false
        }
    }

    private func hasBufferedAuthenticationCompletion(loginID: String) -> Bool {
        bufferedNotifications.contains { notification in
            guard case .accountLoginCompleted(let completed) = notification else {
                return false
            }
            guard let completedLoginID = completed.loginID?.nilIfEmpty else {
                return true
            }
            return completedLoginID == loginID
        }
    }

    private func makeSyntheticAccountUpdatedNotification(
        planType: String?
    ) throws -> AppServerAccountUpdatedNotification {
        var payload: [String: Any] = [
            "authMode": "chatgpt",
        ]
        payload["planType"] = planType
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(AppServerAccountUpdatedNotification.self, from: data)
    }

    private func makeSyntheticAccountLoginCompletedNotification(
        loginID: String
    ) throws -> AppServerAccountLoginCompletedNotification {
        let data = try JSONSerialization.data(
            withJSONObject: [
                "error": NSNull(),
                "loginId": loginID,
                "success": true,
            ]
        )
        return try JSONDecoder().decode(AppServerAccountLoginCompletedNotification.self, from: data)
    }

    private func handleAuthenticationCancellation(for loginID: String) async {
        guard activeLoginID == loginID else {
            return
        }
        activeLoginID = nil
        activeAuthenticationSession = nil
        finishNotificationSubscribers(failing: nil, discardBufferedNotifications: true)
        do {
            try await sharedSession.cancelLogin(loginID: loginID)
        } catch {
        }
        authenticationTask = nil
    }

    private func handleAuthenticationFailure(for loginID: String, error: Error) async {
        guard activeLoginID == loginID else {
            return
        }
        activeLoginID = nil
        activeAuthenticationSession = nil
        finishNotificationSubscribers(
            failing: error as? ReviewAuthError ?? ReviewAuthError.loginFailed(error.localizedDescription)
        )
        do {
            try await sharedSession.cancelLogin(loginID: loginID)
        } catch {
        }
        authenticationTask = nil
    }

    private func finishRelay(error: Error?) {
        relayTask = nil
        relayCancellation = nil
        if let error {
            finishNotificationSubscribers(failing: error)
        } else {
            finishNotificationSubscribers(failing: nil)
        }
    }

    private func removeNotificationSubscriber(id: UUID) {
        notificationSubscribers.removeValue(forKey: id)
    }

    private func finishNotificationSubscribers(
        failing error: Error?,
        discardBufferedNotifications: Bool = false
    ) {
        if notificationTerminalState == nil {
            notificationTerminalState = makeNotificationTerminalState(failing: error)
        }
        if discardBufferedNotifications {
            bufferedNotifications.removeAll(keepingCapacity: false)
        }
        let subscribers = notificationSubscribers.values
        notificationSubscribers.removeAll()
        for continuation in subscribers {
            finishNotificationContinuation(continuation, with: notificationTerminalState!)
        }
    }

    private func throwIfClosed() throws {
        if isClosed {
            throw ReviewAuthError.loginFailed("Authentication session is closed.")
        }
    }

    private func finishNotificationContinuation(
        _ continuation: AsyncThrowingStream<AppServerServerNotification, Error>.Continuation,
        with terminalState: NotificationTerminalState
    ) {
        switch terminalState {
        case .finished:
            continuation.finish()
        case .failed(let error):
            continuation.finish(throwing: error)
        }
    }

    private func makeNotificationTerminalState(failing error: Error?) -> NotificationTerminalState {
        guard let error else {
            return .finished
        }
        if error is CancellationError {
            return .finished
        }
        return .failed(error)
    }
}

@MainActor
private final class CodexReviewEmbeddedServerBackend: CodexReviewStoreBackend {
    let configuration: ReviewServerConfiguration
    let appServerManager: any AppServerManaging
    let accountRegistryStore: ReviewAccountRegistryStore
    let sharedAuthSessionFactory: (@Sendable ([String: String]) async throws -> any ReviewAuthSession)?
    let loginAuthSessionFactory: (@Sendable ([String: String]) async throws -> any ReviewAuthSession)?
    let deferStartupAuthRefreshUntilPrepared: Bool
    let shouldAutoStartEmbeddedServer: Bool
    let initialAccount: CodexAccount?
    let initialAccounts: [CodexAccount]
    let initialActiveAccountKey: String?
    let rateLimitObservationClock: any ReviewClock
    let rateLimitStaleRefreshInterval: Duration
    let inactiveRateLimitRefreshInterval: Duration
    lazy var liveSharedAuthSessionFactory: @Sendable ([String: String]) async throws -> any ReviewAuthSession = { [weak self, appServerManager, configuration] environment in
        let makeCLISession = {
            CLIReviewAuthSession(
                configuration: .init(
                    codexCommand: configuration.codexCommand,
                    environment: environment
                )
            )
        }
        let shouldUseSharedRuntime = await MainActor.run {
            self?.authRuntimeState.serverIsRunning ?? false
        }
        let shouldProbeInjectedManager = (appServerManager is AppServerSupervisor) == false
        guard shouldUseSharedRuntime || shouldProbeInjectedManager else {
            return makeCLISession()
        }
        do {
            let transport = try await appServerManager.checkoutAuthTransport()
            return SharedAppServerReviewAuthSession(transport: transport)
        } catch {
            guard shouldUseSharedRuntime else {
                return makeCLISession()
            }
            throw error
        }
    }
    lazy var liveCLIAuthSessionFactory: @Sendable ([String: String]) async throws -> any ReviewAuthSession = { [configuration] environment in
        CLIReviewAuthSession(
            configuration: .init(
                codexCommand: configuration.codexCommand,
                environment: environment
            )
        )
    }
    lazy var authController: CodexAuthController = {
        CodexAuthController(
            configuration: configuration,
            accountRegistryStore: accountRegistryStore,
            appServerManager: appServerManager,
            sharedAuthSessionFactory: sharedAuthSessionFactory ?? liveSharedAuthSessionFactory,
            loginAuthSessionFactory: loginAuthSessionFactory ?? liveCLIAuthSessionFactory,
            runtimeState: { [weak self] in
                self?.authRuntimeState ?? .stopped
            },
            recycleServerIfRunning: { [weak self] in
                await self?.recycleSharedAppServerAfterAuthChange()
            },
            cancelRunningJobs: { [weak self] reason in
                guard let store = self?.attachedStore else {
                    return
                }
                do {
                    try await store.cancelAllRunningJobs(reason: reason)
                } catch {
                    store.terminateAllRunningJobsLocally(
                        reason: reason,
                        failureMessage: error.localizedDescription
                    )
                    throw error
                }
            },
            rateLimitObservationClock: rateLimitObservationClock,
            rateLimitStaleRefreshInterval: rateLimitStaleRefreshInterval,
            inactiveRateLimitRefreshInterval: inactiveRateLimitRefreshInterval
        )
    }()
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
    private var startupTaskID: UUID?
    private var appServerRuntimeGeneration = 0
    private weak var attachedStore: CodexReviewStore?
    var closedSessions: Set<String> = []
    private var discoveryFileURL: URL {
        ReviewHomePaths.discoveryFileURL(environment: configuration.environment)
    }
    private var runtimeStateFileURL: URL {
        ReviewHomePaths.runtimeStateFileURL(environment: configuration.environment)
    }
    private var authRuntimeState: CodexAuthRuntimeState {
        .init(
            serverIsRunning: server != nil,
            runtimeGeneration: appServerRuntimeGeneration
        )
    }

    var initialSettingsSnapshot: CodexReviewSettingsSnapshot {
        let localConfig = (try? loadReviewLocalConfig(environment: configuration.environment)) ?? .init()
        let fallbackConfig = loadFallbackAppServerConfig(environment: configuration.environment)
        let profileClearsReviewModel = activeProfileClearsReviewModel(
            environment: configuration.environment
        )
        let profileClearsReasoningEffort = activeProfileClearsReasoningEffort(
            environment: configuration.environment
        )
        let profileClearsServiceTier = activeProfileClearsServiceTier(
            environment: configuration.environment
        )
        let displayedOverrides = resolveDisplayedSettingsOverrides(
            localConfig: localConfig,
            resolvedConfig: fallbackConfig,
            profileClearsReasoningEffort: profileClearsReasoningEffort,
            profileClearsServiceTier: profileClearsServiceTier
        )
        return .init(
            model: resolveReviewModelOverride(
                localConfig: localConfig,
                resolvedConfig: fallbackConfig,
                profileClearsReviewModel: profileClearsReviewModel
            ),
            fallbackModel: fallbackConfig.model?.nilIfEmpty,
            reasoningEffort: displayedOverrides.reasoningEffort,
            serviceTier: displayedOverrides.serviceTier,
            models: []
        )
    }

    var isActive: Bool {
        server != nil || waitTask != nil || startupTask != nil
    }

    init(
        configuration: ReviewServerConfiguration,
        appServerManager: (any AppServerManaging)? = nil,
        sharedAuthSessionFactory: (@Sendable ([String: String]) async throws -> any ReviewAuthSession)? = nil,
        loginAuthSessionFactory: (@Sendable ([String: String]) async throws -> any ReviewAuthSession)? = nil,
        rateLimitObservationClock: any ReviewClock = ContinuousClock(),
        rateLimitStaleRefreshInterval: Duration = .seconds(60),
        inactiveRateLimitRefreshInterval: Duration = .seconds(15 * 60),
        deferStartupAuthRefreshUntilPrepared: Bool = false
    ) {
        self.configuration = configuration
        self.appServerManager = appServerManager ?? AppServerSupervisor(
            configuration: .init(
                codexCommand: configuration.codexCommand,
                environment: configuration.environment
            )
        )
        self.accountRegistryStore = ReviewAccountRegistryStore(environment: configuration.environment)
        self.sharedAuthSessionFactory = sharedAuthSessionFactory
        self.loginAuthSessionFactory = loginAuthSessionFactory
        self.rateLimitObservationClock = rateLimitObservationClock
        self.rateLimitStaleRefreshInterval = rateLimitStaleRefreshInterval
        self.inactiveRateLimitRefreshInterval = inactiveRateLimitRefreshInterval
        self.deferStartupAuthRefreshUntilPrepared = deferStartupAuthRefreshUntilPrepared
        self.shouldAutoStartEmbeddedServer = configuration.shouldAutoStartEmbeddedServer
        var seededAccounts = loadRegisteredReviewAccounts(environment: configuration.environment)
        let sharedInitialAccount = loadSharedReviewAccount(environment: configuration.environment)
        if let sharedInitialAccount {
            let matchingSavedAccount = seededAccounts.accounts.first {
                normalizedReviewAccountEmail(email: $0.email)
                    == normalizedReviewAccountEmail(email: sharedInitialAccount.email)
            }
            let activeSavedAccount = seededAccounts.activeAccountKey.flatMap { activeAccountKey in
                seededAccounts.accounts.first(where: { $0.accountKey == activeAccountKey })
            }
            if matchingSavedAccount == nil || activeSavedAccount?.accountKey != matchingSavedAccount?.accountKey {
                _ = try? accountRegistryStore.saveSharedAuthAsSavedAccount(makeActive: true)
                seededAccounts = loadRegisteredReviewAccounts(environment: configuration.environment)
            }
        }

        let resolvedInitialAccount: CodexAccount? = {
            if let sharedInitialAccount {
                return seededAccounts.accounts.first {
                    normalizedReviewAccountEmail(email: $0.email)
                        == normalizedReviewAccountEmail(email: sharedInitialAccount.email)
                } ?? sharedInitialAccount
            }
            if let activeAccountKey = seededAccounts.activeAccountKey {
                return seededAccounts.accounts.first(where: { $0.accountKey == activeAccountKey })
            }
            return nil
        }()

        let initialAccounts = {
            var accounts = seededAccounts.accounts
            if let sharedInitialAccount,
               accounts.contains(where: {
                   normalizedReviewAccountEmail(email: $0.email)
                       == normalizedReviewAccountEmail(email: sharedInitialAccount.email)
               }) == false
            {
                accounts.insert(sharedInitialAccount, at: 0)
            }
            for account in accounts {
                account.updateIsActive(account.accountKey == resolvedInitialAccount?.accountKey)
            }
            return accounts
        }()
        self.initialAccounts = initialAccounts
        self.initialActiveAccountKey = resolvedInitialAccount?.accountKey
        self.initialAccount = resolvedInitialAccount
    }

    func attachStore(_ store: CodexReviewStore) {
        attachedStore = store
    }

    func start(
        store: CodexReviewStore,
        forceRestartIfNeeded: Bool
    ) async {
        closedSessions = []
        if deferStartupAuthRefreshUntilPrepared == false {
            store.auth.startStartupRefresh()
        }
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
        store.auth.cancelStartupRefresh()
        if store.auth.isAuthenticating {
            await store.auth.cancelAuthentication()
        }
        await store.auth.reconcileAuthenticatedSession(
            serverIsRunning: false,
            runtimeGeneration: appServerRuntimeGeneration
        )
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

    func refreshSettings() async throws -> CodexReviewSettingsSnapshot {
        let transport = try await appServerManager.checkoutAuthTransport()
        let localConfig = (try? loadReviewLocalConfig(environment: configuration.environment)) ?? .init()
        let fallbackConfig = loadFallbackAppServerConfig(environment: configuration.environment)
        let configResponse: AppServerConfigReadResponse = try await transport.request(
            method: "config/read",
            params: AppServerConfigReadParams(
                cwd: nil,
                includeLayers: false
            ),
            responseType: AppServerConfigReadResponse.self
        )
        var models: [CodexReviewModelCatalogItem] = []
        var cursor: String?
        repeat {
            let modelResponse: AppServerModelListResponse = try await transport.request(
                method: "model/list",
                params: AppServerModelListParams(
                    cursor: cursor,
                    limit: nil,
                    includeHidden: true
                ),
                responseType: AppServerModelListResponse.self
            )
            models.append(contentsOf: modelResponse.data)
            cursor = modelResponse.nextCursor?.nilIfEmpty
        } while cursor != nil
        let effectiveConfig = mergeAppServerConfig(
            primary: configResponse.config,
            fallback: fallbackConfig
        )
        let profileClearsReviewModel = activeProfileClearsReviewModel(
            environment: configuration.environment
        )
        let profileClearsReasoningEffort = activeProfileClearsReasoningEffort(
            environment: configuration.environment
        )
        let profileClearsServiceTier = activeProfileClearsServiceTier(
            environment: configuration.environment
        )
        let displayedOverrides = resolveDisplayedSettingsOverrides(
            localConfig: localConfig,
            resolvedConfig: effectiveConfig,
            profileClearsReasoningEffort: profileClearsReasoningEffort,
            profileClearsServiceTier: profileClearsServiceTier
        )
        let modelOverride = resolveReviewModelOverride(
            localConfig: localConfig,
            resolvedConfig: effectiveConfig,
            profileClearsReviewModel: profileClearsReviewModel
        )

        return .init(
            model: modelOverride,
            fallbackModel: effectiveConfig.model?.nilIfEmpty,
            reasoningEffort: displayedOverrides.reasoningEffort,
            serviceTier: displayedOverrides.serviceTier,
            models: models
        )
    }

    func updateSettingsModel(
        _ model: String?,
        reasoningEffort: CodexReviewReasoningEffort?,
        persistReasoningEffort: Bool,
        serviceTier: CodexReviewServiceTier?,
        persistServiceTier: Bool
    ) async throws {
        let profile = loadActiveReviewProfile(environment: configuration.environment)
        let localConfig = try loadReviewLocalConfig(environment: configuration.environment)
        let hasRootReviewModel = localConfig.reviewModel?.nilIfEmpty != nil
        let hasProfileReviewModelOverride = activeProfileHasReviewModelOverride(
            environment: configuration.environment
        )
        let writeModelAtRoot = profile == nil
            || (hasRootReviewModel && hasProfileReviewModelOverride == false)
        let hasRootReasoningEffort = localConfig.modelReasoningEffort?
            .nilIfEmpty
            .flatMap(CodexReviewReasoningEffort.init(rawValue:)) != nil
        let hasProfileReasoningEffortOverride = activeProfileHasReasoningEffortOverride(
            environment: configuration.environment
        )
        let writeReasoningAtRoot = profile == nil
            || (hasRootReasoningEffort && hasProfileReasoningEffortOverride == false)
        let hasRootServiceTier = localConfig.serviceTier?
            .nilIfEmpty
            .flatMap(CodexReviewServiceTier.init(rawValue:)) != nil
        let hasProfileServiceTierOverride = activeProfileHasServiceTierOverride(
            environment: configuration.environment
        )
        let writeServiceTierAtRoot = profile == nil
            || (serviceTier == nil && hasRootServiceTier && hasProfileServiceTierOverride == false)
        var edits: [AppServerConfigEdit] = [
            .init(
                keyPath: settingsKeyPath(
                    "review_model",
                    profileKeyPath: profile?.keyPathPrefix,
                    forceRoot: writeModelAtRoot
                ),
                value: model.map(AppServerJSONValue.string) ?? .null,
                mergeStrategy: .replace
            ),
        ]
        if persistReasoningEffort {
            edits.append(
                .init(
                    keyPath: settingsKeyPath(
                        "model_reasoning_effort",
                        profileKeyPath: profile?.keyPathPrefix,
                        forceRoot: writeReasoningAtRoot
                    ),
                    value: reasoningEffort.map { .string($0.rawValue) } ?? .null,
                    mergeStrategy: .replace
                )
            )
        }
        if persistServiceTier {
            edits.append(
                .init(
                    keyPath: settingsKeyPath(
                        "service_tier",
                        profileKeyPath: profile?.keyPathPrefix,
                        forceRoot: writeServiceTierAtRoot
                    ),
                    value: serviceTier.map { .string($0.rawValue) } ?? .null,
                    mergeStrategy: .replace
                )
            )
        }
        try await writeSettings(edits: edits)
    }

    func updateSettingsReasoningEffort(
        _ reasoningEffort: CodexReviewReasoningEffort?
    ) async throws {
        let profile = loadActiveReviewProfile(environment: configuration.environment)
        let localConfig = try loadReviewLocalConfig(environment: configuration.environment)
        let hasRootReasoningEffort = localConfig.modelReasoningEffort?
            .nilIfEmpty
            .flatMap(CodexReviewReasoningEffort.init(rawValue:)) != nil
        let hasProfileReasoningEffortOverride = activeProfileHasReasoningEffortOverride(
            environment: configuration.environment
        )
        let forceRoot = profile == nil
            || (hasRootReasoningEffort && hasProfileReasoningEffortOverride == false)
        try await writeSettings(
            edits: [
                .init(
                    keyPath: settingsKeyPath(
                        "model_reasoning_effort",
                        profileKeyPath: profile?.keyPathPrefix,
                        forceRoot: forceRoot
                    ),
                    value: reasoningEffort.map { .string($0.rawValue) } ?? .null,
                    mergeStrategy: .replace
                ),
            ]
        )
    }

    func updateSettingsServiceTier(
        _ serviceTier: CodexReviewServiceTier?
    ) async throws {
        let profile = loadActiveReviewProfile(environment: configuration.environment)
        let localConfig = try loadReviewLocalConfig(environment: configuration.environment)
        let hasRootServiceTier = localConfig.serviceTier?
            .nilIfEmpty
            .flatMap(CodexReviewServiceTier.init(rawValue:)) != nil
        let hasProfileServiceTierOverride = activeProfileHasServiceTierOverride(
            environment: configuration.environment
        )
        let forceRoot = profile == nil
            || (serviceTier == nil && hasRootServiceTier && hasProfileServiceTierOverride == false)
        try await writeSettings(
            edits: [
                .init(
                    keyPath: settingsKeyPath(
                        "service_tier",
                        profileKeyPath: profile?.keyPathPrefix,
                        forceRoot: forceRoot
                    ),
                    value: serviceTier.map { .string($0.rawValue) } ?? .null,
                    mergeStrategy: .replace
                ),
            ]
        )
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
            appServerRuntimeGeneration += 1
            store.transitionToRunning(serverURL: url)
            await store.auth.reconcileAuthenticatedSession(
                serverIsRunning: true,
                runtimeGeneration: appServerRuntimeGeneration
            )
            if deferStartupAuthRefreshUntilPrepared {
                store.auth.startStartupRefresh()
            }
            observeServerLifecycle(server: server, store: store)
        } catch is CancellationError {
            guard startupTaskID == startupID else {
                return
            }
            await server.stop()
            await appServerManager.shutdown()
            self.server = nil
            await store.auth.reconcileAuthenticatedSession(
                serverIsRunning: false,
                runtimeGeneration: appServerRuntimeGeneration
            )
        } catch {
            guard startupTaskID == startupID else {
                return
            }
            await server.stop()
            await appServerManager.shutdown()
            self.server = nil
            await store.auth.reconcileAuthenticatedSession(
                serverIsRunning: false,
                runtimeGeneration: appServerRuntimeGeneration
            )
            store.transitionToFailed(CodexReviewStore.errorMessage(from: error))
            if deferStartupAuthRefreshUntilPrepared {
                store.auth.startStartupRefresh()
            }
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
                store.auth.cancelStartupRefresh()
                await store.auth.reconcileAuthenticatedSession(
                    serverIsRunning: false,
                    runtimeGeneration: self.appServerRuntimeGeneration
                )
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
                store.auth.cancelStartupRefresh()
                await store.auth.reconcileAuthenticatedSession(
                    serverIsRunning: false,
                    runtimeGeneration: self.appServerRuntimeGeneration
                )
                self.closedSessions = []
                store.transitionToFailed(
                    CodexReviewStore.errorMessage(from: error),
                    resetJobs: true
                )
            }
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
            appServerRuntimeGeneration += 1
        } catch {
            let endpointRecord = server.currentEndpointRecord()
            removeRuntimeState(endpointRecord: endpointRecord)
            await server.stop()
            self.server = nil
            self.closedSessions = []
            if let store = attachedStore {
                await self.executionCoordinator.shutdown(reason: "Review server failed.", store: store)
                store.terminateAllRunningJobsLocally(
                    reason: "Review server failed.",
                    failureMessage: CodexReviewStore.errorMessage(from: error)
                )
                store.auth.cancelStartupRefresh()
                await store.auth.reconcileAuthenticatedSession(
                    serverIsRunning: false,
                    runtimeGeneration: self.appServerRuntimeGeneration
                )
                store.transitionToFailed(
                    CodexReviewStore.errorMessage(from: error),
                    resetJobs: false
                )
            }
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

    private func writeSettings(
        edits: [AppServerConfigEdit]
    ) async throws {
        let transport = try await appServerManager.checkoutAuthTransport()
        let _: AppServerConfigWriteResponse = try await transport.request(
            method: "config/batchWrite",
            params: AppServerConfigBatchWriteParams(
                edits: edits,
                filePath: nil,
                expectedVersion: nil,
                reloadUserConfig: true
            ),
            responseType: AppServerConfigWriteResponse.self
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
