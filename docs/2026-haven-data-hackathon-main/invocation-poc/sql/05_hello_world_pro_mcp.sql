-- Exposes HELLO_WORLD_PRO_AGENT as a single CORTEX_AGENT_RUN tool.
-- Separate from SEMANTIC_VIEWS_MCP (which the agent itself uses) so the agent never sees itself as a tool.
-- Endpoint: https://<account_url>/api/v2/databases/HAVEN_DATA_SCIENCE_DEV/schemas/PETERZENTAI_LOCAL/mcp-servers/HELLO_WORLD_PRO_MCP
CREATE OR REPLACE MCP SERVER HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.HELLO_WORLD_PRO_MCP
  FROM SPECIFICATION $$
tools:
  - title: "Hello World Pro agent"
    name: "hello_world_pro_agent"
    type: "CORTEX_AGENT_RUN"
    identifier: "HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.HELLO_WORLD_PRO_AGENT"
    description: >-
      Cortex Agent that answers business questions about Haven F&B retail sales (revenue GBP ex VAT, orders,
      average order value, wet share, voids; by park, region, venue, category, date, hour, season) and park
      footfall (booked guests on park, arrivals, leavers, ratios; by park, region, date, stay type). It plans,
      writes and runs governed SQL over the FNB_RETAIL_SV and FOOTFALL_ARRIVALS_SV_V3 semantic views and
      answers in prose with the numbers. Ask one complete, self-contained question; takes ~30-60 s.
$$;
