import Foundation
import MCP

package struct ReviewRegistryConfiguration: Sendable {
    package var codexCommand: String
    package var environment: [String: String]

    package init(
        codexCommand: String = "codex",
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.codexCommand = codexCommand
        self.environment = environment
    }
}

private struct ParentThreadKey: Hashable {
    var cwd: String
    var model: String?
}

private struct ParentThreadRecord {
    var threadID: String
}

private struct ParentThreadOperation {
    var id: UUID
    var reusesCachedThread: Bool
    var task: Task<ParentThreadRecord, Error>
}

private struct ReviewRecord {
    var sessionID: String
    var parentThreadID: String
    var reviewThreadID: String
    var turnID: String
    var cwd: String
    var model: String?
    var status: ReviewJobState
    var review: String
    var error: String?
    var needsRefresh: Bool

    var isActive: Bool {
        status.isTerminal == false
    }

    func handle() -> ReviewHandle {
        ReviewHandle(
            parentThreadID: parentThreadID,
            reviewThreadID: reviewThreadID,
            turnID: turnID,
            status: status
        )
    }

    func readResult() -> ReviewReadResult {
        ReviewReadResult(
            parentThreadID: parentThreadID,
            reviewThreadID: reviewThreadID,
            turnID: turnID,
            status: status,
            review: review,
            error: error
        )
    }
}

private struct AppServerThreadResponse: Decodable {
    var thread: AppServerThread
}

private struct AppServerThreadReadParams: Codable {
    var threadId: String
    var includeTurns: Bool
}

private struct AppServerThreadStartParams: Codable {
    var cwd: String
    var model: String?
    var approvalPolicy: String = "never"
}

private struct AppServerThreadResumeParams: Codable {
    var threadId: String
}

private struct AppServerThreadUnsubscribeParams: Codable {
    var threadId: String
}

private struct AppServerReviewStartParams: Codable {
    var threadId: String
    var target: ReviewTargetEnvelope
    var delivery: String = "detached"
}

private struct ReviewTargetEnvelope: Codable {
    var type: String
    var branch: String?
    var sha: String?
    var title: String?
    var instructions: String?
}

private struct AppServerReviewStartResponse: Decodable {
    var turn: AppServerTurn
    var reviewThreadId: String
}

private struct AppServerTurnInterruptParams: Codable {
    var threadId: String
    var turnId: String
}

private struct AppServerThread: Decodable {
    var id: String
    var turns: [AppServerTurn]
}

private struct AppServerTurn: Decodable {
    var id: String
    var items: [Value]
    var status: AppServerTurnStatus
    var error: AppServerTurnError?
}

private struct AppServerTurnError: Decodable {
    var message: String
}

private enum AppServerTurnStatus: String, Decodable {
    case completed = "completed"
    case interrupted = "interrupted"
    case failed = "failed"
    case inProgress = "inProgress"
}

private struct AppServerTurnStartedNotification: Decodable {
    var threadId: String
    var turn: AppServerTurn
}

private struct AppServerTurnCompletedNotification: Decodable {
    var threadId: String
    var turn: AppServerTurn
}

private struct AppServerItemCompletedNotification: Decodable {
    var item: Value
    var threadId: String
    var turnId: String
}

package actor ReviewRegistry {
    private let client: CodexAppServerClient
    private var eventTask: Task<Void, Never>?
    private var parentThreadsBySession: [String: [ParentThreadKey: ParentThreadRecord]] = [:]
    private var parentThreadOperationsBySession: [String: [ParentThreadKey: ParentThreadOperation]] = [:]
    private var reviews: [String: ReviewRecord] = [:]
    private var closedSessions: Set<String> = []

    package init(
        configuration: ReviewRegistryConfiguration = .init(),
        transportFactory: CodexAppServerTransportFactory? = nil
    ) {
        self.client = CodexAppServerClient(
            configuration: .init(
                codexCommand: configuration.codexCommand,
                environment: configuration.environment
            ),
            transportFactory: transportFactory
        )
    }

    package func start() {
        guard eventTask == nil else {
            return
        }
        let events = client.events
        eventTask = Task {
            for await event in events {
                await self.handleClientEvent(event)
            }
        }
    }

    package func startReview(
        sessionID: String,
        request: ReviewStartRequest
    ) async throws -> ReviewHandle {
        guard closedSessions.contains(sessionID) == false else {
            throw ReviewError.accessDenied("Session \(sessionID) is already closed.")
        }
        let request = try request.validated()
        let parentThread = try await ensureParentThread(sessionID: sessionID, request: request)
        guard closedSessions.contains(sessionID) == false else {
            throw ReviewError.accessDenied("Session \(sessionID) is already closed.")
        }
        let response = try await client.call(
            method: "review/start",
            params: AppServerReviewStartParams(
                threadId: parentThread.threadID,
                target: makeTargetEnvelope(request.target)
            ),
            as: AppServerReviewStartResponse.self
        )
        if closedSessions.contains(sessionID) {
            _ = try? await client.call(
                method: "turn/interrupt",
                params: try Value(
                    AppServerTurnInterruptParams(
                        threadId: response.reviewThreadId,
                        turnId: response.turn.id
                    )
                )
            )
            throw ReviewError.accessDenied("Session \(sessionID) is already closed.")
        }

        let record = ReviewRecord(
            sessionID: sessionID,
            parentThreadID: parentThread.threadID,
            reviewThreadID: response.reviewThreadId,
            turnID: response.turn.id,
            cwd: request.cwd,
            model: request.model,
            status: mapTurnStatus(response.turn.status),
            review: extractReviewText(from: response.turn.items) ?? "",
            error: response.turn.error?.message,
            needsRefresh: false
        )
        reviews[record.reviewThreadID] = record
        return record.handle()
    }

    package func readReview(
        reviewThreadID: String,
        sessionID: String
    ) async throws -> ReviewReadResult {
        try ensureAccess(reviewThreadID: reviewThreadID, sessionID: sessionID)
        try await refreshReviewIfNeeded(reviewThreadID: reviewThreadID)
        guard let record = reviews[reviewThreadID] else {
            throw ReviewError.jobNotFound("Review \(reviewThreadID) was not found.")
        }
        return record.readResult()
    }

    package func cancelReview(
        reviewThreadID: String,
        sessionID: String
    ) async throws -> ReviewCancelOutcome {
        try ensureAccess(reviewThreadID: reviewThreadID, sessionID: sessionID)
        guard let record = reviews[reviewThreadID] else {
            throw ReviewError.jobNotFound("Review \(reviewThreadID) was not found.")
        }
        guard record.isActive else {
            return ReviewCancelOutcome(
                reviewThreadID: reviewThreadID,
                turnID: record.turnID,
                cancelled: false
            )
        }
        do {
            _ = try await client.call(
                method: "turn/interrupt",
                params: try Value(
                    AppServerTurnInterruptParams(
                        threadId: reviewThreadID,
                        turnId: record.turnID
                    )
                )
            )
            var updatedRecord = record
            updatedRecord.status = .cancelled
            updatedRecord.error = "Cancellation requested."
            updatedRecord.needsRefresh = false
            reviews[reviewThreadID] = updatedRecord
            return ReviewCancelOutcome(
                reviewThreadID: reviewThreadID,
                turnID: record.turnID,
                cancelled: true
            )
        } catch {
            throw ReviewError.io("Failed to interrupt review turn \(record.turnID): \(error.localizedDescription)")
        }
    }

    package func closeSession(_ sessionID: String, reason: String) async {
        closedSessions.insert(sessionID)
        let reviewIDs = reviews.compactMap { reviewThreadID, record in
            record.sessionID == sessionID ? reviewThreadID : nil
        }
        for reviewThreadID in reviewIDs {
            if let record = reviews[reviewThreadID], record.isActive {
                _ = try? await client.call(
                    method: "turn/interrupt",
                    params: try Value(
                        AppServerTurnInterruptParams(
                            threadId: reviewThreadID,
                            turnId: record.turnID
                        )
                    )
                )
            }
        }
        if let parentThreads = parentThreadsBySession[sessionID] {
            for parentThread in parentThreads.values {
                _ = try? await client.call(
                    method: "thread/unsubscribe",
                    params: try Value(AppServerThreadUnsubscribeParams(threadId: parentThread.threadID))
                )
            }
        }
        reviews = reviews.filter { _, record in
            record.sessionID != sessionID
        }
        parentThreadsBySession.removeValue(forKey: sessionID)
        parentThreadOperationsBySession.removeValue(forKey: sessionID)
        _ = reason
    }

    package func hasActiveReviews(for sessionID: String) -> Bool {
        reviews.values.contains { record in
            record.sessionID == sessionID && record.isActive
        }
    }

    package func shutdown() async {
        eventTask?.cancel()
        eventTask = nil
        await client.shutdown()
    }

    private func ensureParentThread(
        sessionID: String,
        request: ReviewStartRequest
    ) async throws -> ParentThreadRecord {
        let key = ParentThreadKey(cwd: request.cwd, model: request.model)
        let operation: ParentThreadOperation
        if let existingOperation = parentThreadOperationsBySession[sessionID]?[key] {
            operation = existingOperation
        } else {
            let cachedParentThread = parentThreadsBySession[sessionID]?[key]
            let operationID = UUID()
            let client = self.client
            let newOperation = ParentThreadOperation(
                id: operationID,
                reusesCachedThread: cachedParentThread != nil,
                task: Task {
                    if let cachedParentThread {
                        _ = try await client.call(
                            method: "thread/resume",
                            params: AppServerThreadResumeParams(threadId: cachedParentThread.threadID),
                            as: AppServerThreadResponse.self
                        )
                        return cachedParentThread
                    }

                    let response = try await client.call(
                        method: "thread/start",
                        params: AppServerThreadStartParams(
                            cwd: request.cwd,
                            model: request.model
                        ),
                        as: AppServerThreadResponse.self
                    )
                    return ParentThreadRecord(threadID: response.thread.id)
                }
            )
            parentThreadOperationsBySession[sessionID, default: [:]][key] = newOperation
            operation = newOperation
        }

        do {
            return try await awaitParentThreadOperation(
                operation,
                sessionID: sessionID,
                key: key
            )
        } catch {
            if operation.reusesCachedThread, closedSessions.contains(sessionID) == false {
                return try await ensureParentThread(sessionID: sessionID, request: request)
            }
            throw error
        }
    }

    private func awaitParentThreadOperation(
        _ operation: ParentThreadOperation,
        sessionID: String,
        key: ParentThreadKey
    ) async throws -> ParentThreadRecord {
        defer {
            if parentThreadOperationsBySession[sessionID]?[key]?.id == operation.id {
                parentThreadOperationsBySession[sessionID]?[key] = nil
                if parentThreadOperationsBySession[sessionID]?.isEmpty == true {
                    parentThreadOperationsBySession.removeValue(forKey: sessionID)
                }
            }
        }

        do {
            let record = try await operation.task.value
            if closedSessions.contains(sessionID) {
                _ = try? await client.call(
                    method: "thread/unsubscribe",
                    params: try Value(AppServerThreadUnsubscribeParams(threadId: record.threadID))
                )
                throw ReviewError.accessDenied("Session \(sessionID) is already closed.")
            }
            parentThreadsBySession[sessionID, default: [:]][key] = record
            return record
        } catch {
            if operation.reusesCachedThread {
                parentThreadsBySession[sessionID]?[key] = nil
            }
            throw error
        }
    }

    private func refreshReviewIfNeeded(reviewThreadID: String) async throws {
        guard let record = reviews[reviewThreadID] else {
            return
        }
        guard record.status != .cancelled else {
            return
        }
        guard record.status.isTerminal || record.needsRefresh else {
            return
        }
        do {
            let response = try await client.call(
                method: "thread/read",
                params: AppServerThreadReadParams(
                    threadId: reviewThreadID,
                    includeTurns: true
                ),
                as: AppServerThreadResponse.self
            )
            guard var current = reviews[reviewThreadID] else {
                return
            }
            let turn = response.thread.turns.first { $0.id == current.turnID } ?? response.thread.turns.last
            if let turn {
                current.turnID = turn.id
                current.status = mapTurnStatus(turn.status)
                current.error = turn.error?.message
                current.needsRefresh = false
                if let review = extractReviewText(from: turn.items) {
                    current.review = review
                }
                reviews[reviewThreadID] = current
            }
        } catch {
            // Keep the locally cached terminal state when replay fails.
        }
    }

    private func ensureAccess(reviewThreadID: String, sessionID: String) throws {
        guard let record = reviews[reviewThreadID] else {
            throw ReviewError.jobNotFound("Review \(reviewThreadID) was not found.")
        }
        guard record.sessionID == sessionID else {
            throw ReviewError.accessDenied("Review \(reviewThreadID) is owned by another session.")
        }
    }

    private func handleClientEvent(_ event: CodexAppServerEvent) async {
        switch event {
        case .notification(let notification):
            await handleNotification(notification)
        case .disconnected:
            let reviewThreadIDs = Array(reviews.keys)
            for reviewThreadID in reviewThreadIDs {
                guard var record = reviews[reviewThreadID], record.isActive else {
                    continue
                }
                record.error = "codex app-server disconnected."
                record.needsRefresh = true
                reviews[reviewThreadID] = record
            }
        }
    }

    private func handleNotification(_ notification: CodexAppServerNotification) async {
        switch notification.method {
        case "turn/started":
            guard let params = notification.params else { return }
            if let payload = try? decodeValue(params, as: AppServerTurnStartedNotification.self) {
                applyTurnState(threadID: payload.threadId, turn: payload.turn)
            }
        case "turn/completed":
            guard let params = notification.params else { return }
            if let payload = try? decodeValue(params, as: AppServerTurnCompletedNotification.self) {
                applyTurnState(threadID: payload.threadId, turn: payload.turn)
            }
        case "item/completed":
            guard let params = notification.params else { return }
            if let payload = try? decodeValue(params, as: AppServerItemCompletedNotification.self),
               var record = reviews[payload.threadId]
            {
                if payload.turnId == record.turnID,
                   let review = extractReviewText(from: [payload.item])
                {
                    record.review = review
                    reviews[payload.threadId] = record
                }
            }
        default:
            break
        }
    }

    private func applyTurnState(threadID: String, turn: AppServerTurn) {
        guard var record = reviews[threadID] else {
            return
        }
        guard record.status != .cancelled else {
            return
        }
        record.turnID = turn.id
        record.status = mapTurnStatus(turn.status)
        record.error = turn.error?.message
        record.needsRefresh = false
        if let review = extractReviewText(from: turn.items) {
            record.review = review
        }
        reviews[threadID] = record
    }
}

private func makeTargetEnvelope(_ target: ReviewTarget) -> ReviewTargetEnvelope {
    switch target {
    case .uncommittedChanges:
        .init(type: "uncommittedChanges", branch: nil, sha: nil, title: nil, instructions: nil)
    case .baseBranch(let branch):
        .init(type: "baseBranch", branch: branch, sha: nil, title: nil, instructions: nil)
    case .commit(let sha, let title):
        .init(type: "commit", branch: nil, sha: sha, title: title, instructions: nil)
    case .custom(let instructions):
        .init(type: "custom", branch: nil, sha: nil, title: nil, instructions: instructions)
    }
}

private func mapTurnStatus(_ status: AppServerTurnStatus) -> ReviewJobState {
    switch status {
    case .completed:
        .succeeded
    case .interrupted:
        .cancelled
    case .failed:
        .failed
    case .inProgress:
        .running
    }
}

private func extractReviewText(from items: [Value]) -> String? {
    for item in items {
        guard let object = item.objectValue else {
            continue
        }
        guard object["type"]?.stringValue == "exitedReviewMode" else {
            continue
        }
        if let review = object["review"]?.stringValue {
            return review
        }
    }
    return nil
}

private func decodeValue<T: Decodable>(_ value: Value, as type: T.Type) throws -> T {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(type, from: data)
}
