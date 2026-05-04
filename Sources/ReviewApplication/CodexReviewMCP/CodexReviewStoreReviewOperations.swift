import Foundation
import ReviewPorts
import ReviewDomain

extension CodexReviewStore {
    package func startReview(
        sessionID: String,
        request: ReviewStartRequest
    ) async throws -> ReviewReadResult {
        try await coordinator.startReview(
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
            cancellation: job.cancellation,
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
        cancellation: ReviewCancellation = .system()
    ) async throws -> ReviewCancelOutcome {
        try await coordinator.cancelReviewByID(
            jobID: jobID,
            sessionID: sessionID,
            cancellation: cancellation,
            store: self
        )
    }

    package func cancelReview(
        selector: ReviewJobSelector,
        sessionID: String,
        cancellation: ReviewCancellation = .system()
    ) async throws -> ReviewCancelOutcome {
        try await coordinator.cancelReviewBySelector(
            selector: selector,
            sessionID: sessionID,
            cancellation: cancellation,
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
        await coordinator.closeSession(sessionID, reason: reason, store: self)
    }

    package func enqueueReview(
        sessionID: String,
        request: ReviewRequestOptions,
        initialModel: String? = nil
    ) throws -> String {
        if coordinator.isSessionClosed(sessionID) {
            throw ReviewError.accessDenied("Session \(sessionID) is already closed.")
        }
        let request = try request.validated()
        let jobID = coreDependencies.uuid().uuidString
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
            job.summary = if outcome.state == .cancelled {
                job.cancellation?.message ?? outcome.errorMessage?.nilIfEmpty ?? outcome.summary
            } else {
                outcome.summary
            }
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
            if outcome.state != .cancelled {
                job.cancellation = nil
            }
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
            job.cancellation = nil
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
        cancellation: ReviewCancellation,
        model: String? = nil,
        startedAt: Date,
        endedAt: Date
    ) {
        updateJob(id: jobID) { job in
            job.cancellationRequested = false
            job.cancellation = cancellation
            job.status = .cancelled
            job.summary = cancellation.message
            job.model = model ?? job.model
            job.hasFinalReview = false
            job.errorMessage = cancellation.message.nilIfEmpty ?? job.errorMessage
            if job.startedAt == nil {
                job.startedAt = startedAt
            }
            job.endedAt = endedAt
        }
    }

    package func requestCancellation(
        jobID: String,
        sessionID: String,
        cancellation: ReviewCancellation
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
            let endedAt = coreDependencies.dateNow()
            updateJob(id: jobID) { job in
                job.cancellationRequested = false
                job.cancellation = cancellation
                job.status = .cancelled
                job.summary = cancellation.message
                job.hasFinalReview = false
                if cancellation.message.isEmpty == false {
                    job.errorMessage = cancellation.message
                }
                job.endedAt = endedAt
            }
            return ReviewCancelResult(jobID: jobID, state: .cancelled, signalled: false)
        case .running:
            let pendingMessage = "Cancellation requested."
            updateJob(id: jobID) { job in
                job.cancellationRequested = true
                job.cancellation = cancellation
                job.summary = pendingMessage
                job.hasFinalReview = false
                job.errorMessage = pendingMessage
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
            guard coordinator.isSessionClosed(sessionID) else {
                return nil
            }
            return .cancelled(.sessionClosed(message: defaultReason))
        }()

        guard let location = jobLocation(id: jobID) else {
            return closedSessionReason
        }
        let job = workspaces[location.workspaceIndex].jobs[location.jobIndex]
        guard job.sessionID == sessionID else {
            return .cancelled(.system(message: defaultReason))
        }
        if job.status == .cancelled || job.cancellationRequested {
            return .cancelled(job.cancellation ?? .system(message: job.errorMessage?.nilIfEmpty ?? defaultReason))
        }
        return closedSessionReason
    }

    package func closeSessionState(_ sessionID: String) -> [String] {
        coordinator.closeSessionState(sessionID)
    }

    package func pruneClosedJobIfNeeded(jobID: String) {
        guard let location = jobLocation(id: jobID)
        else {
            return
        }
        let job = workspaces[location.workspaceIndex].jobs[location.jobIndex]
        guard coordinator.isSessionClosed(job.sessionID),
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
        guard coordinator.isSessionClosed(sessionID) else {
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

    package static func errorMessage(from error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription, localized.isEmpty == false {
            return localized
        }
        return error.localizedDescription
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
        noteJobMutation()
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
        noteJobMutation()
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
        noteJobMutation()
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
            cancellable: job.isTerminal == false && job.cancellationRequested == false,
            cancellation: job.cancellation
        )
    }

    private func elapsedSeconds(for job: CodexReviewJob) -> Int? {
        guard let startedAt = job.startedAt else {
            return nil
        }
        let endedAt = job.endedAt ?? (job.isTerminal ? coreDependencies.dateNow() : nil) ?? coreDependencies.dateNow()
        return Int(endedAt.timeIntervalSince(startedAt))
    }

}

private struct ReviewQueuedJob {
    var jobID: String
    var sessionID: String
    var request: ReviewRequestOptions
    var initialModel: String?
}
