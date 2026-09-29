---
name: cortex-agent
description: Converse with the Snowflake Cortex Agent FNB_RETAIL_AGENT (Haven F&B retail sales over the FNB_RETAIL_SV semantic view) - it plans, runs several queries, checks them and answers in prose with tables, charts and follow-up suggestions, with server-side conversation threads. Use for multi-step or comparative F&B business questions, "typical"/median questions, and when the user wants the agent's answer or to test the agent itself.
trigger_patterns:
  - "ask the agent"
  - "ask the cortex agent"
  - "use the snowflake agent"
  - multi-step / comparative questions about F&B revenue, venues, categories, parks
  - testing or debugging FNB_RETAIL_AGENT
---

# cortex-agent

Calls `POST /api/v2/databases/{db}/schemas/{schema}/agents/{name}:run` with the
**same EXTERNALBROWSER SSO session** as the `snowflake-query` skill (no PAT, no MCP).
The agent (orchestration model `auto`, currently resolving to an Opus model) uses Cortex
Analyst over `FNB_RETAIL_SV` as its tool, runs the SQL itself, sees the results and can
take several steps before answering.

## Usage

```bash
A=.claude/skills/cortex-agent/cortex_agent.py

python $A "typical take per open venue-day by category, August 2026"            # one-off
python $A "same question" --thread fnb --reset                                  # new conversation
python $A "how does that compare with August 2025?" --thread fnb                # follow-up
python $A "..." --show-sql                                                      # print SQL it ran
python $A "..." --save sandbox/tmp/agent_run1     # response.json, queries.sql, table_N.parquet, chart_N.vl.json
python $A --threads                                                             # saved conversations
python $A "..." --agent DB.SCHEMA.OTHER_AGENT
```

Run from the repo root with the project venv active. Progress (status, tool calls) goes to
stderr, the answer to stdout. Expect **40-60 s per turn**.

## cortex-agent vs cortex-analyst

| | cortex-analyst | cortex-agent |
|---|---|---|
| Does | one question -> one SQL | plans, runs several queries, checks, writes the answer |
| Sees results | no | yes (can sanity-check, compare, chart) |
| Memory | client resends history | server-side thread |
| Speed / cost | ~5 s, one Analyst message | 40-60 s, ~100k (mostly cached) Opus tokens per turn |
| Best for | getting / inspecting SQL, testing the semantic view | business answers, multi-step and "typical"/median questions |

When the user wants the numbers for further work in Python, prefer `cortex-analyst --run --out`
or `--save` here and load `table_N.parquet`.

## Reading the output

- Report the agent's answer, but **check the definitions line it gives** and relay
  caveats (drinks share for FASTFOOD/TREATS is near zero by product coding).
- Use `--show-sql` whenever a number matters or looks surprising; the agent may drop out of
  semantic SQL into raw logical-table SQL (e.g. for medians), and that is where grain
  mistakes happen — a venue is `(park_code, venue name)`, never name alone.
- The agent sometimes repeats a table in its final text; that is cosmetic.

## Where things live

- Agent spec: `sandbox/sql/FNB_RETAIL_AGENT.sql`; semantic view:
  `sandbox/sql/FNB_RETAIL_SEMANTIC_VIEW.sql`. Deploy either with
  `python sandbox/sql/deploy_fnb_retail_sv.py <FILE.sql>`.
- Behaviour is steered by the spec's `instructions.orchestration` / `instructions.response`;
  improve answers there (or in the semantic view), not in this script.
- Thread state: `.claude/skills/cortex-agent/.threads/<name>.json` (thread_id + last
  assistant message id).
