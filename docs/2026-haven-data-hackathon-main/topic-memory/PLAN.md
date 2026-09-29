# topic-memory: development plan

> **Status 2026-09-27: phases 0–2 are built and deployed, and phase 3 is done for Claude Code only (the
> Cortex agents are not rewired, as requested). See README.md for usage, test results and platform findings.**
> Decisions taken: (1) one shared set of tables, (2) everything in `PETERZENTAI_LOCAL`, (3) a triage pipeline
> on insert plus an agent review on a schedule, (4) contributors add items and only the organiser changes
> status, (5) contributor identity is the `agent_type` argument.
> Where the build differs from the plan below, because of the spike results:
> - The fast tools are **fully rendered SQL procedures per topic**, not thin wrappers over core procedures.
>   A Python procedure costs ~3.6 s per call and a nested call ~0.25 s. The organiser procedures stay core,
>   with per-topic wrappers for the agent.
> - Tool inputs are scalars only: tags and list attributes are comma-separated strings, one argument per attribute.
> - MCP servers can't carry instructions, resources or prompts. The brief goes into the tool descriptions
>   (max 2,500 chars) and the index tool. A Claude Code SessionStart hook loads the index at session start.
> - The index is computed live from the items; only the overview at its top is written by the organiser
>   (in `MEM_TOC`). No per-section TOC rows are stored.
> - Search scores cosine similarity plus a keyword boost, with a floor (`search_floor`), because short
>   keyword queries embed poorly.

A templated, Snowflake-native **shared memory / knowledge collector**. Each *topic* is described by one
config document, and a provisioning CLI turns that document into a dedicated, semantically named
Snowflake-managed MCP server with fast read/write tools, a table of contents, and a background
organiser. It builds on `agent-orchestration/` (`01_agent_memory.sql`, `03_knowledge_agent.sql`)
and `invocation-poc/` (MCP server, auth).

## 1. What changes compared with the POC

| POC (`agent-orchestration`) | topic-memory |
|---|---|
| One hard-coded memory (`AGENT_MEMORY`, domains arrivals/bookings/general) | Any number of topics, each from a config doc |
| Every read/write goes through `KNOWLEDGE_AGENT` (10-25 s per call) | Direct procedure tools over MCP: save / get / search / TOC in ~1-2 s, no agent loop |
| De-duplication happens synchronously inside the agent call | Save is fast and returns near-duplicates. Dedup, merge and rewrite happen afterwards in the **organiser** |
| Generic tool names (`recall_observations`) | Tool names, titles and descriptions come from the topic brief (`record_finding`, `search_findings`, ...) |
| No index; agents can only search | A curated **TOC** (like Claude Code's `MEMORY.md`) that agents read first |
| Plain-text protocol (`RECALL` / `RECORD`) | Typed tool inputs validated against the topic schema (categories, attributes, limits) |
| Only Cortex agents can use it | Any MCP client: Claude Code, Cortex Agents (`mcp_servers:`), other platforms |

Kept from the POC: inline `EMBED_TEXT_1024` + `VECTOR_COSINE_SIMILARITY`, so a new item is
searchable immediately (no Cortex Search refresh lag); retire instead of delete; per-write audit;
templated SQL rendered by a Python deployer.

## 2. Architecture

```
                 topic config (YAML)  ──►  memctl (validate / render / deploy / smoke / teardown)
                                                       │
            ┌──────────────────────────────────────────┴──────────────────────────────┐
            ▼ core (once)                                                            ▼ per topic
  MEM_TOPIC_REGISTRY   MEM_ITEM (+ VECTOR)                     <T>_SAVE / _GET / _SEARCH / _TOC   (owner's-rights procs)
  MEM_ITEM_VERSION     MEM_LINK   MEM_TOC                      <T>_ORG_* organiser-only procs
  MEM_EVENT_LOG        MEM_ORGANISER_RUN                       MCP SERVER <T>_MEMORY_MCP         (read-write)
  core procs: MEM_CORE_SAVE / SEARCH / GET / TOC / ...         MCP SERVER <T>_MEMORY_RO_MCP      (optional, read-only)
                                                               AGENT <T>_ORGANISER_AGENT
                                                               STREAM + triggered TASK (on insert), cron TASK (cadence)

  clients:  Claude Code (mcp add-json + optional SessionStart TOC hook)
            Cortex Agents (mcp_servers: - server_spec: {name: <T>_MEMORY_MCP}) + generated "memory protocol" prompt snippet
```

**Main design choices** (each can be revisited, see §7):

1. **Shared core tables keyed by `TOPIC_ID`, with thin per-topic procedures.** An MCP `GENERIC`
   tool is bound to one procedure with fixed arguments, so the topic has to be built into the
   procedure. Each per-topic wrapper passes its topic id and config to the core procedures
   (`MEM_CORE_*`), the same pattern as `ASK_*_AGENT` → `RUN_AGENT`. Schema migrations and bug fixes
   happen once, cross-topic monitoring is a single query, and topics stay isolated through grants
   on their own procedures and MCP server.
2. **Owner's-rights tool procedures.** Clients get `USAGE` on the MCP server and the procedures,
   never direct DML on the tables. All writes pass through validation.
3. **Save is fast and optimistic.** The `new` status is searchable at once, flagged as
   `unreviewed`. The organiser then promotes, merges, supersedes or rejects the item
   asynchronously.
4. **The organiser has two engines.** A deterministic **pipeline** (Python procedure plus
   `AI_COMPLETE` with structured JSON output, with decisions applied in code) handles
   per-insert triage. The Cortex **agent** handles cadence reviews (consolidation, gap
   analysis, TOC rewrite). This avoids an agent loop per insert, whose cost and 10-25 s
   latency the POC measured.

## 3. Modules

### M0. Platform spikes (do first; each is a short throwaway script with results written into README findings)
| # | Question | Why it matters |
|---|---|---|
| S1 | Limits on MCP tool `name`/`title`/`description` length, and whether `input_schema` descriptions reach the client | Rich per-topic descriptions are the main feature |
| S2 | Does a Snowflake-managed MCP server support server-level `instructions`, `resources` or `prompts`? | That would be the natural home for the topic brief and TOC (auto-injected like `MEMORY.md`) |
| S3 | `GENERIC` tool on an **owner's-rights** procedure called via MCP: works? whose identity does `CURRENT_USER()` report? | Access model (§2.2) and `CREATED_BY` attribution |
| S4 | Procedure return type: `VARIANT`/`OBJECT` versus `VARCHAR` JSON: what does the MCP client receive? | Tool output format |
| S5 | Latency of save (embed + insert) and search (embed + cosine scan over 10k rows): warm versus suspended XS warehouse | The "fast" requirement; decide warehouse auto-suspend / keep-warm |
| S6 | Triggered task (`WHEN SYSTEM$STREAM_HAS_DATA`, no schedule) calling a procedure that runs `DATA_AGENT_RUN` and `AI_COMPLETE`: role, privileges, minimum trigger interval | Organiser on insert |
| S7 | Concurrent saves from several sessions (sequence ids, no lost updates when the organiser edits while agents save) | Multi-agent correctness |

### M1. Core schema (`templates/core/10_tables.sql`)
- `MEM_TOPIC_REGISTRY`: `TOPIC_ID`, `VERSION`, `CONFIG` (VARIANT, full rendered config), `CONFIG_HASH`, `MCP_SERVER`, `ORGANISER_AGENT`, `STATUS`, `DEPLOYED_AT`, `DEPLOYED_BY`.
- `MEM_ITEM`: `ITEM_ID` (short readable `<PREFIX>-000123` from a per-topic sequence), `TOPIC_ID`, `TITLE`, `BODY`, `CATEGORY`, `TAGS` ARRAY, `ATTRIBUTES` VARIANT (topic-defined fields), `AS_OF_DATE`, `CONFIDENCE`, `SOURCE_AGENT_TYPE`, `SOURCE_AGENT_INSTANCE` (conversation/session ref), `CREATED_BY`, `CREATED_AT`, `UPDATED_AT`, `STATUS` (`new|active|superseded|merged|rejected|retired`), `STATUS_REASON`, `SUPERSEDED_BY`, `REVIEWED_AT`, `REVISION` int, `EMBEDDING VECTOR(FLOAT,1024)`.
- `MEM_ITEM_VERSION`: an append-only copy of each revision (who, when, what operation, why), used for audit and rollback.
- `MEM_LINK`: `FROM_ID`, `TO_ID`, `RELATION` (`duplicates|supersedes|refines|related|contradicts|merged_into`), `CREATED_BY`.
- `MEM_TOC`: `TOPIC_ID`, `SECTION`, `ORDINAL`, `LINE`, `ITEM_IDS`, `GENERATED_AT`, `GENERATED_BY` (organiser run), plus `MEM_TOC_DOC` holding the rendered text.
- `MEM_EVENT_LOG`: every tool call (topic, tool, caller, source agent, args summary, latency, result size, error), used for usage stats and latency tracking.
- `MEM_ORGANISER_RUN`: each organiser run (trigger, engine, items in, actions taken, tokens/credits, error).
- `MEM_FEEDBACK` (phase 2): contributor flags such as "outdated" or "wrong", consumed by the organiser.

### M2. Core procedures (`templates/core/20_procs.sql`), topic-agnostic, all take `TOPIC_ID`
- `MEM_CORE_SAVE(topic_id, payload VARIANT)`: validates against the registered config (category enum, required attributes, length limits, `as_of_date` format, PII regex deny-list). Embeds `title + body + tags`, inserts with status `new`, writes a version row and an event row. **Returns** `{item_id, status:"new", similar:[top 3 active items above dup_threshold with id/title/similarity]}` so the caller can see possible duplicates at once, without waiting.
- `MEM_CORE_GET(topic_id, ids ARRAY)`: full items plus links (`superseded_by`, `related`), up to N per call.
- `MEM_CORE_SEARCH(topic_id, query, filters VARIANT, top_k)`: hybrid ranking: cosine similarity plus a keyword boost (title/tags match), with filters on category, tags, `as_of` range, source agent type and `include_unreviewed` (default true). Returns compact rows (id, title, category, one-line summary, as_of, status, score). Callers use `get` for the full body.
- `MEM_CORE_TOC(topic_id, section)`: returns the brief header, "how to contribute" lines, and the curated `MEM_TOC_DOC`, with **live addenda** listing items not yet in the TOC (new since the last organiser run). If the organiser has never run, a TOC is computed from the items grouped by category. Output is capped by `toc.max_lines`, like the 200-line cap on `MEMORY.md`.
- Organiser-only procedures: `MEM_ORG_LIST_PENDING`, `MEM_ORG_UPDATE_ITEM` (rewrite title/body/category/tags; re-embeds; bumps the revision), `MEM_ORG_SET_STATUS` (activate/reject/retire/supersede, with a required reason), `MEM_ORG_MERGE(ids, merged_payload)`, `MEM_ORG_LINK`, `MEM_ORG_WRITE_TOC(sections VARIANT)`.

### M3. Topic config spec (`schema/topic_config.schema.json` + docs)
One YAML document per topic (sketch in §4). Sections: `topic`, `brief`, `schema`, `tools`,
`retrieval`, `toc`, `organiser`, `access`, `deployment`. Validation checks the JSON Schema plus
lint rules: every category has a description; tool descriptions fall between a minimum and
maximum length (maximum from S1); the organiser prompt mentions every category; no unresolved
placeholders. Tool descriptions are **templates with defaults**: a topic can override any of
them, but by default they are assembled from `brief.*`, so even a minimal config produces
semantic descriptions.

### M4. Per-topic templates (`templates/topic/*.sql.j2`)
- `30_procs.sql.j2`: `<T>_SAVE`, `<T>_GET`, `<T>_SEARCH`, `<T>_TOC` wrappers with typed arguments (one argument per schema field, so the MCP `input_schema` is explicit), plus `<T>_ORG_*` wrappers.
- `40_mcp_server.sql.j2`: the `<T>_MEMORY_MCP` server with the four tools (names such as `record_finding`, `get_findings`, `search_findings`, `findings_index`). Titles, descriptions and per-parameter descriptions are rendered from the config. An optional `<T>_MEMORY_RO_MCP` server (get/search/toc only) serves read-only consumers.
- `50_organiser_agent.sql.j2`: `<T>_ORGANISER_AGENT`, whose `instructions.system` combines a fixed core protocol with the topic's `organiser.prompt`. Its tools are the `<T>_ORG_*` procedures plus search/get. It uses `permission_policy: always_allow` and a budget from config (POC finding).
- `60_organiser_pipeline.sql.j2`: the `<T>_ORGANISE(trigger)` Python procedure. For each pending item it fetches neighbours, then `AI_COMPLETE` with a JSON schema returns `{action: activate|duplicate_of|supersedes|merge_with|reject|needs_agent, rewrite?, category?, tags?, reason}`. Code applies the decision and logs to `MEM_ORGANISER_RUN`. `needs_agent` escalates hard cases to the agent.
- `70_tasks.sql.j2`: a stream on `MEM_ITEM` filtered by topic in the task body, a triggered task (on insert; micro-batched) calling `<T>_ORGANISE('insert')`, and a cron task calling the agent for the cadence review (`consolidate` duplicates, retire stale items using `as_of` and `review_after_days`, fill TOC gaps, rewrite TOC).
- `80_grants.sql.j2`: roles from `access.*`: reader (RO server), contributor (RW server), admin (organiser, tasks).
- `99_teardown.sql.j2`: drops the per-topic objects. Data is kept unless `--purge`.

### M5. Provisioning CLI `memctl` (Python, reusing the `snowflake-query` session like `agent-orchestration/deploy.py`)
```
memctl validate topics/footfall_bookings.yaml
memctl render   topics/footfall_bookings.yaml        # -> build/footfall_bookings/*.sql (reviewable, dry run)
memctl deploy   topics/footfall_bookings.yaml [--core] [--only procs,mcp,organiser,tasks]
memctl status   [topic]                               # registry, config drift (hash), item counts, last organiser run
memctl smoke    footfall_bookings                     # calls every tool over the real MCP endpoint (sf_mcp_auth)
memctl client   footfall_bookings --claude-code|--cortex-snippet|--hook
memctl teardown footfall_bookings [--purge]
memctl seed     footfall_bookings --from-agent-memory # migrate the POC AGENT_MEMORY rows
```
Rendering uses Jinja2 (`StrictUndefined`) in place of the POC's ad-hoc `#@mode` tags, and the
fully rendered config is stored in `MEM_TOPIC_REGISTRY` so the core procedures validate against
exactly what was deployed. `deploy` is idempotent (`CREATE OR REPLACE` for code objects,
`IF NOT EXISTS` plus additive `ALTER` for tables) and re-grants after replace (POC finding:
`COPY GRANTS` fails to parse on agents).

### M6. Client integration
- **Claude Code:** `memctl client --claude-code` prints the `claude mcp add-json` entry (http + `headersHelper` from `invocation-poc/sf_mcp_auth.py`). `--hook` generates a `SessionStart` hook that calls `<T>_TOC` and injects the result as context. This is the closest equivalent of `MEMORY.md` being loaded automatically (MCP itself cannot push context, unless S2 finds server instructions).
- **Cortex Agents:** `--cortex-snippet` prints the `mcp_servers:` entry plus a generated **memory protocol** block for the agent's `instructions.system`: call the index first; search before exploring; save at most N durable items per task, with a required `source_agent_type` and `source_agent_instance`.
- Migrate `ARRIVALS_AGENT` / `BOOKINGS_AGENT` from `ask_knowledge_assistant` to the topic MCP server. Their existing `scenario_threaded.sh` and `ask.py` runs become the before/after benchmark (the POC measured 10-25 s per memory hop).

### M7. Tests and evals (`tests/`)
- **Render tests:** every template renders for the example topic and for a minimal topic; the rendered SQL parses (Snowflake `EXPLAIN`/dry run where possible).
- **Procedure tests** against a scratch topic: validation rejects bad category, missing attribute, oversize body and PII; save → search → get round trip; status transitions; the TOC includes unreviewed addenda.
- **Concurrency:** N parallel savers plus an organiser run: no lost writes, sequence ids unique, revisions consistent.
- **Organiser quality eval:** a seeded fixture with exact duplicates, paraphrases, a correction that supersedes an older fact, an out-of-scope item and a PII item. Expected actions are checked, and the score is tracked per prompt version.
- **Latency budget** (from S5): save p50 under 2 s and search p50 under 2 s on a warm XS warehouse; the numbers are recorded in the README.

### M8. Observability and operations
Views: `MEM_V_TOPIC_STATS` (items by status/category, growth, unreviewed backlog age),
`MEM_V_TOOL_USAGE` (calls, latency percentiles, top contributors by agent type), and
`MEM_V_ORGANISER` (actions, errors, credits). `memctl status` reads these. Alerting is out of
scope for v1.

## 4. Example topic config (sketch of `topics/footfall_bookings.yaml`)

```yaml
topic:
  id: footfall_bookings            # slug -> object prefix MEM_FOOTFALL_BOOKINGS_*
  name: Haven footfall & bookings data findings
  item_noun: finding               # drives tool names: record_finding, search_findings, get_findings, findings_index
  id_prefix: FBF
  version: 1
  owner: PETERZENTAI

brief:
  purpose: >
    Durable, verified knowledge about Haven's guest footfall (guests on park, arrivals, leavers) and holiday
    bookings data, collected by the agents that analyse it so that later agents skip re-discovery.
  sources:                          # what the findings are about (used in descriptions + organiser scope checks)
    - HAVEN_STORE.ARRIVAL.FCT_PARK_ARRIVAL
    - HAVEN_STORE.BOOKING.FCT_HOLIDAY_BOOKINGS
    - HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V3
    - data-views DAILY_FOOTFALL_FACTS_V3 / FOOTFALL_FUTURE_CHANNELS_V4
  contribute_when: >
    You established something another analyst would otherwise have to rediscover: table grain, join keys,
    code meanings, data-quality issues, business definitions, a validated headline number, a proven query pattern.
  how_to_write: >
    One atomic, self-contained fact per finding. Name tables and columns fully, state units and the date the
    fact refers to (as_of_date), include the SQL that proves it when useful. Search first; if a finding already
    exists and yours corrects it, record yours with supersedes=<id>.
  do_not_save: >
    Personal data (guest names, emails, individual guest/booking ids as examples), one-off answers to a single
    question, speculation without evidence, anything derivable in one DESCRIBE.

schema:
  categories:
    data_structure:   "Grain, keys, joins, partitioning/snapshot semantics of a table or view"
    definition:       "Business definitions and rules (what counts as an arrival, a booking, a guest night...)"
    data_quality:     "Known gaps, anomalies, sentinel values, late-arriving data, with scope and dates"
    validated_metric: "A checked headline number with its exact definition, filters and as_of_date"
    query_pattern:    "A proven, efficient SQL pattern (e.g. filter SNAPSHOT_DATE first on bookings)"
    cross_domain:     "How footfall and bookings relate or reconcile"
    open_question:    "Something observed but not yet explained; the organiser tracks these"
  attributes:
    tables:       {type: array, items: string, required: true, description: "Fully-qualified tables/views involved"}
    evidence_sql: {type: string, required: false, max_len: 4000}
    confidence:   {type: enum, values: [verified, likely, hypothesis], required: true}
  limits: {title_max: 120, body_max: 3000, tags_max: 8}

tools:                               # optional overrides; defaults are rendered from brief.*
  save:   {description_extra: "Returns possible duplicates - if one matches, don't retry; the organiser merges."}
  search: {description_extra: "Search before querying FCT_HOLIDAY_BOOKINGS: it is a 4B-row daily snapshot."}

retrieval: {embed_model: snowflake-arctic-embed-l-v2.0, top_k_default: 8, top_k_max: 25, min_similarity: 0.40, dup_threshold: 0.88}
toc:       {group_by: category, max_lines: 150, section_item_limit: 25, pin: []}

organiser:
  on_insert: {enabled: true, engine: pipeline, model: claude-sonnet-5, batch_max: 20}
  cadence:   {enabled: true, engine: agent, cron: "0 5 * * * Europe/London", budget_seconds: 600}
  review_after_days: {validated_metric: 90, data_quality: 60}
  prompt: |
    You curate the footfall & bookings findings. Keep one finding per fact. Merge paraphrases; when a newer
    finding corrects an older one, supersede the older one and keep the audit reason. Reject out-of-scope or
    personal data. Reclassify misfiled categories. Promote open_questions that later findings answer.
    Rewrite the index so a new analyst can scan it in one minute: one line per finding, most-used first.

access: {reader_roles: [HAVEN_DATA_SCIENCE_DEV], contributor_roles: [HAVEN_DATA_SCIENCE_DEV], admin_role: HAVEN_DATA_SCIENCE_DEV}
deployment: {database: HAVEN_DATA_SCIENCE_DEV, schema: PETERZENTAI_LOCAL, warehouse: HAVEN_DATA_SCIENCE_DEV_WAREHOUSE_XSMALL, read_only_server: true}
```

Resulting MCP tools (server `FOOTFALL_BOOKINGS_MEMORY_MCP`):

| Tool | Proc | Purpose |
|---|---|---|
| `findings_index` | `MEM_FOOTFALL_BOOKINGS_TOC` | Brief, contribution rules and curated index. Call once at the start |
| `search_findings` | `..._SEARCH` | Hybrid search with category/table/as-of filters |
| `get_findings` | `..._GET` | Full findings by id(s), including supersession links |
| `record_finding` | `..._SAVE` | Typed save; returns the id and possible duplicates |

## 5. Delivery phases

| Phase | Scope | Exit criterion |
|---|---|---|
| **0. Spikes** | S1-S7 | Findings recorded; §7 decisions confirmed or changed |
| **1. Walking skeleton** | M1, M2 (save/get/search/toc, no organiser), M3 schema, M4 procs + MCP, M5 `validate/render/deploy/smoke`, example topic | From Claude Code: `findings_index` → `record_finding` → `search_findings` works end to end, with latency measured |
| **2. Organiser** | M2 org procs, M4 pipeline + agent + tasks, TOC generation, `MEM_ORGANISER_RUN` | A seeded duplicate is merged within about 1 min of insert; the nightly run rewrites the TOC; eval fixture passes |
| **3. Clients** | M6: Claude Code entry + SessionStart hook, Cortex snippet, migrate arrivals/bookings agents, `seed --from-agent-memory` | POC scenario re-run: memory hops drop from 10-25 s to about 2 s; answers keep their quality |
| **4. Hardening** | M7 concurrency/evals, M8 views, RO server, teardown, a **second topic** (e.g. F&B retail findings) provisioned from config alone | A second topic deploys with no code change |

## 6. Proposed layout

```
topic-memory/
  PLAN.md  README.md
  memctl.py                      # CLI entry
  memctl/  config.py render.py deploy.py smoke.py client.py
  schema/topic_config.schema.json
  templates/core/   10_tables.sql 20_procs.sql 30_views.sql
  templates/topic/  30_procs.sql.j2 40_mcp_server.sql.j2 50_organiser_agent.sql.j2
                    60_organiser_pipeline.sql.j2 70_tasks.sql.j2 80_grants.sql.j2 99_teardown.sql.j2
  topics/footfall_bookings.yaml
  tests/  fixtures/organiser_eval.yaml
  build/                         # rendered SQL (gitignored)
```

## 7. Decisions to confirm

1. **Shared core tables with a topic column** (recommended) **or fully separate tables per topic.** Separate tables isolate more strongly but mean N schema migrations.
2. **Where topics live.** Dev: `HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL` with `MEM_<TOPIC>_` prefixes, or one schema per topic (needs CREATE SCHEMA).
3. **Organiser engine per trigger.** Recommended: pipeline on insert, agent on cadence. Agent-only is simpler but costs an agent run per insert batch.
4. **Can contributors edit or retire?** v1: no. Contributors only save (optionally with `supersedes=<id>`), and only the organiser changes status. A `flag_finding` tool can come in phase 4.
5. **Contributor identity.** MCP calls run as a Snowflake user, so agent type and conversation instance must be **required tool arguments** (`source_agent_type`, `source_agent_instance`); they are not inferable.
6. **Organiser model.** Default `claude-sonnet-5` via `AI_COMPLETE` (pipeline) and `auto` for the agent, depending on account availability.

## 8. Risks

- **Prompt injection or bad writes.** Mitigations: owner's-rights procedures with validation, a PII deny-list, the organiser's reject path, a read-only server for consumers, and full version history.
- **Warehouse cold start** breaks "fast". Decided by S5: keep-warm, a longer auto-suspend, or serverless options.
- **MCP description limits** cap how much of the brief fits in tool descriptions. `findings_index` returns the full brief anyway.
- **Triggered-task/agent privileges** (S6). Fallback: a cadence-only organiser every N minutes.
- **Embedding model or dimension change** needs a re-embed job. Store the model name per row and add `memctl reembed`.
