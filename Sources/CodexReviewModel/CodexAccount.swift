import Foundation
import Observation
import ReviewJobs

@MainActor
@Observable
public final class CodexRateLimitWindow {
    nonisolated public let id: String
    nonisolated public let accountKey: String
    nonisolated public let windowDurationMinutes: Int
    public var usedPercent: Int
    public var resetsAt: Date?

    public init(
        accountKey: String = "__standalone__",
        windowDurationMinutes: Int,
        usedPercent: Int,
        resetsAt: Date? = nil
    ) {
        precondition(windowDurationMinutes > 0, "CodexRateLimitWindow duration must be positive.")
        self.accountKey = accountKey
        self.windowDurationMinutes = windowDurationMinutes
        self.id = "\(accountKey):\(windowDurationMinutes)"
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
    public package(set) var email: String
    public package(set) var maskedEmail: String
    public var planType: String?
    public package(set) var rateLimits: [CodexRateLimitWindow] = []
    public package(set) var isActive = false
    public package(set) var isSwitching = false
    public package(set) var lastRateLimitFetchAt: Date?
    public package(set) var lastRateLimitError: String?

    nonisolated public var accountKey: String {
        id
    }

    public init(
        accountKey: String? = nil,
        email: String,
        planType: String? = nil
    ) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(trimmedEmail.isEmpty == false, "CodexAccount email must not be empty.")
        let normalizedEmail = normalizedReviewAccountEmail(email: trimmedEmail)
        let resolvedAccountKey = accountKey.map {
            normalizedReviewAccountEmail(email: $0)
        } ?? normalizedEmail
        precondition(
            resolvedAccountKey == normalizedEmail,
            "CodexAccount accountKey must match normalized email identity."
        )
        self.id = resolvedAccountKey
        self.email = trimmedEmail
        self.maskedEmail = maskedReviewAccountEmail(trimmedEmail)
        self.planType = planType
    }

    package func updateEmail(_ email: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(trimmedEmail.isEmpty == false, "CodexAccount email must not be empty.")
        precondition(
            normalizedReviewAccountEmail(email: trimmedEmail) == accountKey,
            "CodexAccount email updates must preserve account identity."
        )
        self.email = trimmedEmail
        self.maskedEmail = maskedReviewAccountEmail(trimmedEmail)
    }

    package func updatePlanType(_ planType: String?) {
        self.planType = planType
    }

    package func updateIsActive(_ isActive: Bool) {
        self.isActive = isActive
    }

    package func updateIsSwitching(_ isSwitching: Bool) {
        guard self.isSwitching != isSwitching else {
            return
        }
        self.isSwitching = isSwitching
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
                    accountKey: accountKey,
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

private func maskedReviewAccountEmail(_ email: String) -> String {
    let parts = email.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2,
          parts[0].isEmpty == false,
          parts[1].isEmpty == false
    else {
        return maskedReviewAccountEmailSegment(email)
    }
    return "\(maskedReviewAccountEmailSegment(String(parts[0])))@\(parts[1])"
}

private func maskedReviewAccountEmailSegment(_ segment: String) -> String {
    let characters = Array(segment)
    switch characters.count {
    case 0:
        return segment
    case 1 ... 2:
        return String(characters.prefix(1)) + "…"
    case 3 ... 4:
        return String(characters.prefix(1)) + "…" + String(characters.suffix(1))
    default:
        return String(characters.prefix(2)) + "…" + String(characters.suffix(2))
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
