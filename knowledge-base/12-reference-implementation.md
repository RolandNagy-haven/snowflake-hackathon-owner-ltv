# 12 — Peter's Reference Implementation (`2026-haven-data-hackathon-main`)

Peter's working repo (`cortex-semantic-spike`) — extracted to
`2026-haven-data-hackathon-main/` in the project dir. It is the **actual, tested code** behind
the deck in [11](11-tooling-and-build-method.md). Each folder is a self-contained POC with its
own README, numbered `sql/` scripts and a `deploy.py`. This file is a map so we can **copy the
patterns** for Owner LTV rather than invent them.

> ⚠️ Most POCs are built on the **footfall / F&B / bookings** example domain, not owner data.
> The *patterns* transfer; the owner-specific material is in `topic-memory/` (below). The one
> POC already targeting our env (`NEXUS_HACKATHON_DB`, role `NEXUS_SPIKE`) is `sv-to-agent/`.

## Repo layout

| Dir | What it is | Copy for us? |
|---|---|---|
| `.claude/skills/` | Claude Code skills: `snowflake-query` (Snowpark SSO read-only helper — used by every `deploy.py`), `cortex-analyst` (ask Analyst over a view), `cortex-agent` (converse with any agent over REST) | ✅ reuse as-is |
| `.mcp.json` | Connects Claude Code to the footfall-bookings memory via the SSO proxy | template |
| `mcp_auth/` | **The clean, shareable SSO auth** for Snowflake MCP from Claude Code | ✅ the real one |
| `invocation-poc/` | Step POC: proc → MCP tool → semantic-view Analyst tools + `run_sql` → agent from MCP → agent over MCP | learn from |
| `semantic-views/footfall/` | The **worked semantic-view example**, V1→V3, with parity tests | ✅ template |
| `sv-to-agent/` | Six ways an agent can use a semantic view + agent-as-threaded-tool; **already on `NEXUS_SPIKE`** | ✅ templates |
| `agent-orchestration/` | Master agent delegating to specialists that share a memory agent (threaded) | ✅ pattern |
| `topic-memory/` | The **knowledge agent**: one YAML topic → a memory MCP server. **Contains our owner topics** | ✅ ours already exists |
| `data-views/` | Hand-built SQL cubes (footfall/F&B/holiday). The "before" picture views replace | skip (F&B) |

**Where things live in Snowflake:** account `bd78472.eu-west-1`, SSO. `sv-to-agent` →
`NEXUS_HACKATHON_DB.PZ_CORTEX_SPIKE`; the owner memory → `NEXUS_HACKATHON_DB.SHARED_OWNER_VIEW_MEMORY`.

## 1 · The semantic-view worked example — `semantic-views/footfall/`

`FOOTFALL_ARRIVALS_SV_V1..V3` rebuild an old ~50-col cube as a semantic view: **one row per
booked guest per night**, each old column condition exposed as a dimension. Each version ships a
**parity test** against the old cube and a script that runs every example query.

- **v1** booked guests · **v2** adds arrivals, leavers, bookings, ratios · **v3** adds owners
  (Fraser's estimates) as a *separate, never-added* measure.
- The view carries **synonyms, sample values, verified queries and long custom instructions** for
  Cortex Analyst — exactly the fields our proxy caveats ([05](05-owner-ltv-playbook.md)) and
  pinned churn definitions ([10](10-churn-model-repo.md)) belong in.

✅ **Cleanest full template to copy for `OWNER_LTV_SV`:**
`semantic-views/footfall/FOOTFALL_ARRIVALS_SV_V3.sql` (fullest metadata), with
`QUERY_EXAMPLES_V3.md` + `parity_v3.py` as the pattern for verified queries and number-checking.

⚠️ **Lesson baked into v3:** put **zero-filled metrics in the view itself** so every agent gets
"missing day = 0" right — Analyst-based agents otherwise skip empty periods (see §3).

## 2 · Semantic view → agent — `sv-to-agent/sql/` (already on `NEXUS_SPIKE`)

Walk it numerically:

| Step | File | Adds |
|---|---|---|
| 01 | `01_footfall_semantic_view.sql` | Deploys the view (+3 helper views) into our schema |
| 02 | `02_agent_analyst_tool.sql` | **Agent 1** — the view *is* the tool via `cortex_analyst_text_to_sql` |
| 03 | `03_run_sql_mcp.sql` | Read-only `run_sql` MCP server (`SYSTEM_EXECUTE_SQL`, `read_only`) |
| 04 | `04_agent_run_sql.sql` | **Agent 2** — no Analyst; model writes its own `SEMANTIC_VIEW(...)` SQL |
| 07 | `07_agent_code_pandas.sql` | **Agent 5** — full code sandbox (`code_toolset_all`) → Snowpark → pandas. **← deck step-4 template** |
| 08 | `08_agent_analyst_python.sql` | **Agent 6** — Analyst + `code_execution` Python sandbox |
| 09 | `09_agent_delegation.sql` | Agent-as-tool via caller's-rights `RUN_AGENT` + `DATA_AGENT_RUN`. **← deck step-5 template** |
| 10 | `10_pandas_agent_mcp.sql` | Makes agent 5 callable as a **threaded** GENERIC tool over MCP |
| 11 | `11_agent_orchestrator.sql` | **Agent 7** — front-door orchestrator, owns no data, delegates to agent 5, continues its thread |

**`AGENT_COMPARISON.md` conclusion:** the big difference is **correctness, not speed**. Analyst
agents (1, 6) skipped days with no guests → weekday averages **~5% high**; only agent 5 (with a
required checklist of the view's rules) zero-filled correctly. **Fix = zero-fill in the view.**
Also useful: `system_execute_sql` declared directly on an agent **fails at runtime** ("not
enabled on your account") — get SQL execution from an MCP `SYSTEM_EXECUTE_SQL` tool instead.

## 3 · Full orchestration — `agent-orchestration/sql/`

The master/delegate pattern our Platform team mirrors (arrivals/bookings are the *example*
domain; substitute Owner LTV / ToF / Perf Marketing):

| File | Object | Role |
|---|---|---|
| `01_agent_memory.sql` | `AGENT_MEMORY` table | One row per observation; recall = cosine similarity on an **arctic embedding** (recallable the instant it's written — no search-index lag) |
| `02_agent_delegation.sql` | `RUN_AGENT` + `AGENT_CALL_LOG` | **Caller's-rights procedure** that runs another agent via `DATA_AGENT_RUN` — keeps the end user's grants down the whole chain |
| `03_knowledge_agent.sql` | `KNOWLEDGE_AGENT` | Shared memory keeper; only records/recalls/retires — never touches business data |
| `04_arrivals_agent.sql` | `ARRIVALS_AGENT` | Specialist: read-only SQL + Python sandbox + the knowledge assistant. No semantic view |
| `05_bookings_agent.sql` | `BOOKINGS_AGENT` | Second specialist, same shape |
| `06_master_agent.sql` | `HAVEN_MASTER_AGENT` | The front door; owns no data tools; delegates to specialists via caller's-rights `DATA_AGENT_RUN`. **Stateless** (fresh each call) or **threaded** (`thread_ref` continues the specialist's server-side thread) |

⚠️ **Why the procedures exist:** the built-in `CORTEX_AGENT_RUN` tool only accepts `{"text"}`, so
every call starts fresh. Threaded, memory-carrying delegation needs the caller's-rights
`DATA_AGENT_RUN` procedure — that's the whole reason `02`/`06` exist.

## 4 · The knowledge agent — `topic-memory/` (our memory already exists ✅)

`memctl.py` turns **one YAML topic config → a Snowflake-managed MCP server** with four
owner's-rights SQL-procedure tools (arctic embeddings, ~1.5 s/call):
`owner_findings_index`, `search_owner_findings`, `get_owner_findings`, `record_owner_finding`.
A background **organiser** (`AI_COMPLETE` triage on insert ~30 s + a nightly 05:00 Cortex-agent
review) accepts/merges/supersedes/rejects findings; every change is **versioned with a reason**.

### The owner topics are already configured for us

`topics/shared_owner_view.yaml` is the live **Knowledge agent** of the shared owner view (id
prefix `SOV`, owner `NEXUS_SPIKE`, deployed to `NEXUS_HACKATHON_DB.SHARED_OWNER_VIEW_MEMORY`). It
already encodes: the shared-owner-definition scope, categories (`owner_definition`,
`identity_resolution`, `data_structure`, `definition`, `data_quality`, `validated_metric`,
`query_pattern`, `owner_insight`, `open_question`), a `domain` attribute
(`owner_ltv|top_of_funnel|performance_marketing|cross_domain`), a `confidence` attribute
(`verified|likely|hypothesis`), PII auto-rejection (email/UK mobile/postcode), and the
in-scope source tables per domain.

Per-team **sandbox** instances extend it (`shared_owner_view_<team>.yaml`) — ours is
`shared_owner_view_owner_ltv.yaml` → schema `SHARED_OWNER_VIEW_MEMORY_OWNER_LTV`, id prefix
**`SOL-`**. Deploy/reset:
```bash
.venv/bin/python topic-memory/memctl.py deploy topics/shared_owner_view_owner_ltv.yaml
```

**Connecting the memory (from `SHARED_OWNER_VIEW_MEMORY.md`):**
- **From a Cortex agent** — add to the spec (tools come from the server, no `tools:` entry):
  ```yaml
  mcp_servers:
    - server_spec:
        name: "NEXUS_HACKATHON_DB.SHARED_OWNER_VIEW_MEMORY_OWNER_LTV.SHARED_OWNER_VIEW_MEMORY_MCP"
  ```
  Switch to `…SHARED_OWNER_VIEW_MEMORY.…` for the shared (real) memory. Each schema also has a
  `…_RO_MCP` read-only server for consumers that shouldn't write.
- **From Claude Code** — streamable HTTP endpoint; `Snowflake Token="…"` (SSO session, ~1 h) or
  `Bearer <PAT>`. `memctl.py client topics/shared_owner_view_owner_ltv.yaml --install` wires it
  through the SSO proxy with auto-refresh.

### Live MCP server endpoints (from `MCP_server.rtf`)

Peter provisioned **one memory MCP server per team for testing** plus **one shared server we
ultimately use**. All are the `SHARED_OWNER_VIEW_MEMORY_MCP` server, one per schema under
`NEXUS_HACKATHON_DB`, on account host `trvdulb-dq93660.snowflakecomputing.com`:

| Team / use | Schema | MCP URL (path after the host) |
|---|---|---|
| **Owner LTV (ours)** | `SHARED_OWNER_VIEW_MEMORY_OWNER_LTV` | `/api/v2/databases/NEXUS_HACKATHON_DB/schemas/SHARED_OWNER_VIEW_MEMORY_OWNER_LTV/mcp-servers/SHARED_OWNER_VIEW_MEMORY_MCP` |
| Top of Funnel | `SHARED_OWNER_VIEW_MEMORY_TOP_OF_FUNNEL` | `…/schemas/SHARED_OWNER_VIEW_MEMORY_TOP_OF_FUNNEL/mcp-servers/SHARED_OWNER_VIEW_MEMORY_MCP` |
| Performance Marketing | `SHARED_OWNER_VIEW_MEMORY_PERFORMANCE_MARKETING` | `…/schemas/SHARED_OWNER_VIEW_MEMORY_PERFORMANCE_MARKETING/mcp-servers/SHARED_OWNER_VIEW_MEMORY_MCP` |
| Orchestrator | `SHARED_OWNER_VIEW_MEMORY_ORCHESTRATOR` | `…/schemas/SHARED_OWNER_VIEW_MEMORY_ORCHESTRATOR/mcp-servers/SHARED_OWNER_VIEW_MEMORY_MCP` |

These per-team servers are the **sandboxes** (matching the `shared_owner_view_<team>.yaml` topics
above); the **shared** `…SHARED_OWNER_VIEW_MEMORY.…` server is the one for the real run. Full URL
for our team = host + the Owner LTV path above.

**`.mcp.json` config Peter ships** (the entry name in his example — `mem-footfall-hackathon` — is
just a stale label; rename it e.g. `mem-owner-ltv`, and point the URL at our schema):
```jsonc
"mem-owner-ltv": {
  "type": "stdio",
  "command": ".venv/bin/python3",
  "args": [
    "invocation-poc/sf_mcp_proxy.py",
    "https://trvdulb-dq93660.snowflakecomputing.com/api/v2/databases/NEXUS_HACKATHON_DB/schemas/SHARED_OWNER_VIEW_MEMORY_OWNER_LTV/mcp-servers/SHARED_OWNER_VIEW_MEMORY_MCP"
  ],
  "env": { "SF_ROLE": "NEXUS_SPIKE" }
}
```
⚠️ **Host mismatch to resolve on the day:** the server URLs use `trvdulb-dq93660.snowflakecomputing.com`,
but Peter's config example (and §Where-things-live above) reference the account
`bd78472.eu-west-1.snowflakecomputing.com`. Use the host from the **actual URL list**
(`trvdulb-dq93660`) for these memory servers; if the proxy can't reach it, that account-host
difference is the first thing to check. Config also uses `sf_mcp_proxy.py` from `invocation-poc/`
— [§5](#5--mcp-auth--mcp_auth-vs-invocation-poc) prefers the `mcp_auth/` copy; either works, same proxy.

**Usage protocol our agent's instructions should carry:** call `owner_findings_index` at task
start; `search_owner_findings` before each sub-question, before hitting `FCT_ACCOUNT_HISTORY`
(~350M rows), and before stating any number/definition; record **at most 2-3** durable findings
after verified work, always passing `agent_type` (`owner_ltv_agent` / `claude_code`); correct a
wrong finding with `supersedes=<id>`. Never record PII or one-off answers.

⚠️ **Open item already logged in the topic:** `OWNER_RISK_SCORES` exists in
`HAVEN_DATA_SCIENCE_DEV.OWNER_CHURN`, `.DATA_SCIENCE` **and** `.DATA_SCIENCE_CLONE` with
**different row counts — which is authoritative is still open.** Ties directly to the
schema/column discrepancy in [10](10-churn-model-repo.md): `DESCRIBE` and pick the source
before we promise fields.

## 5 · MCP auth — `mcp_auth/` vs `invocation-poc/`

Same idea, covered conceptually in [11](11-tooling-and-build-method.md). Use **`mcp_auth/`** —
it's the standalone, shareable version (`sf_mcp_proxy.py` = local stdio MCP server forwarding to
Snowflake, renewing the ~1 h session token; `sf_mcp_auth.py` = prints the token header for short
sessions). `invocation-poc/`'s copies are the earlier POC versions; prefer `mcp_auth/`.
Local-dev only: every call runs **as you, with your role** — for shared/unattended use switch to
a PAT / key pair / OAuth.

## What to copy for Owner LTV — the starting kit

1. **Semantic view:** clone `semantic-views/footfall/FOOTFALL_ARRIVALS_SV_V3.sql` shape for
   `OWNER_LTV_SV`; put proxy caveats + pinned churn definitions ([05](05-owner-ltv-playbook.md),
   [10](10-churn-model-repo.md)) into descriptions / AI instructions / verified queries; keep a
   `parity_*.py`-style check against plain SQL.
2. **Build flow:** deck's 5 steps ([11](11-tooling-and-build-method.md)) using `sv-to-agent`
   templates — `07_agent_code_pandas.sql` for the agent, `09_agent_delegation.sql` to expose it
   as a tool for the orchestrator.
3. **Memory:** connect our agent (and our Claude Code sessions) to the **`SHARED_OWNER_VIEW_MEMORY_OWNER_LTV`**
   sandbox first, then the shared `SHARED_OWNER_VIEW_MEMORY` for the real run; paste the usage
   protocol into the agent's instructions.
4. **Auth:** `mcp_auth/` proxy with `SF_ROLE=NEXUS_SPIKE`.
5. **Skills:** the `.claude/skills/` (`snowflake-query`, `cortex-analyst`, `cortex-agent`) are
   reusable immediately for querying and testing.
