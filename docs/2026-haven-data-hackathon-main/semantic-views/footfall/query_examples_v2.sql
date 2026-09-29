-- =====================================================================================
-- query_examples_v2.sql - v2 questions (arrivals, leavers, bookings, ratios) asked three ways
--
--   old = plain SQL on the wide table HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_FACTS_V3
--         (or, in a "b" scenario, plain SQL on the v2 base view as an independent reference)
--   A   = semantic view, SEMANTIC_VIEW( ... DIMENSIONS ... METRICS ... WHERE ... ) clause
--   B   = semantic view named directly in FROM, metrics wrapped in AGG(), GROUP BY dims
--
-- Read alongside QUERY_EXAMPLES_V2.md. Checked by check_query_examples_v2.py, which reads
-- the "-- [S<n>[b].<tag>]" markers below:
--   old / A / B / A2 / B2 ...  must return the same rows as [S<n>.old]
--   *_wrong, *_differs         must return DIFFERENT rows (a pitfall, or a deliberately
--                              different answer)
--   *_demo                     only has to run
-- Each query ends with a semicolon at the end of a line.
-- =====================================================================================


-- -------------------------------------------------------------------------------------
-- S1. Arrivals vs leavers per day at Craig Tara (CT), 1-10 August 2025
-- -------------------------------------------------------------------------------------
-- [S1.old]
select on_park_date, dayname(on_park_date) as day_of_week,
       first_day as arrivals, leavers, last_full_day, total_nights as guest_nights
from HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_FACTS_V3
where park_code = 'CT'
  and on_park_date between '2025-08-01' and '2025-08-10'
order by on_park_date;

-- [S1.A]
select *
from semantic_view(
    HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V2
    dimensions park_days.on_park_date, park_days.day_of_week
    metrics guests.first_day_guests, guests.leavers, guests.last_full_day_guests, guests.guest_nights
    where park_days.park_code = 'CT'
      and park_days.on_park_date between '2025-08-01' and '2025-08-10'
)
order by on_park_date;

-- [S1.B]
select on_park_date, day_of_week,
       agg(first_day_guests) as arrivals, agg(leavers) as leavers,
       agg(last_full_day_guests) as last_full_day, agg(guest_nights) as guest_nights
from HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V2
where park_code = 'CT'
  and on_park_date between '2025-08-01' and '2025-08-10'
group by on_park_date, day_of_week
order by on_park_date;

-- [S1.A_by_stay_type_demo]  (V3 has no "leavers by age" or "arrivals by play pass x stay type")
select *
from semantic_view(
    HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V2
    dimensions guests.stay_type, guests.guest_age
    metrics guests.first_day_guests, guests.leavers
    where park_days.park_code = 'CT'
      and park_days.on_park_date = '2025-08-04'
)
order by stay_type, guest_age;


-- -------------------------------------------------------------------------------------
-- S2. Bookings vs guests per day at Craig Tara, 4-10 August 2025
--     (V3's TOTAL_BOOKINGS includes owners; its HM + PL columns are the comparable number)
-- -------------------------------------------------------------------------------------
-- [S2.old]
select on_park_date,
       total_bookings_holiday_makers + total_bookings_private_lets as bookings_on_park,
       total_nights as guest_nights,
       round(total_nights / (total_bookings_holiday_makers + total_bookings_private_lets), 2) as guests_per_booking
from HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_FACTS_V3
where park_code = 'CT'
  and on_park_date between '2025-08-04' and '2025-08-10'
order by on_park_date;

-- [S2.A]
select on_park_date, bookings_on_park, guest_nights, round(guests_per_booking, 2) as guests_per_booking
from semantic_view(
    HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V2
    dimensions park_days.on_park_date
    metrics guests.bookings_on_park, guests.guest_nights,
            guests.guest_nights / guests.bookings_on_park as guests_per_booking
    where park_days.park_code = 'CT'
      and park_days.on_park_date between '2025-08-04' and '2025-08-10'
)
order by on_park_date;

-- [S2.B]
select on_park_date, agg(bookings_on_park) as bookings_on_park, agg(guest_nights) as guest_nights,
       round(agg(guest_nights) / agg(bookings_on_park), 2) as guests_per_booking
from HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V2
where park_code = 'CT'
  and on_park_date between '2025-08-04' and '2025-08-10'
group by on_park_date
order by on_park_date;


-- -------------------------------------------------------------------------------------
-- S3. Bookings over the whole week: summing the daily numbers vs recounting
-- -------------------------------------------------------------------------------------
-- [S3.old]  the only thing V3 can do: add up its daily columns
select sum(total_bookings_holiday_makers + total_bookings_private_lets)       as bookings_on_park,
       sum(first_day_booking_count_holiday_makers + first_day_booking_count_private_lets) as first_day_bookings,
       sum(leavers_booking_count_holiday_makers + leavers_booking_count_private_lets)     as leaver_bookings
from HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_FACTS_V3
where park_code = 'CT'
  and on_park_date between '2025-08-04' and '2025-08-10';

-- [S3.A_sum_of_daily]  the same mistake with the semantic view: sum the daily rows
select sum(bookings_on_park) as bookings_on_park, sum(first_day_bookings) as first_day_bookings,
       sum(leaver_bookings) as leaver_bookings
from semantic_view(
    HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V2
    dimensions park_days.on_park_date
    metrics guests.bookings_on_park, guests.first_day_bookings, guests.leaver_bookings
    where park_days.park_code = 'CT'
      and park_days.on_park_date between '2025-08-04' and '2025-08-10'
);

-- [S3.A_week_differs]  RIGHT: ask for the week, the view recounts distinct bookings
select *
from semantic_view(
    HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V2
    metrics guests.bookings_on_park, guests.first_day_bookings, guests.leaver_bookings
    where park_days.park_code = 'CT'
      and park_days.on_park_date between '2025-08-04' and '2025-08-10'
);

-- [S3.B_week_differs]
select agg(bookings_on_park) as bookings_on_park, agg(first_day_bookings) as first_day_bookings,
       agg(leaver_bookings) as leaver_bookings
from HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V2
where park_code = 'CT'
  and on_park_date between '2025-08-04' and '2025-08-10';

-- -------------------------------------------------------------------------------------
-- S3b. Independent check of the weekly recount: plain SQL on the v2 base view
-- -------------------------------------------------------------------------------------
-- [S3b.old]
select count(distinct iff(not is_departure_day, booking_id, null)) as bookings_on_park,
       count(distinct iff(is_first_day, booking_id, null))         as first_day_bookings,
       count(distinct iff(is_departure_day, booking_id, null))     as leaver_bookings
from HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_SV_GUEST_DAYS_V2
where park_code = 'CT'
  and on_park_date between '2025-08-04' and '2025-08-10';

-- [S3b.A]
select *
from semantic_view(
    HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V2
    metrics guests.bookings_on_park, guests.first_day_bookings, guests.leaver_bookings
    where park_days.park_code = 'CT'
      and park_days.on_park_date between '2025-08-04' and '2025-08-10'
);


-- -------------------------------------------------------------------------------------
-- S4. A ratio at two grains: holiday-maker share at Haggerston (HA), November 2025
-- -------------------------------------------------------------------------------------
-- [S4.old]  RIGHT with V3: recompute from the counts, sum / sum
select round(sum(total_holiday_makers) / sum(total_nights), 4) as holiday_makers_ratio
from HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_FACTS_V3
where park_code = 'HA'
  and on_park_date between '2025-11-01' and '2025-11-30';

-- [S4.A]  ask for the ratio at the month grain; the view divides the month's sums
select round(holiday_makers_ratio, 4) as holiday_makers_ratio
from semantic_view(
    HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V2
    metrics guests.holiday_makers_ratio
    where park_days.park_code = 'HA'
      and park_days.stay_month = '2025-11-01'
);

-- [S4.B]
select round(agg(holiday_makers_ratio), 4) as holiday_makers_ratio
from HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V2
where park_code = 'HA'
  and stay_month = '2025-11-01';

-- [S4.A_avg_of_daily_wrong]  WRONG: average the daily ratios
select round(avg(holiday_makers_ratio), 4) as holiday_makers_ratio
from semantic_view(
    HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V2
    dimensions park_days.on_park_date
    metrics guests.holiday_makers_ratio
    where park_days.park_code = 'HA'
      and park_days.stay_month = '2025-11-01'
);

-- [S4.old_avg_of_daily_wrong]  the same mistake on V3's ratio column
select round(avg(holiday_makers_ratio), 4) as holiday_makers_ratio
from HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_FACTS_V3
where park_code = 'HA'
  and on_park_date between '2025-11-01' and '2025-11-30';

-- [S4.A_weekly_demo]  the same metric at week grain, recomputed per week
select stay_week, guest_nights, holiday_maker_nights, round(holiday_makers_ratio, 4) as holiday_makers_ratio
from semantic_view(
    HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V2
    dimensions park_days.stay_week
    metrics guests.guest_nights, guests.holiday_maker_nights, guests.holiday_makers_ratio
    where park_days.park_code = 'HA'
      and park_days.stay_month = '2025-11-01'
)
order by stay_week;


-- -------------------------------------------------------------------------------------
-- S5. Self-catering: arriving holiday-maker bookings, August 2025, CT / HA / WM
-- -------------------------------------------------------------------------------------
-- [S5.old]
select park_code,
       sum(first_day_booking_count_holiday_makers)               as hm_arriving_bookings,
       sum(first_day_booking_count_holiday_makers_self_catering) as self_catering_arriving_bookings
from HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_FACTS_V3
where park_code in ('CT', 'HA', 'WM')
  and on_park_date between '2025-08-01' and '2025-08-31'
group by park_code
order by park_code;

-- [S5.A]  group by the flag, pivot outside. Summing the two flag groups is valid:
--         every booking is either self-catering or not, never both.
select park_code,
       sum(first_day_bookings)                             as hm_arriving_bookings,
       sum(iff(is_self_catering, first_day_bookings, 0))   as self_catering_arriving_bookings
from semantic_view(
    HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V2
    dimensions park_days.park_code, guests.is_self_catering
    metrics guests.first_day_bookings
    where park_days.park_code in ('CT', 'HA', 'WM')
      and park_days.stay_month = '2025-08-01'
      and guests.stay_type = 'Holiday Maker'
)
group by park_code
order by park_code;

-- [S5.B]  one metric, two filters would need two queries; here the filter goes into the
--         WHERE and the unfiltered number comes from a second AGG over the same rows
with hm as (
    select park_code, is_self_catering, agg(first_day_bookings) as first_day_bookings
    from HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V2
    where park_code in ('CT', 'HA', 'WM')
      and stay_month = '2025-08-01'
      and stay_type = 'Holiday Maker'
    group by park_code, is_self_catering
)
select park_code, sum(first_day_bookings) as hm_arriving_bookings,
       sum(iff(is_self_catering, first_day_bookings, 0)) as self_catering_arriving_bookings
from hm
group by park_code
order by park_code;

-- [S5.A_self_catering_only_demo]  the question as usually asked: a filter is fine for a total
select park_code, first_day_bookings
from semantic_view(
    HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V2
    dimensions park_days.park_code
    metrics guests.first_day_bookings
    where park_days.park_code in ('CT', 'HA', 'WM')
      and park_days.stay_month = '2025-08-01'
      and guests.is_self_catering
)
order by park_code;

-- [S5.A_by_grade_demo]  what "not self-catering" is: the Touring grade group (a pitch)
select grade_group, first_day_bookings
from semantic_view(
    HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V2
    dimensions guests.grade_group
    metrics guests.first_day_bookings
    where park_days.park_code = 'HA'
      and park_days.stay_month = '2025-08-01'
      and guests.stay_type = 'Holiday Maker'
)
order by first_day_bookings desc;


-- -------------------------------------------------------------------------------------
-- S6. The day-flag filter trap: average arrivals per day at HA, 6-12 November 2025
-- -------------------------------------------------------------------------------------
-- [S6.old]
select sum(first_day) as arrivals, count(*) as park_days,
       round(sum(first_day) / count(*), 2) as avg_arrivals_per_day
from HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_FACTS_V3
where park_code = 'HA'
  and on_park_date between '2025-11-06' and '2025-11-12';

-- [S6.A]  RIGHT: the metric first_day_guests, divided by the unfiltered day count
select first_day_guests, park_days, round(avg_arrivals_per_day, 2) as avg_arrivals_per_day
from semantic_view(
    HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V2
    metrics guests.first_day_guests, park_days.park_days,
            guests.first_day_guests / park_days.park_days as avg_arrivals_per_day
    where park_days.park_code = 'HA'
      and park_days.on_park_date between '2025-11-06' and '2025-11-12'
);

-- [S6.B]
select agg(first_day_guests) as arrivals, agg(park_days) as park_days,
       round(agg(first_day_guests) / agg(park_days), 2) as avg_arrivals_per_day
from HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V2
where park_code = 'HA'
  and on_park_date between '2025-11-06' and '2025-11-12';

-- [S6.A_wrong]  WRONG: filter to first days, then use the general daily average
select guest_nights, park_days, round(avg_guests_per_day, 2) as avg_guests_per_day
from semantic_view(
    HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V2
    metrics guests.guest_nights, park_days.park_days, avg_guests_per_day
    where park_days.park_code = 'HA'
      and park_days.on_park_date between '2025-11-06' and '2025-11-12'
      and guests.is_first_day
);

-- [S6.B_wrong]
select agg(first_day_guests) as arrivals, agg(park_days) as park_days,
       round(agg(first_day_guests) / agg(park_days), 2) as avg_arrivals_per_day
from HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V2
where park_code = 'HA'
  and on_park_date between '2025-11-06' and '2025-11-12'
  and is_first_day;

-- [S6.A_departure_filter_demo]  another flag trap: guest_nights counts nights only, so
--                               with WHERE is_departure_day it is 0; use leavers instead
select *
from semantic_view(
    HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V2
    metrics guests.guest_nights, guests.leavers, park_days.park_days
    where park_days.park_code = 'HA'
      and park_days.on_park_date between '2025-11-06' and '2025-11-12'
      and guests.is_departure_day
);
