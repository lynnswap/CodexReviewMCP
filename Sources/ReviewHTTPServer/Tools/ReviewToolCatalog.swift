import MCP

enum ReviewToolCatalog {
    static let tools: [Tool] = [
        Tool(
            name: "review_start",
            description: "Run a repository review through codex exec review and wait until the final result is ready.",
            inputSchema: reviewStartInputSchema,
            annotations: .init(readOnlyHint: false)
        ),
        Tool(
            name: "review_list",
            description: "List review jobs owned by the current MCP session.",
            inputSchema: reviewListInputSchema,
            annotations: .init(readOnlyHint: true)
        ),
        Tool(
            name: "review_read",
            description: "Read the current or final state of a review job owned by the current MCP session.",
            inputSchema: reviewReadInputSchema,
            annotations: .init(readOnlyHint: true)
        ),
        Tool(
            name: "review_cancel",
            description: "Cancel a running review job owned by the current MCP session.",
            inputSchema: cancelInputSchema,
            annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        ),
    ]

    private static let reviewStartInputSchema: Value = [
        "type": "object",
        "properties": [
            "cwd": ["type": "string", "description": "Repository path to review."],
            "target": [
                "type": "object",
                "properties": [
                    "type": [
                        "type": "string",
                        "enum": ["uncommittedChanges", "baseBranch", "commit", "custom"],
                    ],
                    "branch": ["type": "string"],
                    "sha": ["type": "string"],
                    "title": ["type": "string"],
                    "instructions": ["type": "string"],
                ],
                "required": ["type"],
                "additionalProperties": false,
            ],
            "model": ["type": "string"],
        ],
        "required": ["cwd", "target"],
        "additionalProperties": false,
    ]

    private static let reviewReadInputSchema: Value = [
        "type": "object",
        "properties": [
            "reviewThreadId": ["type": "string"],
        ],
        "required": ["reviewThreadId"],
        "additionalProperties": false,
    ]

    private static let cancelInputSchema: Value = [
        "type": "object",
        "properties": [
            "reviewThreadId": ["type": "string"],
            "cwd": ["type": "string"],
            "statuses": [
                "type": "array",
                "items": [
                    "type": "string",
                    "enum": ["queued", "running", "succeeded", "failed", "cancelled"],
                ],
            ],
            "latest": ["type": "boolean"],
        ],
        "additionalProperties": false,
    ]

    private static let reviewListInputSchema: Value = [
        "type": "object",
        "properties": [
            "cwd": ["type": "string"],
            "statuses": [
                "type": "array",
                "items": [
                    "type": "string",
                    "enum": ["queued", "running", "succeeded", "failed", "cancelled"],
                ],
            ],
            "limit": ["type": "integer"],
        ],
        "additionalProperties": false,
    ]
}
