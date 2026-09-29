-- Read-only SQL tool for agent 2. Declaring system_execute_sql directly in an agent spec is accepted at
-- CREATE time but fails at run time with "system_execute_sql is not a tool enabled on your account", so the
-- tool comes from a Snowflake-managed MCP server instead (SYSTEM_EXECUTE_SQL, read_only enforced by Snowflake).
CREATE OR REPLACE MCP SERVER {{DB}}.{{SCHEMA}}.SV_SQL_MCP
  FROM SPECIFICATION $$
tools:
  - title: "Run read-only SQL"
    name: "run_sql"
    type: "SYSTEM_EXECUTE_SQL"
    description: "Executes one read-only SQL statement in Snowflake and returns the rows."
    config:
      read_only: true
      warehouse: "{{WH}}"
      query_timeout: 120
$$;
