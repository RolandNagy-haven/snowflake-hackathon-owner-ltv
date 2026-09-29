-- =====================================================================================
-- FOOTFALL_ARRIVALS_SV_V1: booked guests on park, one row per guest per night
--
-- Target: HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL
-- Deploy: python semantic-views/footfall/deploy.py FOOTFALL_ARRIVALS_SV_V1.sql
-- Test:   python semantic-views/footfall/parity_v1.py
--         python semantic-views/footfall/spine_experiment_v1.py
--
-- v1 scope (see README.md for the v1..v5 roadmap):
--   * ONLY booked guests: Holiday Makers + Private Lets. Owner rows of the arrival table
--     are dropped at the source, because arrival data is not a reliable owner count.
--     Owners come back in v3, from Fraser's heads-on-park figures only.
--   * Everything in this view is a person-night count, so every metric is additive
--     across parks, days, stay types, ages and play pass.
--   * Replaces the TOTAL_* columns of DAILY_FOOTFALL_FACTS_V3 (not first day, leavers,
--     bookings or ratios - those are v2).
--
-- The date spine experiment:
--   PARK_DAYS is one row per park per calendar day (like V3's parks_and_dates). Park and
--   date dimensions live there, and guest nights hang off it. Two things to learn:
--     1. park_days counts every day incl. days with no guests, so per-day averages
--        divide by the right number;
--     2. whether SEMANTIC_VIEW() keeps spine rows that have no matching guest rows
--        (i.e. behaves like V3's zero-padding). spine_experiment_v1.py measures it.
-- =====================================================================================

use database HAVEN_DATA_SCIENCE_DEV;
use schema PETERZENTAI_LOCAL;

-- -------------------------------------------------------------------------------------
-- 1. Fact base: one row per booked guest per night on park.
--    Relationships must be on physical columns, so the date is materialised as a
--    column here instead of being a semantic expression.
--    Departure-day rows (on_park_date = departure_date) are not nights and are
--    excluded, exactly as in V3's base block; v2 brings them back as leavers.
-- -------------------------------------------------------------------------------------
create or replace view FOOTFALL_SV_GUEST_NIGHTS_V1 as
select
    to_date(a.on_park_date_xid::string, 'YYYYMMDD')     as on_park_date,
    p.park_code,
    a.booking_id,
    a.guest_id,
    gt.stay_type,
    gt.guest_age,
    bt.play_pass
from haven_store.arrival.fct_park_arrival a
    join haven_store.common.dim_park p using (park_xid)
    join haven_store.arrival.dim_arrival_guest_type gt using (guest_type_xid)
    left join haven_store.arrival.dim_arrival_booking_type bt using (booking_type_xid)
where gt.stay_type in ('Holiday Maker', 'Private Let')
  and a.on_park_date_xid <> a.departure_date_xid
  and a.on_park_date_xid >= 20230101
  and to_date(a.on_park_date_xid::string, 'YYYYMMDD') < current_date;

-- -------------------------------------------------------------------------------------
-- 2. Spine: one row per park per day, 2023-01-01 .. yesterday.
--    Same park set as V3 (every park that ever had an arrival row).
-- -------------------------------------------------------------------------------------
create or replace view FOOTFALL_SV_PARK_DAYS_V1 as
with days as (
    select dateadd(day, row_number() over (order by seq4()) - 1, '2023-01-01'::date) as on_park_date
    from table(generator(rowcount => 5000))
),
parks as (
    select distinct p.park_code
    from haven_store.arrival.fct_park_arrival a
        join haven_store.common.dim_park p using (park_xid)
    where a.on_park_date_xid >= 20230101
)
select d.on_park_date, p.park_code
from days d
    cross join parks p
where d.on_park_date < current_date;

-- -------------------------------------------------------------------------------------
-- 3. Semantic view
-- -------------------------------------------------------------------------------------
create or replace semantic view FOOTFALL_ARRIVALS_SV_V1

  tables (
    guests as HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_SV_GUEST_NIGHTS_V1
      with synonyms = ('guest nights', 'arrivals', 'booked guests', 'footfall', 'visitors', 'guests on park')
      comment = 'One row per booked guest (Holiday Maker or Private Let) per night spent on a Haven park, 2023-01-01 to yesterday. Owners are not included.',

    park_days as HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_SV_PARK_DAYS_V1
      primary key (park_code, on_park_date)
      with synonyms = ('calendar', 'days', 'park calendar')
      comment = 'One row per park per calendar day, 2023-01-01 to yesterday, whether or not the park had guests. The spine for park and date.',

    parks as HAVEN_STORE.COMMON.DIM_PARK
      primary key (park_code)
      with synonyms = ('holiday parks', 'sites', 'park')
      comment = 'Haven holiday parks with name, cluster, size band and operating region.'
  )

  relationships (
    guests_to_park_day as guests (park_code, on_park_date) references park_days,
    park_day_to_park   as park_days (park_code)             references parks
  )

  facts (
    guests.guest_night as 1
      comment = 'One person on park for one night.',
    private guests.booking_ref as booking_id,
    private guests.guest_ref   as guest_id,
    private guests.park_day_key as park_code || '|' || to_char(on_park_date)
  )

  dimensions (
    -- when (on the spine, so days without guests exist too)
    park_days.on_park_date as on_park_date
      with synonyms = ('date', 'day', 'night', 'stay date')
      comment = 'The calendar date of the night on park (the guest is on park that evening).',
    park_days.stay_year    as year(on_park_date)             comment = 'Calendar year.',
    park_days.stay_month   as date_trunc('month', on_park_date)
      with synonyms = ('month') comment = 'First day of the month.',
    park_days.stay_week    as date_trunc('week', on_park_date)
      with synonyms = ('week') comment = 'Monday of the week.',
    park_days.day_of_week  as dayname(on_park_date)
      with synonyms = ('weekday') comment = 'Three-letter day name (Mon..Sun).',
    park_days.is_weekend_night as dayofweekiso(on_park_date) in (5, 6)
      comment = 'True for Friday and Saturday nights.',

    -- where (park_code sits on the spine, the park's attributes on parks)
    park_days.park_code    as park_code
      comment = 'Two-letter park code, e.g. CT = Craig Tara.',
    parks.park_name        as park_name
      with synonyms = ('park', 'site name') comment = 'Park name, e.g. Craig Tara.',
    parks.park_cluster     as park_cluster_name   comment = 'Operational park cluster.',
    parks.park_size        as park_sizing          comment = 'Park size band.',
    parks.region           as director_region
      with synonyms = ('area', 'operating region') comment = 'Operating region of the park director.',

    -- who
    guests.stay_type       as stay_type
      with synonyms = ('guest type', 'segment', 'customer type')
      comment = 'Holiday Maker (booked a Haven holiday) or Private Let (stays in an owner''s caravan let privately). Owners are not in this view.',
    guests.guest_age       as guest_age
      with synonyms = ('age group', 'age band')
      comment = 'Adult, Child or Infant.',
    guests.play_pass       as play_pass
      with synonyms = ('play pass status')
      comment = 'Whether the booking has a play pass: ''Has play pass'' or ''No play pass''.'
  )

  metrics (
    guests.guest_nights as sum(guests.guest_night)
      with synonyms = ('guests', 'people on park', 'footfall', 'headcount', 'total nights', 'visitors', 'occupancy')
      comment = 'Person-nights of booked guests. On a single day this is the number of booked guests on park that night. Summed over several days it is person-nights, not distinct people.',
    guests.holiday_maker_nights as sum(iff(guests.stay_type = 'Holiday Maker', guests.guest_night, 0))
      with synonyms = ('holiday makers')
      comment = 'Person-nights of Holiday Makers.',
    guests.private_let_nights as sum(iff(guests.stay_type = 'Private Let', guests.guest_night, 0))
      with synonyms = ('private lets')
      comment = 'Person-nights of Private Let guests.',
    guests.guests_with_play_pass as sum(iff(guests.play_pass = 'Has play pass', guests.guest_night, 0))
      comment = 'Person-nights of guests whose booking has a play pass.',
    guests.distinct_guests as count(distinct guests.guest_ref)
      with synonyms = ('unique guests', 'distinct people')
      comment = 'Distinct guests over the period. Not additive across periods or parks.',
    guests.park_days_with_guests as count(distinct guests.park_day_key)
      with synonyms = ('open days', 'occupied days')
      comment = 'Park x days with at least one booked guest.',

    park_days.park_days as count(park_days.on_park_date)
      with synonyms = ('calendar days', 'days in period')
      comment = 'Park x calendar days in the period, including days with no guests.',

    -- derived across tables: averages over ALL calendar days, zero days included
    avg_guests_per_day as div0(guests.guest_nights, park_days.park_days)
      with synonyms = ('average daily guests', 'average footfall', 'average occupancy')
      comment = 'Average booked guests on park per calendar day, counting days with no guests as zero.',
    -- zero-padded: referencing a park_days metric makes the query return every spine
    -- row, so days without guests come back as 0 (a plain coalesce does not - measured).
    guests_on_park as iff(park_days.park_days > 0, coalesce(guests.guest_nights, 0), null)
      with synonyms = ('guests per day zero filled', 'daily guests incl closed days')
      comment = 'guest_nights on the full park x day grid: days with no booked guests are returned as 0 instead of being absent. Use for daily series and time-series exports.'
  )

  comment = 'Haven footfall v1: booked guests (Holiday Makers + Private Lets) on park per night, by park, date, stay type, age and play pass. Owners are excluded.'

  ai_sql_generation 'Guest counts are person-nights: on one date guest_nights is the number of booked guests on park that night; over a date range it is person-nights, so for "how many people per day" use avg_guests_per_day or group by on_park_date. This view has Holiday Makers and Private Lets only. Owners are NOT included and cannot be derived here, so never describe guest_nights as the total population of a park; call it booked guests. A day with no guest rows means zero booked guests, not missing data: use avg_guests_per_day, which divides by park_days (all calendar days), for daily averages, and guests_on_park for a daily series that must include zero days. IMPORTANT: a WHERE filter on a guests dimension (stay_type, guest_age, play_pass) also removes calendar days without such guests, so park_days and avg_guests_per_day then divide by the wrong number of days. For per-segment daily averages use the segment metrics (holiday_maker_nights, private_let_nights, guests_with_play_pass) divided by park_days, not a WHERE filter. Filters on park or date are safe. Data covers 2023-01-01 to yesterday; there are no future dates. Round averages to whole people.'

  ai_verified_queries (
    guests_by_park_last_7d as (
      question 'How many booked guests were on each park over the last 7 days, and what was the daily average?'
      onboarding_question true
      sql 'select * from semantic_view(HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V1 dimensions parks.park_name metrics guests.guest_nights, avg_guests_per_day where park_days.on_park_date between current_date - 7 and current_date - 1) order by guest_nights desc'
    ),
    daily_mix_by_stay_type as (
      question 'Show daily booked guests by stay type for Craig Tara in August 2026'
      sql 'select * from semantic_view(HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V1 dimensions park_days.on_park_date, guests.stay_type metrics guests.guest_nights where park_days.park_code = ''CT'' and park_days.on_park_date between ''2026-08-01'' and ''2026-08-31'') order by on_park_date, stay_type'
    )
  )
;
