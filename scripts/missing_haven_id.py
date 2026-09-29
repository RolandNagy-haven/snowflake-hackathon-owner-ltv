"""Find/quantify accounts with a missing (NULL) HAVEN_ID and show one example."""
from sf_session import get_session

s = get_session(role="NEXUS_SPIKE")

def one(sql):
    return s.sql(sql).collect()

AD = "HAVEN_STORE.CARAVANS.ACCOUNT_DETAIL"
TS = "HAVEN_STORE.CARAVANS.OWNER_STATUS_TIME_SERIES_ANALYSIS"

print("== how many ACCOUNT_DETAIL rows have no HAVEN_ID")
r = one(f"""select count(*) n,
                   count(HAVEN_ID) with_id,
                   count(*) - count(HAVEN_ID) missing
            from {AD}""")[0]
print(f"   accounts={r['N']:,}  with_haven_id={r['WITH_ID']:,}  missing={r['MISSING']:,}")

print("== do any of those missing-HID accounts carry real LTV facts?")
r = one(f"""select count(distinct a.ACCOUNT_NO) missing_accts_with_facts
            from {AD} a
            join {TS} t using (ACCOUNT_NO)
            where a.HAVEN_ID is null""")[0]
print(f"   missing-HID accounts that appear in the time series = {r['MISSING_ACCTS_WITH_FACTS']:,}")

print("== one concrete example: a missing-HID account that still has spend/ledger facts")
ex = one(f"""select a.ACCOUNT_NO, a.HAVEN_ID, a.PARK_CODE,
                    max_by(t.RENT_LEDGER_BALANCE, t.MONTH_END_DATE) rent_ledger_latest,
                    sum(t.MONTH_SPEND) lifetime_spend,
                    count(*) months
             from {AD} a
             join {TS} t using (ACCOUNT_NO)
             where a.HAVEN_ID is null
             group by 1,2,3
             order by lifetime_spend desc nulls last
             limit 1""")
for row in ex:
    print(f"   ACCOUNT_NO={row['ACCOUNT_NO']}  HAVEN_ID={row['HAVEN_ID']!r}  "
          f"PARK_CODE={row['PARK_CODE']}  rent_ledger_latest={row['RENT_LEDGER_LATEST']}  "
          f"lifetime_spend={row['LIFETIME_SPEND']}  months={row['MONTHS']}")
