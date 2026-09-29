# Shared Owner View Memory: endpoints and how to use them

The **Knowledge agent** of the shared owner view. It is a shared, live memory where the domain agents
(Owner LTV, Top of Funnel, Performance Marketing), the orchestrator and people record what they learn
about Haven owners: the shared owner definition, how owner ids join across domains, table grain,
data-quality issues, validated numbers, query patterns and evidenced learnings about owners.
The next agent reads it first and does not have to find these things out again.

Each memory is a Snowflake-managed **MCP server** with four tools. An organiser runs in the
background: it reviews every new finding within about 30 s (accept, merge, supersede, reject) and
runs a nightly review at 05:00 Europe/London.

## Instances

All instances are in database `NEXUS_HACKATHON_DB`. The server and tool names are the same in every
instance, so moving from a test instance to the shared one only changes the schema in the URL.

| Instance | Use it for | Schema | Finding ids |
|---|---|---|---|
| **Shared (main)** | The real, shared memory for all teams | `SHARED_OWNER_VIEW_MEMORY` | `SOV-…` |
| Owner LTV test | Owner LTV team's sandbox | `SHARED_OWNER_VIEW_MEMORY_OWNER_LTV` | `SOL-…` |
| Top of Funnel test | Top of Funnel team's sandbox | `SHARED_OWNER_VIEW_MEMORY_TOP_OF_FUNNEL` | `SOT-…` |
| Performance Marketing test | Performance Marketing team's sandbox | `SHARED_OWNER_VIEW_MEMORY_PERFORMANCE_MARKETING` | `SOP-…` |
| Orchestrator test | Orchestrator team's sandbox | `SHARED_OWNER_VIEW_MEMORY_ORCHESTRATOR` | `SOO-…` |

Each schema has two MCP servers:

- `SHARED_OWNER_VIEW_MEMORY_MCP`: read and write (all 4 tools).
- `SHARED_OWNER_VIEW_MEMORY_RO_MCP`: read-only (no `record_owner_finding`), for consumers that should not contribute.

### Endpoint URLs

| Instance | Read/write endpoint |
|---|---|
| Shared (main) | `https://bd78472.eu-west-1.snowflakecomputing.com/api/v2/databases/NEXUS_HACKATHON_DB/schemas/SHARED_OWNER_VIEW_MEMORY/mcp-servers/SHARED_OWNER_VIEW_MEMORY_MCP` |
| Owner LTV test | `https://bd78472.eu-west-1.snowflakecomputing.com/api/v2/databases/NEXUS_HACKATHON_DB/schemas/SHARED_OWNER_VIEW_MEMORY_OWNER_LTV/mcp-servers/SHARED_OWNER_VIEW_MEMORY_MCP` |
| Top of Funnel test | `https://bd78472.eu-west-1.snowflakecomputing.com/api/v2/databases/NEXUS_HACKATHON_DB/schemas/SHARED_OWNER_VIEW_MEMORY_TOP_OF_FUNNEL/mcp-servers/SHARED_OWNER_VIEW_MEMORY_MCP` |
| Performance Marketing test | `https://bd78472.eu-west-1.snowflakecomputing.com/api/v2/databases/NEXUS_HACKATHON_DB/schemas/SHARED_OWNER_VIEW_MEMORY_PERFORMANCE_MARKETING/mcp-servers/SHARED_OWNER_VIEW_MEMORY_MCP` |
| Orchestrator test | `https://bd78472.eu-west-1.snowflakecomputing.com/api/v2/databases/NEXUS_HACKATHON_DB/schemas/SHARED_OWNER_VIEW_MEMORY_ORCHESTRATOR/mcp-servers/SHARED_OWNER_VIEW_MEMORY_MCP` |

For the read-only server, replace `SHARED_OWNER_VIEW_MEMORY_MCP` at the end with `SHARED_OWNER_VIEW_MEMORY_RO_MCP`.

## Connecting

### From a Cortex agent

Add the server to the agent specification. No `tools:` entry is needed; the tools and their
descriptions come from the server:

```yaml
mcp_servers:
  - server_spec:
      name: "NEXUS_HACKATHON_DB.SHARED_OWNER_VIEW_MEMORY_OWNER_LTV.SHARED_OWNER_VIEW_MEMORY_MCP"   # your test instance
```

Switch to `NEXUS_HACKATHON_DB.SHARED_OWNER_VIEW_MEMORY.SHARED_OWNER_VIEW_MEMORY_MCP` for the shared memory.
Add the usage protocol below to the agent's orchestration instructions.

### From Claude Code (or another MCP client)

It is a streamable HTTP MCP endpoint. Snowflake accepts:

- `Authorization: Snowflake Token="<session token>"` (a normal connector session token, verified). Session tokens expire after about 1 h.
- `Authorization: Bearer <PAT>` with a programmatic access token (should work, not yet tested by us).

Example `.mcp.json` entry with a PAT:

```json
{
  "mcpServers": {
    "shared-owner-view-memory": {
      "type": "http",
      "url": "https://bd78472.eu-west-1.snowflakecomputing.com/api/v2/databases/NEXUS_HACKATHON_DB/schemas/SHARED_OWNER_VIEW_MEMORY/mcp-servers/SHARED_OWNER_VIEW_MEMORY_MCP",
      "headers": { "Authorization": "Bearer ${SNOWFLAKE_PAT}" }
    }
  }
}
```

In the `cortex-semantic-spike` repo, `topic-memory/memctl.py client topics/shared_owner_view.yaml --install`
(or `shared_owner_view_<team>.yaml`) adds an entry that uses SSO through `invocation-poc/sf_mcp_proxy.py`
and refreshes the session automatically.

Your Snowflake role needs `USAGE` on the MCP server and on the tool procedures. Ask Peter if you get a permission error.

## Tools

| Tool | What it does | Required args |
|---|---|---|
| `owner_findings_index` | Brief, contribution rules, organiser overview and a one-line index of all findings by category. `category=` shows one category in full; `since=<checked_at>` or `since=30m` returns only what changed. | none |
| `search_owner_findings` | Semantic + keyword search. Optional: `category`, `text_filter` (exact text such as a table name), `include_unreviewed`, `top_k`. | `query` |
| `get_owner_findings` | Full findings by id (comma-separated, max 20), with attributes, status, links and `replaced_by`. | `ids` |
| `record_owner_finding` | Saves one finding. Returns its id and similar existing findings (likely duplicates are flagged). Optional: `category`, `tags`, `supersedes`, `as_of_date`, `tables`, `evidence_sql`. | `title`, `body`, `agent_type`, `domain`, `confidence` |

All arguments are strings, numbers or booleans. Lists (`tags`, `tables`, `ids`) are comma-separated strings.

**`agent_type`** is your identity. Use one of `owner_ltv_agent`, `top_of_funnel_agent`,
`performance_marketing_agent`, `orchestrator_agent`, `claude_code` or `human`. Other snake_case values are accepted too.

**`domain`**: `owner_ltv` | `top_of_funnel` | `performance_marketing` | `cross_domain`.

**`confidence`**: `verified` (checked with a query in this task) | `likely` | `hypothesis`.

**Categories**

| Category | For |
|---|---|
| `owner_definition` | The shared owner definition, its counting rules and edge cases |
| `identity_resolution` | How owner / prospect / customer ids map across domains (CS_TIERED_XID bridges, match rates, fan-out) |
| `data_structure` | Grain, keys, joins and snapshot semantics of a table or view |
| `definition` | Other business definitions (churn, risk score, funnel stage, conversion, attribution role) |
| `data_quality` | Known gaps, anomalies, sentinel values and lags, with their scope and dates |
| `validated_metric` | A checked headline number with its exact definition, filters and `as_of_date` |
| `query_pattern` | A proven, efficient SQL pattern |
| `owner_insight` | An evidenced, durable learning about owners |
| `open_question` | Something observed but not yet explained |

Suggested tags: `owner`, `churn`, `risk_score`, `account_history`, `funnel`, `prospect`, `attribution`,
`bloomreach`, `channel`, `xid`, `dim_park`, `grain`, `performance` (any tag is accepted, max 6).

## Usage protocol (put this in your agent's instructions)

The memory is **live**: during the hackathon, all teams' agents and people write to it at the same
time, and the organiser merges, corrects and supersedes findings in the background.

- At the start of a task in scope, call `owner_findings_index`, then `get_owner_findings` for the
  ids that matter. Keep the `checked_at` it returns.
- Check again during the task: `search_owner_findings` before each new sub-question, before
  expensive queries (e.g. on `FCT_ACCOUNT_HISTORY`, ~350M rows), and before stating a number or a
  definition (especially what counts as an owner). Use `owner_findings_index since=<checked_at>`
  to see what others added in the meantime.
- After verified work, search once more, then record **at most 2-3** durable findings with
  `record_owner_finding`. Always pass `agent_type`. If a finding you used was wrong, record the
  corrected one with `supersedes=<id>`.
- Findings marked `[unreviewed]` are new: use them, but verify numbers that matter.

**What to record:** one atomic, self-contained fact per finding, such as a verified grain, key or
cross-domain join; a code or sentinel meaning; a data-quality problem; a definition that changes owner
counts; a checked headline number (with its definition and `as_of_date`); a fast query pattern; or an
evidenced learning about owners. Use fully-qualified table and column names and add the proving SQL
in `evidence_sql`.

**Do not record:** personal data (names, emails, phones, addresses, individual owner / account / plot
ids as examples), one-off answers, speculation without evidence, facts obvious from one `DESCRIBE TABLE`,
or credentials. Emails, UK mobile numbers and postcodes are rejected automatically.

## Source tables in scope

| Domain | Tables |
|---|---|
| Owner LTV | `HAVEN_STORE.CARAVANS.FCT_ACCOUNT_HISTORY`, `HAVEN_STORE.CARAVANS.OWNER_STATUS_TIME_SERIES_ANALYSIS`, `OWNER_RISK_SCORES` (in `HAVEN_DATA_SCIENCE_DEV.OWNER_CHURN`, `.DATA_SCIENCE` and `.DATA_SCIENCE_CLONE`, with different row counts: which one is authoritative is still open), `HAVEN_STORE.COMMON.DIM_PARK` |
| Top of Funnel | `HAVEN_STORE.PROSPECTS.FCT_TOP_OF_THE_FUNNEL`, `HAVEN_STORE.PROSPECTS.DIM_TOP_OF_THE_FUNNEL`, `HAVEN_STORE.PROSPECTS.BRIDGE_{ANALYTICS_ID, CSI_NO, FRESHSALES_CONTACT_XID, HAVEN_ID, PLOT_OWNER_ID, WEB_SOURCE_UID}_TO_CS_TIERED_XID` |
| Performance Marketing | `HAVEN_STORE.PERFORMANCE_MARKETING.FCT_ATTRIBUTION_JOURNEY_SUMMARY`, `…FCT_ATTRIBUTION_CHANNEL_JOURNEY_ROLE`, `…DIM_BLOOMREACH_CUSTOMER` |

The semantic views of the domain agents will be added when they exist.

## Test instances: resetting

The team test instances are yours to experiment with. You have full permissions on your schema. To
start from an empty memory, truncate the data tables:

```sql
USE SCHEMA NEXUS_HACKATHON_DB.SHARED_OWNER_VIEW_MEMORY_<TEAM>;
TRUNCATE TABLE MEM_ITEM;
TRUNCATE TABLE MEM_ITEM_HISTORY;
TRUNCATE TABLE MEM_LINK;
TRUNCATE TABLE MEM_TOC;
TRUNCATE TABLE MEM_EVENT_LOG;
TRUNCATE TABLE MEM_ORGANISER_RUN;
```

- **Do not truncate `MEM_TOPIC`.** It holds the topic registration (brief, categories, rules) that the tools read.
- Finding ids keep counting after a reset (a sequence); they do not restart at 00001.
- If you drop objects by accident, ask Peter to redeploy the instance
  (`memctl.py deploy topics/shared_owner_view_<team>.yaml`, about 1 min).

Please do not wipe the shared `SHARED_OWNER_VIEW_MEMORY` schema.

## Status

This is a first version of the topic definition. The categories, prompts and sources will be refined as
the teams learn more about the data. Tell Peter about anything that is missing or gets in the way.
