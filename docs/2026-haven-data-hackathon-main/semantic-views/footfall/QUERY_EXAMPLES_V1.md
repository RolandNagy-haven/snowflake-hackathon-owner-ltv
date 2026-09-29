# Querying the footfall semantic view: old SQL vs new, side by side

For people who know SQL and have not queried a Snowflake semantic view before.

- **Old:** `HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_FACTS_V3`, a wide table with one row
  per park per day (zero-padded) and one column per count (`TOTAL_NIGHTS`,
  `TOTAL_HOLIDAY_MAKERS`, `TOTAL_ADULTS`, ...).
- **New:** `HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V1`, a semantic view
  over one row per guest per night, with park, date, stay type, age and play pass as
  dimensions (definition: `FOOTFALL_ARRIVALS_SV_V1.sql`).

Every query below is in `query_examples_v1.sql`. `check_query_examples_v1.py` runs them all
and checks that the old and new answers are the same. Every number in this document comes
from those queries, run on 2026-09-25 (data up to 2026-09-24).

## 1. The model in one picture

```
guests     one row per booked guest per night    dims: stay_type, guest_age, play_pass
   |  (park_code, on_park_date)                  metrics: guest_nights, holiday_maker_nights, ...
park_days  one row per park per calendar day     dims: on_park_date, stay_week/month/year, park_code, ...
   |  (park_code)                                metric: park_days (counts calendar days)
parks      one row per park (DIM_PARK)           dims: park_name, region, park_cluster, park_size
```

You never write the joins. You name the dimensions (what to group by) and the metrics (what
to add up), and Snowflake builds the joins from the relationships in the view.

Names can be written qualified (`guests.stay_type`) or bare (`stay_type`). Bare names work
here because no name is used twice in this view.

## 2. The two ways to query it

Both work on this account, and both gave identical results in every scenario below.

**Flavour A: the `SEMANTIC_VIEW(...)` clause.** You list dimensions and metrics as clauses
inside a table function. There is no GROUP BY; the dimensions *are* the grouping. The result
is an ordinary table, so you can use any SQL around it.

```sql
select * from semantic_view(
    HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V1
    dimensions park_days.park_code
    metrics    guests.guest_nights
    where      park_days.on_park_date between '2025-08-01' and '2025-08-31'
)
order by guest_nights desc;
```

**Flavour B: the view name in FROM, standard SQL.** Metrics must be wrapped in `AGG()`,
dimensions in the SELECT must be in the GROUP BY.

```sql
select park_code, agg(guest_nights) as guest_nights
from HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V1
where on_park_date between '2025-08-01' and '2025-08-31'
group by park_code
order by guest_nights desc;
```

Docs: [Querying semantic views](https://docs.snowflake.com/en/user-guide/views-semantic/querying),
[SEMANTIC_VIEW clause](https://docs.snowflake.com/en/sql-reference/constructs/semantic_view),
[AGG function](https://docs.snowflake.com/en/sql-reference/functions/agg).

### Cheat sheet (every row tested against this view)

| | Flavour A `SEMANTIC_VIEW(...)` | Flavour B `FROM <view>` |
|---|---|---|
| Pick a metric | `metrics guests.guest_nights` | `agg(guest_nights)`. Without AGG: *"'...GUEST_NIGHTS' in select clause is neither an aggregate nor in the group by clause"*. `sum(guest_nights)`: *"Invalid metric expression"* |
| Group | list it under `dimensions`; no GROUP BY | put it in SELECT **and** GROUP BY (`group by 1` works). Missing: *"[...PARK_CODE] is not a valid group by expression"* |
| Only metrics, no grouping | yes | yes, no GROUP BY needed |
| Arithmetic on metrics | `metrics a / b as x` | `agg(a) / agg(b)` |
| Ad-hoc aggregate of a fact | `metrics sum(iff(guests.stay_type='Holiday Maker', guests.guest_night, 0)) as hm` | `sum(iff(stay_type='Holiday Maker', guest_night, 0))` |
| `count(*)` | n/a | not allowed: *"Invalid metric expression 'COUNT(*)'"* (`count(on_park_date)` works) |
| WHERE | dimensions and facts only, applied **before** the metrics are computed | same |
| WHERE on a metric | *"Requested semantic expression 'GUESTS.GUEST_NIGHTS' in WHERE clause must be one of the following types: (DIMENSION, FACT)"* | same error. Use `having agg(guest_nights) > ...` |
| HAVING | n/a (filter the result outside the clause) | only on `AGG(metric)`; a bare metric gives the "not a valid group by expression" error |
| Window functions, QUALIFY, joins, PIVOT | yes, **outside** the clause (it returns a plain table) | not in the same SELECT: *"Unsupported feature 'WINDOW FUNCTIONS'"*, *"Joins are not allowed in semantic query blocks"*. `PIVOT` directly on the view gave an internal error. Put the query in a CTE and do these in the outer query |
| Subquery in WHERE | not tested | uncorrelated `IN (select ...)` works |
| `select *` | returns the dims and metrics you listed | fails (`invalid identifier 'GUESTS.BOOKING_REF'`, a private fact) |
| Facts (row-level values) | `facts ...` cannot be combined with `metrics`: *"Facts and metrics cannot be requested in the same query"* | a bare fact returns one row per guest-night (`select guest_night ...`); rarely useful |
| Output column names | bare names (`GUEST_NIGHTS`) | the expression text (`AGG(GUEST_NIGHTS)`) unless you alias it, so always alias |

Rule of thumb: flavour B reads like normal SQL and is fine for one-off grouped answers.
Flavour A is easier to embed, because anything you want to do afterwards (joins, windows,
pivots) goes around it.

One difference from the old table that is not about the query language: V3's
`ON_PARK_DATE` is a `TIMESTAMP_NTZ` (midnight); the semantic view's `on_park_date` is a
`DATE`. Cast before joining the two.

---

## 3. Scenarios

### S1. Total guest nights for one park, one month

*How many guest nights did Craig Tara (CT) have in August 2025?*

```sql
-- old
select sum(total_nights) as guest_nights
from HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_FACTS_V3
where park_code = 'CT' and on_park_date between '2025-08-01' and '2025-08-31';

-- new A
select * from semantic_view(HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V1
    metrics guests.guest_nights
    where park_days.park_code = 'CT'
      and park_days.on_park_date between '2025-08-01' and '2025-08-31');

-- new B
select agg(guest_nights) as guest_nights
from HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V1
where park_code = 'CT' and on_park_date between '2025-08-01' and '2025-08-31';
```

| guest_nights |
|---|
| 130,971 |

Old, A and B: **match**.

What to notice
- `guest_nights` is `TOTAL_NIGHTS`: person-nights. Over a month it is not "people"; on a
  single day it is the number of guests on park.
- No GROUP BY anywhere: with no dimensions you get one row.

### S2. Top parks for one week, with name and region

*Top 5 parks by guest nights in the week starting Monday 4 August 2025.*

```sql
-- old: park name and region need a join
select f.park_code, p.park_name, p.director_region as region, sum(f.total_nights) as guest_nights
from HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_FACTS_V3 f
    join HAVEN_STORE.COMMON.DIM_PARK p on p.park_code = f.park_code
where f.on_park_date between '2025-08-04' and '2025-08-10'
group by f.park_code, p.park_name, p.director_region
order by guest_nights desc limit 5;

-- new A
select * from semantic_view(HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V1
    dimensions park_days.park_code, parks.park_name, parks.region
    metrics guests.guest_nights
    where park_days.stay_week = '2025-08-04')
order by guest_nights desc limit 5;

-- new B
select park_code, park_name, region, agg(guest_nights) as guest_nights
from HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V1
where stay_week = '2025-08-04'
group by park_code, park_name, region
order by guest_nights desc limit 5;
```

| park_code | park_name | region | guest_nights |
|---|---|---|---|
| DE | Devon Cliffs | South West | 38,409 |
| CT | Craig Tara | North | 32,637 |
| HM | Hafan y Mor | South West | 31,370 |
| PV | Primrose Valley | North | 28,919 |
| TP | Cleethorpes Beach | East | 28,434 |

Old, A and B: **match**.

What to notice
- `park_name` and `region` come from DIM_PARK, but you do not write the join.
- `stay_week` is a ready-made dimension (Monday of the week), so the filter is one equality.
- ORDER BY and LIMIT go outside the clause in A, and work normally in B.

### S3. Daily series for one park

*Guests on park at Craig Tara each day, 1-7 August 2025.*

```sql
-- old
select on_park_date, dayname(on_park_date) as day_of_week, total_nights as guest_nights
from HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_FACTS_V3
where park_code = 'CT' and on_park_date between '2025-08-01' and '2025-08-07'
order by on_park_date;

-- new A
select * from semantic_view(HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V1
    dimensions park_days.on_park_date, park_days.day_of_week
    metrics guests.guest_nights
    where park_days.park_code = 'CT'
      and park_days.on_park_date between '2025-08-01' and '2025-08-07')
order by on_park_date;

-- new B
select on_park_date, day_of_week, agg(guest_nights) as guest_nights
from HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V1
where park_code = 'CT' and on_park_date between '2025-08-01' and '2025-08-07'
group by on_park_date, day_of_week
order by on_park_date;
```

| on_park_date | day_of_week | guest_nights |
|---|---|---|
| 2025-08-01 | Fri | 4,341 |
| 2025-08-02 | Sat | 4,323 |
| 2025-08-03 | Sun | 4,309 |
| 2025-08-04 | Mon | 4,542 |
| 2025-08-05 | Tue | 4,659 |
| 2025-08-06 | Wed | 4,642 |
| 2025-08-07 | Thu | 4,639 |

Old, A and B: **match** (after treating V3's midnight timestamp as a date).

What to notice
- Adding `on_park_date` as a dimension is all it takes to go from a total to a series.
- This park had guests every day. S7 shows what happens on days with none.

### S4. Breakdown by a guest attribute (the cube V3 built by hand)

*Guest nights by age group at Craig Tara, August 2025.*

```sql
-- old: one column per age, unpivoted by hand
select guest_age, guest_nights
from (select sum(total_adults) as "Adult", sum(total_children) as "Child", sum(total_infants) as "Infant"
      from HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_FACTS_V3
      where park_code = 'CT' and on_park_date between '2025-08-01' and '2025-08-31')
unpivot (guest_nights for guest_age in ("Adult", "Child", "Infant"))
order by guest_age;

-- new A
select * from semantic_view(HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V1
    dimensions guests.guest_age
    metrics guests.guest_nights
    where park_days.park_code = 'CT'
      and park_days.on_park_date between '2025-08-01' and '2025-08-31')
order by guest_age;

-- new B
select guest_age, agg(guest_nights) as guest_nights
from HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V1
where park_code = 'CT' and on_park_date between '2025-08-01' and '2025-08-31'
group by guest_age order by guest_age;
```

| guest_age | guest_nights |
|---|---|
| Adult | 74,620 |
| Child | 45,002 |
| Infant | 11,349 |

Old, A and B: **match**.

The new view can also cross the attributes, which V3 cannot: every V3 column applies one
condition, so there is no "adult holiday makers with a play pass" column.

```sql
select stay_type, guest_age, play_pass, agg(guest_nights) as guest_nights
from HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V1
where park_code = 'CT' and on_park_date between '2025-08-01' and '2025-08-31'
group by stay_type, guest_age, play_pass order by 1, 2, 3;
```

| stay_type | guest_age | Has play pass | No play pass |
|---|---|---|---|
| Holiday Maker | Adult | 56,496 | 7,454 |
| Holiday Maker | Child | 36,842 | 2,957 |
| Holiday Maker | Infant | 9,231 | 651 |
| Private Let | Adult | 2,500 | 8,170 |
| Private Let | Child | 1,611 | 3,592 |
| Private Let | Infant | 522 | 945 |

(Query returns 12 long rows; shown pivoted here. No old equivalent. The Adult rows add up
to 74,620, as in the table above.)

What to notice
- In V3 each breakdown is a column somebody had to write. Here it is a dimension, and
  any combination of dimensions works.
- 74,620 + 45,002 + 11,349 = 130,971, the S1 total. Every guest-night has exactly one
  age, so the groups add up to the total.

### S5. Segments side by side (holiday makers vs private lets as columns)

*Holiday makers, private lets and play-pass guests per park, August 2025 (CT, HA, WM).*

```sql
-- old: they are columns already
select park_code, sum(total_holiday_makers) as holiday_maker_nights,
       sum(total_private_lets) as private_let_nights, sum(total_play_pass) as guests_with_play_pass
from HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_FACTS_V3
where park_code in ('CT','HA','WM') and on_park_date between '2025-08-01' and '2025-08-31'
group by park_code order by park_code;

-- new A, option 1: the view has segment metrics for exactly this
select * from semantic_view(HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V1
    dimensions park_days.park_code
    metrics guests.holiday_maker_nights, guests.private_let_nights, guests.guests_with_play_pass
    where park_days.park_code in ('CT','HA','WM')
      and park_days.on_park_date between '2025-08-01' and '2025-08-31')
order by park_code;

-- new A, option 2: group by the dimensions, pivot outside the clause
with long as (
    select * from semantic_view(HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V1
        dimensions park_days.park_code, guests.stay_type, guests.play_pass
        metrics guests.guest_nights
        where park_days.park_code in ('CT','HA','WM')
          and park_days.on_park_date between '2025-08-01' and '2025-08-31'))
select park_code,
       sum(iff(stay_type = 'Holiday Maker', guest_nights, 0)) as holiday_maker_nights,
       sum(iff(stay_type = 'Private Let',   guest_nights, 0)) as private_let_nights,
       sum(iff(play_pass = 'Has play pass', guest_nights, 0)) as guests_with_play_pass
from long group by park_code order by park_code;

-- new B, option 1
select park_code, agg(holiday_maker_nights) as holiday_maker_nights,
       agg(private_let_nights) as private_let_nights, agg(guests_with_play_pass) as guests_with_play_pass
from HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V1
where park_code in ('CT','HA','WM') and on_park_date between '2025-08-01' and '2025-08-31'
group by park_code order by park_code;

-- new B, option 2: ad-hoc, from the fact guest_night (= 1 per guest-night)
select park_code,
       sum(iff(stay_type = 'Holiday Maker', guest_night, 0)) as holiday_maker_nights,
       sum(iff(stay_type = 'Private Let',   guest_night, 0)) as private_let_nights,
       sum(iff(play_pass = 'Has play pass', guest_night, 0)) as guests_with_play_pass
from HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V1
where park_code in ('CT','HA','WM') and on_park_date between '2025-08-01' and '2025-08-31'
group by park_code order by park_code;
```

| park_code | holiday_maker_nights | private_let_nights | guests_with_play_pass |
|---|---|---|---|
| CT | 113,631 | 17,340 | 107,202 |
| HA | 91,272 | 12,062 | 79,504 |
| WM | 64,089 | 9,297 | 62,222 |

Old and all four new versions: **match**.

What to notice
- A *segment metric* (`holiday_maker_nights`) is a metric with the condition built in:
  `sum(iff(stay_type = 'Holiday Maker', 1, 0))`. It is not a filter, so it leaves the
  rest of the query alone. This matters for averages (S8).
- `PIVOT` is not allowed directly on the view in flavour B (it gave an internal error).
  Pivot outside a flavour A clause or a CTE instead.
- **Correction (added with v3):** the ad-hoc version is not flavour-B-only. Flavour A
  accepts the same conditional aggregate *inside* the `METRICS` clause, and it can be
  combined with other metrics there (see the cheat sheet row "Ad-hoc aggregate of a
  fact", and S8 below for why this matters):
  `metrics sum(iff(guests.stay_type = 'Holiday Maker', guests.guest_night, 0)) as holiday_maker_nights, ...`.
  Pivoting outside the clause (option 2) is one way to do it, not the only way.

### S6. Average guests per day for a month, closed days counted as zero

*Average guests per day in March 2025 at HA, PS and RV. These parks were empty on some
days (RV opened on 21 March).*

```sql
-- old: works because V3 has a row with 0 for every empty day
select park_code, count(*) as park_days, count_if(total_nights > 0) as park_days_with_guests,
       sum(total_nights) as guest_nights, avg(total_nights) as avg_guests_per_day
from HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_FACTS_V3
where park_code in ('HA','PS','RV') and on_park_date between '2025-03-01' and '2025-03-31'
group by park_code order by park_code;

-- new A
select * from semantic_view(HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V1
    dimensions park_days.park_code
    metrics park_days.park_days, guests.park_days_with_guests, guests.guest_nights, avg_guests_per_day
    where park_days.park_code in ('HA','PS','RV') and park_days.stay_month = '2025-03-01')
order by park_code;

-- new B
select park_code, agg(park_days) as park_days, agg(park_days_with_guests) as park_days_with_guests,
       agg(guest_nights) as guest_nights, agg(avg_guests_per_day) as avg_guests_per_day
from HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V1
where park_code in ('HA','PS','RV') and stay_month = '2025-03-01'
group by park_code order by park_code;
```

| park_code | park_days | park_days_with_guests | guest_nights | avg_guests_per_day |
|---|---|---|---|---|
| HA | 31 | 25 | 42,426 | 1,368.58 |
| PS | 31 | 21 | 25,751 | 830.68 |
| RV | 31 | 11 | 8,358 | 269.61 |

Old, A and B: **match**.

The easy mistake: take a daily series (as in S3) and average it in SQL. The semantic view
returns no row for a day with no guests (see S7), so `avg()` divides by 11 days, not 31:

| park_code | days averaged | avg (wrong) |
|---|---|---|
| HA | 25 | 1,697.04 |
| PS | 21 | 1,226.24 |
| RV | 11 | 759.82 |

What to notice
- `park_days` counts calendar days from the `park_days` table, whether or not anyone was
  there. `avg_guests_per_day` is `guest_nights / park_days`.
- In V3, `avg(total_nights)` is right only because V3 stores the zero rows. In the new
  view, use `avg_guests_per_day`; don't average rows yourself.

### S7. Zero-padded daily series

*Riviera Bay (RV), 17-23 March 2025, one row per day including the days before it opened.*

```sql
-- old
select on_park_date, total_nights as guests_on_park
from HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_FACTS_V3
where park_code = 'RV' and on_park_date between '2025-03-17' and '2025-03-23'
order by on_park_date;

-- new A
select * from semantic_view(HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V1
    dimensions park_days.on_park_date
    metrics guests_on_park
    where park_days.park_code = 'RV'
      and park_days.on_park_date between '2025-03-17' and '2025-03-23')
order by on_park_date;

-- new B
select on_park_date, agg(guests_on_park) as guests_on_park
from HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V1
where park_code = 'RV' and on_park_date between '2025-03-17' and '2025-03-23'
group by on_park_date order by on_park_date;
```

| on_park_date | old `total_nights` | new `guests_on_park` | new `guest_nights` (wrong for this) |
|---|---|---|---|
| 2025-03-17 | 0 | 0 | *no row* |
| 2025-03-18 | 0 | 0 | *no row* |
| 2025-03-19 | 0 | 0 | *no row* |
| 2025-03-20 | 0 | 0 | *no row* |
| 2025-03-21 | 822 | 822 | 822 |
| 2025-03-22 | 822 | 822 | 822 |
| 2025-03-23 | 822 | 822 | 822 |

Old, A and B with `guests_on_park`: **match** (7 rows). With `guest_nights`: 3 rows.

What to notice
- A semantic view returns a row for a park-day only if some metric has something to
  count there. `guest_nights` has no guest rows on 17-20 March, so those days vanish.
- `guests_on_park` includes the calendar metric `park_days` in its formula, so every
  calendar day produces a row, and it returns 0 where there are no guests.
- Use `guests_on_park` for time series, model features and exports.

### S8. Per-segment daily average: why a WHERE on stay type gives the wrong answer

*Average holiday makers on park per day at Haggerston (HA), 6-12 November 2025.*

Here is what V3 holds for that week. Holiday makers were there until the 9th. From the
10th only private lets were on park:

| on_park_date | total_nights | total_holiday_makers | total_private_lets |
|---|---|---|---|
| 2025-11-06 | 1,246 | 1,238 | 8 |
| 2025-11-07 | 2,240 | 2,138 | 102 |
| 2025-11-08 | 2,260 | 2,158 | 102 |
| 2025-11-09 | 2,106 | 2,010 | 96 |
| 2025-11-10 | 1 | **0** | 1 |
| 2025-11-11 | 1 | **0** | 1 |
| 2025-11-12 | 1 | **0** | 1 |

The answer we want: 7,544 holiday-maker nights over 7 days = **1,077.7 per day**.

```sql
-- old
select sum(total_holiday_makers) as holiday_maker_nights, count(*) as park_days,
       sum(total_holiday_makers) / count(*) as avg_holiday_makers_per_day
from HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_FACTS_V3
where park_code = 'HA' and on_park_date between '2025-11-06' and '2025-11-12';

-- new, RIGHT (A): segment metric / park_days, no filter on stay_type
select * from semantic_view(HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V1
    metrics guests.holiday_maker_nights, park_days.park_days,
            guests.holiday_maker_nights / park_days.park_days as avg_holiday_makers_per_day
    where park_days.park_code = 'HA'
      and park_days.on_park_date between '2025-11-06' and '2025-11-12');

-- new, RIGHT (B)
select agg(holiday_maker_nights) as holiday_maker_nights, agg(park_days) as park_days,
       agg(holiday_maker_nights) / agg(park_days) as avg_holiday_makers_per_day
from HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V1
where park_code = 'HA' and on_park_date between '2025-11-06' and '2025-11-12';

-- new, WRONG (A): filter to holiday makers, then use the general average
select * from semantic_view(HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V1
    metrics guests.guest_nights, park_days.park_days, avg_guests_per_day
    where park_days.park_code = 'HA'
      and park_days.on_park_date between '2025-11-06' and '2025-11-12'
      and guests.stay_type = 'Holiday Maker');

-- new, WRONG (B): same thing in flavour B
select agg(guest_nights) as guest_nights, agg(park_days) as park_days,
       agg(avg_guests_per_day) as avg_guests_per_day
from HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V1
where park_code = 'HA' and on_park_date between '2025-11-06' and '2025-11-12'
  and stay_type = 'Holiday Maker';
```

| query | holiday-maker nights | park_days | average per day |
|---|---|---|---|
| old: `sum(total_holiday_makers) / count(*)` | 7,544 | 7 | **1,077.71** |
| new A or B: `holiday_maker_nights / park_days` | 7,544 | 7 | **1,077.71** (match) |
| new A or B: `WHERE stay_type = 'Holiday Maker'` + `avg_guests_per_day` | 7,544 | **4** | **1,886.00** (wrong) |
| new A: `GROUP BY stay_type`, Holiday Maker row | 7,544 | **4** | **1,886.00** (wrong) |

The total (7,544) is right in every version. Only the day count is wrong, so anything that
divides by days is wrong.

**Why.** The view has two tables: the calendar (`park_days`, one row per park per day)
and the guest rows (`guests`, one row per guest per night). `park_days` is a count of
calendar rows.

- A filter on `park_code` or `on_park_date` is a filter on calendar columns. It removes
  calendar rows directly, and the 7 days of the week remain. That filter is safe.
- `stay_type` is not a column of the calendar. It exists only on guest rows. To apply
  `stay_type = 'Holiday Maker'` to the calendar, Snowflake keeps **a calendar day only if
  at least one guest row on that park-day has stay_type = 'Holiday Maker'**. That is a
  `WHERE EXISTS` (semi-join) from the calendar to the filtered guest rows.
- On 10-12 November there are guest rows, but only private lets. None pass the filter, so
  those three calendar days are dropped before `park_days` is counted: 7 becomes 4.

V3 does not have this problem because "holiday makers" is a *column* there, not a row
filter. The 10th still has a row, with `total_holiday_makers = 0`, and `count(*)` is 7.
The segment metric `holiday_maker_nights` does the same thing in the new view: the
condition sits inside the sum, so no calendar row is removed.

**How this was checked.**
1. The filter drops calendar days even when no guest metric is requested:
   `metrics park_days.park_days where ... and guests.stay_type = 'Holiday Maker'` returns 4.
   With the filter and the day as a dimension, you get only the 4 rows for 6-9 Nov.
2. The plain SQL below gives the same 4:
   ```sql
   select count(*) from FOOTFALL_SV_PARK_DAYS_V1 d
   where d.park_code = 'HA' and d.on_park_date between '2025-11-06' and '2025-11-12'
     and exists (select 1 from FOOTFALL_SV_GUEST_NIGHTS_V1 g
                 where g.park_code = d.park_code and g.on_park_date = d.on_park_date
                   and g.stay_type = 'Holiday Maker');
   ```
3. `EXPLAIN` of the filtered query shows an inner join from the calendar to the
   *distinct* (park_code, date) pairs of Holiday Maker guest rows. It is an inner join,
   but on distinct keys, so it removes days without adding rows. The count is 4, not 7,544.
4. Over the whole history (2023-01-01 to 2026-09-24), `park_days` is 55,883 without the
   filter and 36,365 with it. 36,365 is also the number of V3 rows with
   `total_holiday_makers > 0`.
5. Flavour B behaves the same: same query, same 4 and 1,886.

What to notice
- A WHERE on a guest attribute (`stay_type`, `guest_age`, `play_pass`) is safe for totals
  and wrong for anything divided by days (`park_days`, `avg_guests_per_day`,
  `guests_on_park` rows). GROUP BY on a guest attribute does the same per group
  (Holiday Maker 4 days, Private Let 7 days here).
- For a per-segment daily average, divide the segment metric by the unfiltered day count:
  `holiday_maker_nights / park_days`, `private_let_nights / park_days`,
  `guests_with_play_pass / park_days`.
- **No ready segment metric? Define one inside `METRICS`** (added with v3; this corrects
  the impression above that ad-hoc conditional aggregation only works outside the
  clause). The condition goes into the metric, not the WHERE, so no calendar day is
  dropped. This is the cleanest general way around the trap:
  ```sql
  select * from semantic_view(HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V1
      metrics sum(iff(guests.stay_type = 'Holiday Maker', guests.guest_night, 0)) as hm_nights,
              park_days.park_days,
              hm_nights / park_days.park_days as avg_hm_per_day
      where park_days.park_code = 'HA'
        and park_days.on_park_date between '2025-11-06' and '2025-11-12');
  ```
  Result (run on 2026-09-25): `hm_nights` 7,544, `park_days` 7, `avg_hm_per_day`
  1,077.71, the right answer. Flavour B does the same with an aggregate over the fact
  next to `AGG()`: `sum(iff(stay_type = 'Holiday Maker', guest_night, 0)) / agg(park_days)`
  gives the same 7,544 / 7 / 1,077.71. More in `QUERY_EXAMPLES_V3.md` S6.
- Filters on park, region or date are safe. `where parks.region = 'South West'` for that
  week gives `park_days` = 119 (17 parks x 7 days), the same as counting the calendar
  directly.

---

## 4. Summary: which metric for which question

| Question | Use | Not |
|---|---|---|
| Total guest nights | `guest_nights` | |
| Segment totals as columns | `holiday_maker_nights`, `private_let_nights`, `guests_with_play_pass` | |
| Breakdown by segment/age/play pass | a dimension (`stay_type`, `guest_age`, `play_pass`) | |
| Average guests per day | `avg_guests_per_day` | `avg()` over a daily result |
| Average per day for a segment | `holiday_maker_nights / park_days` | `WHERE stay_type = ...` + `avg_guests_per_day` |
| Daily series with zero days | `guests_on_park` | `guest_nights` |
| How many days were open | `park_days_with_guests` (vs `park_days`) | |
