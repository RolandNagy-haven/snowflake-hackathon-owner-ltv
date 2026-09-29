# Semantic view → Cortex Agent: comparison of agents 1, 2, 5, 6

All agents use the semantic view `NEXUS_HACKATHON_DB.PZ_CORTEX_SPIKE.FOOTFALL_ARRIVALS_SV_V3` (tested 2026-09-28).
Agent 3 (`code_toolset_all` restricted to `snowflake_sql_execute`) was removed: it added nothing over agent 2.
Timings are from single runs of the test questions (see `README.md`). "Not tested" means the agent wasn't given that question.

| Attribute | Agent 1: Analyst | Agent 2: run_sql | Agent 5: pandas | Agent 6: Analyst + Python |
|---|---|---|---|---|
| **Object** | `SV_AGENT_1_ANALYST` | `SV_AGENT_2_RUN_SQL` | `SV_AGENT_5_PANDAS` | `SV_AGENT_6_ANALYST_PYTHON` |
| **Script** | `sql/02_agent_analyst_tool.sql` | `sql/03_run_sql_mcp.sql` + `sql/04_agent_run_sql.sql` | `sql/07_agent_code_pandas.sql` | `sql/08_agent_analyst_python.sql` |
| **Tools** | `cortex_analyst_text_to_sql`, plus the auto-added `system_execute_sql` | `run_sql` from MCP server `SV_SQL_MCP` (`SYSTEM_EXECUTE_SQL`) | `code_toolset_all` | `cortex_analyst_text_to_sql` + `code_execution` |
| **Who writes the SQL** | Cortex Analyst | The agent's own model | The agent's own model, run from Python | Cortex Analyst |
| **How it learns the view** | Analyst reads it internally (verified queries, custom instructions) | `DESCRIBE SEMANTIC VIEW` into the model's context | A discovery script that pivots `DESCRIBE`, plus a checklist of the rules that apply | Analyst reads it internally |
| **Where calculations happen** | SQL around `SEMANTIC_VIEW` | SQL around `SEMANTIC_VIEW` | pandas / numpy / scipy | SQL; Python only for small inputs |
| **How data reaches the model or code** | Structured result set | JSON result with column types | pandas DataFrame via a Snowpark session (`connection_name='default'`) | Result set; into Python only by the model copying rows into its script |
| **Model** | `auto` → Opus 4.8 | `auto` → Opus 4.8 | `claude-opus-5-5` | `claude-opus-4-8` |
| **Instruction field that works** | `orchestration` / `response` | `orchestration` / `response` | Undocumented `system` only | `orchestration` / `response` |
| **Documented and editable in Snowsight** | Yes | Yes (needs an MCP server) | No: undocumented `system` and sandbox connection | Yes |
| **Read-only** | Yes (Analyst generates only SELECTs) | Yes, enforced by the MCP server's `read_only: true` | **No**: the session has the caller's role | Yes (Analyst; the sandbox has no connection) |
| **Median / std dev per park (Aug 2025)** | 65 s, correct | Not tested | 79 s, 2 calls, correct, zero-filled check (41 × 31) | 38 s, correct |
| **Correlation + weekday changeover (Jul–Aug 2025)** | 48 s; correlations right; **weekday averages ~5% high** (days with no guests skipped) | Not tested | 71 s, 2 calls, **fully correct** (zero-filled: 369 park-days per weekday) | 137 s; same ~5% error, and it **claimed** to zero-fill |
| **Weekday regression (Aug 2025)** | Not tested | Not tested | 83 s, correct, with std errors and p-values | 81 s, correct (data copied by hand) |
| **Output** | Real tables and charts | Real tables | Markdown only: the code runtime has no `data_to_chart` and its Snowpark results never reach the agent loop, so there is nothing for a `table`/`chart` part to reference (it could still save a chart file; untested) | Real tables and charts |
| **Setup needs** | Semantic view and warehouse | Plus an MCP server with SQL execution | `always_allow`; no owner's rights; a narrow calling role | `always_allow` on `code_execution` |
| **Strengths** | Most governed; fast; documented; tables and charts; applies verified queries | Transparent, with no second LLM; read-only enforced by the server; documented instructions work | Any Python analysis over large pulls; best at following the view's rules with the required checklist; best answers (caveats, statistics) | Documented way to combine Analyst and Python; fastest on SQL-shaped questions |
| **Weaknesses** | Can break the view's rules when it adds calculations around the view (zero-fill); no Python | Staying on the semantic view relies only on instructions (role permitting); ~400-row `DESCRIBE` in context; not tested on the harder questions | Undocumented; not read-only; slowest; markdown output only | Python only works for small inputs (tens of rows); inherits Analyst's zero-fill error; can claim steps it didn't do |
| **Best for** | Everyday business questions | SQL-only use without Cortex Analyst | Analytical or statistical work that needs Python, run with a narrow role | Analyst questions that occasionally need small-scale Python |

## Key takeaway

The biggest correctness difference is zero-filling. When agents built on Cortex Analyst (1 and 6) computed per-day averages
themselves, they skipped days with no guests. Only agent 5, with its required checklist of view rules, got this right. Adding
zero-filled daily metrics for arrivals and leavers to the semantic view itself, like the existing `guests_on_park`, would fix it for every agent.
