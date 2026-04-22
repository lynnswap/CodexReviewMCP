import Foundation
package import ReviewInfra
import ReviewDomain

package enum MockAppServerMode: Sendable {
    case success(
        reviewThreadID: String = "thr-review",
        threadID: String = "thr-review",
        turnID: String = "turn-review",
        model: String = "gpt-5.4-mini",
        finalReview: String = "Looks solid overall."
    )
    case longRunning(
        reviewThreadID: String = "thr-review",
        threadID: String = "thr-review",
        turnID: String = "turn-review",
        model: String = "gpt-5.4-mini"
    )
    case longRunningWithoutTurnStarted(
        reviewThreadID: String = "thr-review",
        threadID: String = "thr-review",
        turnID: String = "turn-review",
        model: String = "gpt-5.4-mini"
    )
    case detachedLongRunning(
        reviewThreadID: String = "thr-review",
        parentThreadID: String = "thr-parent",
        turnID: String = "turn-review",
        model: String = "gpt-5.4-mini"
    )
    case reviewStartFailure(message: String = "review start failed")
    case configReadFailure(message: String = "config read failed")
    case configReadUnsupported
    case bootstrapFailure(message: String = "bootstrap failed before thread/start")
    case interruptFailure(message: String = "interrupt failed")
    case interruptIgnoredLongRunning(
        reviewThreadID: String = "thr-review",
        threadID: String = "thr-review",
        turnID: String = "turn-review",
        model: String = "gpt-5.4-mini"
    )
    case turnFailure(message: String = "turn failed")
    case threadClosedWithoutTurnCompletion(
        reviewThreadID: String = "thr-review",
        threadID: String = "thr-review",
        turnID: String = "turn-review",
        model: String = "gpt-5.4-mini"
    )
    case threadClosedBeforeCompletedNotifications(
        reviewThreadID: String = "thr-review",
        threadID: String = "thr-review",
        turnID: String = "turn-review",
        model: String = "gpt-5.4-mini",
        finalReview: String = "Looks solid overall."
    )
    case threadClosedThenTransportDisconnect(
        reviewThreadID: String = "thr-review",
        threadID: String = "thr-review",
        turnID: String = "turn-review",
        model: String = "gpt-5.4-mini",
        message: String = "mock app-server transport disconnected"
    )
    case detachedParentThreadClosedBeforeCompletedNotifications(
        reviewThreadID: String = "thr-review",
        parentThreadID: String = "thr-parent",
        turnID: String = "turn-review",
        model: String = "gpt-5.4-mini",
        finalReview: String = "Looks solid overall."
    )
    case unrelatedNonRetryErrorThenSuccess(
        reviewThreadID: String = "thr-review",
        threadID: String = "thr-review",
        turnID: String = "turn-review",
        model: String = "gpt-5.4-mini",
        finalReview: String = "Looks solid overall."
    )
    case unrelatedTurnStartedBeforeReviewStartThenSuccess(
        reviewThreadID: String = "thr-review",
        threadID: String = "thr-review",
        turnID: String = "turn-review",
        model: String = "gpt-5.4-mini",
        finalReview: String = "Looks solid overall."
    )
    case nonRetryErrorWithoutTurnCompletion(
        reviewThreadID: String = "thr-review",
        threadID: String = "thr-review",
        turnID: String = "turn-review",
        model: String = "gpt-5.4-mini",
        message: String = "review failed hard"
    )
    case completedThenNonRetryError(
        reviewThreadID: String = "thr-review",
        threadID: String = "thr-review",
        turnID: String = "turn-review",
        model: String = "gpt-5.4-mini",
        finalReview: String = "Looks solid overall.",
        message: String = "review failed after completion"
    )
    case nonRetryErrorThenCompleted(
        reviewThreadID: String = "thr-review",
        threadID: String = "thr-review",
        turnID: String = "turn-review",
        model: String = "gpt-5.4-mini",
        finalReview: String = "Looks solid overall.",
        message: String = "review failed before completion"
    )
    case finalReviewWithoutTurnCompletionAfterThreadUnavailable(
        reviewThreadID: String = "thr-review",
        threadID: String = "thr-review",
        turnID: String = "turn-review",
        model: String = "gpt-5.4-mini",
        finalReview: String = "Looks solid overall."
    )
    case turnCompletedBeforeFinalReviewThenThreadUnavailable(
        reviewThreadID: String = "thr-review",
        threadID: String = "thr-review",
        turnID: String = "turn-review",
        model: String = "gpt-5.4-mini",
        finalReview: String = "Looks solid overall."
    )
    case threadUnavailableRescheduledByTrackedActivity(
        reviewThreadID: String = "thr-review",
        threadID: String = "thr-review",
        turnID: String = "turn-review",
        model: String = "gpt-5.4-mini",
        finalReview: String = "Looks solid overall.",
        activityDelta: String = "still running"
    )
    case completedWithoutFinalReviewThenThreadUnavailable(
        reviewThreadID: String = "thr-review",
        threadID: String = "thr-review",
        turnID: String = "turn-review",
        model: String = "gpt-5.4-mini"
    )
    case commandOutputThenTransportDisconnect(
        reviewThreadID: String = "thr-review",
        threadID: String = "thr-review",
        turnID: String = "turn-review",
        model: String = "gpt-5.4-mini",
        outputDelta: String = "stdout chunk",
        message: String = "mock app-server transport disconnected"
    )
    case commandOutputThenSuccessThenTransportDisconnect(
        reviewThreadID: String = "thr-review",
        threadID: String = "thr-review",
        turnID: String = "turn-review",
        model: String = "gpt-5.4-mini",
        finalReview: String = "Looks solid overall.",
        outputDelta: String = "stdout chunk",
        message: String = "mock app-server transport disconnected"
    )
    case turnCompletedThenTransportDisconnect(
        reviewThreadID: String = "thr-review",
        threadID: String = "thr-review",
        turnID: String = "turn-review",
        model: String = "gpt-5.4-mini",
        message: String = "mock app-server transport disconnected"
    )
    case batchedSuccess(
        reviewThreadID: String = "thr-review",
        threadID: String = "thr-review",
        turnID: String = "turn-review",
        model: String = "gpt-5.4-mini",
        finalReview: String = "Looks solid overall."
    )
}

package actor MockAppServerSessionTransport: AppServerSessionTransport {
    package struct RecordedRequest: Sendable {
        package var method: String
        package var payload: Data
    }

    private let mode: MockAppServerMode
    private let initialize: AppServerInitializeResponse
    private var notificationSubscribers: [UUID: AsyncThrowingStream<AppServerServerNotification, Error>.Continuation] = [:]
    private var delayedNotifications: [AppServerServerNotification] = []
    private var delayedNotificationFlushTask: Task<Void, Never>?
    private var delayedDisconnectTask: Task<Void, Never>?
    private var requests: [RecordedRequest] = []
    private var requestCounts: [String: Int] = [:]
    private var requestWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var disconnected: Error?
    private var closed = false
    private var currentThreadID: String?
    private var currentTurnID: String?
    private(set) package var backgroundCleanCount = 0
    private(set) package var unsubscribeCount = 0

    package init(
        mode: MockAppServerMode,
        initialize: AppServerInitializeResponse = .init(
            userAgent: nil,
            codexHome: nil,
            platformFamily: "macOS",
            platformOs: "Darwin"
        )
    ) {
        self.mode = mode
        self.initialize = initialize
    }

    package func initializeResponse() async -> AppServerInitializeResponse {
        initialize
    }

    package func request<Params: Encodable & Sendable, Response: Decodable & Sendable>(
        method: String,
        params: Params,
        responseType: Response.Type
    ) async throws -> Response {
        if let disconnected {
            throw disconnected
        }
        if closed {
            throw ReviewError.io("mock app-server session is closed.")
        }

        let payload = try JSONEncoder().encode(EncodableBox(value: params))
        requests.append(.init(method: method, payload: payload))
        noteRequest(method)

        switch method {
        case "initialize":
            return try decodeResponse(
                [
                    "platformFamily": initialize.platformFamily as Any,
                    "platformOs": initialize.platformOs as Any,
                    "codexHome": initialize.codexHome as Any,
                    "userAgent": initialize.userAgent as Any,
                ].compactMapValues { $0 },
                as: responseType
            )
        case "config/read":
            switch mode {
            case .configReadFailure(let message):
                throw AppServerResponseError(code: -32001, message: message)
            case .configReadUnsupported:
                throw AppServerResponseError(code: -32601, message: "Method not found")
            default:
                return try decodeResponse(
                    ["config": ["model": "gpt-5.4-mini"]],
                    as: responseType
                )
            }
        case "account/rateLimits/read":
            throw AppServerResponseError(code: -32601, message: "Method not found")
        case "thread/start":
            switch mode {
            case .bootstrapFailure(let message):
                disconnected = ReviewError.io(message)
                throw disconnected!
            case .detachedLongRunning(_, let parentThreadID, _, let model):
                currentThreadID = parentThreadID
                return try decodeResponse(
                    ["thread": ["id": parentThreadID], "model": model],
                    as: responseType
                )
            case .detachedParentThreadClosedBeforeCompletedNotifications(_, let parentThreadID, _, let model, _):
                currentThreadID = parentThreadID
                return try decodeResponse(
                    ["thread": ["id": parentThreadID], "model": model],
                    as: responseType
                )
            case .success(_, let threadID, _, let model, _):
                currentThreadID = threadID
                return try decodeResponse(
                    ["thread": ["id": threadID], "model": model],
                    as: responseType
                )
            case .longRunning(_, let threadID, _, let model):
                currentThreadID = threadID
                return try decodeResponse(
                    ["thread": ["id": threadID], "model": model],
                    as: responseType
                )
            case .reviewStartFailure:
                currentThreadID = "thr-review"
                return try decodeResponse(
                    ["thread": ["id": "thr-review"], "model": "gpt-5.4-mini"],
                    as: responseType
                )
            case .turnFailure:
                currentThreadID = "thr-review"
                return try decodeResponse(
                    ["thread": ["id": "thr-review"], "model": "gpt-5.4-mini"],
                    as: responseType
                )
            default:
                currentThreadID = "thr-review"
                return try decodeResponse(
                    ["thread": ["id": "thr-review"], "model": "gpt-5.4-mini"],
                    as: responseType
                )
            }
        case "review/start":
            switch mode {
            case .reviewStartFailure(let message):
                throw AppServerResponseError(code: -32002, message: message)
            case .success(let reviewThreadID, _, let turnID, _, let finalReview):
                currentTurnID = turnID
                enqueueReviewStarted(reviewThreadID: reviewThreadID, turnID: turnID)
                enqueueSuccessReview(reviewThreadID: reviewThreadID, turnID: turnID, finalReview: finalReview)
                return try decodeResponse(
                    [
                        "turn": ["id": turnID, "status": "inProgress", "error": NSNull()],
                        "reviewThreadId": reviewThreadID,
                    ],
                    as: responseType
                )
            case .longRunning(let reviewThreadID, _, let turnID, _):
                currentTurnID = turnID
                enqueueReviewStarted(reviewThreadID: reviewThreadID, turnID: turnID)
                return try decodeResponse(
                    [
                        "turn": ["id": turnID, "status": "inProgress", "error": NSNull()],
                        "reviewThreadId": reviewThreadID,
                    ],
                    as: responseType
                )
            case .longRunningWithoutTurnStarted(let reviewThreadID, _, let turnID, _):
                currentTurnID = turnID
                return try decodeResponse(
                    [
                        "turn": ["id": turnID, "status": "inProgress", "error": NSNull()],
                        "reviewThreadId": reviewThreadID,
                    ],
                    as: responseType
                )
            case .interruptIgnoredLongRunning(let reviewThreadID, _, let turnID, _):
                currentTurnID = turnID
                enqueueReviewStarted(reviewThreadID: reviewThreadID, turnID: turnID)
                return try decodeResponse(
                    [
                        "turn": ["id": turnID, "status": "inProgress", "error": NSNull()],
                        "reviewThreadId": reviewThreadID,
                    ],
                    as: responseType
                )
            case .interruptFailure:
                let reviewThreadID = "thr-review"
                let turnID = "turn-review"
                currentTurnID = turnID
                enqueueReviewStarted(reviewThreadID: reviewThreadID, turnID: turnID)
                return try decodeResponse(
                    [
                        "turn": ["id": turnID, "status": "inProgress", "error": NSNull()],
                        "reviewThreadId": reviewThreadID,
                    ],
                    as: responseType
                )
            case .detachedLongRunning(let reviewThreadID, _, let turnID, _):
                currentTurnID = turnID
                enqueueReviewStarted(reviewThreadID: reviewThreadID, turnID: turnID)
                return try decodeResponse(
                    [
                        "turn": ["id": turnID, "status": "inProgress", "error": NSNull()],
                        "reviewThreadId": reviewThreadID,
                    ],
                    as: responseType
                )
            case .detachedParentThreadClosedBeforeCompletedNotifications(
                let reviewThreadID,
                let parentThreadID,
                let turnID,
                _,
                let finalReview
            ):
                currentTurnID = turnID
                enqueueReviewStarted(reviewThreadID: reviewThreadID, turnID: turnID)
                enqueueNotification(
                    .threadStatusChanged(
                        .init(
                            threadID: parentThreadID,
                            status: .init(type: "notLoaded")
                        )
                    )
                )
                enqueueNotification(.threadClosed(.init(threadID: parentThreadID)))
                enqueueSuccessReview(reviewThreadID: reviewThreadID, turnID: turnID, finalReview: finalReview)
                return try decodeResponse(
                    [
                        "turn": ["id": turnID, "status": "inProgress", "error": NSNull()],
                        "reviewThreadId": reviewThreadID,
                    ],
                    as: responseType
                )
            case .unrelatedNonRetryErrorThenSuccess(let reviewThreadID, _, let turnID, _, let finalReview):
                currentTurnID = turnID
                enqueueReviewStarted(reviewThreadID: reviewThreadID, turnID: turnID)
                let unrelatedError: AppServerErrorNotification = try decodeResponse(
                    [
                        "error": [
                            "message": "unrelated failure",
                            "additionalDetails": NSNull(),
                        ],
                        "willRetry": false,
                        "threadId": "thr-unrelated",
                        "turnId": "turn-unrelated",
                    ],
                    as: AppServerErrorNotification.self
                )
                enqueueNotification(
                    AppServerServerNotification.error(unrelatedError)
                )
                enqueueSuccessReview(reviewThreadID: reviewThreadID, turnID: turnID, finalReview: finalReview)
                return try decodeResponse(
                    [
                        "turn": ["id": turnID, "status": "inProgress", "error": NSNull()],
                        "reviewThreadId": reviewThreadID,
                    ],
                    as: responseType
                )
            case .unrelatedTurnStartedBeforeReviewStartThenSuccess(
                let reviewThreadID,
                _,
                let turnID,
                _,
                let finalReview
            ):
                currentTurnID = turnID
                enqueueNotification(
                    .turnStarted(
                        .init(
                            threadID: "thr-unrelated",
                            turn: .init(id: "turn-unrelated", status: .inProgress, error: nil)
                        )
                    )
                )
                enqueueReviewStarted(reviewThreadID: reviewThreadID, turnID: turnID)
                enqueueSuccessReview(reviewThreadID: reviewThreadID, turnID: turnID, finalReview: finalReview)
                return try decodeResponse(
                    [
                        "turn": ["id": turnID, "status": "inProgress", "error": NSNull()],
                        "reviewThreadId": reviewThreadID,
                    ],
                    as: responseType
                )
            case .nonRetryErrorWithoutTurnCompletion(let reviewThreadID, _, let turnID, _, let message):
                currentTurnID = turnID
                enqueueReviewStarted(reviewThreadID: reviewThreadID, turnID: turnID)
                let threadID = currentThreadID ?? reviewThreadID
                let failure: AppServerErrorNotification = try decodeResponse(
                    [
                        "error": [
                            "message": message,
                            "additionalDetails": NSNull(),
                        ],
                        "willRetry": false,
                        "threadId": threadID,
                        "turnId": turnID,
                    ],
                    as: AppServerErrorNotification.self
                )
                enqueueNotification(.error(failure))
                return try decodeResponse(
                    [
                        "turn": ["id": turnID, "status": "inProgress", "error": NSNull()],
                        "reviewThreadId": reviewThreadID,
                    ],
                    as: responseType
                )
            case .completedThenNonRetryError(let reviewThreadID, _, let turnID, _, let finalReview, let message):
                currentTurnID = turnID
                enqueueReviewStarted(reviewThreadID: reviewThreadID, turnID: turnID)
                enqueueSuccessReview(reviewThreadID: reviewThreadID, turnID: turnID, finalReview: finalReview)
                let threadID = currentThreadID ?? reviewThreadID
                let failure: AppServerErrorNotification = try decodeResponse(
                    [
                        "error": [
                            "message": message,
                            "additionalDetails": NSNull(),
                        ],
                        "willRetry": false,
                        "threadId": threadID,
                        "turnId": turnID,
                    ],
                    as: AppServerErrorNotification.self
                )
                enqueueNotification(.error(failure))
                return try decodeResponse(
                    [
                        "turn": ["id": turnID, "status": "inProgress", "error": NSNull()],
                        "reviewThreadId": reviewThreadID,
                    ],
                    as: responseType
                )
            case .nonRetryErrorThenCompleted(let reviewThreadID, _, let turnID, _, let finalReview, let message):
                currentTurnID = turnID
                enqueueReviewStarted(reviewThreadID: reviewThreadID, turnID: turnID)
                let threadID = currentThreadID ?? reviewThreadID
                let failure: AppServerErrorNotification = try decodeResponse(
                    [
                        "error": [
                            "message": message,
                            "additionalDetails": NSNull(),
                        ],
                        "willRetry": false,
                        "threadId": threadID,
                        "turnId": turnID,
                    ],
                    as: AppServerErrorNotification.self
                )
                enqueueNotification(.error(failure))
                enqueueSuccessReview(reviewThreadID: reviewThreadID, turnID: turnID, finalReview: finalReview)
                return try decodeResponse(
                    [
                        "turn": ["id": turnID, "status": "inProgress", "error": NSNull()],
                        "reviewThreadId": reviewThreadID,
                    ],
                    as: responseType
                )
            case .finalReviewWithoutTurnCompletionAfterThreadUnavailable(let reviewThreadID, _, let turnID, _, let finalReview):
                currentTurnID = turnID
                enqueueReviewStarted(reviewThreadID: reviewThreadID, turnID: turnID)
                let threadID = currentThreadID ?? reviewThreadID
                enqueueNotification(
                    .threadStatusChanged(
                        .init(
                            threadID: threadID,
                            status: .init(type: "notLoaded")
                        )
                    )
                )
                enqueueNotification(.threadClosed(.init(threadID: threadID)))
                enqueueNotification(
                    .itemCompleted(
                        .init(
                            item: .exitedReviewMode(id: turnID, review: finalReview),
                            threadID: threadID,
                            turnID: turnID
                        )
                    )
                )
                return try decodeResponse(
                    [
                        "turn": ["id": turnID, "status": "inProgress", "error": NSNull()],
                        "reviewThreadId": reviewThreadID,
                    ],
                    as: responseType
                )
            case .turnCompletedBeforeFinalReviewThenThreadUnavailable(let reviewThreadID, _, let turnID, _, let finalReview):
                currentTurnID = turnID
                enqueueReviewStarted(reviewThreadID: reviewThreadID, turnID: turnID)
                let threadID = currentThreadID ?? reviewThreadID
                enqueueNotification(
                    .turnCompleted(
                        .init(
                            threadID: threadID,
                            turn: .init(id: turnID, status: .completed, error: nil)
                        )
                    )
                )
                enqueueNotification(
                    .threadStatusChanged(
                        .init(
                            threadID: threadID,
                            status: .init(type: "notLoaded")
                        )
                    )
                )
                enqueueNotification(.threadClosed(.init(threadID: threadID)))
                delayedNotifications.append(
                    .itemCompleted(
                        .init(
                            item: .exitedReviewMode(id: turnID, review: finalReview),
                            threadID: threadID,
                            turnID: turnID
                        )
                    )
                )
                scheduleDelayedNotifications()
                return try decodeResponse(
                    [
                        "turn": ["id": turnID, "status": "inProgress", "error": NSNull()],
                        "reviewThreadId": reviewThreadID,
                    ],
                    as: responseType
                )
            case .threadUnavailableRescheduledByTrackedActivity(
                let reviewThreadID,
                _,
                let turnID,
                _,
                let finalReview,
                let activityDelta
            ):
                currentTurnID = turnID
                enqueueReviewStarted(reviewThreadID: reviewThreadID, turnID: turnID)
                let threadID = currentThreadID ?? reviewThreadID
                enqueueNotification(
                    .threadStatusChanged(
                        .init(
                            threadID: threadID,
                            status: .init(type: "notLoaded")
                        )
                    )
                )
                let trackedActivity: AppServerAgentMessageDeltaNotification = try decodeResponse(
                    [
                        "threadId": threadID,
                        "turnId": turnID,
                        "itemId": "msg-review",
                        "delta": activityDelta,
                    ],
                    as: AppServerAgentMessageDeltaNotification.self
                )
                enqueueNotification(.agentMessageDelta(trackedActivity))
                enqueueSuccessReview(
                    reviewThreadID: reviewThreadID,
                    turnID: turnID,
                    finalReview: finalReview,
                    into: &delayedNotifications
                )
                scheduleDelayedNotifications()
                return try decodeResponse(
                    [
                        "turn": ["id": turnID, "status": "inProgress", "error": NSNull()],
                        "reviewThreadId": reviewThreadID,
                    ],
                    as: responseType
                )
            case .completedWithoutFinalReviewThenThreadUnavailable(let reviewThreadID, _, let turnID, _):
                currentTurnID = turnID
                enqueueReviewStarted(reviewThreadID: reviewThreadID, turnID: turnID)
                let threadID = currentThreadID ?? reviewThreadID
                enqueueNotification(
                    .turnCompleted(
                        .init(
                            threadID: threadID,
                            turn: .init(id: turnID, status: .completed, error: nil)
                        )
                    )
                )
                enqueueNotification(
                    .threadStatusChanged(
                        .init(
                            threadID: threadID,
                            status: .init(type: "notLoaded")
                        )
                    )
                )
                return try decodeResponse(
                    [
                        "turn": ["id": turnID, "status": "inProgress", "error": NSNull()],
                        "reviewThreadId": reviewThreadID,
                    ],
                    as: responseType
                )
            case .commandOutputThenTransportDisconnect(
                let reviewThreadID,
                _,
                let turnID,
                _,
                let outputDelta,
                let message
            ):
                currentTurnID = turnID
                enqueueReviewStarted(reviewThreadID: reviewThreadID, turnID: turnID)
                let threadID = currentThreadID ?? reviewThreadID
                let output: AppServerCommandExecutionOutputDeltaNotification = try decodeResponse(
                    [
                        "threadId": threadID,
                        "turnId": turnID,
                        "itemId": "cmd-review",
                        "delta": outputDelta,
                    ],
                    as: AppServerCommandExecutionOutputDeltaNotification.self
                )
                enqueueNotification(.commandExecutionOutputDelta(output))
                scheduleDelayedDisconnect(message: message)
                return try decodeResponse(
                    [
                        "turn": ["id": turnID, "status": "inProgress", "error": NSNull()],
                        "reviewThreadId": reviewThreadID,
                    ],
                    as: responseType
                )
            case .commandOutputThenSuccessThenTransportDisconnect(
                let reviewThreadID,
                _,
                let turnID,
                _,
                let finalReview,
                let outputDelta,
                let message
            ):
                currentTurnID = turnID
                enqueueReviewStarted(reviewThreadID: reviewThreadID, turnID: turnID)
                let threadID = currentThreadID ?? reviewThreadID
                let output: AppServerCommandExecutionOutputDeltaNotification = try decodeResponse(
                    [
                        "threadId": threadID,
                        "turnId": turnID,
                        "itemId": "cmd-review",
                        "delta": outputDelta,
                    ],
                    as: AppServerCommandExecutionOutputDeltaNotification.self
                )
                enqueueNotification(.commandExecutionOutputDelta(output))
                enqueueSuccessReview(reviewThreadID: reviewThreadID, turnID: turnID, finalReview: finalReview)
                scheduleDelayedDisconnect(message: message)
                return try decodeResponse(
                    [
                        "turn": ["id": turnID, "status": "inProgress", "error": NSNull()],
                        "reviewThreadId": reviewThreadID,
                    ],
                    as: responseType
                )
            case .turnCompletedThenTransportDisconnect(
                let reviewThreadID,
                _,
                let turnID,
                _,
                let message
            ):
                currentTurnID = turnID
                enqueueReviewStarted(reviewThreadID: reviewThreadID, turnID: turnID)
                let threadID = currentThreadID ?? reviewThreadID
                enqueueNotification(
                    .turnCompleted(
                        .init(
                            threadID: threadID,
                            turn: .init(id: turnID, status: .completed, error: nil)
                        )
                    )
                )
                scheduleDelayedDisconnect(message: message)
                return try decodeResponse(
                    [
                        "turn": ["id": turnID, "status": "inProgress", "error": NSNull()],
                        "reviewThreadId": reviewThreadID,
                    ],
                    as: responseType
                )
            case .turnFailure(let message):
                let reviewThreadID = "thr-review"
                let turnID = "turn-review"
                currentTurnID = turnID
                enqueueReviewStarted(reviewThreadID: reviewThreadID, turnID: turnID)
                let threadID = currentThreadID ?? reviewThreadID
                enqueueNotification(
                    .turnCompleted(
                        .init(
                            threadID: threadID,
                            turn: .init(id: turnID, status: .failed, error: .init(message: message))
                        )
                    )
                )
                return try decodeResponse(
                    [
                        "turn": ["id": turnID, "status": "inProgress", "error": NSNull()],
                        "reviewThreadId": reviewThreadID,
                    ],
                    as: responseType
                )
            case .threadClosedWithoutTurnCompletion(let reviewThreadID, _, let turnID, _):
                currentTurnID = turnID
                enqueueReviewStarted(reviewThreadID: reviewThreadID, turnID: turnID)
                let threadID = currentThreadID ?? reviewThreadID
                enqueueNotification(
                    .threadStatusChanged(
                        .init(
                            threadID: threadID,
                            status: .init(type: "notLoaded")
                        )
                    )
                )
                enqueueNotification(.threadClosed(.init(threadID: threadID)))
                return try decodeResponse(
                    [
                        "turn": ["id": turnID, "status": "inProgress", "error": NSNull()],
                        "reviewThreadId": reviewThreadID,
                    ],
                    as: responseType
                )
            case .threadClosedBeforeCompletedNotifications(let reviewThreadID, _, let turnID, _, let finalReview):
                currentTurnID = turnID
                enqueueReviewStarted(reviewThreadID: reviewThreadID, turnID: turnID)
                let threadID = currentThreadID ?? reviewThreadID
                enqueueNotification(
                    .threadStatusChanged(
                        .init(
                            threadID: threadID,
                            status: .init(type: "notLoaded")
                        )
                    )
                )
                enqueueNotification(.threadClosed(.init(threadID: threadID)))
                enqueueSuccessReview(reviewThreadID: reviewThreadID, turnID: turnID, finalReview: finalReview)
                return try decodeResponse(
                    [
                        "turn": ["id": turnID, "status": "inProgress", "error": NSNull()],
                        "reviewThreadId": reviewThreadID,
                    ],
                    as: responseType
                )
            case .threadClosedThenTransportDisconnect(let reviewThreadID, _, let turnID, _, let message):
                currentTurnID = turnID
                enqueueReviewStarted(reviewThreadID: reviewThreadID, turnID: turnID)
                let threadID = currentThreadID ?? reviewThreadID
                enqueueNotification(
                    .threadStatusChanged(
                        .init(
                            threadID: threadID,
                            status: .init(type: "notLoaded")
                        )
                    )
                )
                enqueueNotification(.threadClosed(.init(threadID: threadID)))
                scheduleDelayedDisconnect(message: message)
                return try decodeResponse(
                    [
                        "turn": ["id": turnID, "status": "inProgress", "error": NSNull()],
                        "reviewThreadId": reviewThreadID,
                    ],
                    as: responseType
                )
            case .batchedSuccess(let reviewThreadID, _, let turnID, _, let finalReview):
                currentTurnID = turnID
                enqueueReviewStarted(reviewThreadID: reviewThreadID, turnID: turnID)
                enqueueSuccessReview(
                    reviewThreadID: reviewThreadID,
                    turnID: turnID,
                    finalReview: finalReview,
                    into: &delayedNotifications
                )
                scheduleDelayedNotifications()
                return try decodeResponse(
                    [
                        "turn": ["id": turnID, "status": "inProgress", "error": NSNull()],
                        "reviewThreadId": reviewThreadID,
                    ],
                    as: responseType
                )
            default:
                let reviewThreadID = "thr-review"
                let turnID = "turn-review"
                currentTurnID = turnID
                enqueueReviewStarted(reviewThreadID: reviewThreadID, turnID: turnID)
                enqueueSuccessReview(reviewThreadID: reviewThreadID, turnID: turnID, finalReview: "Looks solid overall.")
                return try decodeResponse(
                    [
                        "turn": ["id": turnID, "status": "inProgress", "error": NSNull()],
                        "reviewThreadId": reviewThreadID,
                    ],
                    as: responseType
                )
            }
        case "turn/interrupt":
            if case .interruptFailure(let message) = mode {
                throw AppServerResponseError(code: -32003, message: message)
            }
            if case .interruptIgnoredLongRunning = mode {
                return try decodeResponse([:], as: responseType)
            }
            let threadID = currentThreadID ?? "thr-review"
            let turnID = currentTurnID ?? "turn-review"
            enqueueNotification(
                .turnCompleted(
                    .init(
                        threadID: threadID,
                        turn: .init(
                            id: turnID,
                            status: .interrupted,
                            error: .init(message: "Cancellation requested.")
                        )
                    )
                )
            )
            return try decodeResponse([:], as: responseType)
        case "thread/backgroundTerminals/clean":
            backgroundCleanCount += 1
            return try decodeResponse([:], as: responseType)
        case "thread/unsubscribe":
            unsubscribeCount += 1
            return try decodeResponse(["status": "unsubscribed"], as: responseType)
        default:
            throw ReviewError.io("unsupported mock request: \(method)")
        }
    }

    package func notify<Params: Encodable & Sendable>(method: String, params _: Params) async throws {
        guard closed == false else {
            throw ReviewError.io("mock app-server session is closed.")
        }
        _ = method
    }

    package func notificationStream() async -> AsyncThrowingStreamSubscription<AppServerServerNotification> {
        let disconnected = self.disconnected
        let closed = self.closed
        var continuation: AsyncThrowingStream<AppServerServerNotification, Error>.Continuation!
        let stream = AsyncThrowingStream<AppServerServerNotification, Error>(bufferingPolicy: .unbounded) {
            continuation = $0
        }
        if let disconnected {
            continuation.finish(throwing: disconnected)
            return .init(stream: stream, cancel: {})
        }
        if closed {
            continuation.finish()
            return .init(stream: stream, cancel: {})
        }

        let subscriberID = UUID()
        notificationSubscribers[subscriberID] = continuation
        continuation.onTermination = { _ in
            Task {
                await self.removeNotificationSubscriber(id: subscriberID)
            }
        }
        return .init(
            stream: stream,
            cancel: { [weak self] in
                await self?.cancelNotificationSubscriber(id: subscriberID)
            }
        )
    }

    package func isClosed() async -> Bool {
        closed
    }

    package func close() async {
        closed = true
        delayedNotificationFlushTask?.cancel()
        delayedNotificationFlushTask = nil
        delayedDisconnectTask?.cancel()
        delayedDisconnectTask = nil
        finishNotificationSubscribers(failing: nil)
    }

    package func recordedPayload(for method: String) async -> Data? {
        requests.last(where: { $0.method == method })?.payload
    }

    package func activeNotificationSubscriberCount() async -> Int {
        notificationSubscribers.count
    }

    package func waitForRequest(_ method: String) async {
        if requestCounts[method, default: 0] > 0 {
            return
        }
        await withCheckedContinuation { continuation in
            if requestCounts[method, default: 0] > 0 {
                continuation.resume()
            } else {
                requestWaiters[method, default: []].append(continuation)
            }
        }
    }

    private func enqueueReviewStarted(reviewThreadID: String, turnID: String) {
        let threadID = currentThreadID ?? reviewThreadID
        enqueueNotification(
            .turnStarted(
                .init(
                    threadID: threadID,
                    turn: .init(id: turnID, status: .inProgress, error: nil)
                )
            )
        )
        enqueueNotification(
            .itemStarted(
                .init(
                    item: .enteredReviewMode(id: turnID, review: "current changes"),
                    threadID: threadID,
                    turnID: turnID
                )
            )
        )
    }

    private func enqueueSuccessReview(reviewThreadID: String, turnID: String, finalReview: String) {
        let threadID = currentThreadID ?? reviewThreadID
        enqueueNotification(
            .itemCompleted(
                .init(
                    item: .exitedReviewMode(id: turnID, review: finalReview),
                    threadID: threadID,
                    turnID: turnID
                )
            )
        )
        enqueueNotification(
            .turnCompleted(
                .init(
                    threadID: threadID,
                    turn: .init(id: turnID, status: .completed, error: nil)
                )
            )
        )
    }

    private func enqueueSuccessReview(
        reviewThreadID: String,
        turnID: String,
        finalReview: String,
        into destination: inout [AppServerServerNotification]
    ) {
        let threadID = currentThreadID ?? reviewThreadID
        destination.append(
            .itemCompleted(
                .init(
                    item: .exitedReviewMode(id: turnID, review: finalReview),
                    threadID: threadID,
                    turnID: turnID
                )
            )
        )
        destination.append(
            .turnCompleted(
                .init(
                    threadID: threadID,
                    turn: .init(id: turnID, status: .completed, error: nil)
                )
            )
        )
    }

    private func decodeResponse<Response: Decodable & Sendable>(
        _ object: Any,
        as responseType: Response.Type
    ) throws -> Response {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(responseType, from: data)
    }

    private func noteRequest(_ method: String) {
        requestCounts[method, default: 0] += 1
        let waiters = requestWaiters.removeValue(forKey: method) ?? []
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func enqueueNotification(_ notification: AppServerServerNotification) {
        for continuation in notificationSubscribers.values {
            continuation.yield(notification)
        }
    }

    private func scheduleDelayedNotifications() {
        delayedNotificationFlushTask?.cancel()
        delayedNotificationFlushTask = Task {
            await Task.yield()
            self.flushDelayedNotifications()
        }
    }

    private func scheduleDelayedDisconnect(message: String) {
        delayedDisconnectTask?.cancel()
        delayedDisconnectTask = Task {
            await Task.yield()
            self.disconnect(message: message)
        }
    }

    private func flushDelayedNotifications() {
        delayedNotificationFlushTask = nil
        guard delayedNotifications.isEmpty == false else {
            return
        }
        let notifications = delayedNotifications
        delayedNotifications.removeAll(keepingCapacity: false)
        for notification in notifications {
            enqueueNotification(notification)
        }
    }

    private func finishNotificationSubscribers(failing error: Error?) {
        let continuations = notificationSubscribers.values
        notificationSubscribers.removeAll()
        for continuation in continuations {
            if let error {
                continuation.finish(throwing: error)
            } else {
                continuation.finish()
            }
        }
    }

    private func disconnect(message: String) {
        closed = true
        delayedNotificationFlushTask?.cancel()
        delayedNotificationFlushTask = nil
        delayedDisconnectTask?.cancel()
        delayedDisconnectTask = nil
        let error = ReviewError.io(message)
        disconnected = error
        finishNotificationSubscribers(failing: error)
    }

    private func removeNotificationSubscriber(id: UUID) {
        notificationSubscribers[id] = nil
    }

    private func cancelNotificationSubscriber(id: UUID) {
        guard let continuation = notificationSubscribers.removeValue(forKey: id) else {
            return
        }
        continuation.finish()
    }
}

package actor MockAppServerManager: AppServerManaging {
    private struct TransportWaiter {
        var index: Int
        var continuation: CheckedContinuation<MockAppServerSessionTransport, Never>
    }

    private let modeProvider: @Sendable (String) -> MockAppServerMode
    private let runtimeState: AppServerRuntimeState
    private var prepareCountStorage = 0
    private var shutdownCountStorage = 0
    private var transports: [String: [MockAppServerSessionTransport]] = [:]
    private var transportCreationCounts: [String: Int] = [:]
    private var transportWaiters: [String: [TransportWaiter]] = [:]

    package init(
        modeProvider: @escaping @Sendable (String) -> MockAppServerMode,
        runtimeState: AppServerRuntimeState = .init(
            pid: 200,
            startTime: .init(seconds: 2, microseconds: 0),
            processGroupLeaderPID: 200,
            processGroupLeaderStartTime: .init(seconds: 2, microseconds: 0)
        )
    ) {
        self.modeProvider = modeProvider
        self.runtimeState = runtimeState
    }

    package func prepare() async throws -> AppServerRuntimeState {
        prepareCountStorage += 1
        return runtimeState
    }

    package func checkoutTransport(sessionID: String) async throws -> any AppServerSessionTransport {
        let transport = MockAppServerSessionTransport(mode: modeProvider(sessionID))
        transports[sessionID, default: []].append(transport)
        transportCreationCounts[sessionID, default: 0] += 1
        let availableTransports = transports[sessionID] ?? []
        let waiters = transportWaiters.removeValue(forKey: sessionID) ?? []
        var remainingWaiters: [TransportWaiter] = []
        for waiter in waiters {
            if availableTransports.indices.contains(waiter.index) {
                waiter.continuation.resume(returning: availableTransports[waiter.index])
            } else {
                remainingWaiters.append(waiter)
            }
        }
        if remainingWaiters.isEmpty == false {
            transportWaiters[sessionID] = remainingWaiters
        }
        return transport
    }

    package func checkoutAuthTransport() async throws -> any AppServerSessionTransport {
        MockAppServerSessionTransport(mode: .success())
    }

    package func currentRuntimeState() async -> AppServerRuntimeState? {
        runtimeState
    }

    package func diagnosticLineStream() async -> AsyncStreamSubscription<String> {
        var continuation: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String>(bufferingPolicy: .unbounded) {
            continuation = $0
        }
        continuation.finish()
        return .init(stream: stream, cancel: {})
    }

    package func diagnosticsTail() async -> String {
        ""
    }

    package func shutdown() async {
        shutdownCountStorage += 1
        for (_, sessionTransports) in transports {
            for transport in sessionTransports {
                await transport.close()
            }
        }
        transports.removeAll()
    }

    package func transport(for sessionID: String) async -> MockAppServerSessionTransport? {
        transports[sessionID]?.last
    }

    package func waitForTransport(
        sessionID: String,
        at index: Int = 0
    ) async -> MockAppServerSessionTransport {
        if let transport = transports[sessionID], transport.indices.contains(index) {
            return transport[index]
        }
        return await withCheckedContinuation { continuation in
            if let transports = transports[sessionID], transports.indices.contains(index) {
                continuation.resume(returning: transports[index])
            } else {
                transportWaiters[sessionID, default: []].append(
                    .init(index: index, continuation: continuation)
                )
            }
        }
    }

    package func prepareCount() async -> Int {
        prepareCountStorage
    }

    package func shutdownCount() async -> Int {
        shutdownCountStorage
    }

    package func transportCreationCount(for sessionID: String) async -> Int {
        transportCreationCounts[sessionID, default: 0]
    }
}

private struct EncodableBox<Value: Encodable>: Encodable {
    let value: Value

    func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
    }
}

package actor StubReviewAuthSession: ReviewAuthSession {
    private var accountResponse: AppServerAccountReadResponse
    private let loginResponse: AppServerLoginAccountResponse

    package init(
        accountResponse: AppServerAccountReadResponse = .init(
            account: nil,
            requiresOpenAIAuth: true
        ),
        loginResponse: AppServerLoginAccountResponse = .chatGPT(
            loginID: "login-stub",
            authURL: "https://example.invalid/oauth"
        )
    ) {
        self.accountResponse = accountResponse
        self.loginResponse = loginResponse
    }

    package func readAccount(refreshToken _: Bool) async throws -> AppServerAccountReadResponse {
        accountResponse
    }

    package func startLogin(_ params: AppServerLoginAccountParams) async throws -> AppServerLoginAccountResponse {
        _ = params
        return loginResponse
    }

    package func cancelLogin(loginID _: String) async throws {}

    package func logout() async throws {
        accountResponse = .init(account: nil, requiresOpenAIAuth: true)
    }

    package func notificationStream() async -> AsyncThrowingStreamSubscription<AppServerServerNotification> {
        let (stream, continuation) = AsyncThrowingStream<AppServerServerNotification, Error>.makeStream()
        continuation.finish()
        return .init(stream: stream, cancel: {})
    }

    package func close() async {}
}

package func makeStubReviewAuthSessionFactory(
    accountResponse: AppServerAccountReadResponse = .init(
        account: nil,
        requiresOpenAIAuth: true
    ),
    loginResponse: AppServerLoginAccountResponse = .chatGPT(
        loginID: "login-stub",
        authURL: "https://example.invalid/oauth"
    )
) -> @Sendable () async throws -> any ReviewAuthSession {
    {
        StubReviewAuthSession(
            accountResponse: accountResponse,
            loginResponse: loginResponse
        )
    }
}
