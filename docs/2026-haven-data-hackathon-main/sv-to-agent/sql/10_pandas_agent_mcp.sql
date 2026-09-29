-- MCP server that makes SV_AGENT_5_PANDAS callable as a threaded tool - by other Cortex Agents (mcp_servers) and by
-- external MCP clients such as Claude Code. The tool is a GENERIC (procedure) tool, not CORTEX_AGENT_RUN, because
-- CORTEX_AGENT_RUN only takes {"text"} and cannot continue a conversation.
-- Endpoint: https://<account_url>/api/v2/databases/{{DB}}/schemas/{{SCHEMA}}/mcp-servers/SV_PANDAS_AGENT_MCP
CREATE OR REPLACE MCP SERVER {{DB}}.{{SCHEMA}}.SV_PANDAS_AGENT_MCP
  FROM SPECIFICATION $$
tools:
  - title: "Ask the footfall pandas analyst (threaded)"
    name: "ask_pandas_agent"
    type: "GENERIC"
    identifier: "{{DB}}.{{SCHEMA}}.ASK_PANDAS_AGENT_THREADED"
    description: >-
      Ask SV_AGENT_5_PANDAS, a Python/pandas data analyst for Haven park footfall (booked guests on park per night,
      arrivals, leavers, bookings, ratios, owner heads; by park, region, date, stay type) over the
      FOOTFALL_ARRIVALS_SV_V3 semantic view. Good at statistics (medians, std dev, correlations, regressions,
      period comparisons). Takes a question and a thread_ref ("new" or one returned earlier); returns JSON with
      its answer, the updated thread_ref, the tools it used and elapsed seconds. Takes 1-3 minutes.
    config:
      type: "procedure"
      warehouse: "{{WH}}"
      input_schema:
        type: "object"
        properties:
          question:
            type: "string"
            description: >-
              The question. Self-contained with explicit dates, parks and definitions for a new thread; may refer
              back to the analyst's earlier answers when continuing a thread.
          thread_ref:
            type: "string"
            description: >-
              "new" to start a fresh conversation with the analyst, or the latest thread_ref returned by
              ask_pandas_agent to continue that conversation.
        required: ["question", "thread_ref"]
$$;
