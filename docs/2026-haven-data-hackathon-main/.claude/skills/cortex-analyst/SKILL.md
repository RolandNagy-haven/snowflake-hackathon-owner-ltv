---
name: cortex-analyst
description: Ask Snowflake Cortex Analyst a natural-language question over a semantic view (default FNB_RETAIL_SV, Haven F&B retail sales) and get governed SQL back, optionally executed. Use for business questions about F&B revenue, orders, average order value, wet share, voids, trading venue-days by park / region / venue / category / concept / date / hour / season / school holiday, and when developing or testing the semantic view itself.
trigger_patterns:
  - "ask cortex analyst"
  - "ask the semantic view"
  - "use the analyst"
  - business questions about F&B / retail revenue, orders, AOV, wet share, venues, concepts
  - testing or debugging FNB_RETAIL_SV / verified queries
---

# cortex-analyst

Calls the Cortex Analyst REST API (`/api/v2/cortex/analyst/message`) with the
**same EXTERNALBROWSER SSO session** as the `snowflake-query` skill — no PAT, no MCP.
Analyst turns the question into SQL against the semantic view; the script can then run
that SQL in the same session.

## Usage

```bash
S=.claude/skills/cortex-analyst/cortex_analyst.py

python $S --describe                                   # metrics + dimensions of the view
python $S "revenue per open venue-day by concept, August 2026"            # SQL only
python $S "revenue per open venue-day by concept, August 2026" --run      # SQL + result
python $S "..." --run --out sandbox/tmp/result.parquet                    # save result
python $S "wet share by region in July 2026" --thread fnb --reset --run   # start a thread
python $S "now split that by weekend" --thread fnb --run                  # follow-up
python $S "..." --view DB.SCHEMA.OTHER_SV                                 # another view
python $S "..." --raw                                                     # full JSON
```

Run from the repo root with the project venv active.

Exit code `2` means Analyst returned **no SQL** — the question was ambiguous; the
`## suggestions` block lists rephrasings it would accept. Pick one and ask again.

## How to use it well

- **Prefer `--run`** for answering a question; drop it when you only want to inspect or
  hand-edit the SQL (e.g. to add a window function / join, which semantic SQL forbids —
  wrap the `SEMANTIC_VIEW(...)` query in a CTE and post-process outside it).
- **Always read the `## interpretation`** block and state it to the user: Analyst
  resolves ambiguity itself (e.g. "last 4 weeks" -> 4 complete calendar weeks) and says so
  there. If the interpretation is not what the user meant, rephrase precisely.
- **Treat `## WARNING` as a defect in the semantic view**, not noise — e.g. a verified
  query that stopped compiling is silently dropped by Analyst and only surfaces here.
- `verified query used: <name>` means the answer came from a curated query in the view's
  `AI_VERIFIED_QUERIES`; `none` means it was generated fresh.
- Follow-ups need `--thread <name>`; without it every call is a fresh conversation.
  Thread history lives in `.claude/skills/cortex-analyst/.threads/`.
- Each call is billed per message, and `--run` also uses the XSMALL warehouse. Queries
  on FNB_RETAIL_SV take roughly 5-20 s.

## Semantic view source

`FNB_RETAIL_SV` DDL, deploy script and hand-written example queries live in
`sandbox/sql/` (`FNB_RETAIL_SEMANTIC_VIEW.sql`, `deploy_fnb_retail_sv.py`,
`FNB_RETAIL_SV_QUERIES.sql`). To improve answers, edit the view — synonyms, comments,
`AI_SQL_GENERATION`, `AI_VERIFIED_QUERIES` — and redeploy; this skill needs no change.

Known view semantics worth repeating to the user when relevant:
- revenue = all lines incl. voids; business day runs 08:00-07:59 (`business_hour` 8..31);
- revenue is attributed to the **servicing** venue (taken revenue), not the cost-centre
  arbitrated serviced revenue of `FNB_RETAIL_FACTS_DAILY_V4`;
- park `season` only from 2025, and peak / off_peak only from 2026;
- window metrics (`net_revenue_7d_avg`, `net_revenue_ly`) partition by every other
  dimension in the query — ask for them by date only.
