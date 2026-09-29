"""Snowflake SSO session token for Snowflake-managed MCP servers (Claude Code `headersHelper`).

    python sf_mcp_auth.py                 # print {"Authorization": "Snowflake Token=\"...\""}
    python sf_mcp_auth.py --login         # interactive SSO (opens the browser) to seed the ID-token cache
    python sf_mcp_auth.py --check <url>   # get a token and call tools/list on an MCP server

How it works: a Snowflake-managed MCP endpoint accepts a regular Snowflake *session token* in
`Authorization: Snowflake Token="<token>"` (a `Bearer` header is treated as OAuth/PAT and rejected).
We get one by logging in with EXTERNALBROWSER. With client_store_temporary_credential and the
connector's `secure-local-storage` extra, the SSO ID token is kept in the OS keychain, so later
logins are silent (~1 s) until it expires (~4 h; needs ALLOW_ID_TOKEN = TRUE on the account), after
which `--login` is needed again. The session token is cached in a 0600 file for TOKEN_TTL and is
keyed by account + user + role. Claude Code re-runs a headersHelper on connect and on 401/403.

Env: SF_ACCOUNT (required), SF_USER (required), SF_ROLE (optional, default role if unset),
     SF_HOST (optional host override, e.g. privatelink), SF_MCP_CACHE (optional cache file path).
"""
import argparse
import hashlib
import json
import os
import sys
import threading
import time
from pathlib import Path

import snowflake.connector

SCRIPT = "sf_mcp_auth.py"
LOGIN_HINT = f"run `python {SCRIPT} --login`"

ACCOUNT = os.environ.get("SF_ACCOUNT", "").strip()
USER = os.environ.get("SF_USER", "").strip()
ROLE = os.environ.get("SF_ROLE", "").strip() or None  # None -> the user's default role
_HOST_OVERRIDE = os.environ.get("SF_HOST", "").strip()
HOST = (_HOST_OVERRIDE.removeprefix("https://").rstrip("/") if _HOST_OVERRIDE
        else f"{ACCOUNT.replace('_', '-')}.snowflakecomputing.com").lower()
BASE_URL = f"https://{HOST}"

# Cache identity: switching account / user / role must never reuse another identity's token.
CACHE_KEY = {"account": ACCOUNT.lower(), "host": HOST, "user": USER.lower(), "role": (ROLE or "").upper()}
_KEY_HASH = hashlib.sha256(json.dumps(CACHE_KEY, sort_keys=True).encode()).hexdigest()[:12]
CACHE_FILE = Path(os.environ.get("SF_MCP_CACHE") or Path.home() / f".snowflake/mcp_session_{_KEY_HASH}.json")

TOKEN_TTL = 50 * 60  # session tokens are valid for 1 h
SILENT_LOGIN_TIMEOUT = 8  # Claude Code kills a headersHelper after ~10 s


def require_config() -> None:
    missing = [name for name, value in (("SF_ACCOUNT", ACCOUNT), ("SF_USER", USER)) if not value]
    if missing:
        sys.exit(f"{SCRIPT}: missing required environment variable(s): {', '.join(missing)}. "
                 "Set SF_ACCOUNT (account identifier, e.g. myorg-myaccount or xy12345.eu-west-1) and "
                 "SF_USER (your Snowflake login name, e.g. you@example.com); SF_ROLE is optional.")


def _write_cache(data: dict) -> None:
    CACHE_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp = CACHE_FILE.with_name(f".{CACHE_FILE.name}.{os.getpid()}.tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(data, f)
    os.chmod(tmp, 0o600)
    os.replace(tmp, CACHE_FILE)  # atomic: a concurrent reader never sees a half-written file


def login() -> str:
    require_config()
    kwargs = dict(account=ACCOUNT, user=USER, authenticator="externalbrowser",
                  client_store_temporary_credential=True,  # reuse the keychain ID token -> no browser
                  server_session_keep_alive=True)  # don't log the session out when this process exits
    if ROLE:
        kwargs["role"] = ROLE
    if _HOST_OVERRIDE:
        kwargs["host"] = HOST
    conn = snowflake.connector.connect(**kwargs)
    token = conn.rest.token
    _write_cache({"token": token, "issued": time.time(), **CACHE_KEY})
    return token


def cached_token() -> str | None:
    try:
        c = json.loads(CACHE_FILE.read_text())
        fresh = time.time() - float(c["issued"]) < TOKEN_TTL
        same_identity = all(c.get(k) == v for k, v in CACHE_KEY.items())
        return c["token"] if fresh and same_identity and c.get("token") else None
    except (OSError, ValueError, KeyError, TypeError):
        return None


def silent_token() -> str:
    """Login in a daemon thread so an expired ID token (-> browser prompt) can't hang the caller."""
    require_config()
    out: dict = {}

    def run():
        try:
            out["token"] = login()
        except Exception as e:  # noqa: BLE001 - reported below
            out["error"] = e

    t = threading.Thread(target=run, daemon=True)
    t.start()
    t.join(SILENT_LOGIN_TIMEOUT)
    if "token" in out:
        return out["token"]
    reason = f" ({type(out['error']).__name__}: {out['error']})" if "error" in out else ""
    sys.exit(f"{SCRIPT}: silent SSO login failed{reason}; {LOGIN_HINT} and reconnect the MCP server (/mcp)")


def get_token() -> str:
    return cached_token() or silent_token()


def header(token: str) -> dict:
    return {"Authorization": f'Snowflake Token="{token}"'}


def check(url: str) -> int:
    import requests

    r = requests.post(url, timeout=60, json={"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}},
                      headers={**header(get_token()), "Accept": "application/json, text/event-stream",
                               "Content-Type": "application/json"})
    text = r.text
    if text.lstrip().startswith("event:") or "\ndata:" in text:  # SSE framing: take the last data line
        data = [line[5:].strip() for line in text.splitlines() if line.startswith("data:")]
        text = data[-1] if data else ""
    try:
        body = json.loads(text)
    except ValueError:
        body = None
    if isinstance(body, dict) and "result" in body:
        tools = body["result"].get("tools", [])
        print(f"OK: HTTP {r.status_code}, {len(tools)} tool(s) on {url}")
        for tool in tools:
            first_line = next(iter((tool.get("description") or "").strip().splitlines()), "")
            print(f"  - {tool.get('name')}: {first_line[:100]}")
        return 0
    print(f"FAILED: HTTP {r.status_code}: {r.text[:1000]}", file=sys.stderr)
    return 1


def main() -> None:
    p = argparse.ArgumentParser(
        prog=SCRIPT,
        description="Print a Snowflake session-token Authorization header for Snowflake-managed MCP servers "
                    "(for use as a Claude Code headersHelper).",
        epilog="Env: SF_ACCOUNT and SF_USER (required), SF_ROLE, SF_HOST, SF_MCP_CACHE (optional).")
    g = p.add_mutually_exclusive_group()
    g.add_argument("--login", action="store_true", help="interactive SSO login (opens the browser once)")
    g.add_argument("--check", metavar="URL", help="call tools/list on this MCP server URL")
    args = p.parse_args()
    require_config()

    if args.login:
        CACHE_FILE.unlink(missing_ok=True)
        login()
        print(f"logged in as {USER} / {ROLE or '(default role)'} on {HOST}; token cached in {CACHE_FILE}")
    elif args.check:
        sys.exit(check(args.check))
    else:
        # Keep stdout clean for the JSON header: the connector may print login chatter to stdout.
        real_stdout, sys.stdout = sys.stdout, sys.stderr
        token = get_token()
        real_stdout.write(json.dumps(header(token)) + "\n")
        real_stdout.flush()


if __name__ == "__main__":
    main()
