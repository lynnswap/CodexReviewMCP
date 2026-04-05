# CodexReviewMCP

An MCP server and STDIO adapter for Codex reviews backed by `codex app-server`.

`codex-review-mcp-server` runs as a persistent HTTP/SSE MCP server and keeps a
single long-lived `codex app-server` backend process alive over loopback
websocket transport. Review jobs are scoped per MCP session and share that
backend through one websocket connection per session.
`codex-review-mcp` is a thin STDIO adapter for clients that require STDIO transport.

## Quick Start

1. Start the server

   ```bash
   swift run codex-review-mcp-server
   ```

2. Register it in your MCP client

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

- `codex-review-mcp-server`
  - Persistent HTTP/SSE MCP server
  - Multi-session
  - Session-scoped review jobs
  - One long-lived `codex app-server` backend process
  - One websocket connection per MCP session
  - Reviews serialize within a session and may run concurrently across sessions
- `codex-review-mcp`
  - JSON-RPC over STDIO adapter
  - Forwards to the HTTP/SSE server
- Discovery
  - Writes the resolved endpoint to `~/.codex_review/review_mcp_endpoint.json`
  - Stores internal supervisor state in `~/.codex_review/review_mcp_runtime_state.json`

Pre-1.0 note:

- Discovery schema, runtime-state layout, and other internal file formats may change without migration before the first release.

## Installation

### Build from source

```bash
swift build
```

Debug binaries are written to:

- `.build/debug/codex-review-mcp`
- `.build/debug/codex-review-mcp-server`
- `.build/debug/codex-review-mcp-login`

Release build:

```bash
swift build -c release
```

Release binaries are written to:

- `.build/release/codex-review-mcp`
- `.build/release/codex-review-mcp-server`
- `.build/release/codex-review-mcp-login`

### Optional: copy binaries into your PATH

```bash
mkdir -p "$HOME/.local/bin"
cp .build/release/codex-review-mcp "$HOME/.local/bin/"
cp .build/release/codex-review-mcp-server "$HOME/.local/bin/"
cp .build/release/codex-review-mcp-login "$HOME/.local/bin/"
chmod +x "$HOME/.local/bin/codex-review-mcp" "$HOME/.local/bin/codex-review-mcp-server" "$HOME/.local/bin/codex-review-mcp-login"
```

### Authenticate ReviewMCP Home

ReviewMCP uses a dedicated Codex home at `~/.codex_review`. To authenticate it with the normal Codex OAuth flow, run:

```bash
codex-review-mcp-login
```

This signs in `~/.codex_review` directly using Codex's built-in account flow. Cached credentials may live in `~/.codex_review/auth.json` or in the OS credential store, depending on Codex configuration. ReviewMCP does not rely on symlinking or copying credentials from `~/.codex`.

Useful variants:

- `codex-review-mcp-login status`
- `codex-review-mcp-login logout`

### Authenticate From ReviewMonitor

The ReviewMonitor app shows ReviewMCP authentication separately from server state.

- Use the server status menu to:
  - `Sign in with ChatGPT`
  - `Sign Out`
- ChatGPT sign-in opens the Codex browser login URL in your default browser and waits for Codex to complete the localhost callback flow.
- If a review fails because authentication is missing or expired, the detail pane shows a sign-in action so you can re-authenticate and retry.

## Usage

### Server: `codex-review-mcp-server`

Defaults:

- listen: `localhost:9417`
- endpoint: `/mcp`
- session timeout: `3600` seconds
- discovery file: `~/.codex_review/review_mcp_endpoint.json`

Options:

| Option | Description |
|--------|-------------|
| `--listen host:port` | Listen address for the HTTP/SSE MCP server |
| `--session-timeout sec` | Session idle timeout in seconds |
| `--codex-command path` | Override the `codex` executable path |
| `--force-restart` | If the listen port is already in use, terminate the discovered existing server and restart |

### Adapter: `codex-review-mcp`

Options:

| Option | Description |
|--------|-------------|
| `--url url` | Explicit upstream MCP URL |
| `--request-timeout sec` | HTTP request timeout for the adapter |

Environment variables:

| Variable | Description |
|----------|-------------|
| `CODEX_REVIEW_MCP_ENDPOINT` | Override the upstream URL for the STDIO adapter |

Adapter endpoint resolution order:

1. `--url`
2. `CODEX_REVIEW_MCP_ENDPOINT`
3. Discovery file: `~/.codex_review/review_mcp_endpoint.json`
4. Default: `http://localhost:9417/mcp`

## MCP Tools

### `review_start`

Runs a review through the shared long-lived `codex app-server` backend and blocks until the final result is ready.

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
