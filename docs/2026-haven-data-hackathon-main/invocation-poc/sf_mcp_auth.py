"""Claude Code `headersHelper` for Snowflake-managed MCP servers, backed by our SSO session.

    python invocation-poc/sf_mcp_auth.py            # print {"Authorization": "Snowflake Token=\"...\""}
    python invocation-poc/sf_mcp_auth.py --login    # interactive SSO (browser) to seed the ID-token cache
    python invocation-poc/sf_mcp_auth.py --check    # mint/reuse a token and call tools/list on the POC server

How it works: the Snowflake-managed MCP endpoint accepts a regular Snowflake *session token* in
`Authorization: Snowflake Token="<token>"` (a `Bearer` header is treated as OAuth and rejected).
We get one by logging in with EXTERNALBROWSER; the connector keeps the SSO ID token in the macOS
keychain (account has ALLOW_ID_TOKEN=true), so later logins are silent (~1s) until it expires (~4h),
after which `--login` is needed again. The session token is cached in CACHE_FILE (0600) and reused
for TOKEN_TTL; Claude Code re-runs this helper on connect and on any 401/403, so an expired token
is replaced automatically.

Env (optional): SF_USER, SF_ROLE, SF_ACCOUNT, SF_MCP_CACHE.
"""
import json
import os
import sys
import threading
import time
from pathlib import Path

import snowflake.connector

ACCOUNT = os.environ.get("SF_ACCOUNT", "bd78472.eu-west-1")
USER = os.environ.get("SF_USER", "peter.zentai@haven.com")
ROLE = os.environ.get("SF_ROLE", "HAVEN_DATA_SCIENCE_DEV")
# one cache file per role, so MCP servers used with different roles don't keep replacing each other's token
CACHE_FILE = Path(os.environ.get("SF_MCP_CACHE", Path.home() / f".snowflake/mcp_session_cache_{ROLE.lower()}.json"))
TOKEN_TTL = 50 * 60  # session tokens are valid for 1h
SILENT_LOGIN_TIMEOUT = 8  # Claude Code kills the helper after 10s
POC_URL = (f"https://{ACCOUNT.replace('_', '-')}.snowflakecomputing.com/api/v2/databases/"
           "HAVEN_DATA_SCIENCE_DEV/schemas/PETERZENTAI_LOCAL/mcp-servers/INVOCATION_POC_MCP")


def login() -> str:
    conn = snowflake.connector.connect(
        account=ACCOUNT, user=USER, role=ROLE, authenticator="externalbrowser",
        client_store_temporary_credential=True,  # reuse the keychain ID token -> no browser
        server_session_keep_alive=True,  # don't log the session out when this process exits
    )
    token = conn.rest.token
    CACHE_FILE.parent.mkdir(parents=True, exist_ok=True)
    CACHE_FILE.touch(mode=0o600, exist_ok=True)
    CACHE_FILE.write_text(json.dumps({"token": token, "issued": time.time(), "user": USER, "role": ROLE}))
    return token


def cached_token() -> str | None:
    try:
        c = json.loads(CACHE_FILE.read_text())
    except (OSError, ValueError):
        return None
    fresh = time.time() - c["issued"] < TOKEN_TTL and (c["user"], c["role"]) == (USER, ROLE)
    return c["token"] if fresh else None


def silent_token() -> str:
    """Login in a daemon thread so an expired ID token (-> browser prompt) can't hang the helper."""
    out: dict = {}
    t = threading.Thread(target=lambda: out.update(token=login()), daemon=True)
    t.start()
    t.join(SILENT_LOGIN_TIMEOUT)
    if "token" not in out:
        sys.exit(f"sf_mcp_auth: silent SSO login failed; run `python {__file__} --login` and reconnect (/mcp)")
    return out["token"]


def header(token: str) -> dict:
    return {"Authorization": f'Snowflake Token="{token}"'}


def check() -> None:
    import requests

    r = requests.post(POC_URL, headers={**header(cached_token() or silent_token()), "Accept": "application/json"},
                      json={"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                            "params": {"name": "hello_world_tool", "arguments": {"name": "check"}}})
    print(r.status_code, r.text)


if __name__ == "__main__":
    if "--login" in sys.argv:
        CACHE_FILE.unlink(missing_ok=True)
        login()
        print(f"logged in as {USER} / {ROLE}; token cached in {CACHE_FILE}")
    elif "--check" in sys.argv:
        check()
    else:
        print(json.dumps(header(cached_token() or silent_token())))
