"""Does SEMANTIC_VIEW() keep park-days that have no guests? (the date-spine experiment)

    python semantic-views/footfall/spine_experiment_v1.py

Compares, for the whole 2023..yesterday history:
  spine rows          rows in FOOTFALL_SV_PARK_DAYS_V1 (every park x day)
  guest park-days     park x days with at least one guest row
  E1                  SEMANTIC_VIEW grouped by the spine's park + date, guest metric only
  E2                  E1 plus a filter on a guest-table dimension (stay_type)
  E3                  E1 plus a spine-table metric (park_days) alongside the guest metric
  E4                  wrapper pattern: spine LEFT JOIN SEMANTIC_VIEW, coalesce to 0
and checks what avg_guests_per_day divides by on a month with closed days.
"""
from sf import session

SV = "HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V1"
s = session()


def one(sql):
    return s.sql(sql).collect()[0]


def show(label, sql):
    r = one(sql)
    print(f"{label:<58} rows={r['N_ROWS']:>7,}  null_guest_rows={r['NULL_ROWS']:>6,}")
    return r["N_ROWS"]


spine = one("select count(*) n from FOOTFALL_SV_PARK_DAYS_V1")["N"]
guest_days = one("select count(*) n from (select distinct park_code, on_park_date from FOOTFALL_SV_GUEST_NIGHTS_V1)")["N"]
print(f"{'spine rows (every park x day)':<58} rows={spine:>7,}")
print(f"{'park-days with >=1 guest row':<58} rows={guest_days:>7,}")
print(f"{'  -> park-days with no guests':<58} rows={spine - guest_days:>7,}\n")

show("E1 spine dims + guest metric", f"""
    select count(*) n_rows, count_if(guest_nights is null) null_rows from semantic_view({SV}
      dimensions park_days.park_code, park_days.on_park_date
      metrics guests.guest_nights)""")
show("E2 E1 + where guests.stay_type = 'Holiday Maker'", f"""
    select count(*) n_rows, count_if(guest_nights is null) null_rows from semantic_view({SV}
      dimensions park_days.park_code, park_days.on_park_date
      metrics guests.guest_nights
      where guests.stay_type = 'Holiday Maker')""")
show("E3 E1 + spine metric park_days", f"""
    select count(*) n_rows, count_if(guest_nights is null) null_rows from semantic_view({SV}
      dimensions park_days.park_code, park_days.on_park_date
      metrics guests.guest_nights, park_days.park_days)""")
show("E4 wrapper: spine left join SEMANTIC_VIEW, coalesce 0", f"""
    with sv as (
      select * from semantic_view({SV}
        dimensions park_days.park_code, park_days.on_park_date
        metrics guests.guest_nights))
    select count(*) n_rows, count_if(sv.guest_nights is null) null_rows
    from FOOTFALL_SV_PARK_DAYS_V1 d
      left join sv on sv.park_code = d.park_code and sv.on_park_date = d.on_park_date""")

# Averages: pick the park-month with the most closed days and compare the divisors.
pm = one("""
    select d.park_code, date_trunc('month', d.on_park_date) m, count(*) days, count(g.on_park_date) open_days
    from FOOTFALL_SV_PARK_DAYS_V1 d
      left join (select distinct park_code, on_park_date from FOOTFALL_SV_GUEST_NIGHTS_V1) g
        using (park_code, on_park_date)
    where d.on_park_date >= '2024-01-01'
    group by 1, 2 having count(g.on_park_date) between 1 and count(*) - 5
    order by count(*) - count(g.on_park_date) desc limit 1""")
print(f"\nAverages for {pm['PARK_CODE']} {pm['M']:%Y-%m}: {pm['DAYS']} calendar days, {pm['OPEN_DAYS']} with guests")
r = one(f"""
    select * from semantic_view({SV}
      dimensions park_days.park_code, park_days.stay_month
      metrics guests.guest_nights, park_days.park_days, guests.park_days_with_guests, avg_guests_per_day
      where park_days.park_code = '{pm['PARK_CODE']}' and park_days.stay_month = '{pm['M']:%Y-%m-%d}')""")
print(f"  guest_nights={r['GUEST_NIGHTS']:,}  park_days={r['PARK_DAYS']}  park_days_with_guests={r['PARK_DAYS_WITH_GUESTS']}")
print(f"  avg_guests_per_day={r['AVG_GUESTS_PER_DAY']:.1f}  "
      f"(per open day would be {r['GUEST_NIGHTS'] / r['PARK_DAYS_WITH_GUESTS']:.1f})")
