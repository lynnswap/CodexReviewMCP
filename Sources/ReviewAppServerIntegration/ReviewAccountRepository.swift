import Foundation
import ReviewDomain
import ReviewInfrastructure

package struct ReviewSavedRateLimitWindowRecord: Codable, Equatable, Sendable {
    package var windowDurationMinutes: Int
    package var usedPercent: Int
    package var resetsAt: Date?

    package init(
        windowDurationMinutes: Int,
        usedPercent: Int,
        resetsAt: Date?
    ) {
        self.windowDurationMinutes = windowDurationMinutes
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

package struct ReviewSavedAccountRecord: Codable, Equatable, Sendable {
    package var accountKey: String
    package var email: String
    package var planType: String?
    package var lastActivatedAt: Date?
    package var lastRateLimitFetchAt: Date?
    package var lastRateLimitError: String?
    package var cachedRateLimits: [ReviewSavedRateLimitWindowRecord]
}

package struct ReviewAccountRegistryRecord: Codable, Equatable, Sendable {
    package var activeAccountKey: String?
    package var accounts: [ReviewSavedAccountRecord]

    package init(
        activeAccountKey: String? = nil,
        accounts: [ReviewSavedAccountRecord] = []
    ) {
        self.activeAccountKey = activeAccountKey
        self.accounts = accounts
    }
}

package struct PreparedInactiveAccountProbe: Sendable {
    package var environment: [String: String]
    package var homeRootURL: URL
}

@MainActor
package func loadRegisteredReviewAccounts(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> (activeAccountKey: String?, accounts: [CodexSavedAccountPayload]) {
    loadRegisteredReviewAccounts(dependencies: .live(environment: environment))
}

@MainActor
package func loadRegisteredReviewAccounts(
    dependencies: ReviewCoreDependencies
) -> (activeAccountKey: String?, accounts: [CodexSavedAccountPayload]) {
    let persistedRegistry = (try? loadRegistryRecord(dependencies: dependencies)) ?? .init()
    let registry = runtimeRegistryRecord(
        from: persistedRegistry,
        dependencies: dependencies
    )
    let records = registry.accounts
    let accounts = records.map(makeSavedAccountPayload)
    let activeAccountKey = records.contains(where: { $0.accountKey == registry.activeAccountKey })
        ? registry.activeAccountKey
        : nil
    return (activeAccountKey, accounts)
}

func runtimeRegistryRecord(
    from persistedRegistry: ReviewAccountRegistryRecord,
    environment: [String: String]
) -> ReviewAccountRegistryRecord {
    runtimeRegistryRecord(
        from: persistedRegistry,
        dependencies: .live(environment: environment)
    )
}

func runtimeRegistryRecord(
    from persistedRegistry: ReviewAccountRegistryRecord,
    dependencies: ReviewCoreDependencies
) -> ReviewAccountRegistryRecord {
    let canonicalPersistedRegistry = canonicalizeRegistryRecord(
        persistedRegistry,
        dependencies: dependencies
    )
    let persistedAccounts = canonicalPersistedRegistry.accounts.filter {
        savedAccountAuthSnapshotExists(
            accountKey: $0.accountKey,
            dependencies: dependencies
        )
    }
    let filteredPersistedRegistry = canonicalizeRegistryRecord(
        .init(
            activeAccountKey: canonicalPersistedRegistry.activeAccountKey,
            accounts: persistedAccounts
        ),
        dependencies: dependencies
    )
    let runtimeAccounts = filteredPersistedRegistry.accounts.map { account in
        var runtimeAccount = account
        runtimeAccount.accountKey = normalizedReviewAccountEmail(email: account.email)
        return runtimeAccount
    }
    let runtimeActiveAccountKey = filteredPersistedRegistry.activeAccountKey.flatMap { activeAccountKey in
        if let activeAccount = filteredPersistedRegistry.accounts.first(where: { $0.accountKey == activeAccountKey }) {
            return normalizedReviewAccountEmail(email: activeAccount.email)
        }
        return activeAccountKey.contains("@") ? normalizedReviewAccountEmail(email: activeAccountKey) : nil
    }
    return .init(
        activeAccountKey: runtimeActiveAccountKey,
        accounts: runtimeAccounts
    )
}

func storedAccount(
    in registry: ReviewAccountRegistryRecord,
    matchingRuntimeAccountKey accountKey: String,
    environment: [String: String]
) -> ReviewSavedAccountRecord? {
    storedAccount(
        in: registry,
        matchingRuntimeAccountKey: accountKey,
        dependencies: .live(environment: environment)
    )
}

func storedAccount(
    in registry: ReviewAccountRegistryRecord,
    matchingRuntimeAccountKey accountKey: String,
    dependencies: ReviewCoreDependencies
) -> ReviewSavedAccountRecord? {
    storedAccountIndex(
        in: registry,
        matchingRuntimeAccountKey: accountKey,
        dependencies: dependencies
    )
    .map { registry.accounts[$0] }
}

func storedAccountIndex(
    in registry: ReviewAccountRegistryRecord,
    matchingRuntimeAccountKey accountKey: String,
    environment: [String: String]
) -> Int? {
    storedAccountIndex(
        in: registry,
        matchingRuntimeAccountKey: accountKey,
        dependencies: .live(environment: environment)
    )
}

func storedAccountIndex(
    in registry: ReviewAccountRegistryRecord,
    matchingRuntimeAccountKey accountKey: String,
    dependencies: ReviewCoreDependencies
) -> Int? {
    if let exactIndex = registry.accounts.firstIndex(where: { $0.accountKey == accountKey }) {
        return exactIndex
    }
    let canonicalAccountsByEmail = canonicalAccountsByNormalizedEmail(
        in: registry,
        dependencies: dependencies
    )
    let normalizedAccountKey = normalizedReviewAccountEmail(email: accountKey)
    guard let canonicalAccount = canonicalAccountsByEmail[normalizedAccountKey] else {
        return nil
    }
    return registry.accounts.firstIndex(of: canonicalAccount)
}

@MainActor
package func loadSharedReviewAccount(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> CodexAccount? {
    loadSharedReviewAccount(dependencies: .live(environment: environment))
}

@MainActor
package func loadSharedReviewAccount(
    dependencies: ReviewCoreDependencies
) -> CodexAccount? {
    guard let snapshot = loadAuthSnapshot(
        at: dependencies.paths.reviewAuthURL(),
        dependencies: dependencies
    ) else {
        return nil
    }
    return CodexAccount(
        email: snapshot.email,
        planType: snapshot.planType
    )
}

package func makeSavedAccountPayload(
    _ record: ReviewSavedAccountRecord
) -> CodexSavedAccountPayload {
    .init(
        accountKey: record.accountKey,
        email: record.email,
        planType: record.planType,
        rateLimits: record.cachedRateLimits.map {
            (
                windowDurationMinutes: $0.windowDurationMinutes,
                usedPercent: $0.usedPercent,
                resetsAt: $0.resetsAt
            )
        },
        lastRateLimitFetchAt: record.lastRateLimitFetchAt,
        lastRateLimitError: record.lastRateLimitError
    )
}
