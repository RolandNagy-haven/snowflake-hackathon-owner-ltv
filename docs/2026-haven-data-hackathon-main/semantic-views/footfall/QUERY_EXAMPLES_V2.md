# Querying the footfall semantic view, v2: arrivals, leavers, bookings, ratios

The follow-up to `QUERY_EXAMPLES_V1.md`. Read that first: it explains the two ways to
query a semantic view (flavour A `SEMANTIC_VIEW(...)`, flavour B `AGG()` over the view), the
cheat sheet, and the calendar trap (S6-S8 there). This page covers only what v2 adds.

- **Old:** `HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_FACTS_V3`, one row per park per
  day, one column per count (`FIRST_DAY`, `LEAVERS`, `TOTAL_BOOKINGS_HOLIDAY_MAKERS`,
  `CHILDREN_RATIO`, ...).
- **New:** `HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V2` (definition:
  `FOOTFALL_ARRIVALS_SV_V2.sql`).

Every query below is in `query_examples_v2.sql`. `check_query_examples_v2.py` runs them all
and checks that old and new agree (or, for a documented pitfall, that they disagree). Every
number in this document comes from those queries, run on 2026-09-25 (data up to 2026-09-24).

## 1. What changed in the model

```
guests     one row per booked guest per DAY on park:          dims: stay_type, guest_age, play_pass,
   |       every night of the stay + the departure morning          is_first_day, is_last_full_day,
   |  (park_code, on_park_date)                                     is_departure_day, is_self_catering,
   |                                                                grade_group, grade
park_days  one row per park per calendar day                  (unchanged from v1)
   |  (park_code)
parks      one row per park (DIM_PARK)                        park_name now trimmed, with sample values
```

A 3-night stay arriving Friday gives each guest four rows:

| on_park_date | is_first_day | is_last_full_day | is_departure_day | counts in |
|---|---|---|---|---|
| Fri | true | false | false | `guest_nights`, `first_day_guests` |
| Sat | false | false | false | `guest_nights` |
| Sun | false | true | false | `guest_nights`, `last_full_day_guests` |
| Mon | false | false | **true** | `leavers` only (the morning is not a night) |

The departure row is **not a night**. The fact `guest_night` is 0 on it, and every night
metric (`guest_nights`, `holiday_maker_nights`, `first_day_guests`, ...) sums `guest_night`.
So adding these rows changed no v1 number (`parity_v2.py` checks all v1 metrics on all
55,883 park-days).

New metrics:

| kind | metrics | adds up across days / parks? |
|---|---|---|
| people | `first_day_guests` (arrivals), `last_full_day_guests`, `leavers` (departures) | yes |
| bookings | `bookings_on_park`, `first_day_bookings`, `leaver_bookings` | **no**, they are distinct counts (S3) |
| ratios | `adults_ratio`, `children_ratio`, `infants_ratio`, `play_pass_ratio`, `holiday_makers_ratio`, `private_lets_ratio`, `first_day_ratio`, `leavers_ratio`, `last_full_day_ratio`, `first_day_adults_ratio`, `first_day_children_ratio`, `first_day_infants_ratio` | **no**, they are recomputed at each grain (S4) |

Owners are still not in the view: there are no owner arrivals, leavers or bookings.

---

## 2. Scenarios

### S1. Arrivals vs leavers per day

*Arrivals, leavers and guests on park at Craig Tara (CT), 1-10 August 2025.*

```sql
-- old
select on_park_date, dayname(on_park_date) as day_of_week,
       first_day as arrivals, leavers, last_full_day, total_nights as guest_nights
from HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_FACTS_V3
where park_code = 'CT' and on_park_date between '2025-08-01' and '2025-08-10'
order by on_park_date;

-- new A
select * from semantic_view(HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V2
    dimensions park_days.on_park_date, park_days.day_of_week
    metrics guests.first_day_guests, guests.leavers, guests.last_full_day_guests, guests.guest_nights
    where park_days.park_code = 'CT'
      and park_days.on_park_date between '2025-08-01' and '2025-08-10')
order by on_park_date;

-- new B
select on_park_date, day_of_week, agg(first_day_guests) as arrivals, agg(leavers) as leavers,
       agg(last_full_day_guests) as last_full_day, agg(guest_nights) as guest_nights
from HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V2
where park_code = 'CT' and on_park_date between '2025-08-01' and '2025-08-10'
group by on_park_date, day_of_week order by on_park_date;
```

| on_park_date | day | arrivals | leavers | last_full_day | guest_nights |
|---|---|---|---|---|---|
| 2025-08-01 | Fri | 3,163 | 3,350 | 185 | 4,341 |
| 2025-08-02 | Sat | 167 | 187 | 33 | 4,323 |
| 2025-08-03 | Sun | 19 | 33 | 3,517 | 4,309 |
| 2025-08-04 | Mon | 3,750 | 3,526 | 12 | 4,542 |
| 2025-08-05 | Tue | 129 | 12 | 24 | 4,659 |
| 2025-08-06 | Wed | 7 | 24 | 13 | 4,642 |
| 2025-08-07 | Thu | 10 | 17 | 3,466 | 4,639 |
| 2025-08-08 | Fri | 3,489 | 3,471 | 67 | 4,662 |
| 2025-08-09 | Sat | 156 | 71 | 26 | 4,751 |
| 2025-08-10 | Sun | 17 | 26 | 3,958 | 4,742 |

Old, A and B: **match**.

The new view can split leavers too, which V3 cannot (V3 has leavers by stay type only).
Arrivals and leavers on Monday 4 August by stay type and age:

```sql
select * from semantic_view(HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V2
    dimensions guests.stay_type, guests.guest_age
    metrics guests.first_day_guests, guests.leavers
    where park_days.park_code = 'CT' and park_days.on_park_date = '2025-08-04')
order by stay_type, guest_age;
```

| stay_type | guest_age | first_day_guests | leavers |
|---|---|---|---|
| Holiday Maker | Adult | 1,699 | 1,796 |
| Holiday Maker | Child | 1,160 | 1,059 |
| Holiday Maker | Infant | 268 | 240 |
| Private Let | Adult | 351 | 267 |
| Private Let | Child | 220 | 134 |
| Private Let | Infant | 52 | 30 |

(The rows add up to 3,750 arrivals and 3,526 leavers, as in the table above.)

What to notice
- Changeover days are Monday and Friday: about 3,500 people leave in the morning and a
  similar number arrive that afternoon.
- Leavers on a day are the previous day's `last_full_day` plus same-day stays: Monday's
  3,526 leavers are Sunday's 3,517 last-night guests plus 9 guests with no night on
  Sunday (checked on the base view). A same-day stay (arrival = departure) has a departure
  row but no night, so it is a leaver and never a first day, exactly as in V3.
- `leavers` are **not** in `guest_nights`: on 4 August, 4,542 guests slept on park, and
  3,526 other guests had left that morning.

### S2. Bookings vs guests per day

*Bookings on park and guests per booking at Craig Tara, 4-10 August 2025.*

V3's `TOTAL_BOOKINGS` includes owner bookings. v2 has no owners, so the comparable V3
number is `TOTAL_BOOKINGS_HOLIDAY_MAKERS + TOTAL_BOOKINGS_PRIVATE_LETS`.

```sql
-- old
select on_park_date,
       total_bookings_holiday_makers + total_bookings_private_lets as bookings_on_park,
       total_nights as guest_nights,
       round(total_nights / (total_bookings_holiday_makers + total_bookings_private_lets), 2) as guests_per_booking
from HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_FACTS_V3
where park_code = 'CT' and on_park_date between '2025-08-04' and '2025-08-10'
order by on_park_date;

-- new A: a ratio of two metrics, defined inline
select on_park_date, bookings_on_park, guest_nights, round(guests_per_booking, 2) as guests_per_booking
from semantic_view(HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V2
    dimensions park_days.on_park_date
    metrics guests.bookings_on_park, guests.guest_nights,
            guests.guest_nights / guests.bookings_on_park as guests_per_booking
    where park_days.park_code = 'CT'
      and park_days.on_park_date between '2025-08-04' and '2025-08-10')
order by on_park_date;

-- new B
select on_park_date, agg(bookings_on_park) as bookings_on_park, agg(guest_nights) as guest_nights,
       round(agg(guest_nights) / agg(bookings_on_park), 2) as guests_per_booking
from HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V2
where park_code = 'CT' and on_park_date between '2025-08-04' and '2025-08-10'
group by on_park_date order by on_park_date;
```

| on_park_date | bookings_on_park | guest_nights | guests_per_booking |
|---|---|---|---|
| 2025-08-04 | 990 | 4,542 | 4.59 |
| 2025-08-05 | 1,013 | 4,659 | 4.60 |
| 2025-08-06 | 1,010 | 4,642 | 4.60 |
| 2025-08-07 | 1,008 | 4,639 | 4.60 |
| 2025-08-08 | 1,012 | 4,662 | 4.61 |
| 2025-08-09 | 1,033 | 4,751 | 4.60 |
| 2025-08-10 | 1,028 | 4,742 | 4.61 |

Old, A and B: **match**.

What to notice
- `bookings_on_park` is `count(distinct booking_id)` over the night rows of that park-day.
  About 1,000 parties of 4.6 people.
- On one day, bookings and guests behave alike. S3 shows where they stop behaving alike.

### S3. Why daily booking counts don't add up over a week

*How many bookings were on park at Craig Tara in the week of 4-10 August 2025?*

```sql
-- old: the only thing V3 can do is add up its daily columns
select sum(total_bookings_holiday_makers + total_bookings_private_lets)                   as bookings_on_park,
       sum(first_day_booking_count_holiday_makers + first_day_booking_count_private_lets) as first_day_bookings,
       sum(leavers_booking_count_holiday_makers + leavers_booking_count_private_lets)     as leaver_bookings
from HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_FACTS_V3
where park_code = 'CT' and on_park_date between '2025-08-04' and '2025-08-10';

-- new A, the same mistake: sum the daily rows outside the clause
select sum(bookings_on_park) as bookings_on_park, sum(first_day_bookings) as first_day_bookings,
       sum(leaver_bookings) as leaver_bookings
from semantic_view(HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V2
    dimensions park_days.on_park_date
    metrics guests.bookings_on_park, guests.first_day_bookings, guests.leaver_bookings
    where park_days.park_code = 'CT'
      and park_days.on_park_date between '2025-08-04' and '2025-08-10');

-- new A, RIGHT: ask for the week; the view recounts distinct bookings
select * from semantic_view(HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V2
    metrics guests.bookings_on_park, guests.first_day_bookings, guests.leaver_bookings
    where park_days.park_code = 'CT'
      and park_days.on_park_date between '2025-08-04' and '2025-08-10');

-- new B, RIGHT
select agg(bookings_on_park) as bookings_on_park, agg(first_day_bookings) as first_day_bookings,
       agg(leaver_bookings) as leaver_bookings
from HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V2
where park_code = 'CT' and on_park_date between '2025-08-04' and '2025-08-10';
```

| query | bookings_on_park | first_day_bookings | leaver_bookings |
|---|---|---|---|
| old: sum of V3's daily columns | 7,094 | 1,648 | 1,569 |
| new A: sum of the daily rows | 7,094 | 1,648 | 1,569 |
| **new A or B: the week as one grain** | **1,826** | 1,648 | 1,569 |

Sum of daily = old (**match**). Weekly recount: **differs, as expected**. An independent
plain-SQL count on the base view (`count(distinct booking_id)` over the week's rows of
`FOOTFALL_SV_GUEST_DAYS_V2`, block `S3b`) gives the same 1,826, 1,648 and 1,569.

What to notice
- 1,826 different bookings stayed at least one night that week. A 7-night booking is on
  park every day, so the sum of daily counts counts it 7 times. 7,094 is "booking-nights",
  not bookings.
- V3 cannot answer "bookings in the week" at all: it only has daily distinct counts, and
  a distinct count cannot be rebuilt by adding.
- `first_day_bookings` and `leaver_bookings` *do* add up over days, because a booking has
  exactly one arrival day and one departure day (checked: none of the 4,389,639 booked
  stays since 2023 has two arrival dates, two departure dates or two parks). That is a
  property of the data, not of distinct counts, so still ask for the grain you need.
- Summing across stay types or `is_self_catering` is also safe (every booking has
  exactly one of each; parity_v2.py checks it on every park-day). Summing across
  `guest_age` is **not**: a family booking has adults and children.

### S4. A ratio at two grains: recomputed, not averaged

*Holiday-maker share of guest nights at Haggerston (HA), November 2025.*

In November 2025 HA had holiday makers until the 9th and a handful of private-let guests
after that. So the daily ratio is about 0.95 for 9 days and 0 for 21 days.

```sql
-- old, RIGHT: recompute from the counts
select round(sum(total_holiday_makers) / sum(total_nights), 4) as holiday_makers_ratio
from HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_FACTS_V3
where park_code = 'HA' and on_park_date between '2025-11-01' and '2025-11-30';

-- new A: ask for the ratio at month grain
select round(holiday_makers_ratio, 4) as holiday_makers_ratio
from semantic_view(HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V2
    metrics guests.holiday_makers_ratio
    where park_days.park_code = 'HA' and park_days.stay_month = '2025-11-01');

-- new B
select round(agg(holiday_makers_ratio), 4) as holiday_makers_ratio
from HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V2
where park_code = 'HA' and stay_month = '2025-11-01';

-- WRONG (A): average the daily ratios
select round(avg(holiday_makers_ratio), 4) as holiday_makers_ratio
from semantic_view(HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V2
    dimensions park_days.on_park_date
    metrics guests.holiday_makers_ratio
    where park_days.park_code = 'HA' and park_days.stay_month = '2025-11-01');

-- WRONG (old): the same on V3's ratio column
select round(avg(holiday_makers_ratio), 4) as holiday_makers_ratio
from HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_FACTS_V3
where park_code = 'HA' and on_park_date between '2025-11-01' and '2025-11-30';
```

| query | holiday_makers_ratio |
|---|---|
| old: `sum(total_holiday_makers) / sum(total_nights)` | **0.9620** |
| new A or B: `holiday_makers_ratio` at month grain | **0.9620** (match) |
| `avg()` of the daily ratios (old or new) | 0.2914 (wrong) |

The same metric grouped by week is recomputed per week (the `stay_month` filter keeps
only 1-2 November of the week starting 27 October):

| stay_week | guest_nights | holiday_maker_nights | holiday_makers_ratio |
|---|---|---|---|
| 2025-10-27 | 5,831 | 5,562 | 0.9539 |
| 2025-11-03 | 11,543 | 11,208 | 0.9710 |
| 2025-11-10 | 29 | 0 | 0.0000 |
| 2025-11-17 | 19 | 0 | 0.0000 |
| 2025-11-24 | 11 | 0 | 0.0000 |

What to notice
- A ratio metric is `div0(numerator, guest_nights)` evaluated **after** grouping. At month
  grain it divides the month's holiday-maker nights by the month's guest nights. 96% of
  the guest nights in November were holiday makers.
- The average of daily ratios gives each day the same weight: a day with 1 guest counts
  as much as a day with 2,260. 0.29 answers no useful question.
- Daily, V3's `HOLIDAY_MAKERS_RATIO` and the view's `holiday_makers_ratio` are identical
  on every park-day (parity_v2.py). Only the aggregation differs.
- `first_day_adults_ratio` and the other first-day ratios divide by **all** guest nights,
  as in V3, not by arrivals.

### S5. Self-catering bookings

*Arriving holiday-maker bookings, and how many were self-catering, at CT, HA and WM in
August 2025.*

Self-catering = Holiday Maker not staying on a touring pitch. v2 reads it from the
accommodation grade on the arrival row itself (`grade_group` other than Touring). V3
gets the same answer a longer way, via the package type on today's booking snapshot
(see "What to notice").

```sql
-- old
select park_code,
       sum(first_day_booking_count_holiday_makers)               as hm_arriving_bookings,
       sum(first_day_booking_count_holiday_makers_self_catering) as self_catering_arriving_bookings
from HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_FACTS_V3
where park_code in ('CT', 'HA', 'WM') and on_park_date between '2025-08-01' and '2025-08-31'
group by park_code order by park_code;

-- new A: group by the flag, pivot outside
select park_code,
       sum(first_day_bookings)                           as hm_arriving_bookings,
       sum(iff(is_self_catering, first_day_bookings, 0)) as self_catering_arriving_bookings
from semantic_view(HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V2
    dimensions park_days.park_code, guests.is_self_catering
    metrics guests.first_day_bookings
    where park_days.park_code in ('CT', 'HA', 'WM')
      and park_days.stay_month = '2025-08-01'
      and guests.stay_type = 'Holiday Maker')
group by park_code order by park_code;

-- new B: the same in a CTE
with hm as (
    select park_code, is_self_catering, agg(first_day_bookings) as first_day_bookings
    from HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V2
    where park_code in ('CT', 'HA', 'WM') and stay_month = '2025-08-01'
      and stay_type = 'Holiday Maker'
    group by park_code, is_self_catering)
select park_code, sum(first_day_bookings) as hm_arriving_bookings,
       sum(iff(is_self_catering, first_day_bookings, 0)) as self_catering_arriving_bookings
from hm group by park_code order by park_code;

-- new A, the question as usually asked: filter to self-catering
select park_code, first_day_bookings
from semantic_view(HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V2
    dimensions park_days.park_code
    metrics guests.first_day_bookings
    where park_days.park_code in ('CT', 'HA', 'WM')
      and park_days.stay_month = '2025-08-01'
      and guests.is_self_catering)
order by park_code;
```

| park_code | hm_arriving_bookings | self_catering_arriving_bookings |
|---|---|---|
| CT | 5,601 | 5,601 |
| HA | 5,232 | 4,583 |
| WM | 2,869 | 2,869 |

Old, A and B: **match**. The filtered query returns the last column (5,601 / 4,583 / 2,869).

What is not self-catering? HA's arriving holiday-maker bookings in August 2025 by
`grade_group`:

| grade_group | first_day_bookings |
|---|---|
| Bronze | 1,302 |
| Silver | 1,205 |
| Dog Grades | 666 |
| Touring | 649 |
| Saver | 557 |
| Signature | 418 |
| Gold | 232 |
| Views, Lodges & Select | 125 |
| Accessible | 78 |

5,232 - 649 Touring = 4,583 self-catering. CT and WM had no touring bookings that month.

What to notice
- For a **total** (not a per-day average), a filter on a guest dimension such as
  `is_self_catering` is fine.
- Where self-catering comes from: V3 joins `HOLIDAY.FCT_HOLIDAY_BOOKINGS` on **today's**
  snapshot to get the package type (TOURING or not), matching on a number parsed out of
  the booking id. The arrival row already carries the accommodation grade, and
  `grade_group = 'Touring'` agrees with `package_type = 'TOURING'` on every one of the
  3.57 million holiday-maker bookings since 2023. So v2 uses the grade: one small lookup
  instead of a large snapshot join, and past days can no longer shift when today's snapshot
  changes. You also get the grade itself (Bronze, Silver, Gold, Touring, ...) as a
  dimension for free.

### S6. The day-flag filter trap, in one week

*Average arrivals per day at Haggerston (HA), 6-12 November 2025.*

V3 for that week (from S4's month): arrivals were 15, 2,104, 38, 1, 0, 0, 0. That is
2,158 arrivals over 7 days = **308.29 per day**.

```sql
-- old
select sum(first_day) as arrivals, count(*) as park_days,
       round(sum(first_day) / count(*), 2) as avg_arrivals_per_day
from HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_FACTS_V3
where park_code = 'HA' and on_park_date between '2025-11-06' and '2025-11-12';

-- new, RIGHT (A): the metric first_day_guests, divided by the unfiltered day count
select first_day_guests, park_days, round(avg_arrivals_per_day, 2) as avg_arrivals_per_day
from semantic_view(HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V2
    metrics guests.first_day_guests, park_days.park_days,
            guests.first_day_guests / park_days.park_days as avg_arrivals_per_day
    where park_days.park_code = 'HA'
      and park_days.on_park_date between '2025-11-06' and '2025-11-12');

-- new, RIGHT (B)
select agg(first_day_guests) as arrivals, agg(park_days) as park_days,
       round(agg(first_day_guests) / agg(park_days), 2) as avg_arrivals_per_day
from HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V2
where park_code = 'HA' and on_park_date between '2025-11-06' and '2025-11-12';

-- new, WRONG (A): filter to first days, then use the general daily average
select guest_nights, park_days, round(avg_guests_per_day, 2) as avg_guests_per_day
from semantic_view(HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V2
    metrics guests.guest_nights, park_days.park_days, avg_guests_per_day
    where park_days.park_code = 'HA'
      and park_days.on_park_date between '2025-11-06' and '2025-11-12'
      and guests.is_first_day);

-- new, WRONG (B)
select agg(first_day_guests) as arrivals, agg(park_days) as park_days,
       round(agg(first_day_guests) / agg(park_days), 2) as avg_arrivals_per_day
from HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V2
where park_code = 'HA' and on_park_date between '2025-11-06' and '2025-11-12'
  and is_first_day;
```

| query | arrivals | park_days | per day |
|---|---|---|---|
| old | 2,158 | 7 | **308.29** |
| new A or B: `first_day_guests / park_days` | 2,158 | 7 | **308.29** (match) |
| new A or B: `WHERE is_first_day` | 2,158 | **4** | **539.50** (wrong) |

What to notice
- Same mechanism as v1's S8. `is_first_day` exists only on guest rows, so
  `WHERE is_first_day` keeps a calendar day only if somebody arrived that day. 10-12
  November had no arrivals, so 7 days become 4. The total (2,158) is right, and anything
  divided by days is wrong.
- The rule is the same as for stay type: **for per-day averages, use a metric and divide
  by `park_days`; don't filter on a guest dimension.** For combinations that have no metric,
  define one inline:
  `metrics sum(iff(guests.stay_type = 'Holiday Maker' and guests.is_first_day, guests.guest_night, 0)) as hm_arrivals, park_days.park_days, hm_arrivals / park_days.park_days as avg_hm_arrivals_per_day`.
- A second trap with the flags: `guest_nights` counts nights only, so with
  `WHERE is_departure_day` it is **0**. For the same week that query returns
  `guest_nights = 0`, `leavers = 3,397`, `park_days = 5`. Count departures with `leavers`.

---

## 3. Summary: which metric for which question

| Question | Use | Not |
|---|---|---|
| Arrivals (check-ins) | `first_day_guests` | `WHERE is_first_day` + `guest_nights` for averages |
| Departures (check-outs) | `leavers` | `guest_nights` with `WHERE is_departure_day` (it is 0) |
| Guests on their last night | `last_full_day_guests` | |
| Average arrivals / leavers per day | `first_day_guests / park_days`, `leavers / park_days` | `WHERE is_first_day` (drops days) |
| Per-day average for a segment of arrivals | inline `sum(iff(... and guests.is_first_day, guests.guest_night, 0))` / `park_days` | a WHERE on the segment |
| Bookings over a week or month | `bookings_on_park` at that grain | the sum of daily booking counts |
| Self-catering bookings | a booking metric with `WHERE guests.is_self_catering` | |
| A share (children, play pass, holiday makers, ...) | the `*_ratio` metric at the grain you want | `avg()` of daily ratios |
| Guests per booking | `guest_nights / bookings_on_park` inline | |
