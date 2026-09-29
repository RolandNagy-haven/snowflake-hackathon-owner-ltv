-- =====================================================================================
-- query_examples_v3.sql - v3 questions (owners from Fraser, next to booked guests) asked
-- three ways
--
--   old = plain SQL on the wide table HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_FACTS_V3
--         (or, where V3 has no such column, plain SQL on the Fraser source itself)
--   A   = semantic view, SEMANTIC_VIEW( ... DIMENSIONS ... METRICS ... WHERE ... ) clause
--   B   = semantic view named directly in FROM, metrics wrapped in AGG(), GROUP BY dims
--
-- Read alongside QUERY_EXAMPLES_V3.md. Checked by check_query_examples_v3.py, which reads
-- the "-- [S<n>[b].<tag>]" markers below:
--   old / A / B / A2 / B2 ...  must return the same rows as [S<n>.old]
--   *_wrong, *_differs         must return DIFFERENT rows (a pitfall, or a deliberately
--                              different answer)
--   *_demo                     only has to run
-- Each query ends with a semicolon at the end of a line.
--
-- Owner heads are floats (Fraser's heads x 7), so every owner number is rounded to 1
-- decimal before it is compared.
-- =====================================================================================


-- -------------------------------------------------------------------------------------
-- S1. Owner heads by park for a month: CT, DE, HA, WM, August 2025
-- -------------------------------------------------------------------------------------
-- [S1.old]
select park_code,
       round(sum(total_owners), 1) as owner_heads,
       count(*)                    as park_days,
       round(avg(total_owners), 1) as avg_owner_heads_per_day
from HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_FACTS_V3
where park_code in ('CT', 'DE', 'HA', 'WM')
  and on_park_date between '2025-08-01' and '2025-08-31'
group by park_code
order by park_code;

-- [S1.A]
select park_code,
       round(owner_heads_indicative, 1)  as owner_heads,
       park_days_with_owner_data         as park_days,
       round(avg_owner_heads_per_day, 1) as avg_owner_heads_per_day
from semantic_view(
    HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V3
    dimensions park_days.park_code
    metrics owners.owner_heads_indicative, owners.park_days_with_owner_data, owners.avg_owner_heads_per_day
    where park_days.park_code in ('CT', 'DE', 'HA', 'WM')
      and park_days.stay_month = '2025-08-01'
)
order by park_code;

-- [S1.B]
select park_code,
       round(agg(owner_heads_indicative), 1)  as owner_heads,
       agg(park_days_with_owner_data)         as park_days,
       round(agg(avg_owner_heads_per_day), 1) as avg_owner_heads_per_day
from HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V3
where park_code in ('CT', 'DE', 'HA', 'WM')
  and stay_month = '2025-08-01'
group by park_code
order by park_code;

-- [S1.A_top_parks_demo]  the parks with most owner heads, with names
select park_name, round(owner_heads_indicative) as owner_heads, round(avg_owner_heads_per_day) as avg_per_day
from semantic_view(
    HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V3
    dimensions parks.park_name
    metrics owners.owner_heads_indicative, owners.avg_owner_heads_per_day
    where park_days.stay_month = '2025-08-01'
)
order by owner_heads desc nulls last
limit 5;


-- -------------------------------------------------------------------------------------
-- S2. Booked guests and owner heads side by side, per day: Devon Cliffs, 4-10 Aug 2025
--     Two columns, never one total.
-- -------------------------------------------------------------------------------------
-- [S2.old]
select on_park_date, total_nights as booked_guests,
       round(total_owners, 1) as owner_heads, round(owners_ratio, 3) as owners_ratio
from HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_FACTS_V3
where park_code = 'DE'
  and on_park_date between '2025-08-04' and '2025-08-10'
order by on_park_date;

-- [S2.A]
select on_park_date, guest_nights as booked_guests,
       round(owner_heads_indicative, 1) as owner_heads, round(owners_ratio, 3) as owners_ratio
from semantic_view(
    HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V3
    dimensions park_days.on_park_date
    metrics guests.guest_nights, owners.owner_heads_indicative, owners_ratio
    where park_days.park_code = 'DE'
      and park_days.stay_week = '2025-08-04'
)
order by on_park_date;

-- [S2.B]
select on_park_date, agg(guest_nights) as booked_guests,
       round(agg(owner_heads_indicative), 1) as owner_heads, round(agg(owners_ratio), 3) as owners_ratio
from HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V3
where park_code = 'DE'
  and stay_week = '2025-08-04'
group by on_park_date
order by on_park_date;

-- -------------------------------------------------------------------------------------
-- S2b. Owners next to a guest SEGMENT: use the segment metric, not a guest filter or a
--      guest dimension. CT, FG, HM, August 2025.
-- -------------------------------------------------------------------------------------
-- [S2b.old]
select park_code, sum(total_holiday_makers) as holiday_maker_nights, round(sum(total_owners), 1) as owner_heads
from HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_FACTS_V3
where park_code in ('CT', 'FG', 'HM')
  and on_park_date between '2025-08-01' and '2025-08-31'
group by park_code
order by park_code;

-- [S2b.A]  RIGHT: the segment metric holiday_maker_nights; owners untouched
select park_code, holiday_maker_nights, round(owner_heads_indicative, 1) as owner_heads
from semantic_view(
    HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V3
    dimensions park_days.park_code
    metrics guests.holiday_maker_nights, owners.owner_heads_indicative
    where park_days.park_code in ('CT', 'FG', 'HM')
      and park_days.stay_month = '2025-08-01'
)
order by park_code;

-- [S2b.B]
select park_code, agg(holiday_maker_nights) as holiday_maker_nights,
       round(agg(owner_heads_indicative), 1) as owner_heads
from HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V3
where park_code in ('CT', 'FG', 'HM')
  and stay_month = '2025-08-01'
group by park_code
order by park_code;

-- [S2b.A_filter_wrong]  WRONG: a guest filter also removes the owners of every park-day
--                       without holiday makers (FG, an owners' park, disappears)
select park_code, guest_nights as holiday_maker_nights, round(owner_heads_indicative, 1) as owner_heads
from semantic_view(
    HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V3
    dimensions park_days.park_code
    metrics guests.guest_nights, owners.owner_heads_indicative
    where park_days.park_code in ('CT', 'FG', 'HM')
      and park_days.stay_month = '2025-08-01'
      and guests.stay_type = 'Holiday Maker'
)
order by park_code;

-- [S2b.A_by_stay_type_wrong]  WRONG: grouping owners by a guest dimension repeats the
--                             park's owner heads on every stay-type row
select park_code, stay_type, guest_nights, round(owner_heads_indicative, 1) as owner_heads
from semantic_view(
    HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V3
    dimensions park_days.park_code, guests.stay_type
    metrics guests.guest_nights, owners.owner_heads_indicative
    where park_days.park_code in ('CT', 'FG', 'HM')
      and park_days.stay_month = '2025-08-01'
)
order by park_code, stay_type;


-- -------------------------------------------------------------------------------------
-- S3. The owners ratio at two grains: Haggerston (HA), November 2025
-- -------------------------------------------------------------------------------------
-- [S3.old]  RIGHT with V3: recompute from the counts
select round(sum(total_owners) / sum(total_nights), 4) as owners_ratio
from HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_FACTS_V3
where park_code = 'HA'
  and on_park_date between '2025-11-01' and '2025-11-30';

-- [S3.A]
select round(owners_ratio, 4) as owners_ratio
from semantic_view(
    HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V3
    metrics owners_ratio
    where park_days.park_code = 'HA'
      and park_days.stay_month = '2025-11-01'
);

-- [S3.B]
select round(agg(owners_ratio), 4) as owners_ratio
from HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V3
where park_code = 'HA'
  and stay_month = '2025-11-01';

-- [S3.A_avg_of_daily_wrong]  WRONG: the average of the daily ratios
select round(avg(owners_ratio), 4) as owners_ratio
from semantic_view(
    HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V3
    dimensions park_days.on_park_date
    metrics owners_ratio
    where park_days.park_code = 'HA'
      and park_days.stay_month = '2025-11-01'
);

-- [S3.old_avg_of_daily_wrong]  the same mistake on V3's ratio column
select round(avg(owners_ratio), 4) as owners_ratio
from HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_FACTS_V3
where park_code = 'HA'
  and on_park_date between '2025-11-01' and '2025-11-30';

-- [S3.A_weekly_demo]  the ratio by week, recomputed per week, with its two parts
select stay_week, guest_nights, round(owner_heads_indicative) as owner_heads, round(owners_ratio, 3) as owners_ratio
from semantic_view(
    HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V3
    dimensions park_days.stay_week
    metrics guests.guest_nights, owners.owner_heads_indicative, owners_ratio
    where park_days.park_code = 'HA'
      and park_days.stay_month = '2025-11-01'
)
order by stay_week;

-- [S3.A_all_parks_demo]  the ratio by park for the same month: it can exceed 1
select park_code, guest_nights, round(owner_heads_indicative) as owner_heads, round(owners_ratio, 3) as owners_ratio
from semantic_view(
    HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V3
    dimensions park_days.park_code
    metrics guests.guest_nights, owners.owner_heads_indicative, owners_ratio
    where park_days.stay_month = '2025-08-01'
)
order by owners_ratio desc nulls last
limit 4;


-- -------------------------------------------------------------------------------------
-- S4. Missing Fraser data vs zero: Craig Tara, early January 2026 (owners' season ends)
-- -------------------------------------------------------------------------------------
-- [S4.old]  V3 turns "no Fraser row" into 0
select on_park_date, total_nights as booked_guests, round(total_owners, 1) as owner_heads
from HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_FACTS_V3
where park_code = 'CT'
  and on_park_date between '2026-01-01' and '2026-01-08'
order by on_park_date;

-- [S4.A_v3_style]  the same answer from the view: park_days keeps every day, coalesce outside
select on_park_date, coalesce(guest_nights, 0) as booked_guests, coalesce(round(owner_heads_indicative, 1), 0) as owner_heads
from semantic_view(
    HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V3
    dimensions park_days.on_park_date
    metrics guests.guest_nights, owners.owner_heads_indicative, park_days.park_days
    where park_days.park_code = 'CT'
      and park_days.on_park_date between '2026-01-01' and '2026-01-08'
)
order by on_park_date;

-- [S4.A_null_differs]  what the view says by itself: NULL where Fraser has no figure
select on_park_date, guest_nights as booked_guests, round(owner_heads_indicative, 1) as owner_heads
from semantic_view(
    HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V3
    dimensions park_days.on_park_date
    metrics guests.guest_nights, owners.owner_heads_indicative, park_days.park_days
    where park_days.park_code = 'CT'
      and park_days.on_park_date between '2026-01-01' and '2026-01-08'
)
order by on_park_date;

-- -------------------------------------------------------------------------------------
-- S4b. Average owner heads per day in January 2026 at CT: which days do you divide by?
-- -------------------------------------------------------------------------------------
-- [S4b.old]  V3: every calendar day, missing = 0
select round(sum(total_owners), 1) as owner_heads, count(*) as days, round(avg(total_owners), 1) as avg_owner_heads_per_day
from HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_FACTS_V3
where park_code = 'CT'
  and on_park_date between '2026-01-01' and '2026-01-31';

-- [S4b.A_calendar]  the same in the view: divide by park_days (all calendar days)
select round(owner_heads_indicative, 1) as owner_heads, park_days as days,
       round(owner_heads_per_calendar_day, 1) as avg_owner_heads_per_day
from semantic_view(
    HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V3
    metrics owners.owner_heads_indicative, park_days.park_days,
            owners.owner_heads_indicative / park_days.park_days as owner_heads_per_calendar_day
    where park_days.park_code = 'CT'
      and park_days.stay_month = '2026-01-01'
);

-- [S4b.A_with_data_differs]  the view's metric: divide by the days WITH a Fraser figure
select round(owner_heads_indicative, 1) as owner_heads, park_days_with_owner_data as days,
       round(avg_owner_heads_per_day, 1) as avg_owner_heads_per_day
from semantic_view(
    HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V3
    metrics owners.owner_heads_indicative, owners.park_days_with_owner_data, owners.avg_owner_heads_per_day
    where park_days.park_code = 'CT'
      and park_days.stay_month = '2026-01-01'
);

-- [S4b.B_with_data_differs]
select round(agg(owner_heads_indicative), 1) as owner_heads, agg(park_days_with_owner_data) as days,
       round(agg(avg_owner_heads_per_day), 1) as avg_owner_heads_per_day
from HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V3
where park_code = 'CT'
  and stay_month = '2026-01-01';

-- [S4b.A_uncovered_parks_demo]  parks Fraser does not cover: V3 says 0, the view says NULL
select park_code, guest_nights, owner_heads_indicative, park_days_with_owner_data, park_days
from semantic_view(
    HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V3
    dimensions park_days.park_code
    metrics guests.guest_nights, owners.owner_heads_indicative, owners.park_days_with_owner_data, park_days.park_days
    where park_days.park_code in ('CW', 'GW', 'PC', 'RV', 'SV')
      and park_days.stay_month = '2025-08-01'
)
order by park_code;


-- -------------------------------------------------------------------------------------
-- S5. Transacted vs Estimated: the Doniford Bay (DF) spike, November 2023, by week
--     V3 has no estimated column, so "old" is plain SQL on the Fraser source.
-- -------------------------------------------------------------------------------------
-- [S5.old]
select date_trunc('week', c.day_date) as stay_week,
       round(sum(iff(gt.calculation_logic = 'Transacted', h.heads * 7, 0)), 1) as owner_heads_transacted,
       round(sum(iff(gt.calculation_logic = 'Estimated',  h.heads * 7, 0)), 1) as owner_heads_estimated
from haven_store.heads_on_park.fct_heads_on_park h
    join haven_store.heads_on_park.dim_on_park_guest_type gt using (guest_type_xid)
    join haven_store.common.dim_calendar c using (date_xid)
    join haven_store.common.dim_park p using (park_xid)
where gt.guest_type = 'Owners'
  and gt.calculation_logic in ('Transacted', 'Estimated')   -- other logics have rows on days these don't
  and p.park_code = 'DF'
  and c.day_date between '2023-11-01' and '2023-11-30'
group by 1
order by 1;

-- [S5.A]
select stay_week, round(owner_heads_indicative, 1) as owner_heads_transacted,
       round(owner_heads_estimated, 1) as owner_heads_estimated
from semantic_view(
    HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V3
    dimensions park_days.stay_week
    metrics owners.owner_heads_indicative, owners.owner_heads_estimated
    where park_days.park_code = 'DF'
      and park_days.stay_month = '2023-11-01'
)
order by stay_week;

-- [S5.B]
select stay_week, round(agg(owner_heads_indicative), 1) as owner_heads_transacted,
       round(agg(owner_heads_estimated), 1) as owner_heads_estimated
from HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V3
where park_code = 'DF'
  and stay_month = '2023-11-01'
group by stay_week
order by stay_week;

-- [S5.A_three_spikes_demo]  the three known spikes as park-months
select park_code, stay_month, round(owner_heads_indicative) as transacted, round(owner_heads_estimated) as estimated,
       round(owner_heads_estimated / owner_heads_indicative, 1) as estimated_over_transacted
from semantic_view(
    HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V3
    dimensions park_days.park_code, park_days.stay_month
    metrics owners.owner_heads_indicative, owners.owner_heads_estimated
    where (park_days.park_code = 'DF' and park_days.stay_month in ('2023-11-01', '2026-03-01'))
       or (park_days.park_code = 'LS' and park_days.stay_month = '2024-11-01')
)
order by park_code, stay_month;


-- -------------------------------------------------------------------------------------
-- S6. A metric defined inside METRICS: average private-let arrivals per day, CT, Aug 2025
-- -------------------------------------------------------------------------------------
-- [S6.old]
select sum(first_day_private_lets) as pl_arrivals, count(*) as park_days,
       round(sum(first_day_private_lets) / count(*), 2) as avg_pl_arrivals_per_day
from HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_FACTS_V3
where park_code = 'CT'
  and on_park_date between '2025-08-01' and '2025-08-31';

-- [S6.A]  the condition lives in the metric; no WHERE on a guest dimension, no day dropped
select pl_arrivals, park_days, round(avg_pl_arrivals_per_day, 2) as avg_pl_arrivals_per_day
from semantic_view(
    HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V3
    metrics sum(iff(guests.stay_type = 'Private Let' and guests.is_first_day, guests.guest_night, 0)) as pl_arrivals,
            park_days.park_days,
            pl_arrivals / park_days.park_days as avg_pl_arrivals_per_day
    where park_days.park_code = 'CT'
      and park_days.stay_month = '2025-08-01'
);

-- [S6.B]  flavour B can do the same: an aggregate over a fact, next to AGG(metric)
select sum(iff(stay_type = 'Private Let' and is_first_day, guest_night, 0)) as pl_arrivals,
       agg(park_days) as park_days,
       round(sum(iff(stay_type = 'Private Let' and is_first_day, guest_night, 0)) / agg(park_days), 2) as avg_pl_arrivals_per_day
from HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V3
where park_code = 'CT'
  and stay_month = '2025-08-01';

-- [S6.A_where_wrong]  WRONG: the same condition as a WHERE drops the day without PL arrivals
select first_day_guests as pl_arrivals, park_days, round(first_day_guests / park_days, 2) as avg_pl_arrivals_per_day
from semantic_view(
    HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V3
    metrics guests.first_day_guests, park_days.park_days
    where park_days.park_code = 'CT'
      and park_days.stay_month = '2025-08-01'
      and guests.stay_type = 'Private Let'
      and guests.is_first_day
);

-- [S6.A_owners_demo]  the same trick next to owners: segment metric + owners, one query,
--                     no guest filter, so no owner day is lost
select pl_arrivals, round(owner_heads_indicative) as owner_heads, park_days, park_days_with_owner_data
from semantic_view(
    HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V3
    metrics sum(iff(guests.stay_type = 'Private Let' and guests.is_first_day, guests.guest_night, 0)) as pl_arrivals,
            owners.owner_heads_indicative, park_days.park_days, owners.park_days_with_owner_data
    where park_days.park_code = 'CT'
      and park_days.stay_month = '2025-08-01'
);
