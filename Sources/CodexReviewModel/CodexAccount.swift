import Foundation
import Observation

public struct CodexRateLimitWindow: Sendable, Equatable {
    public var usedPercent: Int
    public var windowDurationMinutes: Int?
    public var resetsAt: Date?

    public init(
        usedPercent: Int,
        windowDurationMinutes: Int? = nil,
        resetsAt: Date? = nil
    ) {
        self.usedPercent = usedPercent
        self.windowDurationMinutes = windowDurationMinutes
        self.resetsAt = resetsAt
    }
}

public struct CodexRateLimitSnapshot: Sendable, Equatable {
    public var limitID: String?
    public var limitName: String?
    public var primary: CodexRateLimitWindow?
    public var secondary: CodexRateLimitWindow?

    public init(
        limitID: String? = nil,
        limitName: String? = nil,
        primary: CodexRateLimitWindow? = nil,
        secondary: CodexRateLimitWindow? = nil
    ) {
        self.limitID = limitID
        self.limitName = limitName
        self.primary = primary
        self.secondary = secondary
    }
}

@MainActor
@Observable
public final class CodexAccount {
    public var email: String?
    public var planType: String?
    public package(set) var rateLimitSnapshotsByLimitID: [String: CodexRateLimitSnapshot] = [:]
    public package(set) var currentRateLimitSnapshot: CodexRateLimitSnapshot?
    public package(set) var codexRateLimitSnapshot: CodexRateLimitSnapshot?
    public package(set) var codexFiveHourRateLimit: CodexRateLimitWindow?
    public package(set) var codexWeeklyRateLimit: CodexRateLimitWindow?

    public var displayName: String {
        let trimmedEmail = email?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedEmail, trimmedEmail.isEmpty == false {
            return trimmedEmail
        }
        return "ChatGPT"
    }

    public init(
        email: String? = nil,
        planType: String? = nil
    ) {
        self.email = email
        self.planType = planType
    }

    package func updateIdentity(
        email: String?,
        planType: String?
    ) {
        self.email = email
        self.planType = planType
    }

    package func updateRateLimits(
        currentSnapshot: CodexRateLimitSnapshot?,
        snapshotsByLimitID: [String: CodexRateLimitSnapshot]
    ) {
        currentRateLimitSnapshot = currentSnapshot
        rateLimitSnapshotsByLimitID = snapshotsByLimitID
        let resolvedCodexSnapshot = currentSnapshot.flatMap { snapshot in
                let normalizedLimitID = normalizedRateLimitID(snapshot.limitID)
                guard normalizedLimitID == nil || normalizedLimitID == "codex" else {
                    return nil
                }
                return snapshot
            }
            ?? snapshotsByLimitID["codex"]
        codexRateLimitSnapshot = resolvedCodexSnapshot
        codexFiveHourRateLimit = resolvedCodexSnapshot?.primary
        codexWeeklyRateLimit = resolvedCodexSnapshot?.secondary
    }

    package func mergeRateLimitSnapshot(
        _ snapshot: CodexRateLimitSnapshot,
        defaultLimitID: String = "codex"
    ) {
        let normalizedLimitID = normalizedRateLimitID(snapshot.limitID)
        let limitID = normalizedLimitID ?? defaultLimitID
        var snapshots = rateLimitSnapshotsByLimitID
        snapshots[limitID] = snapshot
        let currentBucketID = currentRateLimitSnapshot.flatMap { snapshot in
            normalizedRateLimitID(snapshot.limitID) ?? "codex"
        }
        let updatedCurrentSnapshot: CodexRateLimitSnapshot?
        if normalizedLimitID == nil {
            if currentRateLimitSnapshot == nil || currentBucketID == "codex" {
                updatedCurrentSnapshot = snapshot
            } else {
                updatedCurrentSnapshot = currentRateLimitSnapshot
            }
        } else if currentBucketID == limitID {
            updatedCurrentSnapshot = snapshot
        } else {
            updatedCurrentSnapshot = currentRateLimitSnapshot
        }
        updateRateLimits(
            currentSnapshot: updatedCurrentSnapshot,
            snapshotsByLimitID: snapshots
        )
    }

    package func clearRateLimits() {
        updateRateLimits(
            currentSnapshot: nil,
            snapshotsByLimitID: [:]
        )
    }

    private func normalizedRateLimitID(_ limitID: String?) -> String? {
        guard let limitID, limitID.isEmpty == false else {
            return nil
        }
        return limitID
    }
}
