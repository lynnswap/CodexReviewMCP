import AppKit
import AuthenticationServices
import Foundation
import Observation
import Testing
import ReviewTestSupport
@_spi(Testing) @testable import CodexReviewMCP
@testable import ReviewCore
@testable import ReviewHTTPServer

@Suite(.serialized)
@MainActor
struct CodexReviewMCPTests {
    @Test func startingStoreWritesDiscoveryAndRuntimeState() async throws {
        let environment = try isolatedHomeEnvironment()
        let discoveryFileURL = ReviewHomePaths.discoveryFileURL(environment: environment)
        let runtimeStateFileURL = ReviewHomePaths.runtimeStateFileURL(environment: environment)
        let reviewConfigURL = ReviewHomePaths.reviewConfigURL(environment: environment)
        let reviewAgentsURL = ReviewHomePaths.reviewAgentsURL(environment: environment)
        ReviewDiscovery.remove(at: discoveryFileURL)
        ReviewRuntimeStateStore.remove(at: runtimeStateFileURL)
        defer {
            ReviewDiscovery.remove(at: discoveryFileURL)
            ReviewRuntimeStateStore.remove(at: runtimeStateFileURL)
        }

        let runtimeState = AppServerRuntimeState(
            pid: 200,
            startTime: .init(seconds: 2, microseconds: 0),
            processGroupLeaderPID: 200,
            processGroupLeaderStartTime: .init(seconds: 2, microseconds: 0)
        )
        let manager = MockAppServerManager(modeProvider: { _ in .success() }, runtimeState: runtimeState)
        let store = makeTestStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager
        )

        await store.start()
        defer { Task { await store.stop() } }

        #expect(store.serverState == .running)
        let discovery = try #require(ReviewDiscovery.read(from: discoveryFileURL))
        let persistedRuntimeState = try #require(ReviewRuntimeStateStore.read(from: runtimeStateFileURL))
        #expect(persistedRuntimeState.serverPID == discovery.pid)
        #expect(persistedRuntimeState.serverStartTime == discovery.serverStartTime)
        #expect(persistedRuntimeState.appServerPID == runtimeState.pid)
        #expect(FileManager.default.fileExists(atPath: reviewConfigURL.path))
        #expect(FileManager.default.fileExists(atPath: reviewAgentsURL.path))
    }

    @Test func storeDoesNotSeedInitialAccountWhenRegistryHasNoActiveAccount() async throws {
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
        try registryData.write(to: registryURL, options: .atomic)

        let store = makeTestStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: MockAppServerManager { _ in .success() }
        )

        #expect(store.auth.account == nil)
        #expect(store.auth.savedAccounts.map(\.email) == ["saved@example.com"])
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

        try await waitForObservedValue(authStateProbe) {
            $0 == .signedIn(accountID: "review@example.com")
        }

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

        try await waitForObservedValue(authStateProbe) {
            $0 == .signedIn(accountID: "review@example.com")
        }

        #expect(await manager.prepareCount() >= 1)
        #expect(await manager.authTransportCheckoutCount() > 0)

        await store.stop()
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

        #expect(store.serverState == .failed("prepare failed"))
        try await waitForObservedValue(authStateProbe) {
            $0 == .signedOut
        }
        #expect(await manager.authTransportCheckoutCount() > 0)
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
        try await waitForObservedValue(fiveHourProbe) {
            $0 == 40
        }
        await clock.sleepUntilSuspendedBy()

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
        await authTransport.waitForRateLimitsReadCount(2)
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
        try await waitForObservedValue(fiveHourProbe) {
            $0 == 40
        }
        await clock.sleepUntilSuspendedBy()

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
        await clock.sleepUntilSuspendedBy()

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
        await authTransport.waitForRateLimitsReadCount(2)
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
        try await waitForObservedValue(fiveHourProbe) {
            $0 == 40
        }
        await clock.sleepUntilSuspendedBy()

        await store.auth.refresh()
        try await waitForObservedValue(fiveHourProbe) {
            $0 == 12
        }
        await clock.sleepUntilSuspendedBy()

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
        await secondTransport.waitForRateLimitsReadCount(2)
        try await waitForObservedValue(fiveHourProbe) {
            $0 == 18
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
        try await waitForObservedValue(fiveHourProbe) {
            $0 == 40
        }
        await clock.sleepUntilSuspendedBy()

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
        try await waitForObservedValue(fiveHourProbe) {
            $0 == 40
        }
        await clock.sleepUntilSuspendedBy()

        await authTransport.failNextRateLimitsRead(message: "temporary failure")
        clock.advance(by: .seconds(60))
        await authTransport.waitForRateLimitsReadCount(2)
        await Task.yield()

        #expect(rateLimitWindow(duration: 300, in: store.auth.account)?.usedPercent == 40)
        await clock.sleepUntilSuspendedBy()

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
        await authTransport.waitForRateLimitsReadCount(3)
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
        try await waitForObservedValue(fiveHourProbe) {
            $0 == 40
        }
        await clock.sleepUntilSuspendedBy()

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
        await authTransport.waitForRateLimitsReadCount(2)
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

        await store.auth.refresh()

        try await waitForObservedValue(fiveHourProbe) {
            $0 == 12
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
        let fiveHourProbe = ObservableValueProbe { rateLimitWindow(duration: 300, in: store.auth.account)?.usedPercent }
        defer { fiveHourProbe.cancel() }

        await store.start()
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

        await store.auth.refresh()

        try await waitForObservedValue(fiveHourProbe) {
            $0 == 18
        }

        #expect(testAuthState(from: store.auth) == .signedIn(accountID: "review@example.com"))
        #expect(rateLimitWindow(duration: 300, in: store.auth.account) === initialSessionWindow)
        #expect(rateLimitWindow(duration: 10_080, in: store.auth.account) === initialWeeklyWindow)
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
        try await waitForObservedValue(fiveHourProbe) {
            $0 == 40
        }

        await store.auth.refresh()

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
        try await waitForObservedValue(fiveHourProbe) {
            $0 == 40
        }

        await store.auth.logout()

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
            }
        )
        let authStateProbe = ObservableValueProbe { testAuthState(from: store.auth) }
        defer { authStateProbe.cancel() }

        await store.start()

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
        try await Task.sleep(for: .milliseconds(400))

        #expect(await manager.authTransportCheckoutCount() == 1)
        #expect(rateLimitWindow(duration: 300, in: store.auth.account) == nil)
        #expect(rateLimitWindow(duration: 10_080, in: store.auth.account) == nil)

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

    @Test func diagnosticsSnapshotIncludesServerAndCompletedReviewState() async throws {
        let environment = try isolatedHomeEnvironment()
        let diagnosticsDirectoryURL = try makeTemporaryDirectory()
        let diagnosticsURL = diagnosticsDirectoryURL.appendingPathComponent("diagnostics.json")
        let reviewDirectoryURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: diagnosticsDirectoryURL)
            try? FileManager.default.removeItem(at: reviewDirectoryURL)
        }

        let manager = MockAppServerManager { _ in
            .commandOutputThenSuccessThenTransportDisconnect(
                finalReview: "Looks solid overall.",
                outputDelta: "README.md | 1 +"
            )
        }
        let store = makeTestStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            diagnosticsURL: diagnosticsURL,
            appServerManager: manager
        )

        await store.start()

        let result = try await store.startReview(
            sessionID: "session-diagnostics",
            request: .init(
                cwd: reviewDirectoryURL.path,
                target: .uncommittedChanges
            )
        )

        let snapshot = try readStoreDiagnosticsSnapshot(from: diagnosticsURL)
        let job = try #require(snapshot.jobs.first)

        #expect(result.status == .succeeded)
        #expect(snapshot.serverState == "Running")
        #expect(snapshot.failureMessage == nil)
        #expect(snapshot.serverURL == store.serverURL?.absoluteString)
        #expect(snapshot.childRuntimePath == nil)
        #expect(job.status == "succeeded")
        #expect(job.logText.contains("Looks solid overall."))
        #expect(job.logText.contains("README.md | 1 +"))
        #expect(job.rawLogText.isEmpty)

        await store.stop()
    }

    @Test func stoppingStoreRemovesDiscoveryAndRuntimeState() async throws {
        let environment = try isolatedHomeEnvironment()
        let discoveryFileURL = ReviewHomePaths.discoveryFileURL(environment: environment)
        let runtimeStateFileURL = ReviewHomePaths.runtimeStateFileURL(environment: environment)
        ReviewDiscovery.remove(at: discoveryFileURL)
        ReviewRuntimeStateStore.remove(at: runtimeStateFileURL)
        defer {
            ReviewDiscovery.remove(at: discoveryFileURL)
            ReviewRuntimeStateStore.remove(at: runtimeStateFileURL)
        }

        let manager = MockAppServerManager { _ in .success() }
        let store = makeTestStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager
        )

        await store.start()
        await store.stop()

        #expect(ReviewDiscovery.read(from: discoveryFileURL) == nil)
        #expect(ReviewRuntimeStateStore.read(from: runtimeStateFileURL) == nil)
    }

    @Test func stopKeepsRuntimeStateUntilAppServerShutdownFinishes() async throws {
        let environment = try isolatedHomeEnvironment()
        let runtimeStateFileURL = ReviewHomePaths.runtimeStateFileURL(environment: environment)
        ReviewRuntimeStateStore.remove(at: runtimeStateFileURL)
        defer { ReviewRuntimeStateStore.remove(at: runtimeStateFileURL) }

        let manager = DelayedShutdownAppServerManager(
            runtimeState: .init(
                pid: 200,
                startTime: .init(seconds: 2, microseconds: 0),
                processGroupLeaderPID: 200,
                processGroupLeaderStartTime: .init(seconds: 2, microseconds: 0)
            )
        )
        let store = makeTestStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager
        )

        await store.start()
        let stopTask = Task { await store.stop() }
        await manager.waitForShutdownStart()

        #expect(ReviewRuntimeStateStore.read(from: runtimeStateFileURL) != nil)

        await manager.resumeShutdown()
        _ = await stopTask.value

        #expect(ReviewRuntimeStateStore.read(from: runtimeStateFileURL) == nil)
    }

    @Test func stopCancelsPartialStartupAndRemovesDiscoveryState() async throws {
        let environment = try isolatedHomeEnvironment()
        let discoveryFileURL = ReviewHomePaths.discoveryFileURL(environment: environment)
        let runtimeStateFileURL = ReviewHomePaths.runtimeStateFileURL(environment: environment)
        ReviewDiscovery.remove(at: discoveryFileURL)
        ReviewRuntimeStateStore.remove(at: runtimeStateFileURL)
        defer {
            ReviewDiscovery.remove(at: discoveryFileURL)
            ReviewRuntimeStateStore.remove(at: runtimeStateFileURL)
        }

        let manager = BlockingPrepareAppServerManager(runtimeState: .init(
            pid: 300,
            startTime: .init(seconds: 3, microseconds: 0),
            processGroupLeaderPID: 300,
            processGroupLeaderStartTime: .init(seconds: 3, microseconds: 0)
        ))
        let store = makeTestStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager
        )

        let startTask = Task { await store.start() }

        await manager.waitForPrepareStart()
        try await waitForFileAppearance(at: discoveryFileURL)
        #expect(ReviewRuntimeStateStore.read(from: runtimeStateFileURL) == nil)

        await store.stop()
        _ = await startTask.value

        #expect(store.serverState == .stopped)
        #expect(ReviewDiscovery.readPersisted(from: discoveryFileURL) == nil)
        #expect(ReviewRuntimeStateStore.read(from: runtimeStateFileURL) == nil)
        #expect(await manager.shutdownCount() == 1)
    }

    @Test func stopWithoutLocalServerPreservesPersistedDiscoveryAndRuntimeState() async throws {
        let environment = try isolatedHomeEnvironment()
        let discoveryFileURL = ReviewHomePaths.discoveryFileURL(environment: environment)
        let runtimeStateFileURL = ReviewHomePaths.runtimeStateFileURL(environment: environment)
        ReviewDiscovery.remove(at: discoveryFileURL)
        ReviewRuntimeStateStore.remove(at: runtimeStateFileURL)
        defer {
            ReviewDiscovery.remove(at: discoveryFileURL)
            ReviewRuntimeStateStore.remove(at: runtimeStateFileURL)
        }

        let serverPID = getpid()
        let serverStartTime = try #require(processStartTime(of: serverPID))
        let endpointRecord = try #require(
            ReviewDiscovery.makeRecord(host: "127.0.0.1", port: 9417, pid: Int(serverPID))
        )
        let runtimeState = ReviewRuntimeStateRecord(
            serverPID: Int(serverPID),
            serverStartTime: serverStartTime,
            appServerPID: 999,
            appServerStartTime: .init(seconds: 9, microseconds: 0),
            appServerProcessGroupLeaderPID: 999,
            appServerProcessGroupLeaderStartTime: .init(seconds: 9, microseconds: 0),
            updatedAt: Date()
        )
        try ReviewDiscovery.write(endpointRecord, to: discoveryFileURL)
        try ReviewRuntimeStateStore.write(runtimeState, to: runtimeStateFileURL)

        let manager = MockAppServerManager { _ in .success() }
        let store = makeTestStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager
        )

        await store.stop()

        #expect(ReviewDiscovery.readPersisted(from: discoveryFileURL)?.pid == Int(serverPID))
        #expect(ReviewRuntimeStateStore.read(from: runtimeStateFileURL)?.serverPID == Int(serverPID))
    }

    @Test func restartRecoversFromPartialStartup() async throws {
        let environment = try isolatedHomeEnvironment()
        let runtimeStateFileURL = ReviewHomePaths.runtimeStateFileURL(environment: environment)
        ReviewRuntimeStateStore.remove(at: runtimeStateFileURL)
        defer { ReviewRuntimeStateStore.remove(at: runtimeStateFileURL) }

        let manager = BlockingPrepareAppServerManager(runtimeState: .init(
            pid: 400,
            startTime: .init(seconds: 4, microseconds: 0),
            processGroupLeaderPID: 400,
            processGroupLeaderStartTime: .init(seconds: 4, microseconds: 0)
        ))
        let store = makeTestStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager
        )

        let firstStartTask = Task { await store.start() }

        await manager.waitForPrepareStart()
        await store.restart()
        _ = await firstStartTask.value

        #expect(store.serverState == .running)
        let runtimeState = try #require(ReviewRuntimeStateStore.read(from: runtimeStateFileURL))
        #expect(runtimeState.appServerPID == 400)
        #expect(await manager.prepareCount() == 2)
        #expect(await manager.shutdownCount() >= 1)

        await store.stop()
        #expect(store.serverState == .stopped)
    }

    @Test func sessionTransportFailureDoesNotDropOtherSessionsOrRuntimeState() async throws {
        let environment = try isolatedHomeEnvironment()
        let runtimeStateFileURL = ReviewHomePaths.runtimeStateFileURL(environment: environment)
        ReviewRuntimeStateStore.remove(at: runtimeStateFileURL)
        defer { ReviewRuntimeStateStore.remove(at: runtimeStateFileURL) }

        let manager = MockAppServerManager { sessionID in
            sessionID == "session-a" ? .interruptFailure() : .longRunning()
        }
        let store = makeTestStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager
        )

        await store.start()
        defer { Task { await store.stop() } }

        let sessionAReview = Task {
            try await store.startReview(
                sessionID: "session-a",
                request: .init(
                    cwd: FileManager.default.temporaryDirectory.path,
                    target: .uncommittedChanges
                )
            )
        }
        let sessionBReview = Task {
            try await store.startReview(
                sessionID: "session-b",
                request: .init(
                    cwd: FileManager.default.temporaryDirectory.path,
                    target: .uncommittedChanges
                )
            )
        }

        let sessionATransport = await manager.waitForTransport(sessionID: "session-a")
        let sessionBTransport = await manager.waitForTransport(sessionID: "session-b")
        await sessionATransport.waitForRequest("review/start")
        await sessionBTransport.waitForRequest("review/start")

        _ = try await store.cancelReview(
            selector: .init(cwd: nil, statuses: [.running]),
            sessionID: "session-a"
        )
        let cancelledResult = try await sessionAReview.value

        #expect(cancelledResult.status == .cancelled)
        #expect(await sessionATransport.isClosed())
        #expect(await sessionBTransport.isClosed() == false)
        #expect(await manager.shutdownCount() == 0)
        #expect(ReviewRuntimeStateStore.read(from: runtimeStateFileURL) != nil)

        await store.closeSession("session-b", reason: "test cleanup")
        let sessionBResult = try await sessionBReview.value
        #expect(sessionBResult.status == .cancelled)
    }

    @Test func closeSessionClosesTransportThatFinishesConnectingLater() async throws {
        let manager = DelayedConnectAppServerManager(
            runtimeState: .init(
                pid: 200,
                startTime: .init(seconds: 2, microseconds: 0),
                processGroupLeaderPID: 200,
                processGroupLeaderStartTime: .init(seconds: 2, microseconds: 0)
            )
        )
        let store = makeTestStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: try isolatedHomeEnvironment()
            ),
            appServerManager: manager
        )

        await store.start()
        defer { Task { await store.stop() } }

        let reviewTask = Task {
            try await store.startReview(
                sessionID: "session-delayed-connect",
                request: .init(
                    cwd: FileManager.default.temporaryDirectory.path,
                    target: .uncommittedChanges
                )
            )
        }

        await manager.waitForConnectStart()
        await store.closeSession("session-delayed-connect", reason: "session closed")
        await manager.resumeConnect()

        let result = try await reviewTask.value
        let transport = try #require(await manager.createdTransport())
        #expect(result.status == .cancelled)
        #expect(await transport.isClosed())
    }

    @Test func cancelReviewInterruptsInFlightBootstrapRequest() async throws {
        let manager = BlockingBootstrapAppServerManager()
        let store = makeTestStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: try isolatedHomeEnvironment()
            ),
            appServerManager: manager
        )

        await store.start()
        defer { Task { await store.stop() } }

        let reviewTask = Task {
            try await store.startReview(
                sessionID: "session-bootstrap",
                request: .init(
                    cwd: FileManager.default.temporaryDirectory.path,
                    target: .uncommittedChanges
                )
            )
        }

        let transport = await manager.sessionTransport()
        await transport.waitForRequest("config/read")

        let cancelResult = try await store.cancelReview(
            selector: .init(cwd: nil, statuses: [.running]),
            sessionID: "session-bootstrap"
        )

        #expect(cancelResult.cancelled)

        let result = try await withTestTimeout {
            try await reviewTask.value
        }

        #expect(result.status == .cancelled)
        #expect(result.error == "Cancellation requested.")
        #expect(await transport.isClosed())
    }

    @Test func cancelAllRunningJobsThrowsWhenAnyReviewCancellationFails() async throws {
        let store = CodexReviewStore(
            backend: CancellationFailureStoreBackend(
                failingSessionIDs: ["session-a"],
                error: NSError(
                    domain: "CodexReviewMCPTests.CancellationFailureStoreBackend",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Cancellation failed."]
                )
            )
        )
        let failedJob = CodexReviewJob.makeForTesting(
            id: "job-a",
            sessionID: "session-a",
            targetSummary: "target-a",
            status: .running,
            summary: "Running"
        )
        let cancelledJob = CodexReviewJob.makeForTesting(
            id: "job-b",
            sessionID: "session-b",
            targetSummary: "target-b",
            status: .running,
            summary: "Running"
        )
        store.workspaces = [
            CodexReviewWorkspace(
                cwd: "/tmp/repo",
                jobs: [failedJob, cancelledJob]
            )
        ]

        await #expect(throws: Error.self) {
            try await store.cancelAllRunningJobs(reason: "Account change requested.")
        }

        #expect(failedJob.summary == "Failed to cancel review: Cancellation failed.")
        #expect(failedJob.errorMessage == "Cancellation failed.")
        #expect(cancelledJob.status == .cancelled)
        #expect(cancelledJob.errorMessage == "Account change requested.")
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
            await store.auth.beginAuthentication()
        }

        await authSession.waitForLoginStart()

        await store.auth.cancelAuthentication()
        _ = await beginTask.value

        #expect(testAuthState(from: store.auth) == .signedOut)
        #expect(await authFactory.creationCount() == 1)
        #expect(await authSession.cancelledLoginIDs() == ["login-browser"])
    }

    @Test func beginAuthenticationIgnoresConcurrentRetryWhileLoginIsInProgress() async throws {
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
            await store.auth.beginAuthentication()
        }

        await authSession.waitForLoginStart()

        let secondBeginTask = Task {
            await store.auth.beginAuthentication()
        }
        _ = await secondBeginTask.value

        #expect(await authFactory.creationCount() == 1)

        await store.auth.cancelAuthentication()
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
            await store.auth.beginAuthentication()
        }

        await authSession.waitForLoginStart()

        await store.auth.cancelAuthentication()
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
        applyTestAuthState(auth: store.auth, state: .signedIn(accountID: "review@example.com"))

        let beginTask = Task {
            await store.auth.beginAuthentication()
        }

        await authSession.waitForLoginStart()

        await store.auth.logout()
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
        applyTestAuthState(auth: store.auth, state: .signedIn(accountID: "review@example.com"))

        let beginTask = Task {
            await store.auth.beginAuthentication()
        }

        await authSession.waitForLoginStart()

        let logoutTask = Task {
            await store.auth.logout()
        }
        await authSession.waitForCloseRequest()
        _ = await logoutTask.value

        await authSession.finishPendingClose()
        _ = await beginTask.value

        #expect(testAuthState(from: store.auth) == .signedOut)
        #expect(await authSession.cancelledLoginIDs() == ["login-browser"])
        #expect(await manager.prepareCount() == 2)
        #expect(await manager.shutdownCount() == 1)

        await store.stop()
    }

    @Test func beginAuthenticationUsesInjectedAuthSessionWithoutAuthTransportCheckout() async throws {
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
            await store.auth.beginAuthentication()
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

        await store.auth.cancelAuthentication()
        _ = await beginTask.value

        #expect(await manager.authTransportCheckoutCount() == 0)
        #expect(await manager.reviewTransportCheckoutCount() == 0)
        #expect(await manager.shutdownCount() == 0)
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
        await store.auth.beginAuthentication()

        #expect(testAuthState(from: store.auth) == .signedIn(accountID: "review@example.com"))
        #expect(await manager.prepareCount() == 2)
        #expect(await manager.shutdownCount() == 1)

        await store.stop()
    }

    @Test func sameAccountReauthenticationRecyclesSharedAppServer() async throws {
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
        await store.auth.beginAuthentication()

        #expect(testAuthState(from: store.auth) == .signedIn(accountID: "review@example.com"))
        #expect(await manager.prepareCount() == 2)
        #expect(await manager.shutdownCount() == 1)

        await store.stop()
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
        await store.auth.beginAuthentication()

        #expect(testAuthState(from: store.auth) == .failed(reviewAuthPersistenceFailureMessage))
        #expect(await manager.prepareCount() == 1)
        #expect(await manager.shutdownCount() == 0)

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
        applyTestAuthState(auth: store.auth, state: .signedIn(accountID: "review@example.com"))
        await store.auth.logout()

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
        applyTestAuthState(auth: store.auth, state: .signedIn(accountID: "review@example.com"))
        await store.auth.logout()

        #expect(testAuthState(from: store.auth) == .signedOut)
        #expect(await manager.prepareCount() == 2)
        #expect(await manager.shutdownCount() == 1)

        await store.stop()
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
        applyTestAuthState(auth: store.auth, state: .signedIn(accountID: "review@example.com"))
        await store.auth.logout()

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
        try await waitForObservedValue(fiveHourProbe) {
            $0 == 40
        }

        await store.auth.logout()

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

        await store.auth.beginAuthentication()

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

        await store.auth.beginAuthentication()

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

        await store.auth.beginAuthentication()

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
            await store.auth.beginAuthentication()
        }

        await authSession.waitForLoginStart()

        #expect(store.auth.isAuthenticating)
        #expect(store.auth.isAuthenticated)
        #expect(store.auth.account?.email == "review@example.com")

        await store.auth.cancelAuthentication()
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

        await store.auth.beginAuthentication()

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

        await store.auth.beginAuthentication()

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

        await store.auth.beginAuthentication()

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

        await store.auth.beginAuthentication()

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

        await store.auth.beginAuthentication()

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

        await store.auth.beginAuthentication()

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

        await store.auth.beginAuthentication()

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

        let subscription = await session.notificationStream()
        defer { Task { await subscription.cancel() } }

        try await withTestTimeout {
            for try await _ in subscription.stream {
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

        let subscription = await session.notificationStream()
        defer { Task { await subscription.cancel() } }

        await #expect(throws: ReviewAuthError.loginFailed("Authentication failed.")) {
            try await withTestTimeout {
                for try await _ in subscription.stream {
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

private final class TestRestartClock: Clock, @unchecked Sendable {
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

private actor RestartTaskResultBox {
    private var result: Result<Void, Error>?

    func store(_ result: Result<Void, Error>) {
        self.result = result
    }

    func current() -> Result<Void, Error>? {
        result
    }
}

private actor DelayedShutdownAppServerManager: AppServerManaging {
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

    func diagnosticLineStream() async -> AsyncStreamSubscription<String> {
        let (stream, continuation) = AsyncStream<String>.makeStream()
        continuation.finish()
        return .init(stream: stream, cancel: {})
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

private actor DelayedConnectAppServerManager: AppServerManaging {
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

    func diagnosticLineStream() async -> AsyncStreamSubscription<String> {
        let (stream, continuation) = AsyncStream<String>.makeStream()
        continuation.finish()
        return .init(stream: stream, cancel: {})
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

private actor BlockingPrepareAppServerManager: AppServerManaging {
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

    func diagnosticLineStream() async -> AsyncStreamSubscription<String> {
        let (stream, continuation) = AsyncStream<String>.makeStream()
        continuation.finish()
        return .init(stream: stream, cancel: {})
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

private actor CountingReviewAuthSessionFactory {
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

private actor BlockingLoginReviewAuthSession: ReviewAuthSession {
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

    func notificationStream() async -> AsyncThrowingStreamSubscription<AppServerServerNotification> {
        let (stream, continuation) = AsyncThrowingStream<AppServerServerNotification, Error>.makeStream()
        setContinuation(continuation)
        return .init(
            stream: stream,
            cancel: { [self] in
                await close()
            }
        )
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

private actor DeferredCloseLoginReviewAuthSession: ReviewAuthSession {
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

    func notificationStream() async -> AsyncThrowingStreamSubscription<AppServerServerNotification> {
        let (stream, continuation) = AsyncThrowingStream<AppServerServerNotification, Error>.makeStream()
        self.continuation = continuation
        return .init(
            stream: stream,
            cancel: { [self] in
                await close()
            }
        )
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

private actor SlowReadAccountReviewAuthSession: ReviewAuthSession {
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

    func notificationStream() async -> AsyncThrowingStreamSubscription<AppServerServerNotification> {
        .init(stream: .init { $0.finish() }, cancel: {})
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

private actor ImmediateReadAccountReviewAuthSession: ReviewAuthSession {
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

    func notificationStream() async -> AsyncThrowingStreamSubscription<AppServerServerNotification> {
        .init(stream: .init { $0.finish() }, cancel: {})
    }

    func close() async {}
}

private actor FailingReadAccountReviewAuthSession: ReviewAuthSession {
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

    func notificationStream() async -> AsyncThrowingStreamSubscription<AppServerServerNotification> {
        .init(stream: .init { $0.finish() }, cancel: {})
    }

    func close() async {}
}

private actor SequencedReadAccountReviewAuthSession: ReviewAuthSession {
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

    func notificationStream() async -> AsyncThrowingStreamSubscription<AppServerServerNotification> {
        .init(stream: .init { $0.finish() }, cancel: {})
    }

    func close() async {}
}

private actor SuccessfulLoginReviewAuthSession: ReviewAuthSession {
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

    func notificationStream() async -> AsyncThrowingStreamSubscription<AppServerServerNotification> {
        let (stream, continuation) = AsyncThrowingStream<AppServerServerNotification, Error>.makeStream()
        setContinuation(continuation)
        return .init(stream: stream, cancel: {})
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

private actor SuccessfulLogoutReviewAuthSession: ReviewAuthSession {
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

    func notificationStream() async -> AsyncThrowingStreamSubscription<AppServerServerNotification> {
        .init(stream: .init { $0.finish() }, cancel: {})
    }

    func close() async {}
}

private actor SameAccountSuccessfulLoginReviewAuthSession: ReviewAuthSession {
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

    func notificationStream() async -> AsyncThrowingStreamSubscription<AppServerServerNotification> {
        let (stream, continuation) = AsyncThrowingStream<AppServerServerNotification, Error>.makeStream()
        setContinuation(continuation)
        return .init(stream: stream, cancel: {})
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

private actor FailingLogoutReviewAuthSession: ReviewAuthSession {
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

    func notificationStream() async -> AsyncThrowingStreamSubscription<AppServerServerNotification> {
        .init(stream: .init { $0.finish() }, cancel: {})
    }

    func close() async {}
}

private actor LogoutFailureWithPersistedAuthReviewAuthSession: ReviewAuthSession {
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

    func notificationStream() async -> AsyncThrowingStreamSubscription<AppServerServerNotification> {
        .init(stream: .init { $0.finish() }, cancel: {})
    }

    func close() async {}
}

private actor LogoutFailureWithChangedAccountReviewAuthSession: ReviewAuthSession {
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

    func notificationStream() async -> AsyncThrowingStreamSubscription<AppServerServerNotification> {
        .init(stream: .init { $0.finish() }, cancel: {})
    }

    func close() async {}
}

private actor NonPersistentSuccessfulLoginReviewAuthSession: ReviewAuthSession {
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

    func notificationStream() async -> AsyncThrowingStreamSubscription<AppServerServerNotification> {
        let (stream, continuation) = AsyncThrowingStream<AppServerServerNotification, Error>.makeStream()
        setContinuation(continuation)
        return .init(stream: stream, cancel: {})
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

private actor AuthCapableAppServerManager: AppServerManaging {
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

    func diagnosticLineStream() async -> AsyncStreamSubscription<String> {
        let (stream, continuation) = AsyncStream<String>.makeStream()
        continuation.finish()
        return .init(stream: stream, cancel: {})
    }

    func diagnosticsTail() async -> String {
        ""
    }

    func shutdown() async {
        shutdownCountStorage += 1
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
}

@MainActor
private final class CancellationFailureStoreBackend: CodexReviewStoreBackend {
    let isActive = true
    let shouldAutoStartEmbeddedServer = false
    let initialAccount: CodexAccount? = nil
    let initialAccounts: [CodexAccount] = []
    let initialActiveAccountKey: String? = nil

    private let failingSessionIDs: Set<String>
    private let error: any Error

    init(
        failingSessionIDs: Set<String>,
        error: any Error
    ) {
        self.failingSessionIDs = failingSessionIDs
        self.error = error
    }

    func start(
        store _: CodexReviewStore,
        forceRestartIfNeeded _: Bool
    ) async {}

    func stop(store _: CodexReviewStore) async {}

    func waitUntilStopped() async {}

    func cancelReview(
        jobID: String,
        sessionID: String,
        reason: String,
        store: CodexReviewStore
    ) async throws {
        if failingSessionIDs.contains(sessionID) {
            throw error
        }
        try store.completeCancellationLocally(
            jobID: jobID,
            sessionID: sessionID,
            reason: reason
        )
    }
}

private actor BlockingBootstrapAppServerManager: AppServerManaging {
    private let runtimeState = AppServerRuntimeState(
        pid: 200,
        startTime: .init(seconds: 2, microseconds: 0),
        processGroupLeaderPID: 200,
        processGroupLeaderStartTime: .init(seconds: 2, microseconds: 0)
    )
    private let transportStorage = BlockingBootstrapTransport()

    func prepare() async throws -> AppServerRuntimeState {
        runtimeState
    }

    func checkoutTransport(sessionID _: String) async throws -> any AppServerSessionTransport {
        transportStorage
    }

    func checkoutAuthTransport() async throws -> any AppServerSessionTransport {
        transportStorage
    }

    func currentRuntimeState() async -> AppServerRuntimeState? {
        runtimeState
    }

    func diagnosticLineStream() async -> AsyncStreamSubscription<String> {
        let (stream, continuation) = AsyncStream<String>.makeStream()
        continuation.finish()
        return .init(stream: stream, cancel: {})
    }

    func diagnosticsTail() async -> String {
        ""
    }

    func shutdown() async {}

    func sessionTransport() -> BlockingBootstrapTransport {
        transportStorage
    }
}

private actor BlockingBootstrapTransport: AppServerSessionTransport {
    private var requestCounts: [String: Int] = [:]
    private var requestWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var closedStorage = false
    private let configReadGate = OneShotGate()

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
            await configReadGate.wait()
            try Task.checkCancellation()
            throw TestFailure("config/read should have been interrupted")
        default:
            throw TestFailure("unexpected bootstrap request: \(method)")
        }
    }

    func notify<Params: Encodable & Sendable>(method _: String, params _: Params) async throws {}

    func notificationStream() async -> AsyncThrowingStreamSubscription<AppServerServerNotification> {
        .init(stream: .init { $0.finish() }, cancel: {})
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

private actor AuthCapableAppServerSessionTransport: AppServerSessionTransport {
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

    func notificationStream() async -> AsyncThrowingStreamSubscription<AppServerServerNotification> {
        let (stream, continuation) = AsyncThrowingStream<AppServerServerNotification, Error>.makeStream()
        setContinuation(continuation)
        return .init(
            stream: stream,
            cancel: { [self] in
                await close()
            }
        )
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

private actor DisconnectingRateLimitReadTransport: AppServerSessionTransport {
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

    func notificationStream() async -> AsyncThrowingStreamSubscription<AppServerServerNotification> {
        .init(stream: .init { $0.finish() }, cancel: {})
    }

    func isClosed() async -> Bool {
        false
    }

    func close() async {}
}

private struct TestWebAuthenticationRequest: Equatable {
    var url: URL
    var callbackScheme: String
    var prefersEphemeral: Bool
}

private actor TestWebAuthenticationSessionRecorder {
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

private func makeWebAuthenticationSessionFactory(
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

private func makeInjectedNativeLoginAuthSessionFactory(
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

private func runWithRestartClock(
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
private final class ObservableValueProbe<Value: Sendable>: @unchecked Sendable {
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

private func waitForFileAppearance(
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

private func waitForObservedValue<Value: Sendable>(
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

private func withTestTimeout<T: Sendable>(
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

private final class FakeForcedRestartEnvironment: @unchecked Sendable {
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

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

private func isolatedHomeEnvironment(extra: [String: String] = [:]) throws -> [String: String] {
    var environment = ["HOME": try makeTemporaryDirectory().path]
    for (key, value) in extra {
        environment[key] = value
    }
    return environment
}

@MainActor
private func makeTestStore(
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
private func makeInjectedAuthSessionStore(
    configuration: ReviewServerConfiguration,
    diagnosticsURL: URL? = nil,
    appServerManager: any AppServerManaging,
    authSessionFactory: @escaping @Sendable () async throws -> any ReviewAuthSession,
    rateLimitObservationClock: any ReviewClock = ContinuousClock(),
    rateLimitStaleRefreshInterval: Duration = .seconds(60),
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
        deferStartupAuthRefreshUntilPrepared: deferStartupAuthRefreshUntilPrepared
    )
}

private actor PersistingReviewAuthSession: ReviewAuthSession {
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

    func notificationStream() async -> AsyncThrowingStreamSubscription<AppServerServerNotification> {
        await base.notificationStream()
    }

    func close() async {
        await base.close()
    }
}

private func writeReviewAuthSnapshot(
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

private func makeReviewAuthTestJWT(payload: [String: Any]) -> String {
    let header = ["alg": "none", "typ": "JWT"]
    let headerData = try? JSONSerialization.data(withJSONObject: header)
    let payloadData = try? JSONSerialization.data(withJSONObject: payload)
    let headerComponent = makeReviewAuthJWTComponent(headerData ?? Data())
    let payloadComponent = makeReviewAuthJWTComponent(payloadData ?? Data())
    return "\(headerComponent).\(payloadComponent)."
}

private func makeReviewAuthJWTComponent(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private struct StoreDiagnosticsSnapshot: Decodable {
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

private func readStoreDiagnosticsSnapshot(from fileURL: URL) throws -> StoreDiagnosticsSnapshot {
    let data = try Data(contentsOf: fileURL)
    return try JSONDecoder().decode(StoreDiagnosticsSnapshot.self, from: data)
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private struct TestFailure: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

private struct TestAuthState: Equatable {
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
private func applyTestAuthState(
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
private func testAuthState(from auth: CodexReviewAuthModel) -> TestAuthState {
    .init(
        isAuthenticated: auth.isAuthenticated,
        accountID: auth.account?.email,
        progress: auth.progress,
        errorMessage: auth.errorMessage
    )
}

@MainActor
private func rateLimitWindow(
    duration: Int,
    in account: CodexAccount?
) -> CodexRateLimitWindow? {
    account?.rateLimits.first { $0.windowDurationMinutes == duration }
}
