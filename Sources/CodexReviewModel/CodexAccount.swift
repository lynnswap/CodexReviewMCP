import Foundation
import Observation
import ReviewJobs

@MainActor
@Observable
public final class CodexRateLimitWindow {
    nonisolated public let id: Int
    public var usedPercent: Int
    public var resetsAt: Date?

    nonisolated public var windowDurationMinutes: Int {
        id
    }

    public init(
        windowDurationMinutes: Int,
        usedPercent: Int,
        resetsAt: Date? = nil
    ) {
        precondition(windowDurationMinutes > 0, "CodexRateLimitWindow duration must be positive.")
        self.id = windowDurationMinutes
        self.usedPercent = min(max(usedPercent, 0), 100)
        self.resetsAt = resetsAt
    }

    package func update(
        usedPercent: Int,
        resetsAt: Date?
    ) {
        self.usedPercent = min(max(usedPercent, 0), 100)
        self.resetsAt = resetsAt
    }
}

extension CodexRateLimitWindow: Identifiable, Hashable {
    public static nonisolated func == (lhs: CodexRateLimitWindow, rhs: CodexRateLimitWindow) -> Bool {
        lhs.id == rhs.id
    }

    public nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

@MainActor
@Observable
public final class CodexAccount {
    nonisolated public let id: String
    nonisolated public let email: String
    public var planType: String?
    public package(set) var rateLimits: [CodexRateLimitWindow] = []
    public package(set) var isActive = false
    public package(set) var lastRateLimitFetchAt: Date?
    public package(set) var lastRateLimitError: String?

    nonisolated public var accountKey: String {
        id
    }

    public init(
        email: String,
        planType: String? = nil
    ) {
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(normalizedEmail.isEmpty == false, "CodexAccount email must not be empty.")
        self.id = normalizedReviewAccountKey(email: normalizedEmail)
        self.email = normalizedEmail
        self.planType = planType
    }

    package func updatePlanType(_ planType: String?) {
        self.planType = planType
    }

    package func updateIsActive(_ isActive: Bool) {
        self.isActive = isActive
    }

    package func updateRateLimits(
        _ rateLimits: [(windowDurationMinutes: Int, usedPercent: Int, resetsAt: Date?)]
    ) {
        let validRateLimitsByDuration = rateLimits.reduce(
            into: [Int: (windowDurationMinutes: Int, usedPercent: Int, resetsAt: Date?)]()
        ) { result, rateLimit in
            guard rateLimit.windowDurationMinutes > 0 else {
                return
            }
            result[rateLimit.windowDurationMinutes] = rateLimit
        }
        let existingRateLimitsByDuration = self.rateLimits.reduce(into: [Int: CodexRateLimitWindow]()) { result, window in
            result[window.windowDurationMinutes] = window
        }

        self.rateLimits = validRateLimitsByDuration.values
            .sorted { $0.windowDurationMinutes < $1.windowDurationMinutes }
            .map { rateLimit in
                if let existingRateLimit = existingRateLimitsByDuration[rateLimit.windowDurationMinutes] {
                    existingRateLimit.update(
                        usedPercent: rateLimit.usedPercent,
                        resetsAt: rateLimit.resetsAt
                    )
                    return existingRateLimit
                }

                return CodexRateLimitWindow(
                    windowDurationMinutes: rateLimit.windowDurationMinutes,
                    usedPercent: rateLimit.usedPercent,
                    resetsAt: rateLimit.resetsAt
                )
            }
    }

    package func updateRateLimitFetchMetadata(
        fetchedAt: Date?,
        error: String?
    ) {
        lastRateLimitFetchAt = fetchedAt
        lastRateLimitError = error?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    package func clearRateLimits() {
        rateLimits.removeAll()
    }
}

extension CodexAccount: Identifiable, Hashable {
    public static nonisolated func == (lhs: CodexAccount, rhs: CodexAccount) -> Bool {
        lhs.id == rhs.id
    }

    public nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
