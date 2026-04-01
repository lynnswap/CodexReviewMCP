import Foundation
import Testing
@testable import ReviewCore
@testable import ReviewJobs

@Suite struct ReviewExecutionSettingsBuilderTests {
    @Test func reviewExecutionSettingsBuilderAppliesAppServerDefaults() throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let codexHome = tempDirectory.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try """
        profile = "reviewer"

        [profiles.reviewer]
        model_context_window = 999999
        model_auto_compact_token_limit = 999999
        """.write(to: codexHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

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
        #expect(settings.threadStart.model == "gpt-5.4-mini")
        #expect(settings.threadStart.cwd == tempDirectory.path)
        #expect(settings.threadStart.approvalPolicy == "never")
        #expect(settings.threadStart.sandbox == "danger-full-access")
        #expect(settings.threadStart.personality == "none")
        #expect(settings.threadStart.ephemeral == true)
        #expect(settings.threadStart.config?["hide_agent_reasoning"] == .bool(false))
        #expect(settings.threadStart.config?["model_reasoning_effort"] == .string("xhigh"))
        #expect(settings.threadStart.config?["model_reasoning_summary"] == .string("detailed"))
        #expect(settings.threadStart.config?["model_context_window"] == .int(272000))
        #expect(settings.threadStart.config?["model_auto_compact_token_limit"] == .int(244800))
        #expect(settings.reviewStart.delivery == "inline")
        #expect(settings.reviewStart.target == .uncommittedChanges)
    }

    @Test func reviewExecutionSettingsBuilderUsesExplicitModelOverride() throws {
        let builder = ReviewExecutionSettingsBuilder()
        let settings = try builder.build(
            request: .init(
                cwd: FileManager.default.temporaryDirectory.path,
                target: .commit(sha: "abc1234", title: "Title"),
                model: "gpt-5.4"
            )
        )

        #expect(settings.threadStart.model == "gpt-5.4")
        #expect(settings.reviewStart.target == .commit(sha: "abc1234", title: "Title"))
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
