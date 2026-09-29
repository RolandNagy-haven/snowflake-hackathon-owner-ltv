"""Parity test: FOOTFALL_ARRIVALS_SV_V2 vs HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_FACTS_V3.

    python semantic-views/footfall/parity_v2.py [--since 2023-01-01]

Rebuilds every non-owner V3 column that v2 covers, on every park x day, from THREE
semantic queries:

  q_guests    park x date x stay_type x guest_age x play_pass x the 3 day flags,
              metrics guest_nights + leavers  -> pivoted to TOTAL_*, FIRST_DAY*,
              LAST_FULL_DAY, LEAVERS* (person counts are additive, so any pivot works)
  q_bookings  park x date x stay_type x is_self_catering, the 3 booking metrics
              -> pivoted to the *_HOLIDAY_MAKERS / *_SELF_CATERING / *_PRIVATE_LETS
              booking columns. Summing distinct counts over these groups is valid ONLY
              because every booking has exactly one stay type and one self-catering value
              (checked below as "booking in 2 groups").
  q_day       park x date only: the 3 booking totals (recounted, not summed) + the 12
              ratio metrics, straight from the view.

Columns are grouped as:
  MATCH       must be identical on every park-day (ratios: abs tolerance 1e-6)
  EXPLAINED   differ by design; the script shows the numbers and checks that the
              difference is exactly the stated reason
Also checks that the v1 metrics did not change between FOOTFALL_ARRIVALS_SV_V1 and _V2.
Exit code 1 only on an unexplained mismatch.
"""
import argparse
import sys

from sf import session

SV = "HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V2"
SV1 = "HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V1"
V3 = "HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_FACTS_V3"
RATIO_TOL = 1e-6

HM, PL = "stay_type = 'Holiday Maker'", "stay_type = 'Private Let'"
FD = "is_first_day"

# V3 column -> pivot of q_guests (rows: guest_nights, leavers)
GUEST_COLS = {
    "TOTAL_NIGHTS":             "sum(guest_nights)",
    "TOTAL_HOLIDAY_MAKERS":     f"sum(iff({HM}, guest_nights, 0))",
    "TOTAL_PRIVATE_LETS":       f"sum(iff({PL}, guest_nights, 0))",
    "TOTAL_ADULTS":             "sum(iff(guest_age = 'Adult', guest_nights, 0))",
    "TOTAL_CHILDREN":           "sum(iff(guest_age = 'Child', guest_nights, 0))",
    "TOTAL_INFANTS":            "sum(iff(guest_age = 'Infant', guest_nights, 0))",
    "TOTAL_PLAY_PASS":          "sum(iff(play_pass = 'Has play pass', guest_nights, 0))",
    "TOTAL_NO_PLAY_PASS":       "sum(iff(play_pass = 'No play pass', guest_nights, 0))",
    "FIRST_DAY":                f"sum(iff({FD}, guest_nights, 0))",
    "FIRST_DAY_HOLIDAY_MAKERS": f"sum(iff({FD} and {HM}, guest_nights, 0))",
    "FIRST_DAY_PRIVATE_LETS":   f"sum(iff({FD} and {PL}, guest_nights, 0))",
    "FIRST_DAY_ADULTS":         f"sum(iff({FD} and guest_age = 'Adult', guest_nights, 0))",
    "FIRST_DAY_CHILDREN":       f"sum(iff({FD} and guest_age = 'Child', guest_nights, 0))",
    "FIRST_DAY_INFANTS":        f"sum(iff({FD} and guest_age = 'Infant', guest_nights, 0))",
    "FIRST_DAY_PLAY_PASS":      f"sum(iff({FD} and play_pass = 'Has play pass', guest_nights, 0))",
    "FIRST_DAY_NO_PLAY_PASS":   f"sum(iff({FD} and play_pass = 'No play pass', guest_nights, 0))",
    "LAST_FULL_DAY":            "sum(iff(is_last_full_day, guest_nights, 0))",
    "LEAVERS":                  "sum(leavers)",
    "LEAVERS_HOLIDAY_MAKERS":   f"sum(iff({HM}, leavers, 0))",
    "LEAVERS_PRIVATE_LETS":     f"sum(iff({PL}, leavers, 0))",
}

# V3 column -> pivot of q_bookings (sum over stay_type x is_self_catering groups)
SC = f"{HM} and is_self_catering"
BOOKING_COLS = {
    "TOTAL_BOOKINGS_HOLIDAY_MAKERS":                       f"sum(iff({HM}, bookings_on_park, 0))",
    "TOTAL_BOOKINGS_HOLIDAY_MAKERS_SELF_CATERING":         f"sum(iff({SC}, bookings_on_park, 0))",
    "TOTAL_BOOKINGS_PRIVATE_LETS":                         f"sum(iff({PL}, bookings_on_park, 0))",
    "FIRST_DAY_BOOKING_COUNT_HOLIDAY_MAKERS":              f"sum(iff({HM}, first_day_bookings, 0))",
    "FIRST_DAY_BOOKING_COUNT_HOLIDAY_MAKERS_SELF_CATERING": f"sum(iff({SC}, first_day_bookings, 0))",
    "FIRST_DAY_BOOKING_COUNT_PRIVATE_LETS":                f"sum(iff({PL}, first_day_bookings, 0))",
    "LEAVERS_BOOKING_COUNT_HOLIDAY_MAKERS":                f"sum(iff({HM}, leaver_bookings, 0))",
    "LEAVERS_BOOKING_COUNT_HOLIDAY_MAKERS_SELF_CATERING":  f"sum(iff({SC}, leaver_bookings, 0))",
    "LEAVERS_BOOKING_COUNT_PRIVATE_LETS":                  f"sum(iff({PL}, leaver_bookings, 0))",
}

# Booking totals: the SV recounts at park x day (q_day). V3's own totals include owner
# bookings, so the MATCH comparison is against V3's HM + PL columns, and the raw V3
# column is EXPLAINED if V3 - SV = V3's *_OWNERS column exactly.
BOOKING_TOTALS = {
    # SV metric          V3 total column             V3 HM column                              V3 PL column                           V3 owners column
    "bookings_on_park":   ("TOTAL_BOOKINGS",          "TOTAL_BOOKINGS_HOLIDAY_MAKERS",          "TOTAL_BOOKINGS_PRIVATE_LETS",          "TOTAL_BOOKINGS_OWNERS"),
    "first_day_bookings": ("FIRST_DAY_BOOKING_COUNT", "FIRST_DAY_BOOKING_COUNT_HOLIDAY_MAKERS", "FIRST_DAY_BOOKING_COUNT_PRIVATE_LETS", "FIRST_DAY_BOOKING_COUNT_OWNERS"),
    "leaver_bookings":    ("LEAVERS_BOOKING_COUNT",   "LEAVERS_BOOKING_COUNT_HOLIDAY_MAKERS",   "LEAVERS_BOOKING_COUNT_PRIVATE_LETS",   "LEAVERS_BOOKING_COUNT_OWNERS"),
}

# V3 ratio column -> SV ratio metric (q_day). OWNERS_RATIO waits for v3.
RATIOS = {
    "ADULTS_RATIO": "adults_ratio", "CHILDREN_RATIO": "children_ratio", "INFANTS_RATIO": "infants_ratio",
    "PLAYPASS_RATIO": "play_pass_ratio", "HOLIDAY_MAKERS_RATIO": "holiday_makers_ratio",
    "PRIVATE_LETS_RATIO": "private_lets_ratio", "FIRST_DAY_RATIO": "first_day_ratio",
    "LEAVERS_RATIO": "leavers_ratio", "LAST_FULL_DAY_RATIO": "last_full_day_ratio",
    "FIRST_DAY_ADULTS_RATIO": "first_day_adults_ratio", "FIRST_DAY_CHILDREN_RATIO": "first_day_children_ratio",
    "FIRST_DAY_INFANTS_RATIO": "first_day_infants_ratio",
}

ap = argparse.ArgumentParser()
ap.add_argument("--since", default="2023-01-01")
args = ap.parse_args()
s = session()
W = f"where park_days.on_park_date >= '{args.since}'"

# ---- 1. the main comparison: V3 vs the three semantic queries, per park-day ----------
g_piv = ",\n        ".join(f"{e} as {c}" for c, e in GUEST_COLS.items())
b_piv = ",\n        ".join(f"{e} as {c}" for c, e in BOOKING_COLS.items())
d_metrics = ", ".join(["guests.bookings_on_park", "guests.first_day_bookings", "guests.leaver_bookings"]
                      + [f"guests.{m}" for m in RATIOS.values()])

# every compared value: (label, v3 expr, sv expr, tolerance)
pairs = []
for c in list(GUEST_COLS) + list(BOOKING_COLS):
    pairs.append((c, f"v.{c}", f"n.{c}", 0))
for m, (tot, hm, pl, _own) in BOOKING_TOTALS.items():
    pairs.append((f"{tot} (V3 HM+PL)", f"(v.{hm} + v.{pl})", f"d.{m}", 0))
for c, m in RATIOS.items():
    pairs.append((c, f"v.{c}", f"d.{m}", RATIO_TOL))
# explained: raw V3 booking totals (with owners). diff_* = V3 - SV, own_* = V3 owners col
explained = []
for m, (tot, _hm, _pl, own) in BOOKING_TOTALS.items():
    explained.append((tot, m, own))

sel = []
for i, (label, a, b, tol) in enumerate(pairs):
    cond = (f"abs(coalesce({a}, 0) - coalesce({b}, 0)) > {tol}" if tol
            else f"coalesce({a}, 0) <> coalesce({b}, 0)")
    sel += [f"count_if({cond}) as n{i}", f"sum({a}) as v{i}", f"sum({b}) as s{i}"]
for i, (tot, m, own) in enumerate(explained):
    sel += [f"count_if(v.{tot} <> coalesce(d.{m}, 0)) as en{i}", f"sum(v.{tot}) as ev{i}",
            f"sum(d.{m}) as es{i}", f"sum(v.{own}) as eo{i}",
            f"count_if(v.{tot} - coalesce(d.{m}, 0) <> v.{own}) as ebad{i}"]

sql = f"""
with qg as (
    select * from semantic_view({SV}
        dimensions park_days.park_code, park_days.on_park_date,
                   guests.stay_type, guests.guest_age, guests.play_pass,
                   guests.is_first_day, guests.is_last_full_day, guests.is_departure_day
        metrics guests.guest_nights, guests.leavers
        {W})
),
qb as (
    select * from semantic_view({SV}
        dimensions park_days.park_code, park_days.on_park_date,
                   guests.stay_type, guests.is_self_catering
        metrics guests.bookings_on_park, guests.first_day_bookings, guests.leaver_bookings
        {W})
),
d as (
    select * from semantic_view({SV}
        dimensions park_days.park_code, park_days.on_park_date
        metrics {d_metrics}
        {W})
),
g as (select park_code, on_park_date, {g_piv} from qg group by 1, 2),
b as (select park_code, on_park_date, {b_piv} from qb group by 1, 2),
n as (
    select coalesce(g.park_code, b.park_code) as park_code,
           coalesce(g.on_park_date, b.on_park_date) as on_park_date, g.*exclude (park_code, on_park_date),
           b.*exclude (park_code, on_park_date)
    from g full outer join b on b.park_code = g.park_code and b.on_park_date = g.on_park_date
),
v as (select * exclude on_park_date, on_park_date::date as on_park_date from {V3}
      where on_park_date >= '{args.since}')
select
    count(*) as park_days,
    count_if(v.park_code is null) as only_in_sv,
    count_if(n.park_code is null and d.park_code is null
             and (v.total_nights + v.leavers) > 0) as only_in_v3_nonzero,
    {{SEL}}
from v
    full outer join n on n.park_code = v.park_code and n.on_park_date = v.on_park_date
    full outer join d on d.park_code = coalesce(v.park_code, n.park_code)
                     and d.on_park_date = coalesce(v.on_park_date, n.on_park_date)
"""
r = s.sql(sql.replace("{SEL}", ",\n    ".join(sel))).collect()[0].as_dict()


def fmt(x):
    return f"{x:,.2f}" if isinstance(x, float) or (x is not None and not float(x).is_integer()) else f"{int(x or 0):,}"


print(f"park-days compared: {r['PARK_DAYS']:,}   only in SV: {r['ONLY_IN_SV']}   "
      f"only in V3 with guests or leavers: {r['ONLY_IN_V3_NONZERO']}\n")
print("MATCH (must be identical; ratios within 1e-6)")
print(f"{'column':<54}{'park-days differing':>20}{'V3 total':>16}{'SV total':>16}")
bad = r["ONLY_IN_SV"] + r["ONLY_IN_V3_NONZERO"]
for i, (label, *_rest) in enumerate(pairs):
    bad += r[f"N{i}"]
    print(f"{label:<54}{r[f'N{i}']:>20,}{fmt(r[f'V{i}']):>16}{fmt(r[f'S{i}']):>16}")

print("\nEXPLAINED (differ by design: V3 counts owner bookings, v2 has no owners)")
print(f"{'column':<26}{'park-days differing':>20}{'V3 total':>13}{'SV total':>13}"
      f"{'V3 - SV':>12}{'V3 owners col':>15}{'  park-days where V3-SV <> owners':>34}")
for i, (tot, m, own) in enumerate(explained):
    ev, es, eo, eb = (int(r[f"{k}{i}"] or 0) for k in ("EV", "ES", "EO", "EBAD"))
    bad += eb   # only unexplained if the gap is NOT exactly the owner bookings
    print(f"{tot:<26}{r[f'EN{i}']:>20,}{ev:>13,}{es:>13,}{ev - es:>12,}{eo:>15,}{eb:>34,}")

# ---- 2. assumptions behind the booking pivots -----------------------------------------
chk = s.sql(f"""
with qb as (
    select park_code, on_park_date, sum(bookings_on_park) b, sum(first_day_bookings) f, sum(leaver_bookings) l
    from semantic_view({SV} dimensions park_days.park_code, park_days.on_park_date,
                       guests.stay_type, guests.is_self_catering
         metrics guests.bookings_on_park, guests.first_day_bookings, guests.leaver_bookings {W})
    group by 1, 2),
d as (select * from semantic_view({SV} dimensions park_days.park_code, park_days.on_park_date
         metrics guests.bookings_on_park, guests.first_day_bookings, guests.leaver_bookings {W}))
select count_if(qb.b <> d.bookings_on_park or qb.f <> d.first_day_bookings or qb.l <> d.leaver_bookings)
       as park_days_where_group_sum_differs
from qb join d using (park_code, on_park_date)
""").collect()[0][0]
# self-catering now comes from the arrival grade; V3 uses today's package snapshot.
# They must agree booking by booking (the parity columns check the counts; this checks
# the definition itself).
grade_vs_pkg = s.sql("""
with hm as (select distinct booking_id, grade_group from FOOTFALL_SV_GUEST_DAYS_V2 where stay_type = 'Holiday Maker'),
pk as (
    select h.booking_id, pt.package_type
    from haven_store.holiday.fct_holiday_bookings h
        left join haven_store.holiday.dim_package_type pt using (package_type_xid)
    where h.snapshot_date = current_date())
select count(*) as hm_bookings,
       count_if((coalesce(hm.grade_group, '') = 'Touring') <> (coalesce(pk.package_type, '') = 'TOURING')) as disagree
from hm left join pk on pk.booking_id = try_cast(split_part(hm.booking_id, ':', 2) as number)
""").collect()[0]
future = s.sql("""
select count(*) from haven_store.arrival.fct_park_arrival a
    join haven_store.arrival.dim_arrival_guest_type gt using (guest_type_xid)
where gt.stay_type in ('Holiday Maker', 'Private Let') and a.on_park_date_xid = a.departure_date_xid
  and to_date(a.on_park_date_xid::string, 'YYYYMMDD') >= current_date
""").collect()[0][0]
v3max = s.sql(f"select max(on_park_date)::date, count_if(leavers > 0 and on_park_date >= current_date) from {V3}").collect()[0]

print("\nASSUMPTIONS / KNOWN EFFECTS")
print(f"  booking in 2 stay_type / self-catering groups (group sum <> recount), park-days: {chk}")
print(f"  holiday-maker bookings where touring grade <> V3's TOURING package (today's snapshot): "
      f"{grade_vs_pkg[1]:,} of {grade_vs_pkg[0]:,}")
print(f"  departure rows dated today or later in the arrival table: {future:,}; V3's leavers CTE has no"
      f" date filter but its spine ends {v3max[0]} (V3 rows with leavers on/after today: {v3max[1]}),"
      " so they never reach V3's output")
bad += chk + grade_vs_pkg[1]

# ---- 3. v1 metrics unchanged by adding departure-day rows -----------------------------
V1M = ["guest_nights", "holiday_maker_nights", "private_let_nights", "guests_with_play_pass",
       "park_days_with_guests", "distinct_guests"]
m1 = ", ".join(f"guests.{m}" for m in V1M)
one = s.sql(f"""
with a as (select * from semantic_view({SV1} dimensions park_days.park_code, park_days.on_park_date metrics {m1}, park_days.park_days {W})),
     b as (select * from semantic_view({SV}  dimensions park_days.park_code, park_days.on_park_date metrics {m1}, park_days.park_days {W}))
select count(*) n, {", ".join(f"count_if(coalesce(a.{m},0) <> coalesce(b.{m},0)) d_{m}" for m in V1M + ['park_days'])}
from a full outer join b using (park_code, on_park_date)
""").collect()[0].as_dict()
v1diff = sum(v for k, v in one.items() if k.startswith("D_"))
print(f"\nV1 vs V2 semantic view, park-days: {one['N']:,}; park-days where any v1 metric differs: {v1diff}")
bad += v1diff

print("\nPARITY OK (explained differences above are by design)" if bad == 0 else f"\nPARITY FAILED ({bad})")
sys.exit(0 if bad == 0 else 1)
