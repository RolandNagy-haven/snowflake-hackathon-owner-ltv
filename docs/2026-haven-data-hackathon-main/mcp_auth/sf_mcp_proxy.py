"""stdio <-> Snowflake-managed MCP server proxy with session-token refresh.

    python sf_mcp_proxy.py <mcp server url>

    .mcp.json: {"type": "stdio", "command": "<python>", "args": ["<path>/sf_mcp_proxy.py", "<mcp server url>"],
                "env": {"SF_ACCOUNT": "...", "SF_USER": "...", "SF_ROLE": "..."}}

Why: a Snowflake session token expires 1 h after login. The MCP endpoint then answers HTTP 200 with a plain
REST error body ({"code": "390112", "message": "Your session has expired..."}), not a JSON-RPC message and not a
401, so a client never re-runs its headersHelper and every later call fails with "malformed result".
This proxy speaks MCP over stdio (one JSON-RPC message per line), forwards each message over HTTPS with a
session token from sf_mcp_auth, and on a session/token error logs in again (silent SSO via the keychain
ID token) and retries once. Any reply that still isn't JSON-RPC is turned into a JSON-RPC error that carries
Snowflake's code, message and request_id. Requests run concurrently; logs go to stderr.
One proxy process per server URL. Env vars: see sf_mcp_auth.py.
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
USAGE = "usage: python sf_mcp_proxy.py <mcp server url>   (env: SF_ACCOUNT, SF_USER, optional SF_ROLE)"
URL = ""
_OUT = sys.stdout  # JSON-RPC channel; everything else (incl. connector chatter) goes to stderr
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
        _OUT.write(json.dumps(obj) + "\n")
        _OUT.flush()


def parse(text: str):
    if "\ndata:" in text or text.lstrip().startswith("event:"):
        data = [line[5:].strip() for line in text.splitlines() if line.startswith("data:")]
        text = data[-1] if data else ""
    return json.loads(text) if text.strip() else None


def post(msg, tok: str):
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


def handle(msg) -> None:
    rid = msg.get("id") if isinstance(msg, dict) else None
    try:
        tok = token()
        status, body = post(msg, tok)
        if is_auth_error(status, body):
            status, body = post(msg, token(stale=tok))
    except SystemExit as e:  # silent SSO failed (e.g. the keychain ID token expired too); message has the hint
        body, status = {"code": "AUTH", "message": str(e)}, 0
    except Exception as e:  # noqa: BLE001
        body, status = {"code": "PROXY", "message": f"{type(e).__name__}: {e}"}, 0
    if rid is None:  # notification: nothing to answer
        if isinstance(body, dict) and body.get("code") in ("AUTH", "PROXY"):
            log(body["message"])
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


def safe_handle(msg) -> None:
    try:
        handle(msg)
    except Exception as e:  # noqa: BLE001 - never lose an exception silently inside the pool
        log(f"unhandled {type(e).__name__}: {e}")


def main() -> None:
    global URL
    if len(sys.argv) != 2 or sys.argv[1] in ("-h", "--help") or not sys.argv[1].startswith("https://"):
        print(USAGE, file=sys.stderr)
        sys.exit(0 if len(sys.argv) == 2 and sys.argv[1] in ("-h", "--help") else 2)
    URL = sys.argv[1]
    sf_mcp_auth.require_config()
    sys.stdout = sys.stderr  # keep stray prints (e.g. from the connector) off the JSON-RPC stream
    log(f"proxying {URL} as {sf_mcp_auth.USER} / {sf_mcp_auth.ROLE or '(default role)'}")
    with ThreadPoolExecutor(8) as pool:
        for line in sys.stdin:
            if not line.strip():
                continue
            try:
                msg = json.loads(line)
            except ValueError:
                log(f"ignoring non-JSON input: {line[:200]}")
                continue
            pool.submit(safe_handle, msg)


if __name__ == "__main__":
    main()
