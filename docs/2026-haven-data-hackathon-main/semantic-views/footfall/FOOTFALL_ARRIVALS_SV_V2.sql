-- =====================================================================================
-- FOOTFALL_ARRIVALS_SV_V2: booked guests on park per day, with the start and end of
-- each stay, bookings and ratios
--
-- Target: HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL
-- Deploy: python semantic-views/footfall/deploy.py FOOTFALL_ARRIVALS_SV_V2.sql
-- Test:   python semantic-views/footfall/parity_v2.py
--         python semantic-views/footfall/check_query_examples_v2.py
--
-- v2 = v1 plus (see README.md for the v1..v5 roadmap):
--   * departure-day rows (the morning a guest leaves) -> leavers
--   * day-of-stay flags: is_first_day, is_last_full_day, is_departure_day
--   * bookings: count(distinct booking_id) for nights, first days and departure days,
--     and a self-catering flag (Holiday Maker, accommodation grade not Touring)
--   * ratios (share of guest_nights), recomputed at whatever grain you query
--   * sample values for park_name / park_code so Cortex Analyst matches park names
--
-- Still ONLY booked guests: Holiday Makers + Private Lets. Owner rows of the arrival
-- table are dropped at the source. There are no owner first-day, leaver or booking
-- numbers anywhere in this view; owners come back in v3, from Fraser's figures only.
--
-- DESIGN: ONE guest table that holds both nights and departure days.
--   V3 excludes departure-day rows (on_park_date = departure_date) from its base block and
--   counts them in a separate `leavers` CTE. Here they stay in the same table as the
--   nights, flagged is_departure_day, so stay type, age, play pass and self-catering
--   apply to leavers too, and "leavers vs arrivals by stay type" is one query with one
--   stay_type dimension. (A separate leavers table would need its own copy of every
--   guest dimension - leavers.stay_type next to guests.stay_type - which is confusing for
--   people and for Cortex Analyst.)
--   The price: every "night" metric must skip departure days. That is done ONCE, in the
--   fact guest_night (= 0 on a departure day), and every v1 metric is built on it, so
--   v1 numbers are unchanged (parity_v2.py checks this).
--
-- DAY-OF-STAY FLAGS (separate flags, because they overlap):
--   is_departure_day  on_park_date = departure_date   the morning the guest leaves; NOT a night
--   is_first_day      on_park_date = arrival_date     the first NIGHT of the stay
--                     and not a departure day          (a same-day stay, arrival = departure,
--                                                      has no night: it is a leaver only,
--                                                      exactly as in V3)
--   is_last_full_day  on_park_date = departure - 1    the last night of the stay
--   A one-night stay's single night is both is_first_day and is_last_full_day.
--
-- BOOKINGS are distinct counts: a booking with 4 guests on park for 7 nights is one
-- booking on each of those 7 days, and one booking over the week, not 7. So booking
-- metrics CANNOT be summed across days, parks, or age groups; ask the view for the grain
-- you need and it recounts. (They can be summed across stay_type and is_self_catering,
-- because every booking has exactly one of each - measured, see README.)
--
-- SELF-CATERING comes from the arrival row's own accommodation grade (GRADE_XID ->
-- HAVEN_STORE.HOLIDAY.DIM_GRADE, grade_group 'Touring' = pitch, anything else = caravan /
-- lodge / apartment). V3 instead joins today's snapshot of HOLIDAY.FCT_HOLIDAY_BOOKINGS for
-- the package type. Measured on every booking since 2023: grade_group = 'Touring' and
-- package_type = 'TOURING' agree on all 3,568,324 holiday-maker bookings (0 disagree), so
-- the result is the same, without the big snapshot join, without the booking-id parsing,
-- and without history shifting when today's snapshot changes. DIM_GRADE is unique on
-- grade_xid (413 rows), so the join cannot duplicate guest rows.
-- =====================================================================================

use database HAVEN_DATA_SCIENCE_DEV;
use schema PETERZENTAI_LOCAL;

-- -------------------------------------------------------------------------------------
-- 1. Fact base: one row per booked guest per DAY on park, nights AND departure days.
--    Same filters as v1 except that departure-day rows are kept (and flagged).
-- -------------------------------------------------------------------------------------
create or replace view FOOTFALL_SV_GUEST_DAYS_V2 as
with rows_ as (
    select
        to_date(a.on_park_date_xid::string, 'YYYYMMDD')     as on_park_date,
        to_date(a.arrival_date_xid::string, 'YYYYMMDD')     as arrival_date,
        to_date(a.departure_date_xid::string, 'YYYYMMDD')   as departure_date,
        p.park_code,
        a.booking_id,
        a.guest_id,
        gt.stay_type,
        gt.guest_age,
        bt.play_pass,
        g.grade_description,
        g.grade_group
    from haven_store.arrival.fct_park_arrival a
        join haven_store.common.dim_park p using (park_xid)
        join haven_store.arrival.dim_arrival_guest_type gt using (guest_type_xid)
        left join haven_store.arrival.dim_arrival_booking_type bt using (booking_type_xid)
        left join haven_store.holiday.dim_grade g using (grade_xid)
    where gt.stay_type in ('Holiday Maker', 'Private Let')
      and a.on_park_date_xid >= 20230101
      and to_date(a.on_park_date_xid::string, 'YYYYMMDD') < current_date
)
select
    on_park_date,
    park_code,
    booking_id,
    guest_id,
    stay_type,
    guest_age,
    play_pass,
    grade_description,
    grade_group,
    on_park_date = departure_date                                  as is_departure_day,
    on_park_date = arrival_date and on_park_date < departure_date  as is_first_day,
    on_park_date = dateadd(day, -1, departure_date)                as is_last_full_day,
    -- Holiday Maker not on a touring pitch (V3: package type not TOURING - identical, see header)
    stay_type = 'Holiday Maker' and coalesce(grade_group, '') <> 'Touring' as is_self_catering
from rows_;

-- -------------------------------------------------------------------------------------
-- 2. Spine: one row per park per day, 2023-01-01 .. yesterday (same as v1).
-- -------------------------------------------------------------------------------------
create or replace view FOOTFALL_SV_PARK_DAYS_V2 as
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
create or replace semantic view FOOTFALL_ARRIVALS_SV_V2

  tables (
    guests as HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_SV_GUEST_DAYS_V2
      with synonyms = ('guest nights', 'booked guests', 'footfall', 'visitors', 'guests on park', 'stays')
      comment = 'One row per booked guest (Holiday Maker or Private Let) per day on a Haven park, 2023-01-01 to yesterday: every night of the stay plus the departure morning (is_departure_day). Owners are not included.',

    park_days as HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_SV_PARK_DAYS_V2
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
    -- 1 on a night, 0 on a departure morning. EVERY night-based metric sums this, which
    -- is how departure-day rows are kept out of guest_nights and all v1 metrics.
    guests.guest_night as iff(is_departure_day, 0, 1)
      comment = 'One person on park for one night (0 on the departure morning, which is not a night).',
    guests.leaver as iff(is_departure_day, 1, 0)
      comment = 'One person leaving the park that morning (1 on the departure day, else 0).',
    -- private: only used inside distinct counts. NULL on departure days where the count
    -- is about nights.
    private guests.night_booking_ref  as iff(is_departure_day, null, booking_id),
    private guests.booking_ref        as booking_id,
    private guests.night_guest_ref    as iff(is_departure_day, null, guest_id),
    private guests.night_park_day_key as iff(is_departure_day, null, park_code || '|' || to_char(on_park_date))
  )

  dimensions (
    -- when (on the spine, so days without guests exist too)
    park_days.on_park_date as on_park_date
      with synonyms = ('date', 'day', 'night', 'stay date')
      comment = 'The calendar date on park. For nights: the guest is on park that evening. For departure days: the morning the guest leaves.',
    park_days.stay_year    as year(on_park_date)             comment = 'Calendar year.',
    park_days.stay_month   as date_trunc('month', on_park_date)
      with synonyms = ('month') comment = 'First day of the month.',
    park_days.stay_week    as date_trunc('week', on_park_date)
      with synonyms = ('week') comment = 'Monday of the week.',
    park_days.day_of_week  as dayname(on_park_date)
      with synonyms = ('weekday') comment = 'Three-letter day name (Mon..Sun).',
    park_days.is_weekend_night as dayofweekiso(on_park_date) in (5, 6)
      comment = 'True for Friday and Saturday nights.',

    -- where (park_code sits on the spine, the park's attributes on parks).
    -- Sample values (June 2026 DDL feature) list every park in the spine, so Cortex
    -- Analyst can match "Craig Tara" to CT and knows an invented name is not a park.
    park_days.park_code    as park_code
      with synonyms = ('park code')
      comment = 'Two-letter park code, e.g. CT = Craig Tara, DE = Devon Cliffs.'
      sample_values ('AH', 'BD', 'BE', 'BR', 'CC', 'CF', 'CG', 'CH', 'CT', 'CW', 'DE', 'DF', 'FG', 'GR', 'GS', 'GW', 'HA', 'HM', 'HO', 'KP', 'LA', 'LS', 'LY', 'MM', 'OR', 'PC', 'PH', 'PS', 'PV', 'QW', 'RE', 'RP', 'RV', 'SA', 'SE', 'SN', 'SV', 'TP', 'TW', 'WD', 'WM')
      is_enum,
    -- trim(): two DIM_PARK names carry trailing spaces ('Berwick  ', 'Blue Dolphin '),
    -- so v1's park_name = 'Berwick' matched nothing.
    parks.park_name        as trim(park_name)
      with synonyms = ('park', 'site name', 'holiday park')
      comment = 'Park name, e.g. Craig Tara. Filter on the exact name from the sample values.'
      sample_values ('Berwick', 'Blue Dolphin', 'Burnham-on-Sea', 'Caister', 'Cala Gran', 'Cardigan View', 'Church Farm', 'Cleethorpes Beach', 'Combe Haven', 'Craig Tara', 'Devon Cliffs', 'Doniford Bay', 'Far Grange', 'Garreg Wen', 'Golden Sands', 'Greenacres', 'Hafan y Mor', 'Haggerston', 'Hopton', 'Kent Coast', 'Kiln Park', 'Lakeland', 'Littlesea', 'Lydstep Beach', 'Marton Mere', 'Orchards', 'Penally Court', 'Perran Sands', 'Presthaven', 'Primrose Valley', 'Quay West', 'Reighton Sands', 'Riviere Sands', 'Rockley Park', 'Seashore', 'Seaview', 'Seton', 'Skegness', 'Thornwick', 'Weymouth', 'Wild Duck')
      is_enum,
    parks.park_cluster     as park_cluster_name   comment = 'Operational park cluster.',
    parks.park_size        as park_sizing          comment = 'Park size band.',
    parks.region           as director_region
      with synonyms = ('area', 'operating region') comment = 'Operating region of the park director.',

    -- who
    guests.stay_type       as stay_type
      with synonyms = ('guest type', 'segment', 'customer type')
      comment = 'Holiday Maker (booked a Haven holiday) or Private Let (stays in an owner''s caravan let privately). Owners are not in this view.'
      sample_values ('Holiday Maker', 'Private Let')
      is_enum,
    guests.guest_age       as guest_age
      with synonyms = ('age group', 'age band')
      comment = 'Adult, Child or Infant.'
      sample_values ('Adult', 'Child', 'Infant')
      is_enum,
    guests.play_pass       as play_pass
      with synonyms = ('play pass status')
      comment = 'Whether the booking has a play pass: ''Has play pass'' or ''No play pass''.'
      sample_values ('Has play pass', 'No play pass')
      is_enum,

    -- day of the stay (NEW in v2). Each is a flag on the guest row. Filtering on them
    -- (WHERE is_first_day) also drops calendar days without such rows - see ai_sql_generation.
    guests.is_first_day     as is_first_day
      with synonyms = ('arrival day', 'check-in day', 'first night')
      comment = 'True on the first night of a stay (on_park_date = arrival date). A same-day stay with no night is not a first day.',
    guests.is_last_full_day as is_last_full_day
      with synonyms = ('last night')
      comment = 'True on the last night of a stay (the day before departure). A one-night stay is both first day and last full day.',
    guests.is_departure_day as is_departure_day
      with synonyms = ('departure day', 'check-out day', 'leaving day')
      comment = 'True on the departure morning (on_park_date = departure date). Not a night: guest_nights and all night metrics exclude these rows; leavers counts them.',

    -- booking attributes (NEW in v2)
    guests.grade_group      as grade_group
      with synonyms = ('accommodation type', 'accommodation grade', 'grade', 'caravan grade')
      comment = 'Accommodation grade group of the stay: Saver, Bronze, Silver, Gold, Signature, Dog Grades, Accessible, Apts/Chalets, Views Lodges & Select, Glamping, Cottages, Touring (a touring pitch). Reliable for Holiday Makers; for Private Lets it is ''No Match'' on over half the rows.',
    guests.grade            as grade_description
      comment = 'Detailed accommodation grade, e.g. Bronze (2 Bedroom), Gold (3 Bedroom), TEGA (touring electric pitch).',
    guests.is_self_catering as is_self_catering
      with synonyms = ('self catering', 'self-catering', 'caravan holiday')
      comment = 'True for Holiday Maker stays that are not on a touring pitch (grade_group is not Touring). Always false for Private Lets.'
  )

  metrics (
    -- ---- person counts: additive over days, parks, stay types, ages, play pass ----
    guests.guest_nights as sum(guests.guest_night)
      with synonyms = ('guests', 'people on park', 'footfall', 'headcount', 'total nights', 'visitors', 'occupancy')
      comment = 'Person-nights of booked guests (departure mornings excluded). On a single day this is the number of booked guests on park that night. Summed over several days it is person-nights, not distinct people.',
    guests.holiday_maker_nights as sum(iff(guests.stay_type = 'Holiday Maker', guests.guest_night, 0))
      with synonyms = ('holiday makers')
      comment = 'Person-nights of Holiday Makers.',
    guests.private_let_nights as sum(iff(guests.stay_type = 'Private Let', guests.guest_night, 0))
      with synonyms = ('private lets')
      comment = 'Person-nights of Private Let guests.',
    guests.guests_with_play_pass as sum(iff(guests.play_pass = 'Has play pass', guests.guest_night, 0))
      comment = 'Person-nights of guests whose booking has a play pass.',
    guests.first_day_guests as sum(iff(guests.is_first_day, guests.guest_night, 0))
      with synonyms = ('arrivals', 'arriving guests', 'new arrivals', 'check-ins', 'first day guests')
      comment = 'Guests on the first night of their stay (arrivals). V3 FIRST_DAY.',
    guests.last_full_day_guests as sum(iff(guests.is_last_full_day, guests.guest_night, 0))
      with synonyms = ('last night guests', 'guests leaving tomorrow')
      comment = 'Guests on the last night of their stay. V3 LAST_FULL_DAY.',
    guests.leavers as sum(guests.leaver)
      with synonyms = ('departures', 'departing guests', 'check-outs', 'leaving guests')
      comment = 'Guests leaving the park that morning (departure day). Not included in guest_nights. V3 LEAVERS.',
    guests.distinct_guests as count(distinct guests.night_guest_ref)
      with synonyms = ('unique guests', 'distinct people')
      comment = 'Distinct guests with at least one night in the period. Not additive across periods or parks.',
    guests.park_days_with_guests as count(distinct guests.night_park_day_key)
      with synonyms = ('open days', 'occupied days')
      comment = 'Park x days with at least one booked guest staying the night.',

    -- ---- bookings: DISTINCT counts, never sum them across days, parks or ages ----
    guests.bookings_on_park as count(distinct guests.night_booking_ref)
      with synonyms = ('bookings', 'booking count', 'parties', 'number of bookings')
      comment = 'Distinct bookings with at least one guest on park that night (V3 TOTAL_BOOKINGS without owners). A distinct count: a 7-night booking is 1 on each day and 1 over the week, so never sum daily values; query the grain you need.',
    guests.first_day_bookings as count(distinct iff(guests.is_first_day, guests.booking_ref, null))
      with synonyms = ('arriving bookings', 'bookings arriving', 'check-in bookings')
      comment = 'Distinct bookings on their first night (V3 FIRST_DAY_BOOKING_COUNT without owners). Distinct count; do not sum across periods.',
    guests.leaver_bookings as count(distinct iff(guests.is_departure_day, guests.booking_ref, null))
      with synonyms = ('departing bookings', 'bookings leaving', 'check-out bookings')
      comment = 'Distinct bookings leaving that day (V3 LEAVERS_BOOKING_COUNT without owners). Distinct count; do not sum across periods.',

    -- ---- ratios: share of guest_nights, RECOMPUTED at the query grain ----
    -- div0(numerator, guest_nights) over the rows of each result row, so a monthly ratio
    -- is (month's numerator) / (month's guest_nights), NOT the average of daily ratios.
    guests.adults_ratio as div0(sum(iff(guests.guest_age = 'Adult', guests.guest_night, 0)), guests.guest_nights)
      with synonyms = ('adult share', 'share of adults') comment = 'Adult guest-nights / guest_nights (V3 ADULTS_RATIO).',
    guests.children_ratio as div0(sum(iff(guests.guest_age = 'Child', guests.guest_night, 0)), guests.guest_nights)
      with synonyms = ('child share', 'share of children') comment = 'Child guest-nights / guest_nights (V3 CHILDREN_RATIO).',
    guests.infants_ratio as div0(sum(iff(guests.guest_age = 'Infant', guests.guest_night, 0)), guests.guest_nights)
      with synonyms = ('infant share') comment = 'Infant guest-nights / guest_nights (V3 INFANTS_RATIO).',
    guests.play_pass_ratio as div0(guests.guests_with_play_pass, guests.guest_nights)
      with synonyms = ('play pass rate', 'play pass attach rate', 'play pass share') comment = 'Guest-nights with a play pass / guest_nights (V3 PLAYPASS_RATIO).',
    guests.holiday_makers_ratio as div0(guests.holiday_maker_nights, guests.guest_nights)
      with synonyms = ('holiday maker share') comment = 'Holiday Maker nights / guest_nights (V3 HOLIDAY_MAKERS_RATIO).',
    guests.private_lets_ratio as div0(guests.private_let_nights, guests.guest_nights)
      with synonyms = ('private let share') comment = 'Private Let nights / guest_nights (V3 PRIVATE_LETS_RATIO).',
    guests.first_day_ratio as div0(guests.first_day_guests, guests.guest_nights)
      with synonyms = ('arrivals share', 'arrival rate', 'turnover rate') comment = 'first_day_guests / guest_nights (V3 FIRST_DAY_RATIO).',
    guests.leavers_ratio as div0(guests.leavers, guests.guest_nights)
      with synonyms = ('departure rate', 'leavers share') comment = 'leavers / guest_nights of the same day(s) (V3 LEAVERS_RATIO).',
    guests.last_full_day_ratio as div0(guests.last_full_day_guests, guests.guest_nights)
      comment = 'last_full_day_guests / guest_nights (V3 LAST_FULL_DAY_RATIO).',
    guests.first_day_adults_ratio as div0(sum(iff(guests.is_first_day and guests.guest_age = 'Adult', guests.guest_night, 0)), guests.guest_nights)
      comment = 'First-night adults / guest_nights (V3 FIRST_DAY_ADULTS_RATIO). Note the denominator is ALL guest nights, not arrivals.',
    guests.first_day_children_ratio as div0(sum(iff(guests.is_first_day and guests.guest_age = 'Child', guests.guest_night, 0)), guests.guest_nights)
      comment = 'First-night children / guest_nights (V3 FIRST_DAY_CHILDREN_RATIO). Denominator is ALL guest nights.',
    guests.first_day_infants_ratio as div0(sum(iff(guests.is_first_day and guests.guest_age = 'Infant', guests.guest_night, 0)), guests.guest_nights)
      comment = 'First-night infants / guest_nights (V3 FIRST_DAY_INFANTS_RATIO). Denominator is ALL guest nights.',

    -- ---- spine ----
    park_days.park_days as count(park_days.on_park_date)
      with synonyms = ('calendar days', 'days in period')
      comment = 'Park x calendar days in the period, including days with no guests.',

    -- derived across tables: averages over ALL calendar days, zero days included
    avg_guests_per_day as div0(guests.guest_nights, park_days.park_days)
      with synonyms = ('average daily guests', 'average footfall', 'average occupancy')
      comment = 'Average booked guests on park per calendar day, counting days with no guests as zero.',
    -- zero-padded: referencing a park_days metric makes the query return every spine
    -- row, so days without guests come back as 0 (a plain coalesce does not - v1 measured).
    guests_on_park as iff(park_days.park_days > 0, coalesce(guests.guest_nights, 0), null)
      with synonyms = ('guests per day zero filled', 'daily guests incl closed days')
      comment = 'guest_nights on the full park x day grid: days with no booked guests are returned as 0 instead of being absent. Use for daily series and time-series exports.'
  )

  comment = 'Haven footfall v2: booked guests (Holiday Makers + Private Lets) on park per night, arrivals (first day), last full day, leavers (departure day), distinct bookings, self-catering, and ratios; by park, date, stay type, age and play pass. Owners are excluded.'

  ai_sql_generation 'Guest counts are person-nights: on one date guest_nights is the number of booked guests on park that night; over a date range it is person-nights, so for "how many people per day" use avg_guests_per_day or group by on_park_date. This view has Holiday Makers and Private Lets only. Owners are NOT included and cannot be derived here (no owner arrivals, leavers or bookings), so never describe guest_nights as the total population of a park; call it booked guests. "Arrivals" / "check-ins" means first_day_guests (guests on the first night of their stay); "leavers" / "departures" means leavers (guests leaving that morning, not a night, not in guest_nights). A day with no guest rows means zero, not missing data: use avg_guests_per_day, which divides by park_days (all calendar days), for daily averages, and guests_on_park for a daily series that must include zero days. IMPORTANT: a WHERE filter on a guests dimension (stay_type, guest_age, play_pass, is_self_catering, grade_group, is_first_day, is_last_full_day, is_departure_day) also removes calendar days without such rows, so park_days and any per-day average then divide by the wrong number of days. For per-day averages never filter on those: divide the matching metric by park_days, e.g. holiday_maker_nights / park_days, first_day_guests / park_days (average arrivals per day), leavers / park_days (average departures per day). Do not use WHERE is_first_day or WHERE is_departure_day to count arrivals or leavers; use the metrics first_day_guests and leavers. When no ready metric exists for a combination (e.g. private let arrivals per day), define it inside the METRICS clause and divide there, e.g. METRICS sum(iff(guests.stay_type = ''Private Let'' and guests.is_first_day, guests.guest_night, 0)) as pl_arrivals, park_days.park_days, pl_arrivals / park_days.park_days as avg_pl_arrivals_per_day; never aggregate outside the SEMANTIC_VIEW clause. Filters on guest dimensions are fine for totals, ratios and booking counts. Filters on park or date are always safe. Booking metrics (bookings_on_park, first_day_bookings, leaver_bookings) are DISTINCT counts: never sum or average daily booking counts across days, parks or age groups; request the metric at the grain asked (a week, a park) and let the view recount. Self-catering bookings = a booking metric with WHERE guests.is_self_catering. Ratio metrics (*_ratio) are shares of guest_nights recomputed at the query grain: NEVER average ratios across rows (e.g. daily ratios to a month); request the ratio with the coarser dimensions instead. first_day_adults_ratio etc. divide by all guest nights, not by arrivals. Match park names with park_name using the exact sample values (e.g. Craig Tara); if a park name is not in the list, say the park is not in the data rather than guessing. Data covers 2023-01-01 to yesterday; there are no future dates. Round averages to whole people and ratios to 3 decimals.'

  ai_verified_queries (
    guests_by_park_last_7d as (
      question 'How many booked guests were on each park over the last 7 days, and what was the daily average?'
      onboarding_question true
      sql 'select * from semantic_view(HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V2 dimensions parks.park_name metrics guests.guest_nights, avg_guests_per_day where park_days.on_park_date between current_date - 7 and current_date - 1) order by guest_nights desc'
    ),
    daily_mix_by_stay_type as (
      question 'Show daily booked guests by stay type for Craig Tara in August 2026'
      sql 'select * from semantic_view(HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V2 dimensions park_days.on_park_date, guests.stay_type metrics guests.guest_nights where park_days.park_code = ''CT'' and park_days.on_park_date between ''2026-08-01'' and ''2026-08-31'') order by on_park_date, stay_type'
    ),
    arrivals_by_park_last_7d as (
      question 'How many guests arrived at each park in the last 7 days?'
      onboarding_question true
      sql 'select * from semantic_view(HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V2 dimensions parks.park_name metrics guests.first_day_guests, guests.first_day_bookings where park_days.on_park_date between current_date - 7 and current_date - 1) order by first_day_guests desc'
    ),
    arrivals_vs_leavers_daily as (
      question 'Show arrivals and leavers per day at Craig Tara in August 2026'
      sql 'select * from semantic_view(HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V2 dimensions park_days.on_park_date, park_days.day_of_week metrics guests.first_day_guests, guests.leavers, guests.guest_nights, park_days.park_days where park_days.park_code = ''CT'' and park_days.on_park_date between ''2026-08-01'' and ''2026-08-31'') order by on_park_date'
    ),
    avg_arrivals_per_day as (
      question 'What was the average number of holiday maker arrivals per day at Haggerston in November 2025?'
      sql 'select * from semantic_view(HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V2 metrics sum(iff(guests.is_first_day and guests.stay_type = ''Holiday Maker'', guests.guest_night, 0)) as holiday_maker_arrivals, park_days.park_days, holiday_maker_arrivals / park_days.park_days as avg_holiday_maker_arrivals_per_day where park_days.park_code = ''HA'' and park_days.stay_month = ''2025-11-01'')'
    ),
    self_catering_bookings_by_park as (
      question 'How many self-catering holiday maker bookings arrived at each park in August 2026?'
      sql 'select * from semantic_view(HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V2 dimensions parks.park_name metrics guests.first_day_bookings where guests.is_self_catering and park_days.stay_month = ''2026-08-01'') order by first_day_bookings desc'
    ),
    ratios_by_month as (
      question 'What share of guests were children and what was the play pass rate, by month in 2025?'
      sql 'select * from semantic_view(HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FOOTFALL_ARRIVALS_SV_V2 dimensions park_days.stay_month metrics guests.children_ratio, guests.play_pass_ratio, guests.guest_nights where park_days.stay_year = 2025) order by stay_month'
    )
  )
;
