# topic-memory

Shared memory for agents on Snowflake. Each **topic** is one YAML config document. `memctl` provisions it
as its own Snowflake-managed MCP server, whose tool names and descriptions come from the topic brief.
Around that server it deploys fast save/search/get/index procedures, a background **organiser**, and the
tasks that run the organiser. The first topic is `footfall_bookings` (findings about the footfall and
bookings data). See `PLAN.md` for the design and its history.

```
 agents (Claude Code, Cortex agents, ...)                         topic config (topics/*.yaml)
        │ MCP                                                              │ memctl deploy
        ▼                                                                  ▼
 FOOTFALL_BOOKINGS_MEMORY_MCP  ── findings_index / search_findings / get_findings / record_finding
        │                         (SQL procs MEM_FOOTFALL_BOOKINGS_*, owner's rights, ~1.5 s in Snowflake)
        ▼
 MEM_ITEM (all topics, arctic embeddings) ─ stream ─► triggered task ─► MEM_ORGANISE (AI_COMPLETE triage per new item)
        ▲                                             cron task ──────► MEM_REVIEW ─► MEM_FOOTFALL_BOOKINGS_ORGANISER (Cortex agent)
        └── MEM_ITEM_HISTORY / MEM_LINK / MEM_TOC / MEM_EVENT_LOG / MEM_ORGANISER_RUN
```

## Quick start (repo root, project venv)

```bash
PY=/Users/z/Dev/haven/cortex-semantic-spike/.venv/bin/python3
$PY topic-memory/memctl.py validate topics/footfall_bookings.yaml     # schema + lint + description lengths
$PY topic-memory/memctl.py render   topics/footfall_bookings.yaml     # SQL into topic-memory/build/footfall_bookings/
$PY topic-memory/memctl.py deploy   topics/footfall_bookings.yaml     # core (idempotent) + topic
$PY topic-memory/memctl.py smoke    topics/footfall_bookings.yaml [--write]
$PY topic-memory/memctl.py client   topics/footfall_bookings.yaml [--install] [--protocol]
$PY topic-memory/memctl.py status   [footfall_bookings]               # counts, backlog, last organiser runs
$PY topic-memory/memctl.py organise footfall_bookings [--review]      # run the triage (or agent review) now
$PY topic-memory/memctl.py teardown topics/footfall_bookings.yaml [--purge]
```

`deploy --only 30 50` redeploys selected templates (prefix match), and `--skip-core` leaves the shared
objects alone.

## A new topic

1. Copy `topics/footfall_bookings.yaml` and change `topic.id`, `id_prefix`, `brief`, `schema.categories`,
   `schema.attributes` and the tool names. The config has these sections:
   - `brief`: tool descriptions, the index header and the organiser prompts are all rendered from it.
   - `contributors.agent_types`: the agent types you expect. With `open: true`, other snake_case types are accepted too.
   - `schema`: categories, tags, typed attributes (`text | list | enum | number | boolean`), limits, PII regexes.
   - `retrieval`, `toc`, `organiser` (model, on-insert / cron switches, `triage_prompt`, `review_prompt`).
   - `deployment`: database/schema/warehouse, a read-only MCP server, read logging, grants.
2. Run `memctl validate`. It fails when a rendered tool description exceeds Snowflake's 2,500-character limit.
3. Run `memctl deploy`, then `memctl smoke --write`, then `memctl client --install`.

## Tools each topic gets

| Tool (footfall_bookings) | What it does | Latency (Snowflake / via MCP) |
|---|---|---|
| `findings_index` | Returns the brief, contribution rules, organiser overview, and one line per item grouped by category, with `checked_at`. Unreviewed items are marked. `category=` shows one whole category. `since=<checked_at>` or `since=30m` returns only what was added or changed since then: the cheap "what's new" re-check. | ~1.4 s / ~2.8 s |
| `search_findings` | Scores results by cosine similarity plus a boost for query words found in the text. Filters: `category`, `text_filter` (exact text such as a table name), `include_unreviewed`. Returns `checked_at`. | ~1.5 s / ~2.7 s |
| `get_findings` | Returns full items by id (comma-separated, max 20), with attributes, status, links and `replaced_by`. | ~1.5 s / ~2.6 s |
| `record_finding` | Saves one item. All input problems are reported in one reply. Returns the id and any similar existing items, flagged as likely duplicates. The item is searchable immediately with status `new`. | ~2-3 s / ~3-5 s |

Contributors pass `agent_type`; that is their identity. Only the organiser changes an item's status.

**The memory is live, and the tools say so.** Other agents keep writing, and the organiser merges and
supersedes in the background. So every tool description tells clients to check again during a task, not
just at the start:
- search before each new sub-question, before expensive queries, and before stating a number;
- re-read a finding before relying on it later;
- search right before saving;
- use `findings_index since=<checked_at>` to see what changed.

The topic's `brief.usage` sets the wording; the footfall topic's version mentions the hackathon. If
`brief.usage` is not set, a generic sentence is used.

## Organiser

- **On insert (pipeline):** a triggered task watches a stream on `MEM_ITEM` and fires within about 30 s.
  `MEM_ORGANISE` takes the new items. For each one it finds the 6 nearest items and asks `AI_COMPLETE`
  (`claude-sonnet-5`, structured JSON) for a decision: `activate | duplicate | merge | supersede | reject |
  escalate`, with optional rewrites. The decision is applied through the `MEM_ORG_*` procedures. Each item
  takes about 8 s.
- **Cadence (agent):** a cron task runs `MEM_REVIEW`. It triages any leftovers, then gives the topic's
  Cortex agent (`MEM_<TOPIC>_ORGANISER`) the `needs_review` and stale items to resolve. The agent can
  merge, fix categories and titles, and rewrites the overview at the top of the index.
- Every change bumps `REVISION`, writes `MEM_ITEM_HISTORY` (with a full snapshot) and records a reason.
  Merged and superseded items keep a `RELATED_ID` pointing at the replacement, and `get` shows it as
  `replaced_by`.

## Using it from Claude Code (local test)

`memctl client --install` added `mem-footfall-bookings` to the repo `.mcp.json`. Paths there are relative to the repo root, so start Claude Code from the repo root (not a subdirectory or a worktree without its own `.venv`). Restart Claude Code, or
use `/mcp`, and approve the server. Auth uses the same SSO `headersHelper` as the POC servers.

- **Load the index at session start** (the equivalent of `MEMORY.md`): add the `SessionStart` hook that
  `memctl client` prints to `.claude/settings.local.json`. It takes about 3-8 s and does nothing if
  Snowflake is unreachable. The command sets `SF_ROLE` when the topic has a `client_role`, and names the
  server so the session knows which `mcp__<server>__*` tools belong to that index. Tried locally on
  2026-09-29 and removed: it did not seem to work in a live session (not yet diagnosed).
- **Tell agents how to use it:** `memctl client --protocol` prints a snippet for CLAUDE.md or a subagent
  prompt. The tool descriptions already carry the full brief.
- **Headless check** (done 2026-09-27, 25 s): `claude -p "..." --mcp-config <file> --strict-mcp-config`
  called index → search → get and answered with finding ids.
- **Multi-agent test idea:** run 2-3 `claude -p` sessions or subagents in parallel with different
  `agent_type`s on overlapping footfall/bookings questions, then check `memctl status` and the index. You
  should see duplicates merged and corrections superseded.

## Tests

```bash
$PY topic-memory/tests/organiser_eval.py [--review] [--keep]   # scratch topic 'memtest': 11 fixtures, expected decisions
$PY topic-memory/tests/concurrency_test.py 8                   # parallel MCP saves (needs memtest deployed: --keep)
```

Results on 2026-09-27: organiser eval **11/11**, run twice. The agent review ran cleanly and wrote the
overview. 8 parallel saves produced 8 unique ids, each with one history row (p50 4.9 s under parallel load).

## Platform findings (spikes, 2026-09-26/27)

- An MCP server spec only allows `tools:`. `instructions` is rejected, `resources/list` and `prompts/list`
  are unsupported, and `initialize` returns no instructions. So the brief lives in the tool descriptions
  and the index tool, and the SessionStart hook supplies what `MEMORY.md` auto-loading does.
- A tool `description` may be at most **2,500 characters** (checked at create). A tool `name` may be at
  most **64 characters**, but that is only checked at call time.
- GENERIC tool arguments must be **scalars** (string, number, boolean). Array and object arguments fail
  with `unsupported parameter type`. Lists are therefore passed as comma-separated strings, and each
  attribute gets its own argument.
- Omitted optional arguments take the procedure's SQL `DEFAULT`. A VARIANT return reaches the client as
  pretty-printed JSON text.
- Owner's-rights procedures work as MCP tools, from tasks, and with `DATA_AGENT_RUN` inside them.
  Owner's-rights procedures cannot create temporary tables, so the stream is consumed by
  `INSERT ... SELECT ... FROM stream WHERE FALSE` into a permanent sink table.
- Per-call overhead: a SQL Scripting procedure takes about 0.25 s, a nested SQL call adds about 0.25 s, a
  **Python procedure takes about 3.6 s**, and MCP adds about 1.2 s. That is why the fast tools are fully
  rendered SQL per topic.
- Snowflake Scripting quirks: `SELECT ... INTO` rejects scalar subqueries (use a derived table in FROM).
  Local variable names clash case-insensitively with parameter names. `INSERT ALL` works. Lambdas
  (`FILTER`/`TRANSFORM`) can reference row columns.
- `TRIGGER` is a reserved word, and Snowflake regex has no `\b`.
- `AI_COMPLETE` models available here: `claude-sonnet-5`, `claude-opus-5-5`, `claude-haiku-4-5` and
  others. Structured `response_format` works from a task.

## Current state / open points

- `footfall_bookings` is live with the 4 findings migrated from the POC `AGENT_MEMORY` (FBF-00014..17).
  FBF-00016 is `needs_review`: its example SQL uses a pseudo filter (`status = 'live'`) from the original
  POC note. The nightly review will pick it up; it would be better to re-verify it with a query.
- The existing Cortex agents (arrivals / bookings / master) are **not** rewired yet, as requested. When
  they are, add `mcp_servers: - server_spec: {name: ...FOOTFALL_BOOKINGS_MEMORY_MCP}` and the protocol
  snippet.
- `deployment.usage_roles` is empty: everything runs as HAVEN_DATA_SCIENCE_DEV. Other roles need grants
  first (`80_grants`).
- Cost: each save triggers one `AI_COMPLETE` call (plus a warehouse wake-up). The nightly review is one
  agent run, about 1 min.
- Spike scripts are in `spikes/`. They drop their own objects.
