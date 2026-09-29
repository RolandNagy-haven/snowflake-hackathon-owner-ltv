# CLAUDE.md

## What this repo is

Working repo for the **Owner LTV** domain in Haven's "Owner Big Brain" data hackathon
(Hemel, 29 Sep 2026). The goal is to build a **Cortex Agent over a Snowflake semantic view**
that answers what an owner is worth and how long they stay — one of three domain agents
(Owner LTV, Top of Funnel, Performance Marketing) sitting on a **shared owner definition** and
reachable from one prompt via an orchestrator, plus a knowledge/memory agent.

The lasting deliverable is the **agreed owner definition + join map** and a **semantic view
with real business descriptions**, not a polished model. See `knowledge-base/` for the full
brief — start with `knowledge-base/README.md`.

## Owner (this repo)

Roland — **Owner LTV team lead**. Domain background: owner data via Pitch Perfect. Assume
familiarity with the business context; be concise and technical.

## Tech stack & runtime

- **Snowflake-native.** No third-party tooling. Core objects: `CREATE SEMANTIC VIEW`,
  `CREATE AGENT`, `CREATE MCP SERVER`, with Snowflake CoWork as the demo front end.
- **Claude Code is the build/iterate tool** (write → deploy → test the view, generate agent
  defs, run SQL, record findings). The **demo runtime is Snowflake-native** — Cortex Agents
  and the orchestrator run inside Snowflake.
- Snowflake access from Claude Code is via an MCP proxy (`sf_mcp_proxy.py` + `sf_mcp_auth.py`,
  SSO login) configured in `.mcp.json`. Role: `NEXUS_SPIKE`. Every call runs as you with your
  role — dev only.
- Agent definitions are generated **on `claude-opus-5-5`**.

## Build method (Peter's 5-step flow)

1. Start with a **small** semantic view (a couple of dimensions + metrics), then deploy.
2. Query it with plain SQL from Claude Code over Snowflake; skip Cortex Analyst.
3. Plug in the shared **memory MCP server**; confirm findings get recorded.
4. Generate the Cortex Agent from what worked.
5. Expose the agent as a tool (caller's-rights proc) so the orchestrator can call it.

## Owner LTV domain rules — MUST respect

Reference query (has the join path, grain, and caveats already):
`High_risk_owner_extract_v4.sql` (the `additional_sql` in the pack). Don't re-discover it.

- **Proxy fields — never present as ground truth** (bake the caveat into the semantic view's
  description / AI-instructions):
  - `ASSUMED_FINANCE_BALANCE` → `FINANCE_SETTLEMENT` is a **proxy** (no real settlement field).
  - `MONTHLY_INCOME_TOTAL` → `LETTINGS_CASH_MONTHLY` is a **proxy** for lettings cash.
  - Use `PEX_BASE_TRADE_VALUE` for bottom book value (the corrected column per `#1343`).
- **Performance trap:** `FCT_ACCOUNT_HISTORY` is **350M rows** — filter to the latest snapshot
  in a view first (`SNAPSHOT_DATE = (SELECT MAX(SNAPSHOT_DATE) ...)`) or every query crawls.
- **Owner grain:** default to person (`HAVEN_ID`), but label it — a person with 3 caravans has
  3× site fees. Pre-aggregate `ACCOUNT_DETAIL` to `DISTINCT HAVEN_ID` before declaring any
  cross-domain relationship, or the view double-counts / gets rejected.
- **Scope** the demo to **active owners** and state it; historic churn is a known limitation.
- **No PII** in the semantic layer (name/email/phone joins stay commented out) unless there's a
  clear need.
- Keep to **4–6 tables**, not twenty. Semantic views get hard fast; one day only.

Key tables live in `knowledge-base/05-owner-ltv-playbook.md`; churn-model detail in
`knowledge-base/10-churn-model-repo.md`.

## Conventions

- Correctness over speed: agents that write their own SQL can miscount (e.g. skipping empty
  days) — bake zero-filled / correct metrics into the semantic view so every consumer inherits
  the fix.
- Put business meaning and known pitfalls in the view's **descriptions**, **AI instructions**,
  and **verified queries** fields — that's what they're for.
- SQL for provisioning/agents belongs in versioned `.sql` files; test view numbers against
  plain SQL on the base tables before trusting them.

## Notes

- Data files (`*.csv`, `*.parquet`, `*.xlsx`, `data/`) and secrets (`.env`, `connections.toml`,
  `*.p8`) are gitignored. Add `!`-exceptions for any data file that must be tracked.
- `docs/` = original briefing pack; `knowledge-base/` = the distilled reference to work from.
