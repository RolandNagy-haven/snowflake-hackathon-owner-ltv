# cortex-semantic-spike

A spike into **Snowflake Cortex** for Haven data: semantic views, Cortex Analyst, Cortex Agents and
**MCP** (Model Context Protocol). It asks how governed business data can be exposed to AI agents,
both agents hosted in Snowflake and external clients such as Claude Code. It also asks how agents
can call each other, keep conversations, share memory and run Python.

Each folder is a self-contained proof of concept with its own README, SQL scripts and a `deploy.py`.
This file explains how they fit together and summarises what was learned.

```
                            Haven source data (HAVEN_STORE.*)
                                          │
        data-views/  ── hand-built SQL views (the original cubes: footfall, F&B, holidays, forecasts)
                                          │ replaced by
        semantic-views/footfall/ ── FOOTFALL_ARRIVALS_SV_V1..V3 (semantic views + parity tests)
                                          │ consumed by
   ┌──────────────────────┬───────────────┴────────────┬─────────────────────────┐
   ▼                      ▼                            ▼                         ▼
 invocation-poc/     sv-to-agent/                 agent-orchestration/      topic-memory/
 procs, semantic     6 ways for an agent to       master → specialist       shared, self-organising
 views and agents    use a semantic view; agent   agents, threaded          agent memory served as
 exposed over MCP    as a threaded MCP tool       delegation, memory agent  MCP servers per topic
   │                      │                            │                         │
   └──────────────┬───────┴────────────────────────────┴─────────────────────────┘
                  ▼
   mcp_auth/  ── connect Claude Code to Snowflake-managed MCP servers with your own SSO login
   .claude/skills/ ── Claude Code skills for querying Snowflake, Cortex Analyst and Cortex Agents
```

## Where things live in Snowflake

Account `bd78472.eu-west-1`, SSO login (EXTERNALBROWSER).

| Location | Owner role | Used by |
|---|---|---|
| `HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL` | `HAVEN_DATA_SCIENCE_DEV` | `semantic-views`, `invocation-poc`, `agent-orchestration`, `topic-memory` (footfall topics), `FNB_RETAIL_SV` |
| `NEXUS_HACKATHON_DB.PZ_CORTEX_SPIKE` | `NEXUS_SPIKE` | `sv-to-agent` |
| `NEXUS_HACKATHON_DB.SHARED_OWNER_VIEW_MEMORY` | | `topic-memory` (shared owner view memory for the hackathon) |

`FNB_RETAIL_SV` (Haven F&B retail sales semantic view) is deployed and used here, but its DDL lives outside this repo
(the `cortex-analyst` skill points to `sandbox/sql/`).

## The parts

### `data-views/`: the starting point
Hand-written SQL views that feed the forecasting models: `DAILY_FOOTFALL_FACTS_V3` (a ~50-column footfall cube),
F&B retail facts (daily and hourly, historical and future covariates), holiday features and published footfall predictions.
These are the "before" picture that the semantic views replace.

### `semantic-views/footfall/`: footfall as a semantic view
`FOOTFALL_ARRIVALS_SV_V1..V3` rebuild the footfall cube as a Snowflake semantic view: one row per booked guest per night,
with the cube's column conditions exposed as dimensions, so every old column becomes a query. Each version has a
**parity test** against the old cube and a check that runs every example query.
- v1: booked guests; v2: arrivals, leavers, bookings, ratios; v3: owners (Fraser estimates) as a separate, never-added measure.
- The view carries synonyms, sample values, verified queries and long custom instructions for Cortex Analyst.

### `invocation-poc/`: exposing Snowflake objects over MCP
Step-by-step POC of **Snowflake-managed MCP servers**:
1. A stored procedure exposed as an MCP tool (`GENERIC`), called from Claude Code.
2. Semantic views exposed as Cortex Analyst tools (`CORTEX_ANALYST_MESSAGE`) plus a read-only `run_sql`.
3. An agent whose only tools come from an MCP server (`mcp_servers:` in the agent spec).
4. That agent exposed over MCP (`CORTEX_AGENT_RUN`).

It also has the first version of the SSO auth for Claude Code (`sf_mcp_auth.py`, `sf_mcp_proxy.py`).

### `sv-to-agent/`: how an agent should use a semantic view
Deploys the footfall semantic view to `NEXUS_HACKATHON_DB.PZ_CORTEX_SPIKE`, then compares agents that access it in different ways,
all tested on the same questions (medians, correlations, a regression):

| Agent | Route |
|---|---|
| 1 | Cortex Analyst tool (`cortex_analyst_text_to_sql`) |
| 2 | Its own model writes `SEMANTIC_VIEW(...)` SQL through an MCP `run_sql` tool |
| 5 | Code sandbox (`code_toolset_all`) with a Snowpark session: data into pandas |
| 6 | Cortex Analyst + the `code_execution` Python sandbox |
| 7 | Orchestrator that calls agent 5 over MCP, **continuing its conversation thread** for follow-ups |

See `sv-to-agent/AGENT_COMPARISON.md` for the side-by-side comparison.

### `agent-orchestration/`: agents calling agents
A master agent that delegates to arrivals and bookings specialists, which share a memory agent. Snowflake has no native
"agent calls agent with memory" tool, so each hop is a **caller's-rights procedure** running the target with `DATA_AGENT_RUN`.
- Stateless mode: every call starts fresh.
- Threaded mode: the specialist's server-side thread continues via a `thread_ref`.

This is where the threaded delegation that `sv-to-agent` agent 7 reuses was developed.

### `topic-memory/`: shared agent memory as MCP servers
`memctl.py` turns one YAML topic config into a Snowflake-managed MCP server with fast search/save/get/index tools
(owner's-rights SQL procedures, arctic embeddings, ~1.5 s per call).
- A background **organiser** reviews new items: `AI_COMPLETE` triage on insert, plus a scheduled Cortex agent review.
- Topics: `footfall_bookings`, and `shared_owner_view` for the hackathon. See `SHARED_OWNER_VIEW_MEMORY.md` for how other teams connect.
- The repo's `.mcp.json` connects Claude Code to the footfall-bookings memory through the SSO proxy.

### `mcp_auth/`: SSO auth for Snowflake MCP from Claude Code
A standalone, shareable version of the auth scripts. Claude Code talks to a Snowflake-managed MCP server **as you**,
using your normal browser SSO, with no PAT, key pair or OAuth integration, and so no admin setup.
- `sf_mcp_proxy.py` (recommended): a local stdio MCP server that forwards to Snowflake and renews the session token when it expires.
- `sf_mcp_auth.py`: prints the session-token header, for use as a `headersHelper` in short sessions.

It's intended for local development only.

### `.claude/skills/`: Claude Code skills
| Skill | Does |
|---|---|
| `snowflake-query` | Snowpark session helper (SSO) for read-only queries; used by every `deploy.py` |
| `cortex-analyst` | Ask Cortex Analyst a question over a semantic view (default `FNB_RETAIL_SV`), get or run the SQL |
| `cortex-agent` | Converse with any Cortex Agent over REST (`--agent`, threads, `--show-sql`, `--save`) |
| `activity-supply-demand` | Build activity supply vs demand views and charts |
| `developing-with-streamlit` | Streamlit development guidance and templates |

## Key findings across the POCs

**Auth and MCP**
- A Snowflake-managed MCP endpoint accepts a normal **session token** (`Authorization: Snowflake Token="…"`), so an SSO
  login can drive MCP clients. Session tokens expire after 1 h, and the endpoint then answers with a non-JSON-RPC error,
  which is why `mcp_auth` uses a refreshing proxy.
- An agent can attach a Snowflake-managed MCP server with `mcp_servers:` (the docs only describe external ones). Snowflake
  calls it internally as the end user, with no extra auth.
- The built-in agent-over-MCP tool (`CORTEX_AGENT_RUN`) only takes `{"text"}`, so every call starts fresh. To let an agent
  continue a conversation, expose a caller's-rights procedure that uses `DATA_AGENT_RUN` with thread ids (agent-orchestration,
  sv-to-agent agent 7).

**Agents and tools**
- Declaring `system_execute_sql` as an agent tool fails at run time ("not enabled on your account"). It's only added
  automatically alongside Cortex Analyst. For SQL without Analyst, use an MCP `SYSTEM_EXECUTE_SQL` tool with `read_only: true`.
- Code agents (`code_toolset_all`) follow only `instructions.system`, which isn't documented for agent objects. They ignore
  `orchestration`, and a Snowsight save deletes `system`. Plain agents and `code_execution` agents follow the documented fields.
- The `code_toolset_all` sandbox can open its own Snowpark session as the caller, which enables pandas over large pulls.
  This is undocumented and not read-only. The `code_execution` sandbox has no connection: data reaches it only when the model copies rows in.
- Caller's rights matter throughout. Owner's-rights invocation strips code tools, and everything runs with the end user's grants,
  so give agents with sandboxes a narrow role.

**Semantic views**
- Querying a semantic view needs `SELECT` on the view only, not on its base tables, so a narrow role can confine an agent to it.
- Cortex Analyst follows the view's custom instructions inside `SEMANTIC_VIEW(...)`, but not for calculations it wraps around it.
  In tests it averaged over days with guests only, ignoring the "missing day = 0" rule. A model writing its own queries got this
  right only when required to list the rules that apply before querying.

## Getting started

```bash
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/python sv-to-agent/deploy.py 01 --dry-run    # usage is in each deploy.py docstring; no args = deploy all 0* scripts
python .claude/skills/cortex-agent/cortex_agent.py "question" \
  --agent NEXUS_HACKATHON_DB.PZ_CORTEX_SPIKE.SV_AGENT_1_ANALYST --show-sql
```

- **Login:** the first Snowflake connection opens a browser for SSO. Later ones are silent for about 4 h, because the ID token is cached in the macOS keychain.
- **Script layout:** each POC deploys numbered scripts from its `sql/` folder in order, and `99_teardown.sql` removes what it created.
