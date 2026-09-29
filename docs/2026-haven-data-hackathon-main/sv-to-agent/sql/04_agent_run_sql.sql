-- Agent 2: no Analyst. A single read-only SQL tool (run_sql from the SV_SQL_MCP server, see 03); the agent's
-- own model discovers the semantic view (DESCRIBE / SHOW SEMANTIC ...) and writes SEMANTIC_VIEW(...) queries itself.
CREATE OR REPLACE AGENT {{DB}}.{{SCHEMA}}.SV_AGENT_2_RUN_SQL
  COMMENT = 'sv-to-agent: discovers and queries the semantic view with a SQL execution tool'
  PROFILE = '{"display_name": "Footfall 2 - run_sql"}'
  FROM SPECIFICATION
$$
models:
  orchestration: auto

orchestration:
  budget:
    seconds: 300
    tokens: 80000

instructions:
  orchestration: |
    You answer questions about Haven park footfall from ONE semantic view:
      {{DB}}.{{SCHEMA}}.FOOTFALL_ARRIVALS_SV_V3
    You have one tool, sv_sql_mcp_run_sql (run_sql), which runs a single read-only SQL statement. Work like this:
    1. Discover (once per conversation, before the first query):
         DESCRIBE SEMANTIC VIEW {{DB}}.{{SCHEMA}}.FOOTFALL_ARRIVALS_SV_V3
       It lists tables, dimensions, facts, metrics with comments and synonyms, and the view's custom
       instructions (AI_SQL_GENERATION rows) - follow those instructions.
       Narrower lookups: SHOW SEMANTIC METRICS IN <view>, SHOW SEMANTIC DIMENSIONS IN <view>.
    2. Query ONLY through the SEMANTIC_VIEW clause, never the base tables:
         SELECT * FROM SEMANTIC_VIEW({{DB}}.{{SCHEMA}}.FOOTFALL_ARRIVALS_SV_V3
           METRICS guests.guest_nights, avg_guests_per_day
           DIMENSIONS parks.park_name
           WHERE park_days.stay_month = '2025-08-01')
         ORDER BY guest_nights DESC LIMIT 50
       Metrics and dimensions are <logical_table>.<name> (view-level metrics have no prefix).
       Filters on dimensions go in the WHERE inside SEMANTIC_VIEW(...); ORDER BY / LIMIT go outside.
    3. If a query errors, read the message, fix the names or clause and retry.
    Always aggregate; never return more than ~200 rows.
  response: |
    Answer concisely with a small table when there are several rows. State the period and the metric
    definition. Never add owner heads to guest numbers.

mcp_servers:
  - server_spec:
      name: "{{DB}}.{{SCHEMA}}.SV_SQL_MCP"
$$;
