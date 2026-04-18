import CodexReviewModel
import Foundation
import ReviewJobs

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
) -> (activeAccountKey: String?, accounts: [CodexAccount]) {
    let persistedRegistry = (try? loadRegistryRecord(environment: environment)) ?? .init()
    let registry = runtimeRegistryRecord(
        from: persistedRegistry,
        environment: environment
    )
    let records = registry.accounts
    let accounts = records.map { makeCodexAccount($0) }
    let activeAccountKey = records.contains(where: { $0.accountKey == registry.activeAccountKey })
        ? registry.activeAccountKey
        : nil
    if let activeAccountKey {
        for account in accounts {
            account.updateIsActive(account.accountKey == activeAccountKey)
        }
    }
    return (activeAccountKey, accounts)
}

private func runtimeRegistryRecord(
    from persistedRegistry: ReviewAccountRegistryRecord,
    environment: [String: String]
) -> ReviewAccountRegistryRecord {
    let canonicalPersistedRegistry = canonicalizeRegistryRecord(
        persistedRegistry,
        environment: environment
    )
    let persistedAccounts = canonicalPersistedRegistry.accounts.filter {
        savedAccountAuthSnapshotExists(
            accountKey: $0.accountKey,
            environment: environment
        )
    }
    let filteredPersistedRegistry = canonicalizeRegistryRecord(
        .init(
            activeAccountKey: canonicalPersistedRegistry.activeAccountKey,
            accounts: persistedAccounts
        ),
        environment: environment
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

private func storedAccount(
    in registry: ReviewAccountRegistryRecord,
    matchingRuntimeAccountKey accountKey: String,
    environment: [String: String]
) -> ReviewSavedAccountRecord? {
    storedAccountIndex(
        in: registry,
        matchingRuntimeAccountKey: accountKey,
        environment: environment
    )
    .map { registry.accounts[$0] }
}

private func storedAccountIndex(
    in registry: ReviewAccountRegistryRecord,
    matchingRuntimeAccountKey accountKey: String,
    environment: [String: String]
) -> Int? {
    if let exactIndex = registry.accounts.firstIndex(where: { $0.accountKey == accountKey }) {
        return exactIndex
    }
    let canonicalAccountsByEmail = canonicalAccountsByNormalizedEmail(
        in: registry,
        environment: environment
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
    guard let snapshot = loadAuthSnapshot(at: ReviewHomePaths.reviewAuthURL(environment: environment)) else {
        return nil
    }
    return CodexAccount(
        email: snapshot.email,
        planType: snapshot.planType
    )
}

package actor ReviewAccountRegistryStore {
    private let environment: [String: String]

    package init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    @MainActor
    package func loadAccounts() throws -> (activeAccountKey: String?, accounts: [CodexAccount]) {
        loadRegisteredReviewAccounts(environment: environment)
    }

    @MainActor
    package func saveSharedAuthAsSavedAccount(makeActive: Bool) throws -> CodexAccount? {
        guard let snapshot = loadAuthSnapshot(at: ReviewHomePaths.reviewAuthURL(environment: environment)) else {
            return nil
        }
        var registry = try loadRegistryRecord(environment: environment)
        return try saveAuthSnapshot(
            in: &registry,
            sourceAuthURL: ReviewHomePaths.reviewAuthURL(environment: environment),
            snapshot: snapshot,
            makeActive: makeActive
        )
    }

    @MainActor
    package func saveAuthSnapshot(
        sourceAuthURL: URL,
        makeActive: Bool
    ) throws -> CodexAccount {
        guard let snapshot = loadAuthSnapshot(at: sourceAuthURL) else {
            throw ReviewAuthError.authenticationRequired("Authenticated account is missing email.")
        }
        var registry = try loadRegistryRecord(environment: environment)
        return try saveAuthSnapshot(
            in: &registry,
            sourceAuthURL: sourceAuthURL,
            snapshot: snapshot,
            makeActive: makeActive
        )
    }

    package func activateAccount(_ accountKey: String) throws {
        let originalRegistry = try loadRegistry()
        var registry = originalRegistry
        guard let record = storedAccount(
            in: registry,
            matchingRuntimeAccountKey: accountKey,
            environment: environment
        ) else {
            throw ReviewAuthError.authenticationRequired("Saved account was not found.")
        }
        registry.activeAccountKey = record.accountKey
        registry.accounts = registry.accounts.map { account in
            var updated = account
            if account.accountKey == record.accountKey {
                updated.lastActivatedAt = Date()
            }
            return updated
        }
        try saveRegistry(registry)
        let sharedAuthBackup = loadSharedAuthData()
        do {
            try persistAuthSnapshot(
                from: persistedSavedAccountAuthURL(
                    accountKey: record.accountKey,
                    environment: environment
                ),
                to: ReviewHomePaths.reviewAuthURL(environment: environment)
            )
        } catch {
            rollbackRegistryMutation(
                originalRegistry: originalRegistry,
                sharedAuthBackup: sharedAuthBackup
            )
            throw error
        }
    }

    package func clearActiveAccount(accountKey: String? = nil) throws {
        let originalRegistry = try loadRegistry()
        var registry = originalRegistry
        let resolvedStoredAccount: ReviewSavedAccountRecord?
        if let accountKey {
            resolvedStoredAccount = storedAccount(
                in: registry,
                matchingRuntimeAccountKey: accountKey,
                environment: environment
            )
        } else {
            resolvedStoredAccount = nil
        }
        if let resolvedStoredAccount {
            registry.accounts.removeAll { $0.accountKey == resolvedStoredAccount.accountKey }
        }
        registry.activeAccountKey = nil
        try saveRegistry(registry)
        let sharedAuthBackup = loadSharedAuthData()
        do {
            try removeItemIfExists(at: ReviewHomePaths.reviewAuthURL(environment: environment))
            if let resolvedStoredAccount {
                for directoryURL in savedAccountDirectories(
                    matchingNormalizedEmail: normalizedReviewAccountEmail(email: resolvedStoredAccount.email),
                    fallbackAccountKey: resolvedStoredAccount.accountKey,
                    environment: environment
                ) {
                    try FileManager.default.removeItem(at: directoryURL)
                }
            }
        } catch {
            rollbackRegistryMutation(
                originalRegistry: originalRegistry,
                sharedAuthBackup: sharedAuthBackup
            )
            throw error
        }
    }

    package func invalidateSavedAccountAuth(_ accountKey: String) throws {
        let registry = try loadRegistry()
        guard let storedAccount = storedAccount(
            in: registry,
            matchingRuntimeAccountKey: accountKey,
            environment: environment
        ) else {
            return
        }
        for directoryURL in savedAccountDirectories(
            matchingNormalizedEmail: normalizedReviewAccountEmail(email: storedAccount.email),
            fallbackAccountKey: storedAccount.accountKey,
            environment: environment
        ) {
            try FileManager.default.removeItem(at: directoryURL)
        }
    }

    package func removeAccount(_ accountKey: String) throws -> String? {
        let originalRegistry = try loadRegistry()
        var registry = originalRegistry
        let storedAccount = storedAccount(
            in: originalRegistry,
            matchingRuntimeAccountKey: accountKey,
            environment: environment
        )
        let removedActive = originalRegistry.activeAccountKey == storedAccount?.accountKey
        registry.accounts.removeAll { account in
            account.accountKey == storedAccount?.accountKey
        }
        if removedActive,
           let replacementIndex = registry.accounts.firstIndex(where: { account in
               savedAccountAuthSnapshotExists(
                   accountKey: account.accountKey,
                   environment: environment
               )
           })
        {
            var replacementAccount = registry.accounts[replacementIndex]
            replacementAccount.lastActivatedAt = Date()
            registry.accounts[replacementIndex] = replacementAccount
            registry.activeAccountKey = replacementAccount.accountKey
        } else if removedActive {
            registry.activeAccountKey = nil
        }

        try saveRegistry(registry)
        let sharedAuthBackup = loadSharedAuthData()
        do {
            if removedActive {
                if let replacementAccountKey = registry.activeAccountKey {
                    try persistAuthSnapshot(
                        from: persistedSavedAccountAuthURL(
                            accountKey: replacementAccountKey,
                            environment: environment
                        ),
                        to: ReviewHomePaths.reviewAuthURL(environment: environment)
                    )
                } else {
                    try removeItemIfExists(at: ReviewHomePaths.reviewAuthURL(environment: environment))
                }
            }
            if let storedAccount {
                for directoryURL in savedAccountDirectories(
                    matchingNormalizedEmail: normalizedReviewAccountEmail(email: storedAccount.email),
                    fallbackAccountKey: storedAccount.accountKey,
                    environment: environment
                ) {
                    try FileManager.default.removeItem(at: directoryURL)
                }
            }
        } catch {
            rollbackRegistryMutation(
                originalRegistry: originalRegistry,
                sharedAuthBackup: sharedAuthBackup
            )
            throw error
        }
        return registry.activeAccountKey
    }

    package func reorderAccount(
        accountKey: String,
        toIndex: Int
    ) throws {
        var registry = try loadRegistry()
        let visibleAccountKeys = registry.accounts.compactMap { account -> String? in
            savedAccountAuthSnapshotExists(
                accountKey: account.accountKey,
                environment: environment
            ) ? normalizedReviewAccountEmail(email: account.email) : nil
        }
        guard let sourceVisibleIndex = visibleAccountKeys.firstIndex(of: accountKey) else {
            return
        }

        let destinationVisibleIndex = max(0, min(toIndex, visibleAccountKeys.count - 1))
        guard sourceVisibleIndex != destinationVisibleIndex,
              let sourceIndex = storedAccountIndex(
                in: registry,
                matchingRuntimeAccountKey: accountKey,
                environment: environment
              )
        else {
            return
        }

        let record = registry.accounts.remove(at: sourceIndex)
        let visibleAccountsAfterRemoval = registry.accounts.filter { account in
            savedAccountAuthSnapshotExists(
                accountKey: account.accountKey,
                environment: environment
            )
        }
        let insertionIndex: Int
        if destinationVisibleIndex >= visibleAccountsAfterRemoval.count {
            if let lastVisibleAccount = visibleAccountsAfterRemoval.last,
               let lastVisibleIndex = registry.accounts.firstIndex(where: {
                   $0.accountKey == lastVisibleAccount.accountKey
               })
            {
                insertionIndex = lastVisibleIndex + 1
            } else {
                insertionIndex = registry.accounts.endIndex
            }
        } else if let destinationAccountIndex = registry.accounts.firstIndex(where: {
            $0.accountKey == visibleAccountsAfterRemoval[destinationVisibleIndex].accountKey
        }) {
            insertionIndex = destinationAccountIndex
        } else {
            insertionIndex = registry.accounts.endIndex
        }
        registry.accounts.insert(record, at: insertionIndex)
        try saveRegistry(registry)
    }

    package func updateCachedRateLimits(
        accountKey: String,
        rateLimits: [ReviewSavedRateLimitWindowRecord],
        fetchedAt: Date,
        error: String?
    ) throws {
        var registry = try loadRegistry()
        guard let index = storedAccountIndex(
            in: registry,
            matchingRuntimeAccountKey: accountKey,
            environment: environment
        ) else {
            return
        }
        registry.accounts[index].cachedRateLimits = rateLimits
        registry.accounts[index].lastRateLimitFetchAt = fetchedAt
        registry.accounts[index].lastRateLimitError = error?.nilIfEmpty
        try saveRegistry(registry)
    }

    package func updateRateLimitFetchStatus(
        accountKey: String,
        fetchedAt: Date,
        error: String?
    ) throws {
        var registry = try loadRegistry()
        guard let index = storedAccountIndex(
            in: registry,
            matchingRuntimeAccountKey: accountKey,
            environment: environment
        ) else {
            return
        }
        registry.accounts[index].lastRateLimitFetchAt = fetchedAt
        registry.accounts[index].lastRateLimitError = error?.nilIfEmpty
        try saveRegistry(registry)
    }

    @MainActor
    package func updateCachedRateLimits(from account: CodexAccount) throws {
        var registry = try loadRegistryRecord(environment: environment)
        guard let index = storedAccountIndex(
            in: registry,
            matchingRuntimeAccountKey: account.accountKey,
            environment: environment
        ) else {
            return
        }
        registry.accounts[index].cachedRateLimits = account.rateLimits.map {
            .init(
                windowDurationMinutes: $0.windowDurationMinutes,
                usedPercent: $0.usedPercent,
                resetsAt: $0.resetsAt
            )
        }
        registry.accounts[index].lastRateLimitFetchAt = Date()
        registry.accounts[index].lastRateLimitError = account.lastRateLimitError?.nilIfEmpty
        try saveRegistryRecord(registry, environment: environment)
    }

    @MainActor
    package func updateSavedAccountMetadata(from account: CodexAccount) throws {
        var registry = try loadRegistryRecord(environment: environment)
        if let index = storedAccountIndex(
            in: registry,
            matchingRuntimeAccountKey: account.accountKey,
            environment: environment
        ) {
            registry.accounts[index].email = account.email
            registry.accounts[index].planType = account.planType
            try saveRegistryRecord(registry, environment: environment)
        }
    }

    package func prepareInactiveAccountProbe(accountKey: String) throws -> PreparedInactiveAccountProbe {
        let probeRoot = try makePreparedProbeRoot(copySharedAuthFromAccountKey: accountKey)
        return .init(
            environment: makeProbeEnvironment(homeRootURL: probeRoot),
            homeRootURL: probeRoot
        )
    }

    package func prepareAuthenticationLoginProbe() throws -> PreparedInactiveAccountProbe {
        let probeRoot = try makePreparedProbeRoot(copySharedAuthFromAccountKey: nil)
        return .init(
            environment: makeProbeEnvironment(homeRootURL: probeRoot),
            homeRootURL: probeRoot
        )
    }

    package func prepareSharedAuthProbe() throws -> PreparedInactiveAccountProbe {
        let probeRoot = try makePreparedProbeRoot(
            copySharedAuthFromAccountKey: nil,
            copySharedAuthFromSharedHome: true
        )
        return .init(
            environment: makeProbeEnvironment(homeRootURL: probeRoot),
            homeRootURL: probeRoot
        )
    }

    package func cleanupProbeHome(_ probe: PreparedInactiveAccountProbe) {
        try? FileManager.default.removeItem(at: probe.homeRootURL)
    }

    private func makePreparedProbeRoot(
        copySharedAuthFromAccountKey accountKey: String?,
        copySharedAuthFromSharedHome: Bool = false
    ) throws -> URL {
        let probeRoot = ReviewHomePaths.makeProbeRootURL(environment: environment)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            let probeEnvironment = makeProbeEnvironment(homeRootURL: probeRoot)
            let probeReviewHome = ReviewHomePaths.reviewHomeURL(environment: probeEnvironment)
            try ReviewHomePaths.ensureReviewHomeScaffold(at: probeReviewHome)
            try copySharedConfigurationIfPresent(into: probeReviewHome)
            if let accountKey {
                let registry = try loadRegistry()
                guard let storedAccount = storedAccount(
                    in: registry,
                    matchingRuntimeAccountKey: accountKey,
                    environment: environment
                ) else {
                    throw ReviewAuthError.authenticationRequired("Saved account was not found.")
                }
                try persistAuthSnapshot(
                    from: persistedSavedAccountAuthURL(
                        accountKey: storedAccount.accountKey,
                        environment: environment
                    ),
                    to: ReviewHomePaths.reviewAuthURL(environment: probeEnvironment)
                )
            } else if copySharedAuthFromSharedHome {
                try persistAuthSnapshot(
                    from: ReviewHomePaths.reviewAuthURL(environment: environment),
                    to: ReviewHomePaths.reviewAuthURL(environment: probeEnvironment)
                )
            }
            return probeRoot
        } catch {
            try? FileManager.default.removeItem(at: probeRoot)
            throw error
        }
    }

    private func loadRegistry() throws -> ReviewAccountRegistryRecord {
        try loadRegistryRecord(environment: environment)
    }

    private func saveRegistry(_ registry: ReviewAccountRegistryRecord) throws {
        try saveRegistryRecord(registry, environment: environment)
    }

    private func makeProbeEnvironment(homeRootURL: URL) -> [String: String] {
        var environment = environment
        environment["HOME"] = homeRootURL.path
        environment.removeValue(forKey: "CODEX_HOME")
        return environment
    }

    private func copySharedConfigurationIfPresent(into probeReviewHome: URL) throws {
        let sharedConfigURL = ReviewHomePaths.reviewConfigURL(environment: environment)
        let sharedAgentsURL = ReviewHomePaths.reviewAgentsURL(environment: environment)
        let targetConfigURL = probeReviewHome.appendingPathComponent("config.toml")
        let targetAgentsURL = probeReviewHome.appendingPathComponent("AGENTS.md")
        if FileManager.default.fileExists(atPath: sharedConfigURL.path) {
            try? FileManager.default.removeItem(at: targetConfigURL)
            try FileManager.default.copyItem(at: sharedConfigURL, to: targetConfigURL)
        }
        if FileManager.default.fileExists(atPath: sharedAgentsURL.path) {
            try? FileManager.default.removeItem(at: targetAgentsURL)
            try FileManager.default.copyItem(at: sharedAgentsURL, to: targetAgentsURL)
        }
    }

    @MainActor
    private func saveAuthSnapshot(
        in registry: inout ReviewAccountRegistryRecord,
        sourceAuthURL: URL,
        snapshot: ReviewStoredAuthSnapshot,
        makeActive: Bool
    ) throws -> CodexAccount {
        let record = upsertSavedAccountRecord(
            in: &registry,
            email: snapshot.email,
            planType: snapshot.planType,
            makeActive: makeActive
        )
        try persistAuthSnapshot(
            from: sourceAuthURL,
            to: ReviewHomePaths.savedAccountAuthURL(accountKey: record.accountKey, environment: environment)
        )
        if makeActive {
            try persistAuthSnapshot(
                from: sourceAuthURL,
                to: ReviewHomePaths.reviewAuthURL(environment: environment)
            )
        }
        try saveRegistryRecord(registry, environment: environment)
        return makeCodexAccount(record, isActive: registry.activeAccountKey == record.accountKey)
    }

    private func loadSharedAuthData() -> Data? {
        try? Data(contentsOf: ReviewHomePaths.reviewAuthURL(environment: environment))
    }

    private func rollbackRegistryMutation(
        originalRegistry: ReviewAccountRegistryRecord,
        sharedAuthBackup: Data?
    ) {
        try? saveRegistry(originalRegistry)
        try? restoreSharedAuth(from: sharedAuthBackup)
    }

    private func restoreSharedAuth(from backup: Data?) throws {
        let sharedAuthURL = ReviewHomePaths.reviewAuthURL(environment: environment)
        if let backup {
            try FileManager.default.createDirectory(
                at: sharedAuthURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try backup.write(to: sharedAuthURL, options: .atomic)
            return
        }
        try removeItemIfExists(at: sharedAuthURL)
    }

    private func removeItemIfExists(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

private func loadRegistryRecord(
    environment: [String: String]
) throws -> ReviewAccountRegistryRecord {
    try migrateLegacySharedAuthIfNeeded(environment: environment)
    let registryURL = ReviewHomePaths.accountsRegistryURL(environment: environment)
    guard let data = try? Data(contentsOf: registryURL) else {
        return .init()
    }
    guard let decoded = try? JSONDecoder().decode(ReviewAccountRegistryRecord.self, from: data)
    else {
        return .init()
    }
    return migrateRegistryRecordIfNeeded(decoded, environment: environment)
}

private func saveRegistryRecord(
    _ registry: ReviewAccountRegistryRecord,
    environment: [String: String]
) throws {
    let registryURL = ReviewHomePaths.accountsRegistryURL(environment: environment)
    try FileManager.default.createDirectory(
        at: registryURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(registry).write(to: registryURL, options: .atomic)
}

private func migrateLegacySharedAuthIfNeeded(
    environment: [String: String]
) throws {
    let registryURL = ReviewHomePaths.accountsRegistryURL(environment: environment)
    guard FileManager.default.fileExists(atPath: registryURL.path) == false else {
        return
    }
    guard let snapshot = loadAuthSnapshot(at: ReviewHomePaths.reviewAuthURL(environment: environment)) else {
        return
    }
    var registry = ReviewAccountRegistryRecord()
    let record = upsertSavedAccountRecord(
        in: &registry,
        email: snapshot.email,
        planType: snapshot.planType,
        makeActive: true
    )
    try persistAuthSnapshot(
        from: ReviewHomePaths.reviewAuthURL(environment: environment),
        to: ReviewHomePaths.savedAccountAuthURL(accountKey: record.accountKey, environment: environment)
    )
    try saveRegistryRecord(registry, environment: environment)
}

private func upsertSavedAccountRecord(
    in registry: inout ReviewAccountRegistryRecord,
    email: String,
    planType: String?,
    makeActive: Bool
) -> ReviewSavedAccountRecord {
    let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedEmail = normalizedReviewAccountEmail(email: trimmedEmail)
    let now = Date()
    let record: ReviewSavedAccountRecord
    let activeIndex = makeActive
        ? registry.accounts.firstIndex(where: { $0.accountKey == registry.activeAccountKey })
        : nil
    let emailIndex = registry.accounts.firstIndex {
        normalizedReviewAccountEmail(email: $0.email) == normalizedEmail
    }

    if makeActive, let activeIndex {
        let activeRecord = registry.accounts[activeIndex]
        let activeEmail = normalizedReviewAccountEmail(email: activeRecord.email)
        if activeEmail != normalizedEmail,
           let emailIndex,
           emailIndex != activeIndex
        {
            let emailRecord = registry.accounts[emailIndex]
            var activated = emailRecord
            activated.accountKey = normalizedEmail
            activated.email = trimmedEmail
            activated.planType = planType
            activated.lastActivatedAt = now
            registry.accounts[emailIndex] = activated
            registry.activeAccountKey = activated.accountKey
            return activated
        }

        if activeEmail != normalizedEmail {
            let inserted = ReviewSavedAccountRecord(
                accountKey: normalizedEmail,
                email: trimmedEmail,
                planType: planType,
                lastActivatedAt: now,
                lastRateLimitFetchAt: nil,
                lastRateLimitError: nil,
                cachedRateLimits: []
            )
            registry.accounts.append(inserted)
            record = inserted
        } else {
            var updated = activeRecord
            updated.accountKey = normalizedEmail
            updated.email = trimmedEmail
            updated.planType = planType
            updated.lastActivatedAt = now
            registry.accounts[activeIndex] = updated
            record = updated
        }
    } else if let emailIndex {
        var updated = registry.accounts[emailIndex]
        updated.accountKey = normalizedEmail
        updated.email = trimmedEmail
        updated.planType = planType
        if makeActive {
            updated.lastActivatedAt = now
        }
        registry.accounts[emailIndex] = updated
        record = updated
    } else {
        let inserted = ReviewSavedAccountRecord(
            accountKey: normalizedEmail,
            email: trimmedEmail,
            planType: planType,
            lastActivatedAt: makeActive ? now : nil,
            lastRateLimitFetchAt: nil,
            lastRateLimitError: nil,
            cachedRateLimits: []
        )
        registry.accounts.append(inserted)
        record = inserted
    }
    if makeActive {
        registry.activeAccountKey = record.accountKey
    }
    return record
}

private func persistAuthSnapshot(
    from sourceURL: URL,
    to destinationURL: URL
) throws {
    try FileManager.default.createDirectory(
        at: destinationURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let data = try Data(contentsOf: sourceURL)
    try data.write(to: destinationURL, options: .atomic)
}

@MainActor
private func makeCodexAccount(
    _ record: ReviewSavedAccountRecord,
    isActive: Bool = false
) -> CodexAccount {
    let account = CodexAccount(
        accountKey: record.accountKey,
        email: record.email,
        planType: record.planType
    )
    account.updateRateLimits(
        record.cachedRateLimits.map {
            (
                windowDurationMinutes: $0.windowDurationMinutes,
                usedPercent: $0.usedPercent,
                resetsAt: $0.resetsAt
            )
        }
    )
    account.updateRateLimitFetchMetadata(
        fetchedAt: record.lastRateLimitFetchAt,
        error: record.lastRateLimitError
    )
    account.updateIsActive(isActive)
    return account
}

private func canonicalizeRegistryRecord(
    _ registry: ReviewAccountRegistryRecord,
    environment: [String: String]
) -> ReviewAccountRegistryRecord {
    let canonicalAccountsByEmail = canonicalAccountsByNormalizedEmail(
        in: registry,
        environment: environment
    )
    var emittedEmails: Set<String> = []
    let deduplicatedAccounts: [ReviewSavedAccountRecord] = registry.accounts.compactMap { account in
        let normalizedEmail = normalizedReviewAccountEmail(email: account.email)
        guard canonicalAccountsByEmail[normalizedEmail] == account,
              emittedEmails.insert(normalizedEmail).inserted
        else {
            return nil
        }
        return account
    }

    let resolvedActiveAccountKey: String? = {
        guard let activeAccountKey = registry.activeAccountKey else {
            return nil
        }
        if deduplicatedAccounts.contains(where: { $0.accountKey == activeAccountKey }) {
            return activeAccountKey
        }
        guard let activeAccount = registry.accounts.first(where: { $0.accountKey == activeAccountKey }) else {
            return nil
        }
        let normalizedEmail = normalizedReviewAccountEmail(email: activeAccount.email)
        return deduplicatedAccounts.first {
            normalizedReviewAccountEmail(email: $0.email) == normalizedEmail
        }?.accountKey
    }()

    return .init(
        activeAccountKey: resolvedActiveAccountKey,
        accounts: deduplicatedAccounts
    )
}

private func shouldReplaceCanonicalAccount(
    _ current: ReviewSavedAccountRecord,
    with candidate: ReviewSavedAccountRecord,
    activeAccountKey: String?,
    environment: [String: String]
) -> Bool {
    let currentHasAuthSnapshot = savedAccountAuthSnapshotExists(
        accountKey: current.accountKey,
        environment: environment
    )
    let candidateHasAuthSnapshot = savedAccountAuthSnapshotExists(
        accountKey: candidate.accountKey,
        environment: environment
    )
    if currentHasAuthSnapshot != candidateHasAuthSnapshot {
        return candidateHasAuthSnapshot
    }

    let currentIsActive = current.accountKey == activeAccountKey
    let candidateIsActive = candidate.accountKey == activeAccountKey
    if currentIsActive != candidateIsActive {
        return candidateIsActive
    }

    switch (current.lastActivatedAt, candidate.lastActivatedAt) {
    case let (currentActivatedAt?, candidateActivatedAt?):
        if currentActivatedAt != candidateActivatedAt {
            return candidateActivatedAt > currentActivatedAt
        }
    case (nil, .some):
        return true
    case (.some, nil):
        return false
    case (nil, nil):
        break
    }

    return candidate.accountKey < current.accountKey
}

private func canonicalAccountsByNormalizedEmail(
    in registry: ReviewAccountRegistryRecord,
    environment: [String: String]
) -> [String: ReviewSavedAccountRecord] {
    var canonicalAccountsByEmail: [String: ReviewSavedAccountRecord] = [:]
    for account in registry.accounts {
        let normalizedEmail = normalizedReviewAccountEmail(email: account.email)
        if let existingAccount = canonicalAccountsByEmail[normalizedEmail] {
            if shouldReplaceCanonicalAccount(
                existingAccount,
                with: account,
                activeAccountKey: registry.activeAccountKey,
                environment: environment
            ) {
                canonicalAccountsByEmail[normalizedEmail] = account
            }
        } else {
            canonicalAccountsByEmail[normalizedEmail] = account
        }
    }
    return canonicalAccountsByEmail
}

private func registryUsesEmailKeys(_ registry: ReviewAccountRegistryRecord) -> Bool {
    if let activeAccountKey = registry.activeAccountKey,
       activeAccountKey.contains("@") == false
    {
        return false
    }

    for account in registry.accounts {
        if account.accountKey != normalizedReviewAccountEmail(email: account.email) {
            return false
        }
    }

    return true
}

private func migrateRegistryRecordIfNeeded(
    _ registry: ReviewAccountRegistryRecord,
    environment: [String: String]
) -> ReviewAccountRegistryRecord {
    if registryUsesEmailKeys(registry) {
        let canonicalRegistry = canonicalizeRegistryRecord(
            registry,
            environment: environment
        )
        if canonicalRegistry != registry {
            try? saveRegistryRecord(canonicalRegistry, environment: environment)
        }
        return canonicalRegistry
    }

    let canonicalOriginalAccountsByEmail = canonicalAccountsByNormalizedEmail(
        in: registry,
        environment: environment
    )
    let migratedAccounts = registry.accounts.map { account in
        var migrated = account
        migrated.accountKey = normalizedReviewAccountEmail(email: account.email)
        return migrated
    }

    let migratedActiveAccountKey: String? = registry.activeAccountKey.flatMap { activeAccountKey in
        if let activeAccount = registry.accounts.first(where: { $0.accountKey == activeAccountKey }) {
            return normalizedReviewAccountEmail(email: activeAccount.email)
        }
        return activeAccountKey.contains("@") ? normalizedReviewAccountEmail(email: activeAccountKey) : nil
    }

    let migratedRegistry = canonicalizeRegistryRecord(
        .init(
            activeAccountKey: migratedActiveAccountKey,
            accounts: migratedAccounts
        ),
        environment: environment
    )

    guard migrateSavedAccountDirectories(
        fromCanonicalAccountsByEmail: canonicalOriginalAccountsByEmail,
        to: migratedRegistry,
        environment: environment
    ) else {
        return registry
    }

    if registry != migratedRegistry {
        try? saveRegistryRecord(migratedRegistry, environment: environment)
    }

    return migratedRegistry
}

private func migrateSavedAccountDirectories(
    fromCanonicalAccountsByEmail canonicalOriginalAccountsByEmail: [String: ReviewSavedAccountRecord],
    to migratedRegistry: ReviewAccountRegistryRecord,
    environment: [String: String]
) -> Bool {
    for migratedAccount in migratedRegistry.accounts {
        let destinationAuthURL = ReviewHomePaths.savedAccountAuthURL(
            accountKey: migratedAccount.accountKey,
            environment: environment
        )
        let destinationURL = ReviewHomePaths.savedAccountDirectoryURL(
            accountKey: migratedAccount.accountKey,
            environment: environment
        )

        var candidateURLs: [URL] = []
        if let originalAccount = canonicalOriginalAccountsByEmail[migratedAccount.accountKey] {
            candidateURLs.append(contentsOf: savedAccountDirectoryCandidateURLs(
                accountKey: originalAccount.accountKey,
                environment: environment
            ))
        }
        candidateURLs.append(contentsOf: savedAccountDirectoryCandidateURLs(
            accountKey: migratedAccount.accountKey,
            environment: environment
        ))
        candidateURLs = candidateURLs.uniqued()
        let sourceURLs = candidateURLs.filter { $0 != destinationURL }
        let canonicalSourceURL = sourceURLs.first(where: directoryContainsSavedAccountAuthSnapshot(_:))
        let hasSourceSnapshot = sourceURLs.contains(where: directoryContainsSavedAccountAuthSnapshot(_:))

        if FileManager.default.fileExists(atPath: destinationAuthURL.path) {
            guard let canonicalSourceURL else {
                continue
            }
            let sourceAuthURL = canonicalSourceURL.appendingPathComponent("auth.json")
            let destinationAuthData = try? Data(contentsOf: destinationAuthURL)
            let sourceAuthData = try? Data(contentsOf: sourceAuthURL)
            if destinationAuthData == sourceAuthData {
                continue
            }
            let destinationModificationDate =
                ((try? destinationAuthURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate)
                ?? .distantPast
            let sourceModificationDate =
                ((try? sourceAuthURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate)
                ?? .distantPast
            if destinationModificationDate >= sourceModificationDate {
                continue
            }
            do {
                try FileManager.default.removeItem(at: destinationURL)
                try FileManager.default.copyItem(at: canonicalSourceURL, to: destinationURL)
                continue
            } catch {
                return false
            }
        }

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            if hasSourceSnapshot {
                return false
            }
            continue
        }

        if let canonicalSourceURL {
            do {
                try FileManager.default.createDirectory(
                    at: destinationURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.copyItem(at: canonicalSourceURL, to: destinationURL)
            } catch {
                return false
            }
        }

        if FileManager.default.fileExists(atPath: destinationAuthURL.path) == false,
           hasSourceSnapshot
        {
            return false
        }
    }

    return true
}

private func savedAccountDirectoryCandidateURLs(
    accountKey: String,
    environment: [String: String]
) -> [URL] {
    [
        ReviewHomePaths.savedAccountDirectoryURL(
            accountKey: accountKey,
            environment: environment
        ),
        ReviewHomePaths.legacySavedAccountDirectoryURL(
            accountKey: accountKey,
            environment: environment
        )
    ].uniqued()
}

private func savedAccountAuthSnapshotExists(
    accountKey: String,
    environment: [String: String]
) -> Bool {
    savedAccountDirectoryCandidateURLs(
        accountKey: accountKey,
        environment: environment
    )
    .contains(where: directoryContainsSavedAccountAuthSnapshot(_:))
}

private func directoryContainsSavedAccountAuthSnapshot(_ directoryURL: URL) -> Bool {
    FileManager.default.fileExists(
        atPath: directoryURL.appendingPathComponent("auth.json").path
    )
}

private func persistedSavedAccountAuthURL(
    accountKey: String,
    environment: [String: String]
) -> URL {
    savedAccountDirectoryCandidateURLs(
        accountKey: accountKey,
        environment: environment
    )
    .first(where: directoryContainsSavedAccountAuthSnapshot(_:))?
    .appendingPathComponent("auth.json")
    ?? ReviewHomePaths.savedAccountAuthURL(
        accountKey: accountKey,
        environment: environment
    )
}

private func savedAccountDirectories(
    matchingNormalizedEmail normalizedEmail: String,
    fallbackAccountKey: String? = nil,
    environment: [String: String]
) -> [URL] {
    let accountsDirectoryURL = ReviewHomePaths.accountsDirectoryURL(environment: environment)
    let directoryURLs = (try? FileManager.default.contentsOfDirectory(
        at: accountsDirectoryURL,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    )) ?? []
    let candidatePathComponents: Set<String> = {
        var components: Set<String> = [
            ReviewHomePaths.savedAccountDirectoryURL(
                accountKey: normalizedEmail,
                environment: environment
            ).lastPathComponent,
            ReviewHomePaths.legacySavedAccountDirectoryURL(
                accountKey: normalizedEmail,
                environment: environment
            ).lastPathComponent,
        ]
        if let fallbackAccountKey {
            components.insert(
                ReviewHomePaths.savedAccountDirectoryURL(
                    accountKey: fallbackAccountKey,
                    environment: environment
                ).lastPathComponent
            )
            components.insert(
                ReviewHomePaths.legacySavedAccountDirectoryURL(
                    accountKey: fallbackAccountKey,
                    environment: environment
                ).lastPathComponent
            )
        }
        return components
    }()

    var resolvedDirectories = directoryURLs.filter { candidatePathComponents.contains($0.lastPathComponent) }
    resolvedDirectories.append(contentsOf: directoryURLs.filter { directoryURL in
        guard directoryContainsSavedAccountAuthSnapshot(directoryURL),
              let snapshot = loadAuthSnapshot(
                at: directoryURL.appendingPathComponent("auth.json")
              )
        else {
            return false
        }
        return normalizedReviewAccountEmail(email: snapshot.email) == normalizedEmail
    })
    var seenPaths: Set<String> = []
    return resolvedDirectories.filter { directoryURL in
        guard FileManager.default.fileExists(atPath: directoryURL.path) else {
            return false
        }
        return seenPaths.insert(directoryURL.path).inserted
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}

private struct ReviewStoredAuthSnapshot: Equatable, Sendable {
    var email: String
    var planType: String?
}

private func loadAuthSnapshot(at authURL: URL) -> ReviewStoredAuthSnapshot? {
    guard let data = try? Data(contentsOf: authURL),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let authMode = object["auth_mode"] as? String,
          authMode == "chatgpt",
          let tokens = object["tokens"] as? [String: Any]
    else {
        return nil
    }

    if let idToken = tokens["id_token"] as? String,
       let claims = decodeReviewAuthJWTClaims(idToken),
       let email = reviewAuthClaimString(from: claims, keyPath: ["email"])?.nilIfEmpty
    {
        return .init(
            email: email,
            planType: reviewAuthClaimString(
                from: claims,
                keyPath: ["https://api.openai.com/auth", "chatgpt_plan_type"]
            )?.nilIfEmpty
        )
    }

    return nil
}

private func decodeReviewAuthJWTClaims(_ token: String) -> [String: Any]? {
    let segments = token.split(separator: ".", omittingEmptySubsequences: false)
    guard segments.count >= 2 else {
        return nil
    }

    var payload = String(segments[1])
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    let remainder = payload.count % 4
    if remainder != 0 {
        payload += String(repeating: "=", count: 4 - remainder)
    }

    guard let data = Data(base64Encoded: payload),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        return nil
    }
    return object
}

private func reviewAuthClaimString(
    from object: [String: Any],
    keyPath: [String]
) -> String? {
    var current: Any = object
    for key in keyPath {
        guard let dictionary = current as? [String: Any],
              let next = dictionary[key]
        else {
            return nil
        }
        current = next
    }
    return current as? String
}
