import Foundation
import Testing
@testable import ReviewCore

@Suite struct ReviewCommandBuilderTests {
    @Test func reviewCommandBuilderAppliesDefaultsFromConfigFile() throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let codexHome = tempDirectory.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try """
        personality = "friendly"
        model_context_window = 999999
        model_auto_compact_token_limit = 999999
        """.write(to: codexHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

        let builder = ReviewCommandBuilder(
            codexCommand: "codex",
            environment: ["HOME": tempDirectory.path]
        )
        let command = try builder.build(request: .init(cwd: tempDirectory.path))

        #expect(command.executable == "codex")
        #expect(command.arguments.contains("--json"))
        #expect(command.arguments.contains("review_model=gpt-5.4-mini"))
        #expect(command.arguments.contains("hide_agent_reasoning=false"))
        #expect(command.arguments.contains("personality=none"))
        #expect(command.arguments.contains("model_context_window=272000"))
        #expect(command.arguments.contains("model_auto_compact_token_limit=244800"))
        #expect(command.arguments.contains("model_reasoning_summary=detailed"))
    }

    @Test func reviewRequestRejectsCommitAndBaseAtTheSameTime() {
        let request = ReviewRequestOptions(
            cwd: "/tmp/example",
            base: "main",
            commit: "HEAD~1"
        )

        #expect(throws: ReviewError.self) {
            _ = try request.validated()
        }
    }

    @Test func reviewRequestRejectsBaseAndUncommittedAtTheSameTime() {
        let request = ReviewRequestOptions(
            cwd: "/tmp/example",
            base: "main",
            uncommitted: true
        )

        #expect(throws: ReviewError.self) {
            _ = try request.validated()
        }
    }

    @Test func reviewCommandBuilderClampsProfileScopedModelLimits() throws {
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

        let builder = ReviewCommandBuilder(
            codexCommand: "codex",
            environment: ["HOME": tempDirectory.path]
        )
        let command = try builder.build(request: .init(cwd: tempDirectory.path))

        #expect(command.arguments.contains("model_context_window=272000"))
        #expect(command.arguments.contains("model_auto_compact_token_limit=244800"))
    }

    @Test func reviewCommandBuilderRejectsReservedExtraArgs() throws {
        let builder = ReviewCommandBuilder()

        #expect(throws: ReviewError.self) {
            _ = try builder.build(
                request: .init(
                    cwd: FileManager.default.temporaryDirectory.path,
                    extraArgs: ["--output-last-message", "/tmp/override.txt"]
                )
            )
        }
    }

    @Test func reviewCommandBuilderTreatsPromptAsPositionalArgument() throws {
        let builder = ReviewCommandBuilder()
        let command = try builder.build(
            request: .init(
                cwd: FileManager.default.temporaryDirectory.path,
                prompt: "--model should-stay-a-prompt"
            )
        )

        #expect(command.arguments.contains("review_model=gpt-5.4-mini"))
        #expect(Array(command.arguments.suffix(2)) == ["--", "--model should-stay-a-prompt"])
    }

    @Test func reviewCommandBuilderRecognizesSpacedConfigOverrides() throws {
        let builder = ReviewCommandBuilder()
        let command = try builder.build(
            request: .init(
                cwd: FileManager.default.temporaryDirectory.path,
                configOverrides: [
                    "review_model = gpt-5.3-codex-spark",
                    "model_context_window = 999999",
                ]
            )
        )

        #expect(command.arguments.contains("model_context_window=128000"))
    }

    @Test func reviewCommandBuilderRejectsBareOptionTerminatorInExtraArgs() throws {
        let builder = ReviewCommandBuilder()

        #expect(throws: ReviewError.self) {
            _ = try builder.build(
                request: .init(
                    cwd: FileManager.default.temporaryDirectory.path,
                    extraArgs: ["--"]
                )
            )
        }
    }

    @Test func reviewCommandBuilderPreservesQuotedHashInConfig() throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let codexHome = tempDirectory.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try """
        profile = "review#1"

        [profiles."review#1"]
        personality = "friendly"
        """.write(to: codexHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

        let builder = ReviewCommandBuilder(
            codexCommand: "codex",
            environment: ["HOME": tempDirectory.path]
        )
        let command = try builder.build(request: .init(cwd: tempDirectory.path))

        #expect(command.arguments.contains("personality=none"))
    }
}
