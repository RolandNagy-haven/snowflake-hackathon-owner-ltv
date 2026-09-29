"""Missing HAVEN_ID at each account's most-recent time-series snapshot."""
from sf_session import get_session

s = get_session(role="NEXUS_SPIKE")

def rows(sql):
    return s.sql(sql).collect()

TS = "HAVEN_STORE.CARAVANS.OWNER_STATUS_TIME_SERIES_ANALYSIS"
AD = "HAVEN_STORE.CARAVANS.ACCOUNT_DETAIL"

print("== does the time series carry HAVEN_ID itself?")
cols = [r["name"] for r in rows(f"describe table {TS}")]
has_hid = any(c.upper() == "HAVEN_ID" for c in cols)
print(f"   HAVEN_ID column in time series = {has_hid}")
print("   columns:", ", ".join(cols))

# Latest row per account in the time series.
LATEST = f"""
    select ACCOUNT_NO, MONTH_END_DATE {', HAVEN_ID' if has_hid else ''}
    from {TS}
    qualify row_number() over (partition by ACCOUNT_NO
                               order by MONTH_END_DATE desc) = 1
"""

if has_hid:
    print("\n== missing HAVEN_ID at latest snapshot (from time series' own column)")
    r = rows(f"""select count(*) accts,
                        count(HAVEN_ID) with_id,
                        count(*) - count(HAVEN_ID) missing
                 from ({LATEST})""")[0]
    print(f"   accounts={r['ACCTS']:,}  with_id={r['WITH_ID']:,}  missing={r['MISSING']:,}")

print("\n== missing HAVEN_ID at latest snapshot (via ACCOUNT_DETAIL join)")
r = rows(f"""select count(*) accts,
                    count(a.HAVEN_ID) with_id,
                    count(*) - count(a.HAVEN_ID) missing
             from ({LATEST}) l
             left join {AD} a using (ACCOUNT_NO)""")[0]
print(f"   accounts={r['ACCTS']:,}  with_id={r['WITH_ID']:,}  missing={r['MISSING']:,}")
