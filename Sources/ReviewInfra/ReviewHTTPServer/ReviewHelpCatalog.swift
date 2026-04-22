import Foundation
import MCP
import ReviewDomain

package enum ReviewHelpCatalog {
    package static let overviewURI = "codex-review://help/overview"
    package static let troubleshootingURI = "codex-review://help/troubleshooting"
    package static let toolTemplateURI = "codex-review://help/tools/{toolName}"
    package static let targetTemplateURI = "codex-review://help/targets/{targetType}"

    package static let toolNames = [
        "review_start",
        "review_read",
        "review_list",
        "review_cancel",
    ]

    package static let targetTypes = [
        "uncommittedChanges",
        "baseBranch",
        "commit",
        "custom",
    ]

    package static let helpResourceURIs = [
        overviewURI,
        troubleshootingURI,
    ]

    package static let helpTemplateURIs = [
        toolTemplateURI,
        targetTemplateURI,
    ]

    package static let reviewStartConcreteHelpURIs = [
        toolURI("review_start"),
        targetURI("uncommittedChanges"),
    ]

    package static let reviewStartExample = """
    {
      "cwd": "/absolute/path/to/repo",
      "target": {
        "type": "uncommittedChanges"
      }
    }
    """

    package static let serverInstructions = """
    Run repository reviews through `codex app-server`.

    If you are unsure how to call this server, start with:
    - `resources/read` on `\(overviewURI)`
    - `resources/templates/list`

    Primary execution flow:
    - `review_start` runs a review and waits for the terminal result.
    - `review_read` rereads a known job.
    - `review_list` discovers jobs for the current MCP session.
    - `review_cancel` cancels a running job.
    """

    package static var staticResources: [Resource] {
        [
            Resource(
                name: "Review MCP Overview",
                uri: overviewURI,
                title: "Overview",
                description: "How to discover tools, targets, and the normal review flow.",
                mimeType: "text/markdown",
                annotations: .init(
                    audience: [.user, .assistant],
                    priority: 0.95
                )
            ),
            Resource(
                name: "Review MCP Troubleshooting",
                uri: troubleshootingURI,
                title: "Troubleshooting",
                description: "Common mistakes when calling review_start and how to recover.",
                mimeType: "text/markdown",
                annotations: .init(
                    audience: [.user, .assistant],
                    priority: 0.9
                )
            ),
        ]
    }

    package static var resourceTemplates: [Resource.Template] {
        [
            Resource.Template(
                uriTemplate: toolTemplateURI,
                name: "review_tool_help",
                title: "Tool Help",
                description: "Read concrete usage help for one review MCP tool.",
                mimeType: "text/markdown",
                annotations: .init(
                    audience: [.user, .assistant],
                    priority: 0.95
                )
            ),
            Resource.Template(
                uriTemplate: targetTemplateURI,
                name: "review_target_help",
                title: "Target Help",
                description: "Read concrete usage help for one review_start target.type value.",
                mimeType: "text/markdown",
                annotations: .init(
                    audience: [.user, .assistant],
                    priority: 0.95
                )
            ),
        ]
    }

    package static func toolURI(_ toolName: String) -> String {
        "codex-review://help/tools/\(toolName)"
    }

    package static func targetURI(_ targetType: String) -> String {
        "codex-review://help/targets/\(targetType)"
    }

    package static func readResource(uri: String) throws -> ReadResource.Result {
        let markdown: String
        switch uri {
        case overviewURI:
            markdown = overviewMarkdown
        case troubleshootingURI:
            markdown = troubleshootingMarkdown
        default:
            if let toolName = parseToolName(from: uri) {
                guard toolNames.contains(toolName) else {
                    throw invalidToolNameError(toolName)
                }
                markdown = toolMarkdown(toolName)
            } else if let targetType = parseTargetType(from: uri) {
                guard targetTypes.contains(targetType) else {
                    throw invalidTargetTypeError(targetType)
                }
                markdown = targetMarkdown(targetType)
            } else {
                throw MCPError.invalidParams(
                    """
                    Unknown help resource URI: \(uri)
                    Available static resources: \(helpResourceURIs.joined(separator: ", "))
                    Available templates: \(helpTemplateURIs.joined(separator: ", "))
                    """
                )
            }
        }

        return .init(
            contents: [
                .text(markdown, uri: uri, mimeType: "text/markdown"),
            ]
        )
    }

    package static func reviewStartGuidanceStructuredContent(detail: String?) -> Value {
        var object: [String: Value] = [
            "acceptedTargetTypes": .array(targetTypes.map(Value.string)),
            "helpResources": .array(helpResourceURIs.map(Value.string)),
            "helpTemplates": .array(helpTemplateURIs.map(Value.string)),
            "example": .string(reviewStartExample),
        ]
        if let detail, detail.isEmpty == false {
            object["detail"] = .string(detail)
        }
        return .object(object)
    }

    package static func reviewStartGuidanceMessage(detail: String?) -> String {
        var lines = ["`review_start` arguments were invalid."]
        if let detail, detail.isEmpty == false {
            lines.append("")
            lines.append("Reason: \(detail)")
        }
        lines += [
            "",
            "Accepted `target.type` values: \(targetTypes.joined(separator: ", "))",
            "",
            "Minimal example:",
            "```json",
            reviewStartExample,
            "```",
            "",
            "Read next:",
            "- \(overviewURI)",
            "- \(toolURI("review_start"))",
        ]
        lines += targetTypes.map { "- \(targetURI($0))" }
        return lines.joined(separator: "\n")
    }

    package static var reviewStartDescription: String {
        "Run a repository review through `codex app-server` and wait for the terminal result. Compatibility shorthand also accepts `target: \"uncommitted\"` or `{ \"type\": \"uncommitted\" }`, but prefer the canonical object form. The returned `model` is the effective resolved review model. If you are unsure about the arguments, read `\(toolURI("review_start"))` or browse `resources/templates/list`."
    }

    package static var reviewReadDescription: String {
        "Read the current or final state of a review job owned by the current MCP session. Returns the effective resolved review `model`, ordered `logs`, and `rawLogText`. Read `\(toolURI("review_read"))` for details."
    }

    package static var reviewListDescription: String {
        "List review jobs owned by the current MCP session. `items[].model` is the effective resolved review model, not the raw thread model. Read `\(toolURI("review_list"))` for details."
    }

    package static var reviewCancelDescription: String {
        "Cancel a running review job owned by the current MCP session. Pass either `jobId` or a selector (`cwd`, `statuses`). Read `\(toolURI("review_cancel"))` for details."
    }

    private static var overviewMarkdown: String {
        """
        # Review MCP Overview

        This server exposes review execution as MCP tools and onboarding help as MCP resources.

        ## Start Here

        1. Call `resources/templates/list`.
        2. Read `\(toolURI("review_start"))`.
        3. Read the target you want to use:
           - `\(targetURI("uncommittedChanges"))`
           - `\(targetURI("baseBranch"))`
           - `\(targetURI("commit"))`
           - `\(targetURI("custom"))`
        4. Call `review_start`.

        ## Minimal `review_start` Call

        ```json
        \(reviewStartExample)
        ```

        ## Tools

        - `review_start`: run a review and wait for completion.
        - `review_read`: reread one known job.
        - `review_list`: discover jobs for this MCP session.
        - `review_cancel`: cancel one job by ID or selector.

        ## Templates

        - `\(toolTemplateURI)`
        - `\(targetTemplateURI)`
        """
    }

    private static var troubleshootingMarkdown: String {
        """
        # Review MCP Troubleshooting

        ## `review_start` Fails To Decode

        Check these first:

        - `target.type` must be one of `\(targetTypes.joined(separator: "`, `"))`.
        - Compatibility shorthand also accepts `target: "uncommitted"` and `{ "type": "uncommitted" }`.
        - `baseBranch` requires `branch`.
        - `commit` requires `sha`.
        - `custom` requires `instructions`.
        - `cwd` must be an absolute repository path.

        Read:

        - `\(toolURI("review_start"))`
        - `\(targetURI("uncommittedChanges"))`
        - `\(targetURI("baseBranch"))`
        - `\(targetURI("commit"))`
        - `\(targetURI("custom"))`
        """
    }

    private static func toolMarkdown(_ toolName: String) -> String {
        switch toolName {
        case "review_start":
            return """
            # `review_start`

            Runs a review through `codex app-server` and waits for the terminal result.

            ## Minimal Input

            ```json
            \(reviewStartExample)
            ```

            ## Accepted `target.type`

            - `uncommittedChanges`
            - `baseBranch`
            - `commit`
            - `custom`

            Compatibility shorthand also accepts:

            - `target: "uncommitted"`
            - `target: "uncommittedChanges"`
            - `target: { "type": "uncommitted" }`

            ## Returns

            - `jobId`
            - `threadId`
            - `turnId`
            - `model` (effective resolved review model)
            - `status`
            - `review`
            - `error`

            Use `review_read` to fetch `lastAgentMessage`, ordered `logs`, and `rawLogText`.

            ReviewMCP resolves the reported review model in this order:

            1. `~/.codex_review/config.toml` `review_model`
            2. the effective dedicated Codex config in `~/.codex_review/config.toml` `review_model`
            3. backend-reported `thread/start.model`
            4. the effective dedicated Codex config in `~/.codex_review/config.toml` `model` only as a pre-thread-start fallback when the backend does not report a model

            ## Common Mistakes

            - `uncommitted` is accepted as compatibility shorthand, but `branch` is not
            - Omitting `branch`, `sha`, or `instructions` for the selected target
            """
        case "review_read":
            return """
            # `review_read`

            Reads one known review job by `jobId`.

            ## Minimal Input

            ```json
            {
              "jobId": "<id returned by review_start>"
            }
            ```

            Use `review_list` first if you do not know the ID.

            The response includes `model`, which is the effective resolved review model.
            """
        case "review_list":
            return """
            # `review_list`

            Lists jobs for the current MCP session.

            ## Minimal Input

            ```json
            {}
            ```

            ## Optional Filters

            - `cwd`
            - `statuses`
            - `limit`

            `items[].model` is the effective resolved review model, not the raw thread model.
            """
        case "review_cancel":
            return """
            # `review_cancel`

            Cancels one running job.

            ## By ID

            ```json
            {
              "jobId": "<id>"
            }
            ```

            ## By Selector

            ```json
            {
              "cwd": "/absolute/path/to/repo"
            }
            ```
            """
        default:
            preconditionFailure("Unexpected tool name: \(toolName)")
        }
    }

    private static func targetMarkdown(_ targetType: String) -> String {
        switch targetType {
        case "uncommittedChanges":
            return """
            # `target.type = "uncommittedChanges"`

            Reviews staged, unstaged, and untracked local changes.

            ```json
            {
              "cwd": "/absolute/path/to/repo",
              "target": {
                "type": "uncommittedChanges"
              }
            }
            ```
            """
        case "baseBranch":
            return """
            # `target.type = "baseBranch"`

            Reviews changes relative to a base branch.

            ```json
            {
              "cwd": "/absolute/path/to/repo",
              "target": {
                "type": "baseBranch",
                "branch": "main"
              }
            }
            ```
            """
        case "commit":
            return """
            # `target.type = "commit"`

            Reviews the changes introduced by one commit.

            ```json
            {
              "cwd": "/absolute/path/to/repo",
              "target": {
                "type": "commit",
                "sha": "abc1234",
                "title": "Optional title"
              }
            }
            ```
            """
        case "custom":
            return """
            # `target.type = "custom"`

            Runs a free-form review prompt.

            ```json
            {
              "cwd": "/absolute/path/to/repo",
              "target": {
                "type": "custom",
                "instructions": "Review only the public API changes."
              }
            }
            ```
            """
        default:
            preconditionFailure("Unexpected target type: \(targetType)")
        }
    }

    private static func parseToolName(from uri: String) -> String? {
        let prefix = "codex-review://help/tools/"
        guard uri.hasPrefix(prefix) else {
            return nil
        }
        let toolName = String(uri.dropFirst(prefix.count))
        return toolName.nilIfEmpty
    }

    private static func parseTargetType(from uri: String) -> String? {
        let prefix = "codex-review://help/targets/"
        guard uri.hasPrefix(prefix) else {
            return nil
        }
        let targetType = String(uri.dropFirst(prefix.count))
        return targetType.nilIfEmpty
    }

    private static func invalidToolNameError(_ toolName: String) -> MCPError {
        MCPError.invalidParams(
            "Unknown tool help URI value `\(toolName)`. Allowed values: \(toolNames.joined(separator: ", "))"
        )
    }

    private static func invalidTargetTypeError(_ targetType: String) -> MCPError {
        MCPError.invalidParams(
            "Unknown target help URI value `\(targetType)`. Allowed values: \(targetTypes.joined(separator: ", "))"
        )
    }
}
