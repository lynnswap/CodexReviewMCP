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
    package var accountKey: UUID
    package var email: String
    package var planType: String?
    package var lastActivatedAt: Date?
    package var lastRateLimitFetchAt: Date?
    package var lastRateLimitError: String?
    package var cachedRateLimits: [ReviewSavedRateLimitWindowRecord]
}

package struct ReviewAccountRegistryRecord: Codable, Equatable, Sendable {
    package var activeAccountKey: UUID?
    package var accounts: [ReviewSavedAccountRecord]

    package init(
        activeAccountKey: UUID? = nil,
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
) -> (activeAccountKey: UUID?, accounts: [CodexAccount]) {
    let registry = (try? loadRegistryRecord(environment: environment)) ?? .init()
    let records = registry.accounts.filter {
        FileManager.default.fileExists(
            atPath: ReviewHomePaths.savedAccountAuthURL(
                accountKey: $0.accountKey,
                environment: environment
            ).path
        )
    }
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
    package func loadAccounts() throws -> (activeAccountKey: UUID?, accounts: [CodexAccount]) {
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

    package func activateAccount(_ accountKey: UUID) throws {
        let originalRegistry = try loadRegistry()
        var registry = originalRegistry
        guard let record = registry.accounts.first(where: { $0.accountKey == accountKey }) else {
            throw ReviewAuthError.authenticationRequired("Saved account was not found.")
        }
        registry.activeAccountKey = record.accountKey
        registry.accounts = registry.accounts.map { account in
            var updated = account
            if account.accountKey == accountKey {
                updated.lastActivatedAt = Date()
            }
            return updated
        }.sorted(by: sortAccounts)
        try saveRegistry(registry)
        let sharedAuthBackup = loadSharedAuthData()
        do {
            try persistAuthSnapshot(
                from: ReviewHomePaths.savedAccountAuthURL(accountKey: accountKey, environment: environment),
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

    package func clearActiveAccount(accountKey: UUID? = nil) throws {
        let originalRegistry = try loadRegistry()
        var registry = originalRegistry
        if let accountKey {
            registry.accounts.removeAll { $0.accountKey == accountKey }
        }
        registry.activeAccountKey = nil
        try saveRegistry(registry)
        let sharedAuthBackup = loadSharedAuthData()
        do {
            try removeItemIfExists(at: ReviewHomePaths.reviewAuthURL(environment: environment))
            if let accountKey {
                try removeItemIfExists(
                    at: ReviewHomePaths.savedAccountAuthURL(
                        accountKey: accountKey,
                        environment: environment
                    )
                )
            }
        } catch {
            rollbackRegistryMutation(
                originalRegistry: originalRegistry,
                sharedAuthBackup: sharedAuthBackup
            )
            throw error
        }
    }

    package func invalidateSavedAccountAuth(_ accountKey: UUID) throws {
        try removeItemIfExists(
            at: ReviewHomePaths.savedAccountAuthURL(
                accountKey: accountKey,
                environment: environment
            )
        )
    }

    package func removeAccount(_ accountKey: UUID) throws -> UUID? {
        let originalRegistry = try loadRegistry()
        var registry = originalRegistry
        registry.accounts.removeAll { $0.accountKey == accountKey }
        let savedAccountDirectoryURL = ReviewHomePaths.savedAccountDirectoryURL(
            accountKey: accountKey,
            environment: environment
        )
        if originalRegistry.activeAccountKey == accountKey {
            registry.activeAccountKey = nil
        }

        try saveRegistry(registry)
        let sharedAuthBackup = loadSharedAuthData()
        do {
            if originalRegistry.activeAccountKey == accountKey {
                try removeItemIfExists(at: ReviewHomePaths.reviewAuthURL(environment: environment))
            }
            if FileManager.default.fileExists(atPath: savedAccountDirectoryURL.path) {
                try FileManager.default.removeItem(at: savedAccountDirectoryURL)
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

    package func updateCachedRateLimits(
        accountKey: UUID,
        rateLimits: [ReviewSavedRateLimitWindowRecord],
        fetchedAt: Date,
        error: String?
    ) throws {
        var registry = try loadRegistry()
        guard let index = registry.accounts.firstIndex(where: { $0.accountKey == accountKey }) else {
            return
        }
        registry.accounts[index].cachedRateLimits = rateLimits
        registry.accounts[index].lastRateLimitFetchAt = fetchedAt
        registry.accounts[index].lastRateLimitError = error?.nilIfEmpty
        try saveRegistry(registry)
    }

    package func updateRateLimitFetchStatus(
        accountKey: UUID,
        fetchedAt: Date,
        error: String?
    ) throws {
        var registry = try loadRegistry()
        guard let index = registry.accounts.firstIndex(where: { $0.accountKey == accountKey }) else {
            return
        }
        registry.accounts[index].lastRateLimitFetchAt = fetchedAt
        registry.accounts[index].lastRateLimitError = error?.nilIfEmpty
        try saveRegistry(registry)
    }

    @MainActor
    package func updateCachedRateLimits(from account: CodexAccount) throws {
        var registry = try loadRegistryRecord(environment: environment)
        guard let index = registry.accounts.firstIndex(where: { $0.accountKey == account.accountKey }) else {
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
        if let index = registry.accounts.firstIndex(where: { $0.accountKey == account.accountKey }) {
            registry.accounts[index].email = account.email
            registry.accounts[index].planType = account.planType
            try saveRegistryRecord(registry, environment: environment)
        }
    }

    package func prepareInactiveAccountProbe(accountKey: UUID) throws -> PreparedInactiveAccountProbe {
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
        copySharedAuthFromAccountKey accountKey: UUID?,
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
                try persistAuthSnapshot(
                    from: ReviewHomePaths.savedAccountAuthURL(accountKey: accountKey, environment: environment),
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
    guard let decoded = try? JSONDecoder().decode(ReviewAccountRegistryRecord.self, from: data) else {
        return .init()
    }
    return canonicalizeRegistryRecord(decoded, environment: environment)
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
            activated.email = trimmedEmail
            activated.planType = planType
            activated.lastActivatedAt = now
            registry.accounts[emailIndex] = activated
            registry.activeAccountKey = activated.accountKey
            registry.accounts.sort(by: sortAccounts)
            return activated
        }

        if activeEmail != normalizedEmail {
            let inserted = ReviewSavedAccountRecord(
                accountKey: UUID(),
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
            updated.email = trimmedEmail
            updated.planType = planType
            updated.lastActivatedAt = now
            registry.accounts[activeIndex] = updated
            record = updated
        }
    } else if let emailIndex {
        var updated = registry.accounts[emailIndex]
        updated.email = trimmedEmail
        updated.planType = planType
        if makeActive {
            updated.lastActivatedAt = now
        }
        registry.accounts[emailIndex] = updated
        record = updated
    } else {
        let inserted = ReviewSavedAccountRecord(
            accountKey: UUID(),
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
    registry.accounts.sort(by: sortAccounts)
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
    let orderedAccounts = registry.accounts.sorted {
        canonicalRegistryOrder(
            lhs: $0,
            rhs: $1,
            activeAccountKey: registry.activeAccountKey,
            environment: environment
        )
    }
    var deduplicatedAccounts: [ReviewSavedAccountRecord] = []
    for account in orderedAccounts {
        let normalizedEmail = normalizedReviewAccountEmail(email: account.email)
        guard deduplicatedAccounts.contains(where: {
            normalizedReviewAccountEmail(email: $0.email) == normalizedEmail
        }) == false else {
            continue
        }
        deduplicatedAccounts.append(account)
    }
    deduplicatedAccounts.sort(by: sortAccounts)

    let resolvedActiveAccountKey: UUID? = {
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

private func canonicalRegistryOrder(
    lhs: ReviewSavedAccountRecord,
    rhs: ReviewSavedAccountRecord,
    activeAccountKey: UUID?,
    environment: [String: String]
) -> Bool {
    let lhsHasAuthSnapshot = FileManager.default.fileExists(
        atPath: ReviewHomePaths.savedAccountAuthURL(accountKey: lhs.accountKey, environment: environment).path
    )
    let rhsHasAuthSnapshot = FileManager.default.fileExists(
        atPath: ReviewHomePaths.savedAccountAuthURL(accountKey: rhs.accountKey, environment: environment).path
    )
    if lhsHasAuthSnapshot != rhsHasAuthSnapshot {
        return lhsHasAuthSnapshot && rhsHasAuthSnapshot == false
    }

    let lhsIsActive = lhs.accountKey == activeAccountKey
    let rhsIsActive = rhs.accountKey == activeAccountKey
    if lhsIsActive != rhsIsActive {
        return lhsIsActive && rhsIsActive == false
    }

    if sortAccounts(lhs: lhs, rhs: rhs) {
        return true
    }
    if sortAccounts(lhs: rhs, rhs: lhs) {
        return false
    }
    return lhs.accountKey.uuidString < rhs.accountKey.uuidString
}


private func sortAccounts(
    lhs: ReviewSavedAccountRecord,
    rhs: ReviewSavedAccountRecord
) -> Bool {
    switch (lhs.lastActivatedAt, rhs.lastActivatedAt) {
    case let (left?, right?):
        if left != right {
            return left > right
        }
    case (.some, .none):
        return true
    case (.none, .some):
        return false
    case (.none, .none):
        break
    }
    return lhs.email.localizedCaseInsensitiveCompare(rhs.email) == .orderedAscending
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
