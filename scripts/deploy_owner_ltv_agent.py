"""Deploy the Owner LTV Cortex Agent, then confirm it registered.

Target:  NEXUS_HACKATHON_DB.OWNER_LTV_SV.OWNER_LTV_AGENT  (role NEXUS_SPIKE, wh NEXUS_HACKATHON_WH)
Source:  sql/02_owner_ltv_agent.sql
Test the agent's answers with scripts/ask_owner_ltv_agent.py.
"""
from pathlib import Path

from sf_session import get_session

DB = "NEXUS_HACKATHON_DB"
SCHEMA = "OWNER_LTV_SV"
WH = "NEXUS_HACKATHON_WH"
SQL_FILE = Path(__file__).resolve().parent.parent / "sql" / "02_owner_ltv_agent.sql"

s = get_session(role="NEXUS_SPIKE", warehouse=WH)
s.sql(f"use schema {DB}.{SCHEMA}").collect()
print(f"deploying agent into {DB}.{SCHEMA} as NEXUS_SPIKE\n")

# execute_string is quote/comment aware; the spec has semicolons inside the $$...$$ body.
for cur in s.connection.execute_string(SQL_FILE.read_text(), remove_comments=False):
    if cur.query:
        print(f"-> {cur.query.strip().splitlines()[0][:70]}")
print("\ndeployed OK\n")

print("== agents registered")
for r in s.sql(f"show agents in schema {DB}.{SCHEMA}").collect():
    print("   ", r["name"])
