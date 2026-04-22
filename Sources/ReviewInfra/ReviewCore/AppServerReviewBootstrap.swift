import Foundation
import ReviewDomain

package struct ReviewBootstrapFailure: Error, LocalizedError, Sendable {
    package var message: String
    package var model: String?

    package init(message: String, model: String? = nil) {
        self.message = message
        self.model = model
    }

    package var errorDescription: String? {
        message
    }
}

package struct ReviewProcessOutcome: Sendable {
    package var state: ReviewJobState
    package var exitCode: Int
    package var reviewThreadID: String?
    package var threadID: String?
    package var turnID: String?
    package var model: String?
    package var hasFinalReview: Bool
    package var lastAgentMessage: String
    package var errorMessage: String?
    package var summary: String
    package var startedAt: Date
    package var endedAt: Date
    package var content: String
}

enum AppServerReviewRunnerSignal: Sendable {
    case notification(AppServerServerNotification)
    case diagnosticLine(String)
    case stateChanged
    case timeoutFired
    case threadUnavailableGraceExpired
    case completedWithoutFinalReviewGraceExpired
    case completedTurnSettleExpired
    case transportDisconnectGraceExpired
    case interruptResolutionCheck
    case transportClosed
    case transportDisconnected(String)
}

enum AppServerNotificationDeliveryTier: Sendable {
    case lossless
    case bestEffort
    case auxiliary
}

struct AppServerTrackedNotificationDisposition: Sendable {
    var shouldProcess: Bool
    var countsAsActivity: Bool
}

func codexNotificationDeliveryTier(
    _ notification: AppServerServerNotification
) -> AppServerNotificationDeliveryTier {
    switch notification {
    case .turnCompleted, .itemCompleted, .agentMessageDelta, .planDelta, .reasoningSummaryTextDelta, .reasoningTextDelta:
        .lossless
    case .commandExecutionOutputDelta:
        .bestEffort
    case .threadStatusChanged, .threadClosed, .turnStarted, .itemStarted, .reasoningSummaryPartAdded, .mcpToolCallProgress, .error, .accountLoginCompleted, .accountUpdated, .accountRateLimitsUpdated, .ignored:
        .auxiliary
    }
}

actor AppServerReviewRunnerSignalEmitter {
    private let continuation: AsyncStream<AppServerReviewRunnerSignal>.Continuation

    init(continuation: AsyncStream<AppServerReviewRunnerSignal>.Continuation) {
        self.continuation = continuation
    }

    func yield(_ signal: AppServerReviewRunnerSignal) {
        continuation.yield(signal)
    }
}

func makeNotificationSourceTask(
    subscription: AsyncThrowingStreamSubscription<AppServerServerNotification>,
    emitter: AppServerReviewRunnerSignalEmitter
) -> Task<Void, Never> {
    Task {
        await withTaskCancellationHandler {
            do {
                for try await notification in subscription.stream {
                    await emitter.yield(.notification(notification))
                }
                guard Task.isCancelled == false else {
                    return
                }
                await emitter.yield(.transportClosed)
            } catch {
                guard Task.isCancelled == false else {
                    return
                }
                await emitter.yield(.transportDisconnected(error.localizedDescription))
            }
        } onCancel: {
            Task {
                await subscription.cancel()
            }
        }
    }
}

func makeStringSourceTask(
    subscription: AsyncStreamSubscription<String>,
    emitter: AppServerReviewRunnerSignalEmitter
) -> Task<Void, Never> {
    Task {
        await withTaskCancellationHandler {
            for await line in subscription.stream {
                await emitter.yield(.diagnosticLine(line))
            }
        } onCancel: {
            Task {
                await subscription.cancel()
            }
        }
    }
}

func makeVoidSourceTask(
    subscription: AsyncStreamSubscription<Void>,
    emitter: AppServerReviewRunnerSignalEmitter
) -> Task<Void, Never> {
    Task {
        await withTaskCancellationHandler {
            for await _ in subscription.stream {
                await emitter.yield(.stateChanged)
            }
        } onCancel: {
            Task {
                await subscription.cancel()
            }
        }
    }
}

func makeDelayedSignalTask(
    duration: Duration,
    signal: AppServerReviewRunnerSignal,
    emitter: AppServerReviewRunnerSignalEmitter,
    clock: any ReviewClock,
    yieldFirst: Bool = false
) -> Task<Void, Never> {
    Task {
        do {
            if yieldFirst {
                await Task.yield()
            }
            try Task.checkCancellation()
            try await clock.sleep(for: duration)
            try Task.checkCancellation()
        } catch {
            return
        }
        await emitter.yield(signal)
    }
}

func runWithinRemainingReviewTimeout<Result: Sendable>(
    timeoutSeconds: Int?,
    startedAt: ContinuousClock.Instant,
    clock: any ReviewClock,
    operation: @escaping @Sendable () async throws -> Result
) async throws -> Result {
    guard let timeoutDuration = try remainingReviewTimeoutDuration(
        timeoutSeconds: timeoutSeconds,
        startedAt: startedAt,
        now: clock.now
    ) else {
        return try await operation()
    }
    return try await withThrowingTaskGroup(of: Result.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await clock.sleep(for: timeoutDuration)
            let timeoutSeconds = timeoutSeconds ?? 0
            throw ReviewError.io("Review timed out after \(timeoutSeconds) seconds.")
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else {
            throw ReviewError.io("review operation finished without a result.")
        }
        return result
    }
}

package func remainingReviewTimeoutDuration(
    timeoutSeconds: Int?,
    startedAt: ContinuousClock.Instant,
    now: ContinuousClock.Instant
) throws -> Duration? {
    guard let timeoutSeconds else {
        return nil
    }

    let elapsed = startedAt.duration(to: now)
    let timeoutDuration = Duration.seconds(timeoutSeconds)
    let remaining = timeoutDuration - elapsed
    guard remaining > .zero else {
        throw ReviewError.io("Review timed out after \(timeoutSeconds) seconds.")
    }

    return remaining
}
