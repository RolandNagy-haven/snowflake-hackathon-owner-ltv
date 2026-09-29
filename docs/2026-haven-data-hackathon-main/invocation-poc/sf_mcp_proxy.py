"""stdio <-> Snowflake-managed MCP server proxy with token refresh.

    .mcp.json:  {"type": "stdio", "command": "<python>", "args": ["invocation-poc/sf_mcp_proxy.py", "<mcp server url>"]}

Why: a Snowflake session token expires 1 h after login. The MCP endpoint then answers HTTP 200 with a plain
REST error body ({"code": "390112", "message": "Your session has expired..."}), not a JSON-RPC message and not a
401, so Claude Code never re-runs its headersHelper and every later call fails with "malformed result".
This proxy speaks MCP over stdio (one JSON-RPC message per line), forwards each message over HTTPS with a
session token from sf_mcp_auth, and on a session/token error refreshes the token (silent SSO via the keychain
ID token) and retries once. Any reply that still isn't JSON-RPC is turned into a JSON-RPC error that carries
Snowflake's code, message and request_id. Requests run concurrently; logs go to stderr.
"""
import json
import sys
import threading
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import requests

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sf_mcp_auth  # noqa: E402

AUTH_ERRORS = {"390111", "390112", "390113", "390114", "390318"}  # expired / invalid session or token
URL = sys.argv[1]
_out_lock, _token_lock = threading.Lock(), threading.Lock()


def log(msg: str) -> None:
    print(f"sf_mcp_proxy: {msg}", file=sys.stderr, flush=True)


def token(stale: str | None = None) -> str:
    """Shared token cache (same file as the headersHelper). stale = a token Snowflake just rejected: log in again,
    unless a concurrent request already replaced it."""
    with _token_lock:
        current = sf_mcp_auth.cached_token()
        if stale and current == stale:
            log("session token rejected by Snowflake; logging in again")
            sf_mcp_auth.CACHE_FILE.unlink(missing_ok=True)
            current = None
        return current or sf_mcp_auth.silent_token()


def send(obj: dict) -> None:
    with _out_lock:
        sys.stdout.write(json.dumps(obj) + "\n")
        sys.stdout.flush()


def parse(text: str):
    if "\ndata:" in text or text.lstrip().startswith("event:"):
        data = [line[5:].strip() for line in text.splitlines() if line.startswith("data:")]
        text = data[-1] if data else ""
    return json.loads(text) if text.strip() else None


def post(msg: dict, tok: str):
    r = requests.post(URL, json=msg, timeout=900, headers={
        "Authorization": f'Snowflake Token="{tok}"', "Accept": "application/json, text/event-stream"})
    try:
        body = parse(r.text)
    except ValueError:
        body = {"code": str(r.status_code), "message": r.text[:500]}
    return r.status_code, body


def is_auth_error(status: int, body) -> bool:
    return status in (401, 403) or (isinstance(body, dict) and "jsonrpc" not in body
                                    and str(body.get("code") or body.get("error_code")) in AUTH_ERRORS)


def handle(msg: dict) -> None:
    rid = msg.get("id")
    try:
        tok = token()
        status, body = post(msg, tok)
        if is_auth_error(status, body):
            status, body = post(msg, token(stale=tok))
    except SystemExit as e:  # silent SSO failed: the keychain ID token expired too
        body, status = {"code": "AUTH", "message": f"{e}. Run: python {Path(sf_mcp_auth.__file__)} --login, then /mcp reconnect"}, 0
    except Exception as e:
        body, status = {"code": "PROXY", "message": f"{type(e).__name__}: {e}"}, 0
    if rid is None:  # notification: nothing to answer
        return
    if isinstance(body, dict) and body.get("jsonrpc"):
        send(body)
        return
    detail = body if isinstance(body, dict) else {"body": str(body)[:500]}
    send({"jsonrpc": "2.0", "id": rid, "error": {
        "code": -32603,
        "message": f"Snowflake error {detail.get('code', status)}: {detail.get('message', 'no JSON-RPC response')}"
                   + (f" (request_id {detail['request_id']})" if detail.get("request_id") else ""),
        "data": {"http_status": status, **detail}}})


def main() -> None:
    log(f"proxying {URL}")
    with ThreadPoolExecutor(8) as pool:
        for line in sys.stdin:
            if not line.strip():
                continue
            try:
                msg = json.loads(line)
            except ValueError:
                log(f"ignoring non-JSON input: {line[:200]}")
                continue
            pool.submit(handle, msg)


if __name__ == "__main__":
    main()
