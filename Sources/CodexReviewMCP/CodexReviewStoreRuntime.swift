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
        diagnosticsURL: URL? = nil
    ) {
        self.init(
            backend: CodexReviewEmbeddedServerBackend(configuration: configuration),
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
        reviewThreadID: String,
        sessionID: String
    ) throws -> ReviewReadResult {
        let job = try authorizedJob(reviewThreadID: reviewThreadID, sessionID: sessionID)
        return ReviewReadResult(
            reviewThreadID: publicReviewIdentifier(for: job),
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

    package func readReview(
        jobID: String,
        sessionID: String
    ) throws -> ReviewReadResult {
        let job = try authorizedJob(jobID: jobID, sessionID: sessionID)
        return ReviewReadResult(
            reviewThreadID: publicReviewIdentifier(for: job),
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
        reviewThreadID: String,
        sessionID: String,
        reason: String = "Cancellation requested."
    ) async throws -> ReviewCancelOutcome {
        try await liveBackend().executionCoordinator.cancelReview(
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
                job.logEntries.append(.init(kind: .progress, text: message))
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
                job.logEntries.append(entry)
                if cappedLogKinds.contains(entry.kind) {
                    trimDiagnosticEntries(job: job)
                }
            }
        case .rawLine(let line):
            updateJob(id: jobID) { job in
                job.logEntries.append(.init(kind: .diagnostic, text: line))
                trimDiagnosticEntries(job: job)
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
            job.errorMessage = outcome.errorMessage
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
            job.status = .failed
            job.summary = "Failed to start review."
            job.model = model ?? job.model
            job.errorMessage = message
            job.startedAt = startedAt
            job.endedAt = endedAt
            if message.isEmpty == false {
                job.logEntries.append(.init(kind: .error, text: message))
                trimDiagnosticEntries(job: job)
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
        let endedAt = Date()
        updateJob(id: jobID) { job in
            job.status = .cancelled
            job.summary = "Cancellation requested."
            job.hasFinalReview = false
            if reason.isEmpty == false {
                job.errorMessage = reason
            }
            job.endedAt = endedAt
        }
        return ReviewCancelResult(jobID: jobID, state: .cancelled, signalled: false)
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

        for workspace in workspaces.reversed() {
            workspace.jobs.removeAll { $0.sessionID == sessionID && $0.isTerminal }
        }
        workspaces.removeAll { $0.jobs.isEmpty }
        writeDiagnosticsIfNeeded()
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

    package func resolveJob(
        sessionID: String,
        selector: ReviewJobSelector
    ) throws -> CodexReviewJob {
        if let reviewThreadID = selector.reviewThreadID?.nilIfEmpty {
            return try authorizedJob(reviewThreadID: reviewThreadID, sessionID: sessionID)
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
            sortOrder: nextJobSortOrder(in: queued.request.cwd),
            sessionID: queued.sessionID,
            cwd: queued.request.cwd,
            reviewThreadID: nil,
            targetSummary: queued.request.targetSummary,
            model: queued.initialModel,
            threadID: nil,
            turnID: nil,
            status: .queued,
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
                sortOrder: nextWorkspaceSortOrder(),
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
        return matches.sorted(by: compareRuntimeJobs)
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

    private func nextWorkspaceSortOrder() -> Int {
        (workspaces.map(\.sortOrder).max() ?? 0) + 1
    }

    private func nextJobSortOrder(in cwd: String) -> Int {
        guard let workspace = workspaces.first(where: { $0.cwd == cwd }) else {
            return 1
        }
        return (workspace.jobs.map(\.sortOrder).max() ?? 0) + 1
    }

    private func authorizedJob(reviewThreadID: String, sessionID: String) throws -> CodexReviewJob {
        guard let location = jobLocation(reviewThreadID: reviewThreadID) else {
            throw ReviewError.jobNotFound("Review thread \(reviewThreadID) was not found.")
        }
        let job = workspaces[location.workspaceIndex].jobs[location.jobIndex]
        guard job.sessionID == sessionID else {
            throw ReviewError.accessDenied("Review thread \(reviewThreadID) belongs to another MCP session.")
        }
        return job
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
            reviewThreadID: publicReviewIdentifier(for: job),
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

    private func trimDiagnosticEntries(job: CodexReviewJob) {
        var currentBytes = cappedLogBytes(for: job.logEntries)

        while currentBytes > reviewLogLimitBytes {
            guard let index = job.logEntries.firstIndex(where: {
                trimmableCappedKinds.contains($0.kind)
            }) else {
                guard let errorIndex = job.logEntries.firstIndex(where: { $0.kind == .error }) else {
                    return
                }
                truncateEntry(at: errorIndex, in: job, keeping: .suffix, overflowBytes: currentBytes - reviewLogLimitBytes)
                currentBytes = cappedLogBytes(for: job.logEntries)
                continue
            }
            let entry = job.logEntries[index]
            let overflowBytes = currentBytes - reviewLogLimitBytes
            if entry.text.utf8.count > overflowBytes {
                truncateEntry(at: index, in: job, keeping: .prefix, overflowBytes: overflowBytes)
            } else {
                job.logEntries.remove(at: index)
            }
            currentBytes = cappedLogBytes(for: job.logEntries)
        }
    }

    private enum TruncationDirection {
        case prefix
        case suffix
    }

    private func truncateEntry(
        at index: Int,
        in job: CodexReviewJob,
        keeping direction: TruncationDirection,
        overflowBytes: Int
    ) {
        let entry = job.logEntries[index]
        let retainedBytes = max(0, entry.text.utf8.count - overflowBytes)
        let truncatedText = switch direction {
        case .prefix:
            truncateTextKeepingUTF8Prefix(entry.text, bytes: retainedBytes)
        case .suffix:
            truncateTextKeepingUTF8Suffix(entry.text, bytes: retainedBytes)
        }

        if truncatedText.isEmpty {
            job.logEntries.remove(at: index)
            return
        }

        job.logEntries[index] = .init(
            id: entry.id,
            kind: entry.kind,
            groupID: entry.groupID,
            replacesGroup: entry.replacesGroup,
            text: truncatedText,
            timestamp: entry.timestamp
        )
    }

    private func truncateTextKeepingUTF8Prefix(_ text: String, bytes maxBytes: Int) -> String {
        guard maxBytes > 0 else {
            return ""
        }

        var result = ""
        var usedBytes = 0
        for character in text {
            let characterBytes = String(character).utf8.count
            if usedBytes + characterBytes > maxBytes {
                break
            }
            result.append(character)
            usedBytes += characterBytes
        }
        return result
    }

    private func truncateTextKeepingUTF8Suffix(_ text: String, bytes maxBytes: Int) -> String {
        guard maxBytes > 0 else {
            return ""
        }

        var reversedCharacters: [Character] = []
        var usedBytes = 0
        for character in text.reversed() {
            let characterBytes = String(character).utf8.count
            if usedBytes + characterBytes > maxBytes {
                break
            }
            reversedCharacters.append(character)
            usedBytes += characterBytes
        }
        return String(reversedCharacters.reversed())
    }

    private func cappedLogBytes(for entries: [ReviewLogEntry]) -> Int {
        renderedBytesForGroupedEntries(
            entries.filter { cappedLogKinds.contains($0.kind) }
        )
    }

    private func renderedBytesForGroupedEntries(_ entries: [ReviewLogEntry]) -> Int {
        struct GroupKey: Hashable {
            var kind: ReviewLogEntry.Kind
            var groupID: String
        }

        struct RenderedBlock {
            var kind: ReviewLogEntry.Kind
            var text: String
        }

        var blocks: [RenderedBlock] = []
        var indexByGroup: [GroupKey: Int] = [:]

        for entry in entries {
            if groupedCappedKinds.contains(entry.kind),
               let groupID = entry.groupID,
               groupID.isEmpty == false
            {
                let key = GroupKey(kind: entry.kind, groupID: groupID)
                if let index = indexByGroup[key] {
                    if entry.replacesGroup {
                        blocks[index].text = entry.text
                    } else {
                        blocks[index].text.append(entry.text)
                    }
                    continue
                }
                indexByGroup[key] = blocks.count
            }

            blocks.append(.init(kind: entry.kind, text: entry.text))
        }

        return joinedSectionBytes(blocks.map(\.text).filter { $0.isEmpty == false })
    }

    private func joinedSectionBytes(_ sections: [String]) -> Int {
        guard var result = sections.first else {
            return 0
        }

        for next in sections.dropFirst() {
            if next.isEmpty {
                result += "\n\n"
                continue
            }
            if result.hasSuffix("\n\n") {
                result += next
                continue
            }
            if result.hasSuffix("\n") || next.hasPrefix("\n") {
                result += "\n"
            } else {
                result += "\n\n"
            }
            result += next
        }

        return result.utf8.count
    }

    private var cappedLogKinds: Set<ReviewLogEntry.Kind> {
        [
            .agentMessage,
            .commandOutput,
            .toolCall,
            .plan,
            .reasoningSummary,
            .rawReasoning,
            .diagnostic,
            .error,
        ]
    }

    private var groupedCappedKinds: Set<ReviewLogEntry.Kind> {
        [
            .agentMessage,
            .commandOutput,
            .plan,
            .reasoningSummary,
            .rawReasoning,
        ]
    }

    private var trimmableCappedKinds: Set<ReviewLogEntry.Kind> {
        cappedLogKinds.subtracting([.error])
    }

    private func jobLocation(reviewThreadID: String) -> (workspaceIndex: Int, jobIndex: Int)? {
        for (workspaceIndex, workspace) in workspaces.enumerated() {
            guard let jobIndex = workspace.jobs.firstIndex(where: {
                $0.reviewThreadID == reviewThreadID || $0.id == reviewThreadID
            }) else {
                continue
            }
            return (workspaceIndex, jobIndex)
        }
        return nil
    }

    private func publicReviewIdentifier(for job: CodexReviewJob) -> String {
        job.reviewThreadID ?? job.id
    }
}

@MainActor
private final class CodexReviewEmbeddedServerBackend: CodexReviewStoreBackend {
    let configuration: ReviewServerConfiguration
    let executionCoordinator: ReviewExecutionCoordinator

    private var server: ReviewMCPHTTPServer?
    private var waitTask: Task<Void, Never>?
    var closedSessions: Set<String> = []

    var isActive: Bool {
        server != nil || waitTask != nil
    }

    init(configuration: ReviewServerConfiguration) {
        self.configuration = configuration
        self.executionCoordinator = ReviewExecutionCoordinator(
            configuration: .init(
                codexCommand: configuration.codexCommand,
                environment: configuration.environment
            )
        )
    }

    func start(
        store: CodexReviewStore,
        forceRestartIfNeeded: Bool
    ) async {
        closedSessions = []

        let server = makeServer(store: store)
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
            store.transitionToRunning(serverURL: url)
            observeServerLifecycle(server: server, store: store)
        } catch {
            await server.stop()
            self.server = nil
            store.transitionToFailed(CodexReviewStore.errorMessage(from: error))
        }
    }

    func stop(store: CodexReviewStore) async {
        waitTask?.cancel()
        waitTask = nil
        if let server {
            await server.stop()
        }
        self.server = nil
        closedSessions = []
        _ = store
    }

    func waitUntilStopped() async {
        guard let waitTask else {
            return
        }
        _ = await waitTask.value
    }

    func cancelReview(
        jobID: String,
        sessionID: String,
        reason: String,
        store: CodexReviewStore
    ) async throws {
        let job = try store.resolveJob(jobID: jobID, sessionID: sessionID)
        _ = try await store.cancelReview(
            reviewThreadID: job.reviewThreadID ?? job.id,
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
            readReview: { [weak store] sessionID, reviewThreadID in
                guard let store else {
                    throw ReviewError.io("Review store is unavailable.")
                }
                return try store.readReview(reviewThreadID: reviewThreadID, sessionID: sessionID)
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
            cancelReviewByID: { [weak store] sessionID, reviewThreadID in
                guard let store else {
                    throw ReviewError.io("Review store is unavailable.")
                }
                return try await store.cancelReview(
                    reviewThreadID: reviewThreadID,
                    sessionID: sessionID
                )
            },
            cancelReviewBySelector: { [weak store] sessionID, cwd, statuses, latest in
                guard let store else {
                    throw ReviewError.io("Review store is unavailable.")
                }
                return try await store.cancelReview(
                    selector: .init(
                        reviewThreadID: nil,
                        cwd: cwd,
                        statuses: statuses,
                        latest: latest
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
                self.server = nil
                self.closedSessions = []
                store.transitionToStopped()
            } catch is CancellationError {
            } catch {
                guard let self, let store, self.server === server else {
                    return
                }
                self.server = nil
                self.closedSessions = []
                store.transitionToFailed(
                    CodexReviewStore.errorMessage(from: error),
                    resetJobs: true
                )
            }
        }
    }
}

@MainActor
private func compareRuntimeJobs(_ left: CodexReviewJob, _ right: CodexReviewJob) -> Bool {
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
    var initialModel: String?
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
