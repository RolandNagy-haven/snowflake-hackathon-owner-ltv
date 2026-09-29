"""Confirm grains, rent-ledger balance-vs-flow, join coverage, deploy targets."""
from sf_session import get_session

s = get_session(role="NEXUS_SPIKE")

def one(sql):
    return s.sql(sql).collect()

TS = "HAVEN_STORE.CARAVANS.OWNER_STATUS_TIME_SERIES_ANALYSIS"
AD = "HAVEN_STORE.CARAVANS.ACCOUNT_DETAIL"

print("== ACCOUNT_DETAIL uniqueness on ACCOUNT_NO")
r = one(f"select count(*) n, count(distinct ACCOUNT_NO) d from {AD}")[0]
print(f"   rows={r['N']:,}  distinct_account_no={r['D']:,}  unique={r['N']==r['D']}")

print("== TIME_SERIES grain on (ACCOUNT_NO, MONTH_END_DATE)")
r = one(f"select count(*) n, count(distinct ACCOUNT_NO||'|'||MONTH_END_DATE) d from {TS}")[0]
print(f"   rows={r['N']:,}  distinct_acct_month={r['D']:,}  unique={r['N']==r['D']}")
r = one(f"select min(MONTH_END_DATE) lo, max(MONTH_END_DATE) hi, count(distinct ACCOUNT_NO) a from {TS}")[0]
print(f"   month range {r['LO']} .. {r['HI']}   distinct accounts={r['A']:,}")

print("== rent ledger: one account's monthly series (balance vs flow?)")
acct = one(f"select ACCOUNT_NO from {TS} group by 1 having count(*) >= 6 order by 1 limit 1")[0]["ACCOUNT_NO"]
for row in one(f"select MONTH_END_DATE, RENT_LEDGER_BALANCE, MONTH_SPEND from {TS} "
               f"where ACCOUNT_NO='{acct}' order by MONTH_END_DATE limit 12"):
    print(f"   {acct}  {row['MONTH_END_DATE']}  ledger_bal={row['RENT_LEDGER_BALANCE']}  month_spend={row['MONTH_SPEND']}")

print("== join coverage: TIME_SERIES accounts present in ACCOUNT_DETAIL")
r = one(f"""select count(distinct t.ACCOUNT_NO) ts,
                   count(distinct case when a.ACCOUNT_NO is not null then t.ACCOUNT_NO end) matched
            from (select distinct ACCOUNT_NO from {TS}) t
            left join {AD} a using (ACCOUNT_NO)""")[0]
print(f"   ts_accounts={r['TS']:,}  matched_in_account_detail={r['MATCHED']:,}")

print("== current context + candidate deploy schemas")
c = one("select current_database() db, current_schema() sc")[0]
print(f"   current db={c['DB']} schema={c['SC']}")
try:
    for row in one("show terse schemas in database NEXUS_HACKATHON_DB"):
        print("   schema:", row["name"])
except Exception as e:  # noqa: BLE001
    print("   (could not list NEXUS_HACKATHON_DB schemas):", e)
