import Foundation

package protocol ReviewClock: Sendable {
    var now: ContinuousClock.Instant { get }
    func sleep(until deadline: ContinuousClock.Instant, tolerance: Duration?) async throws
}

package extension ReviewClock {
    func sleep(for duration: Duration) async throws {
        try await sleep(until: now.advanced(by: duration), tolerance: nil)
    }
}

extension ContinuousClock: ReviewClock {}
