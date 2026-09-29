create or replace view DAILY_FOOTFALL_FACTS_V3(
	TS,
	ON_PARK_DATE,
	PARK_CODE,
	TOTAL_NIGHTS,
	TOTAL_NIGHTS_LEGACY,
	TOTAL_HOLIDAY_MAKERS,
	TOTAL_PRIVATE_LETS,
	TOTAL_OWNERS,
	TOTAL_ADULTS,
	TOTAL_CHILDREN,
	TOTAL_INFANTS,
	TOTAL_PLAY_PASS,
	TOTAL_NO_PLAY_PASS,
	FIRST_DAY,
	FIRST_DAY_HOLIDAY_MAKERS,
	FIRST_DAY_OWNERS,
	FIRST_DAY_PRIVATE_LETS,
	FIRST_DAY_ADULTS,
	FIRST_DAY_CHILDREN,
	FIRST_DAY_INFANTS,
	FIRST_DAY_PLAY_PASS,
	FIRST_DAY_NO_PLAY_PASS,
	LAST_FULL_DAY,
	FIRST_DAY_BOOKING_COUNT,
	FIRST_DAY_BOOKING_COUNT_HOLIDAY_MAKERS,
	FIRST_DAY_BOOKING_COUNT_HOLIDAY_MAKERS_SELF_CATERING,
	FIRST_DAY_BOOKING_COUNT_OWNERS,
	FIRST_DAY_BOOKING_COUNT_PRIVATE_LETS,
	TOTAL_BOOKINGS,
	TOTAL_BOOKINGS_HOLIDAY_MAKERS,
	TOTAL_BOOKINGS_HOLIDAY_MAKERS_SELF_CATERING,
	TOTAL_BOOKINGS_OWNERS,
	TOTAL_BOOKINGS_PRIVATE_LETS,
	LEAVERS,
	LEAVERS_HOLIDAY_MAKERS,
	LEAVERS_OWNERS,
	LEAVERS_PRIVATE_LETS,
	LEAVERS_BOOKING_COUNT,
	LEAVERS_BOOKING_COUNT_HOLIDAY_MAKERS,
	LEAVERS_BOOKING_COUNT_HOLIDAY_MAKERS_SELF_CATERING,
	LEAVERS_BOOKING_COUNT_OWNERS,
	LEAVERS_BOOKING_COUNT_PRIVATE_LETS,
	ADULTS_RATIO,
	CHILDREN_RATIO,
	INFANTS_RATIO,
	PLAYPASS_RATIO,
	HOLIDAY_MAKERS_RATIO,
	PRIVATE_LETS_RATIO,
	OWNERS_RATIO,
	FIRST_DAY_RATIO,
	LEAVERS_RATIO,
	LAST_FULL_DAY_RATIO,
	FIRST_DAY_ADULTS_RATIO,
	FIRST_DAY_CHILDREN_RATIO,
	FIRST_DAY_INFANTS_RATIO
) as
with base as (
    select
        to_date(a.on_park_date_xid::string, 'YYYYMMDD') as on_park_date,
        p.park_code,
        -- legacy: raw row count from arrival table, includes owner rows
        count(*) as total_nights_legacy,
        -- new total_nights  only includes Holiday Makers + Private Lets, excludes Owners (arrival source is unreliable for owner classification and age data)
        sum(case when gt.stay_type in ('Holiday Maker','Private Let') then 1 else 0 end) as total_nights,
        sum(case when gt.stay_type = 'Holiday Maker' then 1 else 0 end) as total_holiday_makers,
        sum(case when gt.stay_type = 'Private Let'   then 1 else 0 end) as total_private_lets,
        -- age splits restricted to booked guests (HM + PL); owner age data is unreliable
        sum(case when gt.guest_age = 'Adult'  and gt.stay_type in ('Holiday Maker','Private Let') then 1 else 0 end) as total_adults,
        sum(case when gt.guest_age = 'Child'  and gt.stay_type in ('Holiday Maker','Private Let') then 1 else 0 end) as total_children,
        sum(case when gt.guest_age = 'Infant' and gt.stay_type in ('Holiday Maker','Private Let') then 1 else 0 end) as total_infants,
        sum(case when bt.play_pass = 'Has play pass' and gt.stay_type in ('Holiday Maker','Private Let') then 1 else 0 end) as total_play_pass,
        sum(case when bt.play_pass = 'No play pass'  and gt.stay_type in ('Holiday Maker','Private Let') then 1 else 0 end) as total_no_play_pass,

        sum(case when a.on_park_date_xid = a.arrival_date_xid and gt.stay_type = 'Holiday Maker' then 1 else 0 end) as first_day_holiday_makers,
        sum(case when a.on_park_date_xid = a.arrival_date_xid and gt.stay_type = 'Owner'         then 1 else 0 end) as first_day_owners,
        sum(case when a.on_park_date_xid = a.arrival_date_xid and gt.stay_type = 'Private Let'   then 1 else 0 end) as first_day_private_lets,
        sum(case when a.on_park_date_xid = a.arrival_date_xid and gt.stay_type in ('Holiday Maker','Private Let') then 1 else 0 end) as first_day,
        sum(case when to_date(a.on_park_date_xid::string, 'YYYYMMDD') = dateadd('day', -1, to_date(a.departure_date_xid::string, 'YYYYMMDD')) and gt.stay_type in ('Holiday Maker','Private Let') then 1 else 0 end) as last_full_day,
        sum(case when a.on_park_date_xid = a.arrival_date_xid and gt.stay_type in ('Holiday Maker','Private Let') and gt.guest_age = 'Adult'         then 1 else 0 end) as first_day_adults,
        sum(case when a.on_park_date_xid = a.arrival_date_xid and gt.stay_type in ('Holiday Maker','Private Let') and gt.guest_age = 'Child'         then 1 else 0 end) as first_day_children,
        sum(case when a.on_park_date_xid = a.arrival_date_xid and gt.stay_type in ('Holiday Maker','Private Let') and gt.guest_age = 'Infant'        then 1 else 0 end) as first_day_infants,
        sum(case when a.on_park_date_xid = a.arrival_date_xid and gt.stay_type in ('Holiday Maker','Private Let') and bt.play_pass = 'Has play pass' then 1 else 0 end) as first_day_play_pass,
        sum(case when a.on_park_date_xid = a.arrival_date_xid and gt.stay_type in ('Holiday Maker','Private Let') and bt.play_pass = 'No play pass'  then 1 else 0 end) as first_day_no_play_pass,


        count(distinct case when a.on_park_date_xid = a.arrival_date_xid then a.booking_id end) as first_day_booking_count,
        count(distinct case when a.on_park_date_xid = a.arrival_date_xid and gt.stay_type = 'Holiday Maker' then a.booking_id end) as first_day_booking_count_holiday_makers,
        count(distinct case when a.on_park_date_xid = a.arrival_date_xid and gt.stay_type = 'Holiday Maker' and coalesce(pt.package_type, '') <> 'TOURING' then a.booking_id end) as first_day_booking_count_holiday_makers_self_catering,
        count(distinct case when a.on_park_date_xid = a.arrival_date_xid and gt.stay_type = 'Owner'       then a.booking_id end) as first_day_booking_count_owners,
        count(distinct case when a.on_park_date_xid = a.arrival_date_xid and gt.stay_type = 'Private Let' then a.booking_id end) as first_day_booking_count_private_lets,
        count(distinct a.booking_id) as total_bookings,
        count(distinct case when gt.stay_type = 'Holiday Maker' then a.booking_id end) as total_bookings_holiday_makers,
        count(distinct case when gt.stay_type = 'Holiday Maker' and coalesce(pt.package_type, '') <> 'TOURING' then a.booking_id end) as total_bookings_holiday_makers_self_catering,
        count(distinct case when gt.stay_type = 'Owner'       then a.booking_id end) as total_bookings_owners,
        count(distinct case when gt.stay_type = 'Private Let' then a.booking_id end) as total_bookings_private_lets
    from haven_store.arrival.fct_park_arrival a
        left join haven_store.common.dim_park p using (park_xid)
        left outer join haven_store.arrival.dim_arrival_guest_type gt using (guest_type_xid)
        left outer join haven_store.arrival.dim_arrival_booking_type bt using (booking_type_xid)
        left outer join haven_store.holiday.fct_holiday_bookings h
            on try_cast(split_part(a.booking_id, ':', 2) as number) = h.booking_id
            and h.snapshot_date = current_date()
        left outer join haven_store.holiday.dim_package_type pt
            on h.package_type_xid = pt.package_type_xid
    where a.on_park_date_xid <> a.departure_date_xid
      and a.on_park_date_xid >= '20230101'
      and to_date(a.on_park_date_xid::string, 'YYYYMMDD') < current_date
    group by
        to_date(a.on_park_date_xid::string, 'YYYYMMDD'),
        p.park_code
),

leavers as (
    select
        to_date(a.on_park_date_xid::string, 'YYYYMMDD') as on_park_date,
        p.park_code,
        sum(case when gt.stay_type in ('Holiday Maker', 'Private Let') then 1 else 0 end) as leavers,
        sum(case when gt.stay_type = 'Holiday Maker' then 1 else 0 end) as leavers_holiday_makers,
        sum(case when gt.stay_type = 'Owner'         then 1 else 0 end) as leavers_owners,
        sum(case when gt.stay_type = 'Private Let'   then 1 else 0 end) as leavers_private_lets,
        count(distinct a.booking_id) as leavers_booking_count,
        count(distinct case when gt.stay_type = 'Holiday Maker' then a.booking_id end) as leavers_booking_count_holiday_makers,
        count(distinct case when gt.stay_type = 'Holiday Maker' and coalesce(pt.package_type, '') <> 'TOURING' then a.booking_id end) as leavers_booking_count_holiday_makers_self_catering,
        count(distinct case when gt.stay_type = 'Owner'       then a.booking_id end) as leavers_booking_count_owners,
        count(distinct case when gt.stay_type = 'Private Let' then a.booking_id end) as leavers_booking_count_private_lets
    from haven_store.arrival.fct_park_arrival a
        left join haven_store.common.dim_park p using (park_xid)
        left outer join haven_store.arrival.dim_arrival_guest_type gt using (guest_type_xid)
        left outer join haven_store.holiday.fct_holiday_bookings h
            on try_cast(split_part(a.booking_id, ':', 2) as number) = h.booking_id
            and h.snapshot_date = current_date()
        left outer join haven_store.holiday.dim_package_type pt
            on h.package_type_xid = pt.package_type_xid
    where a.on_park_date_xid = a.departure_date_xid
      and a.on_park_date_xid >= '20230101'
    group by
        to_date(a.on_park_date_xid::string, 'YYYYMMDD'),
        p.park_code
),

-- Fraser (heads-on-park) source — Transacted logic only.
-- heads is a fractional weekly unit; multiply by 7 to obtain a daily person count.
-- Transacted = owners inferred from EPOS/loyalty transactions × fixed ~4-person-per-van rate.
-- This is the canonical owner headcount: strongest correlation with account counts (r=0.89),
-- no data quality outliers across any park or year.
fraser_transacted as (
    select
        c.day_date                          as on_park_date,
        p.park_code,
        sum(h.heads * 7)::float             as total_owners
    from haven_store.heads_on_park.fct_heads_on_park h
        join haven_store.heads_on_park.dim_on_park_guest_type gt using (guest_type_xid)
        join haven_store.common.dim_calendar c using (date_xid)
        join haven_store.common.dim_park p using (park_xid)
    where gt.guest_type = 'Owners'
      and gt.calculation_logic in ('Transacted', 'Registered & Transacted')
    group by c.day_date, p.park_code
),

-- Fraser (heads-on-park) source — Estimated logic only.
-- Model-based estimate derived from van census × fixed occupancy coefficient (~3.9 people/van).
-- Exposed separately as total_owners_estimated for diagnostic and fallback purposes.
-- Known data quality issue: anomalously high van_count values in source for DF (Nov 2023,
-- Mar 2026) and LS (Nov 2024) cause spikes — investigate upstream in fct_heads_on_park.
fraser_estimated as (
    select
        c.day_date                          as on_park_date,
        p.park_code,
        sum(h.heads * 7)::float             as total_owners_estimated
    from haven_store.heads_on_park.fct_heads_on_park h
        join haven_store.heads_on_park.dim_on_park_guest_type gt using (guest_type_xid)
        join haven_store.common.dim_calendar c using (date_xid)
        join haven_store.common.dim_park p using (park_xid)
    where gt.guest_type = 'Owners'
      and gt.calculation_logic = 'Estimated'
    group by c.day_date, p.park_code
),

auto_generated_days_calendar as (
    select on_park_date
    from (
        select dateadd('day', seq4(), '2023-01-01') as on_park_date
        from table(generator(rowcount => 2857))
    )
    where on_park_date < current_date()
),

park_codes as (
    select distinct park_code from base
),

parks_and_dates as (
    select c.on_park_date, p.park_code
    from auto_generated_days_calendar c
    cross join park_codes p
)

select
    pd.on_park_date                                                             as ts,
    pd.on_park_date                                                             as on_park_date,
    pd.park_code,
    -- legacy: raw arrival-table row count (includes owners) — kept for back-compat
    coalesce(b.total_nights, 0)                                                 as total_nights,
    coalesce(b.total_nights_legacy, 0)                                          as total_nights_legacy,
    coalesce(b.total_holiday_makers, 0)                                         as total_holiday_makers,
    coalesce(b.total_private_lets, 0)                                           as total_private_lets,
    -- canonical: booked guests only (HM + PL); owners excluded due to arrival-source unreliability
    -- owners from fraser Transacted logic (canonical owner headcount)
    coalesce(ft.total_owners, 0)                                                as total_owners,
    -- age splits over booked guests only (HM + PL); owners excluded
    coalesce(b.total_adults, 0)                                                 as total_adults,
    coalesce(b.total_children, 0)                                               as total_children,
    coalesce(b.total_infants, 0)                                                as total_infants,
    coalesce(b.total_play_pass, 0)                                              as total_play_pass,
    coalesce(b.total_no_play_pass, 0)                                           as total_no_play_pass,
    coalesce(b.first_day, 0)                                                    as first_day,
    coalesce(b.first_day_holiday_makers, 0)                                     as first_day_holiday_makers,
    coalesce(b.first_day_owners, 0)                                             as first_day_owners,
    coalesce(b.first_day_private_lets, 0)                                       as first_day_private_lets,
    coalesce(b.first_day_adults, 0)                                             as first_day_adults,
    coalesce(b.first_day_children, 0)                                           as first_day_children,
    coalesce(b.first_day_infants, 0)                                            as first_day_infants,
    coalesce(b.first_day_play_pass, 0)                                          as first_day_play_pass,
    coalesce(b.first_day_no_play_pass, 0)                                       as first_day_no_play_pass,
    coalesce(b.last_full_day, 0)                                                as last_full_day,
    coalesce(b.first_day_booking_count, 0)                                      as first_day_booking_count,
    coalesce(b.first_day_booking_count_holiday_makers, 0)                       as first_day_booking_count_holiday_makers,
    coalesce(b.first_day_booking_count_holiday_makers_self_catering, 0)         as first_day_booking_count_holiday_makers_self_catering,
    coalesce(b.first_day_booking_count_owners, 0)                               as first_day_booking_count_owners,
    coalesce(b.first_day_booking_count_private_lets, 0)                         as first_day_booking_count_private_lets,
    coalesce(b.total_bookings, 0)                                               as total_bookings,
    coalesce(b.total_bookings_holiday_makers, 0)                                as total_bookings_holiday_makers,
    coalesce(b.total_bookings_holiday_makers_self_catering, 0)                  as total_bookings_holiday_makers_self_catering,
    coalesce(b.total_bookings_owners, 0)                                        as total_bookings_owners,
    coalesce(b.total_bookings_private_lets, 0)                                  as total_bookings_private_lets,
    coalesce(l.leavers, 0)                                                      as leavers,
    coalesce(l.leavers_holiday_makers, 0)                                       as leavers_holiday_makers,
    coalesce(l.leavers_owners, 0)                                               as leavers_owners,
    coalesce(l.leavers_private_lets, 0)                                         as leavers_private_lets,
    coalesce(l.leavers_booking_count, 0)                                        as leavers_booking_count,
    coalesce(l.leavers_booking_count_holiday_makers, 0)                         as leavers_booking_count_holiday_makers,
    coalesce(l.leavers_booking_count_holiday_makers_self_catering, 0)           as leavers_booking_count_holiday_makers_self_catering,
    coalesce(l.leavers_booking_count_owners, 0)                                 as leavers_booking_count_owners,
    coalesce(l.leavers_booking_count_private_lets, 0)                           as leavers_booking_count_private_lets,

    -- Derived ratios (0 when denominator is 0). Denominator = total_nights (HM + PL).
    -- Age shares within booked guests
    div0(coalesce(b.total_adults, 0),         coalesce(b.total_nights, 0)) as adults_ratio,
    div0(coalesce(b.total_children, 0),       coalesce(b.total_nights, 0)) as children_ratio,
    div0(coalesce(b.total_infants, 0),        coalesce(b.total_nights, 0)) as infants_ratio,
    -- Play-pass attach rate over booked guests
    div0(coalesce(b.total_play_pass, 0),      coalesce(b.total_nights, 0)) as playpass_ratio,
    -- Segment shares within booked guests
    div0(coalesce(b.total_holiday_makers, 0), coalesce(b.total_nights, 0)) as holiday_makers_ratio,
    div0(coalesce(b.total_private_lets, 0),   coalesce(b.total_nights, 0)) as private_lets_ratio,
    -- Owner heads relative to booked guests (cross-source ratio; can exceed 1 at owner-heavy parks)
    div0(coalesce(ft.total_owners, 0),        coalesce(b.total_nights, 0)) as owners_ratio,
    -- First day, last full day, and leaver ratios, playpass ratio
    div0(coalesce(b.first_day, 0),           coalesce(b.total_nights, 0)) as first_day_ratio,
    div0(coalesce(l.leavers, 0),            coalesce(b.total_nights, 0)) as leavers_ratio,
    div0(coalesce(b.last_full_day, 0),       coalesce(b.total_nights, 0)) as last_full_day_ratio,
    -- First day age group ratios over total_nights
    div0(coalesce(b.first_day_adults, 0), coalesce(b.total_nights, 0)) as first_day_adults_ratio,
    div0(coalesce(b.first_day_children, 0), coalesce(b.total_nights, 0)) as first_day_children_ratio,
    div0(coalesce(b.first_day_infants, 0), coalesce(b.total_nights, 0)) as first_day_infants_ratio
from parks_and_dates pd
    left join base b             on pd.on_park_date = b.on_park_date  and pd.park_code = b.park_code
    left join leavers l          on pd.on_park_date = l.on_park_date  and pd.park_code = l.park_code
    left join fraser_transacted ft on pd.on_park_date = ft.on_park_date and pd.park_code = ft.park_code
    left join fraser_estimated  fe on pd.on_park_date = fe.on_park_date and pd.park_code = fe.park_code
order by pd.park_code, pd.on_park_date desc;
