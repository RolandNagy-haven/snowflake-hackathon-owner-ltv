"""Deploy the Owner LTV helper view + semantic view, then smoke-test it.

Target:  NEXUS_HACKATHON_DB.OWNER_LTV_SV   (role NEXUS_SPIKE, wh NEXUS_HACKATHON_WH)
Source:  sql/01_owner_ltv_semantic_view.sql
"""
from pathlib import Path

from sf_session import get_session

DB = "NEXUS_HACKATHON_DB"
SCHEMA = "OWNER_LTV_SV"
WH = "NEXUS_HACKATHON_WH"
SQL_FILE = Path(__file__).resolve().parent.parent / "sql" / "01_owner_ltv_semantic_view.sql"

s = get_session(role="NEXUS_SPIKE", warehouse=WH)

s.sql(f"create schema if not exists {DB}.{SCHEMA}").collect()
s.sql(f"use schema {DB}.{SCHEMA}").collect()
print(f"deploying into {DB}.{SCHEMA} as NEXUS_SPIKE\n")

# execute_string is quote/comment aware — do NOT split on ';' ourselves, the
# comment and ai_sql_generation strings contain semicolons.
for cur in s.connection.execute_string(SQL_FILE.read_text(), remove_comments=False):
    if cur.query:
        print(f"-> {cur.query.strip().splitlines()[0][:70]}")
print("\ndeployed OK\n")

print("== semantic view registered")
for r in s.sql(f"show semantic views in schema {DB}.{SCHEMA}").collect():
    print("   ", r["name"])

print("\n== metrics query: totals across all accounts")
rows = s.sql(f"""
    select * from semantic_view(
        {DB}.{SCHEMA}.OWNER_LTV_SV_V1
        metrics account_count, overall_rent_ledger_value, lifetime_park_spend
    )""").collect()
for r in rows:
    print("   ", {k: r[k] for k in r.as_dict()})

print("\n== metrics by park tier (top 10 by lifetime spend)")
rows = s.sql(f"""
    select * from semantic_view(
        {DB}.{SCHEMA}.OWNER_LTV_SV_V1
        dimensions park_tier
        metrics account_count, overall_rent_ledger_value, lifetime_park_spend
    )
    order by lifetime_park_spend desc nulls last limit 10""").collect()
for r in rows:
    print("   ", {k: r[k] for k in r.as_dict()})
