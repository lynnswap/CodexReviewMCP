import Foundation
import ReviewDomain
import ReviewInfrastructure

package actor ReviewAccountRegistryStore {
    nonisolated(unsafe) static var saveRegistryRecordFailureMessageForTesting: String?
    nonisolated(unsafe) static var savedAccountDirectoryDeleteFailurePathComponentForTesting: String?
    private let coreDependencies: ReviewCoreDependencies
    private let environment: [String: String]

    package init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.coreDependencies = .live(environment: environment)
        self.environment = environment
    }

    package init(coreDependencies: ReviewCoreDependencies) {
        self.coreDependencies = coreDependencies
        self.environment = coreDependencies.environment
    }

    @MainActor
    package func loadAccounts() throws -> (activeAccountKey: String?, accounts: [CodexSavedAccountPayload]) {
        loadRegisteredReviewAccounts(dependencies: coreDependencies)
    }

    @MainActor
    @discardableResult
    package func saveSharedAuthAsSavedAccount(makeActive: Bool) throws -> CodexSavedAccountPayload? {
        guard let snapshot = loadAuthSnapshot(at: coreDependencies.paths.reviewAuthURL(), dependencies: coreDependencies) else {
            return nil
        }
        var registry = try loadRegistry()
        return try saveAuthSnapshot(
            in: &registry,
            sourceAuthURL: coreDependencies.paths.reviewAuthURL(),
            snapshot: snapshot,
            makeActive: makeActive,
            refreshSharedAuth: false
        )
    }

    @MainActor
    @discardableResult
    package func saveAuthSnapshot(
        sourceAuthURL: URL,
        makeActive: Bool,
        refreshSharedAuth: Bool = false
    ) throws -> CodexSavedAccountPayload {
        guard let snapshot = loadAuthSnapshot(at: sourceAuthURL, dependencies: coreDependencies) else {
            throw ReviewAuthError.authenticationRequired("Authenticated account is missing email.")
        }
        var registry = try loadRegistry()
        return try saveAuthSnapshot(
            in: &registry,
            sourceAuthURL: sourceAuthURL,
            snapshot: snapshot,
            makeActive: makeActive,
            refreshSharedAuth: refreshSharedAuth
        )
    }

    package func activateAccount(_ accountKey: String) throws {
        let originalRegistry = try loadRegistry()
        var registry = originalRegistry
        guard let record = storedAccount(
            in: registry,
            matchingRuntimeAccountKey: accountKey,
            dependencies: coreDependencies
        ) else {
            throw ReviewAuthError.authenticationRequired("Saved account was not found.")
        }
        registry.activeAccountKey = record.accountKey
        registry.accounts = registry.accounts.map { account in
            var updated = account
            if account.accountKey == record.accountKey {
                updated.lastActivatedAt = coreDependencies.dateNow()
            }
            return updated
        }
        try saveRegistry(registry)
        let sharedAuthBackup = loadSharedAuthData()
        do {
            try persistAuthSnapshot(
                from: persistedSavedAccountAuthURL(
                    accountKey: record.accountKey,
                    dependencies: coreDependencies
                ),
                to: coreDependencies.paths.reviewAuthURL(),
                dependencies: coreDependencies
            )
        } catch {
            rollbackRegistryMutation(
                originalRegistry: originalRegistry,
                sharedAuthBackup: sharedAuthBackup,
                dependencies: coreDependencies
            )
            throw error
        }
    }

    package func restoreSharedAuthFromSavedAccount(_ accountKey: String) throws {
        let registry = try loadRegistry()
        guard let record = storedAccount(
            in: registry,
            matchingRuntimeAccountKey: accountKey,
            dependencies: coreDependencies
        ) else {
            throw ReviewAuthError.authenticationRequired("Saved account was not found.")
        }
        try persistAuthSnapshot(
            from: persistedSavedAccountAuthURL(
                accountKey: record.accountKey,
                dependencies: coreDependencies
            ),
            to: coreDependencies.paths.reviewAuthURL(),
            dependencies: coreDependencies
        )
    }

    package func clearActiveAccount(accountKey: String? = nil) throws {
        let originalRegistry = try loadRegistry()
        var registry = originalRegistry
        let resolvedStoredAccount: ReviewSavedAccountRecord?
        if let accountKey {
            resolvedStoredAccount = storedAccount(
                in: registry,
                matchingRuntimeAccountKey: accountKey,
                dependencies: coreDependencies
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
        let savedAccountDirectoryBackups = savedAccountDirectoryBackups(
            for: resolvedStoredAccount.map {
                savedAccountDirectories(
                    matchingNormalizedEmail: normalizedReviewAccountEmail(email: $0.email),
                    fallbackAccountKey: $0.accountKey,
                    dependencies: coreDependencies
                )
            } ?? [],
            dependencies: coreDependencies
        )
        do {
            try removeItemIfExists(at: coreDependencies.paths.reviewAuthURL())
            if let resolvedStoredAccount {
                for directoryURL in savedAccountDirectories(
                    matchingNormalizedEmail: normalizedReviewAccountEmail(email: resolvedStoredAccount.email),
                    fallbackAccountKey: resolvedStoredAccount.accountKey,
                    dependencies: coreDependencies
                ) {
                    try removeSavedAccountDirectory(directoryURL, dependencies: coreDependencies)
                }
            }
        } catch {
            rollbackRegistryMutation(
                originalRegistry: originalRegistry,
                sharedAuthBackup: sharedAuthBackup,
                dependencies: coreDependencies,
                savedAccountDirectoryBackups: savedAccountDirectoryBackups
            )
            throw error
        }
    }

    package func invalidateSavedAccountAuth(_ accountKey: String) throws {
        let registry = try loadRegistry()
        guard let storedAccount = storedAccount(
            in: registry,
            matchingRuntimeAccountKey: accountKey,
            dependencies: coreDependencies
        ) else {
            return
        }
        for directoryURL in savedAccountDirectories(
            matchingNormalizedEmail: normalizedReviewAccountEmail(email: storedAccount.email),
            fallbackAccountKey: storedAccount.accountKey,
            dependencies: coreDependencies
        ) {
            try removeSavedAccountDirectory(directoryURL, dependencies: coreDependencies)
        }
    }

    @discardableResult
    package func removeAccount(_ accountKey: String) throws -> String? {
        let originalRegistry = try loadRegistry()
        var registry = originalRegistry
        let resolvedStoredAccount = storedAccount(
            in: originalRegistry,
            matchingRuntimeAccountKey: accountKey,
            dependencies: coreDependencies
        )
        let removedAccountKey = resolvedStoredAccount?.accountKey
        let removedActive = removedAccountKey != nil
            && originalRegistry.activeAccountKey == removedAccountKey
        registry.accounts.removeAll { account in
            account.accountKey == removedAccountKey
        }
        if removedActive,
               let replacementIndex = registry.accounts.firstIndex(where: { account in
               savedAccountAuthSnapshotExists(
                   accountKey: account.accountKey,
                   dependencies: coreDependencies
               )
           })
        {
            var replacementAccount = registry.accounts[replacementIndex]
            replacementAccount.lastActivatedAt = coreDependencies.dateNow()
            registry.accounts[replacementIndex] = replacementAccount
            registry.activeAccountKey = replacementAccount.accountKey
        } else if removedActive {
            registry.activeAccountKey = nil
        }

        try saveRegistry(registry)
        let sharedAuthBackup = loadSharedAuthData()
        let savedAccountDirectoryBackups = savedAccountDirectoryBackups(
            for: resolvedStoredAccount.map {
                savedAccountDirectories(
                    matchingNormalizedEmail: normalizedReviewAccountEmail(email: $0.email),
                    fallbackAccountKey: $0.accountKey,
                    dependencies: coreDependencies
                )
            } ?? [],
            dependencies: coreDependencies
        )
        do {
            if removedActive {
                if let replacementAccountKey = registry.activeAccountKey {
                    try persistAuthSnapshot(
                        from: persistedSavedAccountAuthURL(
                            accountKey: replacementAccountKey,
                            dependencies: coreDependencies
                        ),
                        to: coreDependencies.paths.reviewAuthURL(),
                        dependencies: coreDependencies
                    )
                } else {
                    try removeItemIfExists(at: coreDependencies.paths.reviewAuthURL())
                }
            }
            if let resolvedStoredAccount {
                for directoryURL in savedAccountDirectories(
                    matchingNormalizedEmail: normalizedReviewAccountEmail(email: resolvedStoredAccount.email),
                    fallbackAccountKey: resolvedStoredAccount.accountKey,
                    dependencies: coreDependencies
                ) {
                    try removeSavedAccountDirectory(directoryURL, dependencies: coreDependencies)
                }
            }
        } catch {
            rollbackRegistryMutation(
                originalRegistry: originalRegistry,
                sharedAuthBackup: sharedAuthBackup,
                dependencies: coreDependencies,
                savedAccountDirectoryBackups: savedAccountDirectoryBackups
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
                dependencies: coreDependencies
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
                dependencies: coreDependencies
              )
        else {
            return
        }

        let record = registry.accounts.remove(at: sourceIndex)
        let visibleAccountsAfterRemoval = registry.accounts.filter { account in
            savedAccountAuthSnapshotExists(
                accountKey: account.accountKey,
                dependencies: coreDependencies
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
            dependencies: coreDependencies
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
            dependencies: coreDependencies
        ) else {
            return
        }
        registry.accounts[index].lastRateLimitFetchAt = fetchedAt
        registry.accounts[index].lastRateLimitError = error?.nilIfEmpty
        try saveRegistry(registry)
    }

    @MainActor
    package func updateCachedRateLimits(from account: CodexAccount) throws {
        var registry = try loadRegistry()
        guard let index = storedAccountIndex(
            in: registry,
            matchingRuntimeAccountKey: account.accountKey,
            dependencies: coreDependencies
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
        registry.accounts[index].lastRateLimitFetchAt = coreDependencies.dateNow()
        registry.accounts[index].lastRateLimitError = account.lastRateLimitError?.nilIfEmpty
        try saveRegistry(registry)
    }

    @MainActor
    package func updateSavedAccountMetadata(from account: CodexAccount) throws {
        var registry = try loadRegistry()
        if let index = storedAccountIndex(
            in: registry,
            matchingRuntimeAccountKey: account.accountKey,
            dependencies: coreDependencies
        ) {
            registry.accounts[index].email = account.email
            registry.accounts[index].planType = account.planType
            try saveRegistry(registry)
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
        try? coreDependencies.fileSystem.removeItem(probe.homeRootURL)
    }

    private func makePreparedProbeRoot(
        copySharedAuthFromAccountKey accountKey: String?,
        copySharedAuthFromSharedHome: Bool = false
    ) throws -> URL {
        let probeRoot = coreDependencies.paths.makeProbeRootURL()
            .appendingPathComponent(coreDependencies.uuid().uuidString, isDirectory: true)
        do {
            let probeEnvironment = makeProbeEnvironment(homeRootURL: probeRoot)
            let probeDependencies = ReviewCoreDependencies(
                environment: probeEnvironment,
                fileSystem: coreDependencies.fileSystem,
                process: coreDependencies.process,
                dateNow: coreDependencies.dateNow,
                uuid: coreDependencies.uuid,
                clock: coreDependencies.clock
            )
            let probeReviewHome = probeDependencies.paths.reviewHomeURL()
            try ensureReviewHomeScaffold(at: probeReviewHome, dependencies: probeDependencies)
            try copySharedConfigurationIfPresent(into: probeReviewHome)
            if let accountKey {
                let registry = try loadRegistry()
                guard let storedAccount = storedAccount(
                    in: registry,
                    matchingRuntimeAccountKey: accountKey,
                    dependencies: coreDependencies
                ) else {
                    throw ReviewAuthError.authenticationRequired("Saved account was not found.")
                }
                try persistAuthSnapshot(
                    from: persistedSavedAccountAuthURL(
                        accountKey: storedAccount.accountKey,
                        dependencies: coreDependencies
                    ),
                    to: probeDependencies.paths.reviewAuthURL(),
                    dependencies: coreDependencies
                )
            } else if copySharedAuthFromSharedHome {
                try persistAuthSnapshot(
                    from: coreDependencies.paths.reviewAuthURL(),
                    to: probeDependencies.paths.reviewAuthURL(),
                    dependencies: coreDependencies
                )
            }
            return probeRoot
        } catch {
            try? coreDependencies.fileSystem.removeItem(probeRoot)
            throw error
        }
    }

    nonisolated private func loadRegistry() throws -> ReviewAccountRegistryRecord {
        try loadRegistryRecord(dependencies: coreDependencies)
    }

    nonisolated private func saveRegistry(_ registry: ReviewAccountRegistryRecord) throws {
        try saveRegistryRecord(registry, dependencies: coreDependencies)
    }

    private func makeProbeEnvironment(homeRootURL: URL) -> [String: String] {
        var environment = environment
        environment["HOME"] = homeRootURL.path
        environment.removeValue(forKey: "CODEX_HOME")
        return environment
    }

    private func copySharedConfigurationIfPresent(into probeReviewHome: URL) throws {
        let sharedConfigURL = coreDependencies.paths.reviewConfigURL()
        let sharedAgentsURL = coreDependencies.paths.reviewAgentsURL()
        let targetConfigURL = probeReviewHome.appendingPathComponent("config.toml")
        let targetAgentsURL = probeReviewHome.appendingPathComponent("AGENTS.md")
        if coreDependencies.fileSystem.fileExists(sharedConfigURL.path) {
            try? coreDependencies.fileSystem.removeItem(targetConfigURL)
            try coreDependencies.fileSystem.copyItem(sharedConfigURL, targetConfigURL)
        }
        if coreDependencies.fileSystem.fileExists(sharedAgentsURL.path) {
            try? coreDependencies.fileSystem.removeItem(targetAgentsURL)
            try coreDependencies.fileSystem.copyItem(sharedAgentsURL, targetAgentsURL)
        }
    }

    @MainActor
    private func saveAuthSnapshot(
        in registry: inout ReviewAccountRegistryRecord,
        sourceAuthURL: URL,
        snapshot: ReviewStoredAuthSnapshot,
        makeActive: Bool,
        refreshSharedAuth: Bool
    ) throws -> CodexSavedAccountPayload {
        let originalRegistry = registry
        let record = upsertSavedAccountRecord(
            in: &registry,
            email: snapshot.email,
            planType: snapshot.planType,
            makeActive: makeActive
        )
        let sharedAuthURL = coreDependencies.paths.reviewAuthURL()
        let savedAuthURL = coreDependencies.paths.savedAccountAuthURL(accountKey: record.accountKey)
        let sharedAuthBackup = loadAuthData(at: sharedAuthURL, dependencies: coreDependencies)
        let savedAuthBackup = loadAuthData(at: savedAuthURL, dependencies: coreDependencies)

        do {
            try persistAuthSnapshot(
                from: sourceAuthURL,
                to: savedAuthURL,
                dependencies: coreDependencies
            )
            if makeActive || refreshSharedAuth {
                try persistAuthSnapshot(
                    from: sourceAuthURL,
                    to: sharedAuthURL,
                    dependencies: coreDependencies
                )
            }
            try saveRegistry(registry)
        } catch {
            rollbackRegistryMutation(
                originalRegistry: originalRegistry,
                sharedAuthBackup: sharedAuthBackup,
                dependencies: coreDependencies,
                savedAuthURL: savedAuthURL,
                savedAuthBackup: savedAuthBackup
            )
            throw error
        }
        return makeSavedAccountPayload(record)
    }

    private func loadSharedAuthData() -> Data? {
        loadAuthData(at: coreDependencies.paths.reviewAuthURL(), dependencies: coreDependencies)
    }

    private func removeItemIfExists(at url: URL) throws {
        if coreDependencies.fileSystem.fileExists(url.path) {
            try coreDependencies.fileSystem.removeItem(url)
        }
    }
}

func loadRegistryRecord(
    environment: [String: String]
) throws -> ReviewAccountRegistryRecord {
    try loadRegistryRecord(dependencies: .live(environment: environment))
}

func loadRegistryRecord(
    dependencies: ReviewCoreDependencies
) throws -> ReviewAccountRegistryRecord {
    try migrateLegacySharedAuthIfNeeded(dependencies: dependencies)
    let registryURL = dependencies.paths.accountsRegistryURL()
    guard let data = try? dependencies.fileSystem.readData(registryURL) else {
        return .init()
    }
    guard let decoded = try? JSONDecoder().decode(ReviewAccountRegistryRecord.self, from: data)
    else {
        return .init()
    }
    return migrateRegistryRecordIfNeeded(decoded, dependencies: dependencies)
}

private func saveRegistryRecord(
    _ registry: ReviewAccountRegistryRecord,
    environment: [String: String]
) throws {
    try saveRegistryRecord(registry, dependencies: .live(environment: environment))
}

private func saveRegistryRecord(
    _ registry: ReviewAccountRegistryRecord,
    dependencies: ReviewCoreDependencies
) throws {
    if let failureMessage = ReviewAccountRegistryStore.saveRegistryRecordFailureMessageForTesting {
        throw NSError(
            domain: "ReviewAccountRegistryStore.saveRegistryRecordFailureForTesting",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: failureMessage]
        )
    }
    let registryURL = dependencies.paths.accountsRegistryURL()
    try dependencies.fileSystem.createDirectory(registryURL.deletingLastPathComponent(), true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try dependencies.fileSystem.writeData(encoder.encode(registry), registryURL, [.atomic])
}

private func loadAuthData(at url: URL) -> Data? {
    loadAuthData(at: url, dependencies: .live())
}

private func loadAuthData(at url: URL, dependencies: ReviewCoreDependencies) -> Data? {
    try? dependencies.fileSystem.readData(url)
}

private func rollbackRegistryMutation(
    originalRegistry: ReviewAccountRegistryRecord,
    sharedAuthBackup: Data?,
    environment: [String: String],
    savedAuthURL: URL? = nil,
    savedAuthBackup: Data? = nil,
    savedAccountDirectoryBackups: [SavedAccountDirectoryBackup] = []
) {
    rollbackRegistryMutation(
        originalRegistry: originalRegistry,
        sharedAuthBackup: sharedAuthBackup,
        dependencies: .live(environment: environment),
        savedAuthURL: savedAuthURL,
        savedAuthBackup: savedAuthBackup,
        savedAccountDirectoryBackups: savedAccountDirectoryBackups
    )
}

private func rollbackRegistryMutation(
    originalRegistry: ReviewAccountRegistryRecord,
    sharedAuthBackup: Data?,
    dependencies: ReviewCoreDependencies,
    savedAuthURL: URL? = nil,
    savedAuthBackup: Data? = nil,
    savedAccountDirectoryBackups: [SavedAccountDirectoryBackup] = []
) {
    try? saveRegistryRecord(originalRegistry, dependencies: dependencies)
    try? restoreAuthData(
        from: sharedAuthBackup,
        to: dependencies.paths.reviewAuthURL(),
        dependencies: dependencies
    )
    if let savedAuthURL {
        try? restoreAuthData(from: savedAuthBackup, to: savedAuthURL, dependencies: dependencies)
    }
    for backup in savedAccountDirectoryBackups {
        try? restoreAuthData(
            from: backup.authData,
            to: backup.directoryURL.appendingPathComponent("auth.json"),
            dependencies: dependencies
        )
    }
}

private func restoreAuthData(from backup: Data?, to url: URL) throws {
    try restoreAuthData(from: backup, to: url, dependencies: .live())
}

private func restoreAuthData(
    from backup: Data?,
    to url: URL,
    dependencies: ReviewCoreDependencies
) throws {
    if let backup {
        try dependencies.fileSystem.createDirectory(url.deletingLastPathComponent(), true)
        try dependencies.fileSystem.writeData(backup, url, [.atomic])
        return
    }
    if dependencies.fileSystem.fileExists(url.path) {
        try dependencies.fileSystem.removeItem(url)
    }
}

private func ensureReviewHomeScaffold(
    at homeURL: URL,
    dependencies: ReviewCoreDependencies
) throws {
    try dependencies.fileSystem.createDirectory(homeURL, true)
    try createEmptyFileIfMissing(
        at: homeURL.appendingPathComponent("config.toml"),
        dependencies: dependencies
    )
    try createEmptyFileIfMissing(
        at: homeURL.appendingPathComponent("AGENTS.md"),
        dependencies: dependencies
    )
}

private func createEmptyFileIfMissing(
    at url: URL,
    dependencies: ReviewCoreDependencies
) throws {
    guard dependencies.fileSystem.fileExists(url.path) == false else {
        return
    }
    try dependencies.fileSystem.writeData(Data(), url, [])
}

private func removeSavedAccountDirectory(_ directoryURL: URL) throws {
    try removeSavedAccountDirectory(directoryURL, dependencies: .live())
}

private func removeSavedAccountDirectory(
    _ directoryURL: URL,
    dependencies: ReviewCoreDependencies
) throws {
    if let failingPathComponent = ReviewAccountRegistryStore.savedAccountDirectoryDeleteFailurePathComponentForTesting,
       directoryURL.lastPathComponent == failingPathComponent
    {
        throw NSError(
            domain: "ReviewAccountRegistryStore.removeSavedAccountDirectoryFailureForTesting",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Directory delete failed."]
        )
    }
    try dependencies.fileSystem.removeItem(directoryURL)
}

private struct SavedAccountDirectoryBackup {
    var directoryURL: URL
    var authData: Data?
}

private func savedAccountDirectoryBackups(for directoryURLs: [URL]) -> [SavedAccountDirectoryBackup] {
    savedAccountDirectoryBackups(for: directoryURLs, dependencies: .live())
}

private func savedAccountDirectoryBackups(
    for directoryURLs: [URL],
    dependencies: ReviewCoreDependencies
) -> [SavedAccountDirectoryBackup] {
    directoryURLs.map { directoryURL in
        SavedAccountDirectoryBackup(
            directoryURL: directoryURL,
            authData: loadAuthData(
                at: directoryURL.appendingPathComponent("auth.json"),
                dependencies: dependencies
            )
        )
    }
}

private func migrateLegacySharedAuthIfNeeded(
    environment: [String: String]
) throws {
    try migrateLegacySharedAuthIfNeeded(dependencies: .live(environment: environment))
}

private func migrateLegacySharedAuthIfNeeded(
    dependencies: ReviewCoreDependencies
) throws {
    let registryURL = dependencies.paths.accountsRegistryURL()
    guard dependencies.fileSystem.fileExists(registryURL.path) == false else {
        return
    }
    let sharedAuthURL = dependencies.paths.reviewAuthURL()
    guard let snapshot = loadAuthSnapshot(at: sharedAuthURL, dependencies: dependencies) else {
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
        from: sharedAuthURL,
        to: dependencies.paths.savedAccountAuthURL(accountKey: record.accountKey),
        dependencies: dependencies
    )
    try saveRegistryRecord(registry, dependencies: dependencies)
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
    try persistAuthSnapshot(from: sourceURL, to: destinationURL, dependencies: .live())
}

private func persistAuthSnapshot(
    from sourceURL: URL,
    to destinationURL: URL,
    dependencies: ReviewCoreDependencies
) throws {
    try dependencies.fileSystem.createDirectory(destinationURL.deletingLastPathComponent(), true)
    let data = try dependencies.fileSystem.readData(sourceURL)
    try dependencies.fileSystem.writeData(data, destinationURL, [.atomic])
}

func canonicalizeRegistryRecord(
    _ registry: ReviewAccountRegistryRecord,
    environment: [String: String]
) -> ReviewAccountRegistryRecord {
    canonicalizeRegistryRecord(
        registry,
        dependencies: .live(environment: environment)
    )
}

func canonicalizeRegistryRecord(
    _ registry: ReviewAccountRegistryRecord,
    dependencies: ReviewCoreDependencies
) -> ReviewAccountRegistryRecord {
    let canonicalAccountsByEmail = canonicalAccountsByNormalizedEmail(
        in: registry,
        dependencies: dependencies
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
    shouldReplaceCanonicalAccount(
        current,
        with: candidate,
        activeAccountKey: activeAccountKey,
        dependencies: .live(environment: environment)
    )
}

private func shouldReplaceCanonicalAccount(
    _ current: ReviewSavedAccountRecord,
    with candidate: ReviewSavedAccountRecord,
    activeAccountKey: String?,
    dependencies: ReviewCoreDependencies
) -> Bool {
    let currentHasAuthSnapshot = savedAccountAuthSnapshotExists(
        accountKey: current.accountKey,
        dependencies: dependencies
    )
    let candidateHasAuthSnapshot = savedAccountAuthSnapshotExists(
        accountKey: candidate.accountKey,
        dependencies: dependencies
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

func canonicalAccountsByNormalizedEmail(
    in registry: ReviewAccountRegistryRecord,
    environment: [String: String]
) -> [String: ReviewSavedAccountRecord] {
    canonicalAccountsByNormalizedEmail(
        in: registry,
        dependencies: .live(environment: environment)
    )
}

func canonicalAccountsByNormalizedEmail(
    in registry: ReviewAccountRegistryRecord,
    dependencies: ReviewCoreDependencies
) -> [String: ReviewSavedAccountRecord] {
    var canonicalAccountsByEmail: [String: ReviewSavedAccountRecord] = [:]
    for account in registry.accounts {
        let normalizedEmail = normalizedReviewAccountEmail(email: account.email)
        if let existingAccount = canonicalAccountsByEmail[normalizedEmail] {
            if shouldReplaceCanonicalAccount(
                existingAccount,
                with: account,
                activeAccountKey: registry.activeAccountKey,
                dependencies: dependencies
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
    migrateRegistryRecordIfNeeded(
        registry,
        dependencies: .live(environment: environment)
    )
}

private func migrateRegistryRecordIfNeeded(
    _ registry: ReviewAccountRegistryRecord,
    dependencies: ReviewCoreDependencies
) -> ReviewAccountRegistryRecord {
    if registryUsesEmailKeys(registry) {
        let canonicalRegistry = canonicalizeRegistryRecord(
            registry,
            dependencies: dependencies
        )
        if canonicalRegistry != registry {
            try? saveRegistryRecord(canonicalRegistry, dependencies: dependencies)
        }
        return canonicalRegistry
    }

    let canonicalOriginalAccountsByEmail = canonicalAccountsByNormalizedEmail(
        in: registry,
        dependencies: dependencies
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
        dependencies: dependencies
    )

    guard migrateSavedAccountDirectories(
        fromCanonicalAccountsByEmail: canonicalOriginalAccountsByEmail,
        to: migratedRegistry,
        dependencies: dependencies
    ) else {
        return registry
    }

    if registry != migratedRegistry {
        try? saveRegistryRecord(migratedRegistry, dependencies: dependencies)
    }

    return migratedRegistry
}

private func migrateSavedAccountDirectories(
    fromCanonicalAccountsByEmail canonicalOriginalAccountsByEmail: [String: ReviewSavedAccountRecord],
    to migratedRegistry: ReviewAccountRegistryRecord,
    environment: [String: String]
) -> Bool {
    migrateSavedAccountDirectories(
        fromCanonicalAccountsByEmail: canonicalOriginalAccountsByEmail,
        to: migratedRegistry,
        dependencies: .live(environment: environment)
    )
}

private func migrateSavedAccountDirectories(
    fromCanonicalAccountsByEmail canonicalOriginalAccountsByEmail: [String: ReviewSavedAccountRecord],
    to migratedRegistry: ReviewAccountRegistryRecord,
    dependencies: ReviewCoreDependencies
) -> Bool {
    for migratedAccount in migratedRegistry.accounts {
        let destinationAuthURL = dependencies.paths.savedAccountAuthURL(accountKey: migratedAccount.accountKey)
        let destinationURL = dependencies.paths.savedAccountDirectoryURL(accountKey: migratedAccount.accountKey)

        var candidateURLs: [URL] = []
        if let originalAccount = canonicalOriginalAccountsByEmail[migratedAccount.accountKey] {
            candidateURLs.append(contentsOf: savedAccountDirectoryCandidateURLs(
                accountKey: originalAccount.accountKey,
                dependencies: dependencies
            ))
        }
        candidateURLs.append(contentsOf: savedAccountDirectoryCandidateURLs(
            accountKey: migratedAccount.accountKey,
            dependencies: dependencies
        ))
        candidateURLs = candidateURLs.uniqued()
        let sourceURLs = candidateURLs.filter { $0 != destinationURL }
        let canonicalSourceURL = sourceURLs.first {
            directoryContainsSavedAccountAuthSnapshot($0, dependencies: dependencies)
        }
        let hasSourceSnapshot = sourceURLs.contains {
            directoryContainsSavedAccountAuthSnapshot($0, dependencies: dependencies)
        }

        if dependencies.fileSystem.fileExists(destinationAuthURL.path) {
            guard let canonicalSourceURL else {
                continue
            }
            let sourceAuthURL = canonicalSourceURL.appendingPathComponent("auth.json")
            let destinationAuthData = try? dependencies.fileSystem.readData(destinationAuthURL)
            let sourceAuthData = try? dependencies.fileSystem.readData(sourceAuthURL)
            if destinationAuthData == sourceAuthData {
                continue
            }
            let destinationModificationDate = dependencies.fileSystem.contentModificationDate(destinationAuthURL)
                ?? .distantPast
            let sourceModificationDate = dependencies.fileSystem.contentModificationDate(sourceAuthURL)
                ?? .distantPast
            if destinationModificationDate >= sourceModificationDate {
                continue
            }
            do {
                try dependencies.fileSystem.removeItem(destinationURL)
                try dependencies.fileSystem.copyItem(canonicalSourceURL, destinationURL)
                continue
            } catch {
                return false
            }
        }

        if dependencies.fileSystem.fileExists(destinationURL.path) {
            if hasSourceSnapshot {
                return false
            }
            continue
        }

        if let canonicalSourceURL {
            do {
                try dependencies.fileSystem.createDirectory(destinationURL.deletingLastPathComponent(), true)
                try dependencies.fileSystem.copyItem(canonicalSourceURL, destinationURL)
            } catch {
                return false
            }
        }

        if dependencies.fileSystem.fileExists(destinationAuthURL.path) == false,
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
    savedAccountDirectoryCandidateURLs(
        accountKey: accountKey,
        dependencies: .live(environment: environment)
    )
}

private func savedAccountDirectoryCandidateURLs(
    accountKey: String,
    dependencies: ReviewCoreDependencies
) -> [URL] {
    [
        dependencies.paths.savedAccountDirectoryURL(accountKey: accountKey),
        dependencies.paths.legacySavedAccountDirectoryURL(accountKey: accountKey),
    ].uniqued()
}

func savedAccountAuthSnapshotExists(
    accountKey: String,
    environment: [String: String]
) -> Bool {
    savedAccountAuthSnapshotExists(
        accountKey: accountKey,
        dependencies: .live(environment: environment)
    )
}

func savedAccountAuthSnapshotExists(
    accountKey: String,
    dependencies: ReviewCoreDependencies
) -> Bool {
    savedAccountDirectoryCandidateURLs(
        accountKey: accountKey,
        dependencies: dependencies
    )
    .contains {
        directoryContainsSavedAccountAuthSnapshot($0, dependencies: dependencies)
    }
}

private func directoryContainsSavedAccountAuthSnapshot(_ directoryURL: URL) -> Bool {
    directoryContainsSavedAccountAuthSnapshot(directoryURL, dependencies: .live())
}

private func directoryContainsSavedAccountAuthSnapshot(
    _ directoryURL: URL,
    dependencies: ReviewCoreDependencies
) -> Bool {
    dependencies.fileSystem.fileExists(directoryURL.appendingPathComponent("auth.json").path)
}

private func persistedSavedAccountAuthURL(
    accountKey: String,
    environment: [String: String]
) -> URL {
    persistedSavedAccountAuthURL(
        accountKey: accountKey,
        dependencies: .live(environment: environment)
    )
}

private func persistedSavedAccountAuthURL(
    accountKey: String,
    dependencies: ReviewCoreDependencies
) -> URL {
    savedAccountDirectoryCandidateURLs(
        accountKey: accountKey,
        dependencies: dependencies
    )
    .first {
        directoryContainsSavedAccountAuthSnapshot($0, dependencies: dependencies)
    }?
    .appendingPathComponent("auth.json")
    ?? dependencies.paths.savedAccountAuthURL(accountKey: accountKey)
}

private func savedAccountDirectories(
    matchingNormalizedEmail normalizedEmail: String,
    fallbackAccountKey: String? = nil,
    environment: [String: String]
) -> [URL] {
    savedAccountDirectories(
        matchingNormalizedEmail: normalizedEmail,
        fallbackAccountKey: fallbackAccountKey,
        dependencies: .live(environment: environment)
    )
}

private func savedAccountDirectories(
    matchingNormalizedEmail normalizedEmail: String,
    fallbackAccountKey: String? = nil,
    dependencies: ReviewCoreDependencies
) -> [URL] {
    let accountsDirectoryURL = dependencies.paths.accountsDirectoryURL()
    let directoryURLs = (try? dependencies.fileSystem.contentsOfDirectory(accountsDirectoryURL, true)) ?? []
    let candidatePathComponents: Set<String> = {
        var components: Set<String> = [
            dependencies.paths.savedAccountDirectoryURL(accountKey: normalizedEmail).lastPathComponent,
            dependencies.paths.legacySavedAccountDirectoryURL(accountKey: normalizedEmail).lastPathComponent,
        ]
        if let fallbackAccountKey {
            components.insert(
                dependencies.paths.savedAccountDirectoryURL(accountKey: fallbackAccountKey).lastPathComponent
            )
            components.insert(
                dependencies.paths.legacySavedAccountDirectoryURL(accountKey: fallbackAccountKey).lastPathComponent
            )
        }
        return components
    }()

    var resolvedDirectories = directoryURLs.filter { candidatePathComponents.contains($0.lastPathComponent) }
    resolvedDirectories.append(contentsOf: directoryURLs.filter { directoryURL in
        guard directoryContainsSavedAccountAuthSnapshot(directoryURL, dependencies: dependencies),
              let snapshot = loadAuthSnapshot(
                at: directoryURL.appendingPathComponent("auth.json"),
                dependencies: dependencies
              )
        else {
            return false
        }
        return normalizedReviewAccountEmail(email: snapshot.email) == normalizedEmail
    })
    var seenPaths: Set<String> = []
    return resolvedDirectories.filter { directoryURL in
        guard dependencies.fileSystem.fileExists(directoryURL.path) else {
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

struct ReviewStoredAuthSnapshot: Equatable, Sendable {
    var email: String
    var planType: String?
}

func loadAuthSnapshot(at authURL: URL) -> ReviewStoredAuthSnapshot? {
    loadAuthSnapshot(at: authURL, dependencies: .live())
}

func loadAuthSnapshot(at authURL: URL, dependencies: ReviewCoreDependencies) -> ReviewStoredAuthSnapshot? {
    guard let data = try? dependencies.fileSystem.readData(authURL),
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
