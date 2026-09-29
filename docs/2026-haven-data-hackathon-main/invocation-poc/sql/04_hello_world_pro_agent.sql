-- HELLO_WORLD_PRO_AGENT: gets its tools from the Snowflake-managed MCP server SEMANTIC_VIEWS_MCP
-- (fnb_retail_analyst, footfall_analyst, run_sql) instead of declaring them itself.
CREATE OR REPLACE AGENT HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.HELLO_WORLD_PRO_AGENT
  COMMENT = 'invocation-poc: agent using the SEMANTIC_VIEWS_MCP tools via mcp_servers'
  PROFILE = '{"display_name": "Hello World Pro"}'
  FROM SPECIFICATION
$$
models:
  orchestration: auto

orchestration:
  budget:
    seconds: 240
    tokens: 60000

instructions:
  orchestration: |
    You answer questions about Haven F&B retail sales and park footfall.
    For F&B questions call fnb_retail_analyst, for footfall questions call footfall_analyst.
    Both return SQL only: always execute the returned statement with run_sql and answer from the rows.
  response: |
    Answer concisely, with a small table when there are several rows. State the period and units.

mcp_servers:
  - server_spec:
      name: "HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.SEMANTIC_VIEWS_MCP"
$$;
