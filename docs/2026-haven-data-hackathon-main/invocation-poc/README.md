# invocation-poc — stored procedure as an MCP tool, called from Claude Code

| File | What |
|---|---|
| `sql/01_hello_world_tool.sql` | `HELLO_WORLD_TOOL(NAME)` stored procedure (caller's rights; echoes user/role) |
| `sql/02_mcp_server.sql` | `INVOCATION_POC_MCP` Snowflake-managed MCP server, procedure exposed as a `GENERIC` tool |
| `sql/03_semantic_views_mcp.sql` | `SEMANTIC_VIEWS_MCP`: `fnb_retail_analyst` + `footfall_analyst` (Cortex Analyst over FNB_RETAIL_SV / FOOTFALL_ARRIVALS_SV_V3) and read-only `run_sql` |
| `sql/04_hello_world_pro_agent.sql` | `HELLO_WORLD_PRO_AGENT`: Cortex Agent whose only tools come from `SEMANTIC_VIEWS_MCP` via `mcp_servers:` |
| `sql/05_hello_world_pro_mcp.sql` | `HELLO_WORLD_PRO_MCP`: exposes `HELLO_WORLD_PRO_AGENT` as one `CORTEX_AGENT_RUN` tool |
| `sql/99_teardown.sql` | drops everything |
| `deploy.py` | `python invocation-poc/deploy.py [prefix...]` (default: all `0*.sql`) |
| `sf_mcp_auth.py` | Claude Code `headersHelper`: turns our SSO login into a Snowflake session token |
| `mcp.json` | Claude Code MCP entry (registered at local scope with `claude mcp add-json`) |

Endpoint: `https://bd78472.eu-west-1.snowflakecomputing.com/api/v2/databases/HAVEN_DATA_SCIENCE_DEV/schemas/PETERZENTAI_LOCAL/mcp-servers/INVOCATION_POC_MCP`

## Auth findings
- `Authorization: Snowflake Token="<session token>"` → **200**. A normal connector session token works.
- `Authorization: Bearer <session token>` → 401 `Invalid OAuth access token`. Bearer is for OAuth tokens and PATs.
- The helper logs in with EXTERNALBROWSER. The SSO ID token is kept in the keychain (`ALLOW_ID_TOKEN=true`), so later
  logins are silent (~1s) for about 4h. The session token is cached for 50 min in `~/.snowflake/mcp_session_cache.json` (0600).
- Claude Code re-runs the helper on connect and on 401/403. When the ID token expires, run
  `python invocation-poc/sf_mcp_auth.py --login` and reconnect via `/mcp`.
- Smoke test: `python invocation-poc/sf_mcp_auth.py --check`
- Other options (not tested here): a PAT sent as `Bearer` (static and long-lived), or Snowflake OAuth. OAuth needs a security integration (CREATE INTEGRATION privilege)
  plus `claude mcp add --client-id ... --client-secret --callback-port ...`.

## SEMANTIC_VIEWS_MCP findings
- The analyst tools take `{"message": "..."}` and return interpretation text plus a `SELECT * FROM SEMANTIC_VIEW(...)` statement, no rows.
  Run the statement with `run_sql` (`{"sql": "..."}`).
- `run_sql` also handles `DESCRIBE SEMANTIC VIEW`, `SHOW SEMANTIC METRICS/DIMENSIONS IN <view>` and hand-written `SEMANTIC_VIEW(...)` queries.
- `read_only: true` rejects writes: `CREATE TABLE` fails with the terse error `!399517!` and nothing is created.
- `run_sql` runs as the caller's role, which with our SSO helper is HAVEN_DATA_SCIENCE_DEV, so it can read anything that role can.
  Querying a semantic view needs only SELECT on the view, not on its base tables. A role with SELECT on just the two views
  (set via `SF_ROLE` for the helper) would therefore confine `run_sql` to them.

## HELLO_WORLD_PRO_AGENT findings (agent -> Snowflake-managed MCP server)
- The agent spec has no `tools:` section, only `mcp_servers: - server_spec: {name: <db.schema.MCP_SERVER>}`. The docs describe this for
  EXTERNAL MCP servers, but it also accepts a Snowflake-managed (`CREATE MCP SERVER`) one.
- Tools are discovered at run time and prefixed with the server name: `semantic_views_mcp_fnb_retail_analyst`,
  `semantic_views_mcp_footfall_analyst`, `semantic_views_mcp_run_sql`. The run response lists them as tool_use `type: server_mcp`, `client_side_execute: false`.
- Auth: no API integration, OAuth or credentials. Snowflake calls the server internally, and the SQL runs as the user and role
  calling the agent (query history shows PETERZENTAI / HAVEN_DATA_SCIENCE_DEV). The agent caller still needs USAGE on the MCP server and the underlying grants.
- Answer tables built from MCP results don't embed rows: `table` has `tool_use_id` = the run_sql `query_id` and no `result_set`.
  The `cortex-agent` skill script now resolves these from the matching tool_result.
- Try it: `python .claude/skills/cortex-agent/cortex_agent.py "..." --agent HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.HELLO_WORLD_PRO_AGENT --show-sql`

## HELLO_WORLD_PRO_MCP findings (agent exposed over MCP)
- The agent is on its own server. If it were on SEMANTIC_VIEWS_MCP it would see itself as a tool (the recursion cap is 10).
- The tool input is `{"text": "..."}`, not `message`. Each call is a single stateless agent run with no thread; pass full context every time.
- The call takes ~45 s. The result is a single text block holding the whole agent response JSON (~8 KB):
  text, tool_use/tool_result, thinking, table (row reference only), suggested_queries. The final `text` parts carry the answer, with a markdown table.
- Claude Code: registered as `snowflake-hello-world-pro`, same `headersHelper` SSO auth as the other servers.
