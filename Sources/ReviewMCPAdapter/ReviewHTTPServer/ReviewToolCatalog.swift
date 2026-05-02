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
                "type": "object",
                "description": "Review target object. Set `type` to one of the supported target types. If you are unsure, read `\(ReviewHelpCatalog.toolURI("review_start"))` and then one of `\(ReviewHelpCatalog.targetURI("uncommittedChanges"))`, `\(ReviewHelpCatalog.targetURI("baseBranch"))`, `\(ReviewHelpCatalog.targetURI("commit"))`, or `\(ReviewHelpCatalog.targetURI("custom"))`.",
                "properties": [
                    "type": [
                        "type": "string",
                        "enum": .array(ReviewHelpCatalog.targetTypes.map(Value.string)),
                        "description": "Review target type.",
                    ],
                    "branch": ["type": "string", "description": "Required when `type` is `baseBranch`. Base branch name to compare against, such as `main`."],
                    "sha": ["type": "string", "description": "Required when `type` is `commit`. Commit SHA to review."],
                    "title": ["type": "string", "description": "Optional when `type` is `commit`. Human-readable title shown in summaries."],
                    "instructions": ["type": "string", "description": "Required when `type` is `custom`. Free-form review instructions passed as the prompt."],
                ],
                "required": ["type"],
                "additionalProperties": false,
                "allOf": [
                    targetTypeConstraint(
                        "uncommittedChanges",
                        forbiddenProperties: ["branch", "sha", "title", "instructions"]
                    ),
                    targetTypeConstraint(
                        "baseBranch",
                        requiredProperties: ["branch"],
                        forbiddenProperties: ["sha", "title", "instructions"]
                    ),
                    targetTypeConstraint(
                        "commit",
                        requiredProperties: ["sha"],
                        forbiddenProperties: ["branch", "instructions"]
                    ),
                    targetTypeConstraint(
                        "custom",
                        requiredProperties: ["instructions"],
                        forbiddenProperties: ["branch", "sha", "title"]
                    ),
                ],
            ],
        ],
        "required": ["cwd", "target"],
        "additionalProperties": false,
    ]

    private static let reviewReadInputSchema: Value = [
        "type": "object",
        "properties": [
            "jobId": ["type": "string", "description": "The `jobId` returned by `review_start` or `review_list`. See `\(ReviewHelpCatalog.toolURI("review_read"))` for usage."],
        ],
        "required": ["jobId"],
        "additionalProperties": false,
    ]

    private static let cancelInputSchema: Value = [
        "type": "object",
        "properties": [
            "jobId": ["type": "string", "description": "Cancel a specific review job by ID."],
            "cwd": ["type": "string", "description": "Optional selector that narrows matches to a repository path."],
            "statuses": [
                "type": "array",
                "items": [
                    "type": "string",
                    "enum": ["queued", "running", "succeeded", "failed", "cancelled"],
                ],
                "description": "Optional selector statuses. If omitted, queued and running jobs are considered.",
            ],
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

    private static func targetTypeConstraint(
        _ type: String,
        requiredProperties: [String] = [],
        forbiddenProperties: [String] = []
    ) -> Value {
        var thenSchema: [String: Value] = [:]
        if requiredProperties.isEmpty == false {
            thenSchema["required"] = .array(requiredProperties.map(Value.string))
        }
        if forbiddenProperties.isEmpty == false {
            thenSchema["not"] = [
                "anyOf": .array(
                    forbiddenProperties.map { property in
                        [
                            "required": .array([.string(property)]),
                        ]
                    }
                ),
            ]
        }
        return [
            "if": [
                "properties": [
                    "type": [
                        "const": .string(type),
                    ],
                ],
                "required": ["type"],
            ],
            "then": .object(thenSchema),
        ]
    }
}
