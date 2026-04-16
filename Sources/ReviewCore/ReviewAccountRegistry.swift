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
    let registry = (try? loadRegistryRecord(environment: environment)) ?? .init()
    let accounts = registry.accounts.map { makeCodexAccount($0) }
    if let activeAccountKey = registry.activeAccountKey {
        for account in accounts {
            account.updateIsActive(account.accountKey == activeAccountKey)
        }
    }
    return (registry.activeAccountKey, accounts)
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
        var registry = try loadRegistry()
        guard let record = registry.accounts.first(where: { $0.accountKey == accountKey }) else {
            throw ReviewAuthError.authenticationRequired("Saved account was not found.")
        }
        try persistAuthSnapshot(
            from: ReviewHomePaths.savedAccountAuthURL(accountKey: accountKey, environment: environment),
            to: ReviewHomePaths.reviewAuthURL(environment: environment)
        )
        registry.activeAccountKey = record.accountKey
        registry.accounts = registry.accounts.map { account in
            var updated = account
            if account.accountKey == accountKey {
                updated.lastActivatedAt = Date()
            }
            return updated
        }.sorted(by: sortAccounts)
        try saveRegistry(registry)
    }

    package func clearActiveAccount(accountKey: String? = nil) throws {
        var registry = try loadRegistry()
        registry.activeAccountKey = nil
        try? FileManager.default.removeItem(at: ReviewHomePaths.reviewAuthURL(environment: environment))
        if let accountKey {
            try? FileManager.default.removeItem(
                at: ReviewHomePaths.savedAccountAuthURL(
                    accountKey: accountKey,
                    environment: environment
                )
            )
        }
        try saveRegistry(registry)
    }

    package func removeAccount(_ accountKey: String) throws -> String? {
        var registry = try loadRegistry()
        registry.accounts.removeAll { $0.accountKey == accountKey }
        let savedAccountDirectoryURL = ReviewHomePaths.savedAccountDirectoryURL(
            accountKey: accountKey,
            environment: environment
        )
        if FileManager.default.fileExists(atPath: savedAccountDirectoryURL.path) {
            try FileManager.default.removeItem(at: savedAccountDirectoryURL)
        }

        if registry.activeAccountKey == accountKey {
            registry.activeAccountKey = registry.accounts.first?.accountKey
            if let replacementKey = registry.activeAccountKey {
                try persistAuthSnapshot(
                    from: ReviewHomePaths.savedAccountAuthURL(accountKey: replacementKey, environment: environment),
                    to: ReviewHomePaths.reviewAuthURL(environment: environment)
                )
            } else {
                try? FileManager.default.removeItem(at: ReviewHomePaths.reviewAuthURL(environment: environment))
            }
        }

        try saveRegistry(registry)
        return registry.activeAccountKey
    }

    package func updateCachedRateLimits(
        accountKey: String,
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
        accountKey: String,
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

    package func cleanupProbeHome(_ probe: PreparedInactiveAccountProbe) {
        try? FileManager.default.removeItem(at: probe.homeRootURL)
    }

    private func makePreparedProbeRoot(
        copySharedAuthFromAccountKey accountKey: String?
    ) throws -> URL {
        let probeRoot = ReviewHomePaths.makeProbeRootURL(environment: environment)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let probeEnvironment = makeProbeEnvironment(homeRootURL: probeRoot)
        let probeReviewHome = ReviewHomePaths.reviewHomeURL(environment: probeEnvironment)
        try ReviewHomePaths.ensureReviewHomeScaffold(at: probeReviewHome)
        try copySharedConfigurationIfPresent(into: probeReviewHome)
        if let accountKey {
            try persistAuthSnapshot(
                from: ReviewHomePaths.savedAccountAuthURL(accountKey: accountKey, environment: environment),
                to: ReviewHomePaths.reviewAuthURL(environment: probeEnvironment)
            )
        }
        return probeRoot
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
}

private func loadRegistryRecord(
    environment: [String: String]
) throws -> ReviewAccountRegistryRecord {
    try migrateLegacySharedAuthIfNeeded(environment: environment)
    let registryURL = ReviewHomePaths.accountsRegistryURL(environment: environment)
    guard let data = try? Data(contentsOf: registryURL) else {
        return .init()
    }
    return try JSONDecoder().decode(ReviewAccountRegistryRecord.self, from: data)
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
    let accountKey = normalizedReviewAccountKey(email: email)
    let now = Date()
    let record: ReviewSavedAccountRecord
    if let index = registry.accounts.firstIndex(where: { $0.accountKey == accountKey }) {
        var updated = registry.accounts[index]
        updated.email = email
        updated.planType = planType
        if makeActive {
            updated.lastActivatedAt = now
        }
        registry.accounts[index] = updated
        record = updated
    } else {
        let inserted = ReviewSavedAccountRecord(
            accountKey: accountKey,
            email: email,
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
        registry.activeAccountKey = accountKey
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
