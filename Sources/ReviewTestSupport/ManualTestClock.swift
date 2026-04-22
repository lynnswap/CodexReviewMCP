import Foundation
package import ReviewInfra

public final class ManualTestClock: Clock, @unchecked Sendable {
    public typealias Instant = ContinuousClock.Instant
    public typealias Duration = Swift.Duration

    private struct SleepWaiter {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct SuspensionWaiter {
        let minimumSleepers: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var now: Instant
        var sleepers: [UInt64: SleepWaiter] = [:]
        var nextSleepToken: UInt64 = 0
        var suspensionWaiters: [UInt64: SuspensionWaiter] = [:]
        var nextSuspensionToken: UInt64 = 0
    }

    private let lock = NSLock()
    private var state: State

    public init(now: Instant = ContinuousClock().now) {
        state = State(now: now)
    }

    public var now: Instant {
        lock.withLock { state.now }
    }

    public var minimumResolution: Duration {
        .nanoseconds(1)
    }

    public var hasSleepers: Bool {
        lock.withLock { state.sleepers.isEmpty == false }
    }

    public func sleep(for duration: Duration) async throws {
        try await sleep(until: now.advanced(by: duration), tolerance: nil)
    }

    public func sleep(until deadline: Instant, tolerance _: Duration? = nil) async throws {
        if deadline <= now {
            return
        }
        try Task.checkCancellation()

        let sleepToken = lock.withLock { () -> UInt64 in
            let token = state.nextSleepToken
            state.nextSleepToken &+= 1
            return token
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let suspensionContinuations = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                    if deadline <= state.now {
                        continuation.resume(returning: ())
                        return []
                    }

                    state.sleepers[sleepToken] = SleepWaiter(
                        deadline: deadline,
                        continuation: continuation
                    )
                    return Self.popReadySuspensionWaiters(state: &state)
                }

                for suspensionContinuation in suspensionContinuations {
                    suspensionContinuation.resume()
                }
            }
        } onCancel: {
            let continuation = lock.withLock { state.sleepers.removeValue(forKey: sleepToken)?.continuation }
            continuation?.resume(throwing: CancellationError())
        }
    }

    public func advance(by duration: Duration) {
        precondition(duration >= .zero, "duration must be non-negative")

        let readyContinuations = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            state.now = state.now.advanced(by: duration)

            let readyTokens = state.sleepers.compactMap { token, waiter in
                waiter.deadline <= state.now ? token : nil
            }

            return readyTokens.compactMap { token in
                state.sleepers.removeValue(forKey: token)?.continuation
            }
        }

        for continuation in readyContinuations {
            continuation.resume(returning: ())
        }
    }

    public func sleepUntilSuspendedBy(_ minimumSleepers: Int = 1) async {
        precondition(minimumSleepers > 0, "minimumSleepers must be positive")
        let suspensionToken = lock.withLock { () -> UInt64 in
            let token = state.nextSuspensionToken
            state.nextSuspensionToken &+= 1
            return token
        }

        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let shouldResumeImmediately = lock.withLock { () -> Bool in
                    if state.sleepers.count >= minimumSleepers {
                        return true
                    }

                    state.suspensionWaiters[suspensionToken] = SuspensionWaiter(
                        minimumSleepers: minimumSleepers,
                        continuation: continuation
                    )
                    return false
                }

                if shouldResumeImmediately {
                    continuation.resume()
                }
            }
        } onCancel: {
            let continuation = lock.withLock { state.suspensionWaiters.removeValue(forKey: suspensionToken)?.continuation }
            continuation?.resume()
        }
    }

    private static func popReadySuspensionWaiters(
        state: inout State
    ) -> [CheckedContinuation<Void, Never>] {
        let readyTokens = state.suspensionWaiters.compactMap { token, waiter in
            state.sleepers.count >= waiter.minimumSleepers ? token : nil
        }

        return readyTokens.compactMap { token in
            state.suspensionWaiters.removeValue(forKey: token)?.continuation
        }
    }
}

extension ManualTestClock: ReviewClock {}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
