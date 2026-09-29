# 11 — Tooling & Build Method

Source: **Peter's deck** *"Snowflake Semantic Views & Agents — Hackathon"* (12 slides) — the
09:25 teaching session. This is the "how" behind everything in [01](01-project-overview.md).

## The picture: four agents, one prompt

```
Snowflake CoWork  (business asks here)
        │  MCP
   Orchestrator agent  (Platform) — routes each question, merges answers
   ┌──────────┬──────────────┬─────────────────┐
Owner LTV   Top of Funnel  Perf. Marketing   Knowledge
CORTEX      CORTEX         CORTEX            CORTEX AGENT
AGENT       AGENT          AGENT             (memory)
   │            │              │                │
OWNER_LTV_SV TOP_OF_FUNNEL_SV PERF_MARKETING_SV AGENT_MEMORY table
   └────────────┴──────────────┘
        Shared Owner View
```

Each domain agent = a **Cortex Agent** over a **semantic view**; the Knowledge agent sits on a
**memory table**; the Orchestrator calls the others (an agent can be a tool → agents call agents).

## What a semantic view is

One database object — "like a classic cube plus context for AI." SQL users, BI tools, Cortex
Analyst and our agents **all read the same definitions**.

| Cube part | What it is | Example |
|---|---|---|
| **Tables** | Business names over physical tables, with keys | `guests`, `park_days`, `parks` |
| **Relationships** | How tables join, defined **once** | `guests → park_days → parks` |
| **Dimensions & facts** | What you group/filter by; row-level values | `park_name`, `stay_type`, `on_park_date` |
| **Metrics** | Named aggregations everyone shares | `guest_nights = SUM(guest_night)` |
| **Synonyms** *(AI)* | The words people actually use | `guest_nights ≈ 'footfall', 'headcount'` |
| **Descriptions** *(AI)* | Business meaning on every table/column/metric | `'Owners are not included.'` |
| **AI instructions** *(AI)* | Rules & known pitfalls for SQL generation | `'Round averages to whole people.'` |
| **Verified queries** *(AI)* | Trusted question→SQL pairs, used as examples | `'Guests on each park, last 7 days?'` |

➡️ For **our** Owner LTV view, the descriptions/AI-instructions/verified-queries fields are
exactly where the proxy-field caveats and pinned definitions from [05](05-owner-ltv-playbook.md)
and [10](10-churn-model-repo.md) must go.

## How to create one — two equivalent ways

- **SQL DDL:** `CREATE SEMANTIC VIEW … TABLES(…) RELATIONSHIPS(…) DIMENSIONS(…) METRICS(…)
  COMMENT=…` — reads like a cube definition.
- **YAML spec:** loaded with `SYSTEM$CREATE_SEMANTIC_VIEW_FROM_YAML`. Almost the same
  capabilities — pick either.

> In production this would live in dbt + CI/CD. **Today, Claude Code does the plumbing:**
> **1 Write** — point it at your tables + business rules; it drafts the provisioning script.
> **2 Deploy** — it runs the script in your dev schema and fixes whatever Snowflake rejects.
> **3 Test** — it queries the view and checks the numbers against plain SQL on the tables.

## How to query one — two syntaxes, same result, no JOIN written

```sql
-- A · new syntax
SELECT * FROM SEMANTIC_VIEW(
  FOOTFALL_ARRIVALS_SV_V1
  DIMENSIONS parks.park_name, parks.region
  METRICS    guests.guest_nights
  WHERE      park_days.stay_week = '2025-08-04'
) ORDER BY guest_nights DESC LIMIT 5;

-- B · classic SQL (wrap metrics in AGG())
SELECT park_name, region, AGG(guest_nights) AS guest_nights
FROM FOOTFALL_ARRIVALS_SV_V1
WHERE stay_week = '2025-08-04'
GROUP BY park_name, region ORDER BY guest_nights DESC LIMIT 5;
```

The view already knows `guests → park_days → parks`.

## Tools, MCP, and Cortex Agents

**A tool = one capability an agent can call**; Snowflake MCP servers publish them. Four kinds:

| Tool | Type | Does |
|---|---|---|
| SQL / Python | `GENERIC` | Runs a stored proc / function |
| Run SQL | `SYSTEM_EXECUTE_SQL` | Executes SQL the caller writes |
| Cortex Analyst | `CORTEX_ANALYST_MESSAGE` | Question → SQL over a semantic view |
| Cortex Agent | `CORTEX_AGENT_RUN` | A whole agent, called as one tool |

- **MCP server:** `CREATE MCP SERVER … FROM SPECIFICATION`; each tool gets a name, description,
  input schema. Consumed by Cortex Agents (`mcp_servers:` in the spec) **and** by Claude Code /
  CoWork / IDEs (`mcp.json → server URL`).
- **Cortex Agent:** `CREATE AGENT … FROM SPECIFICATION` — nothing Cortex-specific; a standard
  *plan → call tool → observe* loop Snowflake hosts under your role. = Instructions (role,
  routing, answer style) + Tools + Snowflake-hosted runtime.

## Four ways an agent can reach a semantic view (Peter tested all four)

| Approach | How | Weekday-averages test | Best for |
|---|---|---|---|
| **Cortex Analyst** | Analyst writes + runs the SQL | **~5% high** — skipped empty days | Everyday business questions |
| **Analyst + Python** | Analyst SQL + Python for small inputs | ~5% high, but *claimed* it zero-filled | Analyst + light Python |
| **Run SQL via MCP** | Reads `DESCRIBE`, writes its own SQL | **Fully correct** | SQL-only, no Analyst |
| **Claude Code equiv.** (code sandbox + pandas) | Discovers view, then SQL + Python | **Fully correct** — zero-filled | Statistics / deep analysis |

⚠️ **The big difference is correctness, not speed.** Agents that write their own SQL counted
days with no guests; Analyst-based ones skipped them. **Fix it once for every agent by baking
zero-filled metrics into the semantic view itself.** (This is a concrete instance of the
divergence problem — [09](09-benchmark-and-divergence.md).) All four agent defs live in
`sv-to-agent/sql/` — see [12](12-reference-implementation.md).

## The knowledge agent (Platform) — how shared memory works

Every agent (and Claude Code while building) lists a **memory MCP server** under `mcp_servers:`.
The server (`FOOTFALL_BOOKINGS_MEMORY_MCP` in the example) exposes four tools:

- `findings_index` — brief, rules, one line per finding
- `search_findings` — semantic + keyword search
- `get_findings` — full items by id, with links + history
- `record_finding` — save one finding; flags likely duplicates

A **background organiser** curates: on insert (~30 s) an LLM compares each new item to its 6
nearest and decides *activate / duplicate / merge / supersede / reject / escalate*; nightly a
cron task resolves flagged/stale items and rewrites the index. **Agents record, the organiser
curates. Every change is versioned, with a reason.** One topic = one YAML config, deployed with
`memctl`. Details + the owner topics: [12](12-reference-implementation.md).

## Getting Snowflake MCP tools into Claude Code (`mcp_auth`)

```
Claude Code  --stdio-->  sf_mcp_proxy.py (your laptop)  --HTTPS-->  Snowflake MCP server
             (SSO login; renews the ~1-hour session token)
```

1. `pip install -r requirements.txt`
2. `python sf_mcp_auth.py --login` (opens browser; then silent ~4 hours)
3. Add one proxy entry per MCP server in `.mcp.json`, then approve in `/mcp`
4. `python sf_mcp_auth.py --check <url>`

```jsonc
"my-snowflake-mcp": {
  "type": "stdio",
  "command": ".venv/bin/python",
  "args": ["sf_mcp_proxy.py", "https://<account>…/mcp-servers/<NAME>"],
  "env": { "SF_ACCOUNT": "<account>", "SF_USER": "you@example.com", "SF_ROLE": "MY_ROLE" }
}
```

⚠️ **Dev only: every call runs as you, with your role.** For shared/unattended use, use a PAT,
key pair or OAuth. (For us that role is `NEXUS_SPIKE` — [02](02-agenda-and-logistics.md).)

➡️ **The live memory MCP server URLs are already provisioned** — one per team plus a shared one.
Our Owner LTV endpoint and the ready-to-paste `.mcp.json` block are in
[12 §4 → Live MCP server endpoints](12-reference-implementation.md).

## Your day, in five steps (Peter's recommended flow)

1. **Start with a small semantic view** — a couple of dimensions + metrics, then deploy.
   → *"Create a semantic view over our tables with two metrics"*
2. **Experiment with plain SQL** — use the view from Claude Code over Snowflake; skip Analyst.
   → *"Answer this from the semantic view and show me the SQL"*
3. **Plug in shared memory** — add the memory MCP server; check findings get recorded.
   → *"Record what we just learned as a finding"*
4. **Generate the Cortex Agent** — Claude writes the agent def from what worked, **on Opus 5.5**.
   → *"Turn this session into a Cortex Agent, claude-opus-5-5"*
5. **Expose your agent as a tool** — wrap it in a caller's-rights procedure so the orchestrator
   can call it. → *"Expose my agent as a tool, like the delegation example"*

Templates: step 4 → `sv-to-agent/sql/07_agent_code_pandas.sql`; step 5 →
`sv-to-agent/sql/09_agent_delegation.sql`. See [12](12-reference-implementation.md).

## ➡️ Answering "can we do this entirely in Claude Code?"

The deck confirms the split we reasoned about earlier: **Claude Code is the build/iterate tool**
(write → deploy → test the views, generate agent defs, run the SQL, record findings), and it's
one of the tested agent runtimes ("Claude Code equivalent", fully correct). But the **demo
runtime is Snowflake-native** — CoWork is the front end and the Cortex Agents/orchestrator run
inside Snowflake. Claude Code does the plumbing; Snowflake hosts the result.
