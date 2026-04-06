import Foundation
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

    @Test func startingStoreRefreshesAuthStateInBackgroundWithoutBlockingStartup() async throws {
        let environment = try isolatedHomeEnvironment()
        let manager = MockAppServerManager { _ in .success() }
        let authSession = SlowReadAccountReviewAuthSession()
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

        let startTask = Task {
            await store.start()
        }
        let completed = await taskCompletesWithin(startTask, timeout: .milliseconds(250))

        #expect(completed)
        #expect(store.serverState == .running)
        try await waitUntilAsync(timeout: .seconds(2)) {
            await authSession.readAccountCallCount() == 1
        }

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

        try await waitUntilAsync(timeout: .seconds(2)) {
            await store.auth.state == .signedIn(accountID: "review@example.com")
        }

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
        try await waitUntil(timeout: .seconds(2)) {
            ReviewDiscovery.readPersisted(from: discoveryFileURL) != nil
        }
        #expect(ReviewRuntimeStateStore.read(from: runtimeStateFileURL) == nil)

        await store.stop()
        _ = await startTask.value

        #expect(store.serverState == .stopped)
        #expect(ReviewDiscovery.readPersisted(from: discoveryFileURL) == nil)
        #expect(ReviewRuntimeStateStore.read(from: runtimeStateFileURL) == nil)
        #expect(await manager.shutdownCount() == 1)
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
            selector: .init(reviewThreadID: nil, cwd: nil, statuses: [.running], latest: true),
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
            selector: .init(reviewThreadID: nil, cwd: nil, statuses: [.running], latest: true),
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

    @Test func cancelAuthenticationClosesStateWithoutStartingAnotherAuthSession() async throws {
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

        let beginTask = Task {
            await store.auth.beginAuthentication()
        }

        try await waitUntilAsync(timeout: .seconds(2)) {
            let params = await authSession.recordedLoginParams()
            return params == [.chatGPT]
        }

        await store.auth.cancelAuthentication()
        _ = await beginTask.value

        #expect(store.auth.state == .signedOut)
        #expect(await authFactory.creationCount() == 1)
        #expect(await authSession.cancelledLoginIDs() == ["login-browser"])
    }

    @Test func beginAuthenticationUsesInjectedAuthSessionWithoutAuthTransportCheckout() async throws {
        let environment = try isolatedHomeEnvironment()
        let manager = AuthCapableAppServerManager()
        let authSession = BlockingLoginReviewAuthSession()
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

        let beginTask = Task {
            await store.auth.beginAuthentication()
        }

        try await waitUntilAsync(timeout: .seconds(2)) {
            let params = await authSession.recordedLoginParams()
            return params == [.chatGPT]
        }
        try await waitUntilAsync(timeout: .seconds(2)) {
            let authState = await store.auth.state
            guard case .signingIn(let progress) = authState else {
                return false
            }
            return progress.browserURL?.contains("/oauth/authorize") == true
        }

        await store.auth.cancelAuthentication()
        _ = await beginTask.value

        #expect(await manager.authTransportCheckoutCount() == 0)
        #expect(await manager.reviewTransportCheckoutCount() == 0)
        #expect(await manager.shutdownCount() == 0)
        #expect(store.auth.state == .signedOut)
    }

    @Test func successfulAuthenticationRecyclesSharedAppServer() async throws {
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
        await store.auth.beginAuthentication()

        #expect(store.auth.state == .signedIn(accountID: "review@example.com"))
        #expect(await manager.prepareCount() == 2)
        #expect(await manager.shutdownCount() == 1)

        await store.stop()
    }

    @Test func failedAuthenticationWithoutPersistedDedicatedHomeAuthDoesNotRecycleSharedAppServer() async throws {
        let environment = try isolatedHomeEnvironment()
        let manager = AuthCapableAppServerManager()
        let authSession = NonPersistentSuccessfulLoginReviewAuthSession()
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
        await store.auth.beginAuthentication()

        #expect(store.auth.state == .failed(reviewAuthPersistenceFailureMessage))
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
        store.auth.updateState(.signedIn(accountID: "review@example.com"))
        await store.auth.logout()

        #expect(store.auth.state == .signedOut)
        #expect(await manager.prepareCount() == 2)
        #expect(await manager.shutdownCount() == 1)

        await store.stop()
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

    func readAccount(refreshToken _: Bool) async throws -> AppServerAccountReadResponse {
        .init(account: nil, requiresOpenAIAuth: true)
    }

    func startLogin(_ params: AppServerLoginAccountParams) async throws -> AppServerLoginAccountResponse {
        loginParams.append(params)
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
        let stream = AsyncThrowingStream<AppServerServerNotification, Error> { continuation in
            Task {
                self.setContinuation(continuation)
            }
        }
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

    private func setContinuation(
        _ continuation: AsyncThrowingStream<AppServerServerNotification, Error>.Continuation
    ) {
        self.continuation = continuation
    }
}

private actor SlowReadAccountReviewAuthSession: ReviewAuthSession {
    private var readAccountCallCountStorage = 0

    func readAccount(refreshToken _: Bool) async throws -> AppServerAccountReadResponse {
        readAccountCallCountStorage += 1
        try await Task.sleep(for: .seconds(60))
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

private actor SuccessfulLoginReviewAuthSession: ReviewAuthSession {
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
        let stream = AsyncThrowingStream<AppServerServerNotification, Error> { continuation in
            Task {
                self.setContinuation(continuation)
            }
        }
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
        let stream = AsyncThrowingStream<AppServerServerNotification, Error> { continuation in
            Task {
                self.setContinuation(continuation)
            }
        }
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
    private let authTransport = AuthCapableAppServerSessionTransport()
    private var authCheckoutCountStorage = 0
    private var reviewCheckoutCountStorage = 0
    private var shutdownCountStorage = 0
    private var prepareCountStorage = 0

    func prepare() async throws -> AppServerRuntimeState {
        prepareCountStorage += 1
        return runtimeState
    }

    func checkoutTransport(sessionID _: String) async throws -> any AppServerSessionTransport {
        reviewCheckoutCountStorage += 1
        return MockAppServerSessionTransport(mode: .success())
    }

    func checkoutAuthTransport() async throws -> any AppServerSessionTransport {
        authCheckoutCountStorage += 1
        return authTransport
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
            try await Task.sleep(for: .seconds(60))
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
    private var continuation: AsyncThrowingStream<AppServerServerNotification, Error>.Continuation?
    private var isClosedStorage = false

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
            return try decode(
                ["account": NSNull(), "requiresOpenaiAuth": true],
                as: responseType
            )
        case "account/login/start":
            return try decode(
                [
                    "type": "chatgpt",
                    "loginId": "login-browser",
                    "authUrl": "https://auth.openai.com/oauth/authorize?foo=bar",
                ],
                as: responseType
            )
        case "account/login/cancel":
            return try decode([:], as: responseType)
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
        let stream = AsyncThrowingStream<AppServerServerNotification, Error> { continuation in
            Task {
                self.setContinuation(continuation)
            }
        }
        return .init(
            stream: stream,
            cancel: { [self] in
                await close()
            }
        )
    }

    func isClosed() async -> Bool {
        isClosedStorage
    }

    func close() async {
        isClosedStorage = true
        continuation?.finish()
        continuation = nil
    }

    private func setContinuation(
        _ continuation: AsyncThrowingStream<AppServerServerNotification, Error>.Continuation
    ) {
        self.continuation = continuation
    }

    private func decode<Response: Decodable & Sendable>(
        _ object: Any,
        as responseType: Response.Type
    ) throws -> Response {
        _ = responseType
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(Response.self, from: data)
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

private func waitUntil(
    timeout: Duration,
    interval: Duration = .milliseconds(50),
    condition: @escaping @Sendable () -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() {
            return
        }
        try await Task.sleep(for: interval)
    }
    throw TestFailure("timed out waiting for condition")
}

private func waitUntilAsync(
    timeout: Duration,
    interval: Duration = .milliseconds(50),
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() {
            return
        }
        try await Task.sleep(for: interval)
    }
    throw TestFailure("timed out waiting for condition")
}

private func taskCompletesWithin(
    _ task: Task<Void, Never>,
    timeout: Duration
) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            await task.value
            return true
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return false
        }
        defer { group.cancelAll() }
        return await group.next() ?? false
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
    appServerManager: any AppServerManaging
) -> CodexReviewStore {
    CodexReviewStore(
        configuration: configuration,
        appServerManager: appServerManager,
        authSessionFactory: makeStubReviewAuthSessionFactory()
    )
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
