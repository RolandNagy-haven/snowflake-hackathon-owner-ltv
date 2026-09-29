"""Missing HAVEN_ID within the single global latest snapshot (active book)."""
from sf_session import get_session

s = get_session(role="NEXUS_SPIKE")

def rows(sql):
    return s.sql(sql).collect()

TS = "HAVEN_STORE.CARAVANS.OWNER_STATUS_TIME_SERIES_ANALYSIS"
AD = "HAVEN_STORE.CARAVANS.ACCOUNT_DETAIL"

mx = rows(f"select max(MONTH_END_DATE) m from {TS}")[0]["M"]
print(f"== global latest MONTH_END_DATE = {mx}")

r = rows(f"""
    with latest as (
        select ACCOUNT_NO
        from {TS}
        where MONTH_END_DATE = (select max(MONTH_END_DATE) from {TS})
    )
    select count(*)                      as accts,
           count(a.HAVEN_ID)             as with_id,
           count(*) - count(a.HAVEN_ID)  as missing
    from latest l
    left join {AD} a using (ACCOUNT_NO)
""")[0]
print(f"   accounts in latest snapshot = {r['ACCTS']:,}")
print(f"   with HAVEN_ID               = {r['WITH_ID']:,}")
print(f"   missing HAVEN_ID            = {r['MISSING']:,}  "
      f"({r['MISSING']/r['ACCTS']*100:.1f}%)")
