# sv-to-agent: ways for a Cortex Agent to use a semantic view

Everything lives in `NEXUS_HACKATHON_DB.PZ_CORTEX_SPIKE` and is owned by `NEXUS_SPIKE`. Agent tools run on the `NEXUS_HACKATHON_WH` warehouse.

| Script | Object | What it shows |
|---|---|---|
| `sql/01_footfall_semantic_view.sql` | `FOOTFALL_ARRIVALS_SV_V3` + 3 helper views | Includes `semantic-views/footfall/FOOTFALL_ARRIVALS_SV_V3.sql` at deploy time and retargets it (single source of truth) |
| `sql/02_agent_analyst_tool.sql` | `SV_AGENT_1_ANALYST` | The semantic view **is** the tool: `cortex_analyst_text_to_sql` + `semantic_view` resource |
| `sql/03_run_sql_mcp.sql` | `SV_SQL_MCP` | Managed MCP server with one read-only `SYSTEM_EXECUTE_SQL` tool, `run_sql` |
| `sql/04_agent_run_sql.sql` | `SV_AGENT_2_RUN_SQL` | No Analyst. Gets `run_sql` via `mcp_servers`; its own model discovers the view (`DESCRIBE SEMANTIC VIEW`) and writes `SEMANTIC_VIEW(...)` queries |
| `sql/06_agent_code_minimal.sql` | `SV_AGENT_4_CODE_MINIMAL` | Minimal `code_toolset_all` for experiments: `always_allow`; `instructions.system` names only the semantic view |
| `sql/07_agent_code_pandas.sql` | `SV_AGENT_5_PANDAS` | Code toolset used like local Claude Code: Python opens a Snowpark session on the sandbox's `default` connection, pulls `SEMANTIC_VIEW(...)` into pandas and computes there. Rules in `instructions.system` |
| `sql/08_agent_analyst_python.sql` | `SV_AGENT_6_ANALYST_PYTHON` | Combined route: Cortex Analyst for everything SQL can express, the single-tool `code_execution` sandbox only for Python-only analysis. Documented fields only |
| `sql/09_agent_delegation.sql` | `AGENT_CALL_LOG`, `RUN_AGENT`, `ASK_PANDAS_AGENT_THREADED` | Threaded agent-to-agent call (copied from `agent-orchestration/sql/02_agent_delegation.sql`): caller's-rights procedure running agent 5 via `DATA_AGENT_RUN`, continuing its thread from a `thread_ref` |
| `sql/10_pandas_agent_mcp.sql` | `SV_PANDAS_AGENT_MCP` | MCP server exposing that procedure as the `GENERIC` tool `ask_pandas_agent(question, thread_ref)`, for agents and for Claude Code |
| `sql/11_agent_orchestrator.sql` | `SV_AGENT_7_ORCHESTRATOR` | Front-door agent (Opus 5.5) with no data tools; delegates to agent 5 over MCP, continuing its thread for follow-ups |
| `mcp.json` | | Claude Code entry for `SV_PANDAS_AGENT_MCP` (registered at local scope as `snowflake-pandas-agent`) |
| `sql/99_teardown.sql` | | Drops everything (keeps `AGENT_CALL_LOG`) |

```sh
python sv-to-agent/deploy.py                 # 01..11
python sv-to-agent/deploy.py 04 07           # by prefix
python sv-to-agent/deploy.py 01 --dry-run    # rendered SQL
python sv-to-agent/deploy.py 99_teardown

python .claude/skills/cortex-agent/cortex_agent.py "question" --show-sql \
  --agent NEXUS_HACKATHON_DB.PZ_CORTEX_SPIKE.SV_AGENT_2_RUN_SQL
```

## Comparison of all agent setups

Tests on 2026-09-28. Q1 = median and std dev of daily guests per park, Aug 2025; Q2 = per-park arrivals/leavers correlation
plus weekday changeover, Jul-Aug 2025; Q3 = weekday OLS regression of daily total guests, Aug 2025; R = average guests
per day by region plus the top park for arrivals, Aug 2025. Agent 4 (`SV_AGENT_4_CODE_MINIMAL`) is left out: a dead end. Agent 3 (`code_toolset_all` restricted to
`snowflake_sql_execute`) was removed: it added nothing over agent 2.

| | PoC `HELLO_WORLD_PRO_AGENT` | 1 `SV_AGENT_1_ANALYST` | 2 `SV_AGENT_2_RUN_SQL` | 5 `SV_AGENT_5_PANDAS` | 6 `SV_AGENT_6_ANALYST_PYTHON` |
|---|---|---|---|---|---|
| **Definition** | `invocation-poc/sql/04` | `sql/02` | `sql/03` + `sql/04` | `sql/07` | `sql/08` |
| **Tools in spec** | none; `mcp_servers: SEMANTIC_VIEWS_MCP` | `cortex_analyst_text_to_sql` | none; `mcp_servers: SV_SQL_MCP` | `code_toolset_all` | `cortex_analyst_text_to_sql` + `code_execution` |
| **Tools at run time** | 2 × MCP Cortex Analyst (`CORTEX_ANALYST_MESSAGE`) + MCP `run_sql` | Analyst + auto-added `system_execute_sql` (+ `data_to_chart`) | MCP `run_sql` (`SYSTEM_EXECUTE_SQL`) | bash + Python with Snowpark | Analyst + auto `system_execute_sql` + Python sandbox |
| **Who writes the SQL** | Cortex Analyst | Cortex Analyst | Agent model, after `DESCRIBE SEMANTIC VIEW` | Agent model in Python, after a scripted `DESCRIBE` | Cortex Analyst |
| **Where calculations happen** | SQL | SQL (Analyst writes `MEDIAN`/`CORR` around `SEMANTIC_VIEW`) | SQL | pandas / numpy / scipy | SQL; Python only when needed |
| **How Python gets the data** | — | — | — | Its own Snowpark session, `connection_name='default'` | The model copies result rows into its script by hand (tens of rows; truncated at ~2k) |
| **Read-only** | Enforced (`read_only: true` on the MCP tool) | Yes (Analyst generates SELECTs) | Enforced (`read_only: true`) | **No**; the session has the caller's full role | Yes |
| **Instructions that work** | `orchestration`, `response` | `orchestration`, `response` | `orchestration`, `response` | **only `system`** | `orchestration`, `response` |
| **Undocumented parts** | Managed MCP server in `mcp_servers` (docs only cover external) | none | Same as PoC; native `system_execute_sql` is "not enabled on your account" | `instructions.system` + the sandbox's `default` connection | none |
| **Editable in Snowsight** | Yes | Yes | Yes | No (same) | Yes |
| **Model** | auto → Opus 4.8 | auto → Opus 4.8 | auto → Opus 4.8 | **Opus 5.5** | Opus 4.8 |
| **Result format** | JSON; table parts only reference the query ID | Typed JSON, table parts + charts | Typed JSON, table parts | Markdown tables from printed output | Typed JSON, table parts + charts |
| **Test R** | ~40-47 s ✔ (F&B + footfall variant) | 48 s ✔ | 40 s, 3 calls ✔ | — | — |
| **Test Q1** | — | 65 s, 1 query + chart ✔ | — | 79 s, 2 calls ✔ | **38 s**, 1 query ✔ |
| **Test Q2** | — | 48 s; busy parks ✔, weekday avg **~5% high** (days with no guests skipped) | — | 71 s, 2 calls ✔ **zero-filled** | 137 s; busy parks ✔, weekday avg ~5% high, **claimed zero-filled** |
| **Test Q3** | — | — | — | 83 s ✔ + std err, p-values | 81 s ✔ (data copied into its script) |
| **Main gotcha** | Two MCP hops; raw JSON output when called over MCP | Analyst doesn't apply "missing day = 0" to calculations it wraps around the view | Staying on the view is instruction-only (use a narrow role) | Not read-only; relies on two undocumented features | Python only sees what the model copies over |
| **Best for** | Exposing an agent to external MCP clients | Governed Q&A: fastest, documented, charts | Transparent SQL, no second LLM | Real analysis over large pulls: stats, modelling, completeness checks | Governed Q&A plus light Python on small aggregates |

**Caller identity:** every agent runs its SQL as the caller's user and role, including the Python session in agent 5. The caller's secondary roles decide what an agent can see and find.

## Results (2026-09-28)

Same question to agents 1 and 2: "Average guests on park per day by region in August 2025, and which park had the most
arrivals?" Both returned the same numbers: North 2,574 / East 2,441 / South West 2,029, and Devon Cliffs 34,027 arrivals.

| | Agent 1: Analyst tool | Agent 2: run_sql |
|---|---|---|
| Who writes the SQL | Cortex Analyst (from the view's metadata, verified queries, custom instructions) | The agent's model, after `DESCRIBE SEMANTIC VIEW` |
| Tool calls | analyst → system_execute_sql ×2 (+ chart) | run_sql ×3 (describe + 2 queries) |
| Time | ~48 s | ~40 s |
| Orchestration model (`auto`) | claude-opus-4-8 | claude-opus-4-8 |
| Strength | Most governed: verified queries + instructions are applied | Transparent and cheap; no second LLM |

## Findings

- **`system_execute_sql` can't be declared as an agent tool on this account.** `CREATE AGENT` accepts it, but `agent:run` fails:
  with a `{type: system_execute_sql, execution_environment}` resource it returns *"system_execute_sql is not a tool enabled on your account"*,
  without a resource *"Tool resource not found"*, and other shapes fail to parse. It only appears in docs as the internal tool
  Analyst-based agents use. The workaround is agent 2: `run_sql` from a managed MCP server attached with `mcp_servers`,
  with Snowflake enforcing `read_only`.
- **`sql_connection` doesn't exist** in the docs. The `code_toolset_all` sandbox reaches Snowflake only through its built-in
  `snowflake_sql_execute` tool (SELECT/SHOW, plus stage writes). Documented `tool_resources` keys: `permission_policy`, `workspace_mounts`,
  `disabled_skills`. The single-tool `code_execution` sandbox has no data access; the agent's other SQL tools fetch the data.
- **The code toolset needs `permission_policy: always_allow`** when called from a client that can't answer approval prompts
  (the default `always_ask` stops at the first state-modifying tool). It also isn't supported when the agent is called with owner's rights.
- **Coding-agent instructions only work in `instructions.system`, which is undocumented for agent objects.** The `CREATE AGENT`
  reference and Snowsight know only `response`, `orchestration` and `sample_questions`. `system` is documented only for the
  inline `POST /api/v2/cortex/agent:run` body. A Snowsight save silently deletes `system` (seen on agent 4), so redeploy from the file.
  - Probe, one run each, rule "end every answer with BANANA": `system` was followed by plain and code agents; `orchestration`
    by the plain agent but **not** the code agent.
  - The removed agent 3 (`code_toolset_all`, SQL only) with the rules only in `orchestration` ignored them. It used the `data-discovery` skill or `cortex search` in bash and queried
    `FOOTFALL_ARRIVALS_SV_V2` in another database, and with that skill disabled the raw `HAVEN_STORE.HEADS_ON_PARK` table (a wrong measure).
  - With the rules in `system` and `orchestration` cut to one routing line, it made just `DESCRIBE SEMANTIC VIEW` plus one
    `SEMANTIC_VIEW(...)` query with `MEDIAN`/`STDDEV` in SQL, and gave the correct answer. Snowflake's own AI assistant suggested the same layout.
- **The code sandbox can open its own Snowflake session (undocumented).** It has the connector and Snowpark installed plus a
  `[default]` connection in `~/.snowflake/connections.toml` that uses an injected token, running as the caller (user, role, warehouse, secondary roles).
  `Session.builder.config('connection_name','default').create()` then `.to_pandas()` on a `SEMANTIC_VIEW(...)` query works.
  Unlike `snowflake_sql_execute`, it isn't limited to reads (a write hasn't been tested). `snowflake_sql_execute` returns results
  to the model as text only, never as sandbox files.
- **Identity:** every agent runs its SQL as the caller's role, and the caller's secondary roles decide what it can find. That's why
  a code-toolset agent could see the other schema. `NEXUS_SPIKE` alone can read every source table (`HAVEN_STORE.*`), so the
  views work for anyone with `SELECT` on the semantic view plus `USAGE` on the agent and warehouse.
- **Agent 5 (pandas) results.** First version (Opus 4.8): the median/std question took 111 s with 3 retries parsing `DESCRIBE`
  output (quoted lower-case columns, long property/value rows). It also read the custom instructions but used `guest_nights`
  (1,219 park-days) instead of the zero-filling `guests_on_park` (1,271). The harder correlation question took 154 s and 13 calls.
  Current version (`claude-opus-5-5`, which is available in Cortex Agents) has a ready-made discovery script; a required checklist of the
  custom-instruction rules that apply, written before the first query; explicit pandas re-aggregation rules (sum only additive
  metrics, pull ratios and distinct counts at the final grain, a missing row is zero); and a grid completeness check.
  | Question | Time / calls | Result |
  |---|---|---|
  | Median + std per park, Aug 2025 | 79 s / 2 | Correct; 41 parks x 31 days; noted Presthaven's σ comes from a few very low days (min 1,058) |
  | Arrivals/leavers correlation + weekday changeover, Jul-Aug 2025 | 71 s / 2 | Correct and **zero-filled**: 369 park-days per weekday (328 for Mondays, 8 in the period). Fri 3,117 / Mon 3,065 per park-day |
  | Weekday OLS regression, Aug 2025 | 83 s / 3 | Correct (Tue +892 ...; R² 0.065, adj. R² −0.169) plus std errors and p-values, all > 0.5 |
  On the changeover question it's the only agent with correct weekday averages: agents 1 and 6 (Cortex Analyst SQL) averaged only park-days
  with guest rows (Fri ~3,267, about 5% high), and agent 6 claimed they were zero-filled. It is not read-only (the session runs as the
  caller's role), so call it with a narrow role.
- **Agent 6 (Analyst + `code_execution`) results.** Documented instructions in `orchestration` ARE followed here, unlike `code_toolset_all`.
  - Median/std: 38 s, one Analyst query with `MEDIAN`/`STDDEV` over zero-filled `guests_on_park`, and a day count per park (31 each). Correct.
  - Correlation + weekday changeover: 137 s. It tried Python, but the 2,542-row result was truncated in its context and `RESULT_SCAN`
    from the sandbox failed, so it fell back to SQL. Busy-park results are correct, but it wrongly claimed the series was zero-filled:
    the Friday row count is 352, not 41 parks x 9 Fridays = 369, so the averages (Fri ~3,267) skip no-guest days, like agent 1.
  - Weekday regression (Aug 2025, 31 daily totals): 81 s, done in Python and correct (checked locally: intercept 94,763.5,
    Tue +892, Wed +838.5; R² 0.065). The sandbox had no working Snowflake session (`RESULT_SCAN` via `getOrCreate()` failed),
    so **the model copied the 31 rows from the SQL result into its script by hand**. That's how "data passed into the session"
    works in practice here: fine for tens of rows, not for thousands.
  - So: Analyst + `code_execution` is the documented, UI-editable combination and works when Python needs a small aggregated input.
    For Python over large pulls, agent 5's own session is the only route that works.
- **Agent 5 as a threaded tool over MCP (agent 7).** The built-in MCP type `CORTEX_AGENT_RUN` only takes `{"text"}`, so each call
  is a new run. Instead the MCP server exposes a caller's-rights **procedure** (`GENERIC` tool) that runs agent 5 with
  `DATA_AGENT_RUN` and continues its server-side thread from `thread_ref` (`new` or `<thread_id>:<message_id>`).
  Chain: agent 7 → `mcp_servers` → `ask_pandas_agent` → `ASK_PANDAS_AGENT_THREADED` → `RUN_AGENT` → agent 5 sandbox.
  All hops run as the end user (`AGENT_CALL_LOG.CALLED_BY`); caller's rights also keep agent 5's code sandbox.
  | Turn (2026-09-29) | agent 7 passed | agent 5 thread | agent 5 time |
  |---|---|---|---|
  | Top 3 parks by median daily guests, Aug 2025 | `new` | 2862161349 created | 45.6 s, 2 scripts |
  | "How did those three compare with August 2024?" | `2862161349:187574107726922` | continued | 32.9 s, 1 script |
  | Weekday changeover, July 2025 (new topic) | `new` | 2862161353 created | 52.3 s, 2 scripts |
  The follow-up ("same three parks, same definition") reused agent 5's thread and was faster. The same pattern tested directly over HTTP:
  51 s, then 35 s for the follow-up. End to end, each orchestrator turn takes 65-85 s.
  - **Role:** these objects are owned by `NEXUS_SPIKE`. A client whose session doesn't include that role gets "MCP server ... does not
    exist or not authorized", so the Claude Code helper runs with `SF_ROLE=NEXUS_SPIKE` (see `mcp.json`). A tool call takes about 1 minute.
