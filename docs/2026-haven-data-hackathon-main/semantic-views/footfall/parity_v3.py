"""Parity test for FOOTFALL_ARRIVALS_SV_V3 (owners from Fraser) on every park-day.

    python semantic-views/footfall/parity_v3.py [--since 2023-01-01]

Four checks, each reported per column as "park-days differing" plus totals:

  1. OWNERS vs the old table HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_FACTS_V3
       TOTAL_OWNERS  vs owner_heads_indicative
       OWNERS_RATIO  vs owners_ratio
     V3 coalesces a missing Fraser row to 0, and computes the ratio with div0, so it shows
     0 where v3 shows NULL. Those park-days are EXPLAINED (counted, not failures):
       - no Fraser figure: V3 0, v3 NULL
       - owners but no booked guests: V3 ratio 0 (div0), v3 ratio NULL (nullif)
     Anything else that differs is a failure.
  2. ESTIMATED: V3 builds fraser_estimated but never selects it, so owner_heads_estimated
     is compared with an independent query of the Fraser source.
  3. v2 UNCHANGED: every v2 metric, V2 view vs V3 view, on every park-day (cheaper than
     re-running parity_v2 against the old table, and it proves the same thing: v2 passed
     that test). Plus a hash of every row of the copied base views, and a DESCRIBE diff:
     every v2 dimension / metric / fact property must exist unchanged in v3.
  4. Assumptions: one Fraser row per park x day x logic; every owner row has a spine row.

Exit code 1 only on an unexplained mismatch.
"""
import argparse
import sys

from sf import session

DB = "HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL"
SV3, SV2 = f"{DB}.FOOTFALL_ARRIVALS_SV_V3", f"{DB}.FOOTFALL_ARRIVALS_SV_V2"
V3 = "HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_FACTS_V3"
TOL = 1e-9          # relative tolerance for float owner heads and ratios

ap = argparse.ArgumentParser()
ap.add_argument("--since", default="2023-01-01")
args = ap.parse_args()
s = session()
W = f"where park_days.on_park_date >= '{args.since}'"
DIMS = "dimensions park_days.park_code, park_days.on_park_date"
bad = 0


def close(a, b):
    """SQL: a and b equal within TOL (relative), both treated as numbers."""
    return f"abs({a} - {b}) <= {TOL} * greatest(1, abs({a}), abs({b}))"


def n(x):
    return f"{x:,.0f}" if x is not None else "NULL"


# ---- 1. owners vs the old table --------------------------------------------------------
# park_days in the query makes it return every spine row (v1 finding), so a park-day
# without owners or guests still comes back, with NULL owner metrics.
r = s.sql(f"""
with sv as (
    select * from semantic_view({SV3} {DIMS}
        metrics owners.owner_heads_indicative, owners_ratio, guests.guest_nights, park_days.park_days {W})
),
v as (select park_code, on_park_date::date as on_park_date, total_owners, owners_ratio, total_nights
      from {V3} where on_park_date >= '{args.since}')
select
    count(*)                                                        as park_days,
    count_if(sv.park_code is null)                                  as only_in_v3,
    count_if(v.park_code is null)                                   as only_in_sv,
    -- TOTAL_OWNERS
    sum(v.total_owners)                                             as v3_owners,
    sum(sv.owner_heads_indicative)                                  as sv_owners,
    count_if(not {close('v.total_owners', 'coalesce(sv.owner_heads_indicative, 0)')}) as own_differ,
    count_if(sv.owner_heads_indicative is null)                     as own_sv_null,
    count_if(sv.owner_heads_indicative is null and v.total_owners = 0) as own_null_v3_zero,
    count_if(sv.owner_heads_indicative = 0)                         as own_true_zero,
    -- OWNERS_RATIO
    sum(v.owners_ratio)                                             as v3_ratio,
    sum(sv.owners_ratio)                                            as sv_ratio,
    count_if(not {close('v.owners_ratio', 'coalesce(sv.owners_ratio, 0)')}) as ratio_differ,
    count_if(sv.owners_ratio is null and sv.owner_heads_indicative is null and v.owners_ratio = 0) as ratio_no_fraser,
    count_if(sv.owners_ratio is null and sv.owner_heads_indicative is not null
             and coalesce(sv.guest_nights, 0) = 0 and v.owners_ratio = 0)  as ratio_no_guests,
    count_if(sv.owners_ratio is null and sv.owner_heads_indicative > 0
             and coalesce(sv.guest_nights, 0) = 0)                  as ratio_no_guests_with_owners,
    count_if(sv.owners_ratio > 1)                                   as ratio_gt_1,
    max(sv.owners_ratio)                                            as ratio_max,
    -- is the owners' guest denominator the same as V3's?
    count_if(coalesce(sv.guest_nights, 0) <> v.total_nights)        as nights_differ
from v full outer join sv on sv.park_code = v.park_code and sv.on_park_date = v.on_park_date
""").collect()[0].as_dict()

print(f"park-days compared: {r['PARK_DAYS']:,}   only in V3: {r['ONLY_IN_V3']}   only in SV: {r['ONLY_IN_SV']}"
      f"   guest_nights <> V3 TOTAL_NIGHTS: {r['NIGHTS_DIFFER']}\n")
print("1. OWNERS vs DAILY_FOOTFALL_FACTS_V3 (floats, relative tolerance 1e-9; SV NULL compared as 0)")
print(f"{'column':<40}{'park-days differing':>20}{'V3 total':>16}{'SV total':>16}")
print(f"{'TOTAL_OWNERS / owner_heads_indicative':<40}{r['OWN_DIFFER']:>20,}{n(r['V3_OWNERS']):>16}{n(r['SV_OWNERS']):>16}")
print(f"{'OWNERS_RATIO / owners_ratio':<40}{r['RATIO_DIFFER']:>20,}{r['V3_RATIO']:>16,.2f}{r['SV_RATIO']:>16,.2f}")
print("   EXPLAINED (V3 shows 0, v3 shows NULL):")
print(f"     no Fraser figure (owner_heads NULL, V3 TOTAL_OWNERS = 0):              {r['OWN_NULL_V3_ZERO']:>7,} of {r['OWN_SV_NULL']:,} NULL park-days")
print(f"     owners_ratio NULL because no Fraser figure (V3 ratio 0):             {r['RATIO_NO_FRASER']:>7,}")
print(f"     owners_ratio NULL because no booked guests (V3 div0 = 0):            {r['RATIO_NO_GUESTS']:>7,}"
      f"  (of which with owner heads > 0: {r['RATIO_NO_GUESTS_WITH_OWNERS']:,})")
print(f"   real zeros sent by Fraser (owner_heads_indicative = 0): {r['OWN_TRUE_ZERO']:,};"
      f"  owners_ratio > 1 on {r['RATIO_GT_1']:,} park-days (max {r['RATIO_MAX']:.2f})")
unexplained_null = r["OWN_SV_NULL"] - r["OWN_NULL_V3_ZERO"]
bad += r["ONLY_IN_V3"] + r["ONLY_IN_SV"] + r["NIGHTS_DIFFER"] + r["OWN_DIFFER"] + r["RATIO_DIFFER"] + unexplained_null

# ---- 2. estimated vs an independent query of the Fraser source ------------------------
e = s.sql(f"""
with src as (   -- V3's fraser_estimated CTE, verbatim apart from the date window
    select c.day_date as on_park_date, p.park_code, sum(h.heads * 7)::float as total_owners_estimated
    from haven_store.heads_on_park.fct_heads_on_park h
        join haven_store.heads_on_park.dim_on_park_guest_type gt using (guest_type_xid)
        join haven_store.common.dim_calendar c using (date_xid)
        join haven_store.common.dim_park p using (park_xid)
    where gt.guest_type = 'Owners' and gt.calculation_logic = 'Estimated'
      and c.day_date >= '{args.since}' and c.day_date < current_date
    group by c.day_date, p.park_code
),
sv as (select * from semantic_view({SV3} {DIMS} metrics owners.owner_heads_estimated {W})
       where owner_heads_estimated is not null)
select count(*) as park_days, count_if(sv.park_code is null) only_src, count_if(src.park_code is null) only_sv,
       count_if(not {close('coalesce(src.total_owners_estimated, 0)', 'coalesce(sv.owner_heads_estimated, 0)')}) as differ,
       sum(src.total_owners_estimated) src_total, sum(sv.owner_heads_estimated) sv_total
from src full outer join sv on sv.park_code = src.park_code and sv.on_park_date = src.on_park_date
""").collect()[0].as_dict()
print("\n2. ESTIMATED vs the Fraser source directly (V3 never selects it)")
print(f"{'column':<40}{'park-days differing':>20}{'source total':>16}{'SV total':>16}")
print(f"{'owner_heads_estimated':<40}{e['DIFFER']:>20,}{n(e['SRC_TOTAL']):>16}{n(e['SV_TOTAL']):>16}")
print(f"   park-days with an Estimated figure: {e['PARK_DAYS']:,}; only in source: {e['ONLY_SRC']}, only in SV: {e['ONLY_SV']}")
bad += e["DIFFER"] + e["ONLY_SRC"] + e["ONLY_SV"]

# ---- 3. v2 metrics unchanged -----------------------------------------------------------
V2M = ["guests.guest_nights", "guests.holiday_maker_nights", "guests.private_let_nights",
       "guests.guests_with_play_pass", "guests.first_day_guests", "guests.last_full_day_guests",
       "guests.leavers", "guests.distinct_guests", "guests.park_days_with_guests",
       "guests.bookings_on_park", "guests.first_day_bookings", "guests.leaver_bookings",
       "guests.adults_ratio", "guests.children_ratio", "guests.infants_ratio", "guests.play_pass_ratio",
       "guests.holiday_makers_ratio", "guests.private_lets_ratio", "guests.first_day_ratio",
       "guests.leavers_ratio", "guests.last_full_day_ratio", "guests.first_day_adults_ratio",
       "guests.first_day_children_ratio", "guests.first_day_infants_ratio",
       "park_days.park_days", "avg_guests_per_day", "guests_on_park"]
cols = [m.split(".")[-1] for m in V2M]
ml = ", ".join(V2M)
sel = ", ".join(f"count_if(not equal_null(a.{c}, b.{c})) d_{c}, sum(a.{c}) a_{c}, sum(b.{c}) b_{c}" for c in cols)
v = s.sql(f"""
with a as (select * from semantic_view({SV2} {DIMS} metrics {ml} {W})),
     b as (select * from semantic_view({SV3} {DIMS} metrics {ml} {W}))
select count(*) n, count_if(a.park_code is null) only_v3, count_if(b.park_code is null) only_v2, {sel}
from a full outer join b using (park_code, on_park_date)
""").collect()[0].as_dict()
print(f"\n3. v2 METRICS, V2 view vs V3 view, park-days: {v['N']:,} (only in V2: {v['ONLY_V2']}, only in V3: {v['ONLY_V3']})")
print(f"{'metric':<28}{'park-days differing':>20}{'V2 total':>18}{'V3 total':>18}")
for c in cols:
    fa, fb = v[f"A_{c.upper()}"], v[f"B_{c.upper()}"]
    f = (lambda x: f"{x:,.4f}") if "ratio" in c or c.startswith("avg") else n
    print(f"{c:<28}{v[f'D_{c.upper()}']:>20,}{f(fa):>18}{f(fb):>18}")
    bad += v[f"D_{c.upper()}"]
bad += v["ONLY_V2"] + v["ONLY_V3"]

# the copied base views, row for row (order-independent hash of every column)
for a, b in [("FOOTFALL_SV_GUEST_DAYS_V2", "FOOTFALL_SV_GUEST_DAYS_V3"), ("FOOTFALL_SV_PARK_DAYS_V2", "FOOTFALL_SV_PARK_DAYS_V3")]:
    ha, hb, na, nb = s.sql(f"select (select hash_agg(*) from {a}), (select hash_agg(*) from {b}), "
                           f"(select count(*) from {a}), (select count(*) from {b})").collect()[0]
    print(f"   {a} vs {b}: {na:,} vs {nb:,} rows, hash_agg {'equal' if ha == hb else 'DIFFERENT'}")
    bad += ha != hb

# DESCRIBE diff: every v2 property must be in v3, except the ones deliberately changed
desc = {}
for name in (SV2, SV3):
    rows = s.sql(f"describe semantic view {name}").collect()
    desc[name] = {(x[0], x[1], x[2], x[3]): (x[4] or "").replace("_V2", "_V3") for x in rows}
EXPECTED_CHANGES = {   # (object_kind, object_name, parent, property): why
    ("TABLE", "GUESTS", None, "COMMENT"): "points to the owners table",
    (None, None, None, "COMMENT"): "view comment: v3, owners",
    ("CUSTOM_INSTRUCTION", None, None, "AI_SQL_GENERATION"): "owner rules added, v2 rules kept",
}
changed = [k for k, val in desc[SV2].items() if desc[SV3].get(k) != val]
unexpected = [k for k in changed if k not in EXPECTED_CHANGES]
print(f"   DESCRIBE: {len(desc[SV2]):,} v2 properties; changed in v3: {len(changed)} "
      "(" + ", ".join(f"{k[1] or 'view'}.{k[3]}" for k in changed) + f"); unexpected: {len(unexpected)}")
for k in unexpected:
    print(f"     UNEXPECTED: {k}: {desc[SV2][k][:80]!r} -> {str(desc[SV3].get(k))[:80]!r}")
# the v2 instructions must survive word for word inside the v3 text (bar the owner sentence)
ai2 = desc[SV2][("CUSTOM_INSTRUCTION", None, None, "AI_SQL_GENERATION")]
ai3 = desc[SV3][("CUSTOM_INSTRUCTION", None, None, "AI_SQL_GENERATION")]
# The only v2 sentences allowed to change are the two that said owners are not in the view.
REWRITTEN = ("This view has Holiday Makers and Private Lets only", "Owners are NOT included and cannot be derived here")
missing = [sent for sent in ai2.split(". ") if sent not in ai3]
unexpected_ai = [m for m in missing if not m.startswith(REWRITTEN)]
print(f"   AI_SQL_GENERATION: {len(ai2.split('. '))} v2 sentences, not word for word in v3: {len(missing)} "
      f"(the owner sentences, rewritten on purpose), unexpected: {len(unexpected_ai)}")
for m in missing:
    print(f"     {'rewritten' if m not in unexpected_ai else 'UNEXPECTED'}: {m[:110]}...")
bad += len(unexpected) + len(unexpected_ai)

# ---- 4. assumptions -----------------------------------------------------------------------
a = s.sql(f"""
select
  (select count(*) from (select park_xid, date_xid, guest_type_xid from haven_store.heads_on_park.fct_heads_on_park h
       join haven_store.heads_on_park.dim_on_park_guest_type gt using (guest_type_xid)
       where gt.guest_type = 'Owners' group by all having count(*) > 1)) as dup_fraser_rows,
  (select count(*) from {DB}.FOOTFALL_SV_OWNER_DAYS_V3 o
       where not exists (select 1 from {DB}.FOOTFALL_SV_PARK_DAYS_V3 d
                         where d.park_code = o.park_code and d.on_park_date = o.on_park_date)) as orphan_owner_rows,
  (select count(*) - count(distinct park_code, on_park_date) from {DB}.FOOTFALL_SV_OWNER_DAYS_V3) as dup_owner_keys,
  (select count_if(transacted_heads is null) from {DB}.FOOTFALL_SV_OWNER_DAYS_V3) as rows_without_transacted
""").collect()[0].as_dict()
print("\n4. ASSUMPTIONS")
print(f"   Fraser owner rows duplicated per park x date x logic: {a['DUP_FRASER_ROWS']}")
print(f"   owner rows without a spine row: {a['ORPHAN_OWNER_ROWS']}; duplicate owner keys: {a['DUP_OWNER_KEYS']}")
print(f"   owner rows with Estimated but no Transacted figure: {a['ROWS_WITHOUT_TRANSACTED']}"
      " (0 means park_days_with_owner_data = number of owner rows)")
bad += a["DUP_FRASER_ROWS"] + a["ORPHAN_OWNER_ROWS"] + a["DUP_OWNER_KEYS"] + a["ROWS_WITHOUT_TRANSACTED"]

print("\nPARITY OK (explained differences above are by design)" if bad == 0 else f"\nPARITY FAILED ({bad})")
sys.exit(0 if bad == 0 else 1)
