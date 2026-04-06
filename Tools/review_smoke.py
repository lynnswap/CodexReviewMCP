#!/usr/bin/env python3
"""
Local smoke harness for CodexReviewMCP.

Primary flow:
  python3 Tools/review_smoke.py http-e2e --cwd /abs/repo

Artifacts:
  - session_id.txt
  - initialize.headers.txt
  - initialized.response.txt
  - review_start.sse
  - server.stderr.log
  - summary.json
"""

from __future__ import annotations

import argparse
import http.client
import json
import os
import pathlib
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
from typing import Dict, Optional, Tuple


def project_root() -> pathlib.Path:
    return pathlib.Path(__file__).resolve().parents[1]


def default_server_bin() -> pathlib.Path:
    return project_root() / ".build" / "debug" / "CodexReviewMCPServerExecutable"


def write_text(path: pathlib.Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def run_http_request(
    host: str,
    port: int,
    method: str,
    path: str,
    body: Optional[str],
    headers: Dict[str, str],
) -> Tuple[int, Dict[str, str], str]:
    connection = http.client.HTTPConnection(host, port, timeout=1200)
    try:
        connection.request(method, path, body=body, headers=headers)
        response = connection.getresponse()
        payload = response.read().decode("utf-8", errors="replace")
        response_headers = {key: value for key, value in response.getheaders()}
        return response.status, response_headers, payload
    finally:
        connection.close()


def parse_last_sse_json(sse_text: str) -> Optional[dict]:
    event_data_blocks: list[str] = []
    current_event_data: list[str] = []
    for raw_line in sse_text.splitlines():
        if raw_line.startswith("data:"):
            current_event_data.append(raw_line[len("data:") :].lstrip())
            continue
        if raw_line == "":
            if current_event_data:
                event_data_blocks.append("\n".join(current_event_data))
                current_event_data = []
            continue
    if current_event_data:
        event_data_blocks.append("\n".join(current_event_data))
    if not event_data_blocks:
        return None
    try:
        return json.loads(event_data_blocks[-1])
    except json.JSONDecodeError:
        return None


def sse_reports_failure(event: Optional[dict]) -> bool:
    if not isinstance(event, dict):
        return False
    if "error" in event:
        return True
    result = event.get("result")
    return isinstance(result, dict) and bool(result.get("isError"))


def sse_has_terminal_response(event: Optional[dict]) -> bool:
    if not isinstance(event, dict):
        return False
    return "result" in event or "error" in event


def wait_for_server(host: str, port: int, path: str, timeout_seconds: float) -> None:
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        try:
            with socket.create_connection((host, port), timeout=0.2):
                return
        except OSError:
            time.sleep(0.1)
    raise TimeoutError(f"Timed out waiting for {host}:{port}{path}")


def wait_for_listening_port(stderr_path: pathlib.Path, timeout_seconds: float) -> int:
    deadline = time.time() + timeout_seconds
    pattern = re.compile(r"url=http://[^:]+:(\d+)/")
    while time.time() < deadline:
        if stderr_path.exists():
            text = stderr_path.read_text(encoding="utf-8", errors="replace")
            match = pattern.search(text)
            if match:
                return int(match.group(1))
        time.sleep(0.1)
    raise TimeoutError(f"Timed out waiting for server listen log in {stderr_path}")


def start_server(
    server_bin: pathlib.Path,
    cwd: pathlib.Path,
    host: str,
    port: int,
    codex_command: str,
    stderr_path: pathlib.Path,
) -> subprocess.Popen[str]:
    env = os.environ.copy()
    env.setdefault("CODEX_REVIEW_MCP_DEBUG_WS", "1")
    env.setdefault("CODEX_REVIEW_MCP_DEBUG_RUNNER", "1")
    stderr_file = stderr_path.open("w", encoding="utf-8")
    command = [
        str(server_bin),
        "--listen",
        f"{host}:{port}",
        "--codex-command",
        codex_command,
    ]
    return subprocess.Popen(
        command,
        cwd=str(cwd),
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=stderr_file,
        text=True,
    )


def terminate_process(process: subprocess.Popen[str]) -> None:
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


def run_http_e2e(args: argparse.Namespace) -> int:
    repo_root = pathlib.Path(args.cwd).resolve()
    output_dir = pathlib.Path(args.output_dir).resolve() if args.output_dir else pathlib.Path(
        tempfile.mkdtemp(prefix="codex-review-smoke-")
    )
    output_dir.mkdir(parents=True, exist_ok=True)

    server_bin = pathlib.Path(args.server_bin).resolve() if args.server_bin else default_server_bin()
    if not server_bin.exists():
        raise FileNotFoundError(
            f"Server binary not found at {server_bin}. Run `swift build --target CodexReviewMCPServerExecutable` first or pass --server-bin."
        )

    host = "127.0.0.1"
    requested_port = args.port if args.port else 0
    endpoint_path = args.endpoint
    stderr_path = output_dir / "server.stderr.log"

    process = start_server(
        server_bin=server_bin,
        cwd=repo_root,
        host=host,
        port=requested_port,
        codex_command=args.codex_command,
        stderr_path=stderr_path,
    )

    try:
        port = args.port if args.port else wait_for_listening_port(stderr_path, args.startup_timeout)
        wait_for_server(host=host, port=port, path=endpoint_path, timeout_seconds=args.startup_timeout)

        initialize_body = json.dumps(
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2025-11-25",
                    "capabilities": {},
                    "clientInfo": {
                        "name": "review-smoke",
                        "version": "0.0.1",
                    },
                },
            }
        )
        common_headers = {
            "Accept": "application/json, text/event-stream",
            "Content-Type": "application/json",
            "Mcp-Protocol-Version": "2025-11-25",
        }
        status, headers, body = run_http_request(
            host=host,
            port=port,
            method="POST",
            path=endpoint_path,
            body=initialize_body,
            headers=common_headers,
        )
        write_text(output_dir / "initialize.headers.txt", "\n".join(f"{k}: {v}" for k, v in headers.items()))
        write_text(output_dir / "initialize.body.txt", body)
        session_id = headers.get("Mcp-Session-Id") or headers.get("MCP-Session-Id")
        if status >= 400 or not session_id:
            raise RuntimeError(f"initialize failed: status={status}, session_id={session_id!r}")
        write_text(output_dir / "session_id.txt", session_id)

        initialized_body = json.dumps(
            {
                "jsonrpc": "2.0",
                "method": "notifications/initialized",
                "params": {},
            }
        )
        initialized_status, _, initialized_response = run_http_request(
            host=host,
            port=port,
            method="POST",
            path=endpoint_path,
            body=initialized_body,
            headers={**common_headers, "MCP-Session-Id": session_id},
        )
        write_text(output_dir / "initialized.response.txt", initialized_response)
        if initialized_status >= 400:
            raise RuntimeError(f"notifications/initialized failed: status={initialized_status}")

        review_start_body = json.dumps(
            {
                "jsonrpc": "2.0",
                "id": 2,
                "method": "tools/call",
                "params": {
                    "name": "review_start",
                    "arguments": {
                        "cwd": str(repo_root),
                        "target": {"type": "uncommittedChanges"},
                    },
                },
            }
        )
        review_status, _, review_sse = run_http_request(
            host=host,
            port=port,
            method="POST",
            path=endpoint_path,
            body=review_start_body,
            headers={**common_headers, "MCP-Session-Id": session_id},
        )
        write_text(output_dir / "review_start.sse", review_sse)

        final_event = parse_last_sse_json(review_sse)
        summary = {
            "host": host,
            "port": port,
            "endpoint": endpoint_path,
            "server_bin": str(server_bin),
            "cwd": str(repo_root),
            "session_id": session_id,
            "initialize_status": status,
            "initialized_status": initialized_status,
            "review_start_status": review_status,
            "review_start_final_event": final_event,
            "review_start_has_terminal_response": sse_has_terminal_response(final_event),
            "review_start_reported_error": sse_reports_failure(final_event),
            "stderr_log": str(stderr_path),
            "artifacts_dir": str(output_dir),
        }
        write_text(output_dir / "summary.json", json.dumps(summary, indent=2, ensure_ascii=False))
        print(json.dumps(summary, indent=2, ensure_ascii=False))
        return 0 if review_status < 400 and sse_has_terminal_response(final_event) and sse_reports_failure(final_event) is False else 1
    finally:
        terminate_process(process)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="CodexReviewMCP smoke harness")
    subparsers = parser.add_subparsers(dest="command", required=True)

    http_e2e = subparsers.add_parser("http-e2e", help="Run server startup + MCP review_start smoke")
    http_e2e.add_argument("--cwd", required=True, help="Repository path to review")
    http_e2e.add_argument("--output-dir", help="Directory to write artifacts into")
    http_e2e.add_argument("--server-bin", help="Path to the internal server executable")
    http_e2e.add_argument("--codex-command", default="codex", help="codex executable to use")
    http_e2e.add_argument("--endpoint", default="/mcp", help="Server endpoint path")
    http_e2e.add_argument("--port", type=int, help="Fixed port to bind")
    http_e2e.add_argument("--startup-timeout", type=float, default=30.0, help="Seconds to wait for server readiness")
    http_e2e.set_defaults(func=run_http_e2e)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        return args.func(args)
    except KeyboardInterrupt:
        return 130
    except Exception as error:  # pragma: no cover - smoke harness CLI
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
