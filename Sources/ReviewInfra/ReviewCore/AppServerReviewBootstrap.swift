import Foundation
import ReviewApplicationDependencies
import ReviewDomain

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
    notificationStream: AsyncThrowingStream<AppServerServerNotification, Error>,
    emitter: AppServerReviewRunnerSignalEmitter
) -> Task<Void, Never> {
    Task {
        do {
            for try await notification in notificationStream {
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
    }
}

func makeStringSourceTask(
    stream: AsyncStream<String>,
    emitter: AppServerReviewRunnerSignalEmitter
) -> Task<Void, Never> {
    Task {
        for await line in stream {
            await emitter.yield(.diagnosticLine(line))
        }
    }
}

func makeVoidSourceTask(
    stream: AsyncStream<Void>,
    emitter: AppServerReviewRunnerSignalEmitter
) -> Task<Void, Never> {
    Task {
        for await _ in stream {
            await emitter.yield(.stateChanged)
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

func runBootstrapRequestWithinRemainingReviewTimeout<Output: Sendable>(
    timeoutSeconds: Int?,
    startedAt: ContinuousClock.Instant,
    clock: any ReviewClock,
    operation: @escaping @Sendable () async throws -> Output
) async throws -> Output {
    guard let timeoutDuration = try remainingReviewTimeoutDuration(
        timeoutSeconds: timeoutSeconds,
        startedAt: startedAt,
        now: clock.now
    ) else {
        return try await operation()
    }
    let resultBox = BootstrapRequestResultBox<Output>()
    let operationTask = Task {
        do {
            resultBox.resume(with: .success(try await operation()))
        } catch {
            resultBox.resume(with: .failure(error))
        }
    }
    let timeoutTask = Task {
        do {
            try await clock.sleep(for: timeoutDuration)
            let timeoutSeconds = timeoutSeconds ?? 0
            resultBox.resume(
                with: .failure(
                    ReviewError.io("Review timed out after \(timeoutSeconds) seconds.")
                )
            )
        } catch is CancellationError {
        } catch {
            resultBox.resume(with: .failure(error))
        }
    }

    return try await withTaskCancellationHandler {
        defer {
            operationTask.cancel()
            timeoutTask.cancel()
        }

        return try await withCheckedThrowingContinuation { continuation in
            resultBox.install(continuation)
        }
    } onCancel: {
        resultBox.resume(with: .failure(CancellationError()))
        operationTask.cancel()
        timeoutTask.cancel()
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

private final class BootstrapRequestResultBox<Output: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Output, Error>?
    private var pendingResult: Swift.Result<Output, Error>?

    func install(_ continuation: CheckedContinuation<Output, Error>) {
        let pendingResult = lock.withLock { () -> Swift.Result<Output, Error>? in
            self.continuation = continuation
            let pendingResult = self.pendingResult
            self.pendingResult = nil
            return pendingResult
        }
        if let pendingResult {
            resume(continuation: continuation, with: pendingResult)
        }
    }

    func resume(with result: sending Swift.Result<Output, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<Output, Error>? in
            let continuation = self.continuation
            if continuation == nil, self.pendingResult == nil {
                self.pendingResult = result
                return nil
            }
            self.continuation = nil
            return continuation
        }
        guard let continuation else {
            return
        }

        resume(continuation: continuation, with: result)
    }

    private func resume(
        continuation: CheckedContinuation<Output, Error>,
        with result: Swift.Result<Output, Error>
    ) {
        switch result {
        case .success(let value):
            continuation.resume(returning: value)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
