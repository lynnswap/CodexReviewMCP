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

### Runtime home

ReviewMCP uses `~/.codex_review` as its dedicated Codex home. The shared
`codex app-server` launched by ReviewMCP also uses this home, so backend
settings and runtime files are isolated from your normal Codex home.

ReviewMCP creates the directory when needed. It stores backend config in
`~/.codex_review/config.toml` and runtime metadata such as the current MCP
endpoint under the same directory.

### Codex CLI timeout note

`codex mcp add` does not currently expose MCP timeout flags. If you expect
long-running reviews, add the timeout values manually in your client Codex
config after registration. This client-side MCP entry is separate from the
ReviewMCP backend home described above:

```toml
[mcp_servers.codex_review]
url = "http://localhost:9417/mcp"
startup_timeout_sec = 1200.0
tool_timeout_sec = 1200.0
```

Use your normal `codex mcp add ...` command first, then edit the generated
entry to include the timeout values.

## Architecture

For a concise architecture summary and diagrams, see [Docs/architecture.md](Docs/architecture.md).

## MCP Details

For tool schemas, discovery resources, resource templates, session behavior, and runtime files, see [Docs/mcp.md](Docs/mcp.md).
