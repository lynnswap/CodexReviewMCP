import MCP

enum ReviewToolCatalog {
    static let tools: [Tool] = [
        Tool(
            name: "review_start",
            description: ReviewHelpCatalog.reviewStartDescription,
            inputSchema: reviewStartInputSchema,
            annotations: .init(readOnlyHint: false)
        ),
        Tool(
            name: "review_list",
            description: ReviewHelpCatalog.reviewListDescription,
            inputSchema: reviewListInputSchema,
            annotations: .init(readOnlyHint: true)
        ),
        Tool(
            name: "review_read",
            description: ReviewHelpCatalog.reviewReadDescription,
            inputSchema: reviewReadInputSchema,
            annotations: .init(readOnlyHint: true)
        ),
        Tool(
            name: "review_cancel",
            description: ReviewHelpCatalog.reviewCancelDescription,
            inputSchema: cancelInputSchema,
            annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        ),
    ]

    private static let reviewStartInputSchema: Value = [
        "type": "object",
        "properties": [
            "cwd": ["type": "string", "description": "Absolute repository path to review."],
            "target": [
                "description": "Review target. Use exactly one variant. If you are unsure, read `\(ReviewHelpCatalog.toolURI("review_start"))` and then one of `\(ReviewHelpCatalog.targetURI("uncommitted"))`, `\(ReviewHelpCatalog.targetURI("branch"))`, `\(ReviewHelpCatalog.targetURI("commit"))`, or `\(ReviewHelpCatalog.targetURI("custom"))`.",
                "oneOf": [
                    [
                        "type": "object",
                        "properties": [
                            "type": ["const": "uncommitted", "description": "Review staged, unstaged, and untracked local changes."],
                        ],
                        "required": ["type"],
                        "additionalProperties": false,
                    ],
                    [
                        "type": "object",
                        "properties": [
                            "type": ["const": "branch", "description": "Review changes relative to a base branch."],
                            "branch": ["type": "string", "description": "Base branch name to compare against, such as `main`."],
                        ],
                        "required": ["type", "branch"],
                        "additionalProperties": false,
                    ],
                    [
                        "type": "object",
                        "properties": [
                            "type": ["const": "commit", "description": "Review the changes introduced by a single commit."],
                            "sha": ["type": "string", "description": "Commit SHA to review."],
                            "title": ["type": "string", "description": "Optional human-readable title shown in summaries."],
                        ],
                        "required": ["type", "sha"],
                        "additionalProperties": false,
                    ],
                    [
                        "type": "object",
                        "properties": [
                            "type": ["const": "custom", "description": "Run a free-form review prompt."],
                            "instructions": ["type": "string", "description": "Free-form review instructions passed as the prompt."],
                        ],
                        "required": ["type", "instructions"],
                        "additionalProperties": false,
                    ],
                ],
            ],
            "model": ["type": "string", "description": "Optional review model override."],
        ],
        "required": ["cwd", "target"],
        "additionalProperties": false,
    ]

    private static let reviewReadInputSchema: Value = [
        "type": "object",
        "properties": [
            "reviewThreadId": ["type": "string", "description": "The `reviewThreadId` returned by `review_start` or `review_list`. See `\(ReviewHelpCatalog.toolURI("review_read"))` for usage."],
        ],
        "required": ["reviewThreadId"],
        "additionalProperties": false,
    ]

    private static let cancelInputSchema: Value = [
        "type": "object",
        "properties": [
            "reviewThreadId": ["type": "string", "description": "Cancel a specific review job by ID."],
            "cwd": ["type": "string", "description": "Optional selector that narrows matches to a repository path."],
            "statuses": [
                "type": "array",
                "items": [
                    "type": "string",
                    "enum": ["queued", "running", "succeeded", "failed", "cancelled"],
                ],
                "description": "Optional selector statuses. If omitted, queued and running jobs are considered.",
            ],
            "latest": ["type": "boolean", "description": "When using selector mode, cancel the most recent matching job instead of requiring a unique match."],
        ],
        "additionalProperties": false,
    ]

    private static let reviewListInputSchema: Value = [
        "type": "object",
        "properties": [
            "cwd": ["type": "string", "description": "Optional repository path filter."],
            "statuses": [
                "type": "array",
                "items": [
                    "type": "string",
                    "enum": ["queued", "running", "succeeded", "failed", "cancelled"],
                ],
                "description": "Optional status filter.",
            ],
            "limit": ["type": "integer", "description": "Maximum number of jobs to return. Defaults to 20 and is clamped to 100."],
        ],
        "additionalProperties": false,
    ]
}
