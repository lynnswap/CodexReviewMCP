# CodexReviewMCP

An MCP server and STDIO adapter for Codex reviews backed by `codex exec review --json`.

`codex-review-mcp-server` runs as a persistent HTTP/SSE MCP server and executes
session-scoped review jobs through `codex exec review`.
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
   - `review_read`
   - `review_cancel`

### Codex CLI timeout note

`codex mcp add` does not currently expose MCP timeout flags. If you expect
long-running reviews, add the timeout values manually in `~/.codex/config.toml`
after registration:

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
  - `codex exec review --json` backend
- `codex-review-mcp`
  - JSON-RPC over STDIO adapter
  - Forwards to the HTTP/SSE server
- Discovery
  - Writes the resolved endpoint to `~/Library/Caches/CodexReviewMCP/endpoint.json`

## Installation

### Build from source

```bash
swift build
```

Debug binaries are written to:

- `.build/debug/codex-review-mcp`
- `.build/debug/codex-review-mcp-server`

Release build:

```bash
swift build -c release
```

Release binaries are written to:

- `.build/release/codex-review-mcp`
- `.build/release/codex-review-mcp-server`

### Optional: copy binaries into your PATH

```bash
mkdir -p "$HOME/.local/bin"
cp .build/release/codex-review-mcp "$HOME/.local/bin/"
cp .build/release/codex-review-mcp-server "$HOME/.local/bin/"
chmod +x "$HOME/.local/bin/codex-review-mcp" "$HOME/.local/bin/codex-review-mcp-server"
```

## Usage

### Server: `codex-review-mcp-server`

Defaults:

- listen: `localhost:9417`
- endpoint: `/mcp`
- session timeout: `3600` seconds
- discovery file: `~/Library/Caches/CodexReviewMCP/endpoint.json`

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
3. Discovery file: `~/Library/Caches/CodexReviewMCP/endpoint.json`
4. Default: `http://localhost:9417/mcp`

## MCP Tools

### `review_start`

Runs a review through `codex exec review --json` and blocks until the final result is ready.

Key inputs:

- `cwd`
- `target`
- `model`

`target` uses the review target model:

- `{"type":"uncommittedChanges"}`
- `{"type":"baseBranch","branch":"main"}`
- `{"type":"commit","sha":"abc1234","title":"Optional title"}`
- `{"type":"custom","instructions":"Free-form review instructions"}`

Returns:

- `jobId`
- `reviewThreadId`
- `threadId` when available
- `status`
- `review`
- `lastAgentMessage`
- `error`

Notes:

- `review_start` is the primary client flow. It waits for terminal completion, so MCP clients should configure a sufficiently large tool timeout.
- `review_read` is only a supplementary API for post-hoc inspection or manual troubleshooting.

### `review_read`

Reads the current or final state of a review job owned by the current MCP session.
This is optional for normal clients because `review_start` already returns the final result.

Returns:

- `jobId`
- `reviewThreadId`
- `threadId` when available
- `status`
- `review`
- `lastAgentMessage`
- `error`

### `review_cancel`

Cancels a review job owned by the current MCP session.

## Development Notes

- The package depends on `swift-sdk` via a pinned Git revision in [Package.swift](Package.swift).
- Default review model, clamp limits, and server defaults are loaded from [Sources/ReviewCore/Resources/defaults.json](Sources/ReviewCore/Resources/defaults.json).
- Review jobs are isolated per MCP session.
