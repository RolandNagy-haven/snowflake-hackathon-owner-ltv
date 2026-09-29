-- Snowflake-managed MCP server over two semantic views:
--   fnb_retail_analyst / footfall_analyst  Cortex Analyst text-to-SQL (return SQL only)
--   run_sql                                read-only SQL, runs the analyst SQL or hand-written SEMANTIC_VIEW(...) queries
-- Endpoint: https://<account_url>/api/v2/databases/HAVEN_DATA_SCIENCE_DEV/schemas/PETERZENTAI_LOCAL/mcp-servers/SEMANTIC_VIEWS_MCP
CREATE OR REPLACE MCP SERVER HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.SEMANTIC_VIEWS_MCP
  FROM SPECIFICATION $$
tools:
  - title: "Haven F&B retail sales analyst"
    name: "fnb_retail_analyst"
    type: "CORTEX_ANALYST_MESSAGE"
    identifier: "HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FNB_RETAIL_SV"
    description: >-
      Turns a natural-language question about Haven food & beverage sales (revenue in GBP ex VAT on a 07:00
      business day, orders, average order value, items, wet/food share, voids, trading venue-days, last-year
      comparison; by park, region, venue, venue category, concept, date, hour, season, school/bank holiday)
      into SQL over the FNB_RETAIL_SV semantic view. Returns the SQL only - execute it with run_sql.
  - title: "Haven footfall (guests on park) analyst"
    name: "footfall_analyst"
    type: "CORTEX_ANALYST_MESSAGE"
    identifier: "HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V3"
    description: >-
      Turns a natural-language question about Haven park footfall (booked guests on park per night - Holiday
      Makers and Private Lets - arrivals/first day, last full day, leavers, distinct bookings, self-catering,
      age mix, play pass and ratios; by park, region, date, stay type; plus separately estimated owner heads,
      indicative only and never added to guests) into SQL over the FOOTFALL_ARRIVALS_SV_V3 semantic view.
      Returns the SQL only - execute it with run_sql.
  - title: "Run read-only SQL"
    name: "run_sql"
    type: "SYSTEM_EXECUTE_SQL"
    description: >-
      Executes one read-only SQL statement in Snowflake and returns the rows. Use it to run SQL produced by
      fnb_retail_analyst / footfall_analyst, or to query the semantic views directly:
      discover with DESCRIBE SEMANTIC VIEW HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FNB_RETAIL_SV (or
      FOOTFALL_ARRIVALS_SV_V3), SHOW SEMANTIC METRICS IN <view>, SHOW SEMANTIC DIMENSIONS IN <view>; then query with
      SELECT * FROM SEMANTIC_VIEW(HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FNB_RETAIL_SV
      METRICS sales.net_revenue, sales.orders DIMENSIONS parks.park_name, calendar.business_month
      WHERE calendar.business_year = 2025) ORDER BY 1, 2 LIMIT 100.
      Always aggregate and LIMIT; the response is truncated at 250 KB.
    config:
      read_only: true
      warehouse: "HAVEN_DATA_SCIENCE_DEV_WAREHOUSE_XSMALL"
      query_timeout: 120
$$;
