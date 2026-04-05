# CodexReviewMCP

CodexReviewMCP exposes Codex review over MCP.

## Quick Start

1. Launch ReviewMonitor.

2. Register the MCP server in your client:

   ```bash
   # Recommended: HTTP/SSE
   codex mcp add codex_review --url http://localhost:9417/mcp

   # Alternative: STDIO adapter
   codex mcp add codex_review -- codex-review-mcp
   ```

3. Call one of the exposed tools:

   - `review_start`
   - `review_list`
   - `review_read`
   - `review_cancel`

4. If the client or agent is unfamiliar with the server, inspect discovery resources first:

   - `resources/list`
   - `resources/templates/list`
   - `resources/read` on `codex-review://help/overview`

### Codex CLI timeout note

`codex mcp add` does not currently expose MCP timeout flags. If you expect
long-running reviews, add the timeout values manually in your client Codex
config after registration. This client-side MCP entry is separate from
ReviewMCP's dedicated backend home at `~/.codex_review/config.toml`:

```toml
[mcp_servers.codex_review]
url = "http://localhost:9417/mcp"
startup_timeout_sec = 1200.0
tool_timeout_sec = 1200.0
```

Use your normal `codex mcp add ...` command first, then edit the generated
entry to include the timeout values.

## Architecture

- MCP server
  - Persistent HTTP/SSE MCP server
  - Multi-session
  - Session-scoped review jobs
  - One long-lived `codex app-server` backend process
  - One shared STDIO transport to the backend process
  - Review jobs run concurrently across sessions and within the same session
- Discovery
  - Writes the resolved endpoint to `~/.codex_review/review_mcp_endpoint.json`
  - Stores internal supervisor state in `~/.codex_review/review_mcp_runtime_state.json`

Pre-1.0 note:

- Discovery schema, runtime-state layout, and other internal file formats may change without migration before the first release.

## MCP Tools

### `review_start`

Runs a review through the shared long-lived `codex app-server` backend over STDIO and blocks until the final result is ready.

Key inputs:

- `cwd`
- `target`

`target` uses the app-server review target model:

- `{"type":"uncommittedChanges"}`
- `{"type":"baseBranch","branch":"main"}`
- `{"type":"commit","sha":"abc1234","title":"Optional title"}`
- `{"type":"custom","instructions":"Free-form review instructions"}`

Returns:

- `reviewThreadId`
- `threadId` when available
- `turnId`
- `model` effective resolved review model
- `status`
- `review`
- `error`

Notes:

- `review_start` is the primary client flow. It waits for terminal completion, so MCP clients should configure a sufficiently large tool timeout.
- ReviewMCP resolves the reported review model in this order:
  1. `~/.codex_review/config.toml` `review_model`
  2. the effective dedicated Codex config in `~/.codex_review/config.toml` `review_model`
  3. backend-reported `thread/start.model`
  4. the effective dedicated Codex config in `~/.codex_review/config.toml` `model` only as a pre-thread-start fallback when the backend does not report a model
- Use `review_read` to fetch `lastAgentMessage`, ordered `logs`, and `rawLogText`.

If you are unsure how to build the `target` object, read:

- `codex-review://help/tools/review_start`
- `codex-review://help/targets/uncommittedChanges`
- `codex-review://help/targets/baseBranch`
- `codex-review://help/targets/commit`
- `codex-review://help/targets/custom`

### `review_read`

Reads the current or final state of a review job owned by the current MCP session.
This is optional for normal clients because `review_start` already returns the final summary.

Returns:

- `reviewThreadId`
- `threadId` when available
- `turnId`
- `model` effective resolved review model
- `status`
- `review`
- `logs`
- `rawLogText`
- `lastAgentMessage`
- `error`

### `review_list`

Lists review jobs owned by the current MCP session.

Optional inputs:

- `cwd`
- `statuses`
- `limit` default `20`, max `100`

Returns:

- `items`
  - `reviewThreadId`
  - `cwd`
  - `targetSummary`
  - `model` effective resolved review model
  - `status`
  - `summary`
  - `startedAt`
  - `endedAt`
  - `elapsedSeconds`
  - `threadId`
  - `lastAgentMessage`
  - `cancellable`

### `review_cancel`

Cancels a review job owned by the current MCP session.

Inputs:

- exact:
  - `reviewThreadId`
- selector:
  - `cwd`
  - `statuses`
  - `latest`

Notes:

- `cwd` is a search key, not a unique identifier.
- When `latest: true`, the newest matching active review is selected automatically.
- Without `reviewThreadId`, `review_cancel` searches only the current MCP session.

## Resources

This server exposes onboarding/discovery resources over MCP. Clients can use `resources/list` and `resources/read` to inspect supported review flows without relying on this README.

## Resource Templates

This server also exposes MCP resource templates for tool-specific and target-specific help. Clients can discover them via `resources/templates/list`.

## Development Notes

- The package depends on `swift-sdk` via a pinned release version in [Package.swift](Package.swift).
- Server defaults plus clamp fallback metadata are loaded from [Sources/ReviewCore/Resources/defaults.json](Sources/ReviewCore/Resources/defaults.json).
- ReviewMCP-only overrides live in `~/.codex_review/config.toml` and currently support root-level `review_model`, `model_reasoning_effort`, `model_context_window`, and `model_auto_compact_token_limit`.
- ReviewMCP's dedicated Codex home is `~/.codex_review`. `config.toml`, `AGENTS.md`, `models_cache.json`, and other home-scoped review files are resolved from there.
- Review jobs are isolated per MCP session.
