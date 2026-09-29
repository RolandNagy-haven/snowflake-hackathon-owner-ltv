-- =====================================================================================
-- query_examples_v1.sql - the same questions asked three ways
--
--   old = plain SQL on the wide table HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_FACTS_V3
--   A   = semantic view, SEMANTIC_VIEW( ... DIMENSIONS ... METRICS ... WHERE ... ) clause
--   B   = semantic view named directly in FROM, metrics wrapped in AGG(), GROUP BY dims
--
-- Read alongside QUERY_EXAMPLES_V1.md. Checked by check_query_examples_v1.py, which reads
-- the "-- [S<n>.<tag>]" markers below:
--   old / A / B / A2 / B2 ...  must return the same rows as [S<n>.old]
--   *_wrong                    must return DIFFERENT rows (a documented pitfall)
--   *_demo                     only has to run (the old view cannot answer it)
-- Each query ends with a semicolon at the end of a line.
-- =====================================================================================


-- -------------------------------------------------------------------------------------
-- S1. How many guest nights did Craig Tara (CT) have in August 2025?
-- -------------------------------------------------------------------------------------
-- [S1.old]
select sum(total_nights) as guest_nights
from HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_FACTS_V3
where park_code = 'CT'
  and on_park_date between '2025-08-01' and '2025-08-31';

-- [S1.A]
select *
from semantic_view(
    HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V1
    metrics guests.guest_nights
    where park_days.park_code = 'CT'
      and park_days.on_park_date between '2025-08-01' and '2025-08-31'
);

-- [S1.B]
select agg(guest_nights) as guest_nights
from HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V1
where park_code = 'CT'
  and on_park_date between '2025-08-01' and '2025-08-31';


-- -------------------------------------------------------------------------------------
-- S2. Top 5 parks by guest nights in the week of Monday 4 August 2025, with name and region
-- -------------------------------------------------------------------------------------
-- [S2.old]
select f.park_code, p.park_name, p.director_region as region, sum(f.total_nights) as guest_nights
from HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_FACTS_V3 f
    join HAVEN_STORE.COMMON.DIM_PARK p on p.park_code = f.park_code
where f.on_park_date between '2025-08-04' and '2025-08-10'
group by f.park_code, p.park_name, p.director_region
order by guest_nights desc
limit 5;

-- [S2.A]
select *
from semantic_view(
    HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V1
    dimensions park_days.park_code, parks.park_name, parks.region
    metrics guests.guest_nights
    where park_days.stay_week = '2025-08-04'
)
order by guest_nights desc
limit 5;

-- [S2.B]
select park_code, park_name, region, agg(guest_nights) as guest_nights
from HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V1
where stay_week = '2025-08-04'
group by park_code, park_name, region
order by guest_nights desc
limit 5;


-- -------------------------------------------------------------------------------------
-- S3. Daily guests on park at Craig Tara, 1-7 August 2025
-- -------------------------------------------------------------------------------------
-- [S3.old]
select on_park_date, dayname(on_park_date) as day_of_week, total_nights as guest_nights
from HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_FACTS_V3
where park_code = 'CT'
  and on_park_date between '2025-08-01' and '2025-08-07'
order by on_park_date;

-- [S3.A]
select *
from semantic_view(
    HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V1
    dimensions park_days.on_park_date, park_days.day_of_week
    metrics guests.guest_nights
    where park_days.park_code = 'CT'
      and park_days.on_park_date between '2025-08-01' and '2025-08-07'
)
order by on_park_date;

-- [S3.B]
select on_park_date, day_of_week, agg(guest_nights) as guest_nights
from HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V1
where park_code = 'CT'
  and on_park_date between '2025-08-01' and '2025-08-07'
group by on_park_date, day_of_week
order by on_park_date;


-- -------------------------------------------------------------------------------------
-- S4. Guest nights by age group at Craig Tara, August 2025
--     old: one column per age -> unpivot by hand. new: guest_age is a dimension.
-- -------------------------------------------------------------------------------------
-- [S4.old]
select guest_age, guest_nights
from (
    select sum(total_adults) as "Adult", sum(total_children) as "Child", sum(total_infants) as "Infant"
    from HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_FACTS_V3
    where park_code = 'CT'
      and on_park_date between '2025-08-01' and '2025-08-31'
) unpivot (guest_nights for guest_age in ("Adult", "Child", "Infant"))
order by guest_age;

-- [S4.A]
select *
from semantic_view(
    HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V1
    dimensions guests.guest_age
    metrics guests.guest_nights
    where park_days.park_code = 'CT'
      and park_days.on_park_date between '2025-08-01' and '2025-08-31'
)
order by guest_age;

-- [S4.B]
select guest_age, agg(guest_nights) as guest_nights
from HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V1
where park_code = 'CT'
  and on_park_date between '2025-08-01' and '2025-08-31'
group by guest_age
order by guest_age;

-- Stay type x age x play pass: the old view has no column for "adult holiday makers with
-- a play pass" (every TOTAL_* column is one condition), so this has no old equivalent.
-- [S4.B_demo]
select stay_type, guest_age, play_pass, agg(guest_nights) as guest_nights
from HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V1
where park_code = 'CT'
  and on_park_date between '2025-08-01' and '2025-08-31'
group by stay_type, guest_age, play_pass
order by stay_type, guest_age, play_pass;


-- -------------------------------------------------------------------------------------
-- S5. Holiday makers and private lets side by side, per park, August 2025 (CT, HA, WM)
-- -------------------------------------------------------------------------------------
-- [S5.old]
select park_code,
       sum(total_holiday_makers) as holiday_maker_nights,
       sum(total_private_lets)   as private_let_nights,
       sum(total_play_pass)      as guests_with_play_pass
from HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_FACTS_V3
where park_code in ('CT', 'HA', 'WM')
  and on_park_date between '2025-08-01' and '2025-08-31'
group by park_code
order by park_code;

-- (a) ready-made segment metrics: one row per park, segments are columns
-- [S5.A]
select *
from semantic_view(
    HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V1
    dimensions park_days.park_code
    metrics guests.holiday_maker_nights, guests.private_let_nights, guests.guests_with_play_pass
    where park_days.park_code in ('CT', 'HA', 'WM')
      and park_days.on_park_date between '2025-08-01' and '2025-08-31'
)
order by park_code;

-- [S5.B]
select park_code,
       agg(holiday_maker_nights)  as holiday_maker_nights,
       agg(private_let_nights)    as private_let_nights,
       agg(guests_with_play_pass) as guests_with_play_pass
from HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V1
where park_code in ('CT', 'HA', 'WM')
  and on_park_date between '2025-08-01' and '2025-08-31'
group by park_code
order by park_code;

-- (b) group by the dimensions (long format: one row per park x stay type x play pass),
--     then pivot in ordinary SQL outside the SEMANTIC_VIEW clause
-- [S5.A2]
with long as (
    select *
    from semantic_view(
        HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V1
        dimensions park_days.park_code, guests.stay_type, guests.play_pass
        metrics guests.guest_nights
        where park_days.park_code in ('CT', 'HA', 'WM')
          and park_days.on_park_date between '2025-08-01' and '2025-08-31'
    )
)
select park_code,
       sum(iff(stay_type = 'Holiday Maker', guest_nights, 0)) as holiday_maker_nights,
       sum(iff(stay_type = 'Private Let',   guest_nights, 0)) as private_let_nights,
       sum(iff(play_pass = 'Has play pass', guest_nights, 0)) as guests_with_play_pass
from long
group by park_code
order by park_code;

-- (c) flavour B can build the same ad hoc from the fact guest_night (1 per guest-night)
-- [S5.B2]
select park_code,
       sum(iff(stay_type = 'Holiday Maker', guest_night, 0)) as holiday_maker_nights,
       sum(iff(stay_type = 'Private Let',   guest_night, 0)) as private_let_nights,
       sum(iff(play_pass = 'Has play pass', guest_night, 0)) as guests_with_play_pass
from HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V1
where park_code in ('CT', 'HA', 'WM')
  and on_park_date between '2025-08-01' and '2025-08-31'
group by park_code
order by park_code;


-- -------------------------------------------------------------------------------------
-- S6. Average guests per day in March 2025, counting days with no guests as 0
--     (RV, PS, HA open late in the month / not every day)
-- -------------------------------------------------------------------------------------
-- [S6.old]
select park_code,
       count(*)                    as park_days,
       count_if(total_nights > 0)  as park_days_with_guests,
       sum(total_nights)           as guest_nights,
       avg(total_nights)           as avg_guests_per_day
from HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_FACTS_V3
where park_code in ('HA', 'PS', 'RV')
  and on_park_date between '2025-03-01' and '2025-03-31'
group by park_code
order by park_code;

-- [S6.A]
select *
from semantic_view(
    HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V1
    dimensions park_days.park_code
    metrics park_days.park_days, guests.park_days_with_guests, guests.guest_nights, avg_guests_per_day
    where park_days.park_code in ('HA', 'PS', 'RV')
      and park_days.stay_month = '2025-03-01'
)
order by park_code;

-- [S6.B]
select park_code,
       agg(park_days)             as park_days,
       agg(park_days_with_guests) as park_days_with_guests,
       agg(guest_nights)          as guest_nights,
       agg(avg_guests_per_day)    as avg_guests_per_day
from HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V1
where park_code in ('HA', 'PS', 'RV')
  and stay_month = '2025-03-01'
group by park_code
order by park_code;

-- Pitfall: averaging a daily series that has no rows for empty days divides by open days.
-- [S6.A_wrong]
select park_code, count(*) as park_days, count(*) as park_days_with_guests,
       sum(guest_nights) as guest_nights, avg(guest_nights) as avg_guests_per_day
from semantic_view(
    HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V1
    dimensions park_days.park_code, park_days.on_park_date
    metrics guests.guest_nights
    where park_days.park_code in ('HA', 'PS', 'RV')
      and park_days.stay_month = '2025-03-01'
)
group by park_code
order by park_code;


-- -------------------------------------------------------------------------------------
-- S7. Zero-padded daily series: Riviera Bay (RV), 17-23 March 2025 (opened on the 21st)
-- -------------------------------------------------------------------------------------
-- [S7.old]
select on_park_date, total_nights as guests_on_park
from HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_FACTS_V3
where park_code = 'RV'
  and on_park_date between '2025-03-17' and '2025-03-23'
order by on_park_date;

-- [S7.A]
select *
from semantic_view(
    HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V1
    dimensions park_days.on_park_date
    metrics guests_on_park
    where park_days.park_code = 'RV'
      and park_days.on_park_date between '2025-03-17' and '2025-03-23'
)
order by on_park_date;

-- [S7.B]
select on_park_date, agg(guests_on_park) as guests_on_park
from HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V1
where park_code = 'RV'
  and on_park_date between '2025-03-17' and '2025-03-23'
group by on_park_date
order by on_park_date;

-- Pitfall: guest_nights alone returns only the days that have guests (3 rows, not 7).
-- [S7.A_wrong]
select *
from semantic_view(
    HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V1
    dimensions park_days.on_park_date
    metrics guests.guest_nights
    where park_days.park_code = 'RV'
      and park_days.on_park_date between '2025-03-17' and '2025-03-23'
)
order by on_park_date;


-- -------------------------------------------------------------------------------------
-- S8. Average holiday makers per day at Haggerston (HA), 6-12 November 2025
--     Holiday makers were there on 6-9 Nov only; 10-12 Nov had private lets only.
-- -------------------------------------------------------------------------------------
-- [S8.old]
select sum(total_holiday_makers)            as holiday_maker_nights,
       count(*)                             as park_days,
       sum(total_holiday_makers) / count(*) as avg_holiday_makers_per_day
from HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_FACTS_V3
where park_code = 'HA'
  and on_park_date between '2025-11-06' and '2025-11-12';

-- Right: segment metric divided by park_days, no filter on stay_type
-- [S8.A]
select *
from semantic_view(
    HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V1
    metrics guests.holiday_maker_nights,
            park_days.park_days,
            guests.holiday_maker_nights / park_days.park_days as avg_holiday_makers_per_day
    where park_days.park_code = 'HA'
      and park_days.on_park_date between '2025-11-06' and '2025-11-12'
);

-- [S8.B]
select agg(holiday_maker_nights)                   as holiday_maker_nights,
       agg(park_days)                              as park_days,
       agg(holiday_maker_nights) / agg(park_days)  as avg_holiday_makers_per_day
from HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V1
where park_code = 'HA'
  and on_park_date between '2025-11-06' and '2025-11-12';

-- Wrong: WHERE on a guests dimension - park_days drops from 7 to 4
-- [S8.A_wrong]
select *
from semantic_view(
    HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V1
    metrics guests.guest_nights, park_days.park_days, avg_guests_per_day
    where park_days.park_code = 'HA'
      and park_days.on_park_date between '2025-11-06' and '2025-11-12'
      and guests.stay_type = 'Holiday Maker'
);

-- [S8.B_wrong]
select agg(guest_nights) as guest_nights, agg(park_days) as park_days, agg(avg_guests_per_day) as avg_guests_per_day
from HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V1
where park_code = 'HA'
  and on_park_date between '2025-11-06' and '2025-11-12'
  and stay_type = 'Holiday Maker';

-- Also wrong: GROUP BY stay_type gives each segment its own day count (HM 4, PL 7)
-- [S8.A_wrong2]
select guest_nights, park_days, avg_guests_per_day
from semantic_view(
    HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V1
    dimensions guests.stay_type
    metrics guests.guest_nights, park_days.park_days, avg_guests_per_day
    where park_days.park_code = 'HA'
      and park_days.on_park_date between '2025-11-06' and '2025-11-12'
)
where stay_type = 'Holiday Maker';

-- Why: the filter keeps only the calendar days that have at least one Holiday Maker row.
-- park_days alone, filtered on stay_type, counts 4 - no guest metric needed.
-- [S8.A_demo]
select *
from semantic_view(
    HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V1
    dimensions park_days.on_park_date
    metrics park_days.park_days, guests.holiday_maker_nights
    where park_days.park_code = 'HA'
      and park_days.on_park_date between '2025-11-06' and '2025-11-12'
      and guests.stay_type = 'Holiday Maker'
)
order by on_park_date;

-- Plain-SQL equivalent of what the filtered query does to the calendar (returns 4)
-- [S8.plain_demo]
select count(*) as park_days
from HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_SV_PARK_DAYS_V1 d
where d.park_code = 'HA'
  and d.on_park_date between '2025-11-06' and '2025-11-12'
  and exists (select 1
              from HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_SV_GUEST_NIGHTS_V1 g
              where g.park_code = d.park_code
                and g.on_park_date = d.on_park_date
                and g.stay_type = 'Holiday Maker');
