import Foundation
import Testing
import ReviewTestSupport
@testable import ReviewCore
@testable import ReviewJobs

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
            onStart: { _ in },
            onEvent: { _ in },
            requestedTerminationReason: { nil as ReviewTerminationReason? }
        )

        #expect(result.state == ReviewJobState.succeeded)
        #expect(result.model == "gpt-5.4-mini")
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
        let result = try await task.value

        #expect(result.state == ReviewJobState.cancelled)
        #expect(await session.backgroundCleanCount >= 1)
        #expect(await session.unsubscribeCount >= 1)
    }

    @Test func appServerReviewRunnerCancelsBeforeFirstTurnStatusArrives() async throws {
        let cwd = try makeTemporaryDirectory()
        let cancellation = CancellationFlag()
        let reviewStarted = ReviewStartedProbe()
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
        let result = try await task.value

        #expect(result.state == .cancelled)
        #expect(await session.backgroundCleanCount >= 1)
        #expect(await session.unsubscribeCount >= 1)
    }

    @Test func appServerReviewRunnerPreservesParentThreadIDWhenReviewThreadDiffers() async throws {
        let cwd = try makeTemporaryDirectory()
        let reviewStarted = ReviewStartedProbe()
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
        let result = try await task.value

        #expect(result.state == ReviewJobState.cancelled)
        #expect(result.reviewThreadID == "thr-review")
        #expect(result.threadID == "thr-parent")
    }

    @Test func appServerReviewRunnerStopsLocallyWhenInterruptRequestFails() async throws {
        let cwd = try makeTemporaryDirectory()
        let reviewStarted = ReviewStartedProbe()
        let cancellation = CancellationFlag()
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
        runner.threadUnavailableGracePeriod = .seconds(1)
        let session = MockAppServerSessionTransport(
            mode: .commandOutputThenTransportDisconnect()
        )

        let task = Task {
            try await runner.run(
                session: session,
                request: .init(cwd: cwd.path, target: .uncommittedChanges),
                defaultTimeoutSeconds: nil as Int?,
                onStart: { _ in },
                onEvent: { _ in },
                requestedTerminationReason: { nil as ReviewTerminationReason? }
            )
        }

        #expect(await taskCompletesWithin(task, timeout: .milliseconds(100)) == false)

        let result = try await task.value

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
            onStart: { _ in },
            onEvent: { _ in },
            requestedTerminationReason: { nil as ReviewTerminationReason? }
        )

        #expect(result.state == .succeeded)
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
                stateChangeSubscription: await stateChanges.subscription(),
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
        let result = try await awaitTaskValue(task, timeout: .seconds(1))

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
            onStart: { _ in },
            onEvent: { _ in },
            requestedTerminationReason: { nil as ReviewTerminationReason? }
        )

        #expect(result.state == .failed)
        #expect(result.exitCode == 124)
        #expect(result.errorMessage == "Review timed out after 0 seconds.")
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
        cancellationReason = .cancelled(reason)
    }
}

private actor StateChangeSignal {
    private var continuation: AsyncStream<Void>.Continuation?

    func subscription() -> AsyncStreamSubscription<Void> {
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
        return .init(
            stream: stream,
            cancel: { [weak self] in
                await self?.finish()
            }
        )
    }

    func yield() {
        continuation?.yield(())
    }

    func finish() {
        continuation?.finish()
        continuation = nil
    }
}

private struct TaskAwaitTimeoutError: Error {}

private func taskCompletesWithin<T: Sendable>(
    _ task: Task<T, Error>,
    timeout: Duration
) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            _ = try? await task.value
            return true
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return false
        }
        let completed = await group.next() ?? false
        group.cancelAll()
        return completed
    }
}

private func awaitTaskValue<T: Sendable>(
    _ task: Task<T, Error>,
    timeout: Duration
) async throws -> T {
    defer { task.cancel() }
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await task.value
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw TaskAwaitTimeoutError()
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else {
            throw TaskAwaitTimeoutError()
        }
        return result
    }
}

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
