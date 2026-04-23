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
struct CodexReviewMCPSettingsTests {
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
        let store = makeInjectedAuthSessionStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: manager,
            authSessionFactory: {
                SignedOutReviewAuthSession()
            }
        )

        try await withAsyncCleanup {
            await store.start()

            #expect(store.serverState == .running)
            let discovery = try #require(ReviewDiscovery.read(from: discoveryFileURL))
            let persistedRuntimeState = try #require(ReviewRuntimeStateStore.read(from: runtimeStateFileURL))
            #expect(persistedRuntimeState.serverPID == discovery.pid)
            #expect(persistedRuntimeState.serverStartTime == discovery.serverStartTime)
            #expect(persistedRuntimeState.appServerPID == runtimeState.pid)
            #expect(FileManager.default.fileExists(atPath: reviewConfigURL.path))
            #expect(FileManager.default.fileExists(atPath: reviewAgentsURL.path))
        } cleanup: {
            await store.stop()
        }
    }

    @Test func initialSettingsSnapshotUsesEffectiveFallbackModelWhenReviewModelIsUnset() throws {
        let environment = try isolatedHomeEnvironment()
        let configURL = ReviewHomePaths.reviewConfigURL(environment: environment)
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        profile = "reviewer"

        [profiles.reviewer]
        model = "gpt-5.4-mini"
        model_reasoning_effort = "high"
        service_tier = "flex"
        """.write(
            to: configURL,
            atomically: true,
            encoding: .utf8
        )

        let store = makeTestStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: MockAppServerManager { _ in .success() }
        )

        #expect(store.settings.selectedModel == nil)
        #expect(store.settings.effectiveModel == "gpt-5.4-mini")
        #expect(store.settings.selectedReasoningEffort == .high)
        #expect(store.settings.selectedServiceTier == .flex)
    }

    @Test func refreshSettingsPagesThroughEntireModelCatalog() async throws {
        let transport = SettingsRefreshTransport(
            config: .init(
                model: "gpt-5.4",
                reviewModel: "gpt-5.4-mini"
            ),
            firstPage: .init(
                data: [
                    .init(
                        id: "gpt-5.4",
                        model: "gpt-5.4",
                        displayName: "GPT-5.4",
                        hidden: false,
                        supportedReasoningEfforts: [
                            .init(reasoningEffort: .medium, description: "Balanced default.")
                        ],
                        defaultReasoningEffort: .medium,
                        supportedServiceTiers: [.fast]
                    )
                ],
                nextCursor: "page-2"
            ),
            secondPage: .init(
                data: [
                    .init(
                        id: "gpt-5.4-mini",
                        model: "gpt-5.4-mini",
                        displayName: "GPT-5.4 Mini",
                        hidden: false,
                        supportedReasoningEfforts: [
                            .init(reasoningEffort: .low, description: "Quick pass."),
                            .init(reasoningEffort: .medium, description: "Balanced default.")
                        ],
                        defaultReasoningEffort: .medium,
                        supportedServiceTiers: []
                    )
                ],
                nextCursor: nil
            )
        )
        let store = makeTestStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: try isolatedHomeEnvironment()
            ),
            appServerManager: AuthCapableAppServerManager(authTransport: transport)
        )

        await store.refreshSettings()

        #expect(store.settings.selectedModel == "gpt-5.4-mini")
        #expect(store.settings.fallbackModel == "gpt-5.4")
        #expect(store.settings.displayedModels.map(\.model) == ["gpt-5.4", "gpt-5.4-mini"])
        #expect(await transport.requestedModelListCursors() == [nil, "page-2"])
    }

    @Test func refreshSettingsMergesFallbackConfigWhenConfigReadOmitsOverrides() async throws {
        let environment = try isolatedHomeEnvironment()
        let configURL = ReviewHomePaths.reviewConfigURL(environment: environment)
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        profile = "reviewer"

        [profiles.reviewer]
        review_model = "gpt-5.4-mini"
        model_reasoning_effort = "high"
        service_tier = "flex"
        """.write(
            to: configURL,
            atomically: true,
            encoding: .utf8
        )
        let transport = SettingsRefreshTransport(
            config: .init(model: "gpt-5.4"),
            firstPage: .init(data: [], nextCursor: nil),
            secondPage: .init(data: [], nextCursor: nil)
        )
        let store = makeTestStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: AuthCapableAppServerManager(authTransport: transport)
        )

        await store.refreshSettings()

        #expect(store.settings.selectedModel == "gpt-5.4-mini")
        #expect(store.settings.fallbackModel == "gpt-5.4")
        #expect(store.settings.selectedReasoningEffort == .high)
        #expect(store.settings.selectedServiceTier == .flex)
    }

    @Test func refreshSettingsPrefersReviewLocalModelOverrideOverProfileModel() async throws {
        let environment = try isolatedHomeEnvironment()
        let configURL = ReviewHomePaths.reviewConfigURL(environment: environment)
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        review_model = "gpt-5.4-mini"
        profile = "reviewer"

        [profiles.reviewer]
        model = "gpt-5.4"
        """.write(
            to: configURL,
            atomically: true,
            encoding: .utf8
        )
        let transport = SettingsRefreshTransport(
            config: .init(model: "gpt-5.4"),
            firstPage: .init(data: [], nextCursor: nil),
            secondPage: .init(data: [], nextCursor: nil)
        )
        let store = makeTestStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: AuthCapableAppServerManager(authTransport: transport)
        )

        await store.refreshSettings()

        #expect(store.settings.selectedModel == "gpt-5.4-mini")
        #expect(store.settings.fallbackModel == "gpt-5.4")
    }

    @Test func standaloneSettingsWritesTargetActiveProfileWhenRootOverrideIsAbsent() async throws {
        let environment = try isolatedHomeEnvironment()
        let configURL = ReviewHomePaths.reviewConfigURL(environment: environment)
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        profile = "reviewer"

        [profiles.reviewer]
        model = "gpt-5.3-codex"
        model_reasoning_effort = "low"
        service_tier = "flex"
        """.write(
            to: configURL,
            atomically: true,
            encoding: .utf8
        )
        let transport = SettingsWriteTransport()
        let store = makeTestStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: AuthCapableAppServerManager(authTransport: transport)
        )

        await store.updateSettingsReasoningEffort(.high)
        await store.updateSettingsServiceTier(.fast)

        #expect(await transport.recordedEditKeyPaths() == [
            ["profiles.reviewer.model_reasoning_effort"],
            ["profiles.reviewer.service_tier"],
        ])
    }

    @Test func standaloneSettingsWritesModelOverrideToRootWhenRootOverrideExists() async throws {
        let environment = try isolatedHomeEnvironment()
        let configURL = ReviewHomePaths.reviewConfigURL(environment: environment)
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        review_model = "gpt-5.4"
        profile = "reviewer"

        [profiles.reviewer]
        model = "gpt-5.3-codex"
        """.write(
            to: configURL,
            atomically: true,
            encoding: .utf8
        )
        let transport = SettingsWriteTransport()
        let store = makeTestStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: AuthCapableAppServerManager(authTransport: transport)
        )
        let gpt54 = CodexReviewModelCatalogItem(
            id: "gpt-5.4",
            model: "gpt-5.4",
            displayName: "GPT-5.4",
            hidden: false,
            supportedReasoningEfforts: [
                .init(reasoningEffort: .medium, description: "Balanced default."),
            ],
            defaultReasoningEffort: .medium,
            supportedServiceTiers: [.fast]
        )
        let gpt54Mini = CodexReviewModelCatalogItem(
            id: "gpt-5.4-mini",
            model: "gpt-5.4-mini",
            displayName: "GPT-5.4 Mini",
            hidden: false,
            supportedReasoningEfforts: [
                .init(reasoningEffort: .low, description: "Quick pass."),
                .init(reasoningEffort: .medium, description: "Balanced default."),
            ],
            defaultReasoningEffort: .medium,
            supportedServiceTiers: []
        )
        store.settings.loadForTesting(
            snapshot: .init(
                model: "gpt-5.4",
                fallbackModel: nil,
                reasoningEffort: nil,
                serviceTier: nil,
                models: [gpt54, gpt54Mini]
            )
        )

        await store.updateSettingsModel("gpt-5.4-mini")

        #expect(await transport.recordedEditKeyPaths() == [
            ["review_model"],
        ])
    }

    @Test func standaloneSettingsWritesModelOverrideToProfileWhenProfileClearsRootOverride() async throws {
        let environment = try isolatedHomeEnvironment()
        let configURL = ReviewHomePaths.reviewConfigURL(environment: environment)
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        review_model = "gpt-5.4"
        profile = "reviewer"

        [profiles.reviewer]
        review_model = null
        """.write(
            to: configURL,
            atomically: true,
            encoding: .utf8
        )
        let transport = SettingsWriteTransport()
        let store = makeTestStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: AuthCapableAppServerManager(authTransport: transport)
        )
        let gpt54 = CodexReviewModelCatalogItem(
            id: "gpt-5.4",
            model: "gpt-5.4",
            displayName: "GPT-5.4",
            hidden: false,
            supportedReasoningEfforts: [
                .init(reasoningEffort: .medium, description: "Balanced default."),
            ],
            defaultReasoningEffort: .medium,
            supportedServiceTiers: [.fast]
        )
        let gpt54Mini = CodexReviewModelCatalogItem(
            id: "gpt-5.4-mini",
            model: "gpt-5.4-mini",
            displayName: "GPT-5.4 Mini",
            hidden: false,
            supportedReasoningEfforts: [
                .init(reasoningEffort: .low, description: "Quick pass."),
                .init(reasoningEffort: .medium, description: "Balanced default."),
            ],
            defaultReasoningEffort: .medium,
            supportedServiceTiers: []
        )
        store.settings.loadForTesting(
            snapshot: .init(
                model: nil,
                fallbackModel: "gpt-5.4",
                reasoningEffort: nil,
                serviceTier: nil,
                models: [gpt54, gpt54Mini]
            )
        )

        await store.updateSettingsModel("gpt-5.4-mini")

        #expect(await transport.recordedEditKeyPaths() == [
            ["profiles.reviewer.review_model"],
        ])
    }

    @Test func standaloneSettingsWritesReasoningOverrideToRootWhenRootOverrideExists() async throws {
        let environment = try isolatedHomeEnvironment()
        let configURL = ReviewHomePaths.reviewConfigURL(environment: environment)
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        model_reasoning_effort = "high"
        profile = "reviewer"

        [profiles.reviewer]
        model = "gpt-5.4"
        """.write(
            to: configURL,
            atomically: true,
            encoding: .utf8
        )
        let transport = SettingsWriteTransport()
        let store = makeTestStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: AuthCapableAppServerManager(authTransport: transport)
        )
        store.settings.loadForTesting(
            snapshot: .init(
                model: nil,
                fallbackModel: "gpt-5.4",
                reasoningEffort: .high,
                serviceTier: nil,
                models: []
            )
        )

        await store.updateSettingsReasoningEffort(.low)

        #expect(await transport.recordedEditKeyPaths() == [
            ["model_reasoning_effort"],
        ])
    }

    @Test func standaloneSettingsWritesReasoningOverrideToProfileWhenProfileClearsRootOverride() async throws {
        let environment = try isolatedHomeEnvironment()
        let configURL = ReviewHomePaths.reviewConfigURL(environment: environment)
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        model_reasoning_effort = "high"
        profile = "reviewer"

        [profiles.reviewer]
        model_reasoning_effort = null
        """.write(
            to: configURL,
            atomically: true,
            encoding: .utf8
        )
        let transport = SettingsWriteTransport()
        let store = makeTestStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: AuthCapableAppServerManager(authTransport: transport)
        )
        store.settings.loadForTesting(
            snapshot: .init(
                model: nil,
                fallbackModel: "gpt-5.4",
                reasoningEffort: nil,
                serviceTier: nil,
                models: []
            )
        )

        await store.updateSettingsReasoningEffort(.low)

        #expect(await transport.recordedEditKeyPaths() == [
            ["profiles.reviewer.model_reasoning_effort"],
        ])
    }

    @Test func standaloneSettingsWritesModelOverrideToRootWhenRootNullClearExists() async throws {
        let environment = try isolatedHomeEnvironment()
        let configURL = ReviewHomePaths.reviewConfigURL(environment: environment)
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        review_model = null
        profile = "reviewer"
        """.write(
            to: configURL,
            atomically: true,
            encoding: .utf8
        )
        let transport = SettingsWriteTransport()
        let store = makeTestStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: AuthCapableAppServerManager(authTransport: transport)
        )
        let gpt54 = CodexReviewModelCatalogItem(
            id: "gpt-5.4",
            model: "gpt-5.4",
            displayName: "GPT-5.4",
            hidden: false,
            supportedReasoningEfforts: [
                .init(reasoningEffort: .medium, description: "Balanced default."),
            ],
            defaultReasoningEffort: .medium,
            supportedServiceTiers: [.fast]
        )
        let gpt54Mini = CodexReviewModelCatalogItem(
            id: "gpt-5.4-mini",
            model: "gpt-5.4-mini",
            displayName: "GPT-5.4 Mini",
            hidden: false,
            supportedReasoningEfforts: [
                .init(reasoningEffort: .low, description: "Quick pass."),
                .init(reasoningEffort: .medium, description: "Balanced default."),
            ],
            defaultReasoningEffort: .medium,
            supportedServiceTiers: []
        )
        store.settings.loadForTesting(
            snapshot: .init(
                model: nil,
                fallbackModel: "gpt-5.4",
                reasoningEffort: nil,
                serviceTier: nil,
                models: [gpt54, gpt54Mini]
            )
        )

        await store.updateSettingsModel("gpt-5.4-mini")

        #expect(await transport.recordedEditKeyPaths() == [
            ["review_model"],
        ])
    }

    @Test func standaloneSettingsWritesReasoningOverrideToRootWhenRootNullClearExists() async throws {
        let environment = try isolatedHomeEnvironment()
        let configURL = ReviewHomePaths.reviewConfigURL(environment: environment)
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        model_reasoning_effort = null
        profile = "reviewer"
        """.write(
            to: configURL,
            atomically: true,
            encoding: .utf8
        )
        let transport = SettingsWriteTransport()
        let store = makeTestStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: AuthCapableAppServerManager(authTransport: transport)
        )
        store.settings.loadForTesting(
            snapshot: .init(
                model: nil,
                fallbackModel: "gpt-5.4",
                reasoningEffort: nil,
                serviceTier: nil,
                models: []
            )
        )

        await store.updateSettingsReasoningEffort(.low)

        #expect(await transport.recordedEditKeyPaths() == [
            ["model_reasoning_effort"],
        ])
    }

    @Test func standaloneSettingsWritesTargetQuotedDottedActiveProfile() async throws {
        let environment = try isolatedHomeEnvironment()
        let configURL = ReviewHomePaths.reviewConfigURL(environment: environment)
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        profile = "qa.us"

        [profiles."qa.us"]
        model = "gpt-5.3-codex"
        service_tier = "flex"
        """.write(
            to: configURL,
            atomically: true,
            encoding: .utf8
        )
        let transport = SettingsWriteTransport()
        let store = makeTestStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: AuthCapableAppServerManager(authTransport: transport)
        )

        await store.updateSettingsServiceTier(.fast)

        #expect(await transport.recordedEditKeyPaths() == [
            [#"profiles."qa.us".service_tier"#],
        ])
    }

    @Test func standaloneSettingsWritesTargetActiveProfileBeforeTrackedKeysExist() async throws {
        let environment = try isolatedHomeEnvironment()
        let configURL = ReviewHomePaths.reviewConfigURL(environment: environment)
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        profile = "reviewer"

        [profiles.reviewer]
        sandbox_mode = "danger-full-access"
        """.write(
            to: configURL,
            atomically: true,
            encoding: .utf8
        )
        let transport = SettingsWriteTransport()
        let store = makeTestStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: AuthCapableAppServerManager(authTransport: transport)
        )

        await store.updateSettingsReasoningEffort(.high)

        #expect(await transport.recordedEditKeyPaths() == [
            ["profiles.reviewer.model_reasoning_effort"],
        ])
    }

    @Test func standaloneSettingsWritesTargetActiveProfileWhenSectionIsMissing() async throws {
        let environment = try isolatedHomeEnvironment()
        let configURL = ReviewHomePaths.reviewConfigURL(environment: environment)
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        profile = "reviewer"
        """.write(
            to: configURL,
            atomically: true,
            encoding: .utf8
        )
        let transport = SettingsWriteTransport()
        let store = makeTestStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: AuthCapableAppServerManager(authTransport: transport)
        )

        await store.updateSettingsReasoningEffort(.high)

        #expect(await transport.recordedEditKeyPaths() == [
            ["profiles.reviewer.model_reasoning_effort"],
        ])
    }

    @Test func standaloneSettingsClearsRootOverrideAtRootWhenRootOverrideExists() async throws {
        let environment = try isolatedHomeEnvironment()
        let configURL = ReviewHomePaths.reviewConfigURL(environment: environment)
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        review_model = "gpt-5.4-mini"
        profile = "reviewer"

        [profiles.reviewer]
        model = "gpt-5.4"
        """.write(
            to: configURL,
            atomically: true,
            encoding: .utf8
        )
        let transport = SettingsWriteTransport()
        let store = makeTestStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: AuthCapableAppServerManager(authTransport: transport)
        )

        await store.clearSettingsModelOverride()
        try await waitForMainActorCondition {
            store.settings.selectedModel == nil
        }
        try await waitForSettingsWriteCount(transport, expectedCount: 1)

        let firstWrite = try #require(await transport.recordedEditKeyPaths().first)
        #expect(firstWrite.first == "review_model")
    }

    @Test func profileModelChangeClearsInheritedRootTierAtRoot() async throws {
        let environment = try isolatedHomeEnvironment()
        let configURL = ReviewHomePaths.reviewConfigURL(environment: environment)
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        service_tier = "fast"
        profile = "reviewer"

        [profiles.reviewer]
        model = "gpt-5.3-codex"
        """.write(
            to: configURL,
            atomically: true,
            encoding: .utf8
        )
        let transport = SettingsWriteTransport()
        let store = makeTestStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: AuthCapableAppServerManager(authTransport: transport)
        )
        let gpt54Mini = CodexReviewModelCatalogItem(
            id: "gpt-5.4-mini",
            model: "gpt-5.4-mini",
            displayName: "GPT-5.4 Mini",
            hidden: false,
            supportedReasoningEfforts: [
                .init(reasoningEffort: .low, description: "Quick pass."),
                .init(reasoningEffort: .medium, description: "Balanced default."),
            ],
            defaultReasoningEffort: .medium,
            supportedServiceTiers: []
        )
        let gpt53Codex = CodexReviewModelCatalogItem(
            id: "gpt-5.3-codex",
            model: "gpt-5.3-codex",
            displayName: "GPT-5.3 Codex",
            hidden: false,
            supportedReasoningEfforts: [
                .init(reasoningEffort: .minimal, description: "Lowest overhead."),
                .init(reasoningEffort: .low, description: "Faster iteration."),
                .init(reasoningEffort: .medium, description: "Balanced default."),
            ],
            defaultReasoningEffort: .medium,
            supportedServiceTiers: [.fast, .flex]
        )
        store.settings.loadForTesting(
            snapshot: .init(
                model: nil,
                fallbackModel: "gpt-5.3-codex",
                reasoningEffort: nil,
                serviceTier: .fast,
                models: [gpt53Codex, gpt54Mini]
            )
        )

        await store.updateSettingsModel("gpt-5.4-mini")

        let firstWrite = try #require(await transport.recordedEditKeyPaths().first)
        #expect(firstWrite.contains("service_tier"))
        #expect(firstWrite.contains("profiles.reviewer.service_tier") == false)
    }

    @Test func standaloneSettingsClearsInheritedRootTierAtRoot() async throws {
        let environment = try isolatedHomeEnvironment()
        let configURL = ReviewHomePaths.reviewConfigURL(environment: environment)
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        service_tier = "fast"
        profile = "reviewer"
        """.write(
            to: configURL,
            atomically: true,
            encoding: .utf8
        )
        let transport = SettingsWriteTransport()
        let store = makeTestStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: AuthCapableAppServerManager(authTransport: transport)
        )
        store.settings.loadForTesting(
            snapshot: .init(
                model: nil,
                fallbackModel: "gpt-5.4",
                reasoningEffort: nil,
                serviceTier: .fast,
                models: []
            )
        )

        await store.updateSettingsServiceTier(nil)

        #expect(await transport.recordedEditKeyPaths() == [
            ["service_tier"],
        ])
    }

    @Test func standaloneSettingsUpdatesInheritedRootTierAtRoot() async throws {
        let environment = try isolatedHomeEnvironment()
        let configURL = ReviewHomePaths.reviewConfigURL(environment: environment)
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        service_tier = "fast"
        profile = "reviewer"
        """.write(
            to: configURL,
            atomically: true,
            encoding: .utf8
        )
        let transport = SettingsWriteTransport()
        let store = makeTestStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: AuthCapableAppServerManager(authTransport: transport)
        )
        store.settings.loadForTesting(
            snapshot: .init(
                model: nil,
                fallbackModel: "gpt-5.4",
                reasoningEffort: nil,
                serviceTier: .fast,
                models: []
            )
        )

        await store.updateSettingsServiceTier(.flex)

        #expect(await transport.recordedEditKeyPaths() == [
            ["service_tier"],
        ])
    }

    @Test func standaloneSettingsUpdatesRootNullClearedTierAtRoot() async throws {
        let environment = try isolatedHomeEnvironment()
        let configURL = ReviewHomePaths.reviewConfigURL(environment: environment)
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        service_tier = null
        profile = "reviewer"
        """.write(
            to: configURL,
            atomically: true,
            encoding: .utf8
        )
        let transport = SettingsWriteTransport()
        let store = makeTestStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: AuthCapableAppServerManager(authTransport: transport)
        )
        store.settings.loadForTesting(
            snapshot: .init(
                model: nil,
                fallbackModel: "gpt-5.4",
                reasoningEffort: nil,
                serviceTier: nil,
                models: []
            )
        )

        await store.updateSettingsServiceTier(.flex)

        #expect(await transport.recordedEditKeyPaths() == [
            ["service_tier"],
        ])
    }

    @Test func standaloneSettingsClearsProfileTierToNormalAtProfileWhenRootTierExists() async throws {
        let environment = try isolatedHomeEnvironment()
        let configURL = ReviewHomePaths.reviewConfigURL(environment: environment)
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        service_tier = "fast"
        profile = "reviewer"

        [profiles.reviewer]
        service_tier = "flex"
        """.write(
            to: configURL,
            atomically: true,
            encoding: .utf8
        )
        let transport = SettingsWriteTransport()
        let store = makeTestStore(
            configuration: .init(
                port: 0,
                codexCommand: "codex",
                environment: environment
            ),
            appServerManager: AuthCapableAppServerManager(authTransport: transport)
        )
        store.settings.loadForTesting(
            snapshot: .init(
                model: nil,
                fallbackModel: "gpt-5.4",
                reasoningEffort: nil,
                serviceTier: .flex,
                models: []
            )
        )

        await store.updateSettingsServiceTier(nil)

        #expect(await transport.recordedEditKeyPaths() == [
            ["profiles.reviewer.service_tier"],
        ])
    }

}
