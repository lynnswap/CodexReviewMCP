import Foundation
import Testing
import ReviewPorts
import ReviewTestSupport
@testable import ReviewAppServerAdapter
@testable import ReviewPlatform
@testable import ReviewMCPAdapter

@testable import ReviewDomain

@Suite(.serialized)
struct AppServerReviewRunnerTests {
    @Test func appServerReviewRunnerSucceedsAndCapturesReviewLifecycle() async throws {
        let cwd = try makeTemporaryDirectory()
        let recorder = EventRecorder()
        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                environment: try isolatedHomeEnvironment()
            )
        )
        let session = MockAppServerSessionTransport(
            mode: .success(finalReview: "Looks solid overall.")
        )

        let result = try await runner.run(
            session: session,
            request: .init(cwd: cwd.path, target: .uncommittedChanges),
            defaultTimeoutSeconds: nil as Int?,
            stateChangeStream: await StateChangeSignal().subscription(),
            onStart: { _ in },
            onEvent: { event in
                await recorder.record(event)
            },
            requestedTerminationReason: { nil as ReviewTerminationReason? }
        )

        #expect(result.state == ReviewJobState.succeeded)
        #expect(result.reviewThreadID == "thr-review")
        #expect(result.threadID == "thr-review")
        #expect(result.turnID == "turn-review")
        #expect(result.model == "gpt-5.4-mini")
        #expect(result.content == "Looks solid overall.")
        #expect(await recorder.reviewThreadID == "thr-review")
        #expect(await recorder.reviewModel == "gpt-5.4-mini")
        #expect(await session.backgroundCleanCount >= 1)
        #expect(await session.unsubscribeCount >= 1)
    }

    @Test func appServerReviewRunnerFallsBackWhenConfigReadIsUnavailable() async throws {
        let cwd = try makeTemporaryDirectory()
        let tempHome = try makeTemporaryDirectory()
        try writeReviewLocalConfig(
            homeURL: tempHome,
            content: #"review_model = "gpt-5.4-mini""#
        )
        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                environment: ["HOME": tempHome.path]
            )
        )
        let session = MockAppServerSessionTransport(mode: .configReadUnsupported)

        let result = try await runner.run(
            session: session,
            request: .init(cwd: cwd.path, target: .uncommittedChanges),
            defaultTimeoutSeconds: nil as Int?,
            stateChangeStream: await StateChangeSignal().subscription(),
            onStart: { _ in },
            onEvent: { _ in },
            requestedTerminationReason: { nil as ReviewTerminationReason? }
        )

        #expect(result.state == ReviewJobState.succeeded)
        #expect(result.model == "gpt-5.4-mini")
    }

    @Test func appServerReviewRunnerParsesStructuredReviewResult() async throws {
        let cwd = try makeTemporaryDirectory()
        let dash = "\u{2014}"
        let finalReview = """
        The changes introduce one issue.

        Review comment:

        - [P2] Keep result metadata available \(dash) \(cwd.path)/Sources/App.swift:7-9
          The final review text is currently the only place where finding metadata survives.
        """
        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                environment: try isolatedHomeEnvironment()
            )
        )
        let session = MockAppServerSessionTransport(mode: .success(finalReview: finalReview))

        let result = try await runner.run(
            session: session,
            request: .init(cwd: cwd.path, target: .uncommittedChanges),
            defaultTimeoutSeconds: nil as Int?,
            stateChangeStream: await StateChangeSignal().subscription(),
            onStart: { _ in },
            onEvent: { _ in },
            requestedTerminationReason: { nil as ReviewTerminationReason? }
        )

        let reviewResult = try #require(result.reviewResult)
        #expect(reviewResult.state == .hasFindings)
        #expect(reviewResult.findingCount == 1)
        let finding = try #require(reviewResult.findings.first)
        #expect(finding.title == "[P2] Keep result metadata available")
        #expect(finding.body == "The final review text is currently the only place where finding metadata survives.")
        #expect(finding.priority == 2)
        #expect(finding.location?.path == "\(cwd.path)/Sources/App.swift")
        #expect(finding.location?.startLine == 7)
        #expect(finding.location?.endLine == 9)
    }

    @Test func appServerReviewRunnerReadsReviewConfigFromInjectedPaths() async throws {
        let cwd = try makeTemporaryDirectory()
        let environmentHome = try makeTemporaryDirectory()
        let injectedHome = try makeTemporaryDirectory()
        try writeReviewLocalConfig(homeURL: environmentHome, content: #"review_model = "gpt-env""#)
        try writeReviewLocalConfig(homeURL: injectedHome, content: #"review_model = "gpt-injected""#)
        let environment = ["HOME": environmentHome.path]
        let coreDependencies = ReviewCoreDependencies(
            environment: environment,
            paths: ReviewPathResolver(
                environment: ["HOME": injectedHome.path],
                homeDirectoryForCurrentUser: environmentHome
            )
        )
        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(environment: environment),
            coreDependencies: coreDependencies
        )
        let session = MockAppServerSessionTransport(mode: .success(finalReview: "Looks solid overall."))

        let result = try await runner.run(
            session: session,
            request: .init(cwd: cwd.path, target: .uncommittedChanges),
            defaultTimeoutSeconds: nil as Int?,
            stateChangeStream: await StateChangeSignal().subscription(),
            onStart: { _ in },
            onEvent: { _ in },
            requestedTerminationReason: { nil as ReviewTerminationReason? }
        )

        #expect(result.state == ReviewJobState.succeeded)
        #expect(result.model == "gpt-injected")
    }

    @Test func appServerReviewRunnerWaitsForSecondNotificationBatchBeforeCleaningUp() async throws {
        let cwd = try makeTemporaryDirectory()
        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                environment: try isolatedHomeEnvironment()
            )
        )
        let session = MockAppServerSessionTransport(mode: .batchedSuccess(finalReview: "Looks solid overall."))

        let result = try await runner.run(
            session: session,
            request: .init(cwd: cwd.path, target: .uncommittedChanges),
            defaultTimeoutSeconds: nil as Int?,
            stateChangeStream: await StateChangeSignal().subscription(),
            onStart: { _ in },
            onEvent: { _ in },
            requestedTerminationReason: { nil as ReviewTerminationReason? }
        )

        #expect(result.state == .succeeded)
        #expect(result.content == "Looks solid overall.")
        #expect(await session.backgroundCleanCount == 1)
        #expect(await session.unsubscribeCount == 1)
    }

    @Test func appServerReviewRunnerThrowsWhenConfigReadFailsUnexpectedly() async throws {
        let cwd = try makeTemporaryDirectory()
        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                environment: try isolatedHomeEnvironment()
            )
        )
        let session = MockAppServerSessionTransport(mode: .configReadFailure())

        await #expect(throws: ReviewBootstrapFailure.self) {
            _ = try await runner.run(
                session: session,
                request: .init(cwd: cwd.path, target: .uncommittedChanges),
                defaultTimeoutSeconds: nil as Int?,
                stateChangeStream: await StateChangeSignal().subscription(),
                onStart: { _ in },
                onEvent: { _ in },
                requestedTerminationReason: { nil as ReviewTerminationReason? }
            )
        }
    }

    @Test func appServerReviewRunnerCancelsViaTurnInterruptAndCleansThread() async throws {
        let cwd = try makeTemporaryDirectory()
        let cancellation = CancellationFlag()
        let reviewStarted = ReviewStartedProbe()
        let stateChanges = StateChangeSignal()
        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                environment: try isolatedHomeEnvironment()
            )
        )
        let session = MockAppServerSessionTransport(mode: .longRunning())

        let task = Task {
            try await runner.run(
                session: session,
                request: .init(cwd: cwd.path, target: .uncommittedChanges),
                defaultTimeoutSeconds: nil as Int?,
                stateChangeStream: await stateChanges.subscription(),
                onStart: { _ in },
                onEvent: { event in
                    await reviewStarted.record(event)
                },
                requestedTerminationReason: {
                    await cancellation.reason
                }
            )
        }

        await Task.yield()
        await reviewStarted.wait()
        await cancellation.cancel("Cancellation requested.")
        await stateChanges.yield()
        let result = try await task.value

        #expect(result.state == ReviewJobState.cancelled)
        #expect(await session.backgroundCleanCount >= 1)
        #expect(await session.unsubscribeCount >= 1)
    }

    @Test func appServerReviewRunnerCancelsWithoutObservedTurnStart() async throws {
        let cwd = try makeTemporaryDirectory()
        let cancellation = CancellationFlag()
        let reviewStarted = ReviewStartedProbe()
        let stateChanges = StateChangeSignal()
        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                environment: try isolatedHomeEnvironment()
            )
        )
        let session = MockAppServerSessionTransport(mode: .longRunningWithoutTurnStarted())

        let task = Task {
            try await runner.run(
                session: session,
                request: .init(cwd: cwd.path, target: .uncommittedChanges),
                defaultTimeoutSeconds: nil as Int?,
                stateChangeStream: await stateChanges.subscription(),
                onStart: { _ in },
                onEvent: { event in
                    await reviewStarted.record(event)
                },
                requestedTerminationReason: {
                    await cancellation.reason
                }
            )
        }

        await Task.yield()
        await reviewStarted.wait()
        await cancellation.cancel("Cancellation requested before turn/started.")
        await stateChanges.yield()
        let result = try await task.value

        #expect(result.state == .cancelled)
        #expect(await session.backgroundCleanCount >= 1)
        #expect(await session.unsubscribeCount >= 1)
    }

    @Test func appServerReviewRunnerReplaysPendingCancellationAfterStateSubscriptionAttaches() async throws {
        let cwd = try makeTemporaryDirectory()
        let cancellation = CancellationFlag()
        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                environment: try isolatedHomeEnvironment()
            )
        )
        let session = NotificationHookAppServerSessionTransport(
            base: MockAppServerSessionTransport(mode: .longRunning()),
            onNotificationStream: {
                await cancellation.cancel("Cancellation requested before state stream started consuming.")
            }
        )

        let task = Task {
            try await runner.run(
                session: session,
                request: .init(cwd: cwd.path, target: .uncommittedChanges),
                defaultTimeoutSeconds: nil as Int?,
                stateChangeStream: await StateChangeSignal().subscription(),
                onStart: { _ in },
                onEvent: { _ in },
                requestedTerminationReason: {
                    await cancellation.reason
                }
            )
        }

        let result = try await withTestTimeout {
            try await task.value
        }

        #expect(result.state == .cancelled)
        #expect(result.errorMessage == "Cancellation requested before state stream started consuming.")
    }

    @Test func appServerReviewRunnerPreservesParentThreadIDWhenReviewThreadDiffers() async throws {
        let cwd = try makeTemporaryDirectory()
        let reviewStarted = ReviewStartedProbe()
        let stateChanges = StateChangeSignal()
        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                environment: try isolatedHomeEnvironment()
            )
        )
        let session = MockAppServerSessionTransport(mode: .detachedLongRunning())
        let cancellation = CancellationFlag()

        let task = Task {
            try await runner.run(
                session: session,
                request: .init(cwd: cwd.path, target: .uncommittedChanges),
                defaultTimeoutSeconds: nil as Int?,
                stateChangeStream: await stateChanges.subscription(),
                onStart: { _ in },
                onEvent: { event in
                    await reviewStarted.record(event)
                },
                requestedTerminationReason: {
                    await cancellation.reason
                }
            )
        }

        await Task.yield()
        await reviewStarted.wait()
        await cancellation.cancel("Cancelled from detached test.")
        await stateChanges.yield()
        let result = try await task.value

        #expect(result.state == ReviewJobState.cancelled)
        #expect(result.reviewThreadID == "thr-review")
        #expect(result.threadID == "thr-parent")
    }

    @Test func appServerReviewRunnerStopsLocallyWhenInterruptRequestFails() async throws {
        let cwd = try makeTemporaryDirectory()
        let reviewStarted = ReviewStartedProbe()
        let cancellation = CancellationFlag()
        let stateChanges = StateChangeSignal()
        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                environment: try isolatedHomeEnvironment()
            )
        )
        let session = MockAppServerSessionTransport(mode: .interruptFailure())

        let task = Task {
            try await runner.run(
                session: session,
                request: .init(cwd: cwd.path, target: .uncommittedChanges),
                defaultTimeoutSeconds: nil as Int?,
                stateChangeStream: await stateChanges.subscription(),
                onStart: { _ in },
                onEvent: { event in
                    await reviewStarted.record(event)
                },
                requestedTerminationReason: {
                    await cancellation.reason
                }
            )
        }

        await Task.yield()
        await reviewStarted.wait()
        await cancellation.cancel("Cancellation requested.")
        await stateChanges.yield()
        let result = try await task.value

        #expect(result.state == ReviewJobState.cancelled)
        #expect(result.errorMessage?.contains("Cancellation requested.") == true)
        #expect(await session.backgroundCleanCount >= 1)
        #expect(await session.unsubscribeCount >= 1)
    }

    @Test func appServerReviewRunnerEnforcesTimeoutWhenTurnStaysInProgress() async throws {
        let cwd = try makeTemporaryDirectory()
        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                environment: try isolatedHomeEnvironment()
            )
        )
        let session = MockAppServerSessionTransport(mode: .interruptIgnoredLongRunning())

        let result = try await runner.run(
            session: session,
            request: .init(cwd: cwd.path, target: .uncommittedChanges),
            defaultTimeoutSeconds: 0,
            stateChangeStream: await StateChangeSignal().subscription(),
            onStart: { _ in },
            onEvent: { _ in },
            requestedTerminationReason: { nil as ReviewTerminationReason? },
            onUnrecoverableTransportFailure: {
                await session.close()
            }
        )

        #expect(result.state == ReviewJobState.failed)
        #expect(result.exitCode == 124)
        #expect(await session.isClosed())
    }

    @Test func appServerReviewRunnerCancelsWhenInterruptLeavesTurnInProgress() async throws {
        let cwd = try makeTemporaryDirectory()
        let reviewStarted = ReviewStartedProbe()
        let cancellation = CancellationFlag()
        let stateChanges = StateChangeSignal()
        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                environment: try isolatedHomeEnvironment()
            )
        )
        let session = MockAppServerSessionTransport(mode: .interruptIgnoredLongRunning())

        let task = Task {
            try await runner.run(
                session: session,
                request: .init(cwd: cwd.path, target: .uncommittedChanges),
                defaultTimeoutSeconds: nil,
                stateChangeStream: await stateChanges.subscription(),
                onStart: { _ in },
                onEvent: { event in
                    await reviewStarted.record(event)
                },
                requestedTerminationReason: {
                    await cancellation.reason
                },
                onUnrecoverableTransportFailure: {
                    await session.close()
                }
            )
        }

        await Task.yield()
        await reviewStarted.wait()
        await cancellation.cancel("Cancellation requested.")
        await stateChanges.yield()
        let result = try await task.value

        #expect(result.state == .cancelled)
        #expect(await session.isClosed())
    }

    @Test func appServerReviewRunnerReturnsBootstrapFailureWhenThreadStartDisconnects() async throws {
        let cwd = try makeTemporaryDirectory()
        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                environment: try isolatedHomeEnvironment()
            )
        )
        let session = MockAppServerSessionTransport(mode: .bootstrapFailure())

        await #expect(throws: ReviewBootstrapFailure.self) {
            _ = try await runner.run(
                session: session,
                request: .init(cwd: cwd.path, target: .uncommittedChanges),
                defaultTimeoutSeconds: nil as Int?,
                stateChangeStream: await StateChangeSignal().subscription(),
                onStart: { _ in },
                onEvent: { _ in },
                requestedTerminationReason: { nil as ReviewTerminationReason? }
            )
        }
    }

    @Test func appServerReviewRunnerCancelsSignalSourcesWhenReviewStartFails() async throws {
        let cwd = try makeTemporaryDirectory()
        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                environment: try isolatedHomeEnvironment()
            )
        )
        let session = MockAppServerSessionTransport(mode: .reviewStartFailure())

        await #expect(throws: ReviewBootstrapFailure.self) {
            _ = try await runner.run(
                session: session,
                request: .init(cwd: cwd.path, target: .uncommittedChanges),
                defaultTimeoutSeconds: nil as Int?,
                stateChangeStream: await StateChangeSignal().subscription(),
                onStart: { _ in },
                onEvent: { _ in },
                requestedTerminationReason: { nil as ReviewTerminationReason? }
            )
        }

        #expect(await session.activeNotificationSubscriberCount() == 0)
    }

    @Test func appServerReviewRunnerFailsWhenReviewThreadClosesBeforeTurnCompletes() async throws {
        let cwd = try makeTemporaryDirectory()
        let recorder = EventRecorder()
        var runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                environment: try isolatedHomeEnvironment()
            )
        )
        runner.threadUnavailableGracePeriod = .zero
        let session = MockAppServerSessionTransport(mode: .threadClosedWithoutTurnCompletion())

        let result = try await runner.run(
            session: session,
            request: .init(cwd: cwd.path, target: .uncommittedChanges),
            defaultTimeoutSeconds: nil as Int?,
            stateChangeStream: await StateChangeSignal().subscription(),
            onStart: { _ in },
            onEvent: { event in
                await recorder.record(event)
            },
            requestedTerminationReason: { nil as ReviewTerminationReason? }
        )

        #expect(result.state == .failed)
        #expect(result.errorMessage == "Review thread closed before the review completed.")
    }

    @Test func appServerReviewRunnerWaitsForTerminalEventsAfterThreadCloses() async throws {
        let cwd = try makeTemporaryDirectory()
        var runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                environment: try isolatedHomeEnvironment()
            )
        )
        runner.threadUnavailableGracePeriod = .seconds(1)
        let session = MockAppServerSessionTransport(mode: .threadClosedBeforeCompletedNotifications())

        let result = try await runner.run(
            session: session,
            request: .init(cwd: cwd.path, target: .uncommittedChanges),
            defaultTimeoutSeconds: nil as Int?,
            stateChangeStream: await StateChangeSignal().subscription(),
            onStart: { _ in },
            onEvent: { _ in },
            requestedTerminationReason: { nil as ReviewTerminationReason? }
        )

        #expect(result.state == .succeeded)
        #expect(result.content == "Looks solid overall.")
    }

    @Test func appServerReviewRunnerPrefersThreadUnavailableFailureOverTransportDisconnect() async throws {
        let cwd = try makeTemporaryDirectory()
        var runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                environment: try isolatedHomeEnvironment()
            )
        )
        runner.threadUnavailableGracePeriod = .milliseconds(100)
        let session = MockAppServerSessionTransport(mode: .threadClosedThenTransportDisconnect())

        let result = try await runner.run(
            session: session,
            request: .init(cwd: cwd.path, target: .uncommittedChanges),
            defaultTimeoutSeconds: nil as Int?,
            stateChangeStream: await StateChangeSignal().subscription(),
            onStart: { _ in },
            onEvent: { _ in },
            requestedTerminationReason: { nil as ReviewTerminationReason? }
        )

        #expect(result.state == .failed)
        #expect(result.errorMessage == "Review thread closed before the review completed.")
    }

    @Test func appServerReviewRunnerSucceedsWhenBestEffortCommandOutputPrecedesCompletion() async throws {
        let cwd = try makeTemporaryDirectory()
        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                environment: try isolatedHomeEnvironment()
            )
        )
        let session = MockAppServerSessionTransport(
            mode: .commandOutputThenSuccessThenTransportDisconnect()
        )

        let result = try await runner.run(
            session: session,
            request: .init(cwd: cwd.path, target: .uncommittedChanges),
            defaultTimeoutSeconds: nil as Int?,
            stateChangeStream: await StateChangeSignal().subscription(),
            onStart: { _ in },
            onEvent: { _ in },
            requestedTerminationReason: { nil as ReviewTerminationReason? }
        )

        #expect(result.state == .succeeded)
        #expect(result.content == "Looks solid overall.")
    }

    @Test func appServerReviewRunnerFailsWithTransportDisconnectWhenBestEffortOutputCutsOff() async throws {
        let cwd = try makeTemporaryDirectory()
        var runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                environment: try isolatedHomeEnvironment()
            )
        )
        runner.threadUnavailableGracePeriod = .zero
        let session = MockAppServerSessionTransport(
            mode: .commandOutputThenTransportDisconnect()
        )

        let result = try await runner.run(
            session: session,
            request: .init(cwd: cwd.path, target: .uncommittedChanges),
            defaultTimeoutSeconds: nil as Int?,
            stateChangeStream: await StateChangeSignal().subscription(),
            onStart: { _ in },
            onEvent: { _ in },
            requestedTerminationReason: { nil as ReviewTerminationReason? }
        )

        #expect(result.state == .failed)
        #expect(result.errorMessage == "mock app-server transport disconnected")
    }

    @Test func appServerReviewRunnerWaitsForTransportDisconnectGraceBeforeFailing() async throws {
        let cwd = try makeTemporaryDirectory()
        var runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                environment: try isolatedHomeEnvironment()
            )
        )
        let clock = ManualTestClock()
        runner.threadUnavailableGracePeriod = .seconds(1)
        runner.clock = clock
        let session = MockAppServerSessionTransport(
            mode: .commandOutputThenTransportDisconnect()
        )
        let completionSignal = AsyncSignal()

        let task = Task {
            let result = try await runner.run(
                session: session,
                request: .init(cwd: cwd.path, target: .uncommittedChanges),
                defaultTimeoutSeconds: nil as Int?,
                stateChangeStream: await StateChangeSignal().subscription(),
                onStart: { _ in },
                onEvent: { _ in },
                requestedTerminationReason: { nil as ReviewTerminationReason? }
            )
            await completionSignal.signal()
            return result
        }

        await clock.sleepUntilSuspendedBy(1)
        #expect(await completionSignal.count() == 0)
        clock.advance(by: .seconds(1))

        let result = try await withTestTimeout {
            try await task.value
        }

        #expect(result.state == .failed)
        #expect(result.errorMessage == "mock app-server transport disconnected")
    }

    @Test func appServerReviewRunnerDoesNotLetCancelledThreadUnavailableGraceFailActiveReview() async throws {
        let cwd = try makeTemporaryDirectory()
        var runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                environment: try isolatedHomeEnvironment()
            )
        )
        runner.threadUnavailableGracePeriod = .seconds(1)
        let session = MockAppServerSessionTransport(
            mode: .threadUnavailableRescheduledByTrackedActivity()
        )

        let result = try await runner.run(
            session: session,
            request: .init(cwd: cwd.path, target: .uncommittedChanges),
            defaultTimeoutSeconds: nil as Int?,
            stateChangeStream: await StateChangeSignal().subscription(),
            onStart: { _ in },
            onEvent: { _ in },
            requestedTerminationReason: { nil as ReviewTerminationReason? }
        )

        #expect(result.state == .succeeded)
        #expect(result.content == "Looks solid overall.")
    }

    @Test func appServerReviewRunnerIgnoresUnrelatedNonRetryErrorNotifications() async throws {
        let cwd = try makeTemporaryDirectory()
        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                environment: try isolatedHomeEnvironment()
            )
        )
        let session = MockAppServerSessionTransport(mode: .unrelatedNonRetryErrorThenSuccess())

        let result = try await runner.run(
            session: session,
            request: .init(cwd: cwd.path, target: .uncommittedChanges),
            defaultTimeoutSeconds: nil as Int?,
            stateChangeStream: await StateChangeSignal().subscription(),
            onStart: { _ in },
            onEvent: { _ in },
            requestedTerminationReason: { nil as ReviewTerminationReason? }
        )

        #expect(result.state == .succeeded)
        #expect(result.content == "Looks solid overall.")
    }

    @Test func appServerReviewRunnerIgnoresUnrelatedTurnStartedBeforeReviewStartResponse() async throws {
        let cwd = try makeTemporaryDirectory()
        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                environment: try isolatedHomeEnvironment()
            )
        )
        let session = MockAppServerSessionTransport(
            mode: .unrelatedTurnStartedBeforeReviewStartThenSuccess()
        )

        let result = try await runner.run(
            session: session,
            request: .init(cwd: cwd.path, target: .uncommittedChanges),
            defaultTimeoutSeconds: nil as Int?,
            stateChangeStream: await StateChangeSignal().subscription(),
            onStart: { _ in },
            onEvent: { _ in },
            requestedTerminationReason: { nil as ReviewTerminationReason? }
        )

        #expect(result.state == .succeeded)
        #expect(result.turnID == "turn-review")
        #expect(result.threadID == "thr-review")
        #expect(result.content == "Looks solid overall.")
    }

    @Test func appServerReviewRunnerIgnoresParentThreadClosureForDetachedReviews() async throws {
        let cwd = try makeTemporaryDirectory()
        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                environment: try isolatedHomeEnvironment()
            )
        )
        let session = MockAppServerSessionTransport(
            mode: .detachedParentThreadClosedBeforeCompletedNotifications()
        )

        let result = try await runner.run(
            session: session,
            request: .init(cwd: cwd.path, target: .uncommittedChanges),
            defaultTimeoutSeconds: nil as Int?,
            stateChangeStream: await StateChangeSignal().subscription(),
            onStart: { _ in },
            onEvent: { _ in },
            requestedTerminationReason: { nil as ReviewTerminationReason? }
        )

        #expect(result.state == .succeeded)
        #expect(result.reviewThreadID == "thr-review")
        #expect(result.threadID == "thr-parent")
        #expect(result.content == "Looks solid overall.")
    }

    @Test func appServerReviewRunnerFailsImmediatelyOnTrackedNonRetryErrorNotification() async throws {
        let cwd = try makeTemporaryDirectory()
        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                environment: try isolatedHomeEnvironment()
            )
        )
        let session = MockAppServerSessionTransport(mode: .nonRetryErrorWithoutTurnCompletion())

        let result = try await runner.run(
            session: session,
            request: .init(cwd: cwd.path, target: .uncommittedChanges),
            defaultTimeoutSeconds: nil as Int?,
            stateChangeStream: await StateChangeSignal().subscription(),
            onStart: { _ in },
            onEvent: { _ in },
            requestedTerminationReason: { nil as ReviewTerminationReason? }
        )

        #expect(result.state == .failed)
        #expect(result.errorMessage == "review failed hard")
    }

    @Test func appServerReviewRunnerLetsTerminalErrorOverrideCompletedTurn() async throws {
        let cwd = try makeTemporaryDirectory()
        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                environment: try isolatedHomeEnvironment()
            )
        )
        let session = MockAppServerSessionTransport(mode: .completedThenNonRetryError())

        let result = try await runner.run(
            session: session,
            request: .init(cwd: cwd.path, target: .uncommittedChanges),
            defaultTimeoutSeconds: nil as Int?,
            stateChangeStream: await StateChangeSignal().subscription(),
            onStart: { _ in },
            onEvent: { _ in },
            requestedTerminationReason: { nil as ReviewTerminationReason? }
        )

        #expect(result.state == .failed)
        #expect(result.errorMessage == "review failed after completion")
    }

    @Test func appServerReviewRunnerPreservesFailureWhenTurnCompletesAfterError() async throws {
        let cwd = try makeTemporaryDirectory()
        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                environment: try isolatedHomeEnvironment()
            )
        )
        let session = MockAppServerSessionTransport(mode: .nonRetryErrorThenCompleted())

        let result = try await runner.run(
            session: session,
            request: .init(cwd: cwd.path, target: .uncommittedChanges),
            defaultTimeoutSeconds: nil as Int?,
            stateChangeStream: await StateChangeSignal().subscription(),
            onStart: { _ in },
            onEvent: { _ in },
            requestedTerminationReason: { nil as ReviewTerminationReason? }
        )

        #expect(result.state == .failed)
        #expect(result.errorMessage == "review failed before completion")
    }

    @Test func appServerReviewRunnerFailsWhenFinalReviewArrivesWithoutTurnCompletionAfterThreadUnload() async throws {
        let cwd = try makeTemporaryDirectory()
        var runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                environment: try isolatedHomeEnvironment()
            )
        )
        runner.threadUnavailableGracePeriod = .zero
        let session = MockAppServerSessionTransport(
            mode: .finalReviewWithoutTurnCompletionAfterThreadUnavailable()
        )

        let result = try await runner.run(
            session: session,
            request: .init(cwd: cwd.path, target: .uncommittedChanges),
            defaultTimeoutSeconds: nil as Int?,
            stateChangeStream: await StateChangeSignal().subscription(),
            onStart: { _ in },
            onEvent: { _ in },
            requestedTerminationReason: { nil as ReviewTerminationReason? }
        )

        #expect(result.state == .failed)
        #expect(result.errorMessage == "Review thread closed before the review completed.")
    }

    @Test func appServerReviewRunnerAcceptsLateFinalReviewAfterCompletedTurnAndThreadUnload() async throws {
        let cwd = try makeTemporaryDirectory()
        var runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                environment: try isolatedHomeEnvironment()
            )
        )
        runner.threadUnavailableGracePeriod = .seconds(1)
        let session = MockAppServerSessionTransport(
            mode: .turnCompletedBeforeFinalReviewThenThreadUnavailable()
        )

        let result = try await runner.run(
            session: session,
            request: .init(cwd: cwd.path, target: .uncommittedChanges),
            defaultTimeoutSeconds: nil as Int?,
            stateChangeStream: await StateChangeSignal().subscription(),
            onStart: { _ in },
            onEvent: { _ in },
            requestedTerminationReason: { nil as ReviewTerminationReason? }
        )

        #expect(result.state == .succeeded)
        #expect(result.content == "Looks solid overall.")
    }

    @Test func appServerReviewRunnerUsesTransportDisconnectFailureWhenFinalReviewNeverArrives() async throws {
        let cwd = try makeTemporaryDirectory()
        var runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                environment: try isolatedHomeEnvironment()
            )
        )
        runner.threadUnavailableGracePeriod = .zero
        let session = MockAppServerSessionTransport(
            mode: .turnCompletedThenTransportDisconnect()
        )

        let result = try await runner.run(
            session: session,
            request: .init(cwd: cwd.path, target: .uncommittedChanges),
            defaultTimeoutSeconds: nil as Int?,
            stateChangeStream: await StateChangeSignal().subscription(),
            onStart: { _ in },
            onEvent: { _ in },
            requestedTerminationReason: { nil as ReviewTerminationReason? }
        )

        #expect(result.state == .failed)
        #expect(result.errorMessage == "mock app-server transport disconnected")
    }

    @Test func appServerReviewRunnerReturnsCancelledOutcomeAfterCompletedTurnWithoutFinalReview() async throws {
        let cwd = try makeTemporaryDirectory()
        let cancellation = CancellationFlag()
        let reviewStarted = ReviewStartedProbe()
        let stateChanges = StateChangeSignal()
        var runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                environment: try isolatedHomeEnvironment()
            )
        )
        runner.threadUnavailableGracePeriod = .seconds(1)
        let session = MockAppServerSessionTransport(
            mode: .completedWithoutFinalReviewThenThreadUnavailable()
        )

        let task = Task {
            try await runner.run(
                session: session,
                request: .init(cwd: cwd.path, target: .uncommittedChanges),
                defaultTimeoutSeconds: nil as Int?,
                stateChangeStream: await stateChanges.subscription(),
                onStart: { _ in },
                onEvent: { event in
                    await reviewStarted.record(event)
                },
                requestedTerminationReason: {
                    await cancellation.reason
                }
            )
        }

        await reviewStarted.wait()
        await cancellation.cancel("Cancellation requested after completed turn.")
        await stateChanges.yield()
        let result = try await withTestTimeout {
            try await task.value
        }

        #expect(result.state == .cancelled)
        #expect(result.errorMessage == "Cancellation requested after completed turn.")
    }

    @Test func appServerReviewRunnerPrefersTimeoutOverThreadUnavailableFailure() async throws {
        let cwd = try makeTemporaryDirectory()
        var runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                environment: try isolatedHomeEnvironment()
            )
        )
        runner.threadUnavailableGracePeriod = .zero
        let session = MockAppServerSessionTransport(mode: .threadClosedWithoutTurnCompletion())

        let result = try await runner.run(
            session: session,
            request: .init(cwd: cwd.path, target: .uncommittedChanges),
            defaultTimeoutSeconds: 0,
            stateChangeStream: await StateChangeSignal().subscription(),
            onStart: { _ in },
            onEvent: { _ in },
            requestedTerminationReason: { nil as ReviewTerminationReason? }
        )

        #expect(result.state == .failed)
        #expect(result.exitCode == 124)
        #expect(result.errorMessage == "Review timed out after 0 seconds.")
    }

    @Test func remainingReviewTimeoutDurationSubtractsElapsedBootstrapTime() throws {
        let startedAt = ContinuousClock().now
        let duration = try remainingReviewTimeoutDuration(
            timeoutSeconds: 30,
            startedAt: startedAt,
            now: startedAt.advanced(by: .milliseconds(10_250))
        )

        #expect(duration == .milliseconds(19_750))
    }
}

private actor EventRecorder {
    private(set) var reviewThreadID: String?
    private(set) var reviewModel: String?

    func record(_ event: ReviewProcessEvent) {
        switch event {
        case .reviewStarted(let reviewThreadID, _, _, let model):
            self.reviewThreadID = reviewThreadID
            self.reviewModel = model
        case .progress, .logEntry, .rawLine, .agentMessage, .failed:
            break
        }
    }
}

private actor ReviewStartedProbe {
    private var hasStarted = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func record(_ event: ReviewProcessEvent) {
        guard case .reviewStarted = event, hasStarted == false else {
            return
        }
        hasStarted = true
        let continuations = waiters
        waiters.removeAll(keepingCapacity: false)
        for continuation in continuations {
            continuation.resume()
        }
    }

    func wait() async {
        if hasStarted {
            return
        }
        await withCheckedContinuation { continuation in
            if hasStarted {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }
}

private actor CancellationFlag {
    private var cancellationReason: ReviewTerminationReason?

    var reason: ReviewTerminationReason? {
        cancellationReason
    }

    func cancel(_ reason: String) {
        cancellationReason = .cancelled(.system(message: reason))
    }
}

private actor StateChangeSignal {
    private var continuation: AsyncStream<Void>.Continuation?

    func subscription() -> AsyncStream<Void> {
        var continuation: AsyncStream<Void>.Continuation!
        let stream = AsyncStream<Void>(bufferingPolicy: .unbounded) {
            continuation = $0
        }
        self.continuation = continuation
        continuation.onTermination = { _ in
            Task {
                await self.finish()
            }
        }
        return stream
    }

    func yield() {
        continuation?.yield(())
    }

    func finish() {
        continuation?.finish()
        continuation = nil
    }
}

private actor NotificationHookAppServerSessionTransport: AppServerSessionTransport {
    private let base: MockAppServerSessionTransport
    private let onNotificationStream: @Sendable () async -> Void

    init(
        base: MockAppServerSessionTransport,
        onNotificationStream: @escaping @Sendable () async -> Void
    ) {
        self.base = base
        self.onNotificationStream = onNotificationStream
    }

    func initializeResponse() async -> AppServerInitializeResponse {
        await base.initializeResponse()
    }

    func request<Params: Encodable & Sendable, Response: Decodable & Sendable>(
        method: String,
        params: Params,
        responseType: Response.Type
    ) async throws -> Response {
        try await base.request(method: method, params: params, responseType: responseType)
    }

    func notify<Params: Encodable & Sendable>(method: String, params: Params) async throws {
        try await base.notify(method: method, params: params)
    }

    func notificationStream() async -> AsyncThrowingStream<AppServerServerNotification, Error> {
        await onNotificationStream()
        return await base.notificationStream()
    }

    func isClosed() async -> Bool {
        await base.isClosed()
    }

    func close() async {
        await base.close()
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
            throw ReviewProcessRunnerTimeoutError()
        }
        defer { group.cancelAll() }
        return try await #require(group.next())
    }
}

private struct ReviewProcessRunnerTimeoutError: Error {}

private func writeReviewLocalConfig(homeURL: URL, content: String) throws {
    let configDirectory = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
    try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
    try content.write(
        to: configDirectory.appendingPathComponent("config.toml"),
        atomically: true,
        encoding: .utf8
    )
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func isolatedHomeEnvironment(extra: [String: String] = [:]) throws -> [String: String] {
    var environment = ["HOME": try makeTemporaryDirectory().path]
    for (key, value) in extra {
        environment[key] = value
    }
    return environment
}
