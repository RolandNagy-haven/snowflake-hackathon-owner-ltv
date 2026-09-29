"""Throwaway spike: MCP server spec/limits, owner's-rights procs, VARIANT args/returns, latency."""
import json, sys, time
from pathlib import Path
import requests
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / ".claude/skills/snowflake-query")); sys.path.insert(0, str(ROOT / "invocation-poc"))
from snowflake_session import get_or_create_session
import sf_mcp_auth

FQ = "HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL"
URL = ("https://bd78472.eu-west-1.snowflakecomputing.com/api/v2/databases/HAVEN_DATA_SCIENCE_DEV/"
       "schemas/PETERZENTAI_LOCAL/mcp-servers/SPIKE_MEM_MCP")
s = get_or_create_session()
def run(sql):
    try:
        r = s.sql(sql).collect(); return r
    except Exception as e:
        print("  ERR:", str(e)[:400]); return None

run(f"""CREATE OR REPLACE PROCEDURE {FQ}.SPIKE_MEM_ECHO(TITLE VARCHAR, TAGS VARCHAR, ATTRS BOOLEAN, TOP_K NUMBER, OPT VARCHAR DEFAULT 'dflt')
RETURNS VARIANT LANGUAGE SQL EXECUTE AS OWNER AS
$$ BEGIN RETURN OBJECT_CONSTRUCT('title', :TITLE, 'tags', :TAGS, 'attrs', :ATTRS, 'top_k', :TOP_K, 'opt', :OPT,
   'user', CURRENT_USER(), 'role', CURRENT_ROLE(), 'emb_dim', VECTOR_L2_DISTANCE(SNOWFLAKE.CORTEX.EMBED_TEXT_1024('snowflake-arctic-embed-l-v2.0', :TITLE), SNOWFLAKE.CORTEX.EMBED_TEXT_1024('snowflake-arctic-embed-l-v2.0', 'x'))); END; $$""")
run(f"""CREATE OR REPLACE PROCEDURE {FQ}.SPIKE_MEM_TEXT(Q VARCHAR)
RETURNS VARCHAR LANGUAGE SQL EXECUTE AS OWNER AS $$ BEGIN RETURN 'line1\\nline2 ' || :Q; END; $$""")

long_desc = ("Long description test. " * 104)  # ~2400 chars
tool_echo = f"""
  - title: "Echo variant"
    name: "record_finding"
    type: "GENERIC"
    identifier: "{FQ}.SPIKE_MEM_ECHO"
    description: "{long_desc}END"
    config:
      type: "procedure"
      warehouse: "HAVEN_DATA_SCIENCE_DEV_WAREHOUSE_XSMALL"
      input_schema:
        type: "object"
        properties:
          title: {{type: "string", description: "Title param description"}}
          tags: {{type: "string", description: "tags"}}
          attrs: {{type: "boolean", description: "attrs"}}
          top_k: {{type: "number", description: "k"}}
          opt: {{type: "string", description: "optional"}}
        required: ["title", "tags", "attrs", "top_k"]
  - title: "Text"
    name: "text_tool"
    type: "GENERIC"
    identifier: "{FQ}.SPIKE_MEM_TEXT"
    description: "text"
    config:
      type: "procedure"
      warehouse: "HAVEN_DATA_SCIENCE_DEV_WAREHOUSE_XSMALL"
      input_schema: {{type: "object", properties: {{q: {{type: "string"}}}}, required: ["q"]}}
"""
print("with instructions key:")
ok = run(f"CREATE OR REPLACE MCP SERVER {FQ}.SPIKE_MEM_MCP FROM SPECIFICATION $$\ninstructions: \"Server brief here\"\ntools:{tool_echo}$$")
if ok is None:
    print("without instructions key:")
    run(f"CREATE OR REPLACE MCP SERVER {FQ}.SPIKE_MEM_MCP FROM SPECIFICATION $$\ntools:{tool_echo}$$")

H = {**sf_mcp_auth.header(sf_mcp_auth.cached_token() or sf_mcp_auth.silent_token()), "Accept": "application/json, text/event-stream"}
def rpc(method, params=None):
    t = time.time()
    r = requests.post(URL, headers=H, json={"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}})
    return r.status_code, round(time.time() - t, 2), r.text
st, dt, txt = rpc("initialize", {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "spike", "version": "0"}})
print("initialize", st, dt, txt[:1500])
for m in ("resources/list", "prompts/list"):
    print(m, rpc(m)[0], rpc(m)[2][:300])
st, dt, txt = rpc("tools/list")
tl = json.loads(txt)["result"]["tools"]
for t in tl:
    print("tool", t["name"], len(t["name"]), "desc_len", len(t.get("description", "")), "ends", t.get("description", "")[-10:])
    print("  schema", json.dumps(t.get("inputSchema"))[:400], "keys", list(t))
for i in range(4):
    print("call echo", rpc("tools/call", {"name": tl[0]["name"], "arguments": {"title": "grain of arrivals", "tags": "a,b", "attrs": True, "top_k": 5}})[1:])
print("call echo w/ opt", rpc("tools/call", {"name": tl[0]["name"], "arguments": {"title": "t", "tags": "", "attrs": False, "top_k": 1, "opt": "given"}})[1:])
print("call text", rpc("tools/call", {"name": "text_tool", "arguments": {"q": "hi"}})[1:])
