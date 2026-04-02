import Foundation
import Testing
@testable import ReviewCore
@testable import ReviewJobs

@Suite(.serialized) struct AppServerReviewRunnerTests {
    @Test func appServerReviewRunnerSucceedsAndCapturesLogs() async throws {
        let cwd = try makeTemporaryDirectory()
        let scriptURL = try makeFakeAppServerScript(mode: .success)
        let recorder = EventRecorder()
        var runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                codexCommand: scriptURL.path,
                environment: try isolatedHomeEnvironment()
            )
        )
        runner.gracefulTerminationWait = .milliseconds(100)

        let result = try await runner.run(
            request: .init(cwd: cwd.path, target: .uncommittedChanges),
            defaultTimeoutSeconds: nil as Int?,
            onStart: { _, _ in },
            onEvent: { event in
                await recorder.record(event)
            },
            requestedTerminationReason: { nil as ReviewTerminationReason? }
        )

        #expect(result.state == .succeeded)
        #expect(result.reviewThreadID == "thr-review")
        #expect(result.turnID == "turn-review")
        #expect(result.model == "gpt-5.4-mini")
        #expect(result.content == "Looks solid overall.")
        #expect(await recorder.reviewThreadID == "thr-review")
        #expect(await recorder.reviewModel == "gpt-5.4-mini")
        #expect(await recorder.rawLines.contains("diagnostic: success path"))
        #expect(await recorder.logTexts.contains("$ git diff --stat"))
        #expect(await recorder.logTexts.contains("README.md | 1 +"))
        #expect(await recorder.agentMessages.contains("Looks solid overall."))
    }

    @Test func appServerReviewRunnerPrefersLocalReviewModelWhenNoPublicOverrideExists() async throws {
        let cwd = try makeTemporaryDirectory()
        let tempHome = try makeTemporaryDirectory()
        let captureURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try writeReviewLocalConfig(
            homeURL: tempHome,
            content: #"review_model = "gpt-5.4-mini""#
        )
        let scriptURL = try makeFakeAppServerScript(
            mode: .success,
            configuredReviewModel: nil,
            threadStartModel: "gpt-5.4",
            captureURL: captureURL
        )
        defer { try? FileManager.default.removeItem(at: captureURL) }
        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                codexCommand: scriptURL.path,
                environment: [
                    "HOME": tempHome.path,
                ]
            )
        )

        let result = try await runner.run(
            request: .init(cwd: cwd.path, target: .uncommittedChanges),
            defaultTimeoutSeconds: nil as Int?,
            onStart: { _, _ in },
            onEvent: { _ in },
            requestedTerminationReason: { nil as ReviewTerminationReason? }
        )

        #expect(result.model == "gpt-5.4-mini")
        let threadStartParams = try #require(loadCapturedRequest(at: captureURL, method: "thread/start")?["params"] as? [String: Any])
        let config = try #require(threadStartParams["config"] as? [String: Any])
        #expect(config["review_model"] as? String == "gpt-5.4-mini")
    }

    @Test func appServerReviewRunnerUsesConfiguredReviewModelWhenLocalReviewModelIsMissing() async throws {
        let cwd = try makeTemporaryDirectory()
        let scriptURL = try makeFakeAppServerScript(
            mode: .success,
            configuredReviewModel: "gpt-5.4-mini",
            threadStartModel: "gpt-5.4"
        )
        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                codexCommand: scriptURL.path,
                environment: try isolatedHomeEnvironment()
            )
        )

        let result = try await runner.run(
            request: .init(cwd: cwd.path, target: .uncommittedChanges),
            defaultTimeoutSeconds: nil as Int?,
            onStart: { _, _ in },
            onEvent: { _ in },
            requestedTerminationReason: { nil as ReviewTerminationReason? }
        )

        #expect(result.model == "gpt-5.4-mini")
    }

    @Test func appServerReviewRunnerUsesBackendThreadModelWhenOnlyConfiguredBaseModelExists() async throws {
        let cwd = try makeTemporaryDirectory()
        let tempHome = try makeTemporaryDirectory()
        let recorder = EventRecorder()
        let scriptURL = try makeFakeAppServerScript(
            mode: .success,
            configuredModel: "gpt-5.4",
            configuredReviewModel: nil,
            threadStartModel: "gpt-5.3-codex"
        )
        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                codexCommand: scriptURL.path,
                environment: ["HOME": tempHome.path]
            )
        )

        let result = try await runner.run(
            request: .init(cwd: cwd.path, target: .uncommittedChanges),
            defaultTimeoutSeconds: nil as Int?,
            onStart: { _, _ in },
            onEvent: { event in
                await recorder.record(event)
            },
            requestedTerminationReason: { nil as ReviewTerminationReason? }
        )

        #expect(result.model == "gpt-5.3-codex")
        #expect(await recorder.reviewModel == "gpt-5.3-codex")
    }

    @Test func appServerReviewRunnerFallsBackToThreadStartModelWhenNoPreThreadStartModelExists() async throws {
        let cwd = try makeTemporaryDirectory()
        let tempHome = try makeTemporaryDirectory()
        let recorder = EventRecorder()
        let scriptURL = try makeFakeAppServerScript(
            mode: .success,
            configuredModel: "",
            configuredReviewModel: nil,
            threadStartModel: "gpt-5.4-mini-2026-02-01"
        )
        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                codexCommand: scriptURL.path,
                environment: ["HOME": tempHome.path]
            )
        )

        let result = try await runner.run(
            request: .init(cwd: cwd.path, target: .uncommittedChanges),
            defaultTimeoutSeconds: nil as Int?,
            onStart: { _, _ in },
            onEvent: { event in
                await recorder.record(event)
            },
            requestedTerminationReason: { nil as ReviewTerminationReason? }
        )

        #expect(result.model == "gpt-5.4-mini-2026-02-01")
        #expect(await recorder.reviewModel == "gpt-5.4-mini-2026-02-01")
    }

    @Test func appServerReviewRunnerFallsBackToLocalCodexConfigModelWhenBackendOmitsModel() async throws {
        let cwd = try makeTemporaryDirectory()
        let tempHome = try makeTemporaryDirectory()
        try writeCodexConfig(
            codexHomeURL: tempHome.appendingPathComponent(".codex", isDirectory: true),
            content: #"model = "gpt-5.4-mini""#
        )
        let scriptURL = try makeFakeAppServerScript(
            mode: .success,
            configuredModel: "",
            configuredReviewModel: nil,
            threadStartModel: ""
        )
        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                codexCommand: scriptURL.path,
                environment: ["HOME": tempHome.path]
            )
        )

        let result = try await runner.run(
            request: .init(cwd: cwd.path, target: .uncommittedChanges),
            defaultTimeoutSeconds: nil as Int?,
            onStart: { _, _ in },
            onEvent: { _ in },
            requestedTerminationReason: { nil as ReviewTerminationReason? }
        )

        #expect(result.model == "gpt-5.4-mini")
    }

    @Test func appServerReviewRunnerSendsLocalNumericOverridesToThreadStartConfig() async throws {
        let cwd = try makeTemporaryDirectory()
        let tempHome = try makeTemporaryDirectory()
        try writeReviewLocalConfig(
            homeURL: tempHome,
            content: """
            model_reasoning_effort = "high"
            model_context_window = 120000
            model_auto_compact_token_limit = 110000
            """
        )
        let captureURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let scriptURL = try makeFakeAppServerScript(
            mode: .success,
            configuredModel: "gpt-5.4-mini",
            captureURL: captureURL
        )
        defer { try? FileManager.default.removeItem(at: captureURL) }

        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                codexCommand: scriptURL.path,
                environment: ["HOME": tempHome.path]
            )
        )

        _ = try await runner.run(
            request: .init(cwd: cwd.path, target: .uncommittedChanges),
            defaultTimeoutSeconds: nil as Int?,
            onStart: { _, _ in },
            onEvent: { _ in },
            requestedTerminationReason: { nil as ReviewTerminationReason? }
        )

        let threadStartParams = try #require(loadCapturedRequest(at: captureURL, method: "thread/start")?["params"] as? [String: Any])
        let config = try #require(threadStartParams["config"] as? [String: Any])

        #expect(config["model_reasoning_effort"] as? String == "high")
        #expect(config["model_context_window"] as? Int == 120_000)
        #expect(config["model_auto_compact_token_limit"] as? Int == 110_000)
    }

    @Test func appServerReviewRunnerClampsThreadStartConfigUsingResolvedReviewModel() async throws {
        let cwd = try makeTemporaryDirectory()
        let captureURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let scriptURL = try makeFakeAppServerScript(
            mode: .success,
            configuredModel: "gpt-5.4-mini",
            configuredReviewModel: "gpt-5.4-mini",
            threadStartModel: "gpt-5.4-mini",
            configuredContextWindow: 999_999,
            configuredAutoCompactTokenLimit: 999_999,
            captureURL: captureURL
        )
        defer {
            try? FileManager.default.removeItem(at: captureURL)
        }

        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                codexCommand: scriptURL.path,
                environment: try isolatedHomeEnvironment()
            )
        )

        let result = try await runner.run(
            request: .init(cwd: cwd.path, target: .uncommittedChanges),
            defaultTimeoutSeconds: nil as Int?,
            onStart: { _, _ in },
            onEvent: { _ in },
            requestedTerminationReason: { nil as ReviewTerminationReason? }
        )

        let threadStartParams = try #require(loadCapturedRequest(at: captureURL, method: "thread/start")?["params"] as? [String: Any])
        let config = try #require(threadStartParams["config"] as? [String: Any])

        #expect(result.model == "gpt-5.4-mini")
        #expect(config["model_context_window"] as? Int == 272_000)
        #expect(config["model_auto_compact_token_limit"] as? Int == 244_800)
    }

    @Test func appServerReviewRunnerFallsBackWhenConfigReadIsUnavailable() async throws {
        let cwd = try makeTemporaryDirectory()
        let tempHome = try makeTemporaryDirectory()
        let appServerCodexHome = try makeTemporaryDirectory()
        let captureURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try writeCodexConfig(
            codexHomeURL: appServerCodexHome,
            content: """
            profile = "reviewer"

            [profiles.reviewer]
            model = "custom-review-model"
            model_context_window = 200_000
            model_auto_compact_token_limit = 190_000
            """
        )
        try writeModelsCache(
            codexHomeURL: appServerCodexHome,
            content: try jsonString([
                "models": [[
                    "slug": "custom-review-model",
                    "context_window": 150_000,
                ]]
            ])
        )
        let recorder = EventRecorder()
        let scriptURL = try makeFakeAppServerScript(
            mode: .configReadUnsupported,
            configuredModel: "gpt-5.4-mini",
            threadStartModel: "custom-review-model",
            captureURL: captureURL,
            initializeCodexHome: appServerCodexHome.path
        )
        defer { try? FileManager.default.removeItem(at: captureURL) }

        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                codexCommand: scriptURL.path,
                environment: ["HOME": tempHome.path]
            )
        )

        let result = try await runner.run(
            request: .init(cwd: cwd.path, target: .uncommittedChanges),
            defaultTimeoutSeconds: nil as Int?,
            onStart: { _, _ in },
            onEvent: { event in
                await recorder.record(event)
            },
            requestedTerminationReason: { nil as ReviewTerminationReason? }
        )

        let threadStartParams = try #require(loadCapturedRequest(at: captureURL, method: "thread/start")?["params"] as? [String: Any])
        let config = try #require(threadStartParams["config"] as? [String: Any])

        #expect(result.state == .succeeded)
        #expect(result.model == "custom-review-model")
        #expect(config["model_context_window"] as? Int == 150_000)
        #expect(config["model_auto_compact_token_limit"] as? Int == 135_000)
        #expect(await recorder.logTexts.contains("Falling back to local config parsing because `config/read` is unavailable."))
    }

    @Test func appServerReviewRunnerCapturesPlanReasoningToolAndCompactionLogs() async throws {
        let cwd = try makeTemporaryDirectory()
        let recorder = EventRecorder()
        let scriptURL = try makeFakeAppServerScript(mode: .richLogs)
        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                codexCommand: scriptURL.path,
                environment: try isolatedHomeEnvironment()
            )
        )

        let result = try await runner.run(
            request: .init(cwd: cwd.path, target: .uncommittedChanges),
            defaultTimeoutSeconds: nil as Int?,
            onStart: { _, _ in },
            onEvent: { event in
                await recorder.record(event)
            },
            requestedTerminationReason: { nil as ReviewTerminationReason? }
        )

        #expect(result.state == .succeeded)
        #expect(await recorder.logEntries.contains { $0.kind == .plan && $0.text.contains("- step 1") })
        #expect(await recorder.logEntries.contains { $0.kind == .reasoningSummary && $0.text.contains("thinking") })
        #expect(await recorder.logEntries.contains { $0.kind == .rawReasoning && $0.text.contains("raw chain") })
        #expect(await recorder.logEntries.contains { $0.kind == .toolCall && $0.text.contains("github.search") })
        #expect(await recorder.logEntries.contains { $0.kind == .toolCall && $0.text.contains("Fetching schema") })
        #expect(await recorder.logEntries.contains { $0.kind == .rawReasoning && $0.groupID == "rsn_1:1" && $0.text.contains("second chain") })
        #expect(await recorder.logEntries.contains { $0.kind == .event && $0.text.contains("Context compacted") })
    }

    @Test func appServerReviewRunnerPreservesIncompleteReasoningAtCompletion() async throws {
        let cwd = try makeTemporaryDirectory()
        let recorder = EventRecorder()
        let scriptURL = try makeFakeAppServerScript(mode: .partialReasoningCompletion)
        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                codexCommand: scriptURL.path,
                environment: try isolatedHomeEnvironment()
            )
        )

        let result = try await runner.run(
            request: .init(cwd: cwd.path, target: .uncommittedChanges),
            defaultTimeoutSeconds: nil as Int?,
            onStart: { _, _ in },
            onEvent: { event in
                await recorder.record(event)
            },
            requestedTerminationReason: { nil as ReviewTerminationReason? }
        )

        let rawReasoningEntries = await recorder.logEntries.filter { $0.kind == .rawReasoning }
        let rawReasoningZeroTexts = rawReasoningEntries
            .filter { $0.groupID == "rsn_1:0" }
            .map(\.text)
        #expect(result.state == .succeeded)
        #expect(await recorder.logEntries.contains { $0.kind == .reasoningSummary && $0.text.contains("carefully") })
        #expect(await recorder.logEntries.contains { $0.kind == .reasoningSummary && $0.text.contains("second summary") })
        #expect(rawReasoningEntries.contains { $0.groupID == "rsn_1:1" && $0.text.contains("second raw") })
        #expect(rawReasoningZeroTexts.last?.contains("extended") == true)
    }

    @Test func appServerReviewRunnerPreservesIncompletePlanAtCompletion() async throws {
        let cwd = try makeTemporaryDirectory()
        let recorder = EventRecorder()
        let scriptURL = try makeFakeAppServerScript(mode: .partialPlanCompletion)
        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                codexCommand: scriptURL.path,
                environment: try isolatedHomeEnvironment()
            )
        )

        let result = try await runner.run(
            request: .init(cwd: cwd.path, target: .uncommittedChanges),
            defaultTimeoutSeconds: nil as Int?,
            onStart: { _, _ in },
            onEvent: { event in
                await recorder.record(event)
            },
            requestedTerminationReason: { nil as ReviewTerminationReason? }
        )

        #expect(result.state == .succeeded)
        #expect(await recorder.logEntries.contains { $0.kind == .plan && $0.text.contains(" step 2") })
    }

    @Test func appServerReviewRunnerThrowsWhenConfigReadFailsUnexpectedly() async throws {
        let cwd = try makeTemporaryDirectory()
        let tempHome = try makeTemporaryDirectory()
        let captureURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try writeReviewLocalConfig(
            homeURL: tempHome,
            content: #"review_model = "gpt-5.4-mini""#
        )
        let scriptURL = try makeFakeAppServerScript(
            mode: .configReadFailure,
            captureURL: captureURL
        )
        defer { try? FileManager.default.removeItem(at: captureURL) }

        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                codexCommand: scriptURL.path,
                environment: ["HOME": tempHome.path]
            )
        )

        do {
            _ = try await runner.run(
                request: .init(cwd: cwd.path, target: .uncommittedChanges),
                defaultTimeoutSeconds: nil as Int?,
                onStart: { _, _ in },
                onEvent: { _ in },
                requestedTerminationReason: { nil as ReviewTerminationReason? }
            )
            Issue.record("expected bootstrap failure")
        } catch let error as ReviewBootstrapFailure {
            #expect(error.message.contains("Failed to read app-server config"))
            #expect(error.model == "gpt-5.4-mini")
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        #expect(try loadCapturedRequest(at: captureURL, method: "thread/start") == nil)
    }

    @Test func appServerReviewRunnerKeepsConfiguredModelWhenCancelledAfterConfigRead() async throws {
        let cwd = try makeTemporaryDirectory()
        let cancellation = StepCancellation(triggerOnCall: 5, reason: "Cancelled after config/read.")
        let scriptURL = try makeFakeAppServerScript(
            mode: .success,
            configuredReviewModel: "gpt-5.4-mini",
            threadStartModel: "gpt-5.4-mini"
        )
        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                codexCommand: scriptURL.path,
                environment: try isolatedHomeEnvironment()
            )
        )

        let result = try await runner.run(
            request: .init(cwd: cwd.path, target: .uncommittedChanges),
            defaultTimeoutSeconds: nil as Int?,
            onStart: { _, _ in },
            onEvent: { _ in },
            requestedTerminationReason: {
                await cancellation.reason()
            }
        )

        #expect(result.state == .cancelled)
        #expect(result.errorMessage == "Cancelled after config/read.")
        #expect(result.model == "gpt-5.4-mini")
    }

    @Test func appServerReviewRunnerKeepsBackendThreadModelWhenCancelledAfterThreadStart() async throws {
        let cwd = try makeTemporaryDirectory()
        let tempHome = try makeTemporaryDirectory()
        let cancellation = StepCancellation(triggerOnCall: 6, reason: "Cancelled after thread/start.")
        let scriptURL = try makeFakeAppServerScript(
            mode: .success,
            configuredModel: "gpt-5.4",
            configuredReviewModel: nil,
            threadStartModel: "gpt-5.3-codex"
        )
        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                codexCommand: scriptURL.path,
                environment: ["HOME": tempHome.path]
            )
        )

        let result = try await runner.run(
            request: .init(cwd: cwd.path, target: .uncommittedChanges),
            defaultTimeoutSeconds: nil as Int?,
            onStart: { _, _ in },
            onEvent: { _ in },
            requestedTerminationReason: {
                await cancellation.reason()
            }
        )

        #expect(result.state == .cancelled)
        #expect(result.errorMessage == "Cancelled after thread/start.")
        #expect(result.model == "gpt-5.3-codex")
    }

    @Test func appServerReviewRunnerKeepsResolvedModelWhenCancelledBeforeThreadStart() async throws {
        let cwd = try makeTemporaryDirectory()
        let tempHome = try makeTemporaryDirectory()
        try writeReviewLocalConfig(
            homeURL: tempHome,
            content: #"review_model = "gpt-5.4""#
        )
        let cancellation = StepCancellation(triggerOnCall: 5, reason: "Cancelled during bootstrap.")
        let scriptURL = try makeFakeAppServerScript(mode: .success)
        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                codexCommand: scriptURL.path,
                environment: ["HOME": tempHome.path]
            )
        )

        let result = try await runner.run(
            request: .init(cwd: cwd.path, target: .uncommittedChanges),
            defaultTimeoutSeconds: nil as Int?,
            onStart: { _, _ in },
            onEvent: { _ in },
            requestedTerminationReason: {
                await cancellation.reason()
            }
        )

        #expect(result.state == .cancelled)
        #expect(result.errorMessage == "Cancelled during bootstrap.")
        #expect(result.model == "gpt-5.4")
    }

    @Test func appServerReviewRunnerCancelsViaTurnInterrupt() async throws {
        let cwd = try makeTemporaryDirectory()
        let scriptURL = try makeFakeAppServerScript(mode: .longRunning)
        let recorder = EventRecorder()
        let cancellation = CancellationFlag()
        var runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                codexCommand: scriptURL.path,
                environment: try isolatedHomeEnvironment()
            )
        )
        runner.gracefulTerminationWait = .milliseconds(100)
        runner.pollInterval = .milliseconds(50)

        let task = Task {
            try await runner.run(
                request: .init(cwd: cwd.path, target: .uncommittedChanges),
                defaultTimeoutSeconds: nil as Int?,
                onStart: { _, _ in },
                onEvent: { event in
                    await recorder.record(event)
                },
                requestedTerminationReason: {
                    await cancellation.reason
                }
            )
        }

        try await waitUntil(timeout: .seconds(2), interval: .milliseconds(20)) {
            await recorder.reviewThreadID != nil
        }
        await cancellation.cancel("Cancelled from test.")

        let result = try await task.value
        #expect(result.state == .cancelled)
        #expect(result.errorMessage == "Cancelled from test.")
    }

    @Test func appServerReviewRunnerDoesNotSpawnWhenCancellationWasAlreadyRequested() async throws {
        let cwd = try makeTemporaryDirectory()
        let markerURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let scriptURL = try makeMarkerScript(markerURL: markerURL)
        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                codexCommand: scriptURL.path,
                environment: try isolatedHomeEnvironment()
            )
        )

        let result = try await runner.run(
            request: .init(cwd: cwd.path, target: .custom(instructions: "Inspect API changes")),
            defaultTimeoutSeconds: nil as Int?,
            onStart: { _, _ in
                Issue.record("should not start")
            },
            onEvent: { _ in },
            requestedTerminationReason: {
                .cancelled("Cancelled before spawn.")
            }
        )

        #expect(result.state == .cancelled)
        #expect(result.errorMessage == "Cancelled before spawn.")
        #expect(FileManager.default.fileExists(atPath: markerURL.path) == false)
    }

    @Test func appServerReviewRunnerResolvesCodexFromPATHAtSpawnTime() async throws {
        let cwd = try makeTemporaryDirectory()
        let binDirectory = cwd.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        let executableURL = try makeFakeAppServerScript(mode: .success, at: binDirectory.appendingPathComponent("codex"))

        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                codexCommand: "codex",
                environment: try isolatedHomeEnvironment(
                    extra: ["PATH": "\(binDirectory.path):/usr/bin:/bin"]
                )
            )
        )

        let result = try await runner.run(
            request: .init(cwd: cwd.path, target: .uncommittedChanges),
            defaultTimeoutSeconds: nil as Int?,
            onStart: { _, _ in },
            onEvent: { _ in },
            requestedTerminationReason: { nil as ReviewTerminationReason? }
        )

        #expect(result.state == .succeeded)
        #expect(FileManager.default.fileExists(atPath: executableURL.path))
    }

    @Test func appServerReviewRunnerFailsWithReadableErrorWhenCodexIsMissing() async throws {
        let cwd = try makeTemporaryDirectory()
        let missingCommand = "codex-missing"

        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                codexCommand: missingCommand,
                environment: try isolatedHomeEnvironment(
                    extra: ["PATH": cwd.path]
                )
            )
        )

        await #expect(throws: ReviewError.self) {
            _ = try await runner.run(
                request: .init(cwd: cwd.path, target: .uncommittedChanges),
                defaultTimeoutSeconds: nil as Int?,
                onStart: { _, _ in },
                onEvent: { _ in },
                requestedTerminationReason: { nil as ReviewTerminationReason? }
            )
        }
    }

    @Test func appServerReviewRunnerThrowsWhenBootstrapFailsBeforeReviewStarts() async throws {
        let cwd = try makeTemporaryDirectory()
        let scriptURL = try makeFakeAppServerScript(mode: .bootstrapFailureBeforeThreadStart)
        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                codexCommand: scriptURL.path,
                environment: try isolatedHomeEnvironment()
            )
        )

        await #expect(throws: ReviewBootstrapFailure.self) {
            _ = try await runner.run(
                request: .init(cwd: cwd.path, target: .uncommittedChanges),
                defaultTimeoutSeconds: nil as Int?,
                onStart: { _, _ in },
                onEvent: { _ in },
                requestedTerminationReason: { nil as ReviewTerminationReason? }
            )
        }
    }

    @Test func appServerReviewRunnerPreservesResolvedModelWhenBootstrapFailsBeforeThreadStart() async throws {
        let cwd = try makeTemporaryDirectory()
        let tempHome = try makeTemporaryDirectory()
        try writeReviewLocalConfig(
            homeURL: tempHome,
            content: #"review_model = "gpt-5.4-mini""#
        )
        let scriptURL = try makeFakeAppServerScript(mode: .bootstrapFailureBeforeThreadStart)
        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                codexCommand: scriptURL.path,
                environment: ["HOME": tempHome.path]
            )
        )

        do {
            _ = try await runner.run(
                request: .init(cwd: cwd.path, target: .uncommittedChanges),
                defaultTimeoutSeconds: nil as Int?,
                onStart: { _, _ in },
                onEvent: { _ in },
                requestedTerminationReason: { nil as ReviewTerminationReason? }
            )
            Issue.record("expected bootstrap failure")
        } catch let error as ReviewBootstrapFailure {
            #expect(error.model == "gpt-5.4-mini")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func appServerReviewRunnerReturnsFailureWhenAppServerCrashesAfterReviewStart() async throws {
        let cwd = try makeTemporaryDirectory()
        let scriptURL = try makeFakeAppServerScript(mode: .postReviewCrash)
        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                codexCommand: scriptURL.path,
                environment: try isolatedHomeEnvironment()
            )
        )

        let result = try await runner.run(
            request: .init(cwd: cwd.path, target: .uncommittedChanges),
            defaultTimeoutSeconds: nil as Int?,
            onStart: { _, _ in },
            onEvent: { _ in },
            requestedTerminationReason: { nil as ReviewTerminationReason? }
        )

        #expect(result.state == .failed)
        #expect(result.reviewThreadID == "thr-review")
    }

    @Test func appServerReviewRunnerFailsWhenExitedReviewModeIsMissing() async throws {
        let cwd = try makeTemporaryDirectory()
        let scriptURL = try makeFakeAppServerScript(mode: .missingExitedReviewMode)
        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                codexCommand: scriptURL.path,
                environment: try isolatedHomeEnvironment()
            )
        )

        let result = try await runner.run(
            request: .init(cwd: cwd.path, target: .uncommittedChanges),
            defaultTimeoutSeconds: nil as Int?,
            onStart: { _, _ in },
            onEvent: { _ in },
            requestedTerminationReason: { nil as ReviewTerminationReason? }
        )

        #expect(result.state == .failed)
        #expect(result.errorMessage == "Review completed without an `exitedReviewMode` item.")
    }

    @Test func appServerReviewRunnerWaitsForExitedReviewModeAfterTurnCompletion() async throws {
        let cwd = try makeTemporaryDirectory()
        let scriptURL = try makeFakeAppServerScript(mode: .outOfOrderTurnCompletion)
        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                codexCommand: scriptURL.path,
                environment: try isolatedHomeEnvironment()
            )
        )

        let result = try await runner.run(
            request: .init(cwd: cwd.path, target: .uncommittedChanges),
            defaultTimeoutSeconds: nil as Int?,
            onStart: { _, _ in },
            onEvent: { _ in },
            requestedTerminationReason: { nil as ReviewTerminationReason? }
        )

        #expect(result.state == .succeeded)
        #expect(result.content == "Looks solid overall.")
    }

    @Test func appServerReviewRunnerPreservesParentThreadIDWhenReviewThreadDiffers() async throws {
        let cwd = try makeTemporaryDirectory()
        let scriptURL = try makeFakeAppServerScript(mode: .detachedReviewLike)
        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                codexCommand: scriptURL.path,
                environment: try isolatedHomeEnvironment()
            )
        )

        let result = try await runner.run(
            request: .init(cwd: cwd.path, target: .uncommittedChanges),
            defaultTimeoutSeconds: nil as Int?,
            onStart: { _, _ in },
            onEvent: { _ in },
            requestedTerminationReason: { nil as ReviewTerminationReason? }
        )

        #expect(result.reviewThreadID == "thr-review")
        #expect(result.threadID == "thr-parent")
    }

    @Test func appServerReviewRunnerKeepsTurnFailureMessageWhenStderrContainsErrorWord() async throws {
        let cwd = try makeTemporaryDirectory()
        let scriptURL = try makeFakeAppServerScript(mode: .stderrNoiseAfterFailure)
        let runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                codexCommand: scriptURL.path,
                environment: try isolatedHomeEnvironment()
            )
        )

        let result = try await runner.run(
            request: .init(cwd: cwd.path, target: .uncommittedChanges),
            defaultTimeoutSeconds: nil as Int?,
            onStart: { _, _ in },
            onEvent: { _ in },
            requestedTerminationReason: { nil as ReviewTerminationReason? }
        )

        #expect(result.state == .failed)
        #expect(result.errorMessage == "turn failed")
    }

    @Test func appServerReviewRunnerReturnsBeforeReviewStartWhenCancelledDuringBootstrap() async throws {
        let cwd = try makeTemporaryDirectory()
        let markerURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let scriptURL = try makeFakeAppServerScript(mode: .slowThreadStart, markerURL: markerURL)
        defer {
            try? FileManager.default.removeItem(at: scriptURL)
            try? FileManager.default.removeItem(at: markerURL)
        }

        let cancellation = CancellationFlag()
        var runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                codexCommand: scriptURL.path,
                environment: try isolatedHomeEnvironment()
            )
        )
        runner.pollInterval = .milliseconds(50)

        let task = Task {
            try await runner.run(
                request: .init(cwd: cwd.path, target: .uncommittedChanges),
                defaultTimeoutSeconds: nil as Int?,
                onStart: { _, _ in },
                onEvent: { _ in },
                requestedTerminationReason: {
                    await cancellation.reason
                }
            )
        }

        try await Task.sleep(for: .milliseconds(100))
        await cancellation.cancel("Cancelled during bootstrap.")

        let result = try await task.value
        #expect(result.state == .cancelled)
        #expect(result.reviewThreadID == nil)
        #expect(result.errorMessage == "Cancelled during bootstrap.")
        #expect(FileManager.default.fileExists(atPath: markerURL.path) == false)
    }
}

private enum FakeAppServerMode: String {
    case success
    case richLogs
    case partialReasoningCompletion
    case partialPlanCompletion
    case longRunning
    case configReadUnsupported
    case configReadFailure
    case reviewStartFailure
    case bootstrapFailureBeforeThreadStart
    case postReviewCrash
    case missingExitedReviewMode
    case outOfOrderTurnCompletion
    case detachedReviewLike
    case stderrNoiseAfterFailure
    case slowThreadStart
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

private func makeFakeAppServerScript(
    mode: FakeAppServerMode,
    at url: URL? = nil,
    markerURL: URL? = nil,
    configuredModel: String = "gpt-5.4-mini",
    configuredReviewModel: String? = nil,
    threadStartModel: String? = nil,
    configuredContextWindow: Int? = nil,
    configuredAutoCompactTokenLimit: Int? = nil,
    captureURL: URL? = nil,
    initializeCodexHome: String? = nil
) throws -> URL {
    let destination = url ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var config: [String: Any] = ["model": configuredModel]
    if let configuredReviewModel {
        config["review_model"] = configuredReviewModel
    }
    if let configuredContextWindow {
        config["model_context_window"] = configuredContextWindow
    }
    if let configuredAutoCompactTokenLimit {
        config["model_auto_compact_token_limit"] = configuredAutoCompactTokenLimit
    }
    let configReadResult = try jsonString(["config": config])
    let resolvedThreadStartModel = threadStartModel ?? configuredReviewModel ?? configuredModel
    let capturePathLiteral = try pythonLiteral(captureURL?.path)
    let threadStartModelLiteral = try pythonLiteral(resolvedThreadStartModel)
    let initializeCodexHomeLiteral = try pythonLiteral(initializeCodexHome)
    let script = """
    #!/usr/bin/env python3
    import json
    import sys
    import time

    mode = "\(mode.rawValue)"
    thread_id = "thr-review"
    parent_thread_id = "thr-parent"
    turn_id = "turn-review"
    capture_path = \(capturePathLiteral)
    thread_start_model = \(threadStartModelLiteral)
    initialize_codex_home = \(initializeCodexHomeLiteral)
    config_read_result = json.loads(r'''\(configReadResult)''')

    def send(obj, stream=sys.stdout):
        stream.write(json.dumps(obj) + "\\n")
        stream.flush()

    def capture(obj):
        if capture_path is None:
            return
        with open(capture_path, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(obj) + "\\n")

    for raw in sys.stdin:
        if not raw.strip():
            continue
        message = json.loads(raw)
        method = message.get("method")

        if method == "initialize":
            result = {"platformFamily": "macOS", "platformOs": "Darwin"}
            if initialize_codex_home is not None:
                result["codexHome"] = initialize_codex_home
            send({"id": message["id"], "result": result})
        elif method == "initialized":
            continue
        elif method == "config/read":
            capture({"method": method, "params": message.get("params")})
            if mode == "configReadUnsupported":
                send({"id": message["id"], "error": {"code": -32601, "message": "Method not found"}})
                continue
            if mode == "configReadFailure":
                send({"id": message["id"], "error": {"code": -32001, "message": "config read failed"}})
                continue
            send({"id": message["id"], "result": config_read_result})
        elif method == "thread/start":
            capture({"method": method, "params": message.get("params")})
            if mode == "bootstrapFailureBeforeThreadStart":
                sys.stderr.write("bootstrap failed before thread/start\\n")
                sys.stderr.flush()
                sys.exit(9)
            if mode == "slowThreadStart":
                time.sleep(1)
            send({
                "id": message["id"],
                "result": {
                    "thread": {"id": parent_thread_id if mode == "detachedReviewLike" else thread_id},
                    "model": thread_start_model
                }
            })
        elif method == "review/start":
            if mode == "reviewStartFailure":
                send({"id": message["id"], "error": {"code": -32002, "message": "review start failed"}})
                continue
            if mode == "slowThreadStart":
                open("\(markerURL?.path ?? "/tmp/review-start-marker")", "w").close()
            send({
                "id": message["id"],
                "result": {
                    "turn": {"id": turn_id, "status": "inProgress", "error": None},
                    "reviewThreadId": thread_id
                }
            })
            send({"method": "turn/started", "params": {"threadId": thread_id, "turn": {"id": turn_id, "status": "inProgress", "error": None}}})
            send({"method": "item/started", "params": {"threadId": thread_id, "turnId": turn_id, "item": {"type": "enteredReviewMode", "id": turn_id, "review": "current changes"}}})

            if mode == "longRunning":
                continue

            if mode == "postReviewCrash":
                sys.stderr.write("crashed after review/start\\n")
                sys.stderr.flush()
                sys.exit(7)

            if mode == "stderrNoiseAfterFailure":
                send({"method": "turn/completed", "params": {"threadId": thread_id, "turn": {"id": turn_id, "status": "failed", "error": {"message": "turn failed"}}}})
                sys.stderr.write("0 errors found during cleanup\\n")
                sys.stderr.flush()
                time.sleep(0.2)
                sys.exit(1)

            if mode == "richLogs":
                send({"method": "item/started", "params": {"threadId": thread_id, "turnId": turn_id, "item": {"type": "mcpToolCall", "id": "tool_1", "server": "github", "tool": "search", "status": "inProgress"}}})
                send({"method": "item/mcpToolCall/progress", "params": {"threadId": thread_id, "turnId": turn_id, "itemId": "tool_1", "message": "Fetching schema"}})
                send({"method": "item/plan/delta", "params": {"threadId": thread_id, "turnId": turn_id, "itemId": "plan_1", "delta": "- step 1\\n"}})
                send({"method": "item/plan/delta", "params": {"threadId": thread_id, "turnId": turn_id, "itemId": "plan_1", "delta": "- step 2\\n"}})
                send({"method": "item/reasoning/summaryTextDelta", "params": {"threadId": thread_id, "turnId": turn_id, "itemId": "rsn_1", "delta": "thinking", "summaryIndex": 0}})
                send({"method": "item/reasoning/summaryPartAdded", "params": {"threadId": thread_id, "turnId": turn_id, "itemId": "rsn_1", "summaryIndex": 1}})
                send({"method": "item/reasoning/summaryTextDelta", "params": {"threadId": thread_id, "turnId": turn_id, "itemId": "rsn_1", "delta": " carefully", "summaryIndex": 1}})
                send({"method": "item/reasoning/textDelta", "params": {"threadId": thread_id, "turnId": turn_id, "itemId": "rsn_1", "delta": "raw chain", "contentIndex": 0}})
                send({"method": "item/reasoning/textDelta", "params": {"threadId": thread_id, "turnId": turn_id, "itemId": "rsn_1", "delta": "second chain", "contentIndex": 1}})
                send({"method": "item/completed", "params": {"threadId": thread_id, "turnId": turn_id, "item": {"type": "mcpToolCall", "id": "tool_1", "server": "github", "tool": "search", "status": "completed", "result": {"ok": True}}}})
                send({"method": "item/completed", "params": {"threadId": thread_id, "turnId": turn_id, "item": {"type": "contextCompaction", "id": "ctx_1"}}})
                send({"method": "item/completed", "params": {"threadId": thread_id, "turnId": turn_id, "item": {"type": "exitedReviewMode", "id": turn_id, "review": "Looks solid overall."}}})
                send({"method": "turn/completed", "params": {"threadId": thread_id, "turn": {"id": turn_id, "status": "completed", "error": None}}})
                time.sleep(0.2)
                sys.exit(0)

            if mode == "partialReasoningCompletion":
                send({"method": "item/reasoning/summaryTextDelta", "params": {"threadId": thread_id, "turnId": turn_id, "itemId": "rsn_1", "delta": "thinking", "summaryIndex": 0}})
                send({"method": "item/reasoning/textDelta", "params": {"threadId": thread_id, "turnId": turn_id, "itemId": "rsn_1", "delta": "raw chain", "contentIndex": 0}})
                send({"method": "item/completed", "params": {"threadId": thread_id, "turnId": turn_id, "item": {"type": "reasoning", "id": "rsn_1", "summary": ["thinking carefully", "second summary"], "content": ["raw chain extended", "second raw"]}}})
                time.sleep(0.05)
                send({"method": "item/completed", "params": {"threadId": thread_id, "turnId": turn_id, "item": {"type": "exitedReviewMode", "id": turn_id, "review": "Looks solid overall."}}})
                send({"method": "turn/completed", "params": {"threadId": thread_id, "turn": {"id": turn_id, "status": "completed", "error": None}}})
                time.sleep(0.2)
                sys.exit(0)

            if mode == "partialPlanCompletion":
                send({"method": "item/plan/delta", "params": {"threadId": thread_id, "turnId": turn_id, "itemId": "plan_1", "delta": "- step 1\\n"}})
                send({"method": "item/completed", "params": {"threadId": thread_id, "turnId": turn_id, "item": {"type": "plan", "id": "plan_1", "text": "- step 1\\n- step 2"}}})
                send({"method": "item/completed", "params": {"threadId": thread_id, "turnId": turn_id, "item": {"type": "exitedReviewMode", "id": turn_id, "review": "Looks solid overall."}}})
                send({"method": "turn/completed", "params": {"threadId": thread_id, "turn": {"id": turn_id, "status": "completed", "error": None}}})
                time.sleep(0.2)
                sys.exit(0)

            send({"method": "item/started", "params": {"threadId": thread_id, "turnId": turn_id, "item": {"type": "commandExecution", "id": "cmd_1", "command": "git diff --stat", "status": "inProgress", "aggregatedOutput": None, "exitCode": None}}})
            send({"method": "item/commandExecution/outputDelta", "params": {"threadId": thread_id, "turnId": turn_id, "itemId": "cmd_1", "delta": "README.md | 1 +"}})
            send({"method": "item/completed", "params": {"threadId": thread_id, "turnId": turn_id, "item": {"type": "commandExecution", "id": "cmd_1", "command": "git diff --stat", "status": "completed", "aggregatedOutput": "README.md | 1 +", "exitCode": 0}}})
            send({"method": "item/agentMessage/delta", "params": {"threadId": thread_id, "turnId": turn_id, "itemId": "msg_1", "delta": "Looks solid"}})
            sys.stderr.write("diagnostic: success path\\n")
            sys.stderr.flush()

            if mode == "outOfOrderTurnCompletion":
                send({"method": "turn/completed", "params": {"threadId": thread_id, "turn": {"id": turn_id, "status": "completed", "error": None}}})
                time.sleep(0.05)
                send({"method": "item/completed", "params": {"threadId": thread_id, "turnId": turn_id, "item": {"type": "exitedReviewMode", "id": turn_id, "review": "Looks solid overall."}}})
                time.sleep(0.5)
                sys.exit(0)

            if mode != "missingExitedReviewMode":
                send({"method": "item/completed", "params": {"threadId": thread_id, "turnId": turn_id, "item": {"type": "exitedReviewMode", "id": turn_id, "review": "Looks solid overall."}}})

            send({"method": "turn/completed", "params": {"threadId": thread_id, "turn": {"id": turn_id, "status": "completed", "error": None}}})
            time.sleep(0.5)
            sys.exit(0)
        elif method == "turn/interrupt":
            send({"id": message["id"], "result": {}})
            send({"method": "turn/completed", "params": {"threadId": thread_id, "turn": {"id": turn_id, "status": "interrupted", "error": {"message": "Cancelled from test."}}}})
            time.sleep(0.2)
            sys.exit(0)
    """.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"

    try script.write(to: destination, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
    return destination
}

private func jsonString(_ object: Any) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object, options: [])
    guard let encoded = String(data: data, encoding: .utf8) else {
        throw CocoaError(.fileReadInapplicableStringEncoding)
    }
    return encoded
}

private func pythonLiteral(_ value: String?) throws -> String {
    guard let value else {
        return "None"
    }
    let escaped = value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
    return "\"\(escaped)\""
}

private func loadCapturedRequest(at url: URL, method: String) throws -> [String: Any]? {
    guard let data = try? Data(contentsOf: url),
          let text = String(data: data, encoding: .utf8)
    else {
        return nil
    }
    for line in text.split(whereSeparator: \.isNewline) {
        guard let lineData = line.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              object["method"] as? String == method
        else {
            continue
        }
        return object
    }
    return nil
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

private func writeCodexConfig(codexHomeURL: URL, content: String) throws {
    try FileManager.default.createDirectory(at: codexHomeURL, withIntermediateDirectories: true)
    try content.write(
        to: codexHomeURL.appendingPathComponent("config.toml"),
        atomically: true,
        encoding: .utf8
    )
}

private func writeModelsCache(codexHomeURL: URL, content: String) throws {
    try FileManager.default.createDirectory(at: codexHomeURL, withIntermediateDirectories: true)
    try content.write(
        to: codexHomeURL.appendingPathComponent("models_cache.json"),
        atomically: true,
        encoding: .utf8
    )
}

private func makeMarkerScript(markerURL: URL) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try """
    #!/bin/zsh
    touch "\(markerURL.path)"
    exit 0
    """.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

private actor EventRecorder {
    private(set) var reviewThreadID: String?
    private(set) var reviewModel: String?
    private(set) var rawLines: [String] = []
    private(set) var logEntries: [ReviewLogEntry] = []
    private(set) var logTexts: [String] = []
    private(set) var agentMessages: [String] = []

    func record(_ event: ReviewProcessEvent) {
        switch event {
        case .reviewStarted(let reviewThreadID, _, _, let model):
            self.reviewThreadID = reviewThreadID
            self.reviewModel = model
        case .rawLine(let line):
            rawLines.append(line)
        case .logEntry(let entry):
            logEntries.append(entry)
            logTexts.append(entry.text)
        case .agentMessage(let message):
            agentMessages.append(message)
        case .progress, .failed:
            break
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

private actor StepCancellation {
    private let triggerOnCall: Int
    private let text: String
    private var callCount = 0

    init(triggerOnCall: Int, reason: String) {
        self.triggerOnCall = triggerOnCall
        self.text = reason
    }

    func reason() -> ReviewTerminationReason? {
        callCount += 1
        guard callCount >= triggerOnCall else {
            return nil
        }
        return .cancelled(text)
    }
}

private func waitUntil(
    timeout: Duration,
    interval: Duration,
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() {
            return
        }
        try await Task.sleep(for: interval)
    }
    throw TimeoutError()
}

private struct TimeoutError: Error {}
