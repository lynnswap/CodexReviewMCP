import Foundation
import ReviewPorts
import ReviewDomain

extension CodexReviewStore: ReviewStoreProtocol {
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
        jobID: String
    ) throws -> ReviewReadResult {
        let job = try job(jobID: jobID)
        return ReviewReadResult(
            jobID: job.id,
            core: job.core,
            elapsedSeconds: elapsedSeconds(for: job),
            cancellable: job.isTerminal == false && job.cancellationRequested == false,
            logs: job.logEntries,
            rawLogText: job.rawLogText
        )
    }

    package func readReview(
        jobID: String,
        sessionID _: String
    ) throws -> ReviewReadResult {
        try readReview(jobID: jobID)
    }

    package func listReviews(
        cwd: String? = nil,
        statuses: [ReviewJobState]? = nil,
        limit: Int? = nil
    ) -> ReviewListResult {
        let filtered = filteredJobs(cwd: cwd, statuses: statuses)
        let clampedLimit = min(max(limit ?? 20, 1), 100)
        return ReviewListResult(items: Array(filtered.prefix(clampedLimit)).map(makeListItem))
    }

    package func listReviews(
        sessionID _: String,
        cwd: String? = nil,
        statuses: [ReviewJobState]? = nil,
        limit: Int? = nil
    ) -> ReviewListResult {
        listReviews(cwd: cwd, statuses: statuses, limit: limit)
    }

    package func cancelReview(
        selectedJobID jobID: String,
        cancellation: ReviewCancellation = .system()
    ) async throws -> ReviewCancelOutcome {
        try await coordinator.cancelReviewByID(
            jobID: jobID,
            cancellation: cancellation,
            store: self
        )
    }

    package func cancelReview(
        selectedJobID jobID: String,
        sessionID _: String,
        cancellation: ReviewCancellation = .system()
    ) async throws -> ReviewCancelOutcome {
        try await cancelReview(selectedJobID: jobID, cancellation: cancellation)
    }

    package func cancelReview(
        selector: ReviewJobSelector,
        cancellation: ReviewCancellation = .system()
    ) async throws -> ReviewCancelOutcome {
        try await coordinator.cancelReviewBySelector(
            selector: selector,
            cancellation: cancellation,
            store: self
        )
    }

    package func cancelReview(
        selector: ReviewJobSelector,
        sessionID _: String,
        cancellation: ReviewCancellation = .system()
    ) async throws -> ReviewCancelOutcome {
        try await cancelReview(selector: selector, cancellation: cancellation)
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
            job.core.lifecycle.startedAt = startedAt
            job.cancellationRequested = false
            if job.core.lifecycle.status == .queued {
                job.core.lifecycle.status = .running
                job.core.output.summary = "Running."
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
                job.core.output.summary = message
                job.appendLogEntry(.init(kind: .progress, text: message))
            }
        case .reviewStarted(let reviewThreadID, let threadID, let turnID, let model):
            updateJob(id: jobID) { job in
                job.core.run.reviewThreadID = reviewThreadID
                job.core.run.threadID = threadID
                job.core.run.turnID = turnID
                job.core.run.model = model
                job.core.output.summary = "Review started: \(reviewThreadID)"
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
                job.core.output.lastAgentMessage = message
            }
        case .failed(let message):
            updateJob(id: jobID) { job in
                job.core.lifecycle.errorMessage = message.nilIfEmpty
            }
        }
    }

    package func completeReview(jobID: String, outcome: ReviewProcessOutcome) {
        updateJob(id: jobID) { job in
            var core = outcome.core
            job.cancellationRequested = false
            core.output.summary = if core.lifecycle.status == .cancelled {
                job.core.lifecycle.cancellation?.message
                    ?? core.lifecycle.errorMessage?.nilIfEmpty
                    ?? core.output.summary
            } else {
                core.output.summary
            }
            core.run.model = core.run.model ?? job.core.run.model
            if core.output.hasFinalReview {
                core.output.lastAgentMessage = outcome.content.nilIfEmpty
                    ?? core.output.lastAgentMessage?.nilIfEmpty
                    ?? job.core.output.lastAgentMessage
            } else if core.lifecycle.status == .cancelled {
                let preservedContent = outcome.content.nilIfEmpty
                let preservedMessage = core.output.lastAgentMessage?.nilIfEmpty
                let cancellationMessage = core.lifecycle.errorMessage?.nilIfEmpty
                if let preservedContent,
                   preservedContent != cancellationMessage
                {
                    core.output.lastAgentMessage = preservedContent
                } else if let preservedMessage,
                          preservedMessage != cancellationMessage
                {
                    core.output.lastAgentMessage = preservedMessage
                }
            } else {
                core.output.lastAgentMessage = core.output.lastAgentMessage?.nilIfEmpty
                    ?? job.core.output.lastAgentMessage
            }
            core.lifecycle.errorMessage = reviewAuthDisplayMessage(from: core.lifecycle.errorMessage)
            core.output.reviewResult = core.output.reviewResult
                ?? (core.output.hasFinalReview ? nil : ParsedReviewResult.notAvailable())
            if core.lifecycle.status == .cancelled {
                core.lifecycle.cancellation = job.core.lifecycle.cancellation ?? core.lifecycle.cancellation
            } else {
                core.lifecycle.cancellation = nil
            }
            core.run.reviewThreadID = core.run.reviewThreadID ?? job.core.run.reviewThreadID
            core.run.threadID = core.run.threadID ?? job.core.run.threadID
            core.run.turnID = core.run.turnID ?? job.core.run.turnID
            job.core = core
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
            job.core.lifecycle.cancellation = nil
            job.core.lifecycle.status = .failed
            job.core.output.summary = "Failed to start review."
            job.core.run.model = model ?? job.core.run.model
            job.core.lifecycle.errorMessage = reviewAuthDisplayMessage(from: message)
            job.core.output.reviewResult = ParsedReviewResult.notAvailable()
            job.core.lifecycle.startedAt = startedAt
            job.core.lifecycle.endedAt = endedAt
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
            job.core.lifecycle.cancellation = cancellation
            job.core.lifecycle.status = .cancelled
            job.core.output.summary = cancellation.message
            job.core.run.model = model ?? job.core.run.model
            job.core.output.hasFinalReview = false
            job.core.output.reviewResult = ParsedReviewResult.notAvailable()
            job.core.lifecycle.errorMessage = cancellation.message.nilIfEmpty
                ?? job.core.lifecycle.errorMessage
            if job.core.lifecycle.startedAt == nil {
                job.core.lifecycle.startedAt = startedAt
            }
            job.core.lifecycle.endedAt = endedAt
        }
    }

    package func requestCancellation(
        jobID: String,
        sessionID _: String,
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
        if job.isTerminal {
            return ReviewCancelResult(jobID: jobID, state: job.core.lifecycle.status, signalled: false)
        }

        if job.cancellationRequested {
            return ReviewCancelResult(jobID: jobID, state: job.core.lifecycle.status, signalled: true)
        }

        switch job.core.lifecycle.status {
        case .queued:
            let endedAt = coreDependencies.dateNow()
            updateJob(id: jobID) { job in
                job.cancellationRequested = false
                job.core.lifecycle.cancellation = cancellation
                job.core.lifecycle.status = .cancelled
                job.core.output.summary = cancellation.message
                job.core.output.hasFinalReview = false
                if cancellation.message.isEmpty == false {
                    job.core.lifecycle.errorMessage = cancellation.message
                }
                job.core.lifecycle.endedAt = endedAt
            }
            return ReviewCancelResult(jobID: jobID, state: .cancelled, signalled: false)
        case .running:
            let pendingMessage = "Cancellation requested."
            updateJob(id: jobID) { job in
                job.cancellationRequested = true
                job.core.lifecycle.cancellation = cancellation
                job.core.output.summary = pendingMessage
                job.core.output.hasFinalReview = false
                job.core.lifecycle.errorMessage = pendingMessage
            }
            return ReviewCancelResult(jobID: jobID, state: .running, signalled: true)
        case .succeeded, .failed, .cancelled:
            return ReviewCancelResult(jobID: jobID, state: job.core.lifecycle.status, signalled: false)
        }
    }

    package func discardQueuedOrRunningJob(jobID: String) {
        removeJob(id: jobID)
    }

    package func resolveJob(
        jobID: String,
        sessionID _: String
    ) throws -> CodexReviewJob {
        try job(jobID: jobID)
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
        if job.core.lifecycle.status == .cancelled || job.cancellationRequested {
            return .cancelled(
                job.core.lifecycle.cancellation
                    ?? .system(message: job.core.lifecycle.errorMessage?.nilIfEmpty ?? defaultReason)
            )
        }
        return closedSessionReason
    }

    package func closeSessionState(_ sessionID: String) -> [String] {
        coordinator.closeSessionState(sessionID)
    }

    package func resolveJob(
        sessionID _: String,
        selector: ReviewJobSelector
    ) throws -> CodexReviewJob {
        try resolveJob(selector: selector)
    }

    package func resolveJob(
        selector: ReviewJobSelector
    ) throws -> CodexReviewJob {
        if let jobID = selector.jobID?.nilIfEmpty {
            return try job(jobID: jobID)
        }

        let effectiveStatuses = selector.statuses ?? [.queued, .running]
        let candidates = filteredJobs(
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
            targetSummary: queued.request.targetSummary,
            core: ReviewJobCore(
                run: .init(model: queued.initialModel),
                lifecycle: .init(status: .queued),
                output: .init(summary: "Queued.")
            ),
            cancellationRequested: false,
            logEntries: []
        )

        if let workspace = workspaces.first(where: { $0.cwd == queued.request.cwd }) {
            workspace.insertJobAtFront(job)
        } else {
            let workspace = CodexReviewWorkspace(
                cwd: queued.request.cwd,
                jobs: [job]
            )
            workspace.sortOrder = (orderedWorkspaces.first?.sortOrder ?? 0) - 1
            workspaces.append(workspace)
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
        cwd: String?,
        statuses: [ReviewJobState]?
    ) -> [CodexReviewJob] {
        let normalizedCWD = cwd?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let allowedStatuses = statuses.map(Set.init)
        var matches: [CodexReviewJob] = []
        for workspace in orderedWorkspaces {
            for job in workspace.orderedJobs {
                if let normalizedCWD, job.cwd != normalizedCWD {
                    continue
                }
                if let allowedStatuses, allowedStatuses.contains(job.core.lifecycle.status) == false {
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

    private func job(jobID: String) throws -> CodexReviewJob {
        guard let location = jobLocation(id: jobID) else {
            throw ReviewError.jobNotFound("Job \(jobID) was not found.")
        }
        return workspaces[location.workspaceIndex].jobs[location.jobIndex]
    }

    private func makeListItem(_ job: CodexReviewJob) -> ReviewJobListItem {
        ReviewJobListItem(
            jobID: job.id,
            cwd: job.cwd,
            targetSummary: job.targetSummary,
            core: job.core,
            elapsedSeconds: elapsedSeconds(for: job),
            cancellable: job.isTerminal == false && job.cancellationRequested == false
        )
    }

    private func elapsedSeconds(for job: CodexReviewJob) -> Int? {
        guard let startedAt = job.core.lifecycle.startedAt else {
            return nil
        }
        let endedAt = job.core.lifecycle.endedAt
            ?? (job.isTerminal ? coreDependencies.dateNow() : nil)
            ?? coreDependencies.dateNow()
        return Int(endedAt.timeIntervalSince(startedAt))
    }

}

private struct ReviewQueuedJob {
    var jobID: String
    var sessionID: String
    var request: ReviewRequestOptions
    var initialModel: String?
}
