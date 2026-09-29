"""Discovery: confirm columns/grain for the Owner LTV semantic view (read-only)."""
import sys

from sf_session import get_session

s = get_session(role="NEXUS_SPIKE")

who = s.sql("select current_role() r, current_account() a, current_warehouse() w").collect()[0]
print(f"connected: role={who['R']} account={who['A']} warehouse={who['W']}\n")

TABLES = [
    "HAVEN_STORE.CARAVANS.OWNER_STATUS_TIME_SERIES_ANALYSIS",
    "HAVEN_STORE.CARAVANS.ACCOUNT_DETAIL",
    "HAVEN_STORE.COMMON.DIM_PARK",
]
for t in TABLES:
    print(f"===== {t}")
    try:
        for r in s.sql(f"describe table {t}").collect():
            print(f"  {r['name']:<40} {r['type']}")
    except Exception as e:  # noqa: BLE001
        print(f"  ERROR: {e}", file=sys.stderr)
    print()

# Peek at the financial columns that look like rent ledger / spend, to judge
# balance-vs-flow for the rent ledger metric.
print("===== sample rows: month, spend and rent-ledger-ish columns")
try:
    cols = [r["name"] for r in s.sql(
        "describe table HAVEN_STORE.CARAVANS.OWNER_STATUS_TIME_SERIES_ANALYSIS").collect()]
    interesting = [c for c in cols if any(k in c.upper() for k in
                   ("MONTH", "SPEND", "RENT", "LEDGER", "ACCOUNT"))]
    print("  interesting columns:", interesting)
    sel = ", ".join(interesting) if interesting else "*"
    rows = s.sql(
        f"select {sel} from HAVEN_STORE.CARAVANS.OWNER_STATUS_TIME_SERIES_ANALYSIS "
        "order by 1 limit 8").collect()
    for r in rows:
        print("   ", {k: r[k] for k in r.as_dict()})
except Exception as e:  # noqa: BLE001
    print(f"  ERROR: {e}", file=sys.stderr)
