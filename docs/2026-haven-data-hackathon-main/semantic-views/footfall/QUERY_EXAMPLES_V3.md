# Querying the footfall semantic view, v3: owners next to booked guests

The follow-up to `QUERY_EXAMPLES_V1.md` and `QUERY_EXAMPLES_V2.md`. Read V1 first for the two
ways to query a semantic view (flavour A `SEMANTIC_VIEW(...)`, flavour B `AGG()` over the
view) and the calendar trap. This page covers only what v3 adds: **owners**.

- **Old:** `HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_FACTS_V3`, columns `TOTAL_OWNERS`
  and `OWNERS_RATIO`.
- **New:** `HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V3` (definition:
  `FOOTFALL_ARRIVALS_SV_V3.sql`). Everything from v2 is still there, unchanged.

Every query below is in `query_examples_v3.sql`. `check_query_examples_v3.py` runs them all
and checks that old and new agree (or, for a documented pitfall, that they disagree). Every
number in this document comes from those queries, run on 2026-09-25 (data up to 2026-09-24).
Owner heads are floats, so they are rounded to 1 decimal before comparing.

## 1. What changed in the model

```
guests      one row per booked guest per day       owners     one row per park per day WITH a
   |        (Holiday Maker, Private Let)              |       Fraser owner figure (v3, new)
   |  (park_code, on_park_date)                       |  (park_code, on_park_date)
   +------------------> park_days <-------------------+
                        one row per park per calendar day   (the shared spine)
                           |  (park_code)
                        parks
```

Owners are a **second fact table on the same spine**. They share park and date with the
guests, and nothing else: no stay type, age, play pass, day flags or bookings.

### What an owner head is (and is not)

The figure comes from Fraser's heads-on-park model (`haven_store.heads_on_park`). Fraser does
not count owners. It infers caravans in use from **on-park spending** (EPOS / loyalty
transactions) and multiplies by a fixed rate of about **4 people per van** (measured: 3.96).
That is the "Transacted" logic, and it is V3's `TOTAL_OWNERS`.

So an owner head is a **model estimate in the unit "people on park that day"**. It is not a
list of people, and it comes from a different source and a different method from the guest
rows. That is why:

- **Holiday makers + private lets can be added**: both are counted rows of the same arrival
  table.
- **Owners cannot be added to them.** There is no "total people" metric, on purpose. Show
  booked guests and owner heads **side by side**.

| metric | what | adds up over days? |
|---|---|---|
| `owner_heads_indicative` | Fraser Transacted logic, V3 `TOTAL_OWNERS`. The owner figure. | yes, into owner-head-days (like guest_nights into person-nights) |
| `owner_heads_estimated` | Fraser Estimated logic (van census x ~3.9). **Diagnostics only**, known spikes (S5) | same |
| `park_days_with_owner_data` | park-days that have a Fraser figure | yes |
| `avg_owner_heads_per_day` | `owner_heads_indicative / park_days_with_owner_data` | no, recomputed |
| `owners_ratio` | `owner_heads_indicative / guest_nights`, V3 `OWNERS_RATIO` | no, recomputed (S3) |

Why "indicative": the name keeps the caveat attached to the number wherever it is used, and
stops `owner_heads` looking like a sibling of `guest_nights` that you could add to it.

### Where `× 7` comes from

Fraser stores `heads` as 1/7 of a daily figure. The proof is in the same table: for
**holiday makers**, Fraser's `heads × 7` equals the arrival table's holiday-maker
guest-nights to within 0.5 on 41,855 of 42,409 park-days since 2023 (57.08M in both). So
`heads × 7` is people on park that day, for owners too.

---

## 2. Scenarios

### S1. Owner heads by park for a month

*Owner heads at CT, DE, HA and WM in August 2025, and the average per day.*

```sql
-- old
select park_code, round(sum(total_owners), 1) as owner_heads, count(*) as park_days,
       round(avg(total_owners), 1) as avg_owner_heads_per_day
from HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_FACTS_V3
where park_code in ('CT', 'DE', 'HA', 'WM') and on_park_date between '2025-08-01' and '2025-08-31'
group by park_code order by park_code;

-- new A
select park_code, round(owner_heads_indicative, 1) as owner_heads,
       park_days_with_owner_data as park_days, round(avg_owner_heads_per_day, 1) as avg_owner_heads_per_day
from semantic_view(HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V3
    dimensions park_days.park_code
    metrics owners.owner_heads_indicative, owners.park_days_with_owner_data, owners.avg_owner_heads_per_day
    where park_days.park_code in ('CT', 'DE', 'HA', 'WM') and park_days.stay_month = '2025-08-01')
order by park_code;

-- new B
select park_code, round(agg(owner_heads_indicative), 1) as owner_heads,
       agg(park_days_with_owner_data) as park_days, round(agg(avg_owner_heads_per_day), 1) as avg_owner_heads_per_day
from HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V3
where park_code in ('CT', 'DE', 'HA', 'WM') and stay_month = '2025-08-01'
group by park_code order by park_code;
```

| park_code | owner_heads (owner-head-days) | park_days | avg_owner_heads_per_day |
|---|---|---|---|
| CT | 21,748.5 | 31 | 701.6 |
| DE | 38,792.2 | 31 | 1,251.4 |
| HA | 18,696.7 | 31 | 603.1 |
| WM | 10,618.0 | 31 | 342.5 |

Old, A and B: **match**. Top 5 parks that month (demo): Cleethorpes Beach 52,960, Kent
Coast 50,044, Primrose Valley 44,898, Orchards 43,127, Devon Cliffs 38,792.

What to notice
- Over a month, `owner_heads_indicative` is **owner-head-days**, just as `guest_nights` is
  person-nights. "About 700 owner heads a day at Craig Tara" is the readable number.
- In August every park-day has a Fraser figure, so dividing by `park_days_with_owner_data`
  and by calendar days gives the same answer. S4 shows when it does not.

### S2. Booked guests and owner heads side by side, and why there is no total

*Devon Cliffs (DE), each day of the week starting 4 August 2025.*

```sql
-- old
select on_park_date, total_nights as booked_guests, round(total_owners, 1) as owner_heads,
       round(owners_ratio, 3) as owners_ratio
from HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_FACTS_V3
where park_code = 'DE' and on_park_date between '2025-08-04' and '2025-08-10'
order by on_park_date;

-- new A
select on_park_date, guest_nights as booked_guests, round(owner_heads_indicative, 1) as owner_heads,
       round(owners_ratio, 3) as owners_ratio
from semantic_view(HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V3
    dimensions park_days.on_park_date
    metrics guests.guest_nights, owners.owner_heads_indicative, owners_ratio
    where park_days.park_code = 'DE' and park_days.stay_week = '2025-08-04')
order by on_park_date;

-- new B
select on_park_date, agg(guest_nights) as booked_guests, round(agg(owner_heads_indicative), 1) as owner_heads,
       round(agg(owners_ratio), 3) as owners_ratio
from HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V3
where park_code = 'DE' and stay_week = '2025-08-04'
group by on_park_date order by on_park_date;
```

| on_park_date | booked guests | estimated owner heads | owners_ratio |
|---|---|---|---|
| 2025-08-04 | 5,612 | 1,598.6 | 0.285 |
| 2025-08-05 | 5,613 | 1,621.1 | 0.289 |
| 2025-08-06 | 5,596 | 1,622.7 | 0.290 |
| 2025-08-07 | 5,588 | 1,624.4 | 0.291 |
| 2025-08-08 | 5,365 | 1,527.7 | 0.285 |
| 2025-08-09 | 5,315 | 1,501.9 | 0.283 |
| 2025-08-10 | 5,320 | 1,464.8 | 0.275 |

Old, A and B: **match**. (This is also the view's verified query `guests_and_owners_side_by_side`.)

What to notice
- **Why no total.** 5,612 is a count of guest rows. 1,598.6 is spending turned into vans
  turned into people at a fixed rate. The fraction gives it away: it is an estimate. Adding
  them would give a number ("7,211 people") that is neither counted nor modelled, and the
  error of the estimate would disappear into it. Keep two columns and, if a comparison is wanted, the ratio.
- The view has no metric that adds them, and `AI_SQL_GENERATION` tells Cortex Analyst never
  to add them, even when asked (see README for what it did).

### S2b. Owners next to a guest segment: a metric, not a filter or a group

*Holiday makers and owner heads at CT, FG (Far Grange) and HM (Hafan y Mor), August 2025.*

```sql
-- old
select park_code, sum(total_holiday_makers) as holiday_maker_nights, round(sum(total_owners), 1) as owner_heads
from HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_FACTS_V3
where park_code in ('CT', 'FG', 'HM') and on_park_date between '2025-08-01' and '2025-08-31'
group by park_code order by park_code;

-- new A, RIGHT: the segment metric
select park_code, holiday_maker_nights, round(owner_heads_indicative, 1) as owner_heads
from semantic_view(HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V3
    dimensions park_days.park_code
    metrics guests.holiday_maker_nights, owners.owner_heads_indicative
    where park_days.park_code in ('CT', 'FG', 'HM') and park_days.stay_month = '2025-08-01')
order by park_code;

-- new B, RIGHT
select park_code, agg(holiday_maker_nights) as holiday_maker_nights, round(agg(owner_heads_indicative), 1) as owner_heads
from HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V3
where park_code in ('CT', 'FG', 'HM') and stay_month = '2025-08-01'
group by park_code order by park_code;

-- WRONG 1: a guest filter
select park_code, guest_nights as holiday_maker_nights, round(owner_heads_indicative, 1) as owner_heads
from semantic_view(HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V3
    dimensions park_days.park_code
    metrics guests.guest_nights, owners.owner_heads_indicative
    where park_days.park_code in ('CT', 'FG', 'HM') and park_days.stay_month = '2025-08-01'
      and guests.stay_type = 'Holiday Maker')
order by park_code;

-- WRONG 2: a guest dimension
select park_code, stay_type, guest_nights, round(owner_heads_indicative, 1) as owner_heads
from semantic_view(HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V3
    dimensions park_days.park_code, guests.stay_type
    metrics guests.guest_nights, owners.owner_heads_indicative
    where park_days.park_code in ('CT', 'FG', 'HM') and park_days.stay_month = '2025-08-01')
order by park_code, stay_type;
```

| park_code | holiday_maker_nights | owner_heads |
|---|---|---|
| CT | 113,631 | 21,748.5 |
| FG | 0 | 31,694.8 |
| HM | 114,143 | 22,316.3 |

Old, A and B: **match**.

WRONG 1 returns only CT and HM: **Far Grange and its 31,694.8 owner heads disappear**,
because FG had no holiday makers. WRONG 2 returns:

| park_code | stay_type | guest_nights | owner_heads |
|---|---|---|---|
| CT | Holiday Maker | 113,631 | 21,748.5 |
| CT | Private Let | 17,340 | **21,748.5** |
| FG | Private Let | 297 | 31,694.8 |
| HM | Holiday Maker | 114,143 | 22,316.3 |
| HM | Private Let | 25,822 | **22,316.3** |

What to notice
- Same mechanism as the v1/v2 calendar trap, one step further. A guest filter keeps a
  **spine** day only if it has a matching guest row. Owners hang off the spine, so they lose
  those days too. Over all history, `WHERE stay_type = 'Holiday Maker'` cuts owner heads
  from 18,516,120 to 16,658,483 (-10%) and `park_days_with_owner_data` from 38,475 to 33,747.
- Grouping by a guest dimension is worse: owners have no stay type, so each row gets the
  owner heads of every day that had that stay type. The owner column then sums to twice the
  truth. (All history: Holiday Maker row 16.66M, Private Let row 18.05M, true total 18.52M.)
- The rule: **a query with owner metrics groups and filters on park and date only.** For a
  guest segment, use a segment metric or define one inside METRICS (S6).

### S3. The owners ratio at two grains

*Owners ratio at Haggerston (HA), November 2025.* HA's holiday season ended on 9 November;
after that only a handful of guests stayed, but owners kept coming.

```sql
-- old, RIGHT: recompute from the counts
select round(sum(total_owners) / sum(total_nights), 4) as owners_ratio
from HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_FACTS_V3
where park_code = 'HA' and on_park_date between '2025-11-01' and '2025-11-30';

-- new A
select round(owners_ratio, 4) as owners_ratio
from semantic_view(HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V3
    metrics owners_ratio
    where park_days.park_code = 'HA' and park_days.stay_month = '2025-11-01');

-- new B
select round(agg(owners_ratio), 4) as owners_ratio
from HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V3
where park_code = 'HA' and stay_month = '2025-11-01';

-- WRONG (A, and the same on V3's column): average the daily ratios
select round(avg(owners_ratio), 4) as owners_ratio
from semantic_view(HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V3
    dimensions park_days.on_park_date
    metrics owners_ratio
    where park_days.park_code = 'HA' and park_days.stay_month = '2025-11-01');
```

| query | owners_ratio |
|---|---|
| old: `sum(total_owners) / sum(total_nights)` | **0.3848** |
| new A or B: `owners_ratio` at month grain | **0.3848** (match) |
| `avg()` of daily ratios (old or new) | 68.3485 (wrong) |

By week (the month filter keeps only 1-2 November of the first week):

| stay_week | booked guests | owner heads | owners_ratio |
|---|---|---|---|
| 2025-10-27 | 5,831 | 650 | 0.111 |
| 2025-11-03 | 11,543 | 1,940 | 0.168 |
| 2025-11-10 | 29 | 1,834 | 63.230 |
| 2025-11-17 | 19 | 1,376 | 72.441 |
| 2025-11-24 | 11 | 908 | 82.534 |

What to notice
- `owners_ratio` is owner heads **per booked guest night**. It is not a share (owners are
  not part of guest_nights) and **it can exceed 1**. By park in August 2025 (demo): Far
  Grange 106.7 (31,695 owner heads, 297 guest nights: an owners' park), Kent Coast 0.852,
  LY 0.818, Orchards 0.722. Over all history it is above 1 on 4,099 park-days (max 3,399).
- Averaging daily ratios lets the days with 1 guest and 150 owner heads dominate: 68.3 is
  meaningless. Ask for the ratio at the grain you want.
- "What share of people were owners?" has no honest answer here: owners / (owners +
  guests) would add the two. Give the two numbers and the ratio.
- Two deliberate differences from V3, both counted in `parity_v3.py`: the view gives NULL,
  not 0, when there is no Fraser figure (17,408 park-days), and NULL, not div0's 0, when
  there are owners but no booked guests (1,445 park-days with owner heads > 0).

### S4. Missing Fraser data vs zero

*Craig Tara, 1-8 January 2026, the end of the owners' season.*

```sql
-- old: V3 turns "no Fraser row" into 0
select on_park_date, total_nights as booked_guests, round(total_owners, 1) as owner_heads
from HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_FACTS_V3
where park_code = 'CT' and on_park_date between '2026-01-01' and '2026-01-08'
order by on_park_date;

-- new A: what the view says (park_days keeps every calendar day in the result)
select on_park_date, guest_nights as booked_guests, round(owner_heads_indicative, 1) as owner_heads
from semantic_view(HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V3
    dimensions park_days.on_park_date
    metrics guests.guest_nights, owners.owner_heads_indicative, park_days.park_days
    where park_days.park_code = 'CT' and park_days.on_park_date between '2026-01-01' and '2026-01-08')
order by on_park_date;
-- to get V3's answer: coalesce(guest_nights, 0), coalesce(round(owner_heads_indicative, 1), 0) outside
```

| on_park_date | booked guests (old / new) | owner heads, old | owner heads, new |
|---|---|---|---|
| 2026-01-01 | 1,763 | 882.9 | 882.9 |
| 2026-01-02 | 15 | 451.0 | 451.0 |
| 2026-01-03 | 3 | 123.4 | 123.4 |
| 2026-01-04 | 0 | 19.0 | 19.0 |
| 2026-01-05 | 0 / NULL | 0.0 | **NULL** |
| 2026-01-06 | 0 / NULL | 0.0 | **NULL** |
| 2026-01-07 | 0 / NULL | 0.0 | **NULL** |
| 2026-01-08 | 0 / NULL | 0.0 | **NULL** |

With `coalesce(..., 0)` outside the clause the view gives V3's table exactly (**match**).
Without it: **differs, as designed**.

**S4b. The average for the month depends on which days you divide by:**

```sql
-- old: every calendar day, missing = 0
select round(sum(total_owners), 1) as owner_heads, count(*) as days, round(avg(total_owners), 1) as avg_owner_heads_per_day
from HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_FACTS_V3
where park_code = 'CT' and on_park_date between '2026-01-01' and '2026-01-31';

-- new A, calendar days (= old)
select * from semantic_view(HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V3
    metrics owners.owner_heads_indicative, park_days.park_days,
            owners.owner_heads_indicative / park_days.park_days as owner_heads_per_calendar_day
    where park_days.park_code = 'CT' and park_days.stay_month = '2026-01-01');

-- new A, days with a Fraser figure (the view's metric)
select * from semantic_view(HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V3
    metrics owners.owner_heads_indicative, owners.park_days_with_owner_data, owners.avg_owner_heads_per_day
    where park_days.park_code = 'CT' and park_days.stay_month = '2026-01-01');

-- new B, the same
select agg(owner_heads_indicative), agg(park_days_with_owner_data), agg(avg_owner_heads_per_day)
from HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V3
where park_code = 'CT' and stay_month = '2026-01-01';
```

| query | owner heads | days | per day |
|---|---|---|---|
| old: `avg(total_owners)` | 1,476.3 | 31 | 47.6 |
| new: `owner_heads_indicative / park_days` | 1,476.3 | 31 | 47.6 (match) |
| new: `avg_owner_heads_per_day` (A or B) | 1,476.3 | **4** | **369.1** (differs, by design) |

What to notice
- **What a missing day means.** Measured over all 36 parks Fraser covers: from March to
  October every park has a figure every day. Rows are missing (a) in January and most of
  February 2023, before Fraser starts (20 Feb 2023): *no data*; (b) in the winter closed
  season, as here: Fraser's figure winds down (883, 451, 123, 19) and stops, and the arrival
  table's own owner rows at CT fall from 233 on 1-4 January to 27 over 5-31 January: *park closed to owners*, close to zero
  but not measured; (c) at five parks Fraser has no Transacted figure for at all (CW, GW,
  PC, RV, SV; demo query): *no data*, even though RV and SV had ~39,000 guest nights each in
  August 2025 and CW / GW have Registered owner rows. Fraser does send an explicit 0 on 309
  park-days; those stay 0.
- V3's coalesce makes (a) and (c) look like "no owners", which is wrong. So the view keeps
  NULL, and `avg_owner_heads_per_day` divides by the days that **have** a figure: 369 owner
  heads a day **while the park was open to owners** (4 days). If you want "per calendar day,
  closed days as 0", divide by `park_days` yourself (47.6) and say so. Always report
  `park_days_with_owner_data` next to an owner average.
- `park_days_with_owner_data` is NULL, not 0, for a park with no owner rows in the period
  (the owners table has nothing to count there).
- The same rows-and-spine rules as v1 apply. Measured over all history (55,883 park-days):
  spine dims + owners only: 38,475 rows; + `guest_nights`: 43,896 (the union of owner days
  and guest days); + `park_days`: 55,883, every day.

### S5. Transacted vs Estimated: the spike

*Doniford Bay (DF), November 2023, by week.* V3 builds an Estimated CTE but never selects
it, so "old" here is plain SQL on the Fraser source.

```sql
-- old: the Fraser source directly
select date_trunc('week', c.day_date) as stay_week,
       round(sum(iff(gt.calculation_logic = 'Transacted', h.heads * 7, 0)), 1) as owner_heads_transacted,
       round(sum(iff(gt.calculation_logic = 'Estimated',  h.heads * 7, 0)), 1) as owner_heads_estimated
from haven_store.heads_on_park.fct_heads_on_park h
    join haven_store.heads_on_park.dim_on_park_guest_type gt using (guest_type_xid)
    join haven_store.common.dim_calendar c using (date_xid)
    join haven_store.common.dim_park p using (park_xid)
where gt.guest_type = 'Owners' and gt.calculation_logic in ('Transacted', 'Estimated')
  and p.park_code = 'DF' and c.day_date between '2023-11-01' and '2023-11-30'
group by 1 order by 1;

-- new A
select * from semantic_view(HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V3
    dimensions park_days.stay_week
    metrics owners.owner_heads_indicative, owners.owner_heads_estimated
    where park_days.park_code = 'DF' and park_days.stay_month = '2023-11-01')
order by stay_week;

-- new B
select stay_week, agg(owner_heads_indicative), agg(owner_heads_estimated)
from HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V3
where park_code = 'DF' and stay_month = '2023-11-01'
group by stay_week order by stay_week;
```

| stay_week | transacted (`owner_heads_indicative`) | estimated (`owner_heads_estimated`) |
|---|---|---|
| 2023-10-30 | 872.1 | 206.3 |
| 2023-11-06 | 425.3 | 458.4 |
| 2023-11-13 | 952.4 | 342.7 |
| 2023-11-20 | 867.5 | **188,240.4** |

Old, A and B: **match**. (Fraser has no DF owner rows after 26 November.)

The three known spikes as park-months (demo):

| park | month | transacted | estimated | estimated / transacted |
|---|---|---|---|---|
| DF | Nov 2023 | 3,117 | 189,248 | 60.7 |
| DF | Mar 2026 | 3,961 | 14,407 | 3.6 |
| LS | Nov 2024 | 13,365 | 196,670 | 14.7 |

What to notice
- One week at a park of ~120 owner heads a day shows 188,240 estimated owner-head-days.
  The worst days: DF 25 Nov 2023 38,863 estimated vs 179 transacted; LS 23 Nov 2024 44,241
  vs 1,924; DF 1 Mar 2026 13,158 (the whole March spike is that one day). The cause is
  upstream, in Fraser's `van_count` for the Estimated logic. Not fixed here.
- It is not only these three. Estimated is erratic in November/December at many parks (e.g.
  RP Dec 2023: 142,365 estimated vs 8,188 transacted). Over all park-days the median
  estimated/transacted is 0.42 and the correlation is 0.22. Transacted has no such spikes
  (daily maximum 5,497). This is why Transacted is the figure and Estimated is diagnostics.
- If you do use Estimated, look at it by week or day, as here. A monthly total hides where
  the spike is.

### S6. A metric defined inside METRICS (the cleanest way around the WHERE trap)

*Average private-let arrivals per day at Craig Tara, August 2025.* The view has no
`private_let_arrivals` metric. Define it in the query.

```sql
-- old
select sum(first_day_private_lets) as pl_arrivals, count(*) as park_days,
       round(sum(first_day_private_lets) / count(*), 2) as avg_pl_arrivals_per_day
from HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_FACTS_V3
where park_code = 'CT' and on_park_date between '2025-08-01' and '2025-08-31';

-- new A: the condition lives in the metric
select * from semantic_view(HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V3
    metrics sum(iff(guests.stay_type = 'Private Let' and guests.is_first_day, guests.guest_night, 0)) as pl_arrivals,
            park_days.park_days,
            pl_arrivals / park_days.park_days as avg_pl_arrivals_per_day
    where park_days.park_code = 'CT' and park_days.stay_month = '2025-08-01');

-- new B: an aggregate over the fact, next to AGG(metric)
select sum(iff(stay_type = 'Private Let' and is_first_day, guest_night, 0)) as pl_arrivals,
       agg(park_days) as park_days,
       sum(iff(stay_type = 'Private Let' and is_first_day, guest_night, 0)) / agg(park_days) as avg_pl_arrivals_per_day
from HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V3
where park_code = 'CT' and stay_month = '2025-08-01';

-- WRONG: the same condition as a WHERE
select * from semantic_view(HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V3
    metrics guests.first_day_guests, park_days.park_days
    where park_days.park_code = 'CT' and park_days.stay_month = '2025-08-01'
      and guests.stay_type = 'Private Let' and guests.is_first_day);
```

| query | pl_arrivals | park_days | per day |
|---|---|---|---|
| old | 4,204 | 31 | **135.61** |
| new A (inside METRICS) | 4,204 | 31 | **135.61** (match) |
| new B (ad-hoc aggregate + `AGG`) | 4,204 | 31 | **135.61** (match) |
| WHERE `stay_type = 'Private Let' and is_first_day` | 4,204 | **30** | 140.13 (wrong) |

What to notice
- Inside `METRICS` you can write any aggregate over the view's facts and dimensions,
  give it a name, and use that name in another metric in the same clause. The condition is
  inside the sum, so it filters **rows of the metric**, not **days of the calendar**. No day
  is dropped, and `park_days` stays 31.
- This is the general fix for the v1/v2 WHERE-filter trap: any segment, any combination of
  flags, no new metric in the view needed. `QUERY_EXAMPLES_V1.md` now says so too (it
  previously suggested ad-hoc conditional aggregation only works outside the clause).
- **Flavour B supports it too.** A plain aggregate over a fact (`sum(iff(..., guest_night,
  0))`) sits next to `AGG(park_days)` in one SELECT and gives the same 4,204 / 31 / 135.61.
  What B cannot do is name the ad-hoc aggregate and reuse the name, so you repeat the
  expression.
- It is also how to put a guest segment next to owners without losing owner days (S2b):
  `metrics sum(iff(guests.stay_type = 'Private Let' and guests.is_first_day, guests.guest_night, 0)) as pl_arrivals, owners.owner_heads_indicative, park_days.park_days, owners.park_days_with_owner_data`
  gives 4,204 PL arrivals and 21,749 owner heads over 31 of 31 days (demo query).

---

## 3. Summary: owners

| Question | Use | Not |
|---|---|---|
| Owners on park (a day, a period) | `owner_heads_indicative` (owner-head-days over a period) | `owner_heads_estimated` |
| Average owners per day | `avg_owner_heads_per_day`, with `park_days_with_owner_data` | `owner_heads_indicative / park_days` unless you mean "closed days = 0" |
| "How many people / total population" | `guest_nights` and `owner_heads_indicative` in two columns (per-day averages for a period) | any sum of the two |
| "Share of owners" | `owners_ratio` (owner heads per booked guest night), explained | owners / (owners + guests) |
| Owners next to a guest segment | a segment metric (`holiday_maker_nights`) or one defined inside METRICS | `WHERE stay_type = ...`, or `stay_type` as a dimension |
| Owners ratio for a month | `owners_ratio` at month grain | `avg()` of daily ratios |
| Checking the Estimated logic | `owner_heads_estimated` by day or week | a monthly total |
| A missing Fraser day | NULL, reported as missing | 0 |
