-- Simple stored procedure to be exposed as a GENERIC tool on an MCP server.
CREATE OR REPLACE PROCEDURE HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.HELLO_WORLD_TOOL(NAME VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = 'invocation-poc: hello world tool exposed via MCP'
EXECUTE AS CALLER
AS
$$
BEGIN
  RETURN 'Hello, ' || COALESCE(NULLIF(TRIM(:NAME), ''), 'world') || '! (from Snowflake as '
         || CURRENT_USER() || ' / ' || CURRENT_ROLE() || ' at ' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYY-MM-DD HH24:MI:SS TZH:TZM') || ')';
END;
$$;
