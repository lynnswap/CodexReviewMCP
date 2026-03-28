import Foundation
import Logging

package actor ReviewJobStore {
    package struct Configuration: Sendable {
        package var defaultTimeoutSeconds: Int?
        package var codexCommand: String
        package var environment: [String: String]

        package init(
            defaultTimeoutSeconds: Int? = nil,
            codexCommand: String = "codex",
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) {
            self.defaultTimeoutSeconds = defaultTimeoutSeconds
            self.codexCommand = codexCommand
            self.environment = environment
        }
    }

    private struct JobRecord {
        var sessionID: String
        var request: ReviewRequestOptions
        var state: ReviewJobState
        var threadID: String?
        var lastAgentMessage: String
        var errorMessage: String?
        var startedAt: Date?
        var endedAt: Date?
        var exitCode: Int?
        var summary: String
        var artifacts: ReviewArtifacts
        var processController: ReviewProcessController?
        var requestedTerminationReason: ReviewTerminationReason?
    }

    private let configuration: Configuration
    private let runner: CodexReviewProcessRunner
    private let logger = Logger(label: "codex-review-mcp.jobs")
    private var jobs: [String: JobRecord] = [:]
    private var closedSessions: Set<String> = []

    package init(
        configuration: Configuration = .init()
    ) {
        self.configuration = configuration
        self.runner = CodexReviewProcessRunner(
            commandBuilder: ReviewCommandBuilder(
                codexCommand: configuration.codexCommand,
                environment: configuration.environment
            )
        )
    }

    package func enqueueReview(
        sessionID: String,
        request: ReviewRequestOptions
    ) throws -> String {
        let jobID = UUID().uuidString
        let request = try request.validated()
        jobs[jobID] = JobRecord(
            sessionID: sessionID,
            request: request,
            state: .queued,
            threadID: nil,
            lastAgentMessage: "",
            errorMessage: nil,
            startedAt: nil,
            endedAt: nil,
            exitCode: nil,
            summary: "Queued.",
            artifacts: .init(eventsPath: nil, logPath: nil, lastMessagePath: nil),
            processController: nil,
            requestedTerminationReason: nil
        )
        return jobID
    }

    package func runReview(
        jobID: String,
        progress: @escaping @Sendable (ReviewProgressStage, String?) async -> Void
    ) async -> ReviewExecutionResult {
        let now = Date()
        guard let queuedRecord = jobs[jobID] else {
            return ReviewExecutionResult(
                snapshot: ReviewJobSnapshot(
                    jobID: jobID,
                    sessionID: "",
                    state: .failed,
                    summary: "Job not found."
                ),
                content: "Job \(jobID) was not found.",
                isError: true
            )
        }

        await progress(.queued, "Review queued.")
        do {
            if let cancelledResult = cancelIfAlreadyRequested(jobID: jobID, now: now) {
                pruneClosedJobIfNeeded(jobID: jobID)
                return cancelledResult
            }

            let request = queuedRecord.request

            let outcome = try await runner.run(
                request: request,
                defaultTimeoutSeconds: configuration.defaultTimeoutSeconds,
                onStart: { artifacts, controller, startedAt in
                    await self.markStarted(jobID: jobID, artifacts: artifacts, controller: controller, startedAt: startedAt)
                },
                onSnapshot: { snapshot in
                    await self.applySnapshot(jobID: jobID, snapshot: snapshot)
                },
                requestedTerminationReason: {
                    await self.jobs[jobID]?.requestedTerminationReason
                },
                onProgress: progress
            )
            let snapshot = finish(jobID: jobID, outcome: outcome)
            let result = ReviewExecutionResult(
                snapshot: snapshot,
                content: outcome.content,
                isError: outcome.state != .succeeded
            )
            pruneClosedJobIfNeeded(jobID: jobID)
            return result
        } catch {
            let message = (error as? ReviewError)?.errorDescription ?? error.localizedDescription
            jobs[jobID] = JobRecord(
                sessionID: queuedRecord.sessionID,
                request: queuedRecord.request,
                state: .failed,
                threadID: nil,
                lastAgentMessage: "",
                errorMessage: message,
                startedAt: now,
                endedAt: Date(),
                exitCode: nil,
                summary: "Failed to start review.",
                artifacts: .init(eventsPath: nil, logPath: nil, lastMessagePath: nil),
                processController: nil,
                requestedTerminationReason: nil
            )
            let failedSnapshot = snapshot(jobID: jobID)!
            pruneClosedJobIfNeeded(jobID: jobID)
            return ReviewExecutionResult(
                snapshot: failedSnapshot,
                content: message,
                isError: true
            )
        }
    }

    package func status(jobID: String, sessionID: String, includeArtifacts: Bool) throws -> ReviewJobSnapshot {
        let snapshot = try authorizedSnapshot(jobID: jobID, sessionID: sessionID)
        if includeArtifacts {
            return snapshot
        }
        var copy = snapshot
        copy.artifacts = .init(eventsPath: nil, logPath: nil, lastMessagePath: nil)
        return copy
    }

    package func cancel(jobID: String, sessionID: String, reason: String?) async throws -> ReviewCancelResult {
        try ensureAccess(jobID: jobID, sessionID: sessionID)
        guard var record = jobs[jobID] else {
            throw ReviewError.jobNotFound("Job \(jobID) was not found.")
        }
        if record.state.isTerminal {
            return ReviewCancelResult(jobID: jobID, state: record.state, signalled: false)
        }
        let cancellationReason = reason?.nilIfEmpty ?? "Cancelled by MCP request."
        record.state = .cancelled
        record.summary = "Cancellation requested."
        record.requestedTerminationReason = .cancelled(cancellationReason)
        if record.startedAt == nil {
            record.endedAt = Date()
        }
        jobs[jobID] = record

        var signalled = false
        if let controller = record.processController {
            signalled = await controller.terminateGracefully(grace: .seconds(2))
        }
        return ReviewCancelResult(jobID: jobID, state: .cancelled, signalled: signalled)
    }

    package func logs(jobID: String, sessionID: String, source: ReviewLogSource, tailBytes: Int) throws -> ReviewLogResult {
        let snapshot = try authorizedSnapshot(jobID: jobID, sessionID: sessionID)
        let clampedTail = min(max(tailBytes, 1), 65_536)
        let path: String?
        switch source {
        case .log:
            path = snapshot.artifacts.logPath
        case .events:
            path = snapshot.artifacts.eventsPath
        }
        let text = path.map { readTail(path: $0, tailBytes: clampedTail) ?? "" } ?? ""
        return ReviewLogResult(jobID: jobID, source: source, text: text, tailBytes: clampedTail, path: path)
    }

    package func requestOptions(jobID: String, sessionID: String) throws -> ReviewRequestOptions {
        try ensureAccess(jobID: jobID, sessionID: sessionID)
        guard let record = jobs[jobID] else {
            throw ReviewError.jobNotFound("Job \(jobID) was not found.")
        }
        return record.request
    }

    package func hasActiveJobs(for sessionID: String) -> Bool {
        jobs.values.contains { record in
            record.sessionID == sessionID && !record.state.isTerminal
        }
    }

    package func closeSession(_ sessionID: String, reason: String) async {
        closedSessions.insert(sessionID)
        await cancelJobs(for: sessionID, reason: reason)
        pruneClosedSessionJobs(for: sessionID)
    }

    private func cancelJobs(for sessionID: String, reason: String) async {
        let targetIDs = jobs.compactMap { jobID, record in
            record.sessionID == sessionID && !record.state.isTerminal ? jobID : nil
        }
        for jobID in targetIDs {
            _ = try? await cancel(jobID: jobID, sessionID: sessionID, reason: reason)
        }
    }

    package func allSnapshots(for sessionID: String? = nil) -> [ReviewJobSnapshot] {
        jobs.compactMap { jobID, record in
            if let sessionID, sessionID != record.sessionID {
                return nil
            }
            return snapshot(jobID: jobID)
        }.sorted { $0.jobID < $1.jobID }
    }

    private func markStarted(
        jobID: String,
        artifacts: ReviewArtifacts,
        controller: ReviewProcessController,
        startedAt: Date
    ) {
        guard var record = jobs[jobID] else {
            return
        }
        record.processController = controller
        record.artifacts = artifacts
        record.startedAt = startedAt
        if case .cancelled = record.requestedTerminationReason {
            record.state = .cancelled
            record.summary = "Review cancelled."
            jobs[jobID] = record
            Task {
                _ = await controller.terminateGracefully(grace: .seconds(2))
            }
            return
        }
        if record.state == .queued {
            record.state = .running
            record.summary = "Running."
        }
        jobs[jobID] = record
    }

    private func applySnapshot(jobID: String, snapshot: ReviewEventSnapshot) {
        guard var record = jobs[jobID] else {
            return
        }
        if let threadID = snapshot.threadID {
            record.threadID = threadID
        }
        if snapshot.lastAgentMessage.isEmpty == false {
            record.lastAgentMessage = snapshot.lastAgentMessage
        }
        record.errorMessage = Self.normalizedErrorMessage(from: snapshot)
        jobs[jobID] = record
    }

    package static func normalizedErrorMessage(from snapshot: ReviewEventSnapshot) -> String? {
        snapshot.errorMessage.nilIfEmpty
    }

    @discardableResult
    private func finish(jobID: String, outcome: ReviewProcessOutcome) -> ReviewJobSnapshot {
        guard var record = jobs[jobID] else {
            let fallback = ReviewJobSnapshot(
                jobID: jobID,
                sessionID: "",
                state: outcome.state,
                threadID: outcome.threadID,
                lastAgentMessage: outcome.lastAgentMessage,
                errorMessage: outcome.errorMessage,
                startedAt: outcome.startedAt,
                endedAt: outcome.endedAt,
                exitCode: outcome.exitCode,
                summary: outcome.summary,
                artifacts: outcome.artifacts,
                elapsedSeconds: Int(outcome.endedAt.timeIntervalSince(outcome.startedAt))
            )
            return fallback
        }
        if case .cancelled(let reason) = record.requestedTerminationReason {
            record.state = .cancelled
            record.summary = "Review cancelled."
            record.errorMessage = reason
        } else {
            record.state = outcome.state
            record.summary = outcome.summary
            record.errorMessage = outcome.errorMessage
        }
        record.threadID = outcome.threadID ?? record.threadID
        record.lastAgentMessage = outcome.lastAgentMessage
        record.startedAt = outcome.startedAt
        record.endedAt = outcome.endedAt
        record.exitCode = outcome.exitCode
        record.artifacts = outcome.artifacts
        record.processController = nil
        jobs[jobID] = record
        return snapshot(jobID: jobID)!
    }

    private func authorizedSnapshot(jobID: String, sessionID: String) throws -> ReviewJobSnapshot {
        try ensureAccess(jobID: jobID, sessionID: sessionID)
        guard let snapshot = snapshot(jobID: jobID) else {
            throw ReviewError.jobNotFound("Job \(jobID) was not found.")
        }
        return snapshot
    }

    private func ensureAccess(jobID: String, sessionID: String) throws {
        guard let record = jobs[jobID] else {
            throw ReviewError.jobNotFound("Job \(jobID) was not found.")
        }
        guard record.sessionID == sessionID else {
            throw ReviewError.accessDenied("Job \(jobID) belongs to another MCP session.")
        }
    }

    private func snapshot(jobID: String) -> ReviewJobSnapshot? {
        guard let record = jobs[jobID] else {
            return nil
        }
        let endedAt = record.endedAt ?? (record.state.isTerminal ? Date() : nil)
        let elapsedSeconds: Int?
        if let startedAt = record.startedAt {
            elapsedSeconds = Int((endedAt ?? Date()).timeIntervalSince(startedAt))
        } else {
            elapsedSeconds = nil
        }
        return ReviewJobSnapshot(
            jobID: jobID,
            sessionID: record.sessionID,
            state: record.state,
            threadID: record.threadID,
            lastAgentMessage: record.lastAgentMessage,
            errorMessage: record.errorMessage,
            startedAt: record.startedAt,
            endedAt: record.endedAt,
            exitCode: record.exitCode,
            summary: record.summary,
            artifacts: record.artifacts,
            elapsedSeconds: elapsedSeconds
        )
    }

    private func cancelIfAlreadyRequested(jobID: String, now: Date) -> ReviewExecutionResult? {
        guard var record = jobs[jobID],
              case .cancelled(let reason) = record.requestedTerminationReason
        else {
            return nil
        }
        record.state = .cancelled
        record.summary = "Review cancelled."
        record.errorMessage = reason
        record.endedAt = now
        jobs[jobID] = record
        let snapshot = snapshot(jobID: jobID)!
        return ReviewExecutionResult(
            snapshot: snapshot,
            content: reason,
            isError: true
        )
    }

    private func pruneClosedSessionJobs(for sessionID: String) {
        jobs = jobs.filter { _, record in
            record.sessionID != sessionID || canPrune(record) == false
        }
        clearClosedSessionIfPruned(sessionID)
    }

    private func pruneClosedJobIfNeeded(jobID: String) {
        guard let record = jobs[jobID],
              closedSessions.contains(record.sessionID),
              canPrune(record)
        else {
            return
        }
        let sessionID = record.sessionID
        jobs.removeValue(forKey: jobID)
        clearClosedSessionIfPruned(sessionID)
    }

    private func canPrune(_ record: JobRecord) -> Bool {
        record.state.isTerminal && record.processController == nil && (record.startedAt != nil || record.endedAt != nil)
    }

    private func clearClosedSessionIfPruned(_ sessionID: String) {
        guard jobs.values.contains(where: { $0.sessionID == sessionID }) == false else {
            return
        }
        closedSessions.remove(sessionID)
    }
}

package func readTail(path: String, tailBytes: Int) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
        return nil
    }
    defer {
        try? handle.close()
    }
    let endOffset = (try? handle.seekToEnd()) ?? 0
    let startOffset = endOffset > UInt64(tailBytes) ? endOffset - UInt64(tailBytes) : 0
    try? handle.seek(toOffset: startOffset)
    guard let data = try? handle.readToEnd() else {
        return nil
    }
    return String(decoding: data, as: UTF8.self)
}
