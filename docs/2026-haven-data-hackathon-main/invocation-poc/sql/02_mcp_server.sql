-- Snowflake-managed MCP server exposing HELLO_WORLD_TOOL as a GENERIC tool.
-- Endpoint: https://<account_url>/api/v2/databases/HAVEN_DATA_SCIENCE_DEV/schemas/PETERZENTAI_LOCAL/mcp-servers/INVOCATION_POC_MCP
CREATE OR REPLACE MCP SERVER HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.INVOCATION_POC_MCP
  FROM SPECIFICATION $$
tools:
  - title: "Hello world tool"
    name: "hello_world_tool"
    type: "GENERIC"
    identifier: "HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.HELLO_WORLD_TOOL"
    description: "Greets the given person by name and reports which Snowflake user/role executed the call. Use to verify MCP connectivity."
    config:
      type: "procedure"
      warehouse: "HAVEN_DATA_SCIENCE_DEV_WAREHOUSE_XSMALL"
      input_schema:
        type: "object"
        properties:
          name:
            description: "Name of the person to greet"
            type: "string"
        required: ["name"]
$$;
