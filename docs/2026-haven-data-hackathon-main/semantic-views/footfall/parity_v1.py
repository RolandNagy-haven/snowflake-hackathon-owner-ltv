"""Parity test: FOOTFALL_ARRIVALS_SV_V1 vs HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_FACTS_V3.

    python semantic-views/footfall/parity_v1.py [--since 2023-01-01]

Rebuilds V3's TOTAL_* guest columns from ONE semantic query (park x date x stay type x
age x play pass, guest_nights) and re-pivots it in plain SQL - the cube V3 builds by
hand. Every park x day of V3 is compared column by column; exit code 1 on any mismatch.
"""
import argparse
import sys

from sf import session

SV = "HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V1"
V3 = "HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_FACTS_V3"

# V3 column -> the same number, pivoted from the semantic query's rows
COLUMNS = {
    "TOTAL_NIGHTS":         "sum(guest_nights)",
    "TOTAL_HOLIDAY_MAKERS": "sum(iff(stay_type = 'Holiday Maker', guest_nights, 0))",
    "TOTAL_PRIVATE_LETS":   "sum(iff(stay_type = 'Private Let', guest_nights, 0))",
    "TOTAL_ADULTS":         "sum(iff(guest_age = 'Adult', guest_nights, 0))",
    "TOTAL_CHILDREN":       "sum(iff(guest_age = 'Child', guest_nights, 0))",
    "TOTAL_INFANTS":        "sum(iff(guest_age = 'Infant', guest_nights, 0))",
    "TOTAL_PLAY_PASS":      "sum(iff(play_pass = 'Has play pass', guest_nights, 0))",
    "TOTAL_NO_PLAY_PASS":   "sum(iff(play_pass = 'No play pass', guest_nights, 0))",
}

ap = argparse.ArgumentParser()
ap.add_argument("--since", default="2023-01-01")
args = ap.parse_args()

pivots = ",\n        ".join(f"{expr} as {col}" for col, expr in COLUMNS.items())
diffs = ",\n    ".join(f"count_if(coalesce(v.{c}, 0) <> coalesce(n.{c}, 0)) as {c}" for c in COLUMNS)
totals = ",\n    ".join(f"sum(v.{c}) as v3_{c}, sum(n.{c}) as sv_{c}" for c in COLUMNS)

sql = f"""
with sv as (
    select * from semantic_view({SV}
        dimensions park_days.park_code, park_days.on_park_date,
                   guests.stay_type, guests.guest_age, guests.play_pass
        metrics guests.guest_nights
        where park_days.on_park_date >= '{args.since}')
),
new as (
    select park_code, on_park_date,
        {pivots}
    from sv group by 1, 2
),
v3 as (select * from {V3} where on_park_date >= '{args.since}')
select
    count(*) as park_days,
    count_if(v.park_code is null) as only_in_sv,
    count_if(n.park_code is null and v.total_nights > 0) as only_in_v3_nonzero,
    {diffs},
    {totals}
from v3 v
    full outer join new n on n.park_code = v.park_code and n.on_park_date = v.on_park_date
"""

r = session().sql(sql).collect()[0].as_dict()
print(f"park-days compared: {r['PARK_DAYS']:,}   only in SV: {r['ONLY_IN_SV']}   "
      f"only in V3 with guests: {r['ONLY_IN_V3_NONZERO']}\n")
print(f"{'column':<22}{'park-days differing':>20}{'V3 total':>16}{'SV total':>16}")
bad = r["ONLY_IN_SV"] + r["ONLY_IN_V3_NONZERO"]
for c in COLUMNS:
    bad += r[c]
    print(f"{c:<22}{r[c]:>20,}{r['V3_' + c]:>16,}{r['SV_' + c]:>16,}")
print("\nPARITY OK" if bad == 0 else "\nPARITY FAILED")
sys.exit(0 if bad == 0 else 1)
