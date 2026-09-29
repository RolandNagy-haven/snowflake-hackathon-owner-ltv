"""Deploy the Owner LTV delegation layer (RUN_AGENT + wrapper + MCP server),
then test the chain end-to-end: a first question on a new thread, and a follow-up
that continues the same thread.

Target:  NEXUS_HACKATHON_DB.OWNER_LTV_SV  (role NEXUS_SPIKE, wh NEXUS_HACKATHON_WH)
Source:  sql/03_owner_ltv_delegation.sql
"""
import json
from pathlib import Path

from sf_session import get_session

DB = "NEXUS_HACKATHON_DB"
SCHEMA = "OWNER_LTV_SV"
WH = "NEXUS_HACKATHON_WH"
SQL_FILE = Path(__file__).resolve().parent.parent / "sql" / "03_owner_ltv_delegation.sql"

s = get_session(role="NEXUS_SPIKE", warehouse=WH)
s.sql(f"use schema {DB}.{SCHEMA}").collect()
print(f"deploying delegation layer into {DB}.{SCHEMA} as NEXUS_SPIKE\n")

for cur in s.connection.execute_string(SQL_FILE.read_text(), remove_comments=False):
    if cur.query:
        print(f"-> {cur.query.strip().splitlines()[0][:70]}")
print("\ndeployed OK\n")

print("== MCP servers registered")
for r in s.sql(f"show mcp servers in schema {DB}.{SCHEMA}").collect():
    print("   ", r["name"])


def ask(question, thread_ref):
    raw = s.call(f"{DB}.{SCHEMA}.ASK_OWNER_LTV_AGENT", question, thread_ref)
    return json.loads(raw)


print("\n== turn 1 (new thread)")
r1 = ask("What is the overall rent ledger value and lifetime on-park spend by region? Top 5 regions.", "new")
print("   tools:", r1.get("tools_used"), " elapsed:", r1.get("elapsed_s"), "s")
print("   thread_ref:", r1.get("thread_ref"))
if r1.get("error"):
    print("   ERROR:", r1["error"])
print("   answer:\n", (r1.get("answer") or "")[:1500])

print("\n== turn 2 (continue the thread)")
r2 = ask("For the top region by spend, how many owner accounts is that, and roughly how many people?",
         r1.get("thread_ref") or "new")
print("   tools:", r2.get("tools_used"), " elapsed:", r2.get("elapsed_s"), "s")
print("   thread_ref:", r2.get("thread_ref"))
if r2.get("error"):
    print("   ERROR:", r2["error"])
print("   answer:\n", (r2.get("answer") or "")[:1500])
