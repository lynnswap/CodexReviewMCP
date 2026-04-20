import Foundation
import Testing
@testable import CodexReviewModel
@testable import ReviewCore
@testable import ReviewJobs

@Suite struct ReviewExecutionSettingsBuilderTests {
    @Test func reviewExecutionSettingsBuilderReturnsRawRequestAndFixedOverrides() throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let builder = ReviewExecutionSettingsBuilder(
            codexCommand: "codex",
            environment: ["HOME": tempDirectory.path]
        )
        let settings = try builder.build(
            request: .init(
                cwd: tempDirectory.path,
                target: .uncommittedChanges
            )
        )

        #expect(settings.command.executable == "codex")
        #expect(settings.command.arguments == ["app-server", "--listen", "stdio://"])
        #expect(settings.command.currentDirectory == tempDirectory.path)
        #expect(settings.request.cwd == tempDirectory.path)
        #expect(settings.request.target == .uncommittedChanges)
        #expect(settings.overrides == .reviewRunner)
    }

    @Test func reviewExecutionSettingsBuilderDoesNotInjectThreadStartModelOrReasoningWhenModelIsUnspecified() {
        let config = makeReviewThreadStartConfig(
            reviewSpecificModel: nil,
            localConfig: .init(),
            resolvedConfig: .init(
                model: "gpt-5.4-mini",
                reviewModel: nil,
                modelContextWindow: 999_999,
                modelAutoCompactTokenLimit: 999_999
            ),
            clampModel: "gpt-5.4-mini",
            environment: [:]
        )

        #expect(config?["review_model"] == nil)
        #expect(config?["hide_agent_reasoning"] == nil)
        #expect(config?["model_reasoning_effort"] == nil)
        #expect(config?["model_reasoning_summary"] == nil)
        #expect(config?["model_context_window"] == .int(272_000))
        #expect(config?["model_auto_compact_token_limit"] == .int(244_800))
    }

    @Test func reviewExecutionSettingsBuilderUsesReviewSpecificModelWhenProvided() {
        let config = makeReviewThreadStartConfig(
            reviewSpecificModel: "gpt-5.4",
            localConfig: .init(),
            resolvedConfig: .init(),
            clampModel: "gpt-5.4",
            environment: [:]
        )

        #expect(config == ["review_model": .string("gpt-5.4")])
    }

    @Test func reviewExecutionSettingsBuilderPreservesResolvedNumericLimitsWhenReviewModelIsSpecified() {
        let config = makeReviewThreadStartConfig(
            reviewSpecificModel: "custom-review-model",
            localConfig: .init(),
            resolvedConfig: .init(
                model: nil,
                reviewModel: nil,
                modelContextWindow: 120_000,
                modelAutoCompactTokenLimit: 110_000
            ),
            clampModel: "custom-review-model",
            environment: [:]
        )

        #expect(config?["review_model"] == .string("custom-review-model"))
        #expect(config?["model_context_window"] == .int(120_000))
        #expect(config?["model_auto_compact_token_limit"] == .int(110_000))
    }

    @Test func reviewExecutionSettingsBuilderPrefersResolvedReasoningAndLocalLimits() {
        let config = makeReviewThreadStartConfig(
            reviewSpecificModel: "custom-review-model",
            localConfig: .init(
                modelReasoningEffort: "high",
                modelContextWindow: 120_000,
                modelAutoCompactTokenLimit: 110_000
            ),
            resolvedConfig: .init(
                modelReasoningEffort: .low,
                modelContextWindow: 999_999,
                modelAutoCompactTokenLimit: 888_888
            ),
            clampModel: "custom-review-model",
            environment: [:]
        )

        #expect(config?["model_reasoning_effort"] == .string("low"))
        #expect(config?["model_context_window"] == .int(120_000))
        #expect(config?["model_auto_compact_token_limit"] == .int(110_000))
    }

    @Test func reviewExecutionSettingsBuilderHonorsProfileReasoningClearOverRootOverride() throws {
        let tempHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let codexDirectory = tempHome.appendingPathComponent(".codex_review", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        try """
        profile = "reviewer"

        [profiles.reviewer]
        model_reasoning_effort = null
        """.write(
            to: codexDirectory.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )

        let config = makeReviewThreadStartConfig(
            reviewSpecificModel: nil,
            localConfig: .init(modelReasoningEffort: "high"),
            resolvedConfig: .init(modelReasoningEffort: nil),
            clampModel: nil,
            environment: ["HOME": tempHome.path]
        )

        #expect(config?["model_reasoning_effort"] == nil)
    }

    @Test func reviewExecutionSettingsBuilderHonorsProfileServiceTierClearOverRootFallback() throws {
        let tempHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let codexDirectory = tempHome.appendingPathComponent(".codex_review", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        try """
        profile = "reviewer"

        [profiles.reviewer]
        service_tier = null
        """.write(
            to: codexDirectory.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )

        let config = makeReviewThreadStartConfig(
            reviewSpecificModel: nil,
            localConfig: .init(serviceTier: "fast"),
            resolvedConfig: .init(serviceTier: nil),
            clampModel: nil,
            environment: ["HOME": tempHome.path]
        )

        #expect(config?["service_tier"] == nil)
    }

    @Test func reviewExecutionSettingsBuilderKeepsReasoningOverrideButOmitsNumericLimitsWithoutModel() {
        let config = makeReviewThreadStartConfig(
            reviewSpecificModel: nil,
            localConfig: .init(
                reviewModel: nil,
                modelReasoningEffort: "high",
                modelContextWindow: 100_000,
                modelAutoCompactTokenLimit: 90_000
            ),
            resolvedConfig: .init(),
            clampModel: nil,
            environment: [:]
        )

        #expect(config?["review_model"] == nil)
        #expect(config?["model_reasoning_effort"] == .string("high"))
        #expect(config?["model_context_window"] == nil)
        #expect(config?["model_auto_compact_token_limit"] == nil)
    }

    @Test func reviewExecutionSettingsBuilderPrefersResolvedServiceTierOverride() {
        let config = makeReviewThreadStartConfig(
            reviewSpecificModel: nil,
            localConfig: .init(serviceTier: "fast"),
            resolvedConfig: .init(serviceTier: .flex),
            clampModel: nil,
            environment: [:]
        )

        #expect(config?["service_tier"] == .string("flex"))
    }

    @Test func reviewExecutionSettingsBuilderOmitsNumericLimitsWhenModelIsUnknown() {
        let config = makeReviewThreadStartConfig(
            reviewSpecificModel: nil,
            localConfig: .init(),
            resolvedConfig: .init(
                model: nil,
                reviewModel: nil,
                modelContextWindow: 120_000,
                modelAutoCompactTokenLimit: 110_000
            ),
            clampModel: nil,
            environment: [:]
        )

        #expect(config?["model_context_window"] == nil)
        #expect(config?["model_auto_compact_token_limit"] == nil)
    }

    @Test func resolveInitialReviewModelPrefersLocalThenFallbackConfig() throws {
        let tempHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let reviewDirectory = tempHome.appendingPathComponent(".codex_review", isDirectory: true)
        let codexDirectory = tempHome.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: reviewDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        try #"review_model = "gpt-5.4-mini""#.write(
            to: reviewDirectory.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
        try #"review_model = "gpt-5.4""#.write(
            to: codexDirectory.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )

        let localResolved = resolveInitialReviewModel(environment: ["HOME": tempHome.path])
        try FileManager.default.removeItem(at: reviewDirectory.appendingPathComponent("config.toml"))
        let fallbackResolved = resolveInitialReviewModel(environment: ["HOME": tempHome.path])

        #expect(localResolved == "gpt-5.4-mini")
        #expect(fallbackResolved == nil)
    }

    @Test func resolveDisplayedSettingsOverridesPrefersResolvedValues() {
        let overrides = resolveDisplayedSettingsOverrides(
            localConfig: .init(
                modelReasoningEffort: "high",
                serviceTier: "fast"
            ),
            resolvedConfig: .init(
                modelReasoningEffort: .low,
                serviceTier: .flex
            )
        )

        #expect(overrides.reasoningEffort == .low)
        #expect(overrides.serviceTier == .flex)
    }

    @Test func resolveDisplayedSettingsOverridesHonorsProfileReasoningClear() {
        let overrides = resolveDisplayedSettingsOverrides(
            localConfig: .init(modelReasoningEffort: "high"),
            resolvedConfig: .init(modelReasoningEffort: nil),
            profileClearsReasoningEffort: true
        )

        #expect(overrides.reasoningEffort == nil)
    }

    @Test func resolveDisplayedSettingsOverridesHonorsProfileServiceTierClear() {
        let overrides = resolveDisplayedSettingsOverrides(
            localConfig: .init(serviceTier: "fast"),
            resolvedConfig: .init(serviceTier: nil),
            profileClearsServiceTier: true
        )

        #expect(overrides.serviceTier == nil)
    }

    @Test func resolveReviewModelSelectionPrefersLocalOverride() {
        let selection = resolveReviewModelSelection(
            localConfig: .init(reviewModel: "gpt-root"),
            resolvedConfig: .init(
                model: "gpt-base",
                reviewModel: "gpt-profile"
            )
        )

        #expect(selection.reportedModelBeforeThreadStart == "gpt-root")
    }

    @Test func resolveReviewModelSelectionHonorsProfileReviewModelClear() {
        let selection = resolveReviewModelSelection(
            localConfig: .init(reviewModel: "gpt-root"),
            resolvedConfig: .init(
                model: "gpt-base",
                reviewModel: nil
            ),
            profileClearsReviewModel: true
        )

        #expect(selection.reportedModelBeforeThreadStart == "gpt-base")
    }

    @Test func resolveReviewModelOverridePrefersLocalOverride() {
        let reviewModelOverride = resolveReviewModelOverride(
            localConfig: .init(reviewModel: "gpt-root"),
            resolvedConfig: .init(
                model: "gpt-base",
                reviewModel: "gpt-profile"
            )
        )

        #expect(reviewModelOverride == "gpt-root")
    }

    @Test func resolveReviewModelOverrideHonorsProfileReviewModelClear() {
        let reviewModelOverride = resolveReviewModelOverride(
            localConfig: .init(reviewModel: "gpt-root"),
            resolvedConfig: .init(reviewModel: nil),
            profileClearsReviewModel: true
        )

        #expect(reviewModelOverride == nil)
    }

    @Test func settingsKeyPathQuotesProfileNamesWhenNeeded() {
        #expect(
            settingsKeyPath(
                "review_model",
                profileKeyPath: #"profiles."qa.us""#,
                forceRoot: false
            ) == #"profiles."qa.us".review_model"#
        )
        #expect(
            settingsKeyPath(
                "service_tier",
                profileKeyPath: "profiles.reviewer",
                forceRoot: false
            ) == "profiles.reviewer.service_tier"
        )
        #expect(
            settingsKeyPath(
                "model_reasoning_effort",
                profileKeyPath: "profiles.reviewer",
                forceRoot: true
            ) == "model_reasoning_effort"
        )
    }

    @Test func reviewLocalConfigReadsRootLevelValuesAndIgnoresSections() throws {
        let tempHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let configDirectory = tempHome.appendingPathComponent(".codex_review", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try """
        review_model = "gpt-5.4-mini"
        model_reasoning_effort = "high"
        service_tier = "fast"
        model_context_window = 120_000
        model_auto_compact_token_limit = 110_000

        [profiles.dev]
        review_model = "ignored"
        model_context_window = 999_999
        """.write(
            to: configDirectory.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )

        let config = try loadReviewLocalConfig(environment: ["HOME": tempHome.path])

        #expect(config.reviewModel == "gpt-5.4-mini")
        #expect(config.modelReasoningEffort == "high")
        #expect(config.serviceTier == "fast")
        #expect(config.modelContextWindow == 120_000)
        #expect(config.modelAutoCompactTokenLimit == 110_000)
    }

    @Test func configReadResponseDecodesReasoningEffortAndServiceTier() throws {
        let data = Data(
            """
            {
              "config": {
                "model": "gpt-5.4",
                "review_model": "gpt-5.4-mini",
                "model_reasoning_effort": "high",
                "service_tier": "fast",
                "model_context_window": "120_000",
                "model_auto_compact_token_limit": 110000
              }
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(AppServerConfigReadResponse.self, from: data)

        #expect(response.config.model == "gpt-5.4")
        #expect(response.config.reviewModel == "gpt-5.4-mini")
        #expect(response.config.modelReasoningEffort == .high)
        #expect(response.config.serviceTier == .fast)
        #expect(response.config.modelContextWindow == 120_000)
        #expect(response.config.modelAutoCompactTokenLimit == 110_000)
    }

    @Test func modelListResponseDecodesCatalogMetadata() throws {
        let data = Data(
            """
            {
              "data": [
                {
                  "id": "gpt-5.4",
                  "model": "gpt-5.4",
                  "displayName": "GPT-5.4",
                  "description": "Balanced model",
                  "hidden": false,
                  "supportedReasoningEfforts": [
                    {
                      "reasoningEffort": "medium",
                      "description": "Balanced default."
                    }
                  ],
                  "defaultReasoningEffort": "medium",
                  "inputModalities": ["text"],
                  "supportsPersonality": true,
                  "additionalSpeedTiers": ["fast", "flex"],
                  "isDefault": true,
                  "upgrade": null,
                  "upgradeInfo": null,
                  "availabilityNux": null
                }
              ],
              "nextCursor": null
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(AppServerModelListResponse.self, from: data)
        let model = try #require(response.data.first)

        #expect(model.id == "gpt-5.4")
        #expect(model.displayName == "GPT-5.4")
        #expect(model.supportedReasoningEfforts == [
            .init(reasoningEffort: .medium, description: "Balanced default.")
        ])
        #expect(model.defaultReasoningEffort == .medium)
        #expect(model.supportedServiceTiers == [.fast, .flex])
    }

    @Test func modelListResponseIgnoresUnknownReasoningMetadata() throws {
        let data = Data(
            """
            {
              "data": [
                {
                  "id": "gpt-next",
                  "model": "gpt-next",
                  "displayName": "GPT Next",
                  "hidden": false,
                  "supportedReasoningEfforts": [
                    {
                      "reasoningEffort": "ultra",
                      "description": "Unknown future tier."
                    },
                    {
                      "reasoningEffort": "medium",
                      "description": "Balanced default."
                    }
                  ],
                  "defaultReasoningEffort": "ultra",
                  "inputModalities": ["text"],
                  "supportsPersonality": true,
                  "additionalSpeedTiers": ["fast"],
                  "isDefault": false,
                  "upgrade": null,
                  "upgradeInfo": null,
                  "availabilityNux": null
                }
              ],
              "nextCursor": null
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(AppServerModelListResponse.self, from: data)
        let model = try #require(response.data.first)

        #expect(model.supportedReasoningEfforts == [
            .init(reasoningEffort: .medium, description: "Balanced default.")
        ])
        #expect(model.defaultReasoningEffort == .medium)
    }

    @Test func reviewLocalConfigScaffoldCreatesConfigAndAgentsFiles() throws {
        let tempHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)

        let config = try loadReviewLocalConfig(environment: ["HOME": tempHome.path])

        #expect(config == .init())
        #expect(
            FileManager.default.fileExists(
                atPath: tempHome.appendingPathComponent(".codex_review/config.toml").path
            )
        )
        #expect(
            FileManager.default.fileExists(
                atPath: tempHome.appendingPathComponent(".codex_review/AGENTS.md").path
            )
        )
    }

    @Test func reviewLocalConfigRejectsInvalidValueTypes() throws {
        #expect(throws: ReviewLocalConfigError.self) {
            _ = try parseReviewLocalConfig(
                """
                review_model = 123
                model_context_window = "bad"
                """,
                sourcePath: "/tmp/.codex_review/config.toml"
            )
        }
    }

    @Test func reviewLocalConfigAcceptsQuotedNumericLimits() throws {
        let config = try parseReviewLocalConfig(
            """
            model_context_window = "120_000"
            model_auto_compact_token_limit = "110_000"
            """,
            sourcePath: "/tmp/.codex_review/config.toml"
        )

        #expect(config.modelContextWindow == 120_000)
        #expect(config.modelAutoCompactTokenLimit == 110_000)
    }

    @Test func fallbackAppServerConfigReadsProfileScopedValues() throws {
        let tempHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let codexDirectory = tempHome.appendingPathComponent(".codex_review", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        try """
        profile = "reviewer"
        model = "gpt-5.2"

        [profiles.reviewer]
        model = "gpt-5.3-codex"
        review_model = "gpt-5.4-mini"
        model_context_window = 999_999
        model_auto_compact_token_limit = 888_888
        """.write(
            to: codexDirectory.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )

        let config = loadFallbackAppServerConfig(environment: ["HOME": tempHome.path])

        #expect(config.model == "gpt-5.3-codex")
        #expect(config.reviewModel == "gpt-5.4-mini")
        #expect(config.modelContextWindow == 999_999)
        #expect(config.modelAutoCompactTokenLimit == 888_888)
    }

    @Test func fallbackAppServerConfigReadsQuotedProfileScopedValues() throws {
        let tempHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let codexDirectory = tempHome.appendingPathComponent(".codex_review", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        try """
        profile = "team \\\"alpha\\\""

        [profiles."team \\\"alpha\\\""]
        review_model = "gpt-5.4-mini"
        service_tier = "flex"
        """.write(
            to: codexDirectory.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )

        let config = loadFallbackAppServerConfig(environment: ["HOME": tempHome.path])

        #expect(config.reviewModel == "gpt-5.4-mini")
        #expect(config.serviceTier == .flex)
    }

    @Test func fallbackAppServerConfigReadsQuotedBareSafeProfileScopedValues() throws {
        let tempHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let codexDirectory = tempHome.appendingPathComponent(".codex_review", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        try """
        profile = "reviewer"

        [profiles."reviewer"]
        review_model = "gpt-5.4-mini"
        model_reasoning_effort = "high"
        """.write(
            to: codexDirectory.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )

        let config = loadFallbackAppServerConfig(environment: ["HOME": tempHome.path])

        #expect(config.reviewModel == "gpt-5.4-mini")
        #expect(config.modelReasoningEffort == .high)
    }

    @Test func fallbackAppServerConfigReadsDottedProfileScopedValues() throws {
        let tempHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let codexDirectory = tempHome.appendingPathComponent(".codex_review", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        try """
        profile = "qa.us"

        [profiles.qa.us]
        review_model = "gpt-5.4-mini"
        model_reasoning_effort = "high"
        """.write(
            to: codexDirectory.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )

        let config = loadFallbackAppServerConfig(environment: ["HOME": tempHome.path])

        #expect(config.reviewModel == "gpt-5.4-mini")
        #expect(config.modelReasoningEffort == .high)
    }

    @Test func fallbackAppServerConfigIgnoresUnrelatedProfileScalarKeys() throws {
        let tempHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let codexDirectory = tempHome.appendingPathComponent(".codex_review", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        try """
        profile = "reviewer"

        [profiles.reviewer]
        sandbox_mode = "danger-full-access"
        review_model = "gpt-5.4-mini"
        service_tier = "flex"
        """.write(
            to: codexDirectory.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )

        let config = loadFallbackAppServerConfig(environment: ["HOME": tempHome.path])

        #expect(config.reviewModel == "gpt-5.4-mini")
        #expect(config.serviceTier == .flex)
    }

    @Test func fallbackAppServerConfigAcceptsQuotedNumericLimits() throws {
        let tempHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let codexDirectory = tempHome.appendingPathComponent(".codex_review", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        try """
        model_context_window = "120_000"
        model_auto_compact_token_limit = "110_000"
        """.write(
            to: codexDirectory.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )

        let config = loadFallbackAppServerConfig(environment: ["HOME": tempHome.path])

        #expect(config.modelContextWindow == 120_000)
        #expect(config.modelAutoCompactTokenLimit == 110_000)
    }

    @Test func fallbackAppServerConfigPreservesClearedProfileOverridesOverRootValues() throws {
        let tempHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let codexDirectory = tempHome.appendingPathComponent(".codex_review", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        try """
        model = "gpt-5.4"
        review_model = "gpt-5.4-mini"
        model_reasoning_effort = "high"
        service_tier = "flex"
        profile = "reviewer"

        [profiles.reviewer]
        model = null
        review_model = null
        model_reasoning_effort = null
        service_tier = null
        """.write(
            to: codexDirectory.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )

        let config = loadFallbackAppServerConfig(environment: ["HOME": tempHome.path])

        #expect(config.model == nil)
        #expect(config.reviewModel == nil)
        #expect(config.modelReasoningEffort == nil)
        #expect(config.serviceTier == nil)
    }

    @Test func activeProfileClearDetectorsSurviveProfileNullAssignments() throws {
        let tempHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let codexDirectory = tempHome.appendingPathComponent(".codex_review", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        try """
        profile = "reviewer"

        [profiles.reviewer]
        review_model = null
        model_reasoning_effort = null
        service_tier = null
        """.write(
            to: codexDirectory.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )

        #expect(activeProfileClearsReviewModel(environment: ["HOME": tempHome.path]))
        #expect(activeProfileClearsReasoningEffort(environment: ["HOME": tempHome.path]))
        #expect(activeProfileClearsServiceTier(environment: ["HOME": tempHome.path]))
    }

    @Test func loadActiveReviewProfileDefaultsToDirectProfileKeyPathWhenSectionIsMissing() throws {
        let tempHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let codexDirectory = tempHome.appendingPathComponent(".codex_review", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        try """
        profile = "qa.us"
        """.write(
            to: codexDirectory.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )

        let profile = loadActiveReviewProfile(environment: ["HOME": tempHome.path])

        #expect(profile?.name == "qa.us")
        #expect(profile?.keyPathPrefix == #"profiles."qa.us""#)
    }

    @Test func mergeAppServerConfigUsesFallbackForMissingValuesOnly() {
        let merged = mergeAppServerConfig(
            primary: .init(
                model: nil,
                reviewModel: "gpt-5.4-mini",
                modelContextWindow: nil,
                modelAutoCompactTokenLimit: 110_000
            ),
            fallback: .init(
                model: "gpt-5.4",
                reviewModel: "gpt-5.3-codex",
                modelContextWindow: 120_000,
                modelAutoCompactTokenLimit: 100_000
            )
        )

        #expect(merged.model == "gpt-5.4")
        #expect(merged.reviewModel == "gpt-5.4-mini")
        #expect(merged.modelContextWindow == 120_000)
        #expect(merged.modelAutoCompactTokenLimit == 110_000)
    }

    @Test func modelsCachePathFollowsCodexHomeResolution() {
        #expect(
            ReviewHomePaths.modelsCacheURL(
                environment: ["HOME": "/tmp/home", "CODEX_HOME": "/tmp/custom-codex-home"]
            ).path
            == "/tmp/home/.codex_review/models_cache.json"
        )
        #expect(
            ReviewHomePaths.modelsCacheURL(environment: ["HOME": "/tmp/home"]).path
            == "/tmp/home/.codex_review/models_cache.json"
        )
    }

    @Test func reviewRequestRejectsEmptyBranchAndTimeout() {
        #expect(throws: ReviewError.self) {
            _ = try ReviewRequestOptions(
                cwd: "/tmp/example",
                target: .baseBranch("  ")
            ).validated()
        }

        #expect(throws: ReviewError.self) {
            _ = try ReviewRequestOptions(
                cwd: "/tmp/example",
                target: .custom(instructions: "Inspect API changes"),
                timeoutSeconds: 0
            ).validated()
        }
    }
}
