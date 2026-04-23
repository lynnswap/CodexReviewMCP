import AppKit
import AuthenticationServices
import Foundation
import Observation
import Testing
import ReviewTestSupport
import ReviewDomain
@testable import ReviewInfra
@_spi(Testing) @testable import ReviewApp
@testable import ReviewRuntime

@Suite(.serialized)
@MainActor
struct CodexReviewMCPTests {
    @Test func storeSkipsRegistryAccountsWithoutSavedAuthSnapshots() async throws {
        let environment = try isolatedHomeEnvironment()
        let registryURL = ReviewHomePaths.accountsRegistryURL(environment: environment)
        try FileManager.default.createDirectory(
            at: registryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let registry = ReviewAccountRegistryRecord(
            activeAccountKey: nil,
            accounts: [
                .init(
                    accountKey: "saved@example.com",
                    email: "saved@example.com",
                    planType: "pro",
                    lastActivatedAt: nil,
                    lastRateLimitFetchAt: nil,
                    lastRateLimitError: nil,
                    cachedRateLimits: []
                )
            ]
        )
        let registryData = try JSONEncoder().encode(registry)
        try registryData.write(to: registryURL, options: Data.WritingOptions.atomic)

        let store = makeTestStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: MockAppServerManager { _ in .success() }
        )

        #expect(store.auth.account == nil)
        #expect(store.auth.savedAccounts.isEmpty)
    }

    @Test func storePrefersSharedAuthAccountOverStaleRegistryActiveAccount() async throws {
        let environment = try isolatedHomeEnvironment()
        let registryStore = ReviewAccountRegistryStore(environment: environment)

        try writeReviewAuthSnapshot(
            email: "stale@example.com",
            planType: "pro",
            environment: environment
        )
        _ = try registryStore.saveSharedAuthAsSavedAccount(makeActive: true)

        try writeReviewAuthSnapshot(
            email: "current@example.com",
            planType: "plus",
            environment: environment
        )
        _ = try registryStore.saveSharedAuthAsSavedAccount(makeActive: false)

        let store = makeTestStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: MockAppServerManager { _ in .success() }
        )

        #expect(store.auth.account?.email == "current@example.com")
        #expect(store.auth.savedAccounts.first(where: \.isActive)?.email == "current@example.com")
        #expect(store.auth.savedAccounts.map(\.email) == ["stale@example.com", "current@example.com"])
    }

    @Test func savingDifferentActiveAccountPreservesExistingSavedAccount() async throws {
        let environment = try isolatedHomeEnvironment()
        let registryStore = ReviewAccountRegistryStore(environment: environment)

        try writeReviewAuthSnapshot(
            email: "active@example.com",
            planType: "pro",
            environment: environment
        )
        let firstSavedAccount = try #require(
            try registryStore.saveSharedAuthAsSavedAccount(makeActive: true)
        )

        try writeReviewAuthSnapshot(
            email: "other@example.com",
            planType: "plus",
            environment: environment
        )
        let secondSavedAccount = try #require(
            try registryStore.saveSharedAuthAsSavedAccount(makeActive: true)
        )

        let loadedAccounts = loadRegisteredReviewAccounts(environment: environment)

        #expect(firstSavedAccount.accountKey != secondSavedAccount.accountKey)
        #expect(loadedAccounts.activeAccountKey == secondSavedAccount.accountKey)
        #expect(loadedAccounts.accounts.map(\.email) == ["active@example.com", "other@example.com"])
        #expect(
            FileManager.default.fileExists(
                atPath: ReviewHomePaths.savedAccountAuthURL(
                    accountKey: firstSavedAccount.accountKey,
                    environment: environment
                ).path
            )
        )
        #expect(
            FileManager.default.fileExists(
                atPath: ReviewHomePaths.savedAccountAuthURL(
                    accountKey: secondSavedAccount.accountKey,
                    environment: environment
                ).path
            )
        )
    }

    @Test func savingSavedAccountRollsBackAuthFilesWhenRegistryPersistenceFails() throws {
        let environment = try isolatedHomeEnvironment()
        let probeEnvironment = try isolatedHomeEnvironment()
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        let originalSavedAccount = try saveReviewAccount(
            email: "active@example.com",
            makeActive: true,
            environment: environment,
            registryStore: registryStore
        )
        let originalRegistry = loadRegisteredReviewAccounts(environment: environment)
        let sharedAuthURL = ReviewHomePaths.reviewAuthURL(environment: environment)
        let originalSavedAuthURL = ReviewHomePaths.savedAccountAuthURL(
            accountKey: originalSavedAccount.accountKey,
            environment: environment
        )
        let originalSharedAuthData = try Data(contentsOf: sharedAuthURL)
        let originalSavedAuthData = try Data(contentsOf: originalSavedAuthURL)
        let sourceAuthURL = ReviewHomePaths.reviewAuthURL(environment: probeEnvironment)

        try writeReviewAuthSnapshot(
            email: "other@example.com",
            planType: "plus",
            environment: probeEnvironment
        )
        ReviewAccountRegistryStore.saveRegistryRecordFailureMessageForTesting = "Registry write failed."
        defer {
            ReviewAccountRegistryStore.saveRegistryRecordFailureMessageForTesting = nil
        }

        #expect(throws: Error.self) {
            try registryStore.saveAuthSnapshot(sourceAuthURL: sourceAuthURL, makeActive: true)
        }

        let loadedAccounts = loadRegisteredReviewAccounts(environment: environment)
        #expect(loadedAccounts.activeAccountKey == originalRegistry.activeAccountKey)
        #expect(loadedAccounts.accounts.map(\.email) == originalRegistry.accounts.map(\.email))
        #expect(loadSharedReviewAccount(environment: environment)?.email == "active@example.com")
        #expect((try? Data(contentsOf: sharedAuthURL)) == originalSharedAuthData)
        #expect((try? Data(contentsOf: originalSavedAuthURL)) == originalSavedAuthData)
        #expect(
            FileManager.default.fileExists(
                atPath: ReviewHomePaths.savedAccountAuthURL(
                    accountKey: "other@example.com",
                    environment: environment
                ).path
            ) == false
        )
    }

    @Test func removeAccountRollsBackDeletedSavedSnapshotsWhenDirectoryDeletionFails() async throws {
        let environment = try isolatedHomeEnvironment()
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        try writeReviewAuthSnapshot(
            email: "saved@example.com",
            planType: "pro",
            environment: environment
        )
        let savedAccount = try #require(
            try registryStore.saveSharedAuthAsSavedAccount(makeActive: false)
        )
        try writeSavedAccountAuthSnapshot(
            email: savedAccount.email,
            planType: savedAccount.planType,
            accountKey: savedAccount.accountKey,
            environment: environment,
            useLegacyDirectory: true
        )
        let firstDirectory = ReviewHomePaths.savedAccountDirectoryURL(
            accountKey: savedAccount.accountKey,
            environment: environment
        )
        let secondDirectory = ReviewHomePaths.legacySavedAccountDirectoryURL(
            accountKey: savedAccount.accountKey,
            environment: environment
        )
        ReviewAccountRegistryStore.savedAccountDirectoryDeleteFailurePathComponentForTesting = secondDirectory.lastPathComponent
        defer {
            ReviewAccountRegistryStore.savedAccountDirectoryDeleteFailurePathComponentForTesting = nil
        }

        await #expect(throws: Error.self) {
            try await registryStore.removeAccount(savedAccount.accountKey)
        }

        #expect(FileManager.default.fileExists(atPath: firstDirectory.appendingPathComponent("auth.json").path))
        #expect(FileManager.default.fileExists(atPath: secondDirectory.appendingPathComponent("auth.json").path))
    }

    @Test func removingUnknownAccountDoesNotPromoteReplacementAccount() async throws {
        let environment = try isolatedHomeEnvironment()
        let registryStore = ReviewAccountRegistryStore(environment: environment)

        try writeReviewAuthSnapshot(
            email: "current@example.com",
            planType: "pro",
            environment: environment
        )
        let savedAccount = ReviewSavedAccountRecord(
            accountKey: "saved@example.com",
            email: "saved@example.com",
            planType: "pro",
            lastActivatedAt: nil,
            lastRateLimitFetchAt: nil,
            lastRateLimitError: nil,
            cachedRateLimits: []
        )
        try writeSavedAccountAuthSnapshot(
            email: savedAccount.email,
            planType: savedAccount.planType,
            accountKey: savedAccount.accountKey,
            environment: environment,
            useLegacyDirectory: false
        )
        let registryURL = ReviewHomePaths.accountsRegistryURL(environment: environment)
        try JSONEncoder().encode(
            ReviewAccountRegistryRecord(
                activeAccountKey: nil,
                accounts: [savedAccount]
            )
        ).write(to: registryURL, options: .atomic)
        let sharedAuthURL = ReviewHomePaths.reviewAuthURL(environment: environment)
        let originalSharedAuthData = try Data(contentsOf: sharedAuthURL)
        let initialRegistry = try JSONDecoder().decode(
            ReviewAccountRegistryRecord.self,
            from: Data(contentsOf: registryURL)
        )
        #expect(initialRegistry.activeAccountKey == nil)

        _ = try await registryStore.removeAccount("missing@example.com")

        let persistedRegistry = try JSONDecoder().decode(
            ReviewAccountRegistryRecord.self,
            from: Data(contentsOf: registryURL)
        )
        #expect(persistedRegistry.activeAccountKey == nil)
        #expect(persistedRegistry.accounts.map(\.accountKey) == [savedAccount.accountKey])
        #expect(try Data(contentsOf: sharedAuthURL) == originalSharedAuthData)
    }

    @Test func activatingSavedAccountPreservesAccountOrder() async throws {
        let environment = try isolatedHomeEnvironment()
        let registryStore = ReviewAccountRegistryStore(environment: environment)

        try writeReviewAuthSnapshot(
            email: "first@example.com",
            planType: "pro",
            environment: environment
        )
        let firstAccount = try #require(
            try registryStore.saveSharedAuthAsSavedAccount(makeActive: true)
        )

        try writeReviewAuthSnapshot(
            email: "second@example.com",
            planType: "plus",
            environment: environment
        )
        let secondAccount = try #require(
            try registryStore.saveSharedAuthAsSavedAccount(makeActive: true)
        )

        try await registryStore.activateAccount(firstAccount.accountKey)
        let loadedAccounts = loadRegisteredReviewAccounts(environment: environment)

        #expect(loadedAccounts.activeAccountKey == firstAccount.accountKey)
        #expect(firstAccount.accountKey != secondAccount.accountKey)
        #expect(loadedAccounts.accounts.map(\.email) == ["first@example.com", "second@example.com"])
    }

    @Test func reorderingSavedAccountPersistsOrderAndPreservesActiveAccount() async throws {
        let environment = try isolatedHomeEnvironment()
        let registryStore = ReviewAccountRegistryStore(environment: environment)

        try writeReviewAuthSnapshot(
            email: "first@example.com",
            planType: "pro",
            environment: environment
        )
        let firstAccount = try #require(
            try registryStore.saveSharedAuthAsSavedAccount(makeActive: true)
        )

        try writeReviewAuthSnapshot(
            email: "second@example.com",
            planType: "plus",
            environment: environment
        )
        let secondAccount = try #require(
            try registryStore.saveSharedAuthAsSavedAccount(makeActive: true)
        )
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                ImmediateReadAccountReviewAuthSession(
                    response: .init(
                        account: .chatGPT(email: "saved@example.com", planType: "pro"),
                        requiresOpenAIAuth: false
                    )
                )
            },
            loginAuthSessionFactory: { _ in
                SignedOutReviewAuthSession()
            }
        )
        let initialAccounts = loadRegisteredReviewAccounts(environment: environment)
        auth.updateSavedAccounts(initialAccounts.accounts)
        auth.updateAccount(initialAccounts.accounts.first { $0.accountKey == initialAccounts.activeAccountKey })

        try await auth.store.reorderSavedAccount(accountKey: firstAccount.accountKey, toIndex: 1)

        let loadedAccounts = loadRegisteredReviewAccounts(environment: environment)
        #expect(loadedAccounts.activeAccountKey == secondAccount.accountKey)
        #expect(auth.account?.accountKey == secondAccount.accountKey)
        #expect(auth.savedAccounts.map(\.email) == ["second@example.com", "first@example.com"])
        #expect(loadedAccounts.accounts.map(\.email) == ["second@example.com", "first@example.com"])
    }

    @Test func reorderingSavedAccountsPreservesUnsavedCurrentSessionWhenAnotherSavedAccountIsActive() async throws {
        let environment = try isolatedHomeEnvironment()
        let registryStore = ReviewAccountRegistryStore(environment: environment)

        try writeReviewAuthSnapshot(
            email: "active@example.com",
            planType: "pro",
            environment: environment
        )
        let activeAccount = try #require(
            try registryStore.saveSharedAuthAsSavedAccount(makeActive: true)
        )

        try writeReviewAuthSnapshot(
            email: "other@example.com",
            planType: "plus",
            environment: environment
        )
        let otherAccount = try #require(
            try registryStore.saveSharedAuthAsSavedAccount(makeActive: false)
        )

        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                ImmediateReadAccountReviewAuthSession(
                    response: .init(
                        account: .chatGPT(email: "saved@example.com", planType: "pro"),
                        requiresOpenAIAuth: false
                    )
                )
            },
            loginAuthSessionFactory: { _ in
                SignedOutReviewAuthSession()
            }
        )
        auth.updateSavedAccounts(loadRegisteredReviewAccounts(environment: environment).accounts)
        auth.updateAccount(CodexAccount(email: "current@example.com"))

        try await auth.store.reorderSavedAccount(accountKey: otherAccount.accountKey, toIndex: 0)

        let loadedAccounts = loadRegisteredReviewAccounts(environment: environment)
        #expect(auth.account?.email == "current@example.com")
        #expect(auth.savedAccounts.first(where: \.isActive)?.accountKey == activeAccount.accountKey)
        #expect(loadedAccounts.activeAccountKey == activeAccount.accountKey)
        #expect(loadedAccounts.accounts.map(\.email) == ["other@example.com", "active@example.com"])
    }

    @Test func reorderingSavedAccountsPreservesSignedOutRecoverableState() async throws {
        let environment = try isolatedHomeEnvironment()
        let registryStore = ReviewAccountRegistryStore(environment: environment)

        try writeReviewAuthSnapshot(
            email: "active@example.com",
            planType: "pro",
            environment: environment
        )
        let activeAccount = try #require(
            try registryStore.saveSharedAuthAsSavedAccount(makeActive: true)
        )

        try writeReviewAuthSnapshot(
            email: "other@example.com",
            planType: "plus",
            environment: environment
        )
        let otherAccount = try #require(
            try registryStore.saveSharedAuthAsSavedAccount(makeActive: false)
        )

        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                ImmediateReadAccountReviewAuthSession(
                    response: .init(
                        account: .chatGPT(email: "saved@example.com", planType: "pro"),
                        requiresOpenAIAuth: false
                    )
                )
            },
            loginAuthSessionFactory: { _ in
                SignedOutReviewAuthSession()
            }
        )
        auth.updateSavedAccounts(loadRegisteredReviewAccounts(environment: environment).accounts)
        auth.updateAccount(nil)
        auth.updatePhase(.signedOut)

        try await auth.store.reorderSavedAccount(accountKey: otherAccount.accountKey, toIndex: 0)

        let loadedAccounts = loadRegisteredReviewAccounts(environment: environment)
        #expect(auth.account == nil)
        #expect(testAuthState(from: auth) == .signedOut)
        #expect(auth.savedAccounts.first(where: \.isActive)?.accountKey == activeAccount.accountKey)
        #expect(loadedAccounts.activeAccountKey == activeAccount.accountKey)
        #expect(loadedAccounts.accounts.map(\.email) == ["other@example.com", "active@example.com"])
    }

    @Test func restoringSharedAuthFromSavedAccountPreservesPersistedActiveSelection() async throws {
        let environment = try isolatedHomeEnvironment()
        let registryStore = ReviewAccountRegistryStore(environment: environment)

        _ = try saveReviewAccount(
            email: "active@example.com",
            makeActive: true,
            environment: environment,
            registryStore: registryStore
        )
        _ = try saveReviewAccount(
            email: "review@example.com",
            planType: "plus",
            makeActive: false,
            environment: environment,
            registryStore: registryStore
        )
        try writeReviewAuthSnapshot(
            email: "active@example.com",
            planType: "pro",
            environment: environment
        )

        try await registryStore.restoreSharedAuthFromSavedAccount("review@example.com")

        let loadedAccounts = loadRegisteredReviewAccounts(environment: environment)
        #expect(loadedAccounts.activeAccountKey == "active@example.com")
        #expect(loadSharedReviewAccount(environment: environment)?.email == "review@example.com")
        #expect(loadSharedReviewAccount(environment: environment)?.planType == "plus")
    }

    @Test func storeSeedsSharedAccountWhenRegistryPersistenceFails() async throws {
        let environment = try isolatedHomeEnvironment()
        try writeReviewAuthSnapshot(
            email: "review@example.com",
            planType: "pro",
            environment: environment
        )
        let registryURL = ReviewHomePaths.accountsRegistryURL(environment: environment)
        try FileManager.default.createDirectory(
            at: registryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(to: registryURL, options: .atomic)

        let store = makeTestStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: MockAppServerManager { _ in .success() }
        )

        #expect(store.auth.account?.email == "review@example.com")
        #expect(store.auth.savedAccounts.first?.email == "review@example.com")
    }

    @Test func registryMigrationDoesNotRewriteKeysWhenSavedAccountDirectoryIsBlocked() async throws {
        let environment = try isolatedHomeEnvironment()
        let registryURL = ReviewHomePaths.accountsRegistryURL(environment: environment)
        try FileManager.default.createDirectory(
            at: registryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let legacyAccountKey = "8D0A808B-7DA5-47BE-B5C2-2262783BBF20"
        let registry = ReviewAccountRegistryRecord(
            activeAccountKey: legacyAccountKey,
            accounts: [
                .init(
                    accountKey: legacyAccountKey,
                    email: "saved@example.com",
                    planType: "pro",
                    lastActivatedAt: Date(timeIntervalSince1970: 100),
                    lastRateLimitFetchAt: nil,
                    lastRateLimitError: nil,
                    cachedRateLimits: []
                )
            ]
        )
        try JSONEncoder().encode(registry).write(to: registryURL, options: .atomic)
        try writeSavedAccountAuthSnapshot(
            email: "saved@example.com",
            planType: "pro",
            accountKey: legacyAccountKey,
            environment: environment,
            useLegacyDirectory: true
        )

        let blockedDestinationURL = ReviewHomePaths.savedAccountDirectoryURL(
            accountKey: "saved@example.com",
            environment: environment
        )
        try FileManager.default.createDirectory(
            at: blockedDestinationURL,
            withIntermediateDirectories: true
        )

        let loadedAccounts = loadRegisteredReviewAccounts(environment: environment)
        let persistedRegistry = try JSONDecoder().decode(
            ReviewAccountRegistryRecord.self,
            from: Data(contentsOf: registryURL)
        )

        #expect(loadedAccounts.activeAccountKey == "saved@example.com")
        #expect(loadedAccounts.accounts.map(\.accountKey) == ["saved@example.com"])
        #expect(persistedRegistry.activeAccountKey == legacyAccountKey)
        #expect(persistedRegistry.accounts.map(\.accountKey) == [legacyAccountKey])
        #expect(
            FileManager.default.fileExists(
                atPath: ReviewHomePaths.legacySavedAccountDirectoryURL(
                    accountKey: legacyAccountKey,
                    environment: environment
                )
                .appendingPathComponent("auth.json")
                .path
            )
        )
    }

    @Test func registryMigrationMovesCanonicalDuplicateSavedAccountDirectory() async throws {
        let environment = try isolatedHomeEnvironment()
        let registryURL = ReviewHomePaths.accountsRegistryURL(environment: environment)
        try FileManager.default.createDirectory(
            at: registryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let staleAccountKey = "96E5D11C-55E1-41DF-9A8B-5D7D1317A337"
        let canonicalAccountKey = "D2095F6A-E0C4-45D3-8FD7-FA31D11A4B76"
        let registry = ReviewAccountRegistryRecord(
            activeAccountKey: canonicalAccountKey,
            accounts: [
                .init(
                    accountKey: staleAccountKey,
                    email: "Saved@example.com",
                    planType: "pro",
                    lastActivatedAt: Date(timeIntervalSince1970: 10),
                    lastRateLimitFetchAt: nil,
                    lastRateLimitError: nil,
                    cachedRateLimits: []
                ),
                .init(
                    accountKey: canonicalAccountKey,
                    email: "saved@example.com",
                    planType: "plus",
                    lastActivatedAt: Date(timeIntervalSince1970: 20),
                    lastRateLimitFetchAt: nil,
                    lastRateLimitError: nil,
                    cachedRateLimits: []
                ),
            ]
        )
        try JSONEncoder().encode(registry).write(to: registryURL, options: .atomic)
        try writeSavedAccountAuthSnapshot(
            email: "saved@example.com",
            planType: "plus",
            accountKey: canonicalAccountKey,
            environment: environment,
            useLegacyDirectory: true
        )

        let loadedAccounts = loadRegisteredReviewAccounts(environment: environment)
        #expect(loadedAccounts.accounts.count == 1)
        let migratedAccount = try #require(loadedAccounts.accounts.first)
        let migratedAuthURL = ReviewHomePaths.savedAccountAuthURL(
            accountKey: migratedAccount.accountKey,
            environment: environment
        )

        #expect(migratedAccount.accountKey == "saved@example.com")
        #expect(migratedAccount.planType == "plus")
        #expect(loadedAccounts.activeAccountKey == "saved@example.com")
        #expect(FileManager.default.fileExists(atPath: migratedAuthURL.path))
        #expect(
            FileManager.default.fileExists(
                atPath: ReviewHomePaths.legacySavedAccountDirectoryURL(
                    accountKey: canonicalAccountKey,
                    environment: environment
                )
                .appendingPathComponent("auth.json")
                .path
            )
        )
    }

    @Test func registryMigrationKeepsNewerEncodedAuthSnapshotWhenLegacyCopyIsOlder() async throws {
        let environment = try isolatedHomeEnvironment()
        let registryURL = ReviewHomePaths.accountsRegistryURL(environment: environment)
        try FileManager.default.createDirectory(
            at: registryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let registry = ReviewAccountRegistryRecord(
            activeAccountKey: "saved@example.com",
            accounts: [
                .init(
                    accountKey: "saved@example.com",
                    email: "saved@example.com",
                    planType: "pro",
                    lastActivatedAt: Date(timeIntervalSince1970: 20),
                    lastRateLimitFetchAt: nil,
                    lastRateLimitError: nil,
                    cachedRateLimits: []
                )
            ]
        )
        try JSONEncoder().encode(registry).write(to: registryURL, options: .atomic)
        try writeSavedAccountAuthSnapshot(
            email: "saved@example.com",
            planType: "pro",
            accountKey: "saved@example.com",
            environment: environment,
            useLegacyDirectory: true
        )
        try writeSavedAccountAuthSnapshot(
            email: "saved@example.com",
            planType: "plus",
            accountKey: "saved@example.com",
            environment: environment,
            useLegacyDirectory: false
        )

        let legacyAuthURL = ReviewHomePaths.legacySavedAccountDirectoryURL(
            accountKey: "saved@example.com",
            environment: environment
        ).appendingPathComponent("auth.json")
        let encodedAuthURL = ReviewHomePaths.savedAccountAuthURL(
            accountKey: "saved@example.com",
            environment: environment
        )
        let encodedAuthDataBeforeLoad = try Data(contentsOf: encodedAuthURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 10)],
            ofItemAtPath: legacyAuthURL.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 20)],
            ofItemAtPath: encodedAuthURL.path
        )

        _ = loadRegisteredReviewAccounts(environment: environment)
        #expect(try Data(contentsOf: encodedAuthURL) == encodedAuthDataBeforeLoad)
    }

    @Test func storePrefersSharedAuthWhenRegistryUpdateFails() async throws {
        let environment = try isolatedHomeEnvironment()
        let registryStore = ReviewAccountRegistryStore(environment: environment)

        try writeReviewAuthSnapshot(
            email: "stale@example.com",
            planType: "pro",
            environment: environment
        )
        _ = try registryStore.saveSharedAuthAsSavedAccount(makeActive: true)

        try writeReviewAuthSnapshot(
            email: "current@example.com",
            planType: "plus",
            environment: environment
        )

        let accountsDirectoryURL = ReviewHomePaths.accountsDirectoryURL(environment: environment)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: accountsDirectoryURL.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: accountsDirectoryURL.path)
        }

        let store = makeTestStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: MockAppServerManager { _ in .success() }
        )

        #expect(store.auth.account?.email == "current@example.com")
    }

    @Test func startingStoreRefreshesAuthStateInBackgroundWithoutBlockingStartup() async throws {
        let environment = try isolatedHomeEnvironment()
        let manager = MockAppServerManager { _ in .success() }
        let authSession = SlowReadAccountReviewAuthSession()
        let store = makeInjectedAuthSessionStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            authSessionFactory: {
                authSession
            }
        )

        let startCompletedSignal = AsyncSignal()
        let startTask = Task {
            await store.start()
            await startCompletedSignal.signal()
        }

        await authSession.waitForReadAccountStart()
        try await withTestTimeout {
            await startCompletedSignal.wait()
        }
        #expect(store.serverState == .running)
        await authSession.resumeReadAccount()

        _ = await startTask.value
        await store.stop()
    }

    @Test func startingStoreRestoresSignedInAuthStateFromBackgroundRefresh() async throws {
        let environment = try isolatedHomeEnvironment()
        let manager = MockAppServerManager { _ in .success() }
        let authSession = ImmediateReadAccountReviewAuthSession(
            response: .init(
                account: .chatGPT(email: "review@example.com", planType: "pro"),
                requiresOpenAIAuth: false
            )
        )
        let store = makeInjectedAuthSessionStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            authSessionFactory: {
                authSession
            }
        )
        let authStateProbe = ObservableValueProbe { testAuthState(from: store.auth) }
        defer { authStateProbe.cancel() }

        await store.start()
        defer { Task { await store.stop() } }

        try await waitForObservedValue(authStateProbe) {
            $0 == .signedIn(accountID: "review@example.com")
        }

        await store.stop()
    }

    @Test func authRefreshPreservesSeededAccountWhenRunningAuthTransportCheckoutFails() async throws {
        let environment = try isolatedHomeEnvironment()
        try writeReviewAuthSnapshot(
            email: "review@example.com",
            planType: "pro",
            environment: environment
        )
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        _ = try registryStore.saveSharedAuthAsSavedAccount(makeActive: true)

        let store = CodexReviewStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: FailingAuthCheckoutAppServerManager()
        )

        await store.start()
        defer { Task { await store.stop() } }
        await store.refreshAuthentication()

        #expect(
            testAuthState(from: store.auth) == .failed(
                "Auth transport checkout failed.",
                isAuthenticated: true,
                accountID: "review@example.com"
            )
        )

        await store.stop()
    }

    @Test func reviewMonitorStoreStartupRefreshWaitsForPreparedAuthTransport() async throws {
        let environment = try isolatedHomeEnvironment()
        let authTransport = AuthCapableAppServerSessionTransport()
        await authTransport.updateAccountReadResponse(
            account: [
                "type": "chatgpt",
                "email": "review@example.com",
                "planType": "pro",
            ],
            requiresOpenAIAuth: false
        )
        let manager = AuthCapableAppServerManager(
            authTransport: authTransport,
            requirePrepareBeforeAuthCheckout: true
        )
        let recorder = TestWebAuthenticationSessionRecorder()
        let store = CodexReviewStore.makeReviewMonitorStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            nativeAuthenticationConfiguration: .init(
                callbackScheme: "lynnpd.codexreviewmonitor.auth",
                browserSessionPolicy: .ephemeral,
                presentationAnchorProvider: { NSWindow() }
            ),
            webAuthenticationSessionFactory: makeWebAuthenticationSessionFactory(
                recorder: recorder,
                autoResult: .failure(.cancelled)
            )
        )
        applyTestAuthState(auth: store.auth, state: .signedIn(accountID: "review@example.com"))
        let authStateProbe = ObservableValueProbe { testAuthState(from: store.auth) }
        defer { authStateProbe.cancel() }

        await store.start()
        defer { Task { await store.stop() } }

        try await waitForObservedValue(authStateProbe) {
            $0 == .signedIn(accountID: "review@example.com")
        }

        #expect(await manager.prepareCount() >= 1)
        #expect(await manager.authTransportCheckoutCount() > 0)

        await store.stop()
    }

    @Test func reviewMonitorStoreRefreshDoesNotStartSharedRuntimeWhileStopped() async throws {
        let environment = try isolatedHomeEnvironment()
        let manager = AuthCapableAppServerManager(requirePrepareBeforeAuthCheckout: true)
        let recorder = TestWebAuthenticationSessionRecorder()
        let store = CodexReviewStore.makeReviewMonitorStore(
            configuration: .init(
                port: 0,
                codexCommand: "/usr/bin/false",
                environment: environment
            ),
            appServerManager: manager,
            nativeAuthenticationConfiguration: .init(
                callbackScheme: "lynnpd.codexreviewmonitor.auth",
                browserSessionPolicy: .ephemeral,
                presentationAnchorProvider: { NSWindow() }
            ),
            webAuthenticationSessionFactory: makeWebAuthenticationSessionFactory(
                recorder: recorder,
                autoResult: .failure(.cancelled)
            )
        )

        #expect(store.serverState == .stopped)

        await store.refreshAuthentication()

        #expect(store.serverState == .stopped)
        #expect(await manager.prepareCount() == 0)
        #expect(await manager.authTransportCheckoutCount() == 0)
    }

    @Test func reviewMonitorStoreStartupFailureStillRefreshesAuthState() async throws {
        let environment = try isolatedHomeEnvironment()
        let authTransport = AuthCapableAppServerSessionTransport()
        await authTransport.updateAccountReadResponse(
            account: nil,
            requiresOpenAIAuth: true
        )
        let manager = AuthCapableAppServerManager(
            authTransport: authTransport,
            prepareError: NSError(
                domain: "CodexReviewMCPTests.AuthCapableAppServerManager",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "prepare failed"]
            )
        )
        let recorder = TestWebAuthenticationSessionRecorder()
        let store = CodexReviewStore.makeReviewMonitorStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            nativeAuthenticationConfiguration: .init(
                callbackScheme: "lynnpd.codexreviewmonitor.auth",
                browserSessionPolicy: .ephemeral,
                presentationAnchorProvider: { NSWindow() }
            ),
            webAuthenticationSessionFactory: makeWebAuthenticationSessionFactory(
                recorder: recorder,
                autoResult: .failure(.cancelled)
            )
        )
        applyTestAuthState(auth: store.auth, state: .signedIn(accountID: "review@example.com"))
        let authStateProbe = ObservableValueProbe { testAuthState(from: store.auth) }
        defer { authStateProbe.cancel() }

        await store.start()
        defer { Task { await store.stop() } }

        #expect(store.serverState == .failed("prepare failed"))
        try await waitForObservedValue(authStateProbe) {
            $0 == .signedOut
        }
        #expect(await manager.authTransportCheckoutCount() == 1)
    }

    @Test func startingStoreLoadsCodexRateLimitsForAuthenticatedAccount() async throws {
        let environment = try isolatedHomeEnvironment()
        let manager = AuthCapableAppServerManager()
        let authSession = ImmediateReadAccountReviewAuthSession(
            response: .init(
                account: .chatGPT(email: "review@example.com", planType: "pro"),
                requiresOpenAIAuth: false
            )
        )
        let store = makeInjectedAuthSessionStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            authSessionFactory: {
                authSession
            }
        )
        let fiveHourProbe = ObservableValueProbe { rateLimitWindow(duration: 300, in: store.auth.account)?.usedPercent }
        defer { fiveHourProbe.cancel() }

        await store.start()
        defer { Task { await store.stop() } }

        try await waitForObservedValue(fiveHourProbe) {
            $0 == 40
        }

        #expect(rateLimitWindow(duration: 300, in: store.auth.account)?.usedPercent == 40)
        #expect(rateLimitWindow(duration: 10_080, in: store.auth.account)?.usedPercent == 20)
        await store.stop()
    }

    @Test func startingStorePrefersCurrentCodexSnapshotOverStaleCodexMapEntry() async throws {
        let environment = try isolatedHomeEnvironment()
        let authTransport = AuthCapableAppServerSessionTransport()
        await authTransport.updateRateLimitsResponse(
            current: [
                "limitId": "codex",
                "primary": [
                    "usedPercent": 85,
                    "windowDurationMins": 300,
                    "resetsAt": 1_735_776_000,
                ],
                "secondary": [
                    "usedPercent": 55,
                    "windowDurationMins": 10080,
                    "resetsAt": 1_736_380_800,
                ],
            ],
            byLimitID: [
                "codex": [
                    "limitId": "codex",
                    "primary": [
                        "usedPercent": 40,
                        "windowDurationMins": 300,
                        "resetsAt": 1_735_776_000,
                    ],
                    "secondary": [
                        "usedPercent": 20,
                        "windowDurationMins": 10080,
                        "resetsAt": 1_736_380_800,
                    ],
                ],
            ]
        )
        let manager = AuthCapableAppServerManager(authTransport: authTransport)
        let authSession = ImmediateReadAccountReviewAuthSession(
            response: .init(
                account: .chatGPT(email: "review@example.com", planType: "pro"),
                requiresOpenAIAuth: false
            )
        )
        let store = makeInjectedAuthSessionStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            authSessionFactory: {
                authSession
            }
        )
        let fiveHourProbe = ObservableValueProbe { rateLimitWindow(duration: 300, in: store.auth.account)?.usedPercent }
        defer { fiveHourProbe.cancel() }

        await store.start()
        defer { Task { await store.stop() } }

        try await waitForObservedValue(fiveHourProbe) {
            $0 == 85
        }

        #expect(rateLimitWindow(duration: 300, in: store.auth.account)?.usedPercent == 85)
        #expect(rateLimitWindow(duration: 10_080, in: store.auth.account)?.usedPercent == 55)

        await store.stop()
    }

    @Test func startingStoreKeepsCodexQuotaNilWhenOnlyOtherBucketIsCurrent() async throws {
        let environment = try isolatedHomeEnvironment()
        let authTransport = AuthCapableAppServerSessionTransport()
        await authTransport.updateRateLimitsResponse(
            current: [
                "limitId": "codex_other",
                "limitName": "codex_other",
                "primary": [
                    "usedPercent": 64,
                    "windowDurationMins": 60,
                    "resetsAt": 1_735_776_000,
                ],
                "secondary": NSNull(),
            ],
            byLimitID: [
                "codex_other": [
                    "limitId": "codex_other",
                    "limitName": "codex_other",
                    "primary": [
                        "usedPercent": 64,
                        "windowDurationMins": 60,
                        "resetsAt": 1_735_776_000,
                    ],
                    "secondary": NSNull(),
                ],
            ]
        )
        let manager = AuthCapableAppServerManager(authTransport: authTransport)
        let authSession = ImmediateReadAccountReviewAuthSession(
            response: .init(
                account: .chatGPT(email: "review@example.com", planType: "pro"),
                requiresOpenAIAuth: false
            )
        )
        let store = makeInjectedAuthSessionStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            authSessionFactory: {
                authSession
            }
        )
        let authStateProbe = ObservableValueProbe { testAuthState(from: store.auth) }
        defer { authStateProbe.cancel() }

        await store.start()
        defer { Task { await store.stop() } }

        try await waitForObservedValue(authStateProbe) {
            $0 == .signedIn(accountID: "review@example.com")
        }

        #expect(rateLimitWindow(duration: 300, in: store.auth.account) == nil)
        #expect(rateLimitWindow(duration: 10_080, in: store.auth.account) == nil)

        await store.stop()
    }

    @Test func startingStoreSkipsRateLimitWindowWhenDurationIsMissing() async throws {
        let environment = try isolatedHomeEnvironment()
        let authTransport = AuthCapableAppServerSessionTransport()
        await authTransport.updateRateLimitsResponse(
            current: [
                "limitId": "codex",
                "primary": [
                    "usedPercent": 40,
                    "resetsAt": 1_735_776_000,
                ],
                "secondary": [
                    "usedPercent": 20,
                    "windowDurationMins": 10080,
                    "resetsAt": 1_736_380_800,
                ],
            ]
        )
        let manager = AuthCapableAppServerManager(authTransport: authTransport)
        let authSession = ImmediateReadAccountReviewAuthSession(
            response: .init(
                account: .chatGPT(email: "review@example.com", planType: "pro"),
                requiresOpenAIAuth: false
            )
        )
        let store = makeInjectedAuthSessionStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            authSessionFactory: {
                authSession
            }
        )
        let weeklyProbe = ObservableValueProbe { rateLimitWindow(duration: 10_080, in: store.auth.account)?.usedPercent }
        defer { weeklyProbe.cancel() }

        await store.start()
        defer { Task { await store.stop() } }

        try await waitForObservedValue(weeklyProbe) {
            $0 == 20
        }

        #expect(rateLimitWindow(duration: 300, in: store.auth.account) == nil)
        #expect(rateLimitWindow(duration: 10_080, in: store.auth.account)?.usedPercent == 20)

        await store.stop()
    }

    @Test func codexAccountSkipsInvalidRateLimitDurations() {
        let account = CodexAccount(email: "review@example.com", planType: "pro")

        account.updateRateLimits(
            [
                (windowDurationMinutes: 300, usedPercent: 40, resetsAt: nil),
                (windowDurationMinutes: 300, usedPercent: 55, resetsAt: nil),
                (windowDurationMinutes: 0, usedPercent: 75, resetsAt: nil),
                (windowDurationMinutes: -60, usedPercent: 10, resetsAt: nil),
            ]
        )

        #expect(account.rateLimits.map(\.windowDurationMinutes) == [300])
        #expect(account.rateLimits.map(\.usedPercent) == [55])
    }

    @Test func rateLimitNotificationUpdatesCodexSnapshotAndPreservesOtherBuckets() async throws {
        let environment = try isolatedHomeEnvironment()
        let manager = AuthCapableAppServerManager()
        let authSession = ImmediateReadAccountReviewAuthSession(
            response: .init(
                account: .chatGPT(email: "review@example.com", planType: "pro"),
                requiresOpenAIAuth: false
            )
        )
        let store = makeInjectedAuthSessionStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            authSessionFactory: {
                authSession
            }
        )
        let fiveHourProbe = ObservableValueProbe { rateLimitWindow(duration: 300, in: store.auth.account)?.usedPercent }
        defer { fiveHourProbe.cancel() }

        await store.start()
        defer { Task { await store.stop() } }

        try await waitForObservedValue(fiveHourProbe) {
            $0 == 40
        }

        let initialSessionWindow = try #require(
            rateLimitWindow(duration: 300, in: store.auth.account)
        )
        let initialWeeklyWindow = try #require(
            rateLimitWindow(duration: 10_080, in: store.auth.account)
        )

        let authTransport = try #require(await manager.authTransportForTesting())
        try await authTransport.sendRateLimitsUpdated(
            [
                "limitId": "codex",
                "limitName": NSNull(),
                "primary": [
                    "usedPercent": 85,
                    "windowDurationMins": 300,
                    "resetsAt": 1_735_776_000,
                ],
                "secondary": [
                    "usedPercent": 55,
                    "windowDurationMins": 10080,
                    "resetsAt": 1_736_380_800,
                ],
            ]
        )

        try await waitForObservedValue(fiveHourProbe) {
            $0 == 85
        }

        #expect(rateLimitWindow(duration: 300, in: store.auth.account) === initialSessionWindow)
        #expect(rateLimitWindow(duration: 10_080, in: store.auth.account) === initialWeeklyWindow)
        #expect(rateLimitWindow(duration: 300, in: store.auth.account)?.usedPercent == 85)
        #expect(rateLimitWindow(duration: 10_080, in: store.auth.account)?.usedPercent == 55)
        await store.stop()
    }

    @Test func rateLimitNotificationUpdatesDetachedCurrentAndSavedAccountInstances() async throws {
        let environment = try isolatedHomeEnvironment()
        let manager = AuthCapableAppServerManager()
        let authSession = ImmediateReadAccountReviewAuthSession(
            response: .init(
                account: .chatGPT(email: "review@example.com", planType: "pro"),
                requiresOpenAIAuth: false
            )
        )
        let store = makeInjectedAuthSessionStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            authSessionFactory: {
                authSession
            }
        )
        let currentProbe = ObservableValueProbe { rateLimitWindow(duration: 300, in: store.auth.account)?.usedPercent }
        defer { currentProbe.cancel() }

        await store.start()
        defer { Task { await store.stop() } }

        try await waitForObservedValue(currentProbe) {
            $0 == 40
        }

        let savedAccount = try #require(store.auth.savedAccounts.first)
        let detachedCurrent = CodexAccount(email: "review@example.com", planType: "pro")
        store.auth.updateAccount(detachedCurrent)
        #expect(savedAccount !== detachedCurrent)

        let authTransport = try #require(await manager.authTransportForTesting())
        try await authTransport.sendRateLimitsUpdated(
            [
                "limitId": "codex",
                "limitName": NSNull(),
                "primary": [
                    "usedPercent": 85,
                    "windowDurationMins": 300,
                    "resetsAt": 1_735_776_000,
                ],
                "secondary": [
                    "usedPercent": 55,
                    "windowDurationMins": 10080,
                    "resetsAt": 1_736_380_800,
                ],
            ]
        )

        try await waitForObservedValue(currentProbe) {
            $0 == 85
        }

        #expect(rateLimitWindow(duration: 300, in: detachedCurrent)?.usedPercent == 85)
        #expect(rateLimitWindow(duration: 10_080, in: detachedCurrent)?.usedPercent == 55)
        #expect(rateLimitWindow(duration: 300, in: savedAccount)?.usedPercent == 85)
        #expect(rateLimitWindow(duration: 10_080, in: savedAccount)?.usedPercent == 55)

        await store.stop()
    }

    @Test func startingStoreCapturesRateLimitUpdateDeliveredDuringInitialRead() async throws {
        let environment = try isolatedHomeEnvironment()
        let authTransport = AuthCapableAppServerSessionTransport()
        await authTransport.updateRateLimitsResponse(
            current: [
                "limitId": "codex",
                "primary": [
                    "usedPercent": 40,
                    "windowDurationMins": 300,
                    "resetsAt": 1_735_776_000,
                ],
                "secondary": [
                    "usedPercent": 20,
                    "windowDurationMins": 10080,
                    "resetsAt": 1_736_380_800,
                ],
            ]
        )
        try await authTransport.sendRateLimitsUpdatedDuringNextRead(
            [
                "primary": [
                    "usedPercent": 85,
                    "windowDurationMins": 300,
                    "resetsAt": 1_735_776_000,
                ],
                "secondary": [
                    "usedPercent": 55,
                    "windowDurationMins": 10080,
                    "resetsAt": 1_736_380_800,
                ],
            ]
        )
        let manager = AuthCapableAppServerManager(authTransport: authTransport)
        let authSession = ImmediateReadAccountReviewAuthSession(
            response: .init(
                account: .chatGPT(email: "review@example.com", planType: "pro"),
                requiresOpenAIAuth: false
            )
        )
        let store = makeInjectedAuthSessionStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            authSessionFactory: {
                authSession
            }
        )
        let fiveHourProbe = ObservableValueProbe { rateLimitWindow(duration: 300, in: store.auth.account)?.usedPercent }
        defer { fiveHourProbe.cancel() }

        await store.start()
        defer { Task { await store.stop() } }

        try await waitForObservedValue(fiveHourProbe) {
            $0 == 85
        }

        #expect(rateLimitWindow(duration: 300, in: store.auth.account)?.usedPercent == 85)
        #expect(rateLimitWindow(duration: 10_080, in: store.auth.account)?.usedPercent == 55)

        await store.stop()
    }

    @Test func nonCodexRateLimitUpdateDoesNotReplaceCurrentSnapshot() async throws {
        let environment = try isolatedHomeEnvironment()
        let manager = AuthCapableAppServerManager()
        let authSession = ImmediateReadAccountReviewAuthSession(
            response: .init(
                account: .chatGPT(email: "review@example.com", planType: "pro"),
                requiresOpenAIAuth: false
            )
        )
        let store = makeInjectedAuthSessionStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            authSessionFactory: {
                authSession
            }
        )
        let fiveHourProbe = ObservableValueProbe { rateLimitWindow(duration: 300, in: store.auth.account)?.usedPercent }
        defer { fiveHourProbe.cancel() }

        await store.start()
        defer { Task { await store.stop() } }
        try await waitForObservedValue(fiveHourProbe) {
            $0 == 40
        }

        let authTransport = try #require(await manager.authTransportForTesting())
        try await authTransport.sendRateLimitsUpdated(
            [
                "limitId": "codex_other",
                "limitName": "codex_other",
                "primary": [
                    "usedPercent": 77,
                    "windowDurationMins": 60,
                    "resetsAt": 1_735_776_000,
                ],
                "secondary": NSNull(),
            ]
        )

        try await Task.sleep(for: .milliseconds(50))
        #expect(rateLimitWindow(duration: 300, in: store.auth.account)?.usedPercent == 40)

        await store.stop()
    }

    @Test func nonCodexRateLimitUpdateDoesNotReplaceImplicitCodexCurrentSnapshot() async throws {
        let environment = try isolatedHomeEnvironment()
        let authTransport = AuthCapableAppServerSessionTransport()
        await authTransport.updateRateLimitsResponse(
            current: [
                "primary": [
                    "usedPercent": 40,
                    "windowDurationMins": 300,
                    "resetsAt": 1_735_776_000,
                ],
                "secondary": [
                    "usedPercent": 20,
                    "windowDurationMins": 10080,
                    "resetsAt": 1_736_380_800,
                ],
            ]
        )
        let manager = AuthCapableAppServerManager(authTransport: authTransport)
        let authSession = ImmediateReadAccountReviewAuthSession(
            response: .init(
                account: .chatGPT(email: "review@example.com", planType: "pro"),
                requiresOpenAIAuth: false
            )
        )
        let store = makeInjectedAuthSessionStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            authSessionFactory: {
                authSession
            }
        )
        let fiveHourProbe = ObservableValueProbe { rateLimitWindow(duration: 300, in: store.auth.account)?.usedPercent }
        defer { fiveHourProbe.cancel() }

        await store.start()
        defer { Task { await store.stop() } }
        try await waitForObservedValue(fiveHourProbe) {
            $0 == 40
        }

        try await authTransport.sendRateLimitsUpdated(
            [
                "limitId": "codex_other",
                "limitName": "codex_other",
                "primary": [
                    "usedPercent": 77,
                    "windowDurationMins": 60,
                    "resetsAt": 1_735_776_000,
                ],
                "secondary": NSNull(),
            ]
        )

        try await Task.sleep(for: .milliseconds(50))
        #expect(rateLimitWindow(duration: 300, in: store.auth.account)?.usedPercent == 40)
        #expect(rateLimitWindow(duration: 10_080, in: store.auth.account)?.usedPercent == 20)

        await store.stop()
    }

    @Test func implicitCodexUpdateDoesNotReplaceNonCodexCurrentSnapshot() async throws {
        let environment = try isolatedHomeEnvironment()
        let authTransport = AuthCapableAppServerSessionTransport()
        await authTransport.updateRateLimitsResponse(
            current: [
                "limitId": "codex_other",
                "limitName": "codex_other",
                "primary": [
                    "usedPercent": 64,
                    "windowDurationMins": 60,
                    "resetsAt": 1_735_776_000,
                ],
                "secondary": NSNull(),
            ],
            byLimitID: [
                "codex_other": [
                    "limitId": "codex_other",
                    "limitName": "codex_other",
                    "primary": [
                        "usedPercent": 64,
                        "windowDurationMins": 60,
                        "resetsAt": 1_735_776_000,
                    ],
                    "secondary": NSNull(),
                ],
            ]
        )
        let manager = AuthCapableAppServerManager(authTransport: authTransport)
        let authSession = ImmediateReadAccountReviewAuthSession(
            response: .init(
                account: .chatGPT(email: "review@example.com", planType: "pro"),
                requiresOpenAIAuth: false
            )
        )
        let store = makeInjectedAuthSessionStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            authSessionFactory: {
                authSession
            }
        )
        let codexProbe = ObservableValueProbe { rateLimitWindow(duration: 300, in: store.auth.account)?.usedPercent }
        defer { codexProbe.cancel() }

        await store.start()
        defer { Task { await store.stop() } }
        await authTransport.waitForNotificationStream()

        try await authTransport.sendRateLimitsUpdated(
            [
                "primary": [
                    "usedPercent": 77,
                    "windowDurationMins": 300,
                    "resetsAt": 1_735_776_000,
                ],
                "secondary": [
                    "usedPercent": 21,
                    "windowDurationMins": 10080,
                    "resetsAt": 1_736_380_800,
                ],
            ]
        )

        try await waitForObservedValue(codexProbe) {
            $0 == 77
        }

        #expect(rateLimitWindow(duration: 300, in: store.auth.account)?.usedPercent == 77)
        #expect(rateLimitWindow(duration: 10_080, in: store.auth.account)?.usedPercent == 21)

        await store.stop()
    }

    @Test func rateLimitObserverReconnectsAfterCleanNotificationStreamFinish() async throws {
        let environment = try isolatedHomeEnvironment()
        let firstTransport = AuthCapableAppServerSessionTransport()
        let secondTransport = AuthCapableAppServerSessionTransport()
        await secondTransport.updateRateLimitsResponse(
            current: [
                "limitId": "codex",
                "primary": [
                    "usedPercent": 65,
                    "windowDurationMins": 300,
                    "resetsAt": 1_735_776_000,
                ],
                "secondary": [
                    "usedPercent": 42,
                    "windowDurationMins": 10080,
                    "resetsAt": 1_736_380_800,
                ],
            ]
        )
        let manager = AuthCapableAppServerManager(
            authTransports: [firstTransport, secondTransport]
        )
        let authSession = ImmediateReadAccountReviewAuthSession(
            response: .init(
                account: .chatGPT(email: "review@example.com", planType: "pro"),
                requiresOpenAIAuth: false
            )
        )
        let store = makeInjectedAuthSessionStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            authSessionFactory: {
                authSession
            }
        )
        let fiveHourProbe = ObservableValueProbe { rateLimitWindow(duration: 300, in: store.auth.account)?.usedPercent }
        defer { fiveHourProbe.cancel() }

        await store.start()
        defer { Task { await store.stop() } }
        try await waitForObservedValue(fiveHourProbe) {
            $0 == 40
        }

        await firstTransport.finishNotificationStream()

        try await waitForObservedValue(fiveHourProbe) {
            $0 == 65
        }

        #expect(rateLimitWindow(duration: 300, in: store.auth.account)?.usedPercent == 65)
        #expect(rateLimitWindow(duration: 10_080, in: store.auth.account)?.usedPercent == 42)

        await store.stop()
    }

    @Test func staleRateLimitRefreshRereadsAfterSixtySecondsWithoutUpdates() async throws {
        let environment = try isolatedHomeEnvironment()
        let clock = ManualTestClock()
        let authTransport = AuthCapableAppServerSessionTransport()
        let manager = AuthCapableAppServerManager(authTransport: authTransport)
        let authSession = ImmediateReadAccountReviewAuthSession(
            response: .init(
                account: .chatGPT(email: "review@example.com", planType: "pro"),
                requiresOpenAIAuth: false
            )
        )
        let store = makeInjectedAuthSessionStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            authSessionFactory: {
                authSession
            },
            rateLimitObservationClock: clock
        )
        let fiveHourProbe = ObservableValueProbe { rateLimitWindow(duration: 300, in: store.auth.account)?.usedPercent }
        defer { fiveHourProbe.cancel() }

        await store.start()
        defer { Task { await store.stop() } }
        try await waitForObservedValue(fiveHourProbe) {
            $0 == 40
        }
        try await waitForClockSuspension(clock)

        await authTransport.updateRateLimitsResponse(
            current: [
                "limitId": "codex",
                "primary": [
                    "usedPercent": 65,
                    "windowDurationMins": 300,
                    "resetsAt": 1_735_776_000,
                ],
                "secondary": [
                    "usedPercent": 42,
                    "windowDurationMins": 10080,
                    "resetsAt": 1_736_380_800,
                ],
            ]
        )

        clock.advance(by: .seconds(60))
        try await waitForRateLimitsReadCount(authTransport, expectedCount: 2)
        try await waitForObservedValue(fiveHourProbe) {
            $0 == 65
        }

        #expect(await authTransport.rateLimitsReadCount() == 2)
        #expect(rateLimitWindow(duration: 10_080, in: store.auth.account)?.usedPercent == 42)

        await store.stop()
    }

    @Test func staleRateLimitRefreshResetsDeadlineAfterNotificationUpdate() async throws {
        let environment = try isolatedHomeEnvironment()
        let clock = ManualTestClock()
        let authTransport = AuthCapableAppServerSessionTransport()
        let manager = AuthCapableAppServerManager(authTransport: authTransport)
        let authSession = ImmediateReadAccountReviewAuthSession(
            response: .init(
                account: .chatGPT(email: "review@example.com", planType: "pro"),
                requiresOpenAIAuth: false
            )
        )
        let store = makeInjectedAuthSessionStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            authSessionFactory: {
                authSession
            },
            rateLimitObservationClock: clock
        )
        let fiveHourProbe = ObservableValueProbe { rateLimitWindow(duration: 300, in: store.auth.account)?.usedPercent }
        defer { fiveHourProbe.cancel() }

        await store.start()
        defer { Task { await store.stop() } }
        try await waitForObservedValue(fiveHourProbe) {
            $0 == 40
        }
        try await waitForClockSuspension(clock)

        clock.advance(by: .seconds(30))
        try await authTransport.sendRateLimitsUpdated(
            [
                "limitId": "codex",
                "primary": [
                    "usedPercent": 85,
                    "windowDurationMins": 300,
                    "resetsAt": 1_735_776_000,
                ],
                "secondary": [
                    "usedPercent": 55,
                    "windowDurationMins": 10080,
                    "resetsAt": 1_736_380_800,
                ],
            ]
        )
        try await waitForObservedValue(fiveHourProbe) {
            $0 == 85
        }
        try await waitForClockSuspension(clock)

        await authTransport.updateRateLimitsResponse(
            current: [
                "limitId": "codex",
                "primary": [
                    "usedPercent": 66,
                    "windowDurationMins": 300,
                    "resetsAt": 1_735_776_000,
                ],
                "secondary": [
                    "usedPercent": 44,
                    "windowDurationMins": 10080,
                    "resetsAt": 1_736_380_800,
                ],
            ]
        )

        clock.advance(by: .seconds(30))
        await Task.yield()
        #expect(await authTransport.rateLimitsReadCount() == 1)
        #expect(rateLimitWindow(duration: 300, in: store.auth.account)?.usedPercent == 85)

        clock.advance(by: .seconds(30))
        try await waitForRateLimitsReadCount(authTransport, expectedCount: 2)
        try await waitForObservedValue(fiveHourProbe) {
            $0 == 66
        }

        await store.stop()
    }

    @Test func staleRateLimitRefreshCancelsWhenAccountChanges() async throws {
        let environment = try isolatedHomeEnvironment()
        let clock = ManualTestClock()
        let firstTransport = AuthCapableAppServerSessionTransport()
        let secondTransport = AuthCapableAppServerSessionTransport()
        await secondTransport.updateRateLimitsResponse(
            current: [
                "limitId": "codex",
                "primary": [
                    "usedPercent": 12,
                    "windowDurationMins": 300,
                    "resetsAt": 1_735_776_000,
                ],
                "secondary": [
                    "usedPercent": 8,
                    "windowDurationMins": 10080,
                    "resetsAt": 1_736_380_800,
                ],
            ]
        )
        let manager = AuthCapableAppServerManager(
            authTransports: [firstTransport, secondTransport]
        )
        let authSession = SequencedReadAccountReviewAuthSession(
            responses: [
                .init(
                    account: .chatGPT(email: "old@example.com", planType: "pro"),
                    requiresOpenAIAuth: false
                ),
                .init(
                    account: .chatGPT(email: "new@example.com", planType: "pro"),
                    requiresOpenAIAuth: false
                ),
            ]
        )
        let store = makeInjectedAuthSessionStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            authSessionFactory: {
                authSession
            },
            rateLimitObservationClock: clock
        )
        let fiveHourProbe = ObservableValueProbe { rateLimitWindow(duration: 300, in: store.auth.account)?.usedPercent }
        defer { fiveHourProbe.cancel() }

        await store.start()
        defer { Task { await store.stop() } }
        try await waitForObservedValue(fiveHourProbe) {
            $0 == 40
        }
        try await waitForClockSuspension(clock)

        await store.refreshAuthentication()
        try await waitForMainActorCondition {
            rateLimitWindow(duration: 300, in: store.auth.account)?.usedPercent == 12
        }
        try await waitForClockSuspension(clock)

        await secondTransport.updateRateLimitsResponse(
            current: [
                "limitId": "codex",
                "primary": [
                    "usedPercent": 18,
                    "windowDurationMins": 300,
                    "resetsAt": 1_735_776_000,
                ],
                "secondary": [
                    "usedPercent": 14,
                    "windowDurationMins": 10080,
                    "resetsAt": 1_736_380_800,
                ],
            ]
        )

        clock.advance(by: .seconds(60))
        try await waitForRateLimitsReadCount(secondTransport, expectedCount: 2)
        try await waitForMainActorCondition {
            rateLimitWindow(duration: 300, in: store.auth.account)?.usedPercent == 18
        }

        #expect(await firstTransport.rateLimitsReadCount() == 1)
        #expect(await secondTransport.rateLimitsReadCount() == 2)
        #expect(testAuthState(from: store.auth) == .signedIn(accountID: "new@example.com"))

        await store.stop()
    }

    @Test func staleRateLimitRefreshCancelsWhenSessionDetaches() async throws {
        let environment = try isolatedHomeEnvironment()
        let clock = ManualTestClock()
        let authTransport = AuthCapableAppServerSessionTransport()
        let manager = AuthCapableAppServerManager(authTransport: authTransport)
        let authSession = ImmediateReadAccountReviewAuthSession(
            response: .init(
                account: .chatGPT(email: "review@example.com", planType: "pro"),
                requiresOpenAIAuth: false
            )
        )
        let store = makeInjectedAuthSessionStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            authSessionFactory: {
                authSession
            },
            rateLimitObservationClock: clock
        )
        let fiveHourProbe = ObservableValueProbe { rateLimitWindow(duration: 300, in: store.auth.account)?.usedPercent }
        defer { fiveHourProbe.cancel() }

        await store.start()
        defer { Task { await store.stop() } }
        try await waitForObservedValue(fiveHourProbe) {
            $0 == 40
        }
        try await waitForClockSuspension(clock)

        await store.stop()
        clock.advance(by: .seconds(60))
        await Task.yield()

        #expect(await authTransport.rateLimitsReadCount() == 1)
    }

    @Test func staleRateLimitRefreshKeepsSnapshotAndRetriesAfterReadFailure() async throws {
        let environment = try isolatedHomeEnvironment()
        let clock = ManualTestClock()
        let authTransport = AuthCapableAppServerSessionTransport()
        let manager = AuthCapableAppServerManager(authTransport: authTransport)
        let authSession = ImmediateReadAccountReviewAuthSession(
            response: .init(
                account: .chatGPT(email: "review@example.com", planType: "pro"),
                requiresOpenAIAuth: false
            )
        )
        let store = makeInjectedAuthSessionStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            authSessionFactory: {
                authSession
            },
            rateLimitObservationClock: clock
        )
        let fiveHourProbe = ObservableValueProbe { rateLimitWindow(duration: 300, in: store.auth.account)?.usedPercent }
        defer { fiveHourProbe.cancel() }

        await store.start()
        defer { Task { await store.stop() } }
        try await waitForObservedValue(fiveHourProbe) {
            $0 == 40
        }
        try await waitForClockSuspension(clock)

        await authTransport.failNextRateLimitsRead(message: "temporary failure")
        clock.advance(by: .seconds(60))
        try await waitForRateLimitsReadCount(authTransport, expectedCount: 2)
        await Task.yield()

        #expect(rateLimitWindow(duration: 300, in: store.auth.account)?.usedPercent == 40)
        try await waitForClockSuspension(clock)

        await authTransport.updateRateLimitsResponse(
            current: [
                "limitId": "codex",
                "primary": [
                    "usedPercent": 77,
                    "windowDurationMins": 300,
                    "resetsAt": 1_735_776_000,
                ],
                "secondary": [
                    "usedPercent": 21,
                    "windowDurationMins": 10080,
                    "resetsAt": 1_736_380_800,
                ],
            ]
        )

        clock.advance(by: .seconds(60))
        try await waitForRateLimitsReadCount(authTransport, expectedCount: 3)
        try await waitForObservedValue(fiveHourProbe) {
            $0 == 77
        }

        #expect(rateLimitWindow(duration: 10_080, in: store.auth.account)?.usedPercent == 21)

        await store.stop()
    }

    @Test func staleRateLimitNotificationWinsOverInFlightPollResponse() async throws {
        let environment = try isolatedHomeEnvironment()
        let clock = ManualTestClock()
        let authTransport = AuthCapableAppServerSessionTransport()
        let manager = AuthCapableAppServerManager(authTransport: authTransport)
        let authSession = ImmediateReadAccountReviewAuthSession(
            response: .init(
                account: .chatGPT(email: "review@example.com", planType: "pro"),
                requiresOpenAIAuth: false
            )
        )
        let store = makeInjectedAuthSessionStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            authSessionFactory: {
                authSession
            },
            rateLimitObservationClock: clock
        )
        let fiveHourProbe = ObservableValueProbe { rateLimitWindow(duration: 300, in: store.auth.account)?.usedPercent }
        defer { fiveHourProbe.cancel() }

        await store.start()
        defer { Task { await store.stop() } }
        try await waitForObservedValue(fiveHourProbe) {
            $0 == 40
        }
        try await waitForClockSuspension(clock)

        await authTransport.blockNextRateLimitsRead()
        await authTransport.updateRateLimitsResponse(
            current: [
                "limitId": "codex",
                "primary": [
                    "usedPercent": 15,
                    "windowDurationMins": 300,
                    "resetsAt": 1_735_776_000,
                ],
                "secondary": [
                    "usedPercent": 10,
                    "windowDurationMins": 10080,
                    "resetsAt": 1_736_380_800,
                ],
            ]
        )

        clock.advance(by: .seconds(60))
        await authTransport.waitForBlockedRateLimitsRead()

        try await authTransport.sendRateLimitsUpdated(
            [
                "limitId": "codex",
                "primary": [
                    "usedPercent": 85,
                    "windowDurationMins": 300,
                    "resetsAt": 1_735_776_000,
                ],
                "secondary": [
                    "usedPercent": 55,
                    "windowDurationMins": 10080,
                    "resetsAt": 1_736_380_800,
                ],
            ]
        )
        try await waitForObservedValue(fiveHourProbe) {
            $0 == 85
        }

        await authTransport.resumeBlockedRateLimitsRead()
        try await waitForRateLimitsReadCount(authTransport, expectedCount: 2)
        await Task.yield()

        #expect(rateLimitWindow(duration: 300, in: store.auth.account)?.usedPercent == 85)
        #expect(rateLimitWindow(duration: 10_080, in: store.auth.account)?.usedPercent == 55)

        await store.stop()
    }

    @Test func authRefreshRestartsRateLimitObserverWhenAccountChanges() async throws {
        let environment = try isolatedHomeEnvironment()
        let manager = AuthCapableAppServerManager()
        let authSession = SequencedReadAccountReviewAuthSession(
            responses: [
                .init(
                    account: .chatGPT(email: "old@example.com", planType: "pro"),
                    requiresOpenAIAuth: false
                ),
                .init(
                    account: .chatGPT(email: "new@example.com", planType: "pro"),
                    requiresOpenAIAuth: false
                ),
            ]
        )
        let store = makeInjectedAuthSessionStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            authSessionFactory: {
                authSession
            }
        )
        let fiveHourProbe = ObservableValueProbe { rateLimitWindow(duration: 300, in: store.auth.account)?.usedPercent }
        defer { fiveHourProbe.cancel() }

        await store.start()
        defer { Task { await store.stop() } }
        try await waitForObservedValue(fiveHourProbe) {
            $0 == 40
        }

        let authTransport = try #require(await manager.authTransportForTesting())
        await authTransport.updateRateLimitsResponse(
            current: [
                "limitId": "codex",
                "limitName": NSNull(),
                "primary": [
                    "usedPercent": 12,
                    "windowDurationMins": 300,
                    "resetsAt": 1_735_776_000,
                ],
                "secondary": [
                    "usedPercent": 8,
                    "windowDurationMins": 10080,
                    "resetsAt": 1_736_380_800,
                ],
            ],
            byLimitID: [
                "codex": [
                    "limitId": "codex",
                    "limitName": NSNull(),
                    "primary": [
                        "usedPercent": 12,
                        "windowDurationMins": 300,
                        "resetsAt": 1_735_776_000,
                    ],
                    "secondary": [
                        "usedPercent": 8,
                        "windowDurationMins": 10080,
                        "resetsAt": 1_736_380_800,
                    ],
                ],
            ]
        )

        await store.refreshAuthentication()

        try await waitForMainActorCondition {
            rateLimitWindow(duration: 300, in: store.auth.account)?.usedPercent == 12
        }

        #expect(testAuthState(from: store.auth) == .signedIn(accountID: "new@example.com"))
        #expect(rateLimitWindow(duration: 300, in: store.auth.account)?.usedPercent == 12)
        #expect(rateLimitWindow(duration: 10_080, in: store.auth.account)?.usedPercent == 8)
        #expect(await manager.prepareCount() == 2)
        #expect(await manager.shutdownCount() == 1)

        await store.stop()
    }

    @Test func authRefreshRereadsRateLimitsForSameAccount() async throws {
        let environment = try isolatedHomeEnvironment()
        let manager = AuthCapableAppServerManager()
        let authSession = SequencedReadAccountReviewAuthSession(
            responses: [
                .init(
                    account: .chatGPT(email: "review@example.com", planType: "pro"),
                    requiresOpenAIAuth: false
                ),
                .init(
                    account: .chatGPT(email: "review@example.com", planType: "pro"),
                    requiresOpenAIAuth: false
                ),
            ]
        )
        let store = makeInjectedAuthSessionStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            authSessionFactory: {
                authSession
            }
        )
        await store.start()
        defer { Task { await store.stop() } }
        try await waitForMainActorCondition {
            rateLimitWindow(duration: 300, in: store.auth.account)?.usedPercent == 40
        }

        let authTransport = try #require(await manager.authTransportForTesting())
        await authTransport.updateRateLimitsResponse(
            current: [
                "limitId": "codex",
                "limitName": NSNull(),
                "primary": [
                    "usedPercent": 18,
                    "windowDurationMins": 300,
                    "resetsAt": 1_735_776_000,
                ],
                "secondary": [
                    "usedPercent": 14,
                    "windowDurationMins": 10080,
                    "resetsAt": 1_736_380_800,
                ],
            ],
            byLimitID: [
                "codex": [
                    "limitId": "codex",
                    "limitName": NSNull(),
                    "primary": [
                        "usedPercent": 18,
                        "windowDurationMins": 300,
                        "resetsAt": 1_735_776_000,
                    ],
                    "secondary": [
                        "usedPercent": 14,
                        "windowDurationMins": 10080,
                        "resetsAt": 1_736_380_800,
                    ],
                ],
            ]
        )

        await store.refreshAuthentication()

        try await waitForMainActorCondition {
            rateLimitWindow(duration: 300, in: store.auth.account)?.usedPercent == 18
        }

        #expect(testAuthState(from: store.auth) == .signedIn(accountID: "review@example.com"))
        #expect(rateLimitWindow(duration: 300, in: store.auth.account)?.usedPercent == 18)
        #expect(rateLimitWindow(duration: 10_080, in: store.auth.account)?.usedPercent == 14)

        await store.stop()
    }

    @Test func authRefreshClearsRateLimitsWhenAccountChangesAndReloadIsUnsupported() async throws {
        let environment = try isolatedHomeEnvironment()
        let manager = AuthCapableAppServerManager(
            authTransports: [
                AuthCapableAppServerSessionTransport(),
                MockAppServerSessionTransport(mode: .success()),
            ]
        )
        let authSession = SequencedReadAccountReviewAuthSession(
            responses: [
                .init(
                    account: .chatGPT(email: "old@example.com", planType: "pro"),
                    requiresOpenAIAuth: false
                ),
                .init(
                    account: .chatGPT(email: "new@example.com", planType: "pro"),
                    requiresOpenAIAuth: false
                ),
            ]
        )
        let store = makeInjectedAuthSessionStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            authSessionFactory: {
                authSession
            }
        )
        let fiveHourProbe = ObservableValueProbe { rateLimitWindow(duration: 300, in: store.auth.account)?.usedPercent }
        defer { fiveHourProbe.cancel() }

        await store.start()
        defer { Task { await store.stop() } }
        try await waitForObservedValue(fiveHourProbe) {
            $0 == 40
        }

        await store.refreshAuthentication()

        #expect(testAuthState(from: store.auth) == .signedIn(accountID: "new@example.com"))
        #expect(rateLimitWindow(duration: 300, in: store.auth.account) == nil)
        #expect(rateLimitWindow(duration: 10_080, in: store.auth.account) == nil)
        await store.stop()
    }

    @Test func rateLimitObserverReconnectsAfterTransportDisconnect() async throws {
        let environment = try isolatedHomeEnvironment()
        let firstTransport = AuthCapableAppServerSessionTransport()
        let secondTransport = AuthCapableAppServerSessionTransport()
        await secondTransport.updateRateLimitsResponse(
            current: [
                "limitId": "codex",
                "limitName": NSNull(),
                "primary": [
                    "usedPercent": 27,
                    "windowDurationMins": 300,
                    "resetsAt": 1_735_776_000,
                ],
                "secondary": [
                    "usedPercent": 9,
                    "windowDurationMins": 10080,
                    "resetsAt": 1_736_380_800,
                ],
            ],
            byLimitID: [
                "codex": [
                    "limitId": "codex",
                    "limitName": NSNull(),
                    "primary": [
                        "usedPercent": 27,
                        "windowDurationMins": 300,
                        "resetsAt": 1_735_776_000,
                    ],
                    "secondary": [
                        "usedPercent": 9,
                        "windowDurationMins": 10080,
                        "resetsAt": 1_736_380_800,
                    ],
                ],
            ]
        )
        let manager = AuthCapableAppServerManager(
            authTransports: [firstTransport, secondTransport]
        )
        let authSession = ImmediateReadAccountReviewAuthSession(
            response: .init(
                account: .chatGPT(email: "review@example.com", planType: "pro"),
                requiresOpenAIAuth: false
            )
        )
        let store = makeInjectedAuthSessionStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            authSessionFactory: {
                authSession
            }
        )
        let fiveHourProbe = ObservableValueProbe { rateLimitWindow(duration: 300, in: store.auth.account)?.usedPercent }
        defer { fiveHourProbe.cancel() }

        await store.start()
        defer { Task { await store.stop() } }
        try await waitForObservedValue(fiveHourProbe) {
            $0 == 40
        }

        await firstTransport.failNotificationStream(message: "transport disconnected")

        try await waitForObservedValue(fiveHourProbe) {
            $0 == 27
        }

        #expect(rateLimitWindow(duration: 10_080, in: store.auth.account)?.usedPercent == 9)

        await store.stop()
    }

    @Test func switchingAccountsRefreshesSettingsAfterAppServerRecycle() async throws {
        let environment = try isolatedHomeEnvironment()
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        try writeReviewAuthSnapshot(
            email: "active@example.com",
            planType: "pro",
            environment: environment
        )
        _ = try registryStore.saveSharedAuthAsSavedAccount(makeActive: true)
        try writeReviewAuthSnapshot(
            email: "other@example.com",
            planType: "pro",
            environment: environment
        )
        _ = try registryStore.saveSharedAuthAsSavedAccount(makeActive: false)
        try writeReviewAuthSnapshot(
            email: "active@example.com",
            planType: "pro",
            environment: environment
        )

        let oldTransport = SettingsRefreshTransport(
            config: .init(model: "gpt-5.4", reviewModel: "gpt-old"),
            firstPage: .init(
                data: [
                    .init(
                        id: "gpt-old",
                        model: "gpt-old",
                        displayName: "GPT Old",
                        hidden: false,
                        supportedReasoningEfforts: [
                            .init(reasoningEffort: .medium, description: "Balanced default.")
                        ],
                        defaultReasoningEffort: .medium,
                        supportedServiceTiers: []
                    )
                ],
                nextCursor: nil
            ),
            secondPage: .init(data: [], nextCursor: nil)
        )
        let newTransport = SettingsRefreshTransport(
            config: .init(model: "gpt-5.4", reviewModel: "gpt-new"),
            firstPage: .init(
                data: [
                    .init(
                        id: "gpt-new",
                        model: "gpt-new",
                        displayName: "GPT New",
                        hidden: false,
                        supportedReasoningEfforts: [
                            .init(reasoningEffort: .medium, description: "Balanced default.")
                        ],
                        defaultReasoningEffort: .medium,
                        supportedServiceTiers: []
                    )
                ],
                nextCursor: nil
            ),
            secondPage: .init(data: [], nextCursor: nil)
        )
        let manager = PreparedSettingsRefreshAppServerManager(
            initialAuthTransport: oldTransport,
            recycledAuthTransport: newTransport
        )
        let authSession = SequencedReadAccountReviewAuthSession(
            responses: [
                .init(
                    account: .chatGPT(email: "active@example.com", planType: "pro"),
                    requiresOpenAIAuth: false
                ),
                .init(
                    account: .chatGPT(email: "other@example.com", planType: "pro"),
                    requiresOpenAIAuth: false
                ),
            ]
        )
        let store = makeInjectedAuthSessionStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            authSessionFactory: {
                authSession
            }
        )

        await store.start()
        defer { Task { await store.stop() } }
        try await waitForMainActorCondition {
            store.auth.account?.email == "active@example.com"
                && store.settings.selectedModel == "gpt-old"
        }

        let savedAccount = try #require(store.auth.savedAccounts.first(where: { $0.email == "other@example.com" }))
        try await store.switchAccount(savedAccount)

        try await waitForMainActorCondition {
            store.auth.account?.email == "other@example.com"
                && store.settings.selectedModel == "gpt-new"
        }

        #expect(await manager.prepareCount() == 2)
        #expect(await manager.shutdownCount() == 1)

        await store.stop()
    }

    @Test func rateLimitObserverRetriesAfterInitialReadDisconnect() async throws {
        let environment = try isolatedHomeEnvironment()
        let manager = AuthCapableAppServerManager(
            authTransports: [
                DisconnectingRateLimitReadTransport(),
                AuthCapableAppServerSessionTransport(),
            ]
        )
        let authSession = ImmediateReadAccountReviewAuthSession(
            response: .init(
                account: .chatGPT(email: "review@example.com", planType: "pro"),
                requiresOpenAIAuth: false
            )
        )
        let store = makeInjectedAuthSessionStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            authSessionFactory: {
                authSession
            }
        )
        let fiveHourProbe = ObservableValueProbe { rateLimitWindow(duration: 300, in: store.auth.account)?.usedPercent }
        defer { fiveHourProbe.cancel() }

        await store.start()
        defer { Task { await store.stop() } }

        try await waitForObservedValue(fiveHourProbe) {
            $0 == 40
        }

        await store.stop()
    }

    @Test func logoutClearsRateLimitModel() async throws {
        let environment = try isolatedHomeEnvironment()
        let manager = AuthCapableAppServerManager()
        let authSession = ImmediateReadAccountReviewAuthSession(
            response: .init(
                account: .chatGPT(email: "review@example.com", planType: "pro"),
                requiresOpenAIAuth: false
            )
        )
        let store = makeInjectedAuthSessionStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            authSessionFactory: {
                authSession
            }
        )
        let fiveHourProbe = ObservableValueProbe { rateLimitWindow(duration: 300, in: store.auth.account)?.usedPercent }
        defer { fiveHourProbe.cancel() }

        await store.start()
        defer { Task { await store.stop() } }
        try await waitForObservedValue(fiveHourProbe) {
            $0 == 40
        }

        await store.logout()

        #expect(testAuthState(from: store.auth) == .signedOut)
        #expect(rateLimitWindow(duration: 300, in: store.auth.account) == nil)
        #expect(rateLimitWindow(duration: 10_080, in: store.auth.account) == nil)
        await store.stop()
    }

    @Test func unsupportedRateLimitReadDoesNotBreakAuthenticatedStartup() async throws {
        let environment = try isolatedHomeEnvironment()
        let manager = MockAppServerManager { _ in .success() }
        let authSession = ImmediateReadAccountReviewAuthSession(
            response: .init(
                account: .chatGPT(email: "review@example.com", planType: "pro"),
                requiresOpenAIAuth: false
            )
        )
        let store = CodexReviewStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            authSessionFactory: {
                authSession
            },
            deferStartupAuthRefreshUntilPrepared: true
        )
        let authStateProbe = ObservableValueProbe { testAuthState(from: store.auth) }
        defer { authStateProbe.cancel() }

        await store.start()
        defer { Task { await store.stop() } }

        try await waitForObservedValue(authStateProbe) {
            $0 == .signedIn(accountID: "review@example.com")
        }

        #expect(store.serverState == .running)
        #expect(rateLimitWindow(duration: 300, in: store.auth.account) == nil)
        #expect(rateLimitWindow(duration: 10_080, in: store.auth.account) == nil)
        await store.stop()
    }

    @Test func authRequiredRateLimitReadDoesNotRetryUntilAuthChanges() async throws {
        let environment = try isolatedHomeEnvironment()
        let firstTransport = AuthCapableAppServerSessionTransport(
            rateLimitsReadBehavior: .authenticationRequired
        )
        let secondTransport = AuthCapableAppServerSessionTransport()
        let manager = AuthCapableAppServerManager(
            authTransports: [firstTransport, secondTransport]
        )
        let authSession = ImmediateReadAccountReviewAuthSession(
            response: .init(
                account: .chatGPT(email: "review@example.com", planType: "pro"),
                requiresOpenAIAuth: false
            )
        )
        let store = CodexReviewStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            authSessionFactory: {
                authSession
            }
        )

        await store.start()
        defer { Task { await store.stop() } }
        try await waitForTotalRateLimitsReadCount(
            [firstTransport, secondTransport],
            expectedCount: 1
        )
        try await waitForAuthTransportCheckoutCount(manager, expectedCount: 2)

        let initialCheckoutCount = await manager.authTransportCheckoutCount()
        #expect(await totalRateLimitsReadCount([firstTransport, secondTransport]) == 1)

        await store.reconcileAuthenticatedSession(
            serverIsRunning: true,
            runtimeGeneration: 1
        )

        #expect(await manager.authTransportCheckoutCount() == initialCheckoutCount)
        #expect(await totalRateLimitsReadCount([firstTransport, secondTransport]) == 1)
        #expect(rateLimitWindow(duration: 300, in: store.auth.account) == nil)
        #expect(rateLimitWindow(duration: 10_080, in: store.auth.account) == nil)

        await store.stop()
    }

    @Test func authRequiredRateLimitReadRetriesAfterSameAccountRefresh() async throws {
        let environment = try isolatedHomeEnvironment()
        let firstTransport = AuthCapableAppServerSessionTransport(
            rateLimitsReadBehavior: .authenticationRequired
        )
        let secondTransport = AuthCapableAppServerSessionTransport()
        let manager = AuthCapableAppServerManager(
            authTransports: [firstTransport, secondTransport]
        )
        let authSession = ImmediateReadAccountReviewAuthSession(
            response: .init(
                account: .chatGPT(email: "review@example.com", planType: "pro"),
                requiresOpenAIAuth: false
            )
        )
        let store = CodexReviewStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            authSessionFactory: {
                authSession
            }
        )

        await store.start()
        defer { Task { await store.stop() } }
        try await waitForRateLimitsReadCount(firstTransport, expectedCount: 1)
        #expect(rateLimitWindow(duration: 300, in: store.auth.account) == nil)

        await store.refreshAuthentication()

        try await waitForRateLimitsReadCount(secondTransport, expectedCount: 1)
        try await waitForMainActorCondition {
            rateLimitWindow(duration: 300, in: store.auth.account)?.usedPercent == 40
        }

        #expect(await firstTransport.rateLimitsReadCount() == 1)
        #expect(await secondTransport.rateLimitsReadCount() >= 1)
        #expect(rateLimitWindow(duration: 10_080, in: store.auth.account)?.usedPercent == 20)

        await store.stop()
    }

    @Test func authRequiredRateLimitReadRetriesAfterRuntimeGenerationChanges() async throws {
        let environment = try isolatedHomeEnvironment()
        let firstTransport = AuthCapableAppServerSessionTransport(
            rateLimitsReadBehavior: .authenticationRequired
        )
        let secondTransport = AuthCapableAppServerSessionTransport()
        let manager = AuthCapableAppServerManager(
            authTransports: [firstTransport, secondTransport]
        )
        let authSession = ImmediateReadAccountReviewAuthSession(
            response: .init(
                account: .chatGPT(email: "review@example.com", planType: "pro"),
                requiresOpenAIAuth: false
            )
        )
        let store = CodexReviewStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            authSessionFactory: {
                authSession
            }
        )

        await store.start()
        defer { Task { await store.stop() } }
        try await waitForRateLimitsReadCount(firstTransport, expectedCount: 1)
        #expect(rateLimitWindow(duration: 300, in: store.auth.account) == nil)

        await store.reconcileAuthenticatedSession(
            serverIsRunning: true,
            runtimeGeneration: 2
        )

        try await waitForRateLimitsReadCount(secondTransport, expectedCount: 1)
        try await waitForMainActorCondition {
            rateLimitWindow(duration: 300, in: store.auth.account)?.usedPercent == 40
        }

        #expect(await firstTransport.rateLimitsReadCount() == 1)
        #expect(await secondTransport.rateLimitsReadCount() >= 1)
        #expect(rateLimitWindow(duration: 10_080, in: store.auth.account)?.usedPercent == 20)

        await store.stop()
    }

    @Test func authRequiredRateLimitReadRetriesAfterSameAccountAddAccountReauthentication() async throws {
        let environment = try isolatedHomeEnvironment()
        try writeReviewAuthSnapshot(
            email: "review@example.com",
            planType: "pro",
            environment: environment
        )
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        _ = try registryStore.saveSharedAuthAsSavedAccount(makeActive: true)

        let firstTransport = AuthCapableAppServerSessionTransport(
            rateLimitsReadBehavior: .authenticationRequired
        )
        let secondTransport = AuthCapableAppServerSessionTransport()
        let manager = AuthCapableAppServerManager(
            authTransports: [firstTransport, secondTransport]
        )
        let authSession = SameAccountSuccessfulLoginReviewAuthSession()
        let store = makeInjectedAuthSessionStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            authSessionFactory: {
                authSession
            }
        )

        await store.start()
        defer { Task { await store.stop() } }
        try await waitForRateLimitsReadCount(firstTransport, expectedCount: 1)
        #expect(store.auth.account?.email == "review@example.com")
        #expect(rateLimitWindow(duration: 300, in: store.auth.account) == nil)

        await store.addAccount()

        try await waitForRateLimitsReadCount(secondTransport, expectedCount: 1)
        try await waitForMainActorCondition {
            rateLimitWindow(duration: 300, in: store.auth.account)?.usedPercent == 40
        }

        #expect(await firstTransport.rateLimitsReadCount() == 1)
        #expect(await secondTransport.rateLimitsReadCount() >= 1)
        #expect(rateLimitWindow(duration: 10_080, in: store.auth.account)?.usedPercent == 20)
        #expect(store.auth.account?.email == "review@example.com")

        await store.stop()
    }

    @Test func authRequiredRateLimitReadWaitsForDeferredSameAccountAddAccountRecycle() async throws {
        let environment = try isolatedHomeEnvironment()
        try writeReviewAuthSnapshot(
            email: "review@example.com",
            planType: "pro",
            environment: environment
        )
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        _ = try registryStore.saveSharedAuthAsSavedAccount(makeActive: true)

        let firstTransport = AuthCapableAppServerSessionTransport(
            rateLimitsReadBehavior: .authenticationRequired
        )
        let secondTransport = AuthCapableAppServerSessionTransport()
        let manager = AuthCapableAppServerManager(
            authTransports: [firstTransport, secondTransport]
        )
        let authSession = SameAccountSuccessfulLoginReviewAuthSession()
        let store = makeInjectedAuthSessionStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            authSessionFactory: {
                authSession
            }
        )

        try await withAsyncCleanup {
            await store.start()
            try await waitForRateLimitsReadCount(firstTransport, expectedCount: 1)
            store.auth.account?.updateRateLimitFetchMetadata(
                fetchedAt: Date.distantFuture,
                error: nil
            )
            let jobID = try store.enqueueReview(
                sessionID: "session-a",
                request: .init(
                    cwd: FileManager.default.currentDirectoryPath,
                    target: .uncommittedChanges
                )
            )
            store.markStarted(jobID: jobID, startedAt: Date())

            await store.addAccount()

            #expect(await secondTransport.rateLimitsReadCount() == 0)
            #expect(store.auth.account?.lastRateLimitError == nil)

            store.completeReview(
                jobID: jobID,
                outcome: .init(
                    state: .succeeded,
                    exitCode: 0,
                    reviewThreadID: nil,
                    threadID: nil,
                    turnID: nil,
                    model: nil,
                    hasFinalReview: false,
                    lastAgentMessage: "",
                    errorMessage: nil,
                    summary: "Completed.",
                    startedAt: Date(),
                    endedAt: Date(),
                    content: ""
                )
            )

            try await waitForRateLimitsReadCount(secondTransport, expectedCount: 1)
            try await waitForMainActorCondition {
                rateLimitWindow(duration: 300, in: store.auth.account)?.usedPercent == 40
            }
        } cleanup: {
            await store.stop()
        }
    }

    @Test func authRequiredRateLimitReadDoesNotRetryAfterAddingDifferentAccount() async throws {
        let environment = try isolatedHomeEnvironment()
        try writeReviewAuthSnapshot(
            email: "active@example.com",
            planType: "pro",
            environment: environment
        )
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        _ = try registryStore.saveSharedAuthAsSavedAccount(makeActive: true)

        let firstTransport = AuthCapableAppServerSessionTransport(
            rateLimitsReadBehavior: .authenticationRequired
        )
        let secondTransport = AuthCapableAppServerSessionTransport()
        let manager = AuthCapableAppServerManager(
            authTransports: [firstTransport, secondTransport]
        )
        let store = CodexReviewStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            sharedAuthSessionFactory: { _ in
                ImmediateReadAccountReviewAuthSession(
                    response: .init(
                        account: .chatGPT(email: "active@example.com", planType: "pro"),
                        requiresOpenAIAuth: false
                    )
                )
            },
            loginAuthSessionFactory: { environment in
                PersistingReviewAuthSession(
                    base: SuccessfulLoginReviewAuthSession(),
                    environment: environment
                )
            }
        )

        await store.start()
        defer { Task { await store.stop() } }
        try await waitForRateLimitsReadCount(firstTransport, expectedCount: 1)
        let initialCheckoutCount = await manager.authTransportCheckoutCount()
        #expect(store.auth.account?.email == "active@example.com")
        #expect(rateLimitWindow(duration: 300, in: store.auth.account) == nil)

        await store.addAccount()

        #expect(await manager.authTransportCheckoutCount() == initialCheckoutCount)
        #expect(await totalRateLimitsReadCount([firstTransport, secondTransport]) == 1)
        #expect(await secondTransport.rateLimitsReadCount() == 0)
        #expect(store.auth.account?.email == "active@example.com")
        #expect(rateLimitWindow(duration: 300, in: store.auth.account) == nil)

        await store.stop()
    }

    @Test func unsupportedRateLimitReadDoesNotPromoteFirstNonCurrentNotificationToCurrentSnapshot() async throws {
        let environment = try isolatedHomeEnvironment()
        let authTransport = AuthCapableAppServerSessionTransport(
            rateLimitsReadBehavior: .unsupported
        )
        let manager = AuthCapableAppServerManager(authTransport: authTransport)
        let authSession = ImmediateReadAccountReviewAuthSession(
            response: .init(
                account: .chatGPT(email: "review@example.com", planType: "pro"),
                requiresOpenAIAuth: false
            )
        )
        let store = CodexReviewStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            authSessionFactory: {
                authSession
            }
        )
        await store.start()
        defer { Task { await store.stop() } }
        await authTransport.waitForNotificationStream()

        try await authTransport.sendRateLimitsUpdated(
            [
                "limitId": "codex_other",
                "limitName": "codex_other",
                "primary": [
                    "usedPercent": 77,
                    "windowDurationMins": 60,
                    "resetsAt": 1_735_776_000,
                ],
                "secondary": NSNull(),
            ]
        )

        try await Task.sleep(for: .milliseconds(50))
        #expect(rateLimitWindow(duration: 300, in: store.auth.account) == nil)
        #expect(rateLimitWindow(duration: 10_080, in: store.auth.account) == nil)

        await store.stop()
    }

    @Test func unsupportedRateLimitReadKeepsNotificationSnapshotAfterStaleInterval() async throws {
        let environment = try isolatedHomeEnvironment()
        let clock = ManualTestClock()
        let authTransport = AuthCapableAppServerSessionTransport(
            rateLimitsReadBehavior: .unsupported
        )
        let manager = AuthCapableAppServerManager(authTransport: authTransport)
        let authSession = ImmediateReadAccountReviewAuthSession(
            response: .init(
                account: .chatGPT(email: "review@example.com", planType: "pro"),
                requiresOpenAIAuth: false
            )
        )
        let store = CodexReviewStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            authSessionFactory: {
                authSession
            },
            rateLimitObservationClock: clock
        )
        let fiveHourProbe = ObservableValueProbe { rateLimitWindow(duration: 300, in: store.auth.account)?.usedPercent }
        defer { fiveHourProbe.cancel() }

        await store.start()
        defer { Task { await store.stop() } }
        await authTransport.waitForNotificationStream()

        try await authTransport.sendRateLimitsUpdated(
            [
                "limitId": "codex",
                "primary": [
                    "usedPercent": 73,
                    "windowDurationMins": 300,
                    "resetsAt": 1_735_776_000,
                ],
                "secondary": [
                    "usedPercent": 41,
                    "windowDurationMins": 10080,
                    "resetsAt": 1_736_380_800,
                ],
            ]
        )

        try await waitForObservedValue(fiveHourProbe) {
            $0 == 73
        }

        clock.advance(by: .seconds(60))
        await Task.yield()

        #expect(await authTransport.rateLimitsReadCount() == 1)
        #expect(rateLimitWindow(duration: 300, in: store.auth.account)?.usedPercent == 73)
        #expect(rateLimitWindow(duration: 10_080, in: store.auth.account)?.usedPercent == 41)

        await store.stop()
    }

    @Test func refreshingActiveRateLimitsWhileServerIsStoppedDoesNotStartSharedRuntime() async throws {
        let environment = try isolatedHomeEnvironment()
        try writeReviewAuthSnapshot(
            email: "review@example.com",
            planType: "pro",
            environment: environment
        )
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        _ = try registryStore.saveSharedAuthAsSavedAccount(makeActive: true)

        let manager = AuthCapableAppServerManager()
        let store = CodexReviewStore(
            configuration: .init(
                port: 0,
                codexCommand: "/usr/bin/false",
                environment: environment
            ),
            appServerManager: manager
        )
        let activeAccount = try #require(store.auth.account)

        #expect(store.serverState == .stopped)

        await store.refreshSavedAccountRateLimits(accountKey: activeAccount.accountKey)

        #expect(store.serverState == .stopped)
        #expect(await manager.prepareCount() == 0)
    }

    @Test func refreshingUnsavedActiveRateLimitsWhileServerIsStoppedPreservesCurrentAccount() async throws {
        let environment = try isolatedHomeEnvironment()
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "/usr/bin/false",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                SignedOutReviewAuthSession()
            },
            loginAuthSessionFactory: { _ in
                SignedOutReviewAuthSession()
            }
        )
        let activeAccount = CodexAccount(
            email: "review@example.com",
            planType: "pro"
        )
        auth.updateSavedAccounts([])
        auth.updatePhase(.signedOut)
        auth.updateAccount(activeAccount)

        await auth.store.refreshSavedAccountRateLimits(accountKey: activeAccount.accountKey)

        #expect(auth.account?.email == "review@example.com")
        #expect(auth.savedAccounts.isEmpty)
    }

    @Test func refreshingActiveRateLimitsWhileServerIsStoppedCleansUpProbeHomeOnStartupFailure() async throws {
        let environment = try isolatedHomeEnvironment()
        try writeReviewAuthSnapshot(
            email: "review@example.com",
            planType: "pro",
            environment: environment
        )
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        _ = try registryStore.saveSharedAuthAsSavedAccount(makeActive: true)
        try FileManager.default.removeItem(at: ReviewHomePaths.reviewAuthURL(environment: environment))

        let store = CodexReviewStore(
            configuration: .init(
                port: 0,
                codexCommand: "/usr/bin/false",
                environment: environment
            ),
            appServerManager: MockAppServerManager { _ in .success() }
        )
        let activeAccount = try #require(store.auth.account)

        await store.refreshSavedAccountRateLimits(accountKey: activeAccount.accountKey)

        let probeRootURL = ReviewHomePaths.makeProbeRootURL(environment: environment)
        let remainingProbeEntries = (try? FileManager.default.contentsOfDirectory(
            at: probeRootURL,
            includingPropertiesForKeys: nil
        )) ?? []
        #expect(remainingProbeEntries.isEmpty)
    }

    @Test func refreshingInactiveSavedAccountRateLimitsDoesNotClearUnsavedCurrentSession() async throws {
        let environment = try isolatedHomeEnvironment()
        try writeReviewAuthSnapshot(
            email: "saved@example.com",
            planType: "pro",
            environment: environment
        )
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        _ = try registryStore.saveSharedAuthAsSavedAccount(makeActive: false)
        try FileManager.default.removeItem(at: ReviewHomePaths.reviewAuthURL(environment: environment))

        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "/usr/bin/false",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                SignedOutReviewAuthSession()
            },
            loginAuthSessionFactory: { _ in
                SignedOutReviewAuthSession()
            }
        )
        let currentAccount = CodexAccount(
            email: "current@example.com",
            planType: "pro"
        )
        auth.updateSavedAccounts(loadRegisteredReviewAccounts(environment: environment).accounts)
        auth.updatePhase(.signedOut)
        auth.updateAccount(currentAccount)
        let savedAccount = try #require(auth.savedAccounts.first)

        await auth.store.refreshSavedAccountRateLimits(accountKey: savedAccount.accountKey)

        #expect(auth.account?.email == "current@example.com")
        #expect(auth.savedAccounts.map(\.email) == ["saved@example.com"])
    }

    @Test func refreshingSavedAccountsPreservesSavedCurrentSessionWhenAnotherSavedAccountIsActive() async throws {
        let environment = try isolatedHomeEnvironment()
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        _ = try saveReviewAccount(
            email: "saved@example.com",
            makeActive: true,
            environment: environment,
            registryStore: registryStore
        )
        _ = try saveReviewAccount(
            email: "review@example.com",
            makeActive: false,
            environment: environment,
            registryStore: registryStore
        )
        try FileManager.default.removeItem(at: ReviewHomePaths.reviewAuthURL(environment: environment))

        let manager = AuthCapableAppServerManager()
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "/usr/bin/false",
                environment: environment
            ),
            appServerManager: manager,
            sharedAuthSessionFactory: { _ in
                SignedOutReviewAuthSession()
            },
            loginAuthSessionFactory: { _ in
                SignedOutReviewAuthSession()
            }
        )
        auth.updateSavedAccounts(loadRegisteredReviewAccounts(environment: environment).accounts)
        let currentSavedAccount = try #require(auth.savedAccounts.first(where: { $0.email == "review@example.com" }))
        auth.updateAccount(currentSavedAccount)

        await auth.store.refreshSavedAccountRateLimits(accountKey: currentSavedAccount.accountKey)

        #expect(auth.account?.email == "review@example.com")
        #expect(auth.savedAccounts.first(where: \.isActive)?.email == "saved@example.com")
    }

    @Test func refreshingStoppedDetachedSavedCurrentUsesSelectedSavedProbe() async throws {
        let environment = try isolatedHomeEnvironment()
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        _ = try saveReviewAccount(
            email: "saved@example.com",
            makeActive: true,
            environment: environment,
            registryStore: registryStore
        )
        _ = try saveReviewAccount(
            email: "review@example.com",
            makeActive: false,
            environment: environment,
            registryStore: registryStore
        )
        try writeReviewAuthSnapshot(
            email: "saved@example.com",
            planType: "pro",
            environment: environment
        )

        let capturedProbeAuthData = MutableValueBox<Data?>(nil)
        let rateLimitTransport = AuthCapableAppServerSessionTransport()
        let rateLimitManager = AuthCapableAppServerManager(authTransport: rateLimitTransport)
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                SignedOutReviewAuthSession()
            },
            loginAuthSessionFactory: { _ in
                SignedOutReviewAuthSession()
            },
            probeAppServerManagerFactory: { probeEnvironment in
                capturedProbeAuthData.value = try? Data(
                    contentsOf: ReviewHomePaths.reviewAuthURL(environment: probeEnvironment)
                )
                return rateLimitManager
            }
        )
        auth.updateSavedAccounts(loadRegisteredReviewAccounts(environment: environment).accounts)
        let currentSavedAccount = try #require(auth.savedAccounts.first(where: { $0.email == "review@example.com" }))
        auth.updateAccount(currentSavedAccount)

        await auth.store.refreshSavedAccountRateLimits(accountKey: currentSavedAccount.accountKey)

        let probeAuthData = try #require(capturedProbeAuthData.value)
        let selectedSavedAuthData = try Data(
            contentsOf: ReviewHomePaths.savedAccountAuthURL(
                accountKey: currentSavedAccount.accountKey,
                environment: environment
            )
        )
        let sharedAuthData = try Data(
            contentsOf: ReviewHomePaths.reviewAuthURL(environment: environment)
        )
        #expect(probeAuthData == selectedSavedAuthData)
        #expect(probeAuthData != sharedAuthData)
        #expect(await rateLimitTransport.rateLimitsReadCount() == 1)
    }

    @Test func refreshingInactiveRateLimitsUpdatesSavedAccountModel() async throws {
        let environment = try isolatedHomeEnvironment()
        try writeReviewAuthSnapshot(
            email: "saved@example.com",
            planType: "pro",
            environment: environment
        )
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        _ = try registryStore.saveSharedAuthAsSavedAccount(makeActive: false)
        try FileManager.default.removeItem(at: ReviewHomePaths.reviewAuthURL(environment: environment))

        let store = CodexReviewStore(
            configuration: .init(
                port: 0,
                codexCommand: "/usr/bin/false",
                environment: environment
            ),
            appServerManager: MockAppServerManager { _ in .success() }
        )
        let savedAccount = try #require(store.auth.savedAccounts.first)

        await store.refreshSavedAccountRateLimits(accountKey: savedAccount.accountKey)

        let refreshedAccount = try #require(
            store.auth.savedAccounts.first(where: { $0.accountKey == savedAccount.accountKey })
        )
        #expect(refreshedAccount.lastRateLimitFetchAt != nil)
        #expect(refreshedAccount.lastRateLimitError?.isEmpty == false)
    }

    @Test func refreshingInactiveRateLimitsUpdatesExistingSavedAccountRateLimits() async throws {
        let environment = try isolatedHomeEnvironment()
        try writeReviewAuthSnapshot(
            email: "saved@example.com",
            planType: "pro",
            environment: environment
        )
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        _ = try registryStore.saveSharedAuthAsSavedAccount(makeActive: false)
        try FileManager.default.removeItem(at: ReviewHomePaths.reviewAuthURL(environment: environment))

        let rateLimitTransport = AuthCapableAppServerSessionTransport()
        let rateLimitManager = AuthCapableAppServerManager(authTransport: rateLimitTransport)
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                SignedOutReviewAuthSession()
            },
            loginAuthSessionFactory: { _ in
                SignedOutReviewAuthSession()
            },
            probeAppServerManagerFactory: { _ in
                rateLimitManager
            }
        )
        auth.updateSavedAccounts(loadRegisteredReviewAccounts(environment: environment).accounts)
        let savedAccount = try #require(auth.savedAccounts.first)

        await auth.store.refreshSavedAccountRateLimits(accountKey: savedAccount.accountKey)

        let refreshedAccount = try #require(
            auth.savedAccounts.first(where: { $0.accountKey == savedAccount.accountKey })
        )
        #expect(await rateLimitTransport.rateLimitsReadCount() == 1)
        #expect(rateLimitWindow(duration: 300, in: refreshedAccount)?.usedPercent == 40)
        #expect(rateLimitWindow(duration: 10_080, in: refreshedAccount)?.usedPercent == 20)
    }

    @Test func refreshingInactiveRateLimitsMutatesExistingSavedAccountObject() async throws {
        let environment = try isolatedHomeEnvironment()
        try writeReviewAuthSnapshot(
            email: "saved@example.com",
            planType: "pro",
            environment: environment
        )
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        _ = try registryStore.saveSharedAuthAsSavedAccount(makeActive: false)
        try FileManager.default.removeItem(at: ReviewHomePaths.reviewAuthURL(environment: environment))

        let rateLimitTransport = AuthCapableAppServerSessionTransport()
        let rateLimitManager = AuthCapableAppServerManager(authTransport: rateLimitTransport)
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                SignedOutReviewAuthSession()
            },
            loginAuthSessionFactory: { _ in
                SignedOutReviewAuthSession()
            },
            probeAppServerManagerFactory: { _ in
                rateLimitManager
            }
        )
        auth.updateSavedAccounts(loadRegisteredReviewAccounts(environment: environment).accounts)
        let savedAccount = try #require(auth.savedAccounts.first)

        await auth.store.refreshSavedAccountRateLimits(accountKey: savedAccount.accountKey)

        #expect(await rateLimitTransport.rateLimitsReadCount() == 1)
        #expect(rateLimitWindow(duration: 300, in: savedAccount)?.usedPercent == 40)
        #expect(rateLimitWindow(duration: 10_080, in: savedAccount)?.usedPercent == 20)
    }

    @Test func refreshingInactiveRateLimitsKeepsInMemoryStateWhenPersistenceFails() async throws {
        let environment = try isolatedHomeEnvironment()
        try writeReviewAuthSnapshot(
            email: "saved@example.com",
            planType: "pro",
            environment: environment
        )
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        _ = try registryStore.saveSharedAuthAsSavedAccount(makeActive: false)
        try FileManager.default.removeItem(at: ReviewHomePaths.reviewAuthURL(environment: environment))

        let rateLimitTransport = AuthCapableAppServerSessionTransport()
        let rateLimitManager = AuthCapableAppServerManager(authTransport: rateLimitTransport)
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                SignedOutReviewAuthSession()
            },
            loginAuthSessionFactory: { _ in
                SignedOutReviewAuthSession()
            },
            probeAppServerManagerFactory: { _ in
                rateLimitManager
            }
        )
        auth.updateSavedAccounts(loadRegisteredReviewAccounts(environment: environment).accounts)
        let savedAccount = try #require(auth.savedAccounts.first)
        ReviewAccountRegistryStore.saveRegistryRecordFailureMessageForTesting = "Registry write failed."
        defer {
            ReviewAccountRegistryStore.saveRegistryRecordFailureMessageForTesting = nil
        }

        await auth.store.refreshSavedAccountRateLimits(accountKey: savedAccount.accountKey)

        let refreshedAccount = try #require(
            auth.savedAccounts.first(where: { $0.accountKey == savedAccount.accountKey })
        )
        #expect(await rateLimitTransport.rateLimitsReadCount() == 1)
        #expect(rateLimitWindow(duration: 300, in: refreshedAccount)?.usedPercent == 40)
        #expect(rateLimitWindow(duration: 10_080, in: refreshedAccount)?.usedPercent == 20)
    }

    @Test func refreshingInactiveRateLimitsReplacesSavedAccountWhenPersistedEmailChanges() async throws {
        let environment = try isolatedHomeEnvironment()
        try writeReviewAuthSnapshot(
            email: "saved@example.com",
            planType: "pro",
            environment: environment
        )
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        let initialSavedAccount = try #require(
            try registryStore.saveSharedAuthAsSavedAccount(makeActive: false)
        )
        try FileManager.default.removeItem(at: ReviewHomePaths.reviewAuthURL(environment: environment))

        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "/usr/bin/false",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                SignedOutReviewAuthSession()
            },
            loginAuthSessionFactory: { _ in
                SignedOutReviewAuthSession()
            }
        )
        auth.updateSavedAccounts(loadRegisteredReviewAccounts(environment: environment).accounts)
        let savedAccount = try #require(auth.savedAccounts.first)
        let registryURL = ReviewHomePaths.accountsRegistryURL(environment: environment)
        let updatedRegistry = ReviewAccountRegistryRecord(
            activeAccountKey: nil,
            accounts: [
                .init(
                    accountKey: "updated@example.com",
                    email: "updated@example.com",
                    planType: "pro",
                    lastActivatedAt: nil,
                    lastRateLimitFetchAt: nil,
                    lastRateLimitError: nil,
                    cachedRateLimits: []
                )
            ]
        )
        let previousAuthURL = ReviewHomePaths.savedAccountAuthURL(
            accountKey: initialSavedAccount.accountKey,
            environment: environment
        )
        let updatedAuthURL = ReviewHomePaths.savedAccountAuthURL(
            accountKey: "updated@example.com",
            environment: environment
        )
        try FileManager.default.createDirectory(
            at: updatedAuthURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: previousAuthURL, to: updatedAuthURL)
        try JSONEncoder().encode(updatedRegistry).write(
            to: registryURL,
            options: Data.WritingOptions.atomic
        )

        await auth.store.refreshSavedAccountRateLimits(accountKey: savedAccount.accountKey)

        let refreshedAccount = try #require(auth.savedAccounts.first)
        #expect(refreshedAccount !== savedAccount)
        #expect(refreshedAccount.email == "updated@example.com")
    }

    @Test func inactiveRateLimitRefreshImmediatelyRefreshesStaleSavedAccountsWhenRuntimeStarts() async throws {
        let environment = try isolatedHomeEnvironment()
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        _ = try saveReviewAccount(
            email: "active@example.com",
            makeActive: true,
            environment: environment,
            registryStore: registryStore
        )
        _ = try saveReviewAccount(
            email: "inactive@example.com",
            makeActive: false,
            environment: environment,
            registryStore: registryStore
        )
        try? FileManager.default.removeItem(at: ReviewHomePaths.reviewAuthURL(environment: environment))

        let clock = ManualTestClock()
        let activeTransport = AuthCapableAppServerSessionTransport(
            rateLimitsReadBehavior: .unsupported
        )
        let activeManager = AuthCapableAppServerManager(authTransport: activeTransport)
        let inactiveTransport = AuthCapableAppServerSessionTransport()
        await inactiveTransport.updateRateLimitsResponse(
            current: [
                "limitId": "codex",
                "primary": [
                    "usedPercent": 77,
                    "windowDurationMins": 300,
                    "resetsAt": 1_735_776_000,
                ],
                "secondary": [
                    "usedPercent": 21,
                    "windowDurationMins": 10080,
                    "resetsAt": 1_736_380_800,
                ],
            ]
        )
        let inactiveManager = AuthCapableAppServerManager(authTransport: inactiveTransport)
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: activeManager,
            sharedAuthSessionFactory: { _ in
                SignedOutReviewAuthSession()
            },
            loginAuthSessionFactory: { _ in
                SignedOutReviewAuthSession()
            },
            probeAppServerManagerFactory: { _ in
                inactiveManager
            },
            rateLimitObservationClock: clock,
            rateLimitStaleRefreshInterval: .seconds(24 * 60 * 60)
        )
        let loadedAccounts = loadRegisteredReviewAccounts(environment: environment)
        let activeAccount = try #require(
            loadedAccounts.accounts.first(where: { $0.accountKey == loadedAccounts.activeAccountKey })
        )
        auth.updateSavedAccounts(loadedAccounts.accounts)
        auth.updateAccount(activeAccount)
        let inactiveAccount = try #require(
            auth.savedAccounts.first(where: { $0.accountKey != activeAccount.accountKey })
        )
        inactiveAccount.updateRateLimitFetchMetadata(
            fetchedAt: Date().addingTimeInterval(-3600),
            error: nil
        )

        await auth.store.reconcileAuthenticatedSession(
            serverIsRunning: true,
            runtimeGeneration: 1
        )

        try await waitForRateLimitsReadCount(inactiveTransport, expectedCount: 1)
        try await waitForMainActorCondition {
            rateLimitWindow(duration: 300, in: inactiveAccount)?.usedPercent == 77
        }

        #expect(await inactiveTransport.rateLimitsReadCount() == 1)
        #expect(rateLimitWindow(duration: 10_080, in: inactiveAccount)?.usedPercent == 21)

        await auth.store.reconcileAuthenticatedSession(
            serverIsRunning: false,
            runtimeGeneration: 1
        )
    }

    @Test func inactiveRateLimitRefreshImmediateCatchUpUsesInjectedClockTime() async throws {
        let environment = try isolatedHomeEnvironment()
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        _ = try saveReviewAccount(
            email: "active@example.com",
            makeActive: true,
            environment: environment,
            registryStore: registryStore
        )
        _ = try saveReviewAccount(
            email: "inactive@example.com",
            makeActive: false,
            environment: environment,
            registryStore: registryStore
        )
        try? FileManager.default.removeItem(at: ReviewHomePaths.reviewAuthURL(environment: environment))

        let clock = ManualTestClock()
        let activeTransport = AuthCapableAppServerSessionTransport(
            rateLimitsReadBehavior: .unsupported
        )
        let activeManager = AuthCapableAppServerManager(authTransport: activeTransport)
        let inactiveTransport = AuthCapableAppServerSessionTransport()
        await inactiveTransport.updateRateLimitsResponse(
            current: [
                "limitId": "codex",
                "primary": [
                    "usedPercent": 61,
                    "windowDurationMins": 300,
                    "resetsAt": 1_735_776_000,
                ],
                "secondary": [
                    "usedPercent": 19,
                    "windowDurationMins": 10080,
                    "resetsAt": 1_736_380_800,
                ],
            ]
        )
        let inactiveManager = AuthCapableAppServerManager(authTransport: inactiveTransport)
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: activeManager,
            sharedAuthSessionFactory: { _ in
                SignedOutReviewAuthSession()
            },
            loginAuthSessionFactory: { _ in
                SignedOutReviewAuthSession()
            },
            probeAppServerManagerFactory: { _ in
                inactiveManager
            },
            rateLimitObservationClock: clock,
            rateLimitStaleRefreshInterval: .seconds(24 * 60 * 60)
        )
        let loadedAccounts = loadRegisteredReviewAccounts(environment: environment)
        let activeAccount = try #require(
            loadedAccounts.accounts.first(where: { $0.accountKey == loadedAccounts.activeAccountKey })
        )
        auth.updateSavedAccounts(loadedAccounts.accounts)
        auth.updateAccount(activeAccount)
        let inactiveAccount = try #require(
            auth.savedAccounts.first(where: { $0.accountKey != activeAccount.accountKey })
        )
        inactiveAccount.updateRateLimitFetchMetadata(
            fetchedAt: Date(),
            error: nil
        )

        clock.advance(by: .seconds(24 * 60 * 60 + 60))

        await auth.store.reconcileAuthenticatedSession(
            serverIsRunning: true,
            runtimeGeneration: 1
        )

        try await waitForRateLimitsReadCount(inactiveTransport, expectedCount: 1)
        try await waitForMainActorCondition {
            rateLimitWindow(duration: 300, in: inactiveAccount)?.usedPercent == 61
        }

        #expect(await inactiveTransport.rateLimitsReadCount() == 1)
        #expect(rateLimitWindow(duration: 10_080, in: inactiveAccount)?.usedPercent == 19)

        await auth.store.reconcileAuthenticatedSession(
            serverIsRunning: false,
            runtimeGeneration: 1
        )
    }

    @Test func inactiveRateLimitRefreshWaitsForIntervalWhenSavedAccountsAreFresh() async throws {
        let environment = try isolatedHomeEnvironment()
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        _ = try saveReviewAccount(
            email: "active@example.com",
            makeActive: true,
            environment: environment,
            registryStore: registryStore
        )
        _ = try saveReviewAccount(
            email: "inactive@example.com",
            makeActive: false,
            environment: environment,
            registryStore: registryStore
        )
        try? FileManager.default.removeItem(at: ReviewHomePaths.reviewAuthURL(environment: environment))

        let clock = ManualTestClock()
        let activeTransport = AuthCapableAppServerSessionTransport(
            rateLimitsReadBehavior: .unsupported
        )
        let activeManager = AuthCapableAppServerManager(authTransport: activeTransport)
        let inactiveTransport = AuthCapableAppServerSessionTransport()
        await inactiveTransport.updateRateLimitsResponse(
            current: [
                "limitId": "codex",
                "primary": [
                    "usedPercent": 66,
                    "windowDurationMins": 300,
                    "resetsAt": 1_735_776_000,
                ],
                "secondary": [
                    "usedPercent": 44,
                    "windowDurationMins": 10080,
                    "resetsAt": 1_736_380_800,
                ],
            ]
        )
        let inactiveManager = AuthCapableAppServerManager(authTransport: inactiveTransport)
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: activeManager,
            sharedAuthSessionFactory: { _ in
                SignedOutReviewAuthSession()
            },
            loginAuthSessionFactory: { _ in
                SignedOutReviewAuthSession()
            },
            probeAppServerManagerFactory: { _ in
                inactiveManager
            },
            rateLimitObservationClock: clock,
            rateLimitStaleRefreshInterval: .seconds(24 * 60 * 60)
        )
        let loadedAccounts = loadRegisteredReviewAccounts(environment: environment)
        let activeAccount = try #require(
            loadedAccounts.accounts.first(where: { $0.accountKey == loadedAccounts.activeAccountKey })
        )
        auth.updateSavedAccounts(loadedAccounts.accounts)
        auth.updateAccount(activeAccount)
        let inactiveAccount = try #require(
            auth.savedAccounts.first(where: { $0.accountKey != activeAccount.accountKey })
        )
        inactiveAccount.updateRateLimitFetchMetadata(
            fetchedAt: Date(),
            error: nil
        )

        await auth.store.reconcileAuthenticatedSession(
            serverIsRunning: true,
            runtimeGeneration: 1
        )
        try await waitForClockSuspension(clock)

        #expect(await inactiveTransport.rateLimitsReadCount() == 0)

        clock.advance(by: .seconds(15 * 60))
        try await waitForRateLimitsReadCount(inactiveTransport, expectedCount: 1)
        try await waitForMainActorCondition {
            rateLimitWindow(duration: 300, in: inactiveAccount)?.usedPercent == 66
        }

        #expect(rateLimitWindow(duration: 10_080, in: inactiveAccount)?.usedPercent == 44)

        await auth.store.reconcileAuthenticatedSession(
            serverIsRunning: false,
            runtimeGeneration: 1
        )
    }

    @Test func inactiveRateLimitRefreshSweepsOnlyInactiveAccounts() async throws {
        let environment = try isolatedHomeEnvironment()
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        _ = try saveReviewAccount(
            email: "active@example.com",
            makeActive: true,
            environment: environment,
            registryStore: registryStore
        )
        _ = try saveReviewAccount(
            email: "inactive-one@example.com",
            makeActive: false,
            environment: environment,
            registryStore: registryStore
        )
        _ = try saveReviewAccount(
            email: "inactive-two@example.com",
            makeActive: false,
            environment: environment,
            registryStore: registryStore
        )
        try? FileManager.default.removeItem(at: ReviewHomePaths.reviewAuthURL(environment: environment))

        let clock = ManualTestClock()
        let activeTransport = AuthCapableAppServerSessionTransport(
            rateLimitsReadBehavior: .unsupported
        )
        let activeManager = AuthCapableAppServerManager(authTransport: activeTransport)
        let inactiveTransport = AuthCapableAppServerSessionTransport()
        await inactiveTransport.updateRateLimitsResponse(
            current: [
                "limitId": "codex",
                "primary": [
                    "usedPercent": 55,
                    "windowDurationMins": 300,
                    "resetsAt": 1_735_776_000,
                ],
                "secondary": [
                    "usedPercent": 33,
                    "windowDurationMins": 10080,
                    "resetsAt": 1_736_380_800,
                ],
            ]
        )
        let inactiveManager = AuthCapableAppServerManager(authTransport: inactiveTransport)
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: activeManager,
            sharedAuthSessionFactory: { _ in
                SignedOutReviewAuthSession()
            },
            loginAuthSessionFactory: { _ in
                SignedOutReviewAuthSession()
            },
            probeAppServerManagerFactory: { _ in
                inactiveManager
            },
            rateLimitObservationClock: clock,
            rateLimitStaleRefreshInterval: .seconds(24 * 60 * 60)
        )
        let loadedAccounts = loadRegisteredReviewAccounts(environment: environment)
        let activeAccount = try #require(
            loadedAccounts.accounts.first(where: { $0.accountKey == loadedAccounts.activeAccountKey })
        )
        auth.updateSavedAccounts(loadedAccounts.accounts)
        auth.updateAccount(activeAccount)
        let inactiveAccounts = auth.savedAccounts.filter { $0.accountKey != activeAccount.accountKey }
        for account in inactiveAccounts {
            account.updateRateLimitFetchMetadata(
                fetchedAt: Date(),
                error: nil
            )
        }

        await auth.store.reconcileAuthenticatedSession(
            serverIsRunning: true,
            runtimeGeneration: 1
        )
        try await waitForClockSuspension(clock)

        clock.advance(by: .seconds(15 * 60))
        try await waitForRateLimitsReadCount(inactiveTransport, expectedCount: 2)
        try await waitForMainActorCondition {
            inactiveAccounts.allSatisfy {
                rateLimitWindow(duration: 300, in: $0)?.usedPercent == 55
            }
        }

        #expect(await inactiveTransport.rateLimitsReadCount() >= 2)

        await auth.store.reconcileAuthenticatedSession(
            serverIsRunning: false,
            runtimeGeneration: 1
        )
    }

    @Test func inactiveRateLimitRefreshRetargetsWhenActiveAccountChanges() async throws {
        let environment = try isolatedHomeEnvironment()
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        _ = try saveReviewAccount(
            email: "active@example.com",
            makeActive: true,
            environment: environment,
            registryStore: registryStore
        )
        _ = try saveReviewAccount(
            email: "next@example.com",
            makeActive: false,
            environment: environment,
            registryStore: registryStore
        )
        _ = try saveReviewAccount(
            email: "other@example.com",
            makeActive: false,
            environment: environment,
            registryStore: registryStore
        )
        try? FileManager.default.removeItem(at: ReviewHomePaths.reviewAuthURL(environment: environment))

        let clock = ManualTestClock()
        let activeTransport = AuthCapableAppServerSessionTransport(
            rateLimitsReadBehavior: .unsupported
        )
        let activeManager = AuthCapableAppServerManager(authTransport: activeTransport)
        let inactiveTransport = AuthCapableAppServerSessionTransport()
        await inactiveTransport.updateRateLimitsResponse(
            current: [
                "limitId": "codex",
                "primary": [
                    "usedPercent": 88,
                    "windowDurationMins": 300,
                    "resetsAt": 1_735_776_000,
                ],
                "secondary": [
                    "usedPercent": 61,
                    "windowDurationMins": 10080,
                    "resetsAt": 1_736_380_800,
                ],
            ]
        )
        let inactiveManager = AuthCapableAppServerManager(authTransport: inactiveTransport)
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: activeManager,
            sharedAuthSessionFactory: { _ in
                SignedOutReviewAuthSession()
            },
            loginAuthSessionFactory: { _ in
                SignedOutReviewAuthSession()
            },
            probeAppServerManagerFactory: { _ in
                inactiveManager
            },
            rateLimitObservationClock: clock,
            rateLimitStaleRefreshInterval: .seconds(24 * 60 * 60)
        )
        let loadedAccounts = loadRegisteredReviewAccounts(environment: environment)
        let initialActiveAccount = try #require(
            loadedAccounts.accounts.first(where: { $0.accountKey == loadedAccounts.activeAccountKey })
        )
        auth.updateSavedAccounts(loadedAccounts.accounts)
        auth.updateAccount(initialActiveAccount)
        for account in auth.savedAccounts where account.accountKey != initialActiveAccount.accountKey {
            account.updateRateLimitFetchMetadata(
                fetchedAt: Date(),
                error: nil
            )
        }

        await auth.store.reconcileAuthenticatedSession(
            serverIsRunning: true,
            runtimeGeneration: 1
        )
        try await waitForClockSuspension(clock)

        let newActiveAccount = try #require(
            auth.savedAccounts.first(where: { $0.email == "next@example.com" })
        )
        auth.updateAccount(newActiveAccount)
        await auth.store.reconcileAuthenticatedSession(
            serverIsRunning: true,
            runtimeGeneration: 2
        )
        try await waitForClockSuspension(clock)

        clock.advance(by: .seconds(15 * 60))
        try await waitForRateLimitsReadCount(inactiveTransport, expectedCount: 2)
        try await waitForMainActorCondition {
            let otherAccount = auth.savedAccounts.first(where: { $0.email == "other@example.com" })
            return rateLimitWindow(duration: 300, in: initialActiveAccount)?.usedPercent == 88
                && rateLimitWindow(duration: 300, in: otherAccount)?.usedPercent == 88
        }

        #expect(rateLimitWindow(duration: 300, in: newActiveAccount) == nil)
        #expect(await inactiveTransport.rateLimitsReadCount() >= 2)

        await auth.store.reconcileAuthenticatedSession(
            serverIsRunning: false,
            runtimeGeneration: 2
        )
    }

    @Test func inactiveRateLimitRefreshStopsWhenRuntimeDetaches() async throws {
        let environment = try isolatedHomeEnvironment()
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        _ = try saveReviewAccount(
            email: "active@example.com",
            makeActive: true,
            environment: environment,
            registryStore: registryStore
        )
        _ = try saveReviewAccount(
            email: "inactive@example.com",
            makeActive: false,
            environment: environment,
            registryStore: registryStore
        )
        try? FileManager.default.removeItem(at: ReviewHomePaths.reviewAuthURL(environment: environment))

        let clock = ManualTestClock()
        let activeTransport = AuthCapableAppServerSessionTransport(
            rateLimitsReadBehavior: .unsupported
        )
        let activeManager = AuthCapableAppServerManager(authTransport: activeTransport)
        let inactiveTransport = AuthCapableAppServerSessionTransport()
        let inactiveManager = AuthCapableAppServerManager(authTransport: inactiveTransport)
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: activeManager,
            sharedAuthSessionFactory: { _ in
                SignedOutReviewAuthSession()
            },
            loginAuthSessionFactory: { _ in
                SignedOutReviewAuthSession()
            },
            probeAppServerManagerFactory: { _ in
                inactiveManager
            },
            rateLimitObservationClock: clock,
            rateLimitStaleRefreshInterval: .seconds(24 * 60 * 60)
        )
        let loadedAccounts = loadRegisteredReviewAccounts(environment: environment)
        let activeAccount = try #require(
            loadedAccounts.accounts.first(where: { $0.accountKey == loadedAccounts.activeAccountKey })
        )
        auth.updateSavedAccounts(loadedAccounts.accounts)
        auth.updateAccount(activeAccount)
        let inactiveAccount = try #require(
            auth.savedAccounts.first(where: { $0.accountKey != activeAccount.accountKey })
        )
        inactiveAccount.updateRateLimitFetchMetadata(
            fetchedAt: Date(),
            error: nil
        )

        await auth.store.reconcileAuthenticatedSession(
            serverIsRunning: true,
            runtimeGeneration: 1
        )
        try await waitForClockSuspension(clock)

        await auth.store.reconcileAuthenticatedSession(
            serverIsRunning: false,
            runtimeGeneration: 1
        )
        clock.advance(by: .seconds(15 * 60))
        await Task.yield()

        #expect(await inactiveTransport.rateLimitsReadCount() == 0)
    }

    @Test func inactiveRateLimitRefreshPreservesUnsavedCurrentSession() async throws {
        let environment = try isolatedHomeEnvironment()
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        _ = try saveReviewAccount(
            email: "saved@example.com",
            makeActive: false,
            environment: environment,
            registryStore: registryStore
        )
        try? FileManager.default.removeItem(at: ReviewHomePaths.reviewAuthURL(environment: environment))

        let clock = ManualTestClock()
        let activeTransport = AuthCapableAppServerSessionTransport(
            rateLimitsReadBehavior: .unsupported
        )
        let activeManager = AuthCapableAppServerManager(authTransport: activeTransport)
        let inactiveTransport = AuthCapableAppServerSessionTransport()
        await inactiveTransport.updateRateLimitsResponse(
            current: [
                "limitId": "codex",
                "primary": [
                    "usedPercent": 58,
                    "windowDurationMins": 300,
                    "resetsAt": 1_735_776_000,
                ],
                "secondary": [
                    "usedPercent": 34,
                    "windowDurationMins": 10080,
                    "resetsAt": 1_736_380_800,
                ],
            ]
        )
        let inactiveManager = AuthCapableAppServerManager(authTransport: inactiveTransport)
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: activeManager,
            sharedAuthSessionFactory: { _ in
                SignedOutReviewAuthSession()
            },
            loginAuthSessionFactory: { _ in
                SignedOutReviewAuthSession()
            },
            probeAppServerManagerFactory: { _ in
                inactiveManager
            },
            rateLimitObservationClock: clock,
            rateLimitStaleRefreshInterval: .seconds(24 * 60 * 60)
        )
        auth.updateSavedAccounts(loadRegisteredReviewAccounts(environment: environment).accounts)
        let currentAccount = CodexAccount(
            email: "current@example.com",
            planType: "pro"
        )
        auth.updateAccount(currentAccount)
        let savedAccount = try #require(auth.savedAccounts.first)
        savedAccount.updateRateLimitFetchMetadata(
            fetchedAt: Date(),
            error: nil
        )

        await auth.store.reconcileAuthenticatedSession(
            serverIsRunning: true,
            runtimeGeneration: 1
        )
        try await waitForClockSuspension(clock)

        clock.advance(by: .seconds(15 * 60))
        try await waitForRateLimitsReadCount(inactiveTransport, expectedCount: 1)
        try await waitForMainActorCondition {
            rateLimitWindow(duration: 300, in: savedAccount)?.usedPercent == 58
        }

        #expect(auth.account?.email == "current@example.com")
        #expect(rateLimitWindow(duration: 10_080, in: savedAccount)?.usedPercent == 34)

        await auth.store.reconcileAuthenticatedSession(
            serverIsRunning: false,
            runtimeGeneration: 1
        )
    }

    @Test func startingStoreKeepsSeededAuthWhenBackgroundRefreshFails() async throws {
        let environment = try isolatedHomeEnvironment()
        let manager = MockAppServerManager { _ in .success() }
        let authSession = FailingReadAccountReviewAuthSession(message: "refresh failed")
        let store = CodexReviewStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            authSessionFactory: {
                authSession
            }
        )
        let authStateProbe = ObservableValueProbe { testAuthState(from: store.auth) }
        defer { authStateProbe.cancel() }

        applyTestAuthState(auth: store.auth, state: .signedIn(accountID: "review@example.com"))
        await store.start()
        defer { Task { await store.stop() } }

        try await waitForObservedValue(authStateProbe) {
            $0 == .failed(
                "refresh failed",
                isAuthenticated: true,
                accountID: "review@example.com"
            )
        }

        await store.stop()
    }

    @Test func startingStoreReconcilesRateLimitObservationWhenSeededAuthRefreshFails() async throws {
        let environment = try isolatedHomeEnvironment()
        let manager = AuthCapableAppServerManager()
        let authSession = FailingReadAccountReviewAuthSession(message: "refresh failed")
        let store = CodexReviewStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            authSessionFactory: {
                authSession
            }
        )
        let authStateProbe = ObservableValueProbe { testAuthState(from: store.auth) }
        let fiveHourProbe = ObservableValueProbe { rateLimitWindow(duration: 300, in: store.auth.account)?.usedPercent }
        defer { authStateProbe.cancel() }
        defer { fiveHourProbe.cancel() }

        applyTestAuthState(auth: store.auth, state: .signedIn(accountID: "review@example.com"))
        await store.start()
        defer { Task { await store.stop() } }

        try await waitForObservedValue(authStateProbe) {
            $0 == .failed(
                "refresh failed",
                isAuthenticated: true,
                accountID: "review@example.com"
            )
        }
        try await waitForObservedValue(fiveHourProbe) {
            $0 == 40
        }

        #expect(rateLimitWindow(duration: 300, in: store.auth.account)?.usedPercent == 40)
        #expect(rateLimitWindow(duration: 10_080, in: store.auth.account)?.usedPercent == 20)

        await store.stop()
    }

    @Test func cancelAuthenticationClosesStateWithoutStartingAnotherAuthSession() async throws {
        let environment = try isolatedHomeEnvironment()
        let authSession = BlockingLoginReviewAuthSession()
        let authFactory = CountingReviewAuthSessionFactory(session: authSession)
        let store = makeInjectedAuthSessionStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: MockAppServerManager { _ in .success() },
            authSessionFactory: {
                try await authFactory.makeSession()
            }
        )

        let beginTask = Task {
            await store.signIn()
        }

        await authSession.waitForLoginStart()

        await store.cancelAuthentication()
        _ = await beginTask.value

        #expect(testAuthState(from: store.auth) == .signedOut)
        #expect(await authFactory.creationCount() == 1)
        #expect(await authSession.cancelledLoginIDs() == ["login-browser"])
    }

    @Test func cancelAuthenticationPreservesExistingWarningMessage() async throws {
        let environment = try isolatedHomeEnvironment()
        let authSession = BlockingLoginReviewAuthSession()
        let authFactory = CountingReviewAuthSessionFactory(session: authSession)
        let store = makeInjectedAuthSessionStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: MockAppServerManager { _ in .success() },
            authSessionFactory: {
                try await authFactory.makeSession()
            }
        )
        applyTestAuthState(auth: store.auth, state: .signedIn(accountID: "review@example.com"))
        store.auth.updateWarning(message: "Cancellation failed.")

        let beginTask = Task {
            await store.signIn()
        }

        await authSession.waitForLoginStart()
        await store.cancelAuthentication()
        _ = await beginTask.value

        #expect(store.auth.warningMessage == "Cancellation failed.")
    }

    @Test func cancelAuthenticationRemovesPreparedLoginProbeHome() async throws {
        let environment = try isolatedHomeEnvironment()
        let authSession = BlockingLoginReviewAuthSession()
        let authFactory = CountingReviewAuthSessionFactory(session: authSession)
        let store = makeInjectedAuthSessionStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: MockAppServerManager { _ in .success() },
            authSessionFactory: {
                try await authFactory.makeSession()
            }
        )

        let beginTask = Task {
            await store.signIn()
        }

        await authSession.waitForLoginStart()
        await store.cancelAuthentication()
        _ = await beginTask.value

        let probeRootURL = ReviewHomePaths.makeProbeRootURL(environment: environment)
        let remainingProbeEntries = (try? FileManager.default.contentsOfDirectory(
            at: probeRootURL,
            includingPropertiesForKeys: nil
        )) ?? []
        #expect(remainingProbeEntries.isEmpty)
    }

    @Test func performPrimaryAuthenticationActionBeginsAuthenticationWhenSignedOutAndServerRunning() async {
        let backend = PrimaryAuthenticationStoreBackend()
        let store = CodexReviewStore.makeTestingStore(harness: backend)
        store.loadForTesting(
            serverState: .running,
            authPhase: .signedOut,
            workspaces: []
        )

        await store.performPrimaryAuthenticationAction()

        #expect(backend.recordedActions() == ["begin"])
    }

    @Test func performPrimaryAuthenticationActionCancelsAuthenticationWhenAuthenticating() async {
        let backend = PrimaryAuthenticationStoreBackend()
        let store = CodexReviewStore.makeTestingStore(harness: backend)
        store.loadForTesting(
            serverState: .running,
            authPhase: .signingIn(
                .init(
                    title: "Sign in with ChatGPT",
                    detail: "Open the browser to continue."
                )
            ),
            workspaces: []
        )

        await store.performPrimaryAuthenticationAction()

        #expect(backend.recordedActions() == ["cancel"])
    }

    @Test func performPrimaryAuthenticationActionRestartsFailedServerBeforeBeginningAuthentication() async {
        let backend = PrimaryAuthenticationStoreBackend(
            restartResultingServerState: .running
        )
        let store = CodexReviewStore.makeTestingStore(harness: backend)
        store.loadForTesting(
            serverState: .failed("The embedded server stopped responding."),
            authPhase: .signedOut,
            workspaces: []
        )

        await store.performPrimaryAuthenticationAction()

        #expect(backend.recordedActions() == ["start", "begin"])
        #expect(store.serverState == .running)
    }

    @Test func performPrimaryAuthenticationActionRestartsStoppedServerBeforeBeginningAuthentication() async {
        let backend = PrimaryAuthenticationStoreBackend(
            restartResultingServerState: .running
        )
        let store = CodexReviewStore.makeTestingStore(harness: backend)
        store.loadForTesting(
            serverState: .stopped,
            authPhase: .signedOut,
            workspaces: []
        )

        await store.performPrimaryAuthenticationAction()

        #expect(backend.recordedActions() == ["start", "begin"])
        #expect(store.serverState == .running)
    }

    @Test func performPrimaryAuthenticationActionBeginsAuthenticationEvenWhenRestartFails() async {
        let backend = PrimaryAuthenticationStoreBackend(
            restartResultingServerState: .failed("Still unavailable.")
        )
        let store = CodexReviewStore.makeTestingStore(harness: backend)
        store.loadForTesting(
            serverState: .failed("The embedded server stopped responding."),
            authPhase: .signedOut,
            workspaces: []
        )

        await store.performPrimaryAuthenticationAction()

        #expect(backend.recordedActions() == ["start", "begin"])
        #expect(store.serverState == .failed("Still unavailable."))
    }

    @Test func switchingAccountFailureClearsProgressStateAndPreservesActiveAccount() async {
        let backend = AccountActionStoreBackend(
            switchStartsBlocked: true,
            switchErrorMessage: "Switch failed."
        )
        let store = CodexReviewStore.makeTestingStore(harness: backend)
        let firstAccount = CodexAccount(email: "first@example.com", planType: "pro")
        let secondAccount = CodexAccount(email: "second@example.com", planType: "plus")
        store.auth.updateSavedAccounts([firstAccount, secondAccount])
        store.auth.updateAccount(firstAccount)

        let switchTask = Task {
            try await store.switchAccount(secondAccount)
        }

        await backend.waitForSwitchAccountStartCallCount(1)
        #expect(
            store.auth.savedAccounts.contains(
                where: { $0.accountKey == secondAccount.accountKey && $0.isSwitching }
            )
        )

        await backend.releaseSwitchAccount()
        await #expect(throws: Error.self) {
            try await switchTask.value
        }

        #expect(store.auth.savedAccounts.contains(where: { $0.isSwitching }) == false)
        #expect(store.auth.account?.accountKey == firstAccount.accountKey)
    }

    @Test func metadataOnlySwitchDoesNotPresentRunningJobsConfirmation() async {
        let backend = AccountActionStoreBackend()
        let store = CodexReviewStore.makeTestingStore(harness: backend)
        let activeSavedAccount = CodexAccount(email: "saved@example.com", planType: "pro")
        activeSavedAccount.updateIsActive(true)
        let currentSavedAccount = CodexAccount(email: "current@example.com", planType: "plus")
        let currentSession = CodexAccount(email: "current@example.com", planType: "plus")
        let runningJob = makeStoreTestJob(status: .running, targetSummary: "Uncommitted changes")
        store.loadForTesting(
            serverState: .running,
            authPhase: .signedOut,
            account: currentSession,
            savedAccounts: [activeSavedAccount, currentSavedAccount],
            workspaces: makeStoreTestWorkspaces(from: [runningJob])
        )

        store.requestSwitchAccount(
            currentSavedAccount,
            requiresConfirmation: store.hasRunningJobs
                && store.auth.account?.accountKey != currentSavedAccount.accountKey
        )
        await backend.waitForSwitchAccountCallCount(1)

        #expect(store.auth.pendingAccountAction == nil)
        #expect(backend.lastSwitchedAccountKey() == currentSavedAccount.accountKey)
    }

    @Test func persistedActiveCurrentRecoverySwitchStillDelegatesToController() async throws {
        let backend = AccountActionStoreBackend()
        backend.requiresCurrentSessionRecovery = true
        let store = CodexReviewStore.makeTestingStore(harness: backend)
        let currentAccount = CodexAccount(email: "current@example.com", planType: "plus")
        currentAccount.updateIsActive(true)
        store.loadForTesting(
            serverState: .running,
            authPhase: .failed(message: "Authentication required."),
            account: currentAccount,
            savedAccounts: [currentAccount],
            workspaces: []
        )

        try await store.switchAccount(currentAccount)

        #expect(backend.lastSwitchedAccountKey() == currentAccount.accountKey)
    }

    @Test func sameAccountRecoverySwitchUsesRunningJobsConfirmation() async {
        let backend = AccountActionStoreBackend()
        backend.requiresCurrentSessionRecovery = true
        let store = CodexReviewStore.makeTestingStore(harness: backend)
        let currentAccount = CodexAccount(email: "current@example.com", planType: "plus")
        currentAccount.updateIsActive(true)
        let runningJob = makeStoreTestJob(status: .running, targetSummary: "Uncommitted changes")
        store.loadForTesting(
            serverState: .running,
            authPhase: .failed(message: "Authentication required."),
            account: currentAccount,
            savedAccounts: [currentAccount],
            workspaces: makeStoreTestWorkspaces(from: [runningJob])
        )

        store.requestSwitchAccount(
            currentAccount,
            requiresConfirmation: store.hasRunningJobs
                && store.switchActionRequiresRunningJobsConfirmation(for: currentAccount)
        )

        #expect(store.auth.pendingAccountAction == .switchAccount(accountKey: currentAccount.accountKey))
        #expect(backend.switchAccountCallCount() == 0)

        store.confirmPendingAccountAction()
        await backend.waitForSwitchAccountCallCount(1)

        #expect(backend.lastSwitchedAccountKey() == currentAccount.accountKey)
    }

    @Test func inactiveSavedCurrentRecoverySwitchUsesRunningJobsConfirmation() async {
        let backend = AccountActionStoreBackend()
        backend.requiresCurrentSessionRecovery = true
        let store = CodexReviewStore.makeTestingStore(harness: backend)
        let activeSavedAccount = CodexAccount(email: "saved@example.com", planType: "pro")
        activeSavedAccount.updateIsActive(true)
        let currentSavedAccount = CodexAccount(email: "current@example.com", planType: "plus")
        let runningJob = makeStoreTestJob(status: .running, targetSummary: "Uncommitted changes")
        store.loadForTesting(
            serverState: .running,
            authPhase: .failed(message: "Authentication required."),
            account: currentSavedAccount,
            savedAccounts: [activeSavedAccount, currentSavedAccount],
            workspaces: makeStoreTestWorkspaces(from: [runningJob])
        )

        store.requestSwitchAccount(
            currentSavedAccount,
            requiresConfirmation: store.hasRunningJobs
                && store.switchActionRequiresRunningJobsConfirmation(for: currentSavedAccount)
        )

        #expect(store.auth.pendingAccountAction == .switchAccount(accountKey: currentSavedAccount.accountKey))
        #expect(backend.switchAccountCallCount() == 0)
    }

    @Test func accountActionAlertUsesOptionalPayloadState() {
        let store = CodexReviewStore.makePreviewStore()

        store.auth.presentAccountActionAlert(
            title: "Failed to Reorder Accounts",
            message: "  Request failed.  "
        )

        #expect(store.auth.accountActionAlert != nil)
        #expect(store.auth.accountActionAlert?.message == "Request failed.")

        store.dismissAccountActionAlert()

        #expect(store.auth.accountActionAlert == nil)
    }

    @Test func detachedCurrentSessionCannotRequestNoOpSwitch() {
        let backend = AccountActionStoreBackend()
        let store = CodexReviewStore.makeTestingStore(harness: backend)
        let activeSavedAccount = CodexAccount(email: "saved@example.com", planType: "pro")
        activeSavedAccount.updateIsActive(true)
        let detachedCurrent = CodexAccount(email: "current@example.com", planType: "plus")
        store.loadForTesting(
            serverState: .running,
            authPhase: .signedOut,
            account: detachedCurrent,
            savedAccounts: [activeSavedAccount],
            workspaces: []
        )

        #expect(store.switchActionIsDisabled(for: detachedCurrent))
    }

    @Test func signInIgnoresConcurrentRetryWhileLoginIsInProgress() async throws {
        let environment = try isolatedHomeEnvironment()
        let authSession = BlockingLoginReviewAuthSession()
        let authFactory = CountingReviewAuthSessionFactory(session: authSession)
        let store = makeInjectedAuthSessionStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: MockAppServerManager { _ in .success() },
            authSessionFactory: {
                try await authFactory.makeSession()
            }
        )

        let firstBeginTask = Task {
            await store.signIn()
        }

        await authSession.waitForLoginStart()

        let secondBeginTask = Task {
            await store.signIn()
        }
        _ = await secondBeginTask.value

        #expect(await authFactory.creationCount() == 1)

        await store.cancelAuthentication()
        _ = await firstBeginTask.value
        #expect(await authSession.cancelledLoginIDs() == ["login-browser"])
    }

    @Test func cancelAuthenticationPreservesAuthenticatedRetryState() async throws {
        let environment = try isolatedHomeEnvironment()
        let authSession = BlockingLoginReviewAuthSession()
        let authFactory = CountingReviewAuthSessionFactory(session: authSession)
        let store = makeInjectedAuthSessionStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: MockAppServerManager { _ in .success() },
            authSessionFactory: {
                try await authFactory.makeSession()
            }
        )
        applyTestAuthState(auth: store.auth, state: 
            .failed(
                "Authentication failed.",
                isAuthenticated: true,
                accountID: "review@example.com"
            )
        )

        let beginTask = Task {
            await store.signIn()
        }

        await authSession.waitForLoginStart()

        await store.cancelAuthentication()
        _ = await beginTask.value

        #expect(
            testAuthState(from: store.auth) == .failed(
                "Authentication failed.",
                isAuthenticated: true,
                accountID: "review@example.com"
            )
        )
        #expect(await authFactory.creationCount() == 1)
        #expect(await authSession.cancelledLoginIDs() == ["login-browser"])
    }

    @Test func signInWithSavedAccountsActivatesAuthenticatedAccountFromFailedState() async throws {
        let environment = try isolatedHomeEnvironment()
        try writeReviewAuthSnapshot(
            email: "stale@example.com",
            planType: "pro",
            environment: environment
        )
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        _ = try registryStore.saveSharedAuthAsSavedAccount(makeActive: true)

        let sharedSession = SuccessfulLoginReviewAuthSession()
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                sharedSession
            },
            loginAuthSessionFactory: { environment in
                PersistingReviewAuthSession(
                    base: sharedSession,
                    environment: environment
                )
            }
        )
        let initialAccounts = loadRegisteredReviewAccounts(environment: environment)
        auth.updateSavedAccounts(initialAccounts.accounts)
        auth.updateAccount(initialAccounts.accounts.first(where: { $0.accountKey == initialAccounts.activeAccountKey }))
        auth.updatePhase(.failed(message: "Authentication failed."))

        await auth.store.signIn()

        let loadedAccounts = loadRegisteredReviewAccounts(environment: environment)
        #expect(testAuthState(from: auth) == .signedIn(accountID: "review@example.com"))
        #expect(auth.savedAccounts.first(where: \.isActive)?.email == "review@example.com")
        #expect(auth.savedAccounts.map(\.email) == ["stale@example.com", "review@example.com"])
        #expect(loadedAccounts.activeAccountKey == "review@example.com")
    }

    @Test func logoutDuringAuthenticatedRetryCancelsLoginAndSignsOut() async throws {
        let environment = try isolatedHomeEnvironment()
        let authSession = BlockingLoginReviewAuthSession()
        let authFactory = CountingReviewAuthSessionFactory(session: authSession)
        let manager = AuthCapableAppServerManager()
        let store = makeInjectedAuthSessionStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            authSessionFactory: {
                try await authFactory.makeSession()
            }
        )
        await store.start()
        defer { Task { await store.stop() } }
        applyTestAuthState(auth: store.auth, state: .signedIn(accountID: "review@example.com"))

        let beginTask = Task {
            await store.signIn()
        }

        await authSession.waitForLoginStart()

        await store.logout()
        _ = await beginTask.value

        #expect(testAuthState(from: store.auth) == .signedOut)
        #expect(await authSession.cancelledLoginIDs() == ["login-browser"])
        #expect(await manager.prepareCount() == 2)
        #expect(await manager.shutdownCount() == 1)

        await store.stop()
    }

    @Test func logoutDuringAuthenticatedRetryStaysSignedOutAfterDelayedCancellationCompletion() async throws {
        let environment = try isolatedHomeEnvironment()
        let authSession = DeferredCloseLoginReviewAuthSession()
        let manager = AuthCapableAppServerManager()
        let store = makeInjectedAuthSessionStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            authSessionFactory: {
                authSession
            }
        )
        await store.start()
        defer { Task { await store.stop() } }
        applyTestAuthState(auth: store.auth, state: .signedIn(accountID: "review@example.com"))

        let beginTask = Task {
            await store.signIn()
        }

        await authSession.waitForLoginStart()

        let logoutTask = Task {
            await store.logout()
        }
        await authSession.waitForCloseRequest()
        _ = await logoutTask.value

        await authSession.finishPendingClose()
        _ = await beginTask.value

        #expect(testAuthState(from: store.auth) == .signedOut)
        #expect(await authSession.cancelledLoginIDs() == ["login-browser"])
        try await withTestTimeout {
            while true {
                let prepareCount = await manager.prepareCount()
                let shutdownCount = await manager.shutdownCount()
                if prepareCount == 2, shutdownCount == 1 {
                    return
                }
                await Task.yield()
            }
        }

        await store.stop()
    }

    @Test func signOutRemovesSavedAccount() async throws {
        let environment = try isolatedHomeEnvironment()
        try writeReviewAuthSnapshot(
            email: "review@example.com",
            planType: "pro",
            environment: environment
        )
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        _ = try registryStore.saveSharedAuthAsSavedAccount(makeActive: true)
        let sharedSession = SuccessfulLogoutReviewAuthSession()
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                sharedSession
            },
            loginAuthSessionFactory: { _ in
                sharedSession
            }
        )
        let initialAccounts = loadRegisteredReviewAccounts(environment: environment)
        let savedAccountKey = try #require(initialAccounts.activeAccountKey)
        auth.updateSavedAccounts(initialAccounts.accounts)
        auth.updateAccount(initialAccounts.accounts.first(where: { $0.accountKey == initialAccounts.activeAccountKey }))

        try await auth.store.signOutActiveAccount()

        let loadedAccounts = loadRegisteredReviewAccounts(environment: environment)
        #expect(testAuthState(from: auth) == .signedOut)
        #expect(loadedAccounts.activeAccountKey == nil)
        #expect(loadedAccounts.accounts.isEmpty)
        #expect(
            FileManager.default.fileExists(
                atPath: ReviewHomePaths.savedAccountAuthURL(
                    accountKey: savedAccountKey,
                    environment: environment
                ).path
            ) == false
        )
    }

    @Test func signOutSavedActiveAccountDoesNotPromoteFallbackSavedAccount() async throws {
        let environment = try isolatedHomeEnvironment()
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        try writeReviewAuthSnapshot(
            email: "active@example.com",
            planType: "pro",
            environment: environment
        )
        _ = try registryStore.saveSharedAuthAsSavedAccount(makeActive: true)
        try writeReviewAuthSnapshot(
            email: "other@example.com",
            planType: "pro",
            environment: environment
        )
        _ = try registryStore.saveSharedAuthAsSavedAccount(makeActive: false)
        try writeReviewAuthSnapshot(
            email: "active@example.com",
            planType: "pro",
            environment: environment
        )

        let sharedSession = SuccessfulLogoutReviewAuthSession()
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                sharedSession
            },
            loginAuthSessionFactory: { _ in
                sharedSession
            }
        )
        let initialAccounts = loadRegisteredReviewAccounts(environment: environment)
        auth.updateSavedAccounts(initialAccounts.accounts)
        auth.updateAccount(initialAccounts.accounts.first(where: { $0.accountKey == initialAccounts.activeAccountKey }))

        try await auth.store.signOutActiveAccount()

        let loadedAccounts = loadRegisteredReviewAccounts(environment: environment)
        #expect(testAuthState(from: auth) == .signedOut)
        #expect(auth.account == nil)
        #expect(auth.savedAccounts.map(\.email) == ["other@example.com"])
        #expect(loadedAccounts.activeAccountKey == nil)
        #expect(loadedAccounts.accounts.map(\.email) == ["other@example.com"])
        #expect(loadSharedReviewAccount(environment: environment) == nil)
    }

    @Test func signOutSavedInactiveCurrentPreservesSavedSnapshot() async throws {
        let environment = try isolatedHomeEnvironment()
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        _ = try saveReviewAccount(
            email: "active@example.com",
            makeActive: true,
            environment: environment,
            registryStore: registryStore
        )
        let currentSavedAccount = try saveReviewAccount(
            email: "review@example.com",
            makeActive: false,
            environment: environment,
            registryStore: registryStore
        )
        try writeReviewAuthSnapshot(
            email: "review@example.com",
            planType: "pro",
            environment: environment
        )

        let sharedSession = SuccessfulLogoutReviewAuthSession()
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                sharedSession
            },
            loginAuthSessionFactory: { _ in
                sharedSession
            }
        )
        auth.updateSavedAccounts(loadRegisteredReviewAccounts(environment: environment).accounts)
        auth.updateAccount(currentSavedAccount)

        try await auth.store.signOutActiveAccount()

        let loadedAccounts = loadRegisteredReviewAccounts(environment: environment)
        #expect(testAuthState(from: auth) == .signedOut)
        #expect(auth.account == nil)
        #expect(auth.savedAccounts.map(\.email) == ["active@example.com", "review@example.com"])
        #expect(auth.savedAccounts.first(where: \.isActive)?.email == "active@example.com")
        #expect(loadedAccounts.activeAccountKey == "active@example.com")
        #expect(
            FileManager.default.fileExists(
                atPath: ReviewHomePaths.savedAccountAuthURL(
                    accountKey: currentSavedAccount.accountKey,
                    environment: environment
                ).path
            )
        )
        #expect(loadSharedReviewAccount(environment: environment) == nil)

        await auth.store.refreshAuthentication()

        let refreshedAccounts = loadRegisteredReviewAccounts(environment: environment)
        #expect(testAuthState(from: auth) == .signedOut)
        #expect(auth.savedAccounts.map(\.email) == ["active@example.com", "review@example.com"])
        #expect(auth.savedAccounts.first(where: \.isActive)?.email == "active@example.com")
        #expect(refreshedAccounts.activeAccountKey == "active@example.com")
    }

    @Test func signOutUnsavedCurrentAccountRemovesSharedAuthSnapshot() async throws {
        let environment = try isolatedHomeEnvironment()
        try writeReviewAuthSnapshot(
            email: "review@example.com",
            planType: "pro",
            environment: environment
        )
        let sharedSession = SuccessfulLogoutReviewAuthSession()
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                sharedSession
            },
            loginAuthSessionFactory: { _ in
                sharedSession
            }
        )
        let currentAccount = CodexAccount(
            email: "review@example.com",
            planType: "pro"
        )
        auth.updateSavedAccounts([])
        auth.updatePhase(.signedOut)
        auth.updateAccount(currentAccount)

        try await auth.store.signOutActiveAccount()

        #expect(auth.account == nil)
        #expect(
            FileManager.default.fileExists(
                atPath: ReviewHomePaths.reviewAuthURL(environment: environment).path
            ) == false
        )
    }

    @Test func refreshKeepsUnsavedAuthenticatedSessionOutOfSavedAccounts() async throws {
        let environment = try isolatedHomeEnvironment()
        let sharedSession = ImmediateReadAccountReviewAuthSession(
            response: .init(
                account: .chatGPT(email: "review@example.com", planType: "pro"),
                requiresOpenAIAuth: false
            )
        )
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                sharedSession
            },
            loginAuthSessionFactory: { _ in
                sharedSession
            }
        )

        await auth.store.refreshAuthentication()

        #expect(auth.account?.email == "review@example.com")
        #expect(auth.savedAccounts.isEmpty)
    }

    @Test func refreshPreservesPersistedActiveSelectionForDetachedCurrentSession() async throws {
        let environment = try isolatedHomeEnvironment()
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        _ = try saveReviewAccount(
            email: "saved@example.com",
            makeActive: true,
            environment: environment,
            registryStore: registryStore
        )
        let currentSavedAccount = try saveReviewAccount(
            email: "review@example.com",
            makeActive: false,
            environment: environment,
            registryStore: registryStore
        )
        try writeReviewAuthSnapshot(
            email: "review@example.com",
            planType: "pro",
            environment: environment
        )

        let sharedSession = ImmediateReadAccountReviewAuthSession(
            response: .init(
                account: .chatGPT(email: "review@example.com", planType: "pro"),
                requiresOpenAIAuth: false
            )
        )
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                sharedSession
            },
            loginAuthSessionFactory: { _ in
                sharedSession
            }
        )
        auth.updateSavedAccounts(loadRegisteredReviewAccounts(environment: environment).accounts)
        auth.updateAccount(currentSavedAccount)

        await auth.store.refreshAuthentication()

        let loadedAccounts = loadRegisteredReviewAccounts(environment: environment)
        #expect(auth.account?.email == "review@example.com")
        #expect(auth.savedAccounts.first(where: \.isActive)?.email == "saved@example.com")
        #expect(loadedAccounts.activeAccountKey == "saved@example.com")
        #expect(loadSharedReviewAccount(environment: environment)?.email == "review@example.com")
    }

    @Test func failedInitialAuthenticationPersistenceDoesNotCancelRunningJobs() async throws {
        let environment = try isolatedHomeEnvironment()
        let loginSession = NonPersistentSuccessfulLoginReviewAuthSession()
        let sharedSession = SignedOutReviewAuthSession()
        var cancelCallCount = 0
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                sharedSession
            },
            loginAuthSessionFactory: { environment in
                PersistingReviewAuthSession(
                    base: loginSession,
                    environment: environment
                )
            },
            cancelRunningJobs: { _ in
                cancelCallCount += 1
            }
        )

        await auth.store.signIn()

        #expect(testAuthState(from: auth) == .failed(reviewAuthPersistenceFailureMessage))
        #expect(cancelCallCount == 0)
    }

    @Test func refreshSameEmailDoesNotRecycleSharedAppServerWhenSavedIdentityReplacesUnsavedAccount() async throws {
        let environment = try isolatedHomeEnvironment()
        let manager = AuthCapableAppServerManager()
        let authSession = ImmediateReadAccountReviewAuthSession(
            response: .init(
                account: .chatGPT(email: "review@example.com", planType: "pro"),
                requiresOpenAIAuth: false
            )
        )
        let store = makeInjectedAuthSessionStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            authSessionFactory: {
                authSession
            }
        )
        store.auth.updateSavedAccounts([])
        store.auth.updatePhase(.signedOut)
        store.auth.updateAccount(
            CodexAccount(
                email: "review@example.com",
                planType: "pro"
            )
        )

        await store.start()
        defer { Task { await store.stop() } }
        try await waitForMainActorCondition {
            store.auth.savedAccounts.map(\.email) == ["review@example.com"]
        }

        #expect(store.auth.account?.email == "review@example.com")
        #expect(await manager.prepareCount() == 1)
        #expect(await manager.shutdownCount() == 0)

        await store.stop()
    }

    @Test func recoveredSignOutCancelsRunningJobs() async throws {
        let environment = try isolatedHomeEnvironment()
        try writeReviewAuthSnapshot(
            email: "review@example.com",
            planType: "pro",
            environment: environment
        )
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        _ = try registryStore.saveSharedAuthAsSavedAccount(makeActive: true)
        let sharedSession = FailingLogoutReviewAuthSession()
        var cancelCallCount = 0
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                sharedSession
            },
            loginAuthSessionFactory: { _ in
                sharedSession
            },
            cancelRunningJobs: { _ in
                cancelCallCount += 1
            }
        )
        let initialAccounts = loadRegisteredReviewAccounts(environment: environment)
        auth.updateSavedAccounts(initialAccounts.accounts)
        auth.updateAccount(initialAccounts.accounts.first(where: { $0.accountKey == initialAccounts.activeAccountKey }))

        try await auth.store.signOutActiveAccount()

        #expect(testAuthState(from: auth) == .signedOut)
        #expect(cancelCallCount == 1)
    }

    @Test func recoveredSignOutDoesNotPromoteFallbackSavedAccount() async throws {
        let environment = try isolatedHomeEnvironment()
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        try writeReviewAuthSnapshot(
            email: "active@example.com",
            planType: "pro",
            environment: environment
        )
        _ = try registryStore.saveSharedAuthAsSavedAccount(makeActive: true)
        try writeReviewAuthSnapshot(
            email: "other@example.com",
            planType: "pro",
            environment: environment
        )
        _ = try registryStore.saveSharedAuthAsSavedAccount(makeActive: false)
        try writeReviewAuthSnapshot(
            email: "active@example.com",
            planType: "pro",
            environment: environment
        )

        let sharedSession = FailingLogoutReviewAuthSession()
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                sharedSession
            },
            loginAuthSessionFactory: { _ in
                sharedSession
            }
        )
        let initialAccounts = loadRegisteredReviewAccounts(environment: environment)
        auth.updateSavedAccounts(initialAccounts.accounts)
        auth.updateAccount(initialAccounts.accounts.first(where: { $0.accountKey == initialAccounts.activeAccountKey }))

        try await auth.store.signOutActiveAccount()

        let loadedAccounts = loadRegisteredReviewAccounts(environment: environment)
        #expect(testAuthState(from: auth) == .signedOut)
        #expect(auth.account == nil)
        #expect(auth.savedAccounts.map(\.email) == ["other@example.com"])
        #expect(loadedAccounts.activeAccountKey == nil)
        #expect(loadedAccounts.accounts.map(\.email) == ["other@example.com"])
        #expect(loadSharedReviewAccount(environment: environment) == nil)
    }

    @Test func signOutKeepsCommittedStateAndRecordsCleanupWarning() async throws {
        let environment = try isolatedHomeEnvironment()
        try writeReviewAuthSnapshot(
            email: "review@example.com",
            planType: "pro",
            environment: environment
        )
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        _ = try registryStore.saveSharedAuthAsSavedAccount(makeActive: true)
        let sharedSession = SuccessfulLogoutReviewAuthSession()
        var cancelCallCount = 0
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                sharedSession
            },
            loginAuthSessionFactory: { _ in
                sharedSession
            },
            cancelRunningJobs: { _ in
                cancelCallCount += 1
                throw NSError(
                    domain: "CodexReviewMCPTests.signOutKeepsCommittedStateAndRecordsCleanupWarning",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Cancellation failed."]
                )
            }
        )
        let initialAccounts = loadRegisteredReviewAccounts(environment: environment)
        auth.updateSavedAccounts(initialAccounts.accounts)
        auth.updateAccount(initialAccounts.accounts.first(where: { $0.accountKey == initialAccounts.activeAccountKey }))

        try await auth.store.signOutActiveAccount()

        #expect(testAuthState(from: auth) == .signedOut)
        #expect(cancelCallCount == 1)
        #expect(auth.warningMessage == "Cancellation failed.")
    }

    @Test func logoutReportsCleanupFailureAfterSuccessfulLogout() async throws {
        let environment = try isolatedHomeEnvironment()
        try writeReviewAuthSnapshot(
            email: "review@example.com",
            planType: "pro",
            environment: environment
        )
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        _ = try registryStore.saveSharedAuthAsSavedAccount(makeActive: true)
        let sharedSession = SuccessfulLogoutReviewAuthSession()
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                sharedSession
            },
            loginAuthSessionFactory: { _ in
                sharedSession
            },
            cancelRunningJobs: { _ in
                throw NSError(
                    domain: "CodexReviewMCPTests.logoutReportsCleanupFailureAfterSuccessfulLogout",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Cancellation failed."]
                )
            }
        )
        let initialAccounts = loadRegisteredReviewAccounts(environment: environment)
        auth.updateSavedAccounts(initialAccounts.accounts)
        auth.updateAccount(initialAccounts.accounts.first(where: { $0.accountKey == initialAccounts.activeAccountKey }))

        await auth.store.logout()

        let loadedAccounts = loadRegisteredReviewAccounts(environment: environment)
        #expect(auth.errorMessage == nil)
        #expect(auth.account == nil)
        #expect(loadedAccounts.accounts.isEmpty)
        #expect(auth.warningMessage == "Cancellation failed.")
    }

    @Test func logoutClearsAccountWhenCleanupRecoveryIsUnavailable() async throws {
        let environment = try isolatedHomeEnvironment()
        try writeReviewAuthSnapshot(
            email: "review@example.com",
            planType: "pro",
            environment: environment
        )
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        _ = try registryStore.saveSharedAuthAsSavedAccount(makeActive: true)
        let sharedSession = FailingReadAccountReviewAuthSession(message: "refresh failed")
        var cancelCallCount = 0
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                sharedSession
            },
            loginAuthSessionFactory: { _ in
                sharedSession
            },
            cancelRunningJobs: { _ in
                cancelCallCount += 1
                throw NSError(
                    domain: "CodexReviewMCPTests.logoutClearsAccountWhenCleanupRecoveryIsUnavailable",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Cancellation failed."]
                )
            }
        )
        let initialAccounts = loadRegisteredReviewAccounts(environment: environment)
        auth.updateSavedAccounts(initialAccounts.accounts)
        auth.updateAccount(initialAccounts.accounts.first(where: { $0.accountKey == initialAccounts.activeAccountKey }))

        await auth.store.logout()

        #expect(auth.account == nil)
        #expect(auth.errorMessage == nil)
        #expect(cancelCallCount == 1)
    }

    @Test func signInUsesInjectedAuthSessionWithoutAuthTransportCheckout() async throws {
        let environment = try isolatedHomeEnvironment()
        let manager = AuthCapableAppServerManager()
        let authSession = BlockingLoginReviewAuthSession()
        let store = makeInjectedAuthSessionStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            authSessionFactory: {
                authSession
            }
        )

        let beginTask = Task {
            await store.signIn()
        }
        let authStateProbe = ObservableValueProbe { testAuthState(from: store.auth) }
        defer { authStateProbe.cancel() }

        await authSession.waitForLoginStart()
        try await waitForObservedValue(authStateProbe) { authState in
            guard let progress = authState.progress else {
                return false
            }
            return progress.browserURL?.contains("/oauth/authorize") == true
        }

        await store.cancelAuthentication()
        _ = await beginTask.value

        #expect(await manager.authTransportCheckoutCount() == 0)
        #expect(await manager.reviewTransportCheckoutCount() == 0)
        #expect(await manager.shutdownCount() == 0)
        #expect(testAuthState(from: store.auth) == .signedOut)
    }

    @Test func addAccountCancellationPreservesSignedOutStateWithSavedAccounts() async throws {
        let environment = try isolatedHomeEnvironment()
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        _ = try saveReviewAccount(
            email: "saved@example.com",
            makeActive: true,
            environment: environment,
            registryStore: registryStore
        )
        let manager = AuthCapableAppServerManager()
        let authSession = BlockingLoginReviewAuthSession()
        let store = makeInjectedAuthSessionStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            authSessionFactory: {
                authSession
            }
        )
        let initialAccounts = loadRegisteredReviewAccounts(environment: environment)
        store.auth.updateSavedAccounts(initialAccounts.accounts)
        store.auth.updateAccount(nil)

        let beginTask = Task {
            await store.addAccount()
        }

        await authSession.waitForLoginStart()
        await store.cancelAuthentication()
        _ = await beginTask.value

        #expect(store.auth.account == nil)
        #expect(store.auth.savedAccounts.map(\.email) == ["saved@example.com"])
        #expect(testAuthState(from: store.auth) == .signedOut)
    }

    @Test func successfulAuthenticationRecyclesSharedAppServer() async throws {
        let environment = try isolatedHomeEnvironment()
        let manager = AuthCapableAppServerManager()
        let authSession = SuccessfulLoginReviewAuthSession()
        let store = makeInjectedAuthSessionStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            authSessionFactory: {
                authSession
            }
        )

        await store.start()
        defer { Task { await store.stop() } }
        await store.signIn()

        #expect(testAuthState(from: store.auth) == .signedIn(accountID: "review@example.com"))
        #expect(await manager.prepareCount() == 2)
        #expect(await manager.shutdownCount() == 1)

        await store.stop()
    }

    @Test func sameAccountReauthenticationWithoutInitialEmptyStateRecyclesSharedAppServer() async throws {
        let environment = try isolatedHomeEnvironment()
        let manager = AuthCapableAppServerManager()
        let authSession = SameAccountSuccessfulLoginReviewAuthSession()
        let store = makeInjectedAuthSessionStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            authSessionFactory: {
                authSession
            }
        )

        await store.start()
        defer { Task { await store.stop() } }
        await store.signIn()

        #expect(testAuthState(from: store.auth) == .signedIn(accountID: "review@example.com"))
        #expect(await manager.prepareCount() == 2)
        #expect(await manager.shutdownCount() == 1)

        await store.stop()
    }

    @Test func addAccountWithoutSavedAccountsDoesNotAutoActivate() async throws {
        let environment = try isolatedHomeEnvironment()
        let manager = AuthCapableAppServerManager()
        let authSession = SuccessfulLoginReviewAuthSession()
        let store = makeInjectedAuthSessionStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            authSessionFactory: {
                authSession
            }
        )

        await store.start()
        defer { Task { await store.stop() } }
        await store.addAccount()

        #expect(testAuthState(from: store.auth) == .signedOut)
        #expect(store.auth.savedAccounts.map(\.email) == ["review@example.com"])
        #expect(await manager.prepareCount() == 1)
        #expect(await manager.shutdownCount() == 0)

        await store.stop()
    }

    @Test func addAccountWithUnsavedCurrentSameEmailRecyclesRunningServer() async throws {
        let environment = try isolatedHomeEnvironment()
        let manager = AuthCapableAppServerManager()
        let authSession = SameAccountSuccessfulLoginReviewAuthSession()
        let store = makeInjectedAuthSessionStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            authSessionFactory: {
                authSession
            }
        )

        await store.start()
        defer { Task { await store.stop() } }
        await store.addAccount()

        #expect(testAuthState(from: store.auth) == .signedIn(accountID: "review@example.com"))
        #expect(store.auth.savedAccounts.map(\.email) == ["review@example.com"])
        #expect(await manager.prepareCount() == 2)
        #expect(await manager.shutdownCount() == 1)

        await store.stop()
    }

    @Test func successfulAuthenticationClearsSigningInPhaseWhenResolvedRefreshFails() async throws {
        let environment = try isolatedHomeEnvironment()
        let manager = AuthCapableAppServerManager()
        let authSession = SuccessfulLoginThenFailingRefreshReviewAuthSession()
        let store = makeInjectedAuthSessionStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            authSessionFactory: {
                authSession
            }
        )

        await store.start()
        defer { Task { await store.stop() } }
        await store.signIn()

        #expect(store.auth.isAuthenticating == false)
        #expect(
            testAuthState(from: store.auth) == .failed(
                "refresh failed",
                isAuthenticated: true,
                accountID: "review@example.com"
            )
        )

        await store.stop()
    }

    @Test func cancellingAuthenticationAfterCommittedLoginDoesNotRollbackActivatedAccount() async throws {
        let environment = try isolatedHomeEnvironment()
        let sharedSession = SuccessfulLoginReviewAuthSession()
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                sharedSession
            },
            loginAuthSessionFactory: { environment in
                PersistingReviewAuthSession(
                    base: sharedSession,
                    environment: environment
                )
            }
        )

        await auth.store.signIn()
        await auth.store.cancelAuthentication()

        let loadedAccounts = loadRegisteredReviewAccounts(environment: environment)
        #expect(testAuthState(from: auth) == .signedIn(accountID: "review@example.com"))
        #expect(loadedAccounts.activeAccountKey == loadedAccounts.accounts.first?.accountKey)
        #expect(loadedAccounts.accounts.map(\.email) == ["review@example.com"])
    }

    @Test func addAccountRefreshesInactiveSavedAccountRateLimits() async throws {
        let environment = try isolatedHomeEnvironment()
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        try writeReviewAuthSnapshot(
            email: "active@example.com",
            planType: "pro",
            environment: environment
        )
        _ = try registryStore.saveSharedAuthAsSavedAccount(makeActive: true)
        let loginSession = SuccessfulLoginReviewAuthSession()
        let rateLimitTransport = AuthCapableAppServerSessionTransport()
        let rateLimitManager = AuthCapableAppServerManager(authTransport: rateLimitTransport)
        var cancelCallCount = 0
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                SignedOutReviewAuthSession()
            },
            loginAuthSessionFactory: { environment in
                PersistingReviewAuthSession(
                    base: loginSession,
                    environment: environment
                )
            },
            probeAppServerManagerFactory: { _ in
                rateLimitManager
            },
            cancelRunningJobs: { _ in
                cancelCallCount += 1
            }
        )
        let initialAccounts = loadRegisteredReviewAccounts(environment: environment)
        auth.updateSavedAccounts(initialAccounts.accounts)
        auth.updateAccount(initialAccounts.accounts.first(where: { $0.accountKey == initialAccounts.activeAccountKey }))

        await auth.store.addAccount()

        let addedAccount = try #require(auth.savedAccounts.first(where: { $0.email == "review@example.com" }))
        #expect(await rateLimitTransport.rateLimitsReadCount() == 1)
        #expect(cancelCallCount == 0)
        #expect(auth.account?.email == "active@example.com")
        #expect(auth.savedAccounts.first(where: \.isActive)?.email == "active@example.com")
        #expect(rateLimitWindow(duration: 300, in: addedAccount)?.usedPercent == 40)
        #expect(rateLimitWindow(duration: 10_080, in: addedAccount)?.usedPercent == 20)
    }

    @Test func addAccountRetryAfterFailedAuthenticationKeepsCurrentActiveAccountWithoutCancellingJobs() async throws {
        let environment = try isolatedHomeEnvironment()
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        _ = try saveReviewAccount(
            email: "active@example.com",
            makeActive: true,
            environment: environment,
            registryStore: registryStore
        )
        let loginSession = SuccessfulLoginReviewAuthSession()
        var cancelCallCount = 0
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                ImmediateReadAccountReviewAuthSession(
                    response: .init(
                        account: .chatGPT(email: "active@example.com", planType: "pro"),
                        requiresOpenAIAuth: false
                    )
                )
            },
            loginAuthSessionFactory: { environment in
                PersistingReviewAuthSession(
                    base: loginSession,
                    environment: environment
                )
            },
            cancelRunningJobs: { _ in
                cancelCallCount += 1
            }
        )
        let initialAccounts = loadRegisteredReviewAccounts(environment: environment)
        auth.updateSavedAccounts(initialAccounts.accounts)
        auth.updateAccount(initialAccounts.accounts.first(where: { $0.accountKey == initialAccounts.activeAccountKey }))
        await auth.store.refreshAuthentication()
        auth.updatePhase(.failed(message: "Previous add-account failed."))

        await auth.store.addAccount()

        let loadedAccounts = loadRegisteredReviewAccounts(environment: environment)
        #expect(cancelCallCount == 0)
        #expect(auth.account?.email == "active@example.com")
        #expect(auth.savedAccounts.first(where: \.isActive)?.email == "active@example.com")
        #expect(auth.savedAccounts.map(\.email) == ["active@example.com", "review@example.com"])
        #expect(loadedAccounts.activeAccountKey == "active@example.com")
        #expect(loadedAccounts.accounts.map(\.email) == ["active@example.com", "review@example.com"])
        #expect(loadSharedReviewAccount(environment: environment)?.email == "active@example.com")
    }

    @Test func addAccountUnresolvedFailedStateKeepsCurrentActiveAccountWithoutCancellingJobs() async throws {
        let environment = try isolatedHomeEnvironment()
        try writeReviewAuthSnapshot(
            email: "stale@example.com",
            planType: "pro",
            environment: environment
        )
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        _ = try registryStore.saveSharedAuthAsSavedAccount(makeActive: true)

        let sharedSession = SuccessfulLoginReviewAuthSession()
        var cancelCallCount = 0
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                sharedSession
            },
            loginAuthSessionFactory: { environment in
                PersistingReviewAuthSession(
                    base: sharedSession,
                    environment: environment
                )
            },
            cancelRunningJobs: { _ in
                cancelCallCount += 1
            }
        )
        let initialAccounts = loadRegisteredReviewAccounts(environment: environment)
        auth.updateSavedAccounts(initialAccounts.accounts)
        auth.updateAccount(initialAccounts.accounts.first(where: { $0.accountKey == initialAccounts.activeAccountKey }))
        auth.updatePhase(.failed(message: "Authentication failed."))

        await auth.store.addAccount()

        let loadedAccounts = loadRegisteredReviewAccounts(environment: environment)
        #expect(cancelCallCount == 0)
        #expect(testAuthState(from: auth) == .signedIn(accountID: "stale@example.com"))
        #expect(auth.savedAccounts.first(where: \.isActive)?.email == "stale@example.com")
        #expect(auth.savedAccounts.map(\.email) == ["stale@example.com", "review@example.com"])
        #expect(loadedAccounts.activeAccountKey == "stale@example.com")
        #expect(loadedAccounts.accounts.map(\.email) == ["stale@example.com", "review@example.com"])
    }

    @Test func addAccountUnresolvedFailedStateKeepsCurrentRuntimeWithoutRecycle() async throws {
        let environment = try isolatedHomeEnvironment()
        try writeReviewAuthSnapshot(
            email: "stale@example.com",
            planType: "pro",
            environment: environment
        )
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        _ = try registryStore.saveSharedAuthAsSavedAccount(makeActive: true)

        let manager = AuthCapableAppServerManager()
        let sharedSession = SuccessfulLoginReviewAuthSession()
        var cancelCallCount = 0
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            sharedAuthSessionFactory: { _ in
                sharedSession
            },
            loginAuthSessionFactory: { environment in
                PersistingReviewAuthSession(
                    base: sharedSession,
                    environment: environment
                )
            },
            runtimeState: {
                .init(serverIsRunning: true, runtimeGeneration: 1)
            },
            recycleServerIfRunning: {
                await manager.shutdown()
                _ = try? await manager.prepare()
            },
            cancelRunningJobs: { _ in
                cancelCallCount += 1
            }
        )
        let initialAccounts = loadRegisteredReviewAccounts(environment: environment)
        auth.updateSavedAccounts(initialAccounts.accounts)
        auth.updateAccount(initialAccounts.accounts.first(where: { $0.accountKey == initialAccounts.activeAccountKey }))
        auth.updatePhase(.failed(message: "Authentication failed."))

        await auth.store.addAccount()

        let loadedAccounts = loadRegisteredReviewAccounts(environment: environment)
        #expect(cancelCallCount == 0)
        #expect(testAuthState(from: auth) == .signedIn(accountID: "stale@example.com"))
        #expect(auth.savedAccounts.first(where: \.isActive)?.email == "stale@example.com")
        #expect(auth.savedAccounts.map(\.email) == ["stale@example.com", "review@example.com"])
        #expect(loadedAccounts.activeAccountKey == "stale@example.com")
        #expect(await manager.prepareCount() == 0)
        #expect(await manager.shutdownCount() == 0)
    }

    @Test func addAccountWithoutResolvedCurrentAccountStaysSignedOutWithoutCancellingJobs() async throws {
        let environment = try isolatedHomeEnvironment()
        try writeReviewAuthSnapshot(
            email: "active@example.com",
            planType: "pro",
            environment: environment
        )
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        _ = try registryStore.saveSharedAuthAsSavedAccount(makeActive: true)

        let manager = AuthCapableAppServerManager()
        let sharedSession = SuccessfulLoginReviewAuthSession()
        var cancelCallCount = 0
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            sharedAuthSessionFactory: { _ in
                sharedSession
            },
            loginAuthSessionFactory: { environment in
                PersistingReviewAuthSession(
                    base: sharedSession,
                    environment: environment
                )
            },
            runtimeState: {
                .init(serverIsRunning: true, runtimeGeneration: 1)
            },
            recycleServerIfRunning: {
                await manager.shutdown()
                _ = try? await manager.prepare()
            },
            cancelRunningJobs: { _ in
                cancelCallCount += 1
            }
        )
        let initialAccounts = loadRegisteredReviewAccounts(environment: environment)
        auth.updateSavedAccounts(initialAccounts.accounts)
        auth.updateAccount(nil)
        auth.updatePhase(.failed(message: "Authentication failed."))

        await auth.store.addAccount()

        let loadedAccounts = loadRegisteredReviewAccounts(environment: environment)
        #expect(cancelCallCount == 0)
        #expect(testAuthState(from: auth) == .signedOut)
        #expect(auth.account == nil)
        #expect(auth.savedAccounts.first(where: \.isActive)?.email == "active@example.com")
        #expect(auth.savedAccounts.map(\.email) == ["active@example.com", "review@example.com"])
        #expect(loadedAccounts.activeAccountKey == "active@example.com")
        #expect(await manager.prepareCount() == 0)
        #expect(await manager.shutdownCount() == 0)
    }

    @Test func addAccountWithSavedAccountsAndNoCurrentSessionStaysSignedOut() async throws {
        let environment = try isolatedHomeEnvironment()
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        _ = try saveReviewAccount(
            email: "saved@example.com",
            makeActive: false,
            environment: environment,
            registryStore: registryStore
        )

        let authSession = SuccessfulLoginReviewAuthSession()
        var cancelCallCount = 0
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                authSession
            },
            loginAuthSessionFactory: { environment in
                PersistingReviewAuthSession(
                    base: authSession,
                    environment: environment
                )
            },
            cancelRunningJobs: { _ in
                cancelCallCount += 1
            }
        )
        let initialAccounts = loadRegisteredReviewAccounts(environment: environment)
        auth.updateSavedAccounts(initialAccounts.accounts)
        auth.updateAccount(nil)

        await auth.store.addAccount()

        let loadedAccounts = loadRegisteredReviewAccounts(environment: environment)
        #expect(cancelCallCount == 0)
        #expect(testAuthState(from: auth) == .signedOut)
        #expect(auth.account == nil)
        #expect(auth.savedAccounts.first(where: \.isActive)?.email == "saved@example.com")
        #expect(loadedAccounts.activeAccountKey == "saved@example.com")
        #expect(loadedAccounts.accounts.map(\.email) == ["saved@example.com", "review@example.com"])
    }

    @Test func addAccountWithSavedAccountsAndNoActiveSavedAccountMakesNewAccountRecoverable() async throws {
        let environment = try isolatedHomeEnvironment()
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        _ = try saveReviewAccount(
            email: "saved@example.com",
            makeActive: true,
            environment: environment,
            registryStore: registryStore
        )
        try await registryStore.clearActiveAccount()

        let authSession = SuccessfulLoginReviewAuthSession()
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                authSession
            },
            loginAuthSessionFactory: { environment in
                PersistingReviewAuthSession(
                    base: authSession,
                    environment: environment
                )
            }
        )
        let initialAccounts = loadRegisteredReviewAccounts(environment: environment)
        auth.updateSavedAccounts(initialAccounts.accounts)
        auth.updateAccount(nil)
        auth.updatePhase(.signedOut)

        await auth.store.addAccount()

        let loadedAccounts = loadRegisteredReviewAccounts(environment: environment)
        #expect(testAuthState(from: auth) == .signedOut)
        #expect(auth.account == nil)
        #expect(auth.savedAccounts.first(where: \.isActive)?.email == "review@example.com")
        #expect(loadedAccounts.activeAccountKey == "review@example.com")
        #expect(loadSharedReviewAccount(environment: environment)?.email == "review@example.com")
    }

    @Test func signInWithSavedAccountsAndNoCurrentSessionActivatesAuthenticatedAccount() async throws {
        let environment = try isolatedHomeEnvironment()
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        _ = try saveReviewAccount(
            email: "saved@example.com",
            makeActive: false,
            environment: environment,
            registryStore: registryStore
        )

        let authSession = SuccessfulLoginReviewAuthSession()
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                authSession
            },
            loginAuthSessionFactory: { environment in
                PersistingReviewAuthSession(
                    base: authSession,
                    environment: environment
                )
            }
        )
        let initialAccounts = loadRegisteredReviewAccounts(environment: environment)
        auth.updateSavedAccounts(initialAccounts.accounts)
        auth.updateAccount(nil)

        await auth.store.signIn()

        let loadedAccounts = loadRegisteredReviewAccounts(environment: environment)
        #expect(testAuthState(from: auth) == .signedIn(accountID: "review@example.com"))
        #expect(auth.account?.email == "review@example.com")
        #expect(auth.savedAccounts.first(where: \.isActive)?.email == "review@example.com")
        #expect(loadedAccounts.activeAccountKey == "review@example.com")
        #expect(loadedAccounts.accounts.map(\.email) == ["saved@example.com", "review@example.com"])
    }

    @Test func addAccountSameEmailWithoutCurrentSessionStaysSignedOut() async throws {
        let environment = try isolatedHomeEnvironment()
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        _ = try saveReviewAccount(
            email: "review@example.com",
            makeActive: false,
            environment: environment,
            registryStore: registryStore
        )

        let authSession = SameAccountSuccessfulLoginReviewAuthSession()
        var cancelCallCount = 0
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                authSession
            },
            loginAuthSessionFactory: { environment in
                PersistingReviewAuthSession(
                    base: authSession,
                    environment: environment
                )
            },
            cancelRunningJobs: { _ in
                cancelCallCount += 1
            }
        )
        let initialAccounts = loadRegisteredReviewAccounts(environment: environment)
        auth.updateSavedAccounts(initialAccounts.accounts)
        auth.updateAccount(nil)

        await auth.store.addAccount()

        let loadedAccounts = loadRegisteredReviewAccounts(environment: environment)
        #expect(cancelCallCount == 0)
        #expect(testAuthState(from: auth) == .signedOut)
        #expect(auth.account == nil)
        #expect(auth.savedAccounts.map(\.email) == ["review@example.com"])
        #expect(auth.savedAccounts.first(where: \.isActive)?.email == "review@example.com")
        #expect(loadedAccounts.activeAccountKey == "review@example.com")
        #expect(loadedAccounts.accounts.map(\.email) == ["review@example.com"])
    }

    @Test func addAccountUnsavedSameEmailReauthenticationPreservesCurrentSessionObject() async throws {
        let environment = try isolatedHomeEnvironment()
        let authSession = SameAccountSuccessfulLoginReviewAuthSession()
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                authSession
            },
            loginAuthSessionFactory: { environment in
                PersistingReviewAuthSession(
                    base: authSession,
                    environment: environment
                )
            }
        )
        let unsavedCurrentAccount = CodexAccount(email: "review@example.com")
        auth.updateAccount(unsavedCurrentAccount)

        await auth.store.addAccount()

        #expect(auth.account === unsavedCurrentAccount)
        #expect(auth.savedAccounts.first?.email == "review@example.com")
        #expect(auth.account?.planType == "pro")
        #expect(loadSharedReviewAccount(environment: environment)?.email == "review@example.com")
    }

    @Test func addAccountWithoutActivationPreservesUnsavedCurrentSession() async throws {
        let environment = try isolatedHomeEnvironment()
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        _ = try saveReviewAccount(
            email: "saved@example.com",
            makeActive: true,
            environment: environment,
            registryStore: registryStore
        )

        let authSession = SuccessfulLoginReviewAuthSession()
        var cancelCallCount = 0
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                authSession
            },
            loginAuthSessionFactory: { environment in
                PersistingReviewAuthSession(
                    base: authSession,
                    environment: environment
                )
            },
            cancelRunningJobs: { _ in
                cancelCallCount += 1
            }
        )
        let initialAccounts = loadRegisteredReviewAccounts(environment: environment)
        auth.updateSavedAccounts(initialAccounts.accounts)
        let unsavedCurrentAccount = CodexAccount(email: "unsaved@example.com", planType: "pro")
        unsavedCurrentAccount.updateRateLimits(
            [
                (
                    windowDurationMinutes: 300,
                    usedPercent: 61,
                    resetsAt: Date(timeIntervalSince1970: 1_735_776_000)
                )
            ]
        )
        unsavedCurrentAccount.updateRateLimitFetchMetadata(
            fetchedAt: Date(timeIntervalSince1970: 1_735_700_000),
            error: "cached"
        )
        auth.updateAccount(unsavedCurrentAccount)

        await auth.store.addAccount()

        let loadedAccounts = loadRegisteredReviewAccounts(environment: environment)
        #expect(cancelCallCount == 0)
        #expect(testAuthState(from: auth) == .signedIn(accountID: "unsaved@example.com"))
        #expect(auth.account === unsavedCurrentAccount)
        #expect(rateLimitWindow(duration: 300, in: auth.account)?.usedPercent == 61)
        #expect(auth.account?.lastRateLimitError == "cached")
        #expect(loadedAccounts.activeAccountKey == "saved@example.com")
        #expect(loadedAccounts.accounts.map(\.email) == ["saved@example.com", "review@example.com"])
    }

    @Test func addAccountWithoutSavedAccountsPreservesUnsavedCurrentSession() async throws {
        let environment = try isolatedHomeEnvironment()
        let authSession = SuccessfulLoginReviewAuthSession()
        var cancelCallCount = 0
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                authSession
            },
            loginAuthSessionFactory: { environment in
                PersistingReviewAuthSession(
                    base: authSession,
                    environment: environment
                )
            },
            cancelRunningJobs: { _ in
                cancelCallCount += 1
            }
        )
        let unsavedCurrentAccount = CodexAccount(email: "unsaved@example.com", planType: "pro")
        auth.updateSavedAccounts([])
        auth.updateAccount(unsavedCurrentAccount)

        await auth.store.addAccount()

        let loadedAccounts = loadRegisteredReviewAccounts(environment: environment)
        #expect(cancelCallCount == 0)
        #expect(testAuthState(from: auth) == .signedIn(accountID: "unsaved@example.com"))
        #expect(auth.account === unsavedCurrentAccount)
        #expect(auth.savedAccounts.map(\.email) == ["review@example.com"])
        #expect(loadedAccounts.activeAccountKey == nil)
        #expect(loadedAccounts.accounts.map(\.email) == ["review@example.com"])
    }

    @Test func addAccountWithoutActiveSessionAddsAccountWithoutCancellingJobs() async throws {
        let environment = try isolatedHomeEnvironment()
        let authSession = SuccessfulLoginReviewAuthSession()
        var cancelCallCount = 0
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                authSession
            },
            loginAuthSessionFactory: { environment in
                PersistingReviewAuthSession(
                    base: authSession,
                    environment: environment
                )
            },
            cancelRunningJobs: { _ in
                cancelCallCount += 1
            }
        )

        await auth.store.addAccount()

        let loadedAccounts = loadRegisteredReviewAccounts(environment: environment)
        #expect(cancelCallCount == 0)
        #expect(testAuthState(from: auth) == .signedOut)
        #expect(auth.savedAccounts.first(where: \.isActive)?.email == "review@example.com")
        #expect(loadedAccounts.activeAccountKey == "review@example.com")
        #expect(loadedAccounts.accounts.map(\.email) == ["review@example.com"])
        #expect(loadSharedReviewAccount(environment: environment)?.email == "review@example.com")
    }

    @Test func addAccountSameEmailReauthenticationDoesNotCancelJobsOrSwitchActiveAccount() async throws {
        let environment = try isolatedHomeEnvironment()
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        _ = try saveReviewAccount(
            email: "review@example.com",
            makeActive: true,
            environment: environment,
            registryStore: registryStore
        )
        try writeReviewAuthSnapshot(
            email: "stale@example.com",
            planType: "pro",
            environment: environment
        )
        let authSession = SameAccountSuccessfulLoginReviewAuthSession()
        var cancelCallCount = 0
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                authSession
            },
            loginAuthSessionFactory: { environment in
                PersistingReviewAuthSession(
                    base: authSession,
                    environment: environment
                )
            },
            cancelRunningJobs: { _ in
                cancelCallCount += 1
            }
        )
        let initialAccounts = loadRegisteredReviewAccounts(environment: environment)
        auth.updateSavedAccounts(initialAccounts.accounts)
        auth.updateAccount(initialAccounts.accounts.first(where: { $0.accountKey == initialAccounts.activeAccountKey }))

        await auth.store.addAccount()

        let loadedAccounts = loadRegisteredReviewAccounts(environment: environment)
        #expect(cancelCallCount == 0)
        #expect(auth.account?.email == "review@example.com")
        #expect(auth.savedAccounts.map(\.email) == ["review@example.com"])
        #expect(loadedAccounts.activeAccountKey == "review@example.com")
        #expect(loadedAccounts.accounts.map(\.email) == ["review@example.com"])
        #expect(loadSharedReviewAccount(environment: environment)?.email == "review@example.com")
    }

    @Test func addAccountSavedInactiveCurrentSameEmailRefreshesSharedRuntime() async throws {
        let environment = try isolatedHomeEnvironment()
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        _ = try saveReviewAccount(
            email: "saved@example.com",
            makeActive: true,
            environment: environment,
            registryStore: registryStore
        )
        let currentSavedAccount = try saveReviewAccount(
            email: "review@example.com",
            makeActive: false,
            environment: environment,
            registryStore: registryStore
        )
        try writeReviewAuthSnapshot(
            email: "saved@example.com",
            planType: "pro",
            environment: environment
        )

        let authSession = SameAccountSuccessfulLoginReviewAuthSession()
        var recycleCallCount = 0
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                authSession
            },
            loginAuthSessionFactory: { environment in
                PersistingReviewAuthSession(
                    base: authSession,
                    environment: environment
                )
            },
            runtimeState: {
                .init(serverIsRunning: true, runtimeGeneration: 1)
            },
            recycleServerIfRunning: {
                recycleCallCount += 1
            }
        )
        auth.updateSavedAccounts(loadRegisteredReviewAccounts(environment: environment).accounts)
        auth.updateAccount(currentSavedAccount)

        await auth.store.addAccount()

        let loadedAccounts = loadRegisteredReviewAccounts(environment: environment)
        #expect(recycleCallCount == 1)
        #expect(auth.account === currentSavedAccount)
        #expect(auth.account?.email == "review@example.com")
        #expect(auth.savedAccounts.first(where: \.isActive)?.email == "saved@example.com")
        #expect(loadedAccounts.activeAccountKey == "saved@example.com")
        #expect(loadSharedReviewAccount(environment: environment)?.email == "review@example.com")
    }

    @Test func addAccountSameEmailReauthenticationWithRunningJobsDefersRuntimeRecycleUntilJobsFinish() async throws {
        let environment = try isolatedHomeEnvironment()
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        _ = try saveReviewAccount(
            email: "review@example.com",
            makeActive: true,
            environment: environment,
            registryStore: registryStore
        )
        try writeReviewAuthSnapshot(
            email: "stale@example.com",
            planType: "pro",
            environment: environment
        )
        let authSession = SameAccountSuccessfulLoginReviewAuthSession()
        var cancelCallCount = 0
        var recycleCallCount = 0
        let hasRunningJobs = MutableValueBox(true)
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                authSession
            },
            loginAuthSessionFactory: { environment in
                PersistingReviewAuthSession(
                    base: authSession,
                    environment: environment
                )
            },
            runtimeState: {
                .init(serverIsRunning: true, runtimeGeneration: 1)
            },
            recycleServerIfRunning: {
                recycleCallCount += 1
            },
            hasRunningJobs: {
                hasRunningJobs.value
            },
            cancelRunningJobs: { _ in
                cancelCallCount += 1
            }
        )
        let initialAccounts = loadRegisteredReviewAccounts(environment: environment)
        auth.updateSavedAccounts(initialAccounts.accounts)
        auth.updateAccount(initialAccounts.accounts.first(where: { $0.accountKey == initialAccounts.activeAccountKey }))

        await auth.store.addAccount()

        let loadedAccounts = loadRegisteredReviewAccounts(environment: environment)
        #expect(cancelCallCount == 0)
        #expect(recycleCallCount == 0)
        #expect(auth.account?.email == "review@example.com")
        #expect(loadedAccounts.activeAccountKey == "review@example.com")
        #expect(loadSharedReviewAccount(environment: environment)?.email == "review@example.com")

        hasRunningJobs.value = false
        await auth.store.reconcileAuthenticatedSession(
            serverIsRunning: true,
            runtimeGeneration: 1
        )

        #expect(recycleCallCount == 1)
    }

    @Test func recycleNowRuntimeEffectDefersWhenJobsAppearBeforeApply() async throws {
        let environment = try isolatedHomeEnvironment()
        let hasRunningJobs = MutableValueBox(false)
        var recycleCallCount = 0
        let runtimeDriver = TestAuthRuntimeDriver(
            runtimeState: {
                .init(serverIsRunning: true, runtimeGeneration: 1)
            },
            recycleServerIfRunning: {
                recycleCallCount += 1
            },
            hasRunningJobs: {
                hasRunningJobs.value
            }
        )
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                ImmediateReadAccountReviewAuthSession(
                    response: .init(
                        account: .chatGPT(email: "saved@example.com", planType: "pro"),
                        requiresOpenAIAuth: false
                    )
                )
            },
            loginAuthSessionFactory: { _ in
                SignedOutReviewAuthSession()
            }
        )
        auth.updateAccount(CodexAccount(email: "review@example.com"))

        let effect = runtimeDriver.resolveAddAccountRuntimeEffect(
            accountKey: "review@example.com",
            runtimeGeneration: 1
        )
        hasRunningJobs.value = true

        await runtimeDriver.applyAddAccountRuntimeEffect(
            effect,
            auth: auth.model
        )
        #expect(recycleCallCount == 0)

        hasRunningJobs.value = false
        await runtimeDriver.reconcileDeferredAddAccountRuntimeEffectIfNeeded(
            auth: auth.model,
            serverIsRunning: true,
            runtimeGeneration: 1
        )

        #expect(recycleCallCount == 1)
    }

    @Test func addAccountSameEmailDeferredRuntimeRecycleRunsWhenStoreJobsDrain() async throws {
        let environment = try isolatedHomeEnvironment()
        let manager = AuthCapableAppServerManager()
        let authSession = SameAccountSuccessfulLoginReviewAuthSession()
        let store = makeInjectedAuthSessionStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            authSessionFactory: {
                authSession
            }
        )

        try await withAsyncCleanup {
            await store.start()
            await store.refreshAuthentication()
            #expect(store.auth.account?.email == "review@example.com")
            let jobID = try store.enqueueReview(
                sessionID: "session-a",
                request: .init(
                    cwd: FileManager.default.currentDirectoryPath,
                    target: .uncommittedChanges
                )
            )
            store.markStarted(jobID: jobID, startedAt: Date())

            #expect(store.hasRunningJobs)
            #expect(await manager.prepareCount() == 1)
            #expect(await manager.shutdownCount() == 0)

            await store.addAccount()

            #expect(await manager.prepareCount() == 1)
            #expect(await manager.shutdownCount() == 0)

            store.completeReview(
                jobID: jobID,
                outcome: .init(
                    state: .succeeded,
                    exitCode: 0,
                    reviewThreadID: nil,
                    threadID: nil,
                    turnID: nil,
                    model: nil,
                    hasFinalReview: false,
                    lastAgentMessage: "",
                    errorMessage: nil,
                    summary: "Completed.",
                    startedAt: Date(),
                    endedAt: Date(),
                    content: ""
                )
            )

            try await waitForAppServerLifecycleCounts(
                manager,
                prepareCount: 2,
                shutdownCount: 1
            )
        } cleanup: {
            await store.stop()
        }
    }

    @Test func addAccountSameEmailDeferredRuntimeRecycleRunsWhenCancellationCompletesJob() async throws {
        let environment = try isolatedHomeEnvironment()
        let manager = AuthCapableAppServerManager()
        let authSession = SameAccountSuccessfulLoginReviewAuthSession()
        let store = makeInjectedAuthSessionStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            authSessionFactory: {
                authSession
            }
        )

        try await withAsyncCleanup {
            await store.start()
            await store.refreshAuthentication()
            #expect(store.auth.account?.email == "review@example.com")
            let jobID = try store.enqueueReview(
                sessionID: "session-a",
                request: .init(
                    cwd: FileManager.default.currentDirectoryPath,
                    target: .uncommittedChanges
                )
            )
            store.markStarted(jobID: jobID, startedAt: Date())

            await store.addAccount()

            try store.completeCancellationLocally(
                jobID: jobID,
                sessionID: "session-a"
            )

            try await waitForAppServerLifecycleCounts(
                manager,
                prepareCount: 2,
                shutdownCount: 1
            )
        } cleanup: {
            await store.stop()
        }
    }

    @Test func unrelatedAddAccountDoesNotClearPendingDeferredRuntimeRecycle() async throws {
        let environment = try isolatedHomeEnvironment()
        let manager = AuthCapableAppServerManager()
        let authSession = MutableAuthenticatedLoginReviewAuthSession(
            currentEmail: "review@example.com",
            nextLoginEmails: ["review@example.com", "secondary@example.com"]
        )
        let store = makeInjectedAuthSessionStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            authSessionFactory: {
                authSession
            }
        )

        try await withAsyncCleanup {
            await store.start()
            await store.refreshAuthentication()
            #expect(store.auth.account?.email == "review@example.com")
            let jobID = try store.enqueueReview(
                sessionID: "session-a",
                request: .init(
                    cwd: FileManager.default.currentDirectoryPath,
                    target: .uncommittedChanges
                )
            )
            store.markStarted(jobID: jobID, startedAt: Date())

            await store.addAccount()
            await store.addAccount()

            #expect(await manager.prepareCount() == 1)
            #expect(await manager.shutdownCount() == 0)

            store.completeReview(
                jobID: jobID,
                outcome: .init(
                    state: .succeeded,
                    exitCode: 0,
                    reviewThreadID: nil,
                    threadID: nil,
                    turnID: nil,
                    model: nil,
                    hasFinalReview: false,
                    lastAgentMessage: "",
                    errorMessage: nil,
                    summary: "Completed.",
                    startedAt: Date(),
                    endedAt: Date(),
                    content: ""
                )
            )

            try await waitForAppServerLifecycleCounts(
                manager,
                prepareCount: 2,
                shutdownCount: 1
            )
        } cleanup: {
            await store.stop()
        }
    }

    @Test func addAccountSameEmailDeferredRuntimeRecycleClearsAfterRuntimeGenerationChanges() async throws {
        let environment = try isolatedHomeEnvironment()
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        _ = try saveReviewAccount(
            email: "review@example.com",
            makeActive: true,
            environment: environment,
            registryStore: registryStore
        )
        try writeReviewAuthSnapshot(
            email: "stale@example.com",
            planType: "pro",
            environment: environment
        )
        let authSession = SameAccountSuccessfulLoginReviewAuthSession()
        var recycleCallCount = 0
        let hasRunningJobs = MutableValueBox(true)
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                authSession
            },
            loginAuthSessionFactory: { environment in
                PersistingReviewAuthSession(
                    base: authSession,
                    environment: environment
                )
            },
            runtimeState: {
                .init(serverIsRunning: true, runtimeGeneration: 1)
            },
            recycleServerIfRunning: {
                recycleCallCount += 1
            },
            hasRunningJobs: {
                hasRunningJobs.value
            }
        )
        let initialAccounts = loadRegisteredReviewAccounts(environment: environment)
        auth.updateSavedAccounts(initialAccounts.accounts)
        auth.updateAccount(initialAccounts.accounts.first(where: { $0.accountKey == initialAccounts.activeAccountKey }))

        await auth.store.addAccount()
        #expect(recycleCallCount == 0)

        hasRunningJobs.value = false
        await auth.store.reconcileAuthenticatedSession(
            serverIsRunning: true,
            runtimeGeneration: 2
        )

        #expect(recycleCallCount == 0)
    }

    @Test func addAccountUnsavedSameEmailWithDifferentActiveSavedAccountDoesNotRecycleRuntime() async throws {
        let environment = try isolatedHomeEnvironment()
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        _ = try saveReviewAccount(
            email: "saved@example.com",
            makeActive: true,
            environment: environment,
            registryStore: registryStore
        )
        let authSession = SameAccountSuccessfulLoginReviewAuthSession()
        var recycleCallCount = 0
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                authSession
            },
            loginAuthSessionFactory: { environment in
                PersistingReviewAuthSession(
                    base: authSession,
                    environment: environment
                )
            },
            runtimeState: {
                .init(serverIsRunning: true, runtimeGeneration: 1)
            },
            recycleServerIfRunning: {
                recycleCallCount += 1
            }
        )
        let initialAccounts = loadRegisteredReviewAccounts(environment: environment)
        auth.updateSavedAccounts(initialAccounts.accounts)
        auth.updateAccount(CodexAccount(email: "review@example.com"))

        await auth.store.addAccount()

        let loadedAccounts = loadRegisteredReviewAccounts(environment: environment)
        #expect(recycleCallCount == 0)
        #expect(auth.account?.email == "review@example.com")
        #expect(auth.savedAccounts.first(where: \.isActive)?.email == "saved@example.com")
        #expect(loadedAccounts.activeAccountKey == "saved@example.com")
        #expect(loadSharedReviewAccount(environment: environment)?.email == "saved@example.com")
    }

    @Test func signInRetryAfterFailedAddAccountActivatesAuthenticatedAccount() async throws {
        let environment = try isolatedHomeEnvironment()
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        _ = try saveReviewAccount(
            email: "active@example.com",
            makeActive: true,
            environment: environment,
            registryStore: registryStore
        )
        let loginSession = SuccessfulLoginReviewAuthSession()
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                ImmediateReadAccountReviewAuthSession(
                    response: .init(
                        account: .chatGPT(email: "active@example.com", planType: "pro"),
                        requiresOpenAIAuth: false
                    )
                )
            },
            loginAuthSessionFactory: { environment in
                PersistingReviewAuthSession(
                    base: loginSession,
                    environment: environment
                )
            }
        )
        let initialAccounts = loadRegisteredReviewAccounts(environment: environment)
        auth.updateSavedAccounts(initialAccounts.accounts)
        auth.updateAccount(initialAccounts.accounts.first(where: { $0.accountKey == initialAccounts.activeAccountKey }))
        await auth.store.refreshAuthentication()
        auth.updatePhase(.failed(message: "Previous add-account failed."))

        await auth.store.signIn()

        let loadedAccounts = loadRegisteredReviewAccounts(environment: environment)
        #expect(auth.account?.email == "review@example.com")
        #expect(auth.savedAccounts.first(where: \.isActive)?.email == "review@example.com")
        #expect(auth.savedAccounts.map(\.email) == ["active@example.com", "review@example.com"])
        #expect(loadedAccounts.activeAccountKey == "review@example.com")
        #expect(loadedAccounts.accounts.map(\.email) == ["active@example.com", "review@example.com"])
        #expect(loadSharedReviewAccount(environment: environment)?.email == "review@example.com")
    }

    @Test func switchingToMissingAccountDoesNotCancelRunningJobs() async throws {
        let environment = try isolatedHomeEnvironment()
        let sharedSession = SignedOutReviewAuthSession()
        var cancelCallCount = 0
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                sharedSession
            },
            loginAuthSessionFactory: { _ in
                sharedSession
            },
            cancelRunningJobs: { _ in
                cancelCallCount += 1
            }
        )

        let missingAccount = CodexAccount(email: "missing@example.com")
        try await auth.store.switchAccount(missingAccount)
        #expect(cancelCallCount == 0)
    }

    @Test func switchingSavedAccountWhileServerStoppedHydratesPersistedSession() async throws {
        let environment = try isolatedHomeEnvironment()
        try writeReviewAuthSnapshot(
            email: "saved@example.com",
            planType: "pro",
            environment: environment
        )
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        _ = try registryStore.saveSharedAuthAsSavedAccount(makeActive: false)
        try FileManager.default.removeItem(at: ReviewHomePaths.reviewAuthURL(environment: environment))

        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                ImmediateReadAccountReviewAuthSession(
                    response: .init(
                        account: .chatGPT(email: "saved@example.com", planType: "pro"),
                        requiresOpenAIAuth: false
                    )
                )
            },
            loginAuthSessionFactory: { _ in
                SignedOutReviewAuthSession()
            }
        )
        auth.updateSavedAccounts(loadRegisteredReviewAccounts(environment: environment).accounts)
        let savedAccount = try #require(auth.savedAccounts.first)

        try await auth.store.switchAccount(savedAccount)

        #expect(auth.account?.email == "saved@example.com")
        #expect(auth.isAuthenticated)
        #expect(loadSharedReviewAccount(environment: environment)?.email == "saved@example.com")
    }

    @Test func switchingSavedAccountPromotesCurrentUnsavedSessionWithoutRecycleOrCleanup() async throws {
        let environment = try isolatedHomeEnvironment()
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        _ = try saveReviewAccount(
            email: "saved@example.com",
            makeActive: true,
            environment: environment,
            registryStore: registryStore
        )
        _ = try saveReviewAccount(
            email: "review@example.com",
            makeActive: false,
            environment: environment,
            registryStore: registryStore
        )
        try writeReviewAuthSnapshot(
            email: "review@example.com",
            planType: "pro",
            environment: environment
        )

        var cancelCallCount = 0
        var recycleCallCount = 0
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                SignedOutReviewAuthSession()
            },
            loginAuthSessionFactory: { _ in
                SignedOutReviewAuthSession()
            },
            runtimeState: {
                .init(serverIsRunning: true, runtimeGeneration: 1)
            },
            recycleServerIfRunning: {
                recycleCallCount += 1
            },
            cancelRunningJobs: { _ in
                cancelCallCount += 1
            }
        )
        auth.updateSavedAccounts(loadRegisteredReviewAccounts(environment: environment).accounts)
        let currentAccount = CodexAccount(email: "review@example.com")
        auth.updateAccount(currentAccount)
        let targetAccount = try #require(auth.savedAccounts.first(where: { $0.email == "review@example.com" }))

        try await auth.store.switchAccount(targetAccount)

        let loadedAccounts = loadRegisteredReviewAccounts(environment: environment)
        #expect(cancelCallCount == 0)
        #expect(recycleCallCount == 0)
        #expect(auth.account === currentAccount)
        #expect(auth.savedAccounts.first(where: \.isActive)?.email == "review@example.com")
        #expect(loadedAccounts.activeAccountKey == "review@example.com")
        #expect(loadSharedReviewAccount(environment: environment)?.email == "review@example.com")
    }

    @Test func switchingCurrentSavedAccountMarksItActiveWithoutOverwritingSharedAuth() async throws {
        let environment = try isolatedHomeEnvironment()
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        _ = try saveReviewAccount(
            email: "saved@example.com",
            makeActive: true,
            environment: environment,
            registryStore: registryStore
        )
        _ = try saveReviewAccount(
            email: "review@example.com",
            planType: "pro",
            makeActive: false,
            environment: environment,
            registryStore: registryStore
        )
        try writeReviewAuthSnapshot(
            email: "review@example.com",
            planType: "plus",
            environment: environment
        )

        var cancelCallCount = 0
        var recycleCallCount = 0
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                ImmediateReadAccountReviewAuthSession(
                    response: .init(
                        account: .chatGPT(email: "review@example.com", planType: "plus"),
                        requiresOpenAIAuth: false
                    )
                )
            },
            loginAuthSessionFactory: { _ in
                SignedOutReviewAuthSession()
            },
            runtimeState: {
                .init(serverIsRunning: true, runtimeGeneration: 1)
            },
            recycleServerIfRunning: {
                recycleCallCount += 1
            },
            cancelRunningJobs: { _ in
                cancelCallCount += 1
            }
        )
        auth.updateSavedAccounts(loadRegisteredReviewAccounts(environment: environment).accounts)
        let currentAccount = CodexAccount(email: "review@example.com", planType: "plus")
        auth.updateAccount(currentAccount)

        try await auth.store.switchAccount(CodexAccount(email: "review@example.com"))

        let loadedAccounts = loadRegisteredReviewAccounts(environment: environment)
        #expect(cancelCallCount == 0)
        #expect(recycleCallCount == 0)
        #expect(auth.account === currentAccount)
        #expect(auth.savedAccounts.first(where: \.isActive)?.email == "review@example.com")
        #expect(loadedAccounts.activeAccountKey == "review@example.com")
        #expect(loadSharedReviewAccount(environment: environment)?.planType == "plus")
    }

    @Test func switchingPersistedActiveAccountWithoutCurrentSessionHydratesSavedAccountWithoutRecycleOrCleanup() async throws {
        let environment = try isolatedHomeEnvironment()
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        _ = try saveReviewAccount(
            email: "saved@example.com",
            makeActive: true,
            environment: environment,
            registryStore: registryStore
        )

        var cancelCallCount = 0
        var recycleCallCount = 0
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                ImmediateReadAccountReviewAuthSession(
                    response: .init(
                        account: .chatGPT(email: "saved@example.com", planType: "pro"),
                        requiresOpenAIAuth: false
                    )
                )
            },
            loginAuthSessionFactory: { _ in
                SignedOutReviewAuthSession()
            },
            runtimeState: {
                .init(serverIsRunning: true, runtimeGeneration: 1)
            },
            recycleServerIfRunning: {
                recycleCallCount += 1
            },
            cancelRunningJobs: { _ in
                cancelCallCount += 1
            }
        )
        let initialAccounts = loadRegisteredReviewAccounts(environment: environment)
        auth.updateSavedAccounts(initialAccounts.accounts)
        auth.updateAccount(nil)
        auth.updatePhase(.signedOut)
        let savedAccount = try #require(auth.savedAccounts.first)

        try await auth.store.switchAccount(savedAccount)

        #expect(cancelCallCount == 1)
        #expect(recycleCallCount == 1)
        #expect(auth.account === savedAccount)
        #expect(auth.isAuthenticated)
        #expect(auth.savedAccounts.first(where: \.isActive)?.email == "saved@example.com")
    }

    @Test func switchingPersistedActiveAccountClearsFailedPhase() async throws {
        let environment = try isolatedHomeEnvironment()
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        _ = try saveReviewAccount(
            email: "saved@example.com",
            makeActive: true,
            environment: environment,
            registryStore: registryStore
        )
        try FileManager.default.removeItem(at: ReviewHomePaths.reviewAuthURL(environment: environment))

        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                ImmediateReadAccountReviewAuthSession(
                    response: .init(
                        account: .chatGPT(email: "saved@example.com", planType: "pro"),
                        requiresOpenAIAuth: false
                    )
                )
            },
            loginAuthSessionFactory: { _ in
                SignedOutReviewAuthSession()
            }
        )
        auth.updateSavedAccounts(loadRegisteredReviewAccounts(environment: environment).accounts)
        let savedAccount = try #require(auth.savedAccounts.first)
        auth.updateAccount(nil)
        auth.updatePhase(.failed(message: "Authentication required."))

        try await auth.store.switchAccount(savedAccount)

        #expect(testAuthState(from: auth) == .signedIn(accountID: "saved@example.com"))
        #expect(auth.errorMessage == nil)
    }

    @Test func switchingBackToPersistedActiveAccountRecyclesCurrentDifferentSession() async throws {
        let environment = try isolatedHomeEnvironment()
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        let savedAccount = try saveReviewAccount(
            email: "saved@example.com",
            makeActive: true,
            environment: environment,
            registryStore: registryStore
        )
        try writeReviewAuthSnapshot(
            email: "current@example.com",
            planType: "plus",
            environment: environment
        )

        var cancelCallCount = 0
        var recycleCallCount = 0
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                FileBackedSharedReviewAuthSession(environment: environment)
            },
            loginAuthSessionFactory: { _ in
                SignedOutReviewAuthSession()
            },
            runtimeState: {
                .init(serverIsRunning: true, runtimeGeneration: 1)
            },
            recycleServerIfRunning: {
                recycleCallCount += 1
            },
            cancelRunningJobs: { _ in
                cancelCallCount += 1
            }
        )
        auth.updateSavedAccounts(loadRegisteredReviewAccounts(environment: environment).accounts)
        auth.updateAccount(CodexAccount(email: "current@example.com"))

        try await auth.store.switchAccount(savedAccount)

        #expect(cancelCallCount == 1)
        #expect(recycleCallCount == 1)
        #expect(auth.account?.email == "saved@example.com")
        #expect(auth.savedAccounts.first(where: \.isActive)?.email == "saved@example.com")
        #expect(loadSharedReviewAccount(environment: environment)?.email == "saved@example.com")
    }

    @Test func removingActiveAccountSwitchesToFirstRemainingSavedAccount() async throws {
        let environment = try isolatedHomeEnvironment()
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        try writeReviewAuthSnapshot(
            email: "active@example.com",
            planType: "pro",
            environment: environment
        )
        _ = try registryStore.saveSharedAuthAsSavedAccount(makeActive: true)
        try writeReviewAuthSnapshot(
            email: "other@example.com",
            planType: "pro",
            environment: environment
        )
        _ = try registryStore.saveSharedAuthAsSavedAccount(makeActive: false)
        try writeReviewAuthSnapshot(
            email: "active@example.com",
            planType: "pro",
            environment: environment
        )

        let sharedSession = SignedOutReviewAuthSession()
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                sharedSession
            },
            loginAuthSessionFactory: { _ in
                sharedSession
            }
        )
        let initialAccounts = loadRegisteredReviewAccounts(environment: environment)
        auth.updateSavedAccounts(initialAccounts.accounts)
        auth.updateAccount(initialAccounts.accounts.first(where: { $0.accountKey == initialAccounts.activeAccountKey }))
        let activeAccount = try #require(auth.account)

        try await auth.store.removeAccount(accountKey: activeAccount.accountKey)

        let loadedAccounts = loadRegisteredReviewAccounts(environment: environment)
        #expect(testAuthState(from: auth) == .signedIn(accountID: "other@example.com"))
        #expect(loadedAccounts.activeAccountKey == "other@example.com")
        #expect(loadedAccounts.accounts.map(\.email) == ["other@example.com"])
        #expect(loadSharedReviewAccount(environment: environment)?.email == "other@example.com")
    }

    @Test func removingPersistedActiveAccountWhileSignedOutDoesNotPromoteReplacementAccount() async throws {
        let environment = try isolatedHomeEnvironment()
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        try writeReviewAuthSnapshot(
            email: "active@example.com",
            planType: "pro",
            environment: environment
        )
        guard let activeAccount = try registryStore.saveSharedAuthAsSavedAccount(makeActive: true) else {
            throw TestFailure("expected active account to be persisted")
        }
        try writeReviewAuthSnapshot(
            email: "other@example.com",
            planType: "pro",
            environment: environment
        )
        _ = try registryStore.saveSharedAuthAsSavedAccount(makeActive: false)
        try writeReviewAuthSnapshot(
            email: "active@example.com",
            planType: "pro",
            environment: environment
        )

        var cancelCallCount = 0
        var recycleCallCount = 0
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                SignedOutReviewAuthSession()
            },
            loginAuthSessionFactory: { _ in
                SignedOutReviewAuthSession()
            },
            runtimeState: {
                .init(serverIsRunning: true, runtimeGeneration: 1)
            },
            recycleServerIfRunning: {
                recycleCallCount += 1
            },
            cancelRunningJobs: { _ in
                cancelCallCount += 1
            }
        )
        let initialAccounts = loadRegisteredReviewAccounts(environment: environment)
        auth.updateSavedAccounts(initialAccounts.accounts)
        auth.updateAccount(nil)
        auth.updatePhase(.signedOut)

        try await auth.store.removeAccount(accountKey: activeAccount.accountKey)

        let loadedAccounts = loadRegisteredReviewAccounts(environment: environment)
        #expect(cancelCallCount == 0)
        #expect(recycleCallCount == 0)
        #expect(testAuthState(from: auth) == .signedOut)
        #expect(auth.account == nil)
        #expect(auth.savedAccounts.map(\.email) == ["other@example.com"])
        #expect(auth.savedAccounts.first(where: \.isActive)?.email == "other@example.com")
        #expect(loadedAccounts.activeAccountKey == "other@example.com")
    }

    @Test func removingInactiveSavedAccountPreservesSignedOutRecoverableState() async throws {
        let environment = try isolatedHomeEnvironment()
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        _ = try saveReviewAccount(
            email: "active@example.com",
            makeActive: true,
            environment: environment,
            registryStore: registryStore
        )
        _ = try saveReviewAccount(
            email: "other@example.com",
            makeActive: false,
            environment: environment,
            registryStore: registryStore
        )

        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                SignedOutReviewAuthSession()
            },
            loginAuthSessionFactory: { _ in
                SignedOutReviewAuthSession()
            }
        )
        auth.updateSavedAccounts(loadRegisteredReviewAccounts(environment: environment).accounts)
        auth.updateAccount(nil)
        auth.updatePhase(.signedOut)
        let removedAccount = try #require(auth.savedAccounts.first(where: { $0.email == "other@example.com" }))

        try await auth.store.removeAccount(accountKey: removedAccount.accountKey)

        let loadedAccounts = loadRegisteredReviewAccounts(environment: environment)
        #expect(auth.account == nil)
        #expect(testAuthState(from: auth) == .signedOut)
        #expect(auth.savedAccounts.map(\.email) == ["active@example.com"])
        #expect(auth.savedAccounts.first(where: \.isActive)?.email == "active@example.com")
        #expect(loadedAccounts.activeAccountKey == "active@example.com")
    }

    @Test func removingInactiveSavedAccountDoesNotClearUnsavedCurrentSession() async throws {
        let environment = try isolatedHomeEnvironment()
        try writeReviewAuthSnapshot(
            email: "saved@example.com",
            planType: "pro",
            environment: environment
        )
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        _ = try registryStore.saveSharedAuthAsSavedAccount(makeActive: false)
        try FileManager.default.removeItem(at: ReviewHomePaths.reviewAuthURL(environment: environment))

        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                SignedOutReviewAuthSession()
            },
            loginAuthSessionFactory: { _ in
                SignedOutReviewAuthSession()
            }
        )
        auth.updateSavedAccounts(loadRegisteredReviewAccounts(environment: environment).accounts)
        let currentAccount = CodexAccount(
            email: "current@example.com",
            planType: "pro"
        )
        auth.updatePhase(.signedOut)
        auth.updateAccount(currentAccount)
        let savedAccount = try #require(auth.savedAccounts.first)

        try await auth.store.removeAccount(accountKey: savedAccount.accountKey)

        #expect(auth.account?.email == "current@example.com")
        #expect(auth.savedAccounts.isEmpty)
    }

    @Test func removingSavedAccountPreservesUnsavedCurrentSessionWhenAnotherSavedAccountIsActive() async throws {
        let environment = try isolatedHomeEnvironment()
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        _ = try saveReviewAccount(
            email: "active@example.com",
            makeActive: true,
            environment: environment,
            registryStore: registryStore
        )
        _ = try saveReviewAccount(
            email: "other@example.com",
            makeActive: false,
            environment: environment,
            registryStore: registryStore
        )
        try writeReviewAuthSnapshot(
            email: "active@example.com",
            planType: "pro",
            environment: environment
        )

        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                SignedOutReviewAuthSession()
            },
            loginAuthSessionFactory: { _ in
                SignedOutReviewAuthSession()
            }
        )
        auth.updateSavedAccounts(loadRegisteredReviewAccounts(environment: environment).accounts)
        auth.updateAccount(CodexAccount(email: "current@example.com"))
        let removedAccount = try #require(auth.savedAccounts.first(where: { $0.email == "other@example.com" }))

        try await auth.store.removeAccount(accountKey: removedAccount.accountKey)

        let loadedAccounts = loadRegisteredReviewAccounts(environment: environment)
        #expect(auth.account?.email == "current@example.com")
        #expect(auth.savedAccounts.map(\.email) == ["active@example.com"])
        #expect(auth.savedAccounts.first(where: \.isActive)?.email == "active@example.com")
        #expect(loadedAccounts.activeAccountKey == "active@example.com")
        #expect(loadSharedReviewAccount(environment: environment)?.email == "active@example.com")
    }

    @Test func removingSavedAccountPreservesSavedCurrentSessionWhenAnotherSavedAccountIsActive() async throws {
        let environment = try isolatedHomeEnvironment()
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        _ = try saveReviewAccount(
            email: "active@example.com",
            makeActive: true,
            environment: environment,
            registryStore: registryStore
        )
        _ = try saveReviewAccount(
            email: "current@example.com",
            makeActive: false,
            environment: environment,
            registryStore: registryStore
        )
        _ = try saveReviewAccount(
            email: "other@example.com",
            makeActive: false,
            environment: environment,
            registryStore: registryStore
        )

        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                SignedOutReviewAuthSession()
            },
            loginAuthSessionFactory: { _ in
                SignedOutReviewAuthSession()
            }
        )
        auth.updateSavedAccounts(loadRegisteredReviewAccounts(environment: environment).accounts)
        let currentSavedAccount = try #require(auth.savedAccounts.first(where: { $0.email == "current@example.com" }))
        let removedAccount = try #require(auth.savedAccounts.first(where: { $0.email == "other@example.com" }))
        auth.updateAccount(currentSavedAccount)

        try await auth.store.removeAccount(accountKey: removedAccount.accountKey)

        let loadedAccounts = loadRegisteredReviewAccounts(environment: environment)
        #expect(auth.account?.email == "current@example.com")
        #expect(auth.savedAccounts.map(\.email) == ["active@example.com", "current@example.com"])
        #expect(auth.savedAccounts.first(where: \.isActive)?.email == "active@example.com")
        #expect(loadedAccounts.activeAccountKey == "active@example.com")
    }

    @Test func removingDetachedCurrentSavedAccountRestoresReplacementSharedAuth() async throws {
        let environment = try isolatedHomeEnvironment()
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        _ = try saveReviewAccount(
            email: "active@example.com",
            makeActive: true,
            environment: environment,
            registryStore: registryStore
        )
        let currentSavedAccount = try saveReviewAccount(
            email: "current@example.com",
            makeActive: false,
            environment: environment,
            registryStore: registryStore
        )
        try writeReviewAuthSnapshot(
            email: "current@example.com",
            planType: "pro",
            environment: environment
        )

        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                SignedOutReviewAuthSession()
            },
            loginAuthSessionFactory: { _ in
                SignedOutReviewAuthSession()
            }
        )
        auth.updateSavedAccounts(loadRegisteredReviewAccounts(environment: environment).accounts)
        auth.updateAccount(currentSavedAccount)

        try await auth.store.removeAccount(accountKey: currentSavedAccount.accountKey)

        let loadedAccounts = loadRegisteredReviewAccounts(environment: environment)
        #expect(auth.account?.email == "active@example.com")
        #expect(auth.savedAccounts.map(\.email) == ["active@example.com"])
        #expect(loadedAccounts.activeAccountKey == "active@example.com")
        #expect(loadSharedReviewAccount(environment: environment)?.email == "active@example.com")
    }

    @Test func removingActiveAccountKeepsReplacementWhenSharedAuthReadFails() async throws {
        let environment = try isolatedHomeEnvironment()
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        try writeReviewAuthSnapshot(
            email: "active@example.com",
            planType: "pro",
            environment: environment
        )
        _ = try registryStore.saveSharedAuthAsSavedAccount(makeActive: true)
        try writeReviewAuthSnapshot(
            email: "other@example.com",
            planType: "pro",
            environment: environment
        )
        _ = try registryStore.saveSharedAuthAsSavedAccount(makeActive: false)
        try writeReviewAuthSnapshot(
            email: "active@example.com",
            planType: "pro",
            environment: environment
        )

        let sharedSession = FailingReadAccountReviewAuthSession(message: "refresh failed")
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                sharedSession
            },
            loginAuthSessionFactory: { _ in
                sharedSession
            }
        )
        let initialAccounts = loadRegisteredReviewAccounts(environment: environment)
        auth.updateSavedAccounts(initialAccounts.accounts)
        auth.updateAccount(initialAccounts.accounts.first(where: { $0.accountKey == initialAccounts.activeAccountKey }))
        let activeAccount = try #require(auth.account)

        try await auth.store.removeAccount(accountKey: activeAccount.accountKey)

        let loadedAccounts = loadRegisteredReviewAccounts(environment: environment)
        #expect(testAuthState(from: auth) == .signedIn(accountID: "other@example.com"))
        #expect(auth.account?.email == "other@example.com")
        #expect(loadedAccounts.activeAccountKey == "other@example.com")
        #expect(loadedAccounts.accounts.map(\.email) == ["other@example.com"])
    }

    @Test func removingActiveAccountDoesNotRecreateDeletedAccountWhenForcedRefreshFallsBack() async throws {
        let environment = try isolatedHomeEnvironment()
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        try writeReviewAuthSnapshot(
            email: "active@example.com",
            planType: "pro",
            environment: environment
        )
        _ = try registryStore.saveSharedAuthAsSavedAccount(makeActive: true)
        try writeReviewAuthSnapshot(
            email: "other@example.com",
            planType: "pro",
            environment: environment
        )
        _ = try registryStore.saveSharedAuthAsSavedAccount(makeActive: false)
        try writeReviewAuthSnapshot(
            email: "active@example.com",
            planType: "pro",
            environment: environment
        )

        let sharedSession = SequencedReadAccountThenFailingReviewAuthSession(
            responses: [
                .init(
                    account: .chatGPT(email: "active@example.com", planType: "pro"),
                    requiresOpenAIAuth: false
                )
            ],
            failureMessage: "refresh failed"
        )
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                sharedSession
            },
            loginAuthSessionFactory: { _ in
                sharedSession
            }
        )
        let initialAccounts = loadRegisteredReviewAccounts(environment: environment)
        auth.updateSavedAccounts(initialAccounts.accounts)
        auth.updateAccount(initialAccounts.accounts.first(where: { $0.accountKey == initialAccounts.activeAccountKey }))
        let activeAccount = try #require(auth.account)

        try await auth.store.removeAccount(accountKey: activeAccount.accountKey)

        let loadedAccounts = loadRegisteredReviewAccounts(environment: environment)
        #expect(auth.account?.email == "other@example.com")
        #expect(auth.savedAccounts.map(\.email) == ["other@example.com"])
        #expect(loadedAccounts.activeAccountKey == "other@example.com")
        #expect(loadedAccounts.accounts.map(\.email) == ["other@example.com"])
    }

    @Test func removingActiveAccountWhileServerIsRunningRecyclesToReplacementAccount() async throws {
        let environment = try isolatedHomeEnvironment()
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        try writeReviewAuthSnapshot(
            email: "active@example.com",
            planType: "pro",
            environment: environment
        )
        _ = try registryStore.saveSharedAuthAsSavedAccount(makeActive: true)
        try writeReviewAuthSnapshot(
            email: "other@example.com",
            planType: "pro",
            environment: environment
        )
        _ = try registryStore.saveSharedAuthAsSavedAccount(makeActive: false)
        try writeReviewAuthSnapshot(
            email: "active@example.com",
            planType: "pro",
            environment: environment
        )

        let manager = AuthCapableAppServerManager()
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            sharedAuthSessionFactory: { _ in
                SignedOutReviewAuthSession()
            },
            loginAuthSessionFactory: { _ in
                SignedOutReviewAuthSession()
            },
            runtimeState: {
                .init(serverIsRunning: true, runtimeGeneration: 1)
            },
            recycleServerIfRunning: {
                await manager.shutdown()
                _ = try? await manager.prepare()
            }
        )
        let initialAccounts = loadRegisteredReviewAccounts(environment: environment)
        auth.updateSavedAccounts(initialAccounts.accounts)
        auth.updateAccount(initialAccounts.accounts.first(where: { $0.accountKey == initialAccounts.activeAccountKey }))

        try await auth.store.removeAccount(accountKey: "active@example.com")

        try await withTestTimeout(.seconds(2)) {
            while await manager.authTransportCheckoutCount() == 0 {
                await Task.yield()
            }
        }

        #expect(auth.account?.email == "other@example.com")
        #expect(await manager.prepareCount() == 1)
        #expect(await manager.shutdownCount() == 1)
        #expect(await manager.authTransportCheckoutCount() > 0)
    }

    @Test func failedAuthenticationWithoutPersistedDedicatedHomeAuthDoesNotRecycleSharedAppServer() async throws {
        let environment = try isolatedHomeEnvironment()
        let manager = AuthCapableAppServerManager()
        let authSession = NonPersistentSuccessfulLoginReviewAuthSession()
        let store = makeInjectedAuthSessionStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            authSessionFactory: {
                authSession
            }
        )

        await store.start()
        defer { Task { await store.stop() } }
        await store.signIn()

        #expect(testAuthState(from: store.auth) == .failed(reviewAuthPersistenceFailureMessage))
        #expect(await manager.prepareCount() == 1)
        #expect(await manager.shutdownCount() == 0)

        await store.stop()
    }

    @Test func legacyAuthSessionFactoryFailsLoginWithoutPersistedSharedAuth() async throws {
        let environment = try isolatedHomeEnvironment()
        let manager = AuthCapableAppServerManager()
        let authSession = SuccessfulLoginReviewAuthSession()
        let store = CodexReviewStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            authSessionFactory: {
                authSession
            }
        )

        await store.start()
        defer { Task { await store.stop() } }
        await store.signIn()

        #expect(testAuthState(from: store.auth) == .failed(reviewAuthPersistenceFailureMessage))

        await store.stop()
    }

    @Test func legacyAuthSessionFactorySupportsSameAccountReauthenticationWithPersistedSharedAuth() async throws {
        let environment = try isolatedHomeEnvironment()
        try writeReviewAuthSnapshot(
            email: "review@example.com",
            planType: "pro",
            environment: environment
        )
        let manager = AuthCapableAppServerManager()
        let authSession = SameAccountSuccessfulLoginReviewAuthSession()
        let store = CodexReviewStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            authSessionFactory: {
                authSession
            }
        )

        await store.start()
        defer { Task { await store.stop() } }
        await store.signIn()

        let loadedAccounts = loadRegisteredReviewAccounts(environment: environment)
        #expect(testAuthState(from: store.auth) == .signedIn(accountID: "review@example.com"))
        #expect(loadedAccounts.activeAccountKey == loadedAccounts.accounts.first?.accountKey)
        #expect(loadedAccounts.accounts.first?.email == "review@example.com")
        #expect(loadSharedReviewAccount(environment: environment)?.email == "review@example.com")

        await store.stop()
    }

    @Test func legacyAuthSessionFactoryDoesNotReplaceStaleSharedAuthSnapshotWithoutPersistedLogin() async throws {
        let environment = try isolatedHomeEnvironment()
        try writeReviewAuthSnapshot(
            email: "stale@example.com",
            planType: "pro",
            environment: environment
        )
        let manager = AuthCapableAppServerManager()
        let authSession = SuccessfulLoginReviewAuthSession()
        let store = CodexReviewStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            authSessionFactory: {
                authSession
            }
        )

        await store.start()
        defer { Task { await store.stop() } }
        await store.signIn()

        let loadedAccounts = loadRegisteredReviewAccounts(environment: environment)
        #expect(
            testAuthState(from: store.auth) == .failed(reviewAuthPersistenceFailureMessage)
        )
        #expect(loadedAccounts.activeAccountKey == nil)
        #expect(loadedAccounts.accounts.first?.email == "stale@example.com")
        #expect(loadSharedReviewAccount(environment: environment) == nil)

        await store.stop()
    }

    @Test func logoutRecyclesSharedAppServer() async throws {
        let environment = try isolatedHomeEnvironment()
        let manager = AuthCapableAppServerManager()
        let authSession = SuccessfulLogoutReviewAuthSession()
        let store = CodexReviewStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            authSessionFactory: {
                authSession
            }
        )

        await store.start()
        defer { Task { await store.stop() } }
        applyTestAuthState(auth: store.auth, state: .signedIn(accountID: "review@example.com"))
        await store.logout()

        #expect(testAuthState(from: store.auth) == .signedOut)
        #expect(await manager.prepareCount() == 2)
        #expect(await manager.shutdownCount() == 1)

        await store.stop()
    }

    @Test func logoutFailureUsesResolvedSignedOutState() async throws {
        let environment = try isolatedHomeEnvironment()
        let manager = AuthCapableAppServerManager()
        let authSession = FailingLogoutReviewAuthSession()
        let store = CodexReviewStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            authSessionFactory: {
                authSession
            }
        )

        await store.start()
        defer { Task { await store.stop() } }
        applyTestAuthState(auth: store.auth, state: .signedIn(accountID: "review@example.com"))
        await store.logout()

        #expect(testAuthState(from: store.auth) == .signedOut)
        #expect(await manager.prepareCount() == 2)
        #expect(await manager.shutdownCount() == 1)

        await store.stop()
    }

    @Test func logoutFailureRecoveredToSignedOutRemovesSharedAuthForInactiveCurrentSession() async throws {
        let environment = try isolatedHomeEnvironment()
        let registryStore = ReviewAccountRegistryStore(environment: environment)
        _ = try saveReviewAccount(
            email: "active@example.com",
            makeActive: true,
            environment: environment,
            registryStore: registryStore
        )
        let currentSavedAccount = try saveReviewAccount(
            email: "review@example.com",
            makeActive: false,
            environment: environment,
            registryStore: registryStore
        )
        try writeReviewAuthSnapshot(
            email: "review@example.com",
            planType: "pro",
            environment: environment
        )

        let authSession = FailingLogoutReviewAuthSession()
        let auth = makeAuthModel(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            sharedAuthSessionFactory: { _ in
                authSession
            },
            loginAuthSessionFactory: { _ in
                authSession
            }
        )
        auth.updateSavedAccounts(loadRegisteredReviewAccounts(environment: environment).accounts)
        auth.updateAccount(currentSavedAccount)

        await auth.store.logout()

        #expect(testAuthState(from: auth) == .signedOut)
        #expect(loadSharedReviewAccount(environment: environment) == nil)
        #expect(auth.savedAccounts.first(where: \.isActive)?.email == "active@example.com")
    }

    @Test func logoutFailurePreservesResolvedAuthenticatedState() async throws {
        let environment = try isolatedHomeEnvironment()
        let manager = AuthCapableAppServerManager()
        let authSession = LogoutFailureWithPersistedAuthReviewAuthSession()
        let store = CodexReviewStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            authSessionFactory: {
                authSession
            }
        )

        await store.start()
        defer { Task { await store.stop() } }
        applyTestAuthState(auth: store.auth, state: .signedIn(accountID: "review@example.com"))
        await store.logout()

        #expect(
            testAuthState(from: store.auth) == .failed(
                "Failed to sign out.",
                isAuthenticated: true,
                accountID: "review@example.com"
            )
        )
        #expect(await manager.prepareCount() == 1)
        #expect(await manager.shutdownCount() == 0)

        await store.stop()
    }

    @Test func logoutFailureRefreshesRateLimitsWhenResolvedAccountChanges() async throws {
        let environment = try isolatedHomeEnvironment()
        let firstTransport = AuthCapableAppServerSessionTransport()
        let secondTransport = AuthCapableAppServerSessionTransport()
        await secondTransport.updateRateLimitsResponse(
            current: [
                "limitId": "codex",
                "limitName": NSNull(),
                "primary": [
                    "usedPercent": 22,
                    "windowDurationMins": 300,
                    "resetsAt": 1_735_776_000,
                ],
                "secondary": [
                    "usedPercent": 11,
                    "windowDurationMins": 10080,
                    "resetsAt": 1_736_380_800,
                ],
            ],
            byLimitID: [
                "codex": [
                    "limitId": "codex",
                    "limitName": NSNull(),
                    "primary": [
                        "usedPercent": 22,
                        "windowDurationMins": 300,
                        "resetsAt": 1_735_776_000,
                    ],
                    "secondary": [
                        "usedPercent": 11,
                        "windowDurationMins": 10080,
                        "resetsAt": 1_736_380_800,
                    ],
                ],
            ]
        )
        let manager = AuthCapableAppServerManager(
            authTransports: [firstTransport, secondTransport]
        )
        let authSession = LogoutFailureWithChangedAccountReviewAuthSession()
        let store = CodexReviewStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            authSessionFactory: {
                authSession
            }
        )
        let fiveHourProbe = ObservableValueProbe { rateLimitWindow(duration: 300, in: store.auth.account)?.usedPercent }
        defer { fiveHourProbe.cancel() }

        await store.start()
        defer { Task { await store.stop() } }
        try await waitForObservedValue(fiveHourProbe) {
            $0 == 40
        }

        await store.logout()

        try await waitForObservedValue(fiveHourProbe) {
            $0 == 22
        }

        #expect(
            testAuthState(from: store.auth) == .failed(
                "Failed to sign out.",
                isAuthenticated: true,
                accountID: "new@example.com"
            )
        )
        #expect(rateLimitWindow(duration: 10_080, in: store.auth.account)?.usedPercent == 11)
        #expect(await manager.prepareCount() == 2)
        #expect(await manager.shutdownCount() == 1)

        await store.stop()
    }

    @Test func reviewMonitorStoreUsesInjectedNativeAuthSessionFactory() async throws {
        let environment = try isolatedHomeEnvironment()
        let manager = AuthCapableAppServerManager()
        let recorder = TestWebAuthenticationSessionRecorder()
        let nativeAuthenticationConfiguration = ReviewMonitorNativeAuthenticationConfiguration(
            callbackScheme: "lynnpd.codexreviewmonitor.auth",
            browserSessionPolicy: .ephemeral,
            presentationAnchorProvider: { NSWindow() }
        )
        let webAuthenticationSessionFactory = makeWebAuthenticationSessionFactory(
            recorder: recorder,
            autoResult: .success(URL(string: "lynnpd.codexreviewmonitor.auth://callback?code=123")!)
        )
        let store = CodexReviewStore.makeReviewMonitorStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            nativeAuthenticationConfiguration: nativeAuthenticationConfiguration,
            webAuthenticationSessionFactory: webAuthenticationSessionFactory,
            loginAuthSessionFactoryOverride: makeInjectedNativeLoginAuthSessionFactory(
                manager: manager,
                nativeAuthenticationConfiguration: nativeAuthenticationConfiguration,
                webAuthenticationSessionFactory: webAuthenticationSessionFactory
            )
        )

        let updates = ObservableValueProbe { testAuthState(from: store.auth) }

        await store.signIn()

        try await waitForObservedValue(updates) { $0.isAuthenticated }

        #expect(await manager.authTransportCheckoutCount() > 0)
        #expect(await recorder.lastAuthenticateRequest()?.callbackScheme == "lynnpd.codexreviewmonitor.auth")
        #expect(await recorder.lastAuthenticateRequest()?.prefersEphemeral == true)
        let authTransport = try #require(await manager.authTransportForTesting())
        #expect(await authTransport.completeParams()?.callbackURL == "lynnpd.codexreviewmonitor.auth://callback?code=123")
        #expect(testAuthState(from: store.auth) == TestAuthState.signedIn(accountID: "review@example.com"))
    }

    @Test func reviewMonitorStoreCancelsNativeAuthenticationFlow() async throws {
        let environment = try isolatedHomeEnvironment()
        let manager = AuthCapableAppServerManager()
        let recorder = TestWebAuthenticationSessionRecorder()
        let nativeAuthenticationConfiguration = ReviewMonitorNativeAuthenticationConfiguration(
            callbackScheme: "lynnpd.codexreviewmonitor.auth",
            browserSessionPolicy: .ephemeral,
            presentationAnchorProvider: { NSWindow() }
        )
        let webAuthenticationSessionFactory = makeWebAuthenticationSessionFactory(
            recorder: recorder,
            autoResult: .failure(.cancelled)
        )
        let store = CodexReviewStore.makeReviewMonitorStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            nativeAuthenticationConfiguration: nativeAuthenticationConfiguration,
            webAuthenticationSessionFactory: webAuthenticationSessionFactory,
            loginAuthSessionFactoryOverride: makeInjectedNativeLoginAuthSessionFactory(
                manager: manager,
                nativeAuthenticationConfiguration: nativeAuthenticationConfiguration,
                webAuthenticationSessionFactory: webAuthenticationSessionFactory
            )
        )

        await store.signIn()

        let authTransport = try #require(await manager.authTransportForTesting())
        #expect(await authTransport.completeParams() == nil)
        #expect(await recorder.cancelCallCount() == 0)
        #expect(testAuthState(from: store.auth) == TestAuthState.signedOut)
    }

    @Test func reviewMonitorStorePreservesAuthenticatedStateWhenRetryAuthenticationIsCancelled() async throws {
        let environment = try isolatedHomeEnvironment()
        let manager = AuthCapableAppServerManager()
        let recorder = TestWebAuthenticationSessionRecorder()
        let nativeAuthenticationConfiguration = ReviewMonitorNativeAuthenticationConfiguration(
            callbackScheme: "lynnpd.codexreviewmonitor.auth",
            browserSessionPolicy: .ephemeral,
            presentationAnchorProvider: { NSWindow() }
        )
        let webAuthenticationSessionFactory = makeWebAuthenticationSessionFactory(
            recorder: recorder,
            autoResult: .failure(.cancelled)
        )
        let store = CodexReviewStore.makeReviewMonitorStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            nativeAuthenticationConfiguration: nativeAuthenticationConfiguration,
            webAuthenticationSessionFactory: webAuthenticationSessionFactory,
            loginAuthSessionFactoryOverride: makeInjectedNativeLoginAuthSessionFactory(
                manager: manager,
                nativeAuthenticationConfiguration: nativeAuthenticationConfiguration,
                webAuthenticationSessionFactory: webAuthenticationSessionFactory
            )
        )
        applyTestAuthState(auth: store.auth, state: 
            .failed(
                "Authentication failed.",
                isAuthenticated: true,
                accountID: "review@example.com"
            )
        )

        await store.signIn()

        #expect(
            testAuthState(from: store.auth) == .failed(
                "Authentication failed.",
                isAuthenticated: true,
                accountID: "review@example.com"
            )
        )
    }

    @Test func reviewMonitorLoginAuthSessionFactoryShutsDownManagerWhenStartupFails() async throws {
        let environment = try isolatedHomeEnvironment()
        let manager = AuthCapableAppServerManager(requirePrepareBeforeAuthCheckout: true)
        let recorder = TestWebAuthenticationSessionRecorder()
        let nativeAuthenticationConfiguration = ReviewMonitorNativeAuthenticationConfiguration(
            callbackScheme: "lynnpd.codexreviewmonitor.auth",
            browserSessionPolicy: .ephemeral,
            presentationAnchorProvider: { NSWindow() }
        )
        let webAuthenticationSessionFactory = makeWebAuthenticationSessionFactory(
            recorder: recorder
        )
        let factory = CodexReviewStore.makeReviewMonitorLoginAuthSessionFactory(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            nativeAuthenticationConfiguration: nativeAuthenticationConfiguration,
            webAuthenticationSessionFactory: webAuthenticationSessionFactory,
            runtimeManagerFactory: { _ in manager }
        )

        await #expect(throws: Error.self) {
            _ = try await factory(environment)
        }

        #expect(await manager.shutdownCount() == 1)
        #expect(await recorder.lastAuthenticateRequest() == nil)
    }

    @Test func reviewMonitorStorePreservesAccountMetadataWhileAuthenticatedRetryIsInProgress() async throws {
        let environment = try isolatedHomeEnvironment()
        let authSession = BlockingLoginReviewAuthSession()
        let authFactory = CountingReviewAuthSessionFactory(session: authSession)
        let store = CodexReviewStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: MockAppServerManager { _ in .success() },
            authSessionFactory: {
                try await authFactory.makeSession()
            }
        )
        applyTestAuthState(auth: store.auth, state: 
            .failed(
                "Authentication failed.",
                isAuthenticated: true,
                accountID: "review@example.com"
            )
        )

        let beginTask = Task {
            await store.signIn()
        }

        await authSession.waitForLoginStart()

        #expect(store.auth.isAuthenticating)
        #expect(store.auth.isAuthenticated)
        #expect(store.auth.account?.email == "review@example.com")

        await store.cancelAuthentication()
        #expect(
            testAuthState(from: store.auth) == .failed(
                "Authentication failed.",
                isAuthenticated: true,
                accountID: "review@example.com"
            )
        )
        _ = await beginTask.value
        #expect(
            testAuthState(from: store.auth) == .failed(
                "Authentication failed.",
                isAuthenticated: true,
                accountID: "review@example.com"
            )
        )
    }

    @Test func reviewMonitorStoreUsesConfiguredCallbackSchemeForLegacyAuthenticationResponse() async throws {
        let environment = try isolatedHomeEnvironment()
        let manager = AuthCapableAppServerManager(
            authTransport: AuthCapableAppServerSessionTransport(
                startLoginBehavior: .legacyBrowser
            )
        )
        let recorder = TestWebAuthenticationSessionRecorder()
        let nativeAuthenticationConfiguration = ReviewMonitorNativeAuthenticationConfiguration(
            callbackScheme: "lynnpd.codexreviewmonitor.auth",
            browserSessionPolicy: .ephemeral,
            presentationAnchorProvider: { NSWindow() }
        )
        let webAuthenticationSessionFactory = makeWebAuthenticationSessionFactory(
            recorder: recorder,
            autoResult: .success(URL(string: "lynnpd.codexreviewmonitor.auth://callback?code=123")!)
        )
        let store = CodexReviewStore.makeReviewMonitorStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            nativeAuthenticationConfiguration: nativeAuthenticationConfiguration,
            webAuthenticationSessionFactory: webAuthenticationSessionFactory,
            loginAuthSessionFactoryOverride: makeInjectedNativeLoginAuthSessionFactory(
                manager: manager,
                nativeAuthenticationConfiguration: nativeAuthenticationConfiguration,
                webAuthenticationSessionFactory: webAuthenticationSessionFactory
            )
        )
        applyTestAuthState(auth: store.auth, state: 
            .failed(
                "Authentication failed.",
                isAuthenticated: true,
                accountID: "review@example.com"
            )
        )

        await store.signIn()

        #expect(await recorder.lastAuthenticateRequest()?.callbackScheme == "lynnpd.codexreviewmonitor.auth")
        #expect(testAuthState(from: store.auth) == .signedIn(accountID: "review@example.com"))
        #expect(await manager.shutdownCount() == 0)
        #expect(await manager.prepareCount() == 0)
    }

    @Test func reviewMonitorStoreFailsNativeAuthenticationWhenCompleteEndpointIsUnsupported() async throws {
        let environment = try isolatedHomeEnvironment()
        let manager = AuthCapableAppServerManager(
            authTransport: AuthCapableAppServerSessionTransport(
                completeLoginBehavior: .unsupported
            )
        )
        let recorder = TestWebAuthenticationSessionRecorder()
        let nativeAuthenticationConfiguration = ReviewMonitorNativeAuthenticationConfiguration(
            callbackScheme: "lynnpd.codexreviewmonitor.auth",
            browserSessionPolicy: .ephemeral,
            presentationAnchorProvider: { NSWindow() }
        )
        let webAuthenticationSessionFactory = makeWebAuthenticationSessionFactory(
            recorder: recorder,
            autoResult: .success(URL(string: "lynnpd.codexreviewmonitor.auth://callback?code=123")!)
        )
        let store = CodexReviewStore.makeReviewMonitorStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            nativeAuthenticationConfiguration: nativeAuthenticationConfiguration,
            webAuthenticationSessionFactory: webAuthenticationSessionFactory,
            loginAuthSessionFactoryOverride: makeInjectedNativeLoginAuthSessionFactory(
                manager: manager,
                nativeAuthenticationConfiguration: nativeAuthenticationConfiguration,
                webAuthenticationSessionFactory: webAuthenticationSessionFactory
            )
        )

        await store.signIn()

        #expect(
            testAuthState(from: store.auth) == .failed(
                "Authentication completion is unavailable. Update the app-server and try again."
            )
        )
    }

    @Test func reviewMonitorStorePresentsOAuthForLegacyAuthenticationResponse() async throws {
        let environment = try isolatedHomeEnvironment()
        let manager = AuthCapableAppServerManager(
            authTransport: AuthCapableAppServerSessionTransport(
                startLoginBehavior: .legacyBrowser
            )
        )
        let recorder = TestWebAuthenticationSessionRecorder()
        let nativeAuthenticationConfiguration = ReviewMonitorNativeAuthenticationConfiguration(
            callbackScheme: "lynnpd.codexreviewmonitor.auth",
            browserSessionPolicy: .ephemeral,
            presentationAnchorProvider: { NSWindow() }
        )
        let webAuthenticationSessionFactory = makeWebAuthenticationSessionFactory(
            recorder: recorder,
            autoResult: .success(URL(string: "lynnpd.codexreviewmonitor.auth://callback?code=123")!)
        )
        let store = CodexReviewStore.makeReviewMonitorStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            nativeAuthenticationConfiguration: nativeAuthenticationConfiguration,
            webAuthenticationSessionFactory: webAuthenticationSessionFactory,
            loginAuthSessionFactoryOverride: makeInjectedNativeLoginAuthSessionFactory(
                manager: manager,
                nativeAuthenticationConfiguration: nativeAuthenticationConfiguration,
                webAuthenticationSessionFactory: webAuthenticationSessionFactory
            )
        )

        await store.signIn()

        #expect(await recorder.lastAuthenticateRequest()?.url.absoluteString == "https://auth.openai.com/oauth/authorize?foo=bar")
        #expect(await recorder.lastAuthenticateRequest()?.callbackScheme == "lynnpd.codexreviewmonitor.auth")
        #expect(testAuthState(from: store.auth) == .signedIn(accountID: "review@example.com"))
    }

    @Test func reviewMonitorStoreFailsNativeAuthenticationWhenCallbackSchemeDoesNotMatch() async throws {
        let environment = try isolatedHomeEnvironment()
        let manager = AuthCapableAppServerManager(
            authTransport: AuthCapableAppServerSessionTransport(
                startLoginBehavior: .customNativeCallback("other.app.callback")
            )
        )
        let recorder = TestWebAuthenticationSessionRecorder()
        let nativeAuthenticationConfiguration = ReviewMonitorNativeAuthenticationConfiguration(
            callbackScheme: "lynnpd.codexreviewmonitor.auth",
            browserSessionPolicy: .ephemeral,
            presentationAnchorProvider: { NSWindow() }
        )
        let webAuthenticationSessionFactory = makeWebAuthenticationSessionFactory(
            recorder: recorder,
            autoResult: .success(URL(string: "lynnpd.codexreviewmonitor.auth://callback?code=123")!)
        )
        let store = CodexReviewStore.makeReviewMonitorStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            nativeAuthenticationConfiguration: nativeAuthenticationConfiguration,
            webAuthenticationSessionFactory: webAuthenticationSessionFactory,
            loginAuthSessionFactoryOverride: makeInjectedNativeLoginAuthSessionFactory(
                manager: manager,
                nativeAuthenticationConfiguration: nativeAuthenticationConfiguration,
                webAuthenticationSessionFactory: webAuthenticationSessionFactory
            )
        )

        await store.signIn()

        #expect(await recorder.lastAuthenticateRequest() == nil)
        #expect(
            testAuthState(from: store.auth) == .failed(
                "Authentication callback is misconfigured. Update the app-server and try again."
            )
        )
    }

    @Test func reviewMonitorStoreCompletesNativeAuthenticationWithoutFollowUpNotifications() async throws {
        let environment = try isolatedHomeEnvironment()
        let manager = AuthCapableAppServerManager(
            authTransport: AuthCapableAppServerSessionTransport(
                completeLoginBehavior: .succeedWithoutNotifications
            )
        )
        let recorder = TestWebAuthenticationSessionRecorder()
        let nativeAuthenticationConfiguration = ReviewMonitorNativeAuthenticationConfiguration(
            callbackScheme: "lynnpd.codexreviewmonitor.auth",
            browserSessionPolicy: .ephemeral,
            presentationAnchorProvider: { NSWindow() }
        )
        let webAuthenticationSessionFactory = makeWebAuthenticationSessionFactory(
            recorder: recorder,
            autoResult: .success(URL(string: "lynnpd.codexreviewmonitor.auth://callback?code=123")!)
        )
        let store = CodexReviewStore.makeReviewMonitorStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            nativeAuthenticationConfiguration: nativeAuthenticationConfiguration,
            webAuthenticationSessionFactory: webAuthenticationSessionFactory,
            loginAuthSessionFactoryOverride: makeInjectedNativeLoginAuthSessionFactory(
                manager: manager,
                nativeAuthenticationConfiguration: nativeAuthenticationConfiguration,
                webAuthenticationSessionFactory: webAuthenticationSessionFactory
            )
        )

        await store.signIn()

        #expect(testAuthState(from: store.auth) == .signedIn(accountID: "review@example.com"))
    }

    @Test func reviewMonitorStoreCompletesNativeAuthenticationWhenServerOnlyPublishesAccountUpdated() async throws {
        let environment = try isolatedHomeEnvironment()
        let manager = AuthCapableAppServerManager(
            authTransport: AuthCapableAppServerSessionTransport(
                completeLoginBehavior: .succeedWithAccountUpdatedOnly
            )
        )
        let recorder = TestWebAuthenticationSessionRecorder()
        let nativeAuthenticationConfiguration = ReviewMonitorNativeAuthenticationConfiguration(
            callbackScheme: "lynnpd.codexreviewmonitor.auth",
            browserSessionPolicy: .ephemeral,
            presentationAnchorProvider: { NSWindow() }
        )
        let webAuthenticationSessionFactory = makeWebAuthenticationSessionFactory(
            recorder: recorder,
            autoResult: .success(URL(string: "lynnpd.codexreviewmonitor.auth://callback?code=123")!)
        )
        let store = CodexReviewStore.makeReviewMonitorStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            nativeAuthenticationConfiguration: nativeAuthenticationConfiguration,
            webAuthenticationSessionFactory: webAuthenticationSessionFactory,
            loginAuthSessionFactoryOverride: makeInjectedNativeLoginAuthSessionFactory(
                manager: manager,
                nativeAuthenticationConfiguration: nativeAuthenticationConfiguration,
                webAuthenticationSessionFactory: webAuthenticationSessionFactory
            )
        )

        await store.signIn()

        #expect(testAuthState(from: store.auth) == .signedIn(accountID: "review@example.com"))
    }

    @Test func reviewMonitorStoreWaitsOutDelayedPersistenceAfterNativeAuthenticationCompletion() async throws {
        let environment = try isolatedHomeEnvironment()
        let manager = AuthCapableAppServerManager(
            authTransport: AuthCapableAppServerSessionTransport(
                completeLoginBehavior: .succeedWithoutNotifications,
                postCompleteAccountReadResponses: [
                    [
                        "account": NSNull(),
                        "requiresOpenaiAuth": true,
                    ],
                ]
            )
        )
        let recorder = TestWebAuthenticationSessionRecorder()
        let nativeAuthenticationConfiguration = ReviewMonitorNativeAuthenticationConfiguration(
            callbackScheme: "lynnpd.codexreviewmonitor.auth",
            browserSessionPolicy: .ephemeral,
            presentationAnchorProvider: { NSWindow() }
        )
        let webAuthenticationSessionFactory = makeWebAuthenticationSessionFactory(
            recorder: recorder,
            autoResult: .success(URL(string: "lynnpd.codexreviewmonitor.auth://callback?code=123")!)
        )
        let store = CodexReviewStore.makeReviewMonitorStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            nativeAuthenticationConfiguration: nativeAuthenticationConfiguration,
            webAuthenticationSessionFactory: webAuthenticationSessionFactory,
            loginAuthSessionFactoryOverride: makeInjectedNativeLoginAuthSessionFactory(
                manager: manager,
                nativeAuthenticationConfiguration: nativeAuthenticationConfiguration,
                webAuthenticationSessionFactory: webAuthenticationSessionFactory
            )
        )

        await store.signIn()

        #expect(testAuthState(from: store.auth) == .signedIn(accountID: "review@example.com"))
    }

    @Test func nativeAuthSessionFinishesLateSubscribersAfterCancellation() async throws {
        let transport = AuthCapableAppServerSessionTransport()
        let recorder = TestWebAuthenticationSessionRecorder()
        let session = NativeWebAuthenticationReviewSession(
            sharedSession: SharedAppServerReviewAuthSession(transport: transport),
            nativeAuthenticationConfiguration: .init(
                callbackScheme: "lynnpd.codexreviewmonitor.auth",
                browserSessionPolicy: .ephemeral,
                presentationAnchorProvider: { NSWindow() }
            ),
            webAuthenticationSessionFactory: makeWebAuthenticationSessionFactory(
                recorder: recorder,
                autoResult: .failure(.cancelled)
            )
        )
        defer { Task { await session.close() } }

        _ = try await session.startLogin(.chatGPT)
        await session.waitForAuthenticationTaskCompletion()

        let notificationStream = await session.notificationStream()

        try await withTestTimeout {
            for try await _ in notificationStream {
                Issue.record("Expected late native-auth subscribers to observe terminal cancellation without buffered notifications.")
            }
        }
    }

    @Test func nativeAuthSessionFailsLateSubscribersAfterAuthenticationFailure() async throws {
        let transport = AuthCapableAppServerSessionTransport()
        let recorder = TestWebAuthenticationSessionRecorder()
        let session = NativeWebAuthenticationReviewSession(
            sharedSession: SharedAppServerReviewAuthSession(transport: transport),
            nativeAuthenticationConfiguration: .init(
                callbackScheme: "lynnpd.codexreviewmonitor.auth",
                browserSessionPolicy: .ephemeral,
                presentationAnchorProvider: { NSWindow() }
            ),
            webAuthenticationSessionFactory: makeWebAuthenticationSessionFactory(
                recorder: recorder,
                autoResult: .failure(.loginFailed("Authentication failed."))
            )
        )
        defer { Task { await session.close() } }

        _ = try await session.startLogin(.chatGPT)
        await session.waitForAuthenticationTaskCompletion()

        let notificationStream = await session.notificationStream()

        await #expect(throws: ReviewAuthError.loginFailed("Authentication failed.")) {
            try await withTestTimeout {
                for try await _ in notificationStream {
                    Issue.record("Expected late native-auth subscribers to fail before receiving notifications.")
                }
            }
        }
    }

    @Test func nativeAuthSessionCloseCancelsActiveLogin() async throws {
        let transport = AuthCapableAppServerSessionTransport()
        let recorder = TestWebAuthenticationSessionRecorder()
        let session = NativeWebAuthenticationReviewSession(
            sharedSession: SharedAppServerReviewAuthSession(transport: transport),
            nativeAuthenticationConfiguration: .init(
                callbackScheme: "lynnpd.codexreviewmonitor.auth",
                browserSessionPolicy: .ephemeral,
                presentationAnchorProvider: { NSWindow() }
            ),
            webAuthenticationSessionFactory: makeWebAuthenticationSessionFactory(
                recorder: recorder
            )
        )

        _ = try await session.startLogin(.chatGPT)
        await session.close()

        #expect(await recorder.cancelCallCount() == 1)
        #expect(await transport.cancelLoginIDs() == ["login-browser"])
        #expect(await transport.isClosed())
    }

    @Test func nativeAuthSessionDoesNotCancelCompletedLoginWithoutLoginID() async throws {
        let transport = AuthCapableAppServerSessionTransport(
            completeLoginBehavior: .succeedWithoutLoginID
        )
        let recorder = TestWebAuthenticationSessionRecorder()
        let session = NativeWebAuthenticationReviewSession(
            sharedSession: SharedAppServerReviewAuthSession(transport: transport),
            nativeAuthenticationConfiguration: .init(
                callbackScheme: "lynnpd.codexreviewmonitor.auth",
                browserSessionPolicy: .ephemeral,
                presentationAnchorProvider: { NSWindow() }
            ),
            webAuthenticationSessionFactory: makeWebAuthenticationSessionFactory(
                recorder: recorder,
                autoResult: .success(URL(string: "lynnpd.codexreviewmonitor.auth://callback?code=123")!)
            )
        )

        _ = try await session.startLogin(.chatGPT)
        await session.waitForAuthenticationTaskCompletion()
        await session.close()

        #expect(await transport.cancelLoginIDs().isEmpty)
    }

    @Test func forceRestartStopsServerAndRecordedAppServerGroup() async throws {
        let endpointRecord = LiveEndpointRecord(
            url: "http://localhost:9417/mcp",
            host: "localhost",
            port: 9417,
            pid: 100,
            serverStartTime: .init(seconds: 1, microseconds: 0),
            updatedAt: Date(),
            executableName: nil
        )
        let runtimeState = ReviewRuntimeStateRecord(
            serverPID: 100,
            serverStartTime: .init(seconds: 1, microseconds: 0),
            appServerPID: 200,
            appServerStartTime: .init(seconds: 2, microseconds: 0),
            appServerProcessGroupLeaderPID: 200,
            appServerProcessGroupLeaderStartTime: .init(seconds: 2, microseconds: 0),
            updatedAt: Date()
        )
        let environment = FakeForcedRestartEnvironment()
        environment.addProcess(pid: 100, startTime: .init(seconds: 1, microseconds: 0), termAction: .exit)
        environment.addProcess(pid: 200, startTime: .init(seconds: 2, microseconds: 0), groupLeaderPID: 200, termAction: .ignore)

        let clock = TestRestartClock()
        try await runWithRestartClock(clock) {
            try await forceRestart(
                endpointRecord: endpointRecord,
                runtimeState: runtimeState,
                terminateGracePeriod: .milliseconds(100),
                killGracePeriod: .seconds(2),
                clock: clock,
                runtime: environment.runtime()
            )
        }

        #expect(environment.isAlive(100) == false)
        #expect(environment.isAlive(200) == false)
    }

    @Test func forceRestartIgnoresRuntimeStateWhenServerIdentityMismatches() async throws {
        let endpointRecord = LiveEndpointRecord(
            url: "http://localhost:9417/mcp",
            host: "localhost",
            port: 9417,
            pid: 100,
            serverStartTime: .init(seconds: 1, microseconds: 0),
            updatedAt: Date(),
            executableName: nil
        )
        let runtimeState = ReviewRuntimeStateRecord(
            serverPID: 999,
            serverStartTime: .init(seconds: 9, microseconds: 0),
            appServerPID: 200,
            appServerStartTime: .init(seconds: 2, microseconds: 0),
            appServerProcessGroupLeaderPID: 200,
            appServerProcessGroupLeaderStartTime: .init(seconds: 2, microseconds: 0),
            updatedAt: Date()
        )
        let environment = FakeForcedRestartEnvironment()
        environment.addProcess(pid: 100, startTime: .init(seconds: 1, microseconds: 0), termAction: .exit)
        environment.addProcess(pid: 200, startTime: .init(seconds: 2, microseconds: 0), groupLeaderPID: 200, termAction: .ignore)

        let clock = TestRestartClock()
        try await runWithRestartClock(clock) {
            try await forceRestart(
                endpointRecord: endpointRecord,
                runtimeState: runtimeState,
                terminateGracePeriod: .milliseconds(100),
                killGracePeriod: .seconds(2),
                clock: clock,
                runtime: environment.runtime()
            )
        }

        #expect(environment.isAlive(100) == false)
        #expect(environment.isAlive(200))
    }

    @Test func forceRestartDoesNotScanDescendantsOfReusedServerPID() async throws {
        let endpointRecord = LiveEndpointRecord(
            url: "http://localhost:9417/mcp",
            host: "localhost",
            port: 9417,
            pid: 100,
            serverStartTime: .init(seconds: 1, microseconds: 0),
            updatedAt: Date(),
            executableName: nil
        )
        let environment = FakeForcedRestartEnvironment()
        environment.addProcess(
            pid: 100,
            startTime: .init(seconds: 9, microseconds: 0),
            termAction: .ignore
        )
        environment.addProcess(
            pid: 200,
            parentPID: 100,
            startTime: .init(seconds: 10, microseconds: 0),
            groupLeaderPID: 200,
            termAction: .ignore
        )

        let clock = TestRestartClock()
        try await runWithRestartClock(clock) {
            try await forceRestart(
                endpointRecord: endpointRecord,
                runtimeState: nil,
                terminateGracePeriod: .milliseconds(100),
                killGracePeriod: .seconds(2),
                clock: clock,
                runtime: environment.runtime()
            )
        }

        #expect(environment.isAlive(100))
        #expect(environment.isAlive(200))
    }

    @Test func forceRestartMergesPersistedRuntimeStateWithLiveDescendantGroups() async throws {
        let endpointRecord = LiveEndpointRecord(
            url: "http://localhost:9417/mcp",
            host: "localhost",
            port: 9417,
            pid: 100,
            serverStartTime: .init(seconds: 1, microseconds: 0),
            updatedAt: Date(),
            executableName: nil
        )
        let runtimeState = ReviewRuntimeStateRecord(
            serverPID: 100,
            serverStartTime: .init(seconds: 1, microseconds: 0),
            appServerPID: 200,
            appServerStartTime: .init(seconds: 2, microseconds: 0),
            appServerProcessGroupLeaderPID: 200,
            appServerProcessGroupLeaderStartTime: .init(seconds: 2, microseconds: 0),
            updatedAt: Date()
        )
        let environment = FakeForcedRestartEnvironment()
        environment.addProcess(
            pid: 100,
            startTime: .init(seconds: 1, microseconds: 0),
            termAction: .exit
        )
        environment.addProcess(
            pid: 200,
            parentPID: 100,
            startTime: .init(seconds: 2, microseconds: 0),
            groupLeaderPID: 200,
            termAction: .ignore
        )
        environment.addProcess(
            pid: 300,
            parentPID: 100,
            startTime: .init(seconds: 3, microseconds: 0),
            groupLeaderPID: 300,
            termAction: .ignore
        )

        let clock = TestRestartClock()
        try await runWithRestartClock(clock) {
            try await forceRestart(
                endpointRecord: endpointRecord,
                runtimeState: runtimeState,
                terminateGracePeriod: .milliseconds(100),
                killGracePeriod: .seconds(2),
                clock: clock,
                runtime: environment.runtime()
            )
        }

        #expect(environment.isAlive(100) == false)
        #expect(environment.isAlive(200) == false)
        #expect(environment.isAlive(300) == false)
    }

    @Test func forceRestartFallsBackToLiveChildProcessGroupWhenRuntimeStateIsMissing() async throws {
        let endpointRecord = LiveEndpointRecord(
            url: "http://localhost:9417/mcp",
            host: "localhost",
            port: 9417,
            pid: 100,
            serverStartTime: .init(seconds: 1, microseconds: 0),
            updatedAt: Date(),
            executableName: nil
        )
        let environment = FakeForcedRestartEnvironment()
        environment.addProcess(
            pid: 100,
            startTime: .init(seconds: 1, microseconds: 0),
            termAction: .exit
        )
        environment.addProcess(
            pid: 200,
            parentPID: 100,
            startTime: .init(seconds: 2, microseconds: 0),
            groupLeaderPID: 200,
            termAction: .ignore
        )
        environment.addProcess(
            pid: 300,
            parentPID: 200,
            startTime: .init(seconds: 3, microseconds: 0),
            groupLeaderPID: 300,
            termAction: .ignore
        )

        let clock = TestRestartClock()
        try await runWithRestartClock(clock) {
            try await forceRestart(
                endpointRecord: endpointRecord,
                runtimeState: nil,
                terminateGracePeriod: .milliseconds(100),
                killGracePeriod: .seconds(2),
                clock: clock,
                runtime: environment.runtime()
            )
        }

        #expect(environment.isAlive(100) == false)
        #expect(environment.isAlive(200) == false)
        #expect(environment.isAlive(300) == false)
    }

    @Test func forceRestartFallsBackToServersProcessGroupWhenChildrenShareIt() async throws {
        let endpointRecord = LiveEndpointRecord(
            url: "http://localhost:9417/mcp",
            host: "localhost",
            port: 9417,
            pid: 100,
            serverStartTime: .init(seconds: 1, microseconds: 0),
            updatedAt: Date(),
            executableName: nil
        )
        let environment = FakeForcedRestartEnvironment()
        environment.addProcess(
            pid: 100,
            startTime: .init(seconds: 1, microseconds: 0),
            termAction: .exit
        )
        environment.addProcess(
            pid: 200,
            parentPID: 100,
            startTime: .init(seconds: 2, microseconds: 0),
            groupLeaderPID: 100,
            termAction: .ignore
        )

        let clock = TestRestartClock()
        try await runWithRestartClock(clock) {
            try await forceRestart(
                endpointRecord: endpointRecord,
                runtimeState: nil,
                terminateGracePeriod: .milliseconds(100),
                killGracePeriod: .seconds(2),
                clock: clock,
                runtime: environment.runtime()
            )
        }

        #expect(environment.isAlive(100) == false)
        #expect(environment.isAlive(200) == false)
    }

    @Test func forceRestartKeepsTrackingFallbackProcessGroupAfterLeaderExits() async throws {
        let endpointRecord = LiveEndpointRecord(
            url: "http://localhost:9417/mcp",
            host: "localhost",
            port: 9417,
            pid: 100,
            serverStartTime: .init(seconds: 1, microseconds: 0),
            updatedAt: Date(),
            executableName: nil
        )
        let environment = FakeForcedRestartEnvironment()
        environment.addProcess(
            pid: 100,
            startTime: .init(seconds: 1, microseconds: 0),
            termAction: .exit
        )
        environment.addProcess(
            pid: 200,
            parentPID: 100,
            startTime: .init(seconds: 2, microseconds: 0),
            groupLeaderPID: 200,
            termAction: .exit
        )
        environment.addProcess(
            pid: 201,
            parentPID: 200,
            startTime: .init(seconds: 3, microseconds: 0),
            groupLeaderPID: 200,
            termAction: .ignore
        )

        let clock = TestRestartClock()
        try await runWithRestartClock(clock) {
            try await forceRestart(
                endpointRecord: endpointRecord,
                runtimeState: nil,
                terminateGracePeriod: .milliseconds(100),
                killGracePeriod: .seconds(2),
                clock: clock,
                runtime: environment.runtime()
            )
        }

        #expect(environment.isAlive(100) == false)
        #expect(environment.isAlive(200) == false)
        #expect(environment.isAlive(201) == false)
    }
}

final class TestRestartClock: Clock, @unchecked Sendable {
    typealias Instant = ContinuousClock.Instant
    typealias Duration = Swift.Duration

    private struct SleepWaiter {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct State {
        var now: Instant
        var sleepers: [UInt64: SleepWaiter] = [:]
        var nextSleepToken: UInt64 = 0
    }

    private let lock = NSLock()
    private var state: State

    init(now: Instant = ContinuousClock().now) {
        state = State(now: now)
    }

    var now: Instant {
        lock.withLock { state.now }
    }

    var minimumResolution: Duration { .nanoseconds(1) }

    var hasSleepers: Bool {
        lock.withLock { state.sleepers.isEmpty == false }
    }

    func sleep(until deadline: Instant, tolerance _: Duration? = nil) async throws {
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
                let shouldResumeImmediately = lock.withLock { () -> Bool in
                    if deadline <= state.now {
                        return true
                    }
                    state.sleepers[sleepToken] = SleepWaiter(
                        deadline: deadline,
                        continuation: continuation
                    )
                    return false
                }

                if shouldResumeImmediately {
                    continuation.resume(returning: ())
                }
            }
        } onCancel: {
            let continuation = lock.withLock { state.sleepers.removeValue(forKey: sleepToken)?.continuation }
            continuation?.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        precondition(duration >= .zero)
        let readyContinuations: [CheckedContinuation<Void, Error>] = lock.withLock {
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
}

actor RestartTaskResultBox {
    private var result: Result<Void, Error>?

    func store(_ result: Result<Void, Error>) {
        self.result = result
    }

    func current() -> Result<Void, Error>? {
        result
    }
}

actor DelayedShutdownAppServerManager: AppServerManaging {
    private let runtimeState: AppServerRuntimeState
    private var shutdownStarted = false
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeRequested = false

    init(runtimeState: AppServerRuntimeState) {
        self.runtimeState = runtimeState
    }

    func prepare() async throws -> AppServerRuntimeState {
        runtimeState
    }

    func checkoutTransport(sessionID _: String) async throws -> any AppServerSessionTransport {
        MockAppServerSessionTransport(mode: .success())
    }

    func checkoutAuthTransport() async throws -> any AppServerSessionTransport {
        MockAppServerSessionTransport(mode: .success())
    }

    func currentRuntimeState() async -> AppServerRuntimeState? {
        runtimeState
    }

    func diagnosticLineStream() async -> AsyncStream<String> {
        let (stream, continuation) = AsyncStream<String>.makeStream()
        continuation.finish()
        return stream
    }

    func diagnosticsTail() async -> String {
        ""
    }

    func shutdown() async {
        shutdownStarted = true
        let waiters = shutdownWaiters
        shutdownWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
        if resumeRequested {
            return
        }
        await withCheckedContinuation { continuation in
            resumeWaiters.append(continuation)
        }
    }

    func waitForShutdownStart() async {
        if shutdownStarted {
            return
        }
        await withCheckedContinuation { continuation in
            if shutdownStarted {
                continuation.resume()
            } else {
                shutdownWaiters.append(continuation)
            }
        }
    }

    func resumeShutdown() {
        resumeRequested = true
        let waiters = resumeWaiters
        resumeWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }
}

actor DelayedConnectAppServerManager: AppServerManaging {
    private let runtimeState: AppServerRuntimeState
    private var connectStarted = false
    private var connectStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var connectResumeWaiters: [CheckedContinuation<Void, Never>] = []
    private var connectResumed = false
    private var transport: MockAppServerSessionTransport?

    init(runtimeState: AppServerRuntimeState) {
        self.runtimeState = runtimeState
    }

    func prepare() async throws -> AppServerRuntimeState {
        runtimeState
    }

    func checkoutTransport(sessionID _: String) async throws -> any AppServerSessionTransport {
        connectStarted = true
        let startWaiters = connectStartWaiters
        connectStartWaiters.removeAll(keepingCapacity: false)
        for waiter in startWaiters {
            waiter.resume()
        }
        if connectResumed == false {
            await withCheckedContinuation { continuation in
                connectResumeWaiters.append(continuation)
            }
        }
        let transport = MockAppServerSessionTransport(mode: .success())
        self.transport = transport
        return transport
    }

    func checkoutAuthTransport() async throws -> any AppServerSessionTransport {
        MockAppServerSessionTransport(mode: .success())
    }

    func currentRuntimeState() async -> AppServerRuntimeState? {
        runtimeState
    }

    func diagnosticLineStream() async -> AsyncStream<String> {
        let (stream, continuation) = AsyncStream<String>.makeStream()
        continuation.finish()
        return stream
    }

    func diagnosticsTail() async -> String {
        ""
    }

    func shutdown() async {}

    func waitForConnectStart() async {
        if connectStarted {
            return
        }
        await withCheckedContinuation { continuation in
            if connectStarted {
                continuation.resume()
            } else {
                connectStartWaiters.append(continuation)
            }
        }
    }

    func resumeConnect() {
        connectResumed = true
        let waiters = connectResumeWaiters
        connectResumeWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    func createdTransport() -> MockAppServerSessionTransport? {
        transport
    }
}

actor BlockingPrepareAppServerManager: AppServerManaging {
    private let runtimeState: AppServerRuntimeState
    private var prepareCountStorage = 0
    private var shutdownCountStorage = 0
    private var firstPrepareStarted = false
    private var firstPrepareStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var blockedPrepareContinuations: [CheckedContinuation<AppServerRuntimeState, Error>] = []

    init(runtimeState: AppServerRuntimeState) {
        self.runtimeState = runtimeState
    }

    func prepare() async throws -> AppServerRuntimeState {
        prepareCountStorage += 1
        if prepareCountStorage == 1 {
            firstPrepareStarted = true
            let waiters = firstPrepareStartWaiters
            firstPrepareStartWaiters.removeAll(keepingCapacity: false)
            for waiter in waiters {
                waiter.resume()
            }
            return try await withCheckedThrowingContinuation { continuation in
                blockedPrepareContinuations.append(continuation)
            }
        }
        return runtimeState
    }

    func checkoutTransport(sessionID _: String) async throws -> any AppServerSessionTransport {
        MockAppServerSessionTransport(mode: .success())
    }

    func checkoutAuthTransport() async throws -> any AppServerSessionTransport {
        MockAppServerSessionTransport(mode: .success())
    }

    func currentRuntimeState() async -> AppServerRuntimeState? {
        runtimeState
    }

    func diagnosticLineStream() async -> AsyncStream<String> {
        let (stream, continuation) = AsyncStream<String>.makeStream()
        continuation.finish()
        return stream
    }

    func diagnosticsTail() async -> String {
        ""
    }

    func shutdown() async {
        shutdownCountStorage += 1
        let continuations = blockedPrepareContinuations
        blockedPrepareContinuations.removeAll(keepingCapacity: false)
        for continuation in continuations {
            continuation.resume(throwing: CancellationError())
        }
    }

    func waitForPrepareStart() async {
        if firstPrepareStarted {
            return
        }
        await withCheckedContinuation { continuation in
            if firstPrepareStarted {
                continuation.resume()
            } else {
                firstPrepareStartWaiters.append(continuation)
            }
        }
    }

    func prepareCount() -> Int {
        prepareCountStorage
    }

    func shutdownCount() -> Int {
        shutdownCountStorage
    }
}

actor CountingReviewAuthSessionFactory {
    private let session: BlockingLoginReviewAuthSession
    private var creationCountStorage = 0

    init(session: BlockingLoginReviewAuthSession) {
        self.session = session
    }

    func makeSession() async throws -> any ReviewAuthSession {
        creationCountStorage += 1
        return session
    }

    func creationCount() -> Int {
        creationCountStorage
    }
}

actor BlockingLoginReviewAuthSession: ReviewAuthSession {
    private var loginParams: [AppServerLoginAccountParams] = []
    private var cancelledIDs: [String] = []
    private var continuation: AsyncThrowingStream<AppServerServerNotification, Error>.Continuation?
    private let loginStartedSignal = AsyncSignal()

    func readAccount(refreshToken _: Bool) async throws -> AppServerAccountReadResponse {
        .init(account: nil, requiresOpenAIAuth: true)
    }

    func startLogin(_ params: AppServerLoginAccountParams) async throws -> AppServerLoginAccountResponse {
        loginParams.append(params)
        await loginStartedSignal.signal()
        return .chatGPT(
            loginID: "login-browser",
            authURL: "https://auth.openai.com/oauth/authorize?foo=bar"
        )
    }

    func cancelLogin(loginID: String) async throws {
        cancelledIDs.append(loginID)
    }

    func logout() async throws {}

    func notificationStream() async -> AsyncThrowingStream<AppServerServerNotification, Error> {
        let (stream, continuation) = AsyncThrowingStream<AppServerServerNotification, Error>.makeStream()
        setContinuation(continuation)
        continuation.onTermination = { _ in
            Task {
                await self.close()
            }
        }
        return stream
    }

    func close() async {
        continuation?.finish()
        continuation = nil
    }

    func recordedLoginParams() -> [AppServerLoginAccountParams] {
        loginParams
    }

    func cancelledLoginIDs() -> [String] {
        cancelledIDs
    }

    func waitForLoginStart() async {
        await loginStartedSignal.wait()
    }

    private func setContinuation(
        _ continuation: AsyncThrowingStream<AppServerServerNotification, Error>.Continuation
    ) {
        self.continuation = continuation
    }
}

actor DeferredCloseLoginReviewAuthSession: ReviewAuthSession {
    private var loginParams: [AppServerLoginAccountParams] = []
    private var cancelledIDs: [String] = []
    private var continuation: AsyncThrowingStream<AppServerServerNotification, Error>.Continuation?
    private let loginStartedSignal = AsyncSignal()
    private let closeRequestedSignal = AsyncSignal()
    private let closeResumeGate = OneShotGate()
    private var closeRequested = false

    func readAccount(refreshToken _: Bool) async throws -> AppServerAccountReadResponse {
        .init(account: nil, requiresOpenAIAuth: true)
    }

    func startLogin(_ params: AppServerLoginAccountParams) async throws -> AppServerLoginAccountResponse {
        loginParams.append(params)
        await loginStartedSignal.signal()
        return .chatGPT(
            loginID: "login-browser",
            authURL: "https://auth.openai.com/oauth/authorize?foo=bar"
        )
    }

    func cancelLogin(loginID: String) async throws {
        cancelledIDs.append(loginID)
    }

    func logout() async throws {}

    func notificationStream() async -> AsyncThrowingStream<AppServerServerNotification, Error> {
        let (stream, continuation) = AsyncThrowingStream<AppServerServerNotification, Error>.makeStream()
        self.continuation = continuation
        continuation.onTermination = { _ in
            Task {
                await self.close()
            }
        }
        return stream
    }

    func close() async {
        closeRequested = true
        await closeRequestedSignal.signal()
        Task { [weak self] in
            guard let self else {
                return
            }
            await self.closeResumeGate.wait()
            await self.finishContinuation()
        }
    }

    func waitForLoginStart() async {
        await loginStartedSignal.wait()
    }

    func waitForCloseRequest() async {
        if closeRequested {
            return
        }
        await closeRequestedSignal.wait()
    }

    func finishPendingClose() async {
        await closeResumeGate.open()
    }

    func cancelledLoginIDs() -> [String] {
        cancelledIDs
    }

    private func finishContinuation() {
        continuation?.finish()
        continuation = nil
    }
}

actor SlowReadAccountReviewAuthSession: ReviewAuthSession {
    private var readAccountCallCountStorage = 0
    private let readStartedSignal = AsyncSignal()
    private let readResumeGate = OneShotGate()

    func readAccount(refreshToken _: Bool) async throws -> AppServerAccountReadResponse {
        readAccountCallCountStorage += 1
        await readStartedSignal.signal()
        await readResumeGate.wait()
        try Task.checkCancellation()
        return .init(account: nil, requiresOpenAIAuth: true)
    }

    func startLogin(_ params: AppServerLoginAccountParams) async throws -> AppServerLoginAccountResponse {
        _ = params
        return .chatGPT(
            loginID: "login-browser",
            authURL: "https://auth.openai.com/oauth/authorize?foo=bar"
        )
    }

    func cancelLogin(loginID _: String) async throws {}

    func logout() async throws {}

    func notificationStream() async -> AsyncThrowingStream<AppServerServerNotification, Error> {
        .init { $0.finish() }
    }

    func close() async {}

    func readAccountCallCount() -> Int {
        readAccountCallCountStorage
    }

    func waitForReadAccountStart() async {
        await readStartedSignal.wait()
    }

    func resumeReadAccount() async {
        await readResumeGate.open()
    }
}

actor ImmediateReadAccountReviewAuthSession: ReviewAuthSession {
    private let response: AppServerAccountReadResponse

    init(response: AppServerAccountReadResponse) {
        self.response = response
    }

    func readAccount(refreshToken _: Bool) async throws -> AppServerAccountReadResponse {
        response
    }

    func startLogin(_ params: AppServerLoginAccountParams) async throws -> AppServerLoginAccountResponse {
        _ = params
        return .chatGPT(
            loginID: "login-browser",
            authURL: "https://auth.openai.com/oauth/authorize?foo=bar"
        )
    }

    func cancelLogin(loginID _: String) async throws {}

    func logout() async throws {}

    func notificationStream() async -> AsyncThrowingStream<AppServerServerNotification, Error> {
        .init { $0.finish() }
    }

    func close() async {}
}

actor FailingReadAccountReviewAuthSession: ReviewAuthSession {
    private let message: String

    init(message: String) {
        self.message = message
    }

    func readAccount(refreshToken _: Bool) async throws -> AppServerAccountReadResponse {
        throw NSError(
            domain: "CodexReviewMCPTests.FailingReadAccountReviewAuthSession",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    func startLogin(_ params: AppServerLoginAccountParams) async throws -> AppServerLoginAccountResponse {
        _ = params
        return .chatGPT(
            loginID: "login-browser",
            authURL: "https://auth.openai.com/oauth/authorize?foo=bar"
        )
    }

    func cancelLogin(loginID _: String) async throws {}

    func logout() async throws {}

    func notificationStream() async -> AsyncThrowingStream<AppServerServerNotification, Error> {
        .init { $0.finish() }
    }

    func close() async {}
}

actor SignedOutReviewAuthSession: ReviewAuthSession {
    func readAccount(refreshToken _: Bool) async throws -> AppServerAccountReadResponse {
        .init(account: nil, requiresOpenAIAuth: true)
    }

    func startLogin(_ params: AppServerLoginAccountParams) async throws -> AppServerLoginAccountResponse {
        _ = params
        return .chatGPT(
            loginID: "login-browser",
            authURL: "https://auth.openai.com/oauth/authorize?foo=bar"
        )
    }

    func cancelLogin(loginID _: String) async throws {}

    func logout() async throws {}

    func notificationStream() async -> AsyncThrowingStream<AppServerServerNotification, Error> {
        .init { $0.finish() }
    }

    func close() async {}
}

actor FileBackedSharedReviewAuthSession: ReviewAuthSession {
    private let environment: [String: String]

    init(environment: [String: String]) {
        self.environment = environment
    }

    func readAccount(refreshToken _: Bool) async throws -> AppServerAccountReadResponse {
        guard let snapshot = await MainActor.run(
            body: { () -> (email: String, planType: String?)? in
                guard let account = loadSharedReviewAccount(environment: environment) else {
                    return nil
                }
                return (email: account.email, planType: account.planType)
            }
        ) else {
            return .init(account: nil, requiresOpenAIAuth: true)
        }
        return .init(
            account: .chatGPT(email: snapshot.email, planType: snapshot.planType ?? "free"),
            requiresOpenAIAuth: false
        )
    }

    func startLogin(_ params: AppServerLoginAccountParams) async throws -> AppServerLoginAccountResponse {
        _ = params
        return .chatGPT(
            loginID: "login-browser",
            authURL: "https://auth.openai.com/oauth/authorize?foo=bar"
        )
    }

    func cancelLogin(loginID _: String) async throws {}

    func logout() async throws {}

    func notificationStream() async -> AsyncThrowingStream<AppServerServerNotification, Error> {
        .init { $0.finish() }
    }

    func close() async {}
}

actor BlockingReadAccountReviewAuthSession: ReviewAuthSession {
    private let readStartedSignal = AsyncSignal()
    private let finishReadSignal = AsyncSignal()

    func readAccount(refreshToken _: Bool) async throws -> AppServerAccountReadResponse {
        await readStartedSignal.signal()
        await finishReadSignal.wait()
        return .init(account: nil, requiresOpenAIAuth: true)
    }

    func startLogin(_ params: AppServerLoginAccountParams) async throws -> AppServerLoginAccountResponse {
        _ = params
        return .chatGPT(
            loginID: "login-browser",
            authURL: "https://auth.openai.com/oauth/authorize?foo=bar"
        )
    }

    func cancelLogin(loginID _: String) async throws {}

    func logout() async throws {}

    func notificationStream() async -> AsyncThrowingStream<AppServerServerNotification, Error> {
        .init { $0.finish() }
    }

    func close() async {}

    func waitForReadStart() async {
        await readStartedSignal.wait()
    }

    func finishRead() async {
        await finishReadSignal.signal()
    }
}

actor SequencedReadAccountReviewAuthSession: ReviewAuthSession {
    private var responses: [AppServerAccountReadResponse]

    init(responses: [AppServerAccountReadResponse]) {
        precondition(responses.isEmpty == false)
        self.responses = responses
    }

    func readAccount(refreshToken _: Bool) async throws -> AppServerAccountReadResponse {
        if responses.count == 1 {
            return responses[0]
        }
        return responses.removeFirst()
    }

    func startLogin(_ params: AppServerLoginAccountParams) async throws -> AppServerLoginAccountResponse {
        _ = params
        return .chatGPT(
            loginID: "login-browser",
            authURL: "https://auth.openai.com/oauth/authorize?foo=bar"
        )
    }

    func cancelLogin(loginID _: String) async throws {}

    func logout() async throws {}

    func notificationStream() async -> AsyncThrowingStream<AppServerServerNotification, Error> {
        .init { $0.finish() }
    }

    func close() async {}
}

actor SequencedReadAccountThenFailingReviewAuthSession: ReviewAuthSession {
    private var responses: [AppServerAccountReadResponse]
    private let failureMessage: String

    init(
        responses: [AppServerAccountReadResponse],
        failureMessage: String
    ) {
        self.responses = responses
        self.failureMessage = failureMessage
    }

    func readAccount(refreshToken _: Bool) async throws -> AppServerAccountReadResponse {
        if responses.isEmpty {
            throw NSError(
                domain: "CodexReviewMCPTests.SequencedReadAccountThenFailingReviewAuthSession",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: failureMessage]
            )
        }
        return responses.removeFirst()
    }

    func startLogin(_ params: AppServerLoginAccountParams) async throws -> AppServerLoginAccountResponse {
        _ = params
        return .chatGPT(
            loginID: "login-browser",
            authURL: "https://auth.openai.com/oauth/authorize?foo=bar"
        )
    }

    func cancelLogin(loginID _: String) async throws {}

    func logout() async throws {}

    func notificationStream() async -> AsyncThrowingStream<AppServerServerNotification, Error> {
        .init { $0.finish() }
    }

    func close() async {}
}

actor SuccessfulLoginReviewAuthSession: ReviewAuthSession {
    private var continuation: AsyncThrowingStream<AppServerServerNotification, Error>.Continuation?
    private var bufferedNotifications: [AppServerServerNotification] = []
    private var didLogin = false

    func readAccount(refreshToken _: Bool) async throws -> AppServerAccountReadResponse {
        if didLogin {
            return .init(
                account: .chatGPT(email: "review@example.com", planType: "pro"),
                requiresOpenAIAuth: false
            )
        }
        return .init(account: nil, requiresOpenAIAuth: true)
    }

    func startLogin(_ params: AppServerLoginAccountParams) async throws -> AppServerLoginAccountResponse {
        _ = params
        didLogin = true
        buffer(.accountUpdated(.init(authMode: .chatGPT, planType: "pro")))
        buffer(.accountLoginCompleted(.init(error: nil, loginID: "login-browser", success: true)))
        return .chatGPT(
            loginID: "login-browser",
            authURL: "https://auth.openai.com/oauth/authorize?foo=bar"
        )
    }

    func cancelLogin(loginID _: String) async throws {}

    func logout() async throws {}

    func notificationStream() async -> AsyncThrowingStream<AppServerServerNotification, Error> {
        let (stream, continuation) = AsyncThrowingStream<AppServerServerNotification, Error>.makeStream()
        setContinuation(continuation)
        return stream
    }

    func close() async {
        continuation?.finish()
        continuation = nil
    }

    private func setContinuation(
        _ continuation: AsyncThrowingStream<AppServerServerNotification, Error>.Continuation
    ) {
        self.continuation = continuation
        let bufferedNotifications = self.bufferedNotifications
        self.bufferedNotifications.removeAll(keepingCapacity: false)
        for notification in bufferedNotifications {
            continuation.yield(notification)
        }
    }

    private func buffer(_ notification: AppServerServerNotification) {
        if let continuation {
            continuation.yield(notification)
        } else {
            bufferedNotifications.append(notification)
        }
    }
}

actor SuccessfulLogoutReviewAuthSession: ReviewAuthSession {
    func readAccount(refreshToken _: Bool) async throws -> AppServerAccountReadResponse {
        .init(account: nil, requiresOpenAIAuth: true)
    }

    func startLogin(_ params: AppServerLoginAccountParams) async throws -> AppServerLoginAccountResponse {
        _ = params
        return .chatGPT(
            loginID: "login-browser",
            authURL: "https://auth.openai.com/oauth/authorize?foo=bar"
        )
    }

    func cancelLogin(loginID _: String) async throws {}

    func logout() async throws {}

    func notificationStream() async -> AsyncThrowingStream<AppServerServerNotification, Error> {
        .init { $0.finish() }
    }

    func close() async {}
}

actor SameAccountSuccessfulLoginReviewAuthSession: ReviewAuthSession {
    private var continuation: AsyncThrowingStream<AppServerServerNotification, Error>.Continuation?
    private var bufferedNotifications: [AppServerServerNotification] = []

    func readAccount(refreshToken _: Bool) async throws -> AppServerAccountReadResponse {
        .init(
            account: .chatGPT(email: "review@example.com", planType: "pro"),
            requiresOpenAIAuth: false
        )
    }

    func startLogin(_ params: AppServerLoginAccountParams) async throws -> AppServerLoginAccountResponse {
        _ = params
        buffer(.accountUpdated(.init(authMode: .chatGPT, planType: "pro")))
        buffer(.accountLoginCompleted(.init(error: nil, loginID: "login-browser", success: true)))
        return .chatGPT(
            loginID: "login-browser",
            authURL: "https://auth.openai.com/oauth/authorize?foo=bar"
        )
    }

    func cancelLogin(loginID _: String) async throws {}

    func logout() async throws {}

    func notificationStream() async -> AsyncThrowingStream<AppServerServerNotification, Error> {
        let (stream, continuation) = AsyncThrowingStream<AppServerServerNotification, Error>.makeStream()
        setContinuation(continuation)
        return stream
    }

    func close() async {
        continuation?.finish()
        continuation = nil
    }

    private func setContinuation(
        _ continuation: AsyncThrowingStream<AppServerServerNotification, Error>.Continuation
    ) {
        self.continuation = continuation
        let bufferedNotifications = self.bufferedNotifications
        self.bufferedNotifications.removeAll(keepingCapacity: false)
        for notification in bufferedNotifications {
            continuation.yield(notification)
        }
    }

    private func buffer(_ notification: AppServerServerNotification) {
        if let continuation {
            continuation.yield(notification)
        } else {
            bufferedNotifications.append(notification)
        }
    }
}

actor MutableAuthenticatedLoginReviewAuthSession: ReviewAuthSession {
    private var continuation: AsyncThrowingStream<AppServerServerNotification, Error>.Continuation?
    private var bufferedNotifications: [AppServerServerNotification] = []
    private var currentEmail: String
    private let planType: String
    private var nextLoginEmails: [String]

    init(
        currentEmail: String,
        planType: String = "pro",
        nextLoginEmails: [String]
    ) {
        self.currentEmail = currentEmail
        self.planType = planType
        self.nextLoginEmails = nextLoginEmails
    }

    func readAccount(refreshToken _: Bool) async throws -> AppServerAccountReadResponse {
        .init(
            account: .chatGPT(email: currentEmail, planType: planType),
            requiresOpenAIAuth: false
        )
    }

    func startLogin(_ params: AppServerLoginAccountParams) async throws -> AppServerLoginAccountResponse {
        _ = params
        if let nextLoginEmail = nextLoginEmails.first {
            nextLoginEmails.removeFirst()
            currentEmail = nextLoginEmail
        }
        buffer(.accountUpdated(.init(authMode: .chatGPT, planType: planType)))
        buffer(.accountLoginCompleted(.init(error: nil, loginID: "login-browser", success: true)))
        return .chatGPT(
            loginID: "login-browser",
            authURL: "https://auth.openai.com/oauth/authorize?foo=bar"
        )
    }

    func cancelLogin(loginID _: String) async throws {}

    func logout() async throws {}

    func notificationStream() async -> AsyncThrowingStream<AppServerServerNotification, Error> {
        let (stream, continuation) = AsyncThrowingStream<AppServerServerNotification, Error>.makeStream()
        setContinuation(continuation)
        return stream
    }

    func close() async {
        continuation?.finish()
        continuation = nil
    }

    private func setContinuation(
        _ continuation: AsyncThrowingStream<AppServerServerNotification, Error>.Continuation
    ) {
        self.continuation = continuation
        let bufferedNotifications = self.bufferedNotifications
        self.bufferedNotifications.removeAll(keepingCapacity: false)
        for notification in bufferedNotifications {
            continuation.yield(notification)
        }
    }

    private func buffer(_ notification: AppServerServerNotification) {
        if let continuation {
            continuation.yield(notification)
        } else {
            bufferedNotifications.append(notification)
        }
    }
}

actor SuccessfulLoginThenFailingRefreshReviewAuthSession: ReviewAuthSession {
    private var continuation: AsyncThrowingStream<AppServerServerNotification, Error>.Continuation?
    private var bufferedNotifications: [AppServerServerNotification] = []
    private var didLogin = false
    private var didReturnPostLoginAccount = false

    func readAccount(refreshToken _: Bool) async throws -> AppServerAccountReadResponse {
        if didLogin == false {
            return .init(account: nil, requiresOpenAIAuth: true)
        }
        if didReturnPostLoginAccount == false {
            didReturnPostLoginAccount = true
            return .init(
                account: .chatGPT(email: "review@example.com", planType: "pro"),
                requiresOpenAIAuth: false
            )
        }
        throw NSError(
            domain: "CodexReviewMCPTests.SuccessfulLoginThenFailingRefreshReviewAuthSession",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "refresh failed"]
        )
    }

    func startLogin(_ params: AppServerLoginAccountParams) async throws -> AppServerLoginAccountResponse {
        _ = params
        didLogin = true
        buffer(.accountUpdated(.init(authMode: .chatGPT, planType: "pro")))
        buffer(.accountLoginCompleted(.init(error: nil, loginID: "login-browser", success: true)))
        return .chatGPT(
            loginID: "login-browser",
            authURL: "https://auth.openai.com/oauth/authorize?foo=bar"
        )
    }

    func cancelLogin(loginID _: String) async throws {}

    func logout() async throws {}

    func notificationStream() async -> AsyncThrowingStream<AppServerServerNotification, Error> {
        let (stream, continuation) = AsyncThrowingStream<AppServerServerNotification, Error>.makeStream()
        setContinuation(continuation)
        return stream
    }

    func close() async {
        continuation?.finish()
        continuation = nil
    }

    private func setContinuation(
        _ continuation: AsyncThrowingStream<AppServerServerNotification, Error>.Continuation
    ) {
        self.continuation = continuation
        let bufferedNotifications = self.bufferedNotifications
        self.bufferedNotifications.removeAll(keepingCapacity: false)
        for notification in bufferedNotifications {
            continuation.yield(notification)
        }
    }

    private func buffer(_ notification: AppServerServerNotification) {
        if let continuation {
            continuation.yield(notification)
        } else {
            bufferedNotifications.append(notification)
        }
    }
}

actor FailingLogoutReviewAuthSession: ReviewAuthSession {
    func readAccount(refreshToken _: Bool) async throws -> AppServerAccountReadResponse {
        .init(account: nil, requiresOpenAIAuth: true)
    }

    func startLogin(_ params: AppServerLoginAccountParams) async throws -> AppServerLoginAccountResponse {
        _ = params
        return .chatGPT(
            loginID: "login-browser",
            authURL: "https://auth.openai.com/oauth/authorize?foo=bar"
        )
    }

    func cancelLogin(loginID _: String) async throws {}

    func logout() async throws {
        throw ReviewAuthError.logoutFailed("Failed to sign out.")
    }

    func notificationStream() async -> AsyncThrowingStream<AppServerServerNotification, Error> {
        .init { $0.finish() }
    }

    func close() async {}
}

actor LogoutFailureWithPersistedAuthReviewAuthSession: ReviewAuthSession {
    func readAccount(refreshToken _: Bool) async throws -> AppServerAccountReadResponse {
        .init(
            account: .chatGPT(email: "review@example.com", planType: "pro"),
            requiresOpenAIAuth: false
        )
    }

    func startLogin(_ params: AppServerLoginAccountParams) async throws -> AppServerLoginAccountResponse {
        _ = params
        return .chatGPT(
            loginID: "login-browser",
            authURL: "https://auth.openai.com/oauth/authorize?foo=bar"
        )
    }

    func cancelLogin(loginID _: String) async throws {}

    func logout() async throws {
        throw ReviewAuthError.logoutFailed("Failed to sign out.")
    }

    func notificationStream() async -> AsyncThrowingStream<AppServerServerNotification, Error> {
        .init { $0.finish() }
    }

    func close() async {}
}

actor LogoutFailureWithChangedAccountReviewAuthSession: ReviewAuthSession {
    private var readCount = 0

    func readAccount(refreshToken _: Bool) async throws -> AppServerAccountReadResponse {
        defer { readCount += 1 }
        if readCount == 0 {
            return .init(
                account: .chatGPT(email: "review@example.com", planType: "pro"),
                requiresOpenAIAuth: false
            )
        }
        return .init(
            account: .chatGPT(email: "new@example.com", planType: "pro"),
            requiresOpenAIAuth: false
        )
    }

    func startLogin(_ params: AppServerLoginAccountParams) async throws -> AppServerLoginAccountResponse {
        _ = params
        return .chatGPT(
            loginID: "login-browser",
            authURL: "https://auth.openai.com/oauth/authorize?foo=bar"
        )
    }

    func cancelLogin(loginID _: String) async throws {}

    func logout() async throws {
        throw ReviewAuthError.logoutFailed("Failed to sign out.")
    }

    func notificationStream() async -> AsyncThrowingStream<AppServerServerNotification, Error> {
        .init { $0.finish() }
    }

    func close() async {}
}

actor NonPersistentSuccessfulLoginReviewAuthSession: ReviewAuthSession {
    private var continuation: AsyncThrowingStream<AppServerServerNotification, Error>.Continuation?
    private var bufferedNotifications: [AppServerServerNotification] = []
    private var refreshRequests: [Bool] = []

    func readAccount(refreshToken: Bool) async throws -> AppServerAccountReadResponse {
        refreshRequests.append(refreshToken)
        if refreshToken {
            return .init(account: nil, requiresOpenAIAuth: true)
        }
        return .init(account: nil, requiresOpenAIAuth: true)
    }

    func startLogin(_ params: AppServerLoginAccountParams) async throws -> AppServerLoginAccountResponse {
        _ = params
        buffer(.accountUpdated(.init(authMode: .chatGPT, planType: nil)))
        buffer(.accountLoginCompleted(.init(error: nil, loginID: "login-browser", success: true)))
        return .chatGPT(
            loginID: "login-browser",
            authURL: "https://auth.openai.com/oauth/authorize?foo=bar"
        )
    }

    func cancelLogin(loginID _: String) async throws {}

    func logout() async throws {}

    func notificationStream() async -> AsyncThrowingStream<AppServerServerNotification, Error> {
        let (stream, continuation) = AsyncThrowingStream<AppServerServerNotification, Error>.makeStream()
        setContinuation(continuation)
        return stream
    }

    func close() async {
        continuation?.finish()
        continuation = nil
    }

    func recordedRefreshRequests() -> [Bool] {
        refreshRequests
    }

    private func setContinuation(
        _ continuation: AsyncThrowingStream<AppServerServerNotification, Error>.Continuation
    ) {
        self.continuation = continuation
        let bufferedNotifications = self.bufferedNotifications
        self.bufferedNotifications.removeAll(keepingCapacity: false)
        for notification in bufferedNotifications {
            continuation.yield(notification)
        }
    }

    private func buffer(_ notification: AppServerServerNotification) {
        if let continuation {
            continuation.yield(notification)
        } else {
            bufferedNotifications.append(notification)
        }
    }
}

actor AuthCapableAppServerManager: AppServerManaging {
    private let runtimeState = AppServerRuntimeState(
        pid: 200,
        startTime: .init(seconds: 2, microseconds: 0),
        processGroupLeaderPID: 200,
        processGroupLeaderStartTime: .init(seconds: 2, microseconds: 0)
    )
    private let authTransports: [any AppServerSessionTransport]
    private let requirePrepareBeforeAuthCheckout: Bool
    private let prepareError: Error?
    private var authCheckoutCountStorage = 0
    private var reviewCheckoutCountStorage = 0
    private var shutdownCountStorage = 0
    private var prepareCountStorage = 0
    private let prepareSignal = AsyncSignal()
    private let shutdownSignal = AsyncSignal()

    init(
        authTransport: any AppServerSessionTransport = AuthCapableAppServerSessionTransport(),
        requirePrepareBeforeAuthCheckout: Bool = false,
        prepareError: Error? = nil
    ) {
        authTransports = [authTransport]
        self.requirePrepareBeforeAuthCheckout = requirePrepareBeforeAuthCheckout
        self.prepareError = prepareError
    }

    init(
        authTransports: [any AppServerSessionTransport],
        requirePrepareBeforeAuthCheckout: Bool = false,
        prepareError: Error? = nil
    ) {
        precondition(authTransports.isEmpty == false)
        self.authTransports = authTransports
        self.requirePrepareBeforeAuthCheckout = requirePrepareBeforeAuthCheckout
        self.prepareError = prepareError
    }

    func prepare() async throws -> AppServerRuntimeState {
        if let prepareError {
            throw prepareError
        }
        prepareCountStorage += 1
        await prepareSignal.signal()
        return runtimeState
    }

    func checkoutTransport(sessionID _: String) async throws -> any AppServerSessionTransport {
        reviewCheckoutCountStorage += 1
        return MockAppServerSessionTransport(mode: .success())
    }

    func checkoutAuthTransport() async throws -> any AppServerSessionTransport {
        if requirePrepareBeforeAuthCheckout, prepareCountStorage == 0 {
            throw NSError(
                domain: "CodexReviewMCPTests.AuthCapableAppServerManager",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "auth transport requires prepare() first"]
            )
        }
        let transportIndex = min(authCheckoutCountStorage, authTransports.count - 1)
        authCheckoutCountStorage += 1
        return authTransports[transportIndex]
    }

    func currentRuntimeState() async -> AppServerRuntimeState? {
        runtimeState
    }

    func diagnosticLineStream() async -> AsyncStream<String> {
        let (stream, continuation) = AsyncStream<String>.makeStream()
        continuation.finish()
        return stream
    }

    func diagnosticsTail() async -> String {
        ""
    }

    func shutdown() async {
        shutdownCountStorage += 1
        await shutdownSignal.signal()
    }

    func authTransportCheckoutCount() -> Int {
        authCheckoutCountStorage
    }

    func authTransportForTesting() -> AuthCapableAppServerSessionTransport? {
        authTransports.first as? AuthCapableAppServerSessionTransport
    }

    func reviewTransportCheckoutCount() -> Int {
        reviewCheckoutCountStorage
    }

    func shutdownCount() -> Int {
        shutdownCountStorage
    }

    func prepareCount() -> Int {
        prepareCountStorage
    }

    func waitForPrepareCount(_ expectedCount: Int) async {
        await prepareSignal.wait(untilCount: expectedCount)
    }

    func waitForShutdownCount(_ expectedCount: Int) async {
        await shutdownSignal.wait(untilCount: expectedCount)
    }
}

actor PreparedSettingsRefreshAppServerManager: AppServerManaging {
    private let runtimeState = AppServerRuntimeState(
        pid: 200,
        startTime: .init(seconds: 2, microseconds: 0),
        processGroupLeaderPID: 200,
        processGroupLeaderStartTime: .init(seconds: 2, microseconds: 0)
    )
    private let initialAuthTransport: any AppServerSessionTransport
    private let recycledAuthTransport: any AppServerSessionTransport
    private var prepareCountStorage = 0
    private var shutdownCountStorage = 0

    init(
        initialAuthTransport: any AppServerSessionTransport,
        recycledAuthTransport: any AppServerSessionTransport
    ) {
        self.initialAuthTransport = initialAuthTransport
        self.recycledAuthTransport = recycledAuthTransport
    }

    func prepare() async throws -> AppServerRuntimeState {
        prepareCountStorage += 1
        return runtimeState
    }

    func checkoutTransport(sessionID _: String) async throws -> any AppServerSessionTransport {
        MockAppServerSessionTransport(mode: .success())
    }

    func checkoutAuthTransport() async throws -> any AppServerSessionTransport {
        prepareCountStorage >= 2 ? recycledAuthTransport : initialAuthTransport
    }

    func currentRuntimeState() async -> AppServerRuntimeState? {
        runtimeState
    }

    func diagnosticLineStream() async -> AsyncStream<String> {
        let (stream, continuation) = AsyncStream<String>.makeStream()
        continuation.finish()
        return stream
    }

    func diagnosticsTail() async -> String {
        ""
    }

    func shutdown() async {
        shutdownCountStorage += 1
    }

    func prepareCount() -> Int {
        prepareCountStorage
    }

    func shutdownCount() -> Int {
        shutdownCountStorage
    }
}

actor FailingAuthCheckoutAppServerManager: AppServerManaging {
    private let runtimeState = AppServerRuntimeState(
        pid: 200,
        startTime: .init(seconds: 2, microseconds: 0),
        processGroupLeaderPID: 200,
        processGroupLeaderStartTime: .init(seconds: 2, microseconds: 0)
    )

    func prepare() async throws -> AppServerRuntimeState {
        runtimeState
    }

    func checkoutTransport(sessionID _: String) async throws -> any AppServerSessionTransport {
        MockAppServerSessionTransport(mode: .success())
    }

    func checkoutAuthTransport() async throws -> any AppServerSessionTransport {
        throw NSError(
            domain: "CodexReviewMCPTests.FailingAuthCheckoutAppServerManager",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Auth transport checkout failed."]
        )
    }

    func currentRuntimeState() async -> AppServerRuntimeState? {
        runtimeState
    }

    func diagnosticLineStream() async -> AsyncStream<String> {
        let (stream, continuation) = AsyncStream<String>.makeStream()
        continuation.finish()
        return stream
    }

    func diagnosticsTail() async -> String {
        ""
    }

    func shutdown() async {}
}

@MainActor
final class PrimaryAuthenticationStoreBackend: ReviewMonitorTestingHarness {
    private let restartResultingServerState: CodexReviewServerState
    private var actions: [String] = []

    init(
        restartResultingServerState: CodexReviewServerState = .starting
    ) {
        self.restartResultingServerState = restartResultingServerState
        super.init(
            seed: .init(
                shouldAutoStartEmbeddedServer: false
            )
        )
    }

    override func start(
        store: CodexReviewStore,
        forceRestartIfNeeded _: Bool
    ) async {
        isActive = true
        actions.append("start")
        store.serverState = restartResultingServerState
    }

    override func stop(store _: CodexReviewStore) async {
        isActive = false
    }

    override func waitUntilStopped() async {}

    override func signIn(auth _: CodexReviewAuthModel) async {
        actions.append("begin")
    }

    override func cancelAuthentication(auth _: CodexReviewAuthModel) async {
        actions.append("cancel")
    }

    override func cancelReviewByID(
        jobID _: String,
        sessionID _: String,
        reason _: String,
        store _: CodexReviewStore
    ) async throws -> ReviewCancelOutcome {
        throw TestFailure("cancel review is not expected in PrimaryAuthenticationStoreBackend")
    }

    func recordedActions() -> [String] {
        actions
    }
}

@MainActor
final class AccountActionStoreBackend: ReviewMonitorTestingHarness {
    var requiresCurrentSessionRecovery = false

    private let switchStartSignal = AsyncSignal()
    private let switchSignal = AsyncSignal()
    private let switchCompletionGate: OneShotGate
    private let switchErrorMessage: String?
    private var switchCalls = 0
    private var switchedAccountKeys: [String] = []

    init(
        switchStartsBlocked: Bool = false,
        switchErrorMessage: String? = nil
    ) {
        self.switchCompletionGate = OneShotGate(isOpen: switchStartsBlocked == false)
        self.switchErrorMessage = switchErrorMessage
        super.init(
            seed: .init(
                shouldAutoStartEmbeddedServer: false
            )
        )
    }

    override func start(
        store _: CodexReviewStore,
        forceRestartIfNeeded _: Bool
    ) async {}

    override func stop(store _: CodexReviewStore) async {}

    override func waitUntilStopped() async {}

    override func switchAccount(
        auth: CodexReviewAuthModel,
        accountKey: String
    ) async throws {
        switchCalls += 1
        switchedAccountKeys.append(accountKey)
        await switchStartSignal.signal()
        await switchCompletionGate.wait()
        if let switchErrorMessage {
            throw ReviewError.io(switchErrorMessage)
        }
        if let account = auth.savedAccounts.first(where: { $0.accountKey == accountKey }) {
            auth.updateAccount(account)
        }
        await switchSignal.signal()
    }

    override func requiresCurrentSessionRecovery(
        auth _: CodexReviewAuthModel,
        accountKey _: String
    ) -> Bool {
        requiresCurrentSessionRecovery
    }

    override func cancelReviewByID(
        jobID _: String,
        sessionID _: String,
        reason _: String,
        store _: CodexReviewStore
    ) async throws -> ReviewCancelOutcome {
        throw TestFailure("cancel review is not expected in AccountActionStoreBackend")
    }

    func switchAccountCallCount() -> Int {
        switchCalls
    }

    func waitForSwitchAccountStartCallCount(_ count: Int) async {
        if await switchStartSignal.count() >= count {
            return
        }
        await switchStartSignal.wait(untilCount: count)
    }

    func waitForSwitchAccountCallCount(_ count: Int) async {
        if await switchSignal.count() >= count {
            return
        }
        await switchSignal.wait(untilCount: count)
    }

    func releaseSwitchAccount() async {
        await switchCompletionGate.open()
    }

    func lastSwitchedAccountKey() -> String? {
        switchedAccountKeys.last
    }
}

@MainActor
final class CancellationFailureStoreBackend: ReviewMonitorTestingHarness {
    private let failingSessionIDs: Set<String>
    private let error: any Error

    init(
        failingSessionIDs: Set<String>,
        error: any Error
    ) {
        self.failingSessionIDs = failingSessionIDs
        self.error = error
        super.init(
            seed: .init(
                shouldAutoStartEmbeddedServer: false
            )
        )
    }

    override func start(
        store _: CodexReviewStore,
        forceRestartIfNeeded _: Bool
    ) async {}

    override func stop(store _: CodexReviewStore) async {}

    override func waitUntilStopped() async {}

    override func cancelReviewByID(
        jobID: String,
        sessionID: String,
        reason: String,
        store: CodexReviewStore
    ) async throws -> ReviewCancelOutcome {
        if failingSessionIDs.contains(sessionID) {
            throw error
        }
        try store.completeCancellationLocally(
            jobID: jobID,
            sessionID: sessionID,
            reason: reason
        )
        let job = try store.resolveJob(jobID: jobID, sessionID: sessionID)
        return .init(
            jobID: jobID,
            threadID: job.threadID,
            cancelled: true,
            status: job.status.state
        )
    }
}

actor BlockingBootstrapAppServerManager: AppServerManaging {
    private let runtimeState = AppServerRuntimeState(
        pid: 200,
        startTime: .init(seconds: 2, microseconds: 0),
        processGroupLeaderPID: 200,
        processGroupLeaderStartTime: .init(seconds: 2, microseconds: 0)
    )
    private let transportStorage = BlockingBootstrapTransport()
    private let authTransport = SettingsRefreshTransport(
        config: .init(
            model: "gpt-5.4-mini",
            reviewModel: "gpt-5.4-mini"
        ),
        firstPage: .init(
            data: [
                .init(
                    id: "gpt-5.4-mini",
                    model: "gpt-5.4-mini",
                    displayName: "GPT-5.4 Mini",
                    hidden: false,
                    supportedReasoningEfforts: [
                        .init(
                            reasoningEffort: .medium,
                            description: "Medium reasoning"
                        )
                    ],
                    defaultReasoningEffort: .medium,
                    supportedServiceTiers: []
                )
            ],
            nextCursor: nil
        ),
        secondPage: .init(data: [], nextCursor: nil)
    )

    func prepare() async throws -> AppServerRuntimeState {
        runtimeState
    }

    func checkoutTransport(sessionID _: String) async throws -> any AppServerSessionTransport {
        transportStorage
    }

    func checkoutAuthTransport() async throws -> any AppServerSessionTransport {
        authTransport
    }

    func currentRuntimeState() async -> AppServerRuntimeState? {
        runtimeState
    }

    func diagnosticLineStream() async -> AsyncStream<String> {
        let (stream, continuation) = AsyncStream<String>.makeStream()
        continuation.finish()
        return stream
    }

    func diagnosticsTail() async -> String {
        ""
    }

    func shutdown() async {}

    func sessionTransport() -> BlockingBootstrapTransport {
        transportStorage
    }
}

actor BlockingBootstrapTransport: AppServerSessionTransport {
    private var requestCounts: [String: Int] = [:]
    private var requestWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var closedStorage = false

    func initializeResponse() async -> AppServerInitializeResponse {
        .init(
            userAgent: nil,
            codexHome: nil,
            platformFamily: "macOS",
            platformOs: "Darwin"
        )
    }

    func request<Params: Encodable & Sendable, Response: Decodable & Sendable>(
        method: String,
        params _: Params,
        responseType _: Response.Type
    ) async throws -> Response {
        noteRequest(method)
        switch method {
        case "config/read":
            while true {
                if closedStorage {
                    throw CancellationError()
                }
                try Task.checkCancellation()
                try? await Task.sleep(for: .milliseconds(10))
            }
        default:
            throw TestFailure("unexpected bootstrap request: \(method)")
        }
    }

    func notify<Params: Encodable & Sendable>(method _: String, params _: Params) async throws {}

    func notificationStream() async -> AsyncThrowingStream<AppServerServerNotification, Error> {
        .init { $0.finish() }
    }

    func isClosed() async -> Bool {
        closedStorage
    }

    func close() async {
        closedStorage = true
    }

    func waitForRequest(_ method: String) async {
        if requestCounts[method, default: 0] > 0 {
            return
        }
        await withCheckedContinuation { continuation in
            if requestCounts[method, default: 0] > 0 {
                continuation.resume()
            } else {
                requestWaiters[method, default: []].append(continuation)
            }
        }
    }

    private func noteRequest(_ method: String) {
        requestCounts[method, default: 0] += 1
        let waiters = requestWaiters.removeValue(forKey: method) ?? []
        for waiter in waiters {
            waiter.resume()
        }
    }
}

actor SettingsRefreshTransport: AppServerSessionTransport {
    private let config: AppServerConfigReadResponse.Config
    private let firstPage: AppServerModelListResponse
    private let secondPage: AppServerModelListResponse
    private var requestedModelListCursorsStorage: [String?] = []
    private var closedStorage = false

    init(
        config: AppServerConfigReadResponse.Config,
        firstPage: AppServerModelListResponse,
        secondPage: AppServerModelListResponse
    ) {
        self.config = config
        self.firstPage = firstPage
        self.secondPage = secondPage
    }

    func initializeResponse() async -> AppServerInitializeResponse {
        .init(
            userAgent: nil,
            codexHome: nil,
            platformFamily: "macOS",
            platformOs: "Darwin"
        )
    }

    func request<Params: Encodable & Sendable, Response: Decodable & Sendable>(
        method: String,
        params: Params,
        responseType _: Response.Type
    ) async throws -> Response {
        switch method {
        case "config/read":
            return AppServerConfigReadResponse(config: config) as! Response
        case "model/list":
            guard let params = params as? AppServerModelListParams else {
                throw TestFailure("unexpected model/list params type")
            }
            requestedModelListCursorsStorage.append(params.cursor)
            switch params.cursor {
            case nil:
                return firstPage as! Response
            case "page-2":
                return secondPage as! Response
            default:
                throw TestFailure("unexpected model/list cursor: \(params.cursor ?? "nil")")
            }
        default:
            throw TestFailure("unexpected settings refresh request: \(method)")
        }
    }

    func notify<Params: Encodable & Sendable>(method _: String, params _: Params) async throws {}

    func notificationStream() async -> AsyncThrowingStream<AppServerServerNotification, Error> {
        .init { $0.finish() }
    }

    func isClosed() async -> Bool {
        closedStorage
    }

    func close() async {
        closedStorage = true
    }

    func requestedModelListCursors() -> [String?] {
        requestedModelListCursorsStorage
    }
}

actor SettingsWriteTransport: AppServerSessionTransport {
    private var recordedEditKeyPathsStorage: [[String]] = []
    private var closedStorage = false

    func initializeResponse() async -> AppServerInitializeResponse {
        .init(
            userAgent: nil,
            codexHome: nil,
            platformFamily: "macOS",
            platformOs: "Darwin"
        )
    }

    func request<Params: Encodable & Sendable, Response: Decodable & Sendable>(
        method: String,
        params: Params,
        responseType _: Response.Type
    ) async throws -> Response {
        guard method == "config/batchWrite" else {
            throw TestFailure("unexpected settings write request: \(method)")
        }
        guard let params = params as? AppServerConfigBatchWriteParams else {
            throw TestFailure("unexpected config/batchWrite params type")
        }
        recordedEditKeyPathsStorage.append(params.edits.map(\.keyPath))
        return AppServerConfigWriteResponse(status: "ok") as! Response
    }

    func notify<Params: Encodable & Sendable>(method _: String, params _: Params) async throws {}

    func notificationStream() async -> AsyncThrowingStream<AppServerServerNotification, Error> {
        .init { $0.finish() }
    }

    func isClosed() async -> Bool {
        closedStorage
    }

    func close() async {
        closedStorage = true
    }

    func recordedEditKeyPaths() -> [[String]] {
        recordedEditKeyPathsStorage
    }
}

actor AuthCapableAppServerSessionTransport: AppServerSessionTransport {
    enum StartLoginBehavior {
        case nativeCallback
        case legacyBrowser
        case customNativeCallback(String)
    }

    enum CompleteLoginBehavior {
        case succeed
        case succeedWithAccountUpdatedOnly
        case succeedWithoutNotifications
        case succeedWithoutLoginID
        case unsupported
    }

    enum RateLimitsReadBehavior {
        case supported
        case unsupported
        case authenticationRequired
    }

    private var continuation: AsyncThrowingStream<AppServerServerNotification, Error>.Continuation?
    private var isClosedStorage = false
    private var recordedCompleteParams: AppServerCompleteLoginAccountParams?
    private var recordedCancelLoginIDs: [String] = []
    private var notificationStreamWaiters: [CheckedContinuation<Void, Never>] = []
    private var notificationDuringNextRateLimitRead: AppServerRateLimitSnapshotPayload?
    private var accountReadResponseObject: [String: Any] = [
        "account": NSNull(),
        "requiresOpenaiAuth": true,
    ]
    private var accountRateLimitsResponseObject: [String: Any]
    private var postCompleteAccountReadResponseQueue: [[String: Any]]
    private var didCompleteLogin = false
    private struct RateLimitsReadCountWaiter {
        let expectedCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var rateLimitsReadCountStorage = 0
    private var rateLimitsReadCountWaiters: [RateLimitsReadCountWaiter] = []
    private var nextRateLimitsReadError: Error?
    private let blockedRateLimitsReadStartedGate = OneShotGate()
    private let blockedRateLimitsReadResumeGate = OneShotGate(isOpen: true)
    private var shouldBlockNextRateLimitsRead = false
    private let startLoginBehavior: StartLoginBehavior
    private let completeLoginBehavior: CompleteLoginBehavior
    private let rateLimitsReadBehavior: RateLimitsReadBehavior

    init(
        startLoginBehavior: StartLoginBehavior = .nativeCallback,
        completeLoginBehavior: CompleteLoginBehavior = .succeed,
        rateLimitsReadBehavior: RateLimitsReadBehavior = .supported,
        postCompleteAccountReadResponses: [[String: Any]] = []
    ) {
        self.startLoginBehavior = startLoginBehavior
        self.completeLoginBehavior = completeLoginBehavior
        self.rateLimitsReadBehavior = rateLimitsReadBehavior
        accountRateLimitsResponseObject = Self.defaultRateLimitsResponseObject()
        postCompleteAccountReadResponseQueue = postCompleteAccountReadResponses
    }

    func initializeResponse() async -> AppServerInitializeResponse {
        .init(
            userAgent: nil,
            codexHome: nil,
            platformFamily: "macOS",
            platformOs: "Darwin"
        )
    }

    func request<Params: Encodable & Sendable, Response: Decodable & Sendable>(
        method: String,
        params: Params,
        responseType: Response.Type
    ) async throws -> Response {
        _ = params
        switch method {
        case "account/read":
            if didCompleteLogin,
               postCompleteAccountReadResponseQueue.isEmpty == false {
                let response = postCompleteAccountReadResponseQueue.removeFirst()
                return try decode(response, as: responseType)
            }
            return try decode(accountReadResponseObject, as: responseType)
        case "account/rateLimits/read":
            rateLimitsReadCountStorage += 1
            let readyWaiters = rateLimitsReadCountWaiters.filter {
                $0.expectedCount <= rateLimitsReadCountStorage
            }
            rateLimitsReadCountWaiters.removeAll {
                $0.expectedCount <= rateLimitsReadCountStorage
            }
            for waiter in readyWaiters {
                waiter.continuation.resume()
            }
            if let notificationDuringNextRateLimitRead {
                continuation?.yield(
                    .accountRateLimitsUpdated(
                        .init(rateLimits: notificationDuringNextRateLimitRead)
                    )
                )
                self.notificationDuringNextRateLimitRead = nil
            }
            if let nextRateLimitsReadError {
                self.nextRateLimitsReadError = nil
                throw nextRateLimitsReadError
            }
            if shouldBlockNextRateLimitsRead {
                shouldBlockNextRateLimitsRead = false
                await blockedRateLimitsReadStartedGate.open()
                await blockedRateLimitsReadResumeGate.wait()
            }
            if rateLimitsReadBehavior == .unsupported {
                throw AppServerResponseError(code: -32601, message: "method not found")
            }
            if rateLimitsReadBehavior == .authenticationRequired {
                throw AppServerResponseError(
                    code: -32001,
                    message: "authentication required to read rate limits"
                )
            }
            return try decode(accountRateLimitsResponseObject, as: responseType)
        case "account/login/start":
            switch startLoginBehavior {
            case .nativeCallback:
                return try decode(
                    [
                        "type": "chatgpt",
                        "loginId": "login-browser",
                        "authUrl": "https://auth.openai.com/oauth/authorize?foo=bar",
                        "nativeWebAuthentication": [
                            "callbackUrlScheme": "lynnpd.codexreviewmonitor.auth",
                        ],
                    ],
                    as: responseType
                )
            case .legacyBrowser:
                return try decode(
                    [
                        "type": "chatgpt",
                        "loginId": "login-browser",
                        "authUrl": "https://auth.openai.com/oauth/authorize?foo=bar",
                    ],
                    as: responseType
                )
            case .customNativeCallback(let callbackURLScheme):
                return try decode(
                    [
                        "type": "chatgpt",
                        "loginId": "login-browser",
                        "authUrl": "https://auth.openai.com/oauth/authorize?foo=bar",
                        "nativeWebAuthentication": [
                            "callbackUrlScheme": callbackURLScheme,
                        ],
                    ],
                    as: responseType
                )
            }
        case "account/login/complete":
            switch completeLoginBehavior {
            case .succeed:
                break
            case .succeedWithAccountUpdatedOnly:
                break
            case .succeedWithoutNotifications:
                break
            case .succeedWithoutLoginID:
                break
            case .unsupported:
                throw AppServerResponseError(code: -32601, message: "method not found")
            }
            recordedCompleteParams = params as? AppServerCompleteLoginAccountParams
            didCompleteLogin = true
            accountReadResponseObject = [
                "account": [
                    "type": "chatgpt",
                    "email": "review@example.com",
                    "planType": "plus",
                ],
                "requiresOpenaiAuth": false,
            ]
            if completeLoginBehavior == .succeed || completeLoginBehavior == .succeedWithAccountUpdatedOnly {
                continuation?.yield(.accountUpdated(.init(authMode: .chatGPT, planType: "plus")))
            }
            if completeLoginBehavior == .succeed || completeLoginBehavior == .succeedWithoutLoginID {
                continuation?.yield(
                    .accountLoginCompleted(
                        .init(
                            error: nil,
                            loginID: completeLoginBehavior == .succeedWithoutLoginID ? nil : recordedCompleteParams?.loginID,
                            success: true
                        )
                    )
                )
            }
            return try decode([:], as: responseType)
        case "account/login/cancel":
            if let params = params as? AppServerCancelLoginAccountParams {
                recordedCancelLoginIDs.append(params.loginID)
            }
            return try decode(["status": "canceled"], as: responseType)
        case "account/logout":
            return try decode([:], as: responseType)
        default:
            throw NSError(
                domain: "CodexReviewMCPTests.AuthCapableAppServerSessionTransport",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "unsupported auth mock request: \(method)"]
            )
        }
    }

    func notify<Params: Encodable & Sendable>(method _: String, params _: Params) async throws {}

    func notificationStream() async -> AsyncThrowingStream<AppServerServerNotification, Error> {
        let (stream, continuation) = AsyncThrowingStream<AppServerServerNotification, Error>.makeStream()
        setContinuation(continuation)
        continuation.onTermination = { _ in
            Task {
                await self.close()
            }
        }
        return stream
    }

    func waitForNotificationStream() async {
        if continuation != nil {
            return
        }
        await withCheckedContinuation { continuation in
            if self.continuation != nil {
                continuation.resume()
            } else {
                notificationStreamWaiters.append(continuation)
            }
        }
    }

    func isClosed() async -> Bool {
        isClosedStorage
    }

    func close() async {
        isClosedStorage = true
        continuation?.finish()
        continuation = nil
    }

    func failNotificationStream(message: String) async {
        continuation?.finish(
            throwing: NSError(
                domain: "CodexReviewMCPTests.AuthCapableAppServerSessionTransport",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        )
        continuation = nil
    }

    func finishNotificationStream() async {
        continuation?.finish()
        continuation = nil
    }

    func sendRateLimitsUpdated(
        _ rateLimits: [String: Any]
    ) async throws {
        let snapshot: AppServerRateLimitSnapshotPayload = try decode(rateLimits, as: AppServerRateLimitSnapshotPayload.self)
        continuation?.yield(
            .accountRateLimitsUpdated(
                .init(rateLimits: snapshot)
            )
        )
    }

    func sendRateLimitsUpdatedDuringNextRead(
        _ rateLimits: [String: Any]
    ) async throws {
        notificationDuringNextRateLimitRead = try decode(
            rateLimits,
            as: AppServerRateLimitSnapshotPayload.self
        )
    }

    func updateAccountReadResponse(
        account: [String: Any]?,
        requiresOpenAIAuth: Bool
    ) {
        accountReadResponseObject = [
            "account": account ?? NSNull(),
            "requiresOpenaiAuth": requiresOpenAIAuth,
        ]
    }

    func updateRateLimitsResponse(
        current: [String: Any],
        byLimitID: [String: [String: Any]]? = nil
    ) {
        var response: [String: Any] = [
            "rateLimits": current,
        ]
        if let byLimitID {
            response["rateLimitsByLimitId"] = byLimitID
        }
        accountRateLimitsResponseObject = response
    }

    func rateLimitsReadCount() -> Int {
        rateLimitsReadCountStorage
    }

    func waitForRateLimitsReadCount(_ expectedCount: Int) async {
        if rateLimitsReadCountStorage >= expectedCount {
            return
        }
        await withCheckedContinuation { continuation in
            if rateLimitsReadCountStorage >= expectedCount {
                continuation.resume()
            } else {
                rateLimitsReadCountWaiters.append(
                    .init(expectedCount: expectedCount, continuation: continuation)
                )
            }
        }
    }

    func failNextRateLimitsRead(message: String) {
        nextRateLimitsReadError = NSError(
            domain: "CodexReviewMCPTests.AuthCapableAppServerSessionTransport",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    func blockNextRateLimitsRead() async {
        shouldBlockNextRateLimitsRead = true
        await blockedRateLimitsReadStartedGate.reset()
        await blockedRateLimitsReadResumeGate.reset()
    }

    func waitForBlockedRateLimitsRead() async {
        await blockedRateLimitsReadStartedGate.wait()
    }

    func resumeBlockedRateLimitsRead() async {
        await blockedRateLimitsReadResumeGate.open()
    }

    private static func defaultRateLimitsResponseObject() -> [String: Any] {
        [
            "rateLimits": defaultRateLimitSnapshotObject(
                limitID: "codex",
                limitName: nil,
                primaryUsedPercent: 40,
                primaryWindowMinutes: 300,
                secondaryUsedPercent: 20,
                secondaryWindowMinutes: 10080
            ),
            "rateLimitsByLimitId": [
                "codex": defaultRateLimitSnapshotObject(
                    limitID: "codex",
                    limitName: nil,
                    primaryUsedPercent: 40,
                    primaryWindowMinutes: 300,
                    secondaryUsedPercent: 20,
                    secondaryWindowMinutes: 10080
                ),
                "codex_other": defaultRateLimitSnapshotObject(
                    limitID: "codex_other",
                    limitName: "codex_other",
                    primaryUsedPercent: 10,
                    primaryWindowMinutes: 60,
                    secondaryUsedPercent: nil,
                    secondaryWindowMinutes: nil
                ),
            ],
        ]
    }

    private static func defaultRateLimitSnapshotObject(
        limitID: String,
        limitName: String?,
        primaryUsedPercent: Int,
        primaryWindowMinutes: Int,
        secondaryUsedPercent: Int?,
        secondaryWindowMinutes: Int?
    ) -> [String: Any] {
        var snapshot: [String: Any] = [
            "limitId": limitID,
            "primary": [
                "usedPercent": primaryUsedPercent,
                "windowDurationMins": primaryWindowMinutes,
                "resetsAt": 1_735_689_600,
            ],
        ]
        snapshot["limitName"] = limitName ?? NSNull()
        if let secondaryUsedPercent,
           let secondaryWindowMinutes {
            snapshot["secondary"] = [
                "usedPercent": secondaryUsedPercent,
                "windowDurationMins": secondaryWindowMinutes,
                "resetsAt": 1_736_035_200,
            ]
        } else {
            snapshot["secondary"] = NSNull()
        }
        return snapshot
    }

    private func setContinuation(
        _ continuation: AsyncThrowingStream<AppServerServerNotification, Error>.Continuation
    ) {
        self.continuation = continuation
        let waiters = notificationStreamWaiters
        notificationStreamWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func decode<Response: Decodable & Sendable>(
        _ object: Any,
        as responseType: Response.Type
    ) throws -> Response {
        _ = responseType
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(Response.self, from: data)
    }

    func completeParams() -> AppServerCompleteLoginAccountParams? {
        recordedCompleteParams
    }

    func cancelLoginIDs() -> [String] {
        recordedCancelLoginIDs
    }
}

actor DisconnectingRateLimitReadTransport: AppServerSessionTransport {
    func initializeResponse() async -> AppServerInitializeResponse {
        .init(
            userAgent: nil,
            codexHome: nil,
            platformFamily: "macOS",
            platformOs: "Darwin"
        )
    }

    func request<Params: Encodable & Sendable, Response: Decodable & Sendable>(
        method: String,
        params _: Params,
        responseType _: Response.Type
    ) async throws -> Response {
        if method == "account/rateLimits/read" {
            throw NSError(
                domain: "CodexReviewMCPTests.DisconnectingRateLimitReadTransport",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "app-server stdio disconnected"]
            )
        }
        throw NSError(
            domain: "CodexReviewMCPTests.DisconnectingRateLimitReadTransport",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "unsupported request: \(method)"]
        )
    }

    func notify<Params: Encodable & Sendable>(method _: String, params _: Params) async throws {}

    func notificationStream() async -> AsyncThrowingStream<AppServerServerNotification, Error> {
        .init { $0.finish() }
    }

    func isClosed() async -> Bool {
        false
    }

    func close() async {}
}

struct TestWebAuthenticationRequest: Equatable {
    var url: URL
    var callbackScheme: String
    var prefersEphemeral: Bool
}

actor TestWebAuthenticationSessionRecorder {
    private let authenticateStartedSignal = AsyncSignal()
    private var lastRequest: TestWebAuthenticationRequest?
    private var cancelCalls = 0
    private var activeSession: ReviewMonitorWebAuthenticationSession?

    func recordRequest(_ request: TestWebAuthenticationRequest) {
        lastRequest = request
    }

    func signalAuthenticateStart() async {
        await authenticateStartedSignal.signal()
    }

    func waitForAuthenticateStart() async {
        await authenticateStartedSignal.wait()
    }

    func recordCancel() {
        cancelCalls += 1
    }

    func setActiveSession(_ session: ReviewMonitorWebAuthenticationSession) {
        activeSession = session
    }

    func finishActiveSession(with result: Result<URL, ReviewAuthError>) async {
        await activeSession?.finishForTesting(result)
    }

    func lastAuthenticateRequest() -> TestWebAuthenticationRequest? {
        lastRequest
    }

    func cancelCallCount() -> Int {
        cancelCalls
    }
}

func makeWebAuthenticationSessionFactory(
    recorder: TestWebAuthenticationSessionRecorder,
    autoResult: Result<URL, ReviewAuthError>? = nil
) -> ReviewMonitorWebAuthenticationSessionFactory {
    { url, callbackScheme, browserSessionPolicy, _ in
        await recorder.recordRequest(
            .init(
                url: url,
                callbackScheme: callbackScheme,
                prefersEphemeral: {
                    switch browserSessionPolicy {
                    case .ephemeral:
                        true
                    }
                }()
            )
        )
        let session = ReviewMonitorWebAuthenticationSession(
            onWaitStart: {
                await recorder.signalAuthenticateStart()
            },
            onCancel: {
                await recorder.recordCancel()
            }
        )
        await recorder.setActiveSession(session)
        if let autoResult {
            Task { @MainActor in
                session.finishForTesting(autoResult)
            }
        }
        return session
    }
}

func makeInjectedNativeLoginAuthSessionFactory(
    manager: any AppServerManaging,
    nativeAuthenticationConfiguration: ReviewMonitorNativeAuthenticationConfiguration,
    webAuthenticationSessionFactory: @escaping ReviewMonitorWebAuthenticationSessionFactory
) -> @Sendable ([String: String]) async throws -> any ReviewAuthSession {
    { environment in
        let transport = try await manager.checkoutAuthTransport()
        let session = await MainActor.run {
            NativeWebAuthenticationReviewSession(
                sharedSession: SharedAppServerReviewAuthSession(transport: transport),
                nativeAuthenticationConfiguration: nativeAuthenticationConfiguration,
                webAuthenticationSessionFactory: webAuthenticationSessionFactory
            )
        }
        return PersistingReviewAuthSession(
            base: session,
            environment: environment
        )
    }
}

func runWithRestartClock(
    _ clock: TestRestartClock,
    maxSteps: Int = 40,
    step: Duration = .milliseconds(100),
    operation: @escaping @Sendable () async throws -> Void
) async throws {
    let resultBox = RestartTaskResultBox()
    let task = Task {
        do {
            try await operation()
            await resultBox.store(.success(()))
        } catch {
            await resultBox.store(.failure(error))
        }
    }
    defer { task.cancel() }

    for _ in 0..<maxSteps {
        if let result = await resultBox.current() {
            try result.get()
            return
        }
        var yieldAttempts = 0
        while clock.hasSleepers == false, yieldAttempts < 100 {
            if let result = await resultBox.current() {
                try result.get()
                return
            }
            await Task.yield()
            yieldAttempts += 1
        }
        clock.advance(by: step)
    }
    throw TestFailure("timed out driving restart clock")
}

@MainActor
final class ObservableValueProbe<Value: Sendable>: @unchecked Sendable {
    private let read: @MainActor () -> Value
    private let queue = AsyncValueQueue<Value>()
    private var isCancelled = false

    init(read: @escaping @MainActor () -> Value) {
        self.read = read
        arm()
    }

    func next() async -> Value? {
        await queue.next()
    }

    func cancel() {
        isCancelled = true
    }

    private func arm() {
        guard isCancelled == false else {
            return
        }

        let value = withObservationTracking({
            read()
        }, onChange: { [weak self] in
            Task { @MainActor in
                self?.arm()
            }
        })

        Task {
            await queue.push(value)
        }
    }
}

func waitForFileAppearance(
    at fileURL: URL,
    timeout: Duration = .seconds(2)
) async throws {
    if FileManager.default.fileExists(atPath: fileURL.path) {
        return
    }

    let monitor = try DirectoryChangeMonitor(directoryURL: fileURL.deletingLastPathComponent())
    defer { monitor.cancel() }

    try await withTestTimeout(timeout) {
        var observedEventCount = await monitor.eventCount()
        while FileManager.default.fileExists(atPath: fileURL.path) == false {
            await monitor.waitForChange(after: observedEventCount)
            observedEventCount = await monitor.eventCount()
        }
    }
}

func waitForObservedValue<Value: Sendable>(
    _ probe: ObservableValueProbe<Value>,
    predicate: @escaping @Sendable (Value) -> Bool
) async throws {
    try await withTestTimeout {
        while let value = await probe.next() {
            if predicate(value) {
                return
            }
        }
        throw TestFailure("observable probe ended before the expected value arrived")
    }
}

func waitForClockSuspension(
    _ clock: ManualTestClock,
    timeout: Duration = .seconds(2)
) async throws {
    try await withTestTimeout(timeout) {
        while clock.hasSleepers == false {
            await Task.yield()
        }
    }
}

func waitForRateLimitsReadCount(
    _ transport: AuthCapableAppServerSessionTransport,
    expectedCount: Int,
    timeout: Duration = .seconds(2)
) async throws {
    try await withTestTimeout(timeout) {
        while await transport.rateLimitsReadCount() < expectedCount {
            await Task.yield()
        }
    }
}

func totalRateLimitsReadCount(
    _ transports: [AuthCapableAppServerSessionTransport]
) async -> Int {
    var total = 0
    for transport in transports {
        total += await transport.rateLimitsReadCount()
    }
    return total
}

func waitForTotalRateLimitsReadCount(
    _ transports: [AuthCapableAppServerSessionTransport],
    expectedCount: Int,
    timeout: Duration = .seconds(2)
) async throws {
    try await withTestTimeout(timeout) {
        while await totalRateLimitsReadCount(transports) < expectedCount {
            await Task.yield()
        }
    }
}

func waitForSettingsWriteCount(
    _ transport: SettingsWriteTransport,
    expectedCount: Int,
    timeout: Duration = .seconds(2)
) async throws {
    try await withTestTimeout(timeout) {
        while await transport.recordedEditKeyPaths().count < expectedCount {
            await Task.yield()
        }
    }
}

func waitForAuthTransportCheckoutCount(
    _ manager: AuthCapableAppServerManager,
    expectedCount: Int,
    timeout: Duration = .seconds(2)
) async throws {
    try await withTestTimeout(timeout) {
        while await manager.authTransportCheckoutCount() < expectedCount {
            await Task.yield()
        }
    }
}

func waitForAppServerLifecycleCounts(
    _ manager: AuthCapableAppServerManager,
    prepareCount expectedPrepareCount: Int,
    shutdownCount expectedShutdownCount: Int,
    timeout: Duration = .seconds(2)
) async throws {
    try await withTestTimeout(timeout) {
        async let waitForPrepare = manager.waitForPrepareCount(expectedPrepareCount)
        async let waitForShutdown = manager.waitForShutdownCount(expectedShutdownCount)
        _ = await (waitForPrepare, waitForShutdown)
    }
}

func withTestTimeout<T: Sendable>(
    _ timeout: Duration = .seconds(2),
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw TestFailure("timed out waiting for operation")
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else {
            throw TestFailure("timed out waiting for operation")
        }
        return result
    }
}

final class FakeForcedRestartEnvironment: @unchecked Sendable {
    enum TermAction {
        case ignore
        case exit
    }

    private struct ProcessState {
        var parentPID: pid_t?
        var startTime: ProcessStartTime
        var groupLeaderPID: pid_t
        var termAction: TermAction
        var isAlive = true
    }

    private let lock = NSLock()
    private var processes: [pid_t: ProcessState] = [:]

    func addProcess(
        pid: pid_t,
        parentPID: pid_t? = nil,
        startTime: ProcessStartTime,
        groupLeaderPID: pid_t? = nil,
        termAction: TermAction
    ) {
        lock.withLock {
            processes[pid] = ProcessState(
                parentPID: parentPID,
                startTime: startTime,
                groupLeaderPID: groupLeaderPID ?? pid,
                termAction: termAction
            )
        }
    }

    func isAlive(_ pid: pid_t) -> Bool {
        lock.withLock { processes[pid]?.isAlive == true }
    }

    func runtime() -> ForcedRestartRuntime {
        ForcedRestartRuntime(
            isProcessAlive: { [weak self] pid in
                self?.isAlive(pid) ?? false
            },
            processStartTime: { [weak self] pid in
                self?.lock.withLock {
                    guard let process = self?.processes[pid], process.isAlive else {
                        return nil
                    }
                    return process.startTime
                }
            },
            isMatchingExecutable: { [weak self] pid, _ in
                self?.isAlive(pid) ?? false
            },
            childProcessIDs: { [weak self] pid in
                self?.lock.withLock {
                    self?.processes.compactMap { childPID, process in
                        process.isAlive && process.parentPID == pid ? childPID : nil
                    } ?? []
                } ?? []
            },
            currentProcessGroupID: { [weak self] pid in
                self?.lock.withLock {
                    guard let process = self?.processes[pid], process.isAlive else {
                        return nil
                    }
                    return process.groupLeaderPID
                }
            },
            signalProcess: { [weak self] pid, signal in
                self?.signalProcess(pid: pid, signal: signal) ?? .init(result: -1, errorNumber: ESRCH)
            },
            signalProcessGroup: { [weak self] groupLeaderPID, signal in
                self?.signalProcessGroup(groupLeaderPID: groupLeaderPID, signal: signal) ?? .init(result: -1, errorNumber: ESRCH)
            }
        )
    }

    private func signalProcess(pid: pid_t, signal: Int32) -> ForcedRestartSignalResult {
        lock.withLock {
            guard var process = processes[pid], process.isAlive else {
                return .init(result: -1, errorNumber: ESRCH)
            }
            switch signal {
            case 0:
                return .init(result: 0, errorNumber: 0)
            case SIGKILL:
                process.isAlive = false
            case SIGTERM:
                if case .exit = process.termAction {
                    process.isAlive = false
                }
            default:
                break
            }
            processes[pid] = process
            return .init(result: 0, errorNumber: 0)
        }
    }

    private func signalProcessGroup(
        groupLeaderPID: pid_t,
        signal: Int32
    ) -> ForcedRestartSignalResult {
        lock.withLock {
            let memberPIDs = processes.compactMap { pid, process in
                process.isAlive && process.groupLeaderPID == groupLeaderPID ? pid : nil
            }
            guard memberPIDs.isEmpty == false else {
                return .init(result: -1, errorNumber: ESRCH)
            }
            if signal == 0 {
                return .init(result: 0, errorNumber: 0)
            }
            for pid in memberPIDs {
                guard var process = processes[pid] else {
                    continue
                }
                switch signal {
                case SIGKILL:
                    process.isAlive = false
                case SIGTERM:
                    if case .exit = process.termAction {
                        process.isAlive = false
                    }
                default:
                    break
                }
                processes[pid] = process
            }
            return .init(result: 0, errorNumber: 0)
        }
    }
}

func waitForMainActorCondition(
    timeout: Duration = .seconds(2),
    condition: @escaping @MainActor @Sendable () -> Bool
) async throws {
    try await withTestTimeout(timeout) {
        while true {
            if await MainActor.run(body: condition) {
                return
            }
            await Task.yield()
        }
    }
}

extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

func isolatedHomeEnvironment(extra: [String: String] = [:]) throws -> [String: String] {
    var environment = ["HOME": try makeTemporaryDirectory().path]
    for (key, value) in extra {
        environment[key] = value
    }
    return environment
}

@MainActor
func makeTestStore(
    configuration: ReviewServerConfiguration,
    diagnosticsURL: URL? = nil,
    appServerManager: any AppServerManaging
) -> CodexReviewStore {
    CodexReviewStore(
        configuration: configuration,
        diagnosticsURL: diagnosticsURL,
        appServerManager: appServerManager,
        authSessionFactory: makeStubReviewAuthSessionFactory()
    )
}

@MainActor
func makeInjectedAuthSessionStore(
    configuration: ReviewServerConfiguration,
    diagnosticsURL: URL? = nil,
    appServerManager: any AppServerManaging,
    authSessionFactory: @escaping @Sendable () async throws -> any ReviewAuthSession,
    rateLimitObservationClock: any ReviewClock = ContinuousClock(),
    rateLimitStaleRefreshInterval: Duration = .seconds(60),
    inactiveRateLimitRefreshInterval: Duration = .seconds(15 * 60),
    deferStartupAuthRefreshUntilPrepared: Bool = false
) -> CodexReviewStore {
    let sessionFactory: @Sendable ([String: String]) async throws -> any ReviewAuthSession = { environment in
        let baseSession = try await authSessionFactory()
        return PersistingReviewAuthSession(
            base: baseSession,
            environment: environment
        )
    }
    return CodexReviewStore(
        configuration: configuration,
        diagnosticsURL: diagnosticsURL,
        appServerManager: appServerManager,
        sharedAuthSessionFactory: sessionFactory,
        loginAuthSessionFactory: sessionFactory,
        rateLimitObservationClock: rateLimitObservationClock,
        rateLimitStaleRefreshInterval: rateLimitStaleRefreshInterval,
        inactiveRateLimitRefreshInterval: inactiveRateLimitRefreshInterval,
        deferStartupAuthRefreshUntilPrepared: deferStartupAuthRefreshUntilPrepared
    )
}

@MainActor
func makeStoreTestJob(
    id: String = UUID().uuidString,
    cwd: String = "/tmp/repo",
    startedAt: Date = Date(),
    status: CodexReviewJobStatus,
    targetSummary: String,
    summary: String? = nil
) -> CodexReviewJob {
    CodexReviewJob.makeForTesting(
        id: id,
        cwd: cwd,
        targetSummary: targetSummary,
        threadID: status == .queued ? nil : UUID().uuidString,
        turnID: UUID().uuidString,
        status: status,
        startedAt: startedAt,
        endedAt: status.isTerminal ? startedAt.addingTimeInterval(1) : nil,
        summary: summary ?? status.displayText,
        lastAgentMessage: "",
        logEntries: [],
        errorMessage: status == .failed ? summary ?? status.displayText : nil
    )
}

@MainActor
func makeStoreTestWorkspaces(from jobs: [CodexReviewJob]) -> [CodexReviewWorkspace] {
    var buckets: [String: [CodexReviewJob]] = [:]
    var order: [String] = []
    for job in jobs {
        if buckets[job.cwd] == nil {
            order.insert(job.cwd, at: 0)
            buckets[job.cwd] = []
        }
        buckets[job.cwd, default: []].insert(job, at: 0)
    }
    return order.map { cwd in
        CodexReviewWorkspace(
            cwd: cwd,
            jobs: buckets[cwd] ?? []
        )
    }
}

@MainActor
final class TestAuthRuntimeDriver: ReviewMonitorAuthRuntimeDriver {
    private struct DeferredAddAccountRuntimeEffect {
        var accountKey: String
        var runtimeGeneration: Int
    }

    private let runtimeStateProvider: @MainActor @Sendable () -> CodexAuthRuntimeState
    private let recycleServerIfRunningAction: @MainActor @Sendable () async -> Void
    private let hasRunningJobs: @MainActor @Sendable () -> Bool
    private let cancelRunningJobsAction: @MainActor @Sendable (String) async throws -> Void
    private var deferredAddAccountRuntimeEffect: DeferredAddAccountRuntimeEffect?
    weak var store: CodexReviewStore?

    init(
        runtimeState: @escaping @MainActor @Sendable () -> CodexAuthRuntimeState,
        recycleServerIfRunning: @escaping @MainActor @Sendable () async -> Void,
        hasRunningJobs: @escaping @MainActor @Sendable () -> Bool,
        cancelRunningJobs: @escaping @MainActor @Sendable (String) async throws -> Void = { _ in }
    ) {
        runtimeStateProvider = runtimeState
        recycleServerIfRunningAction = recycleServerIfRunning
        self.hasRunningJobs = hasRunningJobs
        cancelRunningJobsAction = cancelRunningJobs
        super.init()
    }

    override func runtimeState() -> CodexAuthRuntimeState {
        runtimeStateProvider()
    }

    override func recycleServerIfRunning() async {
        await recycleServerIfRunningAction()
    }

    override func resolveAddAccountRuntimeEffect(
        accountKey: String,
        runtimeGeneration: Int
    ) -> CodexAuthRuntimeEffect {
        if hasRunningJobs() {
            return .deferRecycleUntilJobsDrain(
                accountKey: accountKey,
                runtimeGeneration: runtimeGeneration
            )
        }
        return .recycleNow(
            accountKey: accountKey,
            runtimeGeneration: runtimeGeneration
        )
    }

    override func applyAddAccountRuntimeEffect(
        _ effect: CodexAuthRuntimeEffect,
        auth: CodexReviewAuthModel
    ) async {
        switch effect {
        case .none:
            deferredAddAccountRuntimeEffect = nil
        case .deferRecycleUntilJobsDrain(let accountKey, let runtimeGeneration):
            deferredAddAccountRuntimeEffect = .init(
                accountKey: accountKey,
                runtimeGeneration: runtimeGeneration
            )
        case .recycleNow(let accountKey, let runtimeGeneration):
            let currentRuntimeState = runtimeState()
            guard currentRuntimeState.serverIsRunning,
                  currentRuntimeState.runtimeGeneration == runtimeGeneration,
                  auth.account?.accountKey == accountKey
            else {
                deferredAddAccountRuntimeEffect = nil
                return
            }
            guard hasRunningJobs() == false else {
                deferredAddAccountRuntimeEffect = .init(
                    accountKey: accountKey,
                    runtimeGeneration: runtimeGeneration
                )
                return
            }
            deferredAddAccountRuntimeEffect = nil
            await recycleServerIfRunningAction()
            if let store {
                await store.reconcileAuthenticatedSession(
                    serverIsRunning: runtimeStateProvider().serverIsRunning,
                    runtimeGeneration: runtimeStateProvider().runtimeGeneration
                )
            }
        }
    }

    override func cancelRunningJobs(reason: String) async throws {
        try await cancelRunningJobsAction(reason)
    }

    func reconcileDeferredAddAccountRuntimeEffectIfNeeded(
        auth: CodexReviewAuthModel,
        serverIsRunning: Bool,
        runtimeGeneration: Int
    ) async {
        guard let deferredAddAccountRuntimeEffect else {
            return
        }
        guard serverIsRunning,
              deferredAddAccountRuntimeEffect.runtimeGeneration == runtimeGeneration,
              auth.account?.accountKey == deferredAddAccountRuntimeEffect.accountKey
        else {
            self.deferredAddAccountRuntimeEffect = nil
            return
        }
        guard hasRunningJobs() == false else {
            return
        }
        self.deferredAddAccountRuntimeEffect = nil
        await recycleServerIfRunningAction()
    }
}

@MainActor
final class TestRuntimeOwningAuthController: ReviewMonitorTestingHarness {
    private let base: ReviewMonitorAuthOrchestrator
    private let runtimeDriver: TestAuthRuntimeDriver

    init(
        base: ReviewMonitorAuthOrchestrator,
        runtimeDriver: TestAuthRuntimeDriver
    ) {
        self.base = base
        self.runtimeDriver = runtimeDriver
        super.init()
    }

    override func startStartupRefresh(auth: CodexReviewAuthModel) {
        base.startStartupRefresh(auth: auth)
    }

    override func cancelStartupRefresh() {
        base.cancelStartupRefresh()
    }

    override func refreshAuth(auth: CodexReviewAuthModel) async {
        await base.refresh(auth: auth)
    }

    override func signIn(auth: CodexReviewAuthModel) async {
        await base.signIn(auth: auth)
    }

    override func addAccount(auth: CodexReviewAuthModel) async {
        await base.addAccount(auth: auth)
    }

    override func cancelAuthentication(auth: CodexReviewAuthModel) async {
        await base.cancelAuthentication(auth: auth)
    }

    override func switchAccount(
        auth: CodexReviewAuthModel,
        accountKey: String
    ) async throws {
        try await base.switchAccount(auth: auth, accountKey: accountKey)
    }

    override func removeAccount(
        auth: CodexReviewAuthModel,
        accountKey: String
    ) async throws {
        try await base.removeAccount(auth: auth, accountKey: accountKey)
    }

    override func reorderSavedAccount(
        auth: CodexReviewAuthModel,
        accountKey: String,
        toIndex: Int
    ) async throws {
        try await base.reorderSavedAccount(
            auth: auth,
            accountKey: accountKey,
            toIndex: toIndex
        )
    }

    override func signOutActiveAccount(auth: CodexReviewAuthModel) async throws {
        try await base.signOutActiveAccount(auth: auth)
    }

    override func refreshSavedAccountRateLimits(
        auth: CodexReviewAuthModel,
        accountKey: String
    ) async {
        await base.refreshSavedAccountRateLimits(
            auth: auth,
            accountKey: accountKey
        )
    }

    override func reconcileAuthenticatedSession(
        auth: CodexReviewAuthModel,
        serverIsRunning: Bool,
        runtimeGeneration: Int
    ) async {
        await runtimeDriver.reconcileDeferredAddAccountRuntimeEffectIfNeeded(
            auth: auth,
            serverIsRunning: serverIsRunning,
            runtimeGeneration: runtimeGeneration
        )
        await base.reconcileAuthenticatedSession(
            auth: auth,
            serverIsRunning: serverIsRunning,
            runtimeGeneration: runtimeGeneration
        )
    }
}

@MainActor
@dynamicMemberLookup
final class ReviewMonitorAuthTestHarness {
    let store: CodexReviewStore

    init(store: CodexReviewStore) {
        self.store = store
    }

    var model: CodexReviewAuthModel {
        store.auth
    }

    subscript<Value>(dynamicMember keyPath: KeyPath<CodexReviewAuthModel, Value>) -> Value {
        store.auth[keyPath: keyPath]
    }

    func updateSavedAccounts(_ accounts: [CodexAccount]) {
        store.auth.updateSavedAccounts(accounts)
    }

    func updateAccount(_ account: CodexAccount?) {
        store.auth.updateAccount(account)
    }

    func updatePhase(_ phase: CodexReviewAuthModel.Phase) {
        store.auth.updatePhase(phase)
    }

    func updateWarning(message: String?) {
        store.auth.updateWarning(message: message)
    }

    func presentAccountActionAlert(title: LocalizedStringResource, message: String) {
        store.auth.presentAccountActionAlert(title: title, message: message)
    }

    func dismissAccountActionAlert() {
        store.dismissAccountActionAlert()
    }

    func requestSwitchAccount(_ account: CodexAccount, requiresConfirmation: Bool) {
        store.requestSwitchAccount(account, requiresConfirmation: requiresConfirmation)
    }

    func requestSignOutActiveAccount(requiresConfirmation: Bool) {
        store.requestSignOutActiveAccount(requiresConfirmation: requiresConfirmation)
    }

    func requestRemoveAccount(_ account: CodexAccount, requiresConfirmation: Bool) {
        store.requestRemoveAccount(account, requiresConfirmation: requiresConfirmation)
    }

    func cancelPendingAccountAction() {
        store.cancelPendingAccountAction()
    }

    func confirmPendingAccountAction() {
        store.confirmPendingAccountAction()
    }

    func refresh() async {
        await store.refreshAuthentication()
    }

    func signIn() async {
        await store.signIn()
    }

    func addAccount() async {
        await store.addAccount()
    }

    func cancelAuthentication() async {
        await store.cancelAuthentication()
    }

    func switchAccount(_ account: CodexAccount) async throws {
        try await store.switchAccount(account)
    }

    func removeAccount(accountKey: String) async throws {
        try await store.removeAccount(accountKey: accountKey)
    }

    func reorderSavedAccount(accountKey: String, toIndex: Int) async throws {
        try await store.reorderSavedAccount(accountKey: accountKey, toIndex: toIndex)
    }

    func signOutActiveAccount() async throws {
        try await store.signOutActiveAccount()
    }

    func logout() async {
        await store.logout()
    }

    func refreshSavedAccountRateLimits(accountKey: String) async {
        await store.refreshSavedAccountRateLimits(accountKey: accountKey)
    }

    func reconcileAuthenticatedSession(
        serverIsRunning: Bool,
        runtimeGeneration: Int
    ) async {
        await store.reconcileAuthenticatedSession(
            serverIsRunning: serverIsRunning,
            runtimeGeneration: runtimeGeneration
        )
    }
}

@MainActor
func makeAuthModel(
    configuration: ReviewServerConfiguration,
    appServerManager: any AppServerManaging = MockAppServerManager { _ in .success() },
    sharedAuthSessionFactory: @escaping @Sendable ([String: String]) async throws -> any ReviewAuthSession,
    loginAuthSessionFactory: @escaping @Sendable ([String: String]) async throws -> any ReviewAuthSession,
    probeAppServerManagerFactory: (@Sendable ([String: String]) -> any AppServerManaging)? = nil,
    runtimeState: @escaping @MainActor @Sendable () -> CodexAuthRuntimeState = { .stopped },
    recycleServerIfRunning: @escaping @MainActor @Sendable () async -> Void = {},
    hasRunningJobs: @escaping @MainActor @Sendable () -> Bool = { false },
    rateLimitObservationClock: any ReviewClock = ContinuousClock(),
    rateLimitStaleRefreshInterval: Duration = .seconds(60),
    inactiveRateLimitRefreshInterval: Duration = .seconds(15 * 60),
    cancelRunningJobs: @escaping @MainActor @Sendable (String) async throws -> Void = { _ in }
) -> ReviewMonitorAuthTestHarness {
    let runtimeDriver = TestAuthRuntimeDriver(
        runtimeState: runtimeState,
        recycleServerIfRunning: recycleServerIfRunning,
        hasRunningJobs: hasRunningJobs,
        cancelRunningJobs: cancelRunningJobs
    )
    let controller = ReviewMonitorAuthOrchestrator(
        configuration: configuration,
        accountRegistryStore: ReviewAccountRegistryStore(environment: configuration.environment),
        appServerManager: appServerManager,
        sharedAuthSessionFactory: sharedAuthSessionFactory,
        loginAuthSessionFactory: loginAuthSessionFactory,
        probeAppServerManagerFactory: probeAppServerManagerFactory,
        runtimeBridge: .testing(runtimeDriver),
        rateLimitObservationClock: rateLimitObservationClock,
        rateLimitStaleRefreshInterval: rateLimitStaleRefreshInterval,
        inactiveRateLimitRefreshInterval: inactiveRateLimitRefreshInterval
    )
    let adapter = TestRuntimeOwningAuthController(
        base: controller,
        runtimeDriver: runtimeDriver
    )
    let store = CodexReviewStore.makeTestingStore(harness: adapter)
    runtimeDriver.store = store
    return ReviewMonitorAuthTestHarness(store: store)
}

actor PersistingReviewAuthSession: ReviewAuthSession {
    private let base: any ReviewAuthSession
    private let environment: [String: String]

    init(
        base: any ReviewAuthSession,
        environment: [String: String]
    ) {
        self.base = base
        self.environment = environment
    }

    func readAccount(refreshToken: Bool) async throws -> AppServerAccountReadResponse {
        let response = try await base.readAccount(refreshToken: refreshToken)
        if case .chatGPT(let email, let planType)? = response.account {
            try? writeReviewAuthSnapshot(
                email: email,
                planType: planType,
                environment: environment
            )
        } else {
            try? FileManager.default.removeItem(
                at: ReviewHomePaths.reviewAuthURL(environment: environment)
            )
        }
        return response
    }

    func startLogin(_ params: AppServerLoginAccountParams) async throws -> AppServerLoginAccountResponse {
        try await base.startLogin(params)
    }

    func cancelLogin(loginID: String) async throws {
        try await base.cancelLogin(loginID: loginID)
    }

    func logout() async throws {
        try await base.logout()
        try? FileManager.default.removeItem(
            at: ReviewHomePaths.reviewAuthURL(environment: environment)
        )
    }

    func notificationStream() async -> AsyncThrowingStream<AppServerServerNotification, Error> {
        await base.notificationStream()
    }

    func close() async {
        await base.close()
    }
}

func writeReviewAuthSnapshot(
    email: String,
    planType: String?,
    environment: [String: String]
) throws {
    let authURL = ReviewHomePaths.reviewAuthURL(environment: environment)
    try FileManager.default.createDirectory(
        at: authURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    var authPayload: [String: Any] = [:]
    if let planType {
        authPayload["chatgpt_plan_type"] = planType
    }
    let payload: [String: Any] = [
        "email": email,
        "https://api.openai.com/auth": authPayload,
    ]
    let object: [String: Any] = [
        "auth_mode": "chatgpt",
        "tokens": [
            "id_token": makeReviewAuthTestJWT(payload: payload)
        ],
    ]
    let data = try JSONSerialization.data(withJSONObject: object)
    try data.write(to: authURL, options: .atomic)
}

@MainActor
func saveReviewAccount(
    email: String,
    planType: String? = "pro",
    makeActive: Bool,
    environment: [String: String],
    registryStore: ReviewAccountRegistryStore
) throws -> CodexAccount {
    try writeReviewAuthSnapshot(
        email: email,
        planType: planType,
        environment: environment
    )
    guard let savedAccount = try registryStore.saveSharedAuthAsSavedAccount(makeActive: makeActive) else {
        throw TestFailure("expected saved account to be persisted")
    }
    return savedAccount
}

func writeSavedAccountAuthSnapshot(
    email: String,
    planType: String?,
    accountKey: String,
    environment: [String: String],
    useLegacyDirectory: Bool
) throws {
    try writeReviewAuthSnapshot(
        email: email,
        planType: planType,
        environment: environment
    )
    let destinationDirectoryURL = useLegacyDirectory
        ? ReviewHomePaths.legacySavedAccountDirectoryURL(
            accountKey: accountKey,
            environment: environment
        )
        : ReviewHomePaths.savedAccountDirectoryURL(
            accountKey: accountKey,
            environment: environment
        )
    try FileManager.default.createDirectory(
        at: destinationDirectoryURL,
        withIntermediateDirectories: true
    )
    try Data(contentsOf: ReviewHomePaths.reviewAuthURL(environment: environment))
        .write(
            to: destinationDirectoryURL.appendingPathComponent("auth.json"),
            options: .atomic
        )
}

func makeReviewAuthTestJWT(payload: [String: Any]) -> String {
    let header = ["alg": "none", "typ": "JWT"]
    let headerData = try? JSONSerialization.data(withJSONObject: header)
    let payloadData = try? JSONSerialization.data(withJSONObject: payload)
    let headerComponent = makeReviewAuthJWTComponent(headerData ?? Data())
    let payloadComponent = makeReviewAuthJWTComponent(payloadData ?? Data())
    return "\(headerComponent).\(payloadComponent)."
}

func makeReviewAuthJWTComponent(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

struct StoreDiagnosticsSnapshot: Decodable {
    struct Job: Decodable {
        var status: String
        var summary: String
        var logText: String
        var rawLogText: String
    }

    var serverState: String
    var failureMessage: String?
    var serverURL: String?
    var childRuntimePath: String?
    var jobs: [Job]
}

func readStoreDiagnosticsSnapshot(from fileURL: URL) throws -> StoreDiagnosticsSnapshot {
    let data = try Data(contentsOf: fileURL)
    return try JSONDecoder().decode(StoreDiagnosticsSnapshot.self, from: data)
}

func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

struct TestFailure: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

struct TestAuthState: Equatable {
    var phase: CodexReviewAuthModel.Phase
    var accountEmail: String?
    var accountPlanType: String?

    init(
        isAuthenticated: Bool = false,
        accountID: String? = nil,
        progress: CodexReviewAuthModel.Progress? = nil,
        errorMessage: String? = nil
    ) {
        if let progress {
            phase = .signingIn(progress)
        } else if let errorMessage {
            phase = .failed(message: errorMessage)
        } else {
            phase = .signedOut
        }
        accountEmail = isAuthenticated ? accountID : nil
        accountPlanType = isAuthenticated ? "pro" : nil
    }

    static let signedOut = Self()

    static func signedIn(accountID: String?) -> Self {
        .init(
            isAuthenticated: true,
            accountID: accountID
        )
    }

    static func signingIn(_ progress: CodexReviewAuthModel.Progress) -> Self {
        .init(progress: progress)
    }

    static func failed(
        _ message: String,
        isAuthenticated: Bool = false,
        accountID: String? = nil
    ) -> Self {
        .init(
            isAuthenticated: isAuthenticated,
            accountID: accountID,
            errorMessage: message
        )
    }

    var progress: CodexReviewAuthModel.Progress? {
        guard case .signingIn(let progress) = phase else {
            return nil
        }
        return progress
    }

    var isAuthenticated: Bool {
        accountEmail != nil
    }

    var errorMessage: String? {
        guard case .failed(let message) = phase else {
            return nil
        }
        return message
    }
}

@MainActor
func applyTestAuthState(
    auth: CodexReviewAuthModel,
    state: TestAuthState
) {
    auth.updatePhase(state.phase)
    if let accountEmail = state.accountEmail {
        let account = CodexAccount(
            email: accountEmail,
            planType: state.accountPlanType ?? "pro"
        )
        auth.updateSavedAccounts([account])
        auth.updateAccount(account)
    } else {
        auth.updateSavedAccounts([])
        auth.updateAccount(nil)
    }
}

@MainActor
func testAuthState(from auth: CodexReviewAuthModel) -> TestAuthState {
    .init(
        isAuthenticated: auth.isAuthenticated,
        accountID: auth.account?.email,
        progress: auth.progress,
        errorMessage: auth.errorMessage
    )
}

@MainActor
func testAuthState(from auth: ReviewMonitorAuthTestHarness) -> TestAuthState {
    testAuthState(from: auth.model)
}

@MainActor
func rateLimitWindow(
    duration: Int,
    in account: CodexAccount?
) -> CodexRateLimitWindow? {
    account?.rateLimits.first { $0.windowDurationMinutes == duration }
}

@MainActor
func withAsyncCleanup<T>(
    _ operation: @escaping @MainActor @Sendable () async throws -> T,
    cleanup: @escaping @MainActor @Sendable () async -> Void
) async throws -> T {
    do {
        let result = try await operation()
        await cleanup()
        return result
    } catch {
        await cleanup()
        throw error
    }
}

final class MutableValueBox<Value>: @unchecked Sendable {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}
