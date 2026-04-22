# Rearchitecture Contract Baseline

This document captures the external contracts that must remain stable while the
internal architecture of `CodexReviewMCP` is reworked.

## ReviewMonitor / MCP Surface

The current MCP server contract is defined by the combination of:

- [README.md](/Users/kn/Dev/CodexReviewMCP/README.md)
- [ReviewToolCatalog.swift](/Users/kn/Dev/CodexReviewMCP/Sources/ReviewHTTPServer/ReviewToolCatalog.swift)
- [ReviewToolHandler.swift](/Users/kn/Dev/CodexReviewMCP/Sources/ReviewHTTPServer/ReviewToolHandler.swift)
- [ReviewHelpCatalog.swift](/Users/kn/Dev/CodexReviewMCP/Sources/ReviewHTTPServer/ReviewHelpCatalog.swift)

Required tool names:

- `review_start`
- `review_list`
- `review_read`
- `review_cancel`

Required static help resources:

- `codex-review://help/overview`
- `codex-review://help/troubleshooting`

Required help templates:

- `codex-review://help/tools/{toolName}`
- `codex-review://help/targets/{targetType}`

`review_start` must continue to accept the canonical target object variants:

- `{"type":"uncommittedChanges"}`
- `{"type":"baseBranch","branch":"main"}`
- `{"type":"commit","sha":"abc1234","title":"Optional title"}`
- `{"type":"custom","instructions":"Free-form review instructions"}`

Compatibility shorthand remains supported during the rearchitecture:

- `"uncommitted"`
- `{"type":"uncommitted"}`

The structured content returned by the MCP tools must keep the current
top-level keys:

- `review_start`: `jobId`, `status`, `review`, `turnId`, `model`, `error?`
- `review_read`: `jobId`, `status`, `review`, `turnId`, `model`, `logs`,
  `rawLogText`, `lastAgentMessage?`, `error?`
- `review_list`: `items[]` with `jobId`, `cwd`, `targetSummary`, `model`,
  `status`, `summary`, `startedAt?`, `endedAt?`, `elapsedSeconds?`,
  `threadId?`, `lastAgentMessage?`, `cancellable`
- `review_cancel`: `jobId`, `cancelled`, `status`, `turnId`, `threadId?`

## Codex App-Server Contract

The external source of truth is the local Codex checkout at:

- `/Users/kn/Dev/codex/AGENTS.md`
- `/Users/kn/Dev/codex/codex-rs/app-server/README.md`
- `/Users/kn/Dev/codex/codex-rs/app-server-protocol/src/protocol/common.rs`
- `/Users/kn/Dev/codex/codex-rs/app-server-protocol/src/protocol/v2.rs`

The rearchitecture must stay aligned with these app-server v2 concepts:

- `initialize` / `initialized`
- `review/start`
- `thread/start`
- `config/read`
- `model/list`
- account update notifications
- account login completion notifications

Wire-shape rules copied from the Codex app-server guidance:

- request/response/notification payloads use `camelCase`
- config payload fields mirror `config.toml` and use `snake_case`
- string IDs stay stringly-typed at the boundary

Specific fields this repository currently depends on:

- `review/start`: `threadId`, `target`, `delivery`, `reviewThreadId`
- `config/read`: `model`, `review_model`, `model_reasoning_effort`,
  `service_tier`, `model_context_window`, `model_auto_compact_token_limit`
- `model/list`: model catalog `data`, cursor pagination, reasoning metadata,
  `additionalSpeedTiers`
- notifications: account login completion and account update payloads

## Baseline Validation

Current baseline validation command:

```sh
swift test
```

The baseline test run passed before the rearchitecture started, and every
phase must preserve a green `swift test` result before the next phase begins.
