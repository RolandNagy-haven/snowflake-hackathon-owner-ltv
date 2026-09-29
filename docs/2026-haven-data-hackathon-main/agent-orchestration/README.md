# agent-orchestration

Multi-agent test scenario on Snowflake Cortex Agents, all in `HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL`.
No semantic views: the data agents query the fact tables directly with SQL.

```
                 end user
                    |
            HAVEN_MASTER_AGENT            tools: ask_arrivals_agent, ask_bookings_agent
              /             \
   ARRIVALS_AGENT         BOOKINGS_AGENT   tools: code_toolset_all (snowflake_sql_execute, python, ...)
   FCT_PARK_ARRIVAL       FCT_HOLIDAY_BOOKINGS      + ask_knowledge_assistant
              \             /
             KNOWLEDGE_AGENT              tools: recall_observations, remember_observation, retire_observation
                    |
              AGENT_MEMORY (table, arctic embeddings)
```

## How agents talk to each other

Snowflake has no native "agent calls agent" tool (`agent_toolset` only *copies* another agent's
tools; MCP connectors need per-user OAuth and cannot point back at a Snowflake-managed MCP server
in a documented way). So each hop is a **generic (custom) tool backed by a caller's-rights
procedure** that runs the target agent with `SNOWFLAKE.CORTEX.DATA_AGENT_RUN` and returns its final
text:

- `RUN_AGENT(agent_name, question)` (Python): runs the agent, returns
  `{"agent", "answer", "tools_used", "elapsed_s", ["warnings"], ["error"]}` and logs the hop to
  `AGENT_CALL_LOG`.
- `ASK_ARRIVALS_AGENT(question)`, `ASK_BOOKINGS_AGENT(question)`, `ASK_KNOWLEDGE_AGENT(request)`:
  thin wrappers, one per target, so each caller gets a narrowly scoped tool.

Caller's rights keeps the end user's grants all the way down, and keeps the sub-agent's code
sandbox. The docs say that owner's-rights invocation strips the code-execution tools.

The user ↔ master conversation always lives in the master's server-side thread. The master ↔
specialist hop has two modes, chosen at deploy time:

| `--specialist-mode` | Master tools call | Specialist sees | Master must |
|---|---|---|---|
| `stateless` (default) | `ASK_ARRIVALS_AGENT(question)`, `ASK_BOOKINGS_AGENT(question)` | only the current question | restate all context (dates, parks, definitions) every time |
| `threaded` | `ASK_*_AGENT_THREADED(question, thread_ref)` | its own earlier turns in that thread: questions, answers, SQL | continue the thread only for follow-ups that build on that specialist's answer, where it may say "break that down by day"; otherwise start `"new"` with a self-contained question |

In threaded mode every specialist answer returns `thread_ref = "<thread_id>:<assistant_message_id>"`.
The ref lives in the master's own thread as part of the tool results, so each user conversation
gets its own specialist threads, with no lookup table. Passing an older ref forks that thread. The
master is told to always use the latest ref, never to pass one specialist's ref to the other,
and, when unsure, to start a new thread.

Both modes use the same `RUN_AGENT(agent, question, thread_ref)`. `thread_ref` is `'stateless'`,
`'new'` (it creates a thread through `DATA_AGENT_RUN(..., TRUE)`), or `'<thread_id>:<message_id>'`
(it continues the thread through `thread_id` + `parent_message_id`). `AGENT_CALL_LOG` records
`THREAD_ID` and `PARENT_MESSAGE_ID`. Knowledge-assistant calls are always stateless.

`06_master_agent.sql` is a template:
- `{{SPECIALIST_MODE}}` is replaced by the mode name.
- Lines between `#@stateless` / `#@threaded` and `#@end` are kept only for that mode.

`deploy.py` renders the template. The mode is written into the master agent's COMMENT
(`[specialist_mode=threaded]`), so a redeploy without the flag keeps the deployed mode. To see
exactly what would be deployed, run `deploy.py 06 --specialist-mode threaded --dry-run`.

## Shared memory protocol

The data agents send the knowledge agent plain-text requests:

- `RECALL arrivals|bookings|all: <topic>`: returns the relevant notes, or `No relevant notes.`
- `RECORD arrivals|bookings: <topic>: <observation> (from X_AGENT)`: the knowledge agent looks for
  duplicates or conflicts first. It then stores the note, reports the existing duplicate, or
  retires the old note and stores the corrected one.

Recall uses cosine similarity over `EMBED_TEXT_1024('snowflake-arctic-embed-l-v2.0')`, computed
inside the procedure. A note can be recalled the moment it is written, because there is no
Cortex Search refresh lag. Retired notes stay in the table for audit.

## Files

| File | Creates |
|---|---|
| `sql/01_agent_memory.sql` | `AGENT_MEMORY` table; `REMEMBER_OBSERVATION`, `RECALL_OBSERVATIONS`, `RETIRE_OBSERVATION` procs |
| `sql/02_agent_delegation.sql` | `AGENT_CALL_LOG` table; `RUN_AGENT` + `ASK_*_AGENT` (stateless) and `ASK_*_AGENT_THREADED` procs |
| `sql/03_knowledge_agent.sql` | `KNOWLEDGE_AGENT` |
| `sql/04_arrivals_agent.sql` | `ARRIVALS_AGENT` (agent-1) |
| `sql/05_bookings_agent.sql` | `BOOKINGS_AGENT` (agent-2) |
| `sql/06_master_agent.sql` | `HAVEN_MASTER_AGENT` (template, per specialist mode) |
| `sql/99_teardown.sql` | drops agents + procs (keeps memory / log tables) |
| `deploy.py` | renders + runs the scripts (all `0*` by default, or by prefix); `--specialist-mode`, `--dry-run` |
| `scenario_threaded.sh` | 4-turn master conversation testing thread continue / new decisions |
| `ask.py` | talks to any of the agents, prints the tool trace + answer; `--memory`, `--log N` |
| `runs/` | saved responses from the test runs |

## Usage (repo root, project venv)

```bash
python agent-orchestration/deploy.py                  # deploy / redeploy everything (keeps deployed mode)
python agent-orchestration/deploy.py --specialist-mode threaded     # specialists keep conversation threads
python agent-orchestration/deploy.py 06 --specialist-mode stateless # switch the master back
python agent-orchestration/deploy.py 04 05            # just the two data agents
python agent-orchestration/deploy.py 99_teardown      # remove

python agent-orchestration/ask.py master "..." --thread demo --reset   # new conversation
python agent-orchestration/ask.py master "and last year?" --thread demo
python agent-orchestration/ask.py arrivals "..."      # talk to a specialist directly
python agent-orchestration/ask.py knowledge "RECALL all: snapshot"
python agent-orchestration/ask.py --memory            # what the agents have learned
python agent-orchestration/ask.py --log 20            # agent-to-agent traffic
```

## Findings from building it (2026-09-25)

- **`code_toolset_all` needs `instructions.system`.** It is the coding-agent toolset: bash,
  files, grep, web_search and read-only `snowflake_sql_execute`. Its built-in behaviour is to
  search the account for data sources first (`cortex search object`) and prefer semantic views
  via `cortex analyst`. With the rules only in `instructions.orchestration`, the agent ignored
  them: it used `FOOTFALL_ARRIVALS_SV_V2`, and once even `NEXUS_BRONZE...ARRIVAL`. Moving the role
  and rules into `instructions.system` fixed it. The general agent docs don't list `system`; the
  coding-agent page does. Individual sandbox tools can't be disabled, only skills
  (`disabled_skills`).
- `permission_policy: always_allow` is required. `DATA_AGENT_RUN` can't answer approval prompts.
- A generic tool's `query_timeout` is capped at **600 s**. This caps each sub-agent call from
  the master at 10 minutes.
- `CREATE AGENT ... COPY GRANTS COMMENT = ...` fails to parse in this account, so the scripts
  omit `COPY GRANTS`. Re-grant `USAGE` after a replace if other roles use the agents.
- Snowpark binds Python `None` as the string `'None'`; the log insert uses `NULLIF(?, '')`.
- A sub-agent's text includes its narration between tool calls. `RUN_AGENT` returns only the
  text after the last tool call.
- **Latency** (orchestration model `auto`, which resolved to claude-opus-4-6):
  - Knowledge call: 10-25 s.
  - Data agent: 70-170 s.
  - Master cross-domain question: about 6 min (two sequential specialist calls, each with
    RECALL / RECORD hops).
  - Recalled notes cut exploration: the second bookings run skipped the status-code discovery.
- `FCT_HOLIDAY_BOOKINGS` is a daily full snapshot, about 4.9M rows × 3,000 dates (4.1B rows). The
  bookings agent is instructed to filter `SNAPSHOT_DATE` to one date, or a few, in every query.
- **Threaded mode test** (`scenario_threaded.sh`, 2026-09-25): the master chose `new` / continue
  / `new` / continue correctly. Continued follow-ups took **13 s and 29 s**, against 48-67 s for
  fresh questions: the specialist reused its own SQL and definitions and skipped the memory recall.
- **Client stream hang.** The agent SSE stream can stay open after the final `response` event.
  The cortex-agent skill's client now stops reading at that event. `ask.py` also recovers the
  answer from the thread (`GET /api/v2/cortex/threads/{id}`) if the stream drops.
- Threads created by the procedures have `origin_application = sql_function`. Use `ask.py --log`
  (`THREAD_ID`) or the threads API to find them.
- Every `ask.py` invocation is a new process and may trigger an EXTERNALBROWSER SSO login. If a
  run seems stuck at "Initiating login request", check the browser.
