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
struct CodexReviewMCPLifecycleTests {
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
        defer { Task { await store.stop() } }

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
        defer { Task { await store.stop() } }
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
        defer { Task { await store.stop() } }
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
        let coreDependencies = ReviewCoreDependencies(
            environment: environment,
            uuid: { UUID(uuidString: "00000000-0000-0000-0000-000000000022")! }
        )
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
                environment: environment,
                coreDependencies: coreDependencies
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

        try await withAsyncCleanup {
            await store.start()

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
        } cleanup: {
            await store.stop()
        }
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

        try await withAsyncCleanup {
            await store.start()

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
        } cleanup: {
            await store.stop()
        }
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

        try await withAsyncCleanup {
            await store.start()

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
            try await waitForMainActorCondition {
                store.workspaces.contains { workspace in
                    workspace.jobs.contains { job in
                        job.sessionID == "session-bootstrap" && job.status == .running
                    }
                }
            }

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
        } cleanup: {
            await store.stop()
        }
    }

    @Test func cancelAllRunningJobsThrowsWhenAnyReviewCancellationFails() async throws {
        let store = CodexReviewStore.makeTestingStore(
            harness: CancellationFailureStoreBackend(
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

    @Test func terminateAllRunningJobsLocallyFinalizesCancellationRequestedJobs() {
        let store = CodexReviewStore.makePreviewStore()
        let requestedJob = CodexReviewJob.makeForTesting(
            id: "job-requested",
            sessionID: "session-a",
            targetSummary: "target-a",
            status: .running,
            summary: "Cancellation requested."
        )
        requestedJob.cancellationRequested = true
        requestedJob.errorMessage = "Account change requested."
        let failedJob = CodexReviewJob.makeForTesting(
            id: "job-failed",
            sessionID: "session-b",
            targetSummary: "target-b",
            status: .running,
            summary: "Running"
        )
        store.workspaces = [
            CodexReviewWorkspace(
                cwd: "/tmp/repo",
                jobs: [requestedJob, failedJob]
            )
        ]

        store.terminateAllRunningJobsLocally(
            reason: "Account change requested.",
            failureMessage: "Cancellation failed."
        )

        #expect(requestedJob.status == .failed)
        #expect(requestedJob.cancellationRequested == false)
        #expect(requestedJob.summary == "Failed to cancel review: Cancellation failed.")
        #expect(requestedJob.errorMessage == "Cancellation failed.")
        #expect(requestedJob.endedAt != nil)

        #expect(failedJob.status == .failed)
        #expect(failedJob.cancellationRequested == false)
        #expect(failedJob.summary == "Failed to cancel review: Cancellation failed.")
        #expect(failedJob.errorMessage == "Cancellation failed.")
        #expect(failedJob.endedAt != nil)
    }

}
