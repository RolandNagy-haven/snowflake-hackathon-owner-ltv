# Snowflake MCP with your own SSO login

Two small Python scripts that let Claude Code (or any MCP client) talk to
Snowflake-managed MCP servers
as **you**, using your normal browser SSO login. There's no PAT, no key pair and no OAuth security
integration, so an admin doesn't have to set anything up.

- `sf_mcp_proxy.py` is a local stdio MCP server that forwards to the Snowflake endpoint and renews the session
  token when it expires. **This is the recommended setup.**
- `sf_mcp_auth.py` logs in (EXTERNALBROWSER SSO), caches the session token, and prints it as an HTTP header.
  You can use it directly as a Claude Code `headersHelper`, but only for short sessions.

## When to use it (and when not)

**Use it** for local development. You get zero admin work, each developer uses their own identity and role,
and access follows your existing SSO.

**Don't use it** in production, for shared or service use, CI, or anything unattended. Use a PAT, key-pair
JWT or an OAuth security integration there. Those usually need an admin (a network policy for PATs,
`CREATE SECURITY INTEGRATION`, registering public keys), which is exactly the step this project avoids
for dev.

## Requirements

- Python 3.10+
- A Snowflake user that can sign in with SSO (EXTERNALBROWSER) and a desktop browser
- A role with `USAGE` on the MCP server and the grants its tools need (see Troubleshooting)
- Recommended: the account parameter `ALLOW_ID_TOKEN = TRUE`, which gives silent re-login (see below)

## Install

```bash
git clone <this repo> sf-mcp-auth && cd sf-mcp-auth
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

The `secure-local-storage` extra of `snowflake-connector-python` is what stores the SSO ID token in the OS keychain.

## One-time login

```bash
export SF_ACCOUNT=<account>            # e.g. myorg-myaccount or xy12345.eu-west-1
export SF_USER=you@example.com
export SF_ROLE=MY_ROLE                 # optional; your default role if unset
.venv/bin/python sf_mcp_auth.py --login
```

This opens the browser once. The connector keeps the SSO ID token in the OS keychain, so later logins are
silent (~1 s) for about 4 hours, until the ID token expires. After that, run `--login` again.

- Silent re-login needs the account parameter `ALLOW_ID_TOKEN = TRUE`. An admin sets it once, and it's often
  already on. Without it everything still works, but each new login opens the browser. Inside Claude Code
  that login fails fast (see below), so you have to run `--login` about every hour.
- Run `--login` with **the same Python interpreter your MCP config uses**. Another venv or Python binary
  may not see the keychain entry.

## Configure Claude Code

MCP server URLs look like this:

```
https://<account>.snowflakecomputing.com/api/v2/databases/MY_DB/schemas/MY_SCHEMA/mcp-servers/MY_MCP_SERVER
```

(Use `-` instead of `_` in the account part of the host.)

### Recommended: the proxy (stdio)

`.mcp.json`:

```json
{
  "mcpServers": {
    "my-snowflake-mcp": {
      "type": "stdio",
      "command": ".venv/bin/python",
      "args": [
        "sf_mcp_proxy.py",
        "https://<account>.snowflakecomputing.com/api/v2/databases/MY_DB/schemas/MY_SCHEMA/mcp-servers/MY_MCP_SERVER"
      ],
      "env": {
        "SF_ACCOUNT": "<account>",
        "SF_USER": "you@example.com",
        "SF_ROLE": "MY_ROLE"
      }
    }
  }
}
```

Run one proxy entry per server URL. The same thing from the CLI:

```bash
claude mcp add my-snowflake-mcp --scope project \
  -e SF_ACCOUNT=<account> -e SF_USER=you@example.com -e SF_ROLE=MY_ROLE \
  -- .venv/bin/python sf_mcp_proxy.py \
     https://<account>.snowflakecomputing.com/api/v2/databases/MY_DB/schemas/MY_SCHEMA/mcp-servers/MY_MCP_SERVER
```

### Simple: headersHelper only (HTTP)

```json
{
  "mcpServers": {
    "my-snowflake-mcp": {
      "type": "http",
      "url": "https://<account>.snowflakecomputing.com/api/v2/databases/MY_DB/schemas/MY_SCHEMA/mcp-servers/MY_MCP_SERVER",
      "headersHelper": "SF_ACCOUNT=<account> SF_USER=you@example.com SF_ROLE=MY_ROLE .venv/bin/python sf_mcp_auth.py"
    }
  }
}
```

The same thing from the CLI:

```bash
claude mcp add-json my-snowflake-mcp --scope project '{"type":"http","url":"https://<account>.snowflakecomputing.com/api/v2/databases/MY_DB/schemas/MY_SCHEMA/mcp-servers/MY_MCP_SERVER","headersHelper":"SF_ACCOUNT=<account> SF_USER=you@example.com SF_ROLE=MY_ROLE .venv/bin/python sf_mcp_auth.py"}'
```

- `headersHelper` is a shell command. Set the env vars inline as shown, or export them in the shell that starts
  Claude Code.
- Claude Code kills a helper after about 10 s. So if a login would need the browser, the helper gives up after
  8 s and prints a hint instead of hanging.
- **This setup breaks after about an hour** (see [Why the proxy exists](#why-the-proxy-exists)). You then have
  to reconnect with `/mcp`. It's fine for short sessions.

### Paths

Relative paths in `.mcp.json` resolve against the directory Claude Code was **started from**, not the
project root. Relative paths work if you always start Claude Code from the same directory. Otherwise use
absolute paths. `${CLAUDE_PROJECT_DIR}` is **not** expanded in MCP config.

### Other MCP clients

The proxy is a plain stdio MCP server, so any client that can launch stdio servers can use it. Give it the
same command, args and env.

## Verify

```bash
SF_ACCOUNT=<account> SF_USER=you@example.com SF_ROLE=MY_ROLE \
  .venv/bin/python sf_mcp_auth.py --check \
  https://<account>.snowflakecomputing.com/api/v2/databases/MY_DB/schemas/MY_SCHEMA/mcp-servers/MY_MCP_SERVER
```

This makes a harmless `tools/list` call and prints the tools, for example `OK: HTTP 200, 3 tool(s) on ...`.
It exits non-zero on failure.

To test the proxy by hand, send newline-delimited JSON-RPC on stdin:

```bash
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}' \
              '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  | .venv/bin/python sf_mcp_proxy.py <server url>
```

## Environment variables

| Variable       | Required | Meaning |
|----------------|----------|---------|
| `SF_ACCOUNT`   | yes      | Account identifier, e.g. `myorg-myaccount` or `xy12345.eu-west-1`. The host is `https://<account>.snowflakecomputing.com` with `_` replaced by `-`. |
| `SF_USER`      | yes      | Your Snowflake login name, e.g. `you@example.com`. |
| `SF_ROLE`      | no       | Role for the session. If unset, your default role is used. |
| `SF_HOST`      | no       | Host override for unusual setups (e.g. privatelink): `xy12345.eu-west-1.privatelink.snowflakecomputing.com`. |
| `SF_MCP_CACHE` | no       | Token cache file. The default is `~/.snowflake/mcp_session_<hash>.json`, with one file per account + user + role. |

## Troubleshooting

- **"malformed result" / "failed schema validation" on every tool call after about an hour.** You're using the
  headersHelper-only setup and the session token has expired. Switch to the proxy, or reconnect with `/mcp`.
- **`silent SSO login failed; run python sf_mcp_auth.py --login`.** The keychain ID token has expired (after
  about 4 h), or `ALLOW_ID_TOKEN` is off. Run `--login` with the same interpreter as your MCP config, then
  reconnect with `/mcp`.
- **`--login` works but Claude Code still says to log in.** Your MCP config uses a different Python or venv,
  which doesn't see the keychain entry. Run `--login` with exactly the `command` from `.mcp.json`.
- **`missing required environment variable(s)`.** The env vars aren't reaching the process. For the proxy, use
  the `env` block. For the helper, set them inline in `headersHelper` or export them before starting Claude Code.
- **Permission or "does not exist or not authorized" errors.** The role needs `USAGE` on the MCP server
  (`GRANT USAGE ON MCP SERVER MY_DB.MY_SCHEMA.MY_MCP_SERVER TO ROLE MY_ROLE`) and the grants on the objects
  behind its tools (database/schema usage, the semantic views, Cortex Search services, agents, procedures,
  warehouse, ...). Check which role you're actually using with `SF_ROLE`.
- **`Bearer` header rejected.** That's expected. Snowflake treats `Bearer` as OAuth/PAT. A session token must be
  sent as `Authorization: Snowflake Token="<token>"`, and these scripts do that.

## Why the proxy exists

Snowflake-managed MCP endpoints accept a normal Snowflake session token as
`Authorization: Snowflake Token="<token>"`. A session token expires **1 hour** after login. After that the
endpoint doesn't return a 401 or a JSON-RPC error. It returns **HTTP 200** with a plain REST error body:

```json
{"code":"390112","message":"Your session has expired. Please login again.","request_id":"...","error_code":"390112"}
```

Claude Code only re-runs a `headersHelper` when it connects or gets a 401/403. So after an hour every tool call
fails with a "malformed result" error until you reconnect.

The proxy runs as a stdio MCP server and forwards each JSON-RPC message over HTTPS. When it sees a
session/token error (codes 390111, 390112, 390113, 390114, 390318, or HTTP 401/403), it logs in again
silently, once, and retries. Concurrent requests share one re-login. Any reply that still isn't JSON-RPC is
turned into a proper JSON-RPC error with Snowflake's code, message and `request_id`, so the client shows a
readable error. The proxy writes its logs to stderr.

## Security notes

- The session token is cached in `~/.snowflake/` (or `SF_MCP_CACHE`) with mode `0600`, for up to 50 minutes.
  The SSO ID token lives in the OS keychain, managed by the Snowflake connector.
- The session token can do **anything your role can do**, not just call MCP tools. Treat the cache file like a
  password, use a least-privilege role in `SF_ROLE` where you can, and never commit a cache file
  (`.gitignore` covers the default names).
- This is a per-user dev convenience. For shared, production or unattended use, use a PAT, key-pair auth or OAuth.
