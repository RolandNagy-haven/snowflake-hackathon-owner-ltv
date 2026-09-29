"""Minimal JSON-RPC client for Snowflake-managed MCP servers (auth via invocation-poc/sf_mcp_auth.py).

    from mcp_http import McpClient
    c = McpClient(url)
    c.list_tools()
    c.call("search_findings", {"query": "grain of FCT_PARK_ARRIVAL"})   # -> (text, is_error)
"""
import json
import sys
import time
from pathlib import Path

import requests

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "invocation-poc"))
import sf_mcp_auth  # noqa: E402

AUTH_ERRORS = {"390111", "390112", "390113", "390114", "390318"}  # expired / invalid session or token


def _parse(resp: requests.Response) -> dict:
    text = resp.text
    if text.lstrip().startswith("event:") or "\ndata:" in text:  # SSE framing: take the last data line
        data = [line[5:].strip() for line in text.splitlines() if line.startswith("data:")]
        text = data[-1] if data else "{}"
    return json.loads(text)


class McpClient:
    def __init__(self, url: str, timeout: int = 120):
        self.url, self.timeout, self._id = url, timeout, 0

    def _headers(self) -> dict:
        token = sf_mcp_auth.cached_token() or sf_mcp_auth.silent_token()
        return {**sf_mcp_auth.header(token), "Accept": "application/json, text/event-stream"}

    def rpc(self, method: str, params: dict | None = None) -> dict:
        self._id += 1
        msg = {"jsonrpc": "2.0", "id": self._id, "method": method, "params": params or {}}
        r = requests.post(self.url, headers=self._headers(), timeout=self.timeout, json=msg)
        out = _parse(r)
        # An expired session comes back as HTTP 200 with a Snowflake REST error body, not JSON-RPC: log in again once.
        if "jsonrpc" not in out and str(out.get("code")) in AUTH_ERRORS:
            sf_mcp_auth.CACHE_FILE.unlink(missing_ok=True)
            r = requests.post(self.url, headers=self._headers(), timeout=self.timeout, json=msg)
            out = _parse(r)
        if "jsonrpc" not in out:
            raise RuntimeError(f"{method}: Snowflake error {out.get('code')}: {out.get('message')} (request_id {out.get('request_id')})")
        if "error" in out:
            raise RuntimeError(f"{method}: {out['error'].get('message')}")
        return out["result"]

    def list_tools(self) -> list[dict]:
        return self.rpc("tools/list")["tools"]

    def call(self, tool: str, arguments: dict) -> tuple[str, bool, float]:
        """Returns (text, is_error, elapsed_s)."""
        t0 = time.time()
        res = self.rpc("tools/call", {"name": tool, "arguments": arguments})
        text = "\n".join(c.get("text", "") for c in res.get("content", []) if c.get("type") == "text")
        return text, bool(res.get("isError")), round(time.time() - t0, 2)
