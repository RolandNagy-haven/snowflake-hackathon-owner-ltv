-- Hourly counterpart of FNB_RETAIL_FUTURE_FACTS_DAILY_V4, and the future-known
-- mirror of FNB_RETAIL_FACTS_HOURLY_V4: same 47 columns, same order, same types,
-- over the same 60 days with every unknown nulled out. The date axis is entirely the
-- daily view's -- it starts the day after the last business day the HISTORICAL facts
-- cover, not at current_date, so the two feeds join end-to-end at any hour.
--
-- Structurally this is the SAME view as the historical hourly one -- daily context
-- crossed with the 24 business hours (index 08..31 under the 07:00 separator) --
-- with one simplification and one substitution:
--   * every hourly FACT is null, so the two hourly aggregations over
--     FNB_RETAIL_LINES_V4 (taken_hour, cc_hour) disappear entirely. Nothing here
--     reads a transaction. That is why this view costs about what the future daily
--     view costs and no more.
--   * the window columns and all three open-hour flags come from the published
--     calendar -- see below -- so competition off IS_OPEN_HOUR and off
--     CAL_IS_OPEN_HOUR are now the same quantity.
--
-- ALL DAILY CONTEXT COMES FROM FNB_RETAIL_FUTURE_FACTS_DAILY_V4, for the same
-- reason the historical hourly view reads the historical daily view: the two must
-- not be able to disagree about a window, an attribute or the spine. Everything
-- that view decided is inherited here, including the £1k / 30-active-day spine and
-- the reading of a missing calendar row as CLOSED rather than unknown -- but only
-- inside the venue's published coverage. Read that view's header first; this one
-- adds no policy of its own.
--
-- THE THREE OPEN-HOUR FLAGS ARE ALL THE SAME COLUMN HERE. Only the published
-- calendar exists in advance, so IS_OPEN_HOUR and CORE_IS_OPEN_HOUR PROXY
-- CAL_IS_OPEN_HOUR rather than going null -- which is what makes this view a
-- drop-in for the panel, which reads CORE_IS_OPEN_HOUR. Two consequences:
--   * historically the three differ (raw is the traded window, core trims its
--     quiet edges, cal is the rota). Here they are byte-identical, so no
--     difference between them can be read as evidence of anything.
--   * CORE_IS_OPEN_HOUR here is the PUBLISHED window, which is systematically
--     WIDER than the trimmed traded window it names: it includes hours that will
--     not trade and excludes any unpublished overrun.
--
-- CAL_IS_OPEN_HOUR keeps the historical view's null semantics -- null, not 0,
-- where nothing was published, because a silent calendar is not an assertion that
-- the venue was shut. Under the future daily view's missing-row rule the states
-- are:
--     1 / 0   a window was published for the day; this hour is in it or not
--     0       a CLOSURE was published for the day, so every hour of it is a
--             real, asserted zero
--     null    nothing is known about the day -- either the venue has NO opening
--             calendar at all (19 venues, 13 of them Ice Cream Vans) or the day
--             lies BEYOND the venue's published coverage
-- The last case is why the closure test here is `cal_row_published = false` and
-- not `has_opening_calendar`: see the note at that expression. CAL_ROW_PUBLISHED
-- and CAL_COVERAGE_END are inherited and appended, and together with
-- HAS_OPENING_CALENDAR they resolve all four states -- the daily view's header
-- has the table.
--
-- Row count: 60 days x 272 venues x 24 hours = 391,680.
create or replace view FNB_RETAIL_FUTURE_FACTS_HOURLY_V4 as
with daily as (
    select business_date,
           park_code,
           servicing_venue_name,
           venue_category,
           concept,
           is_main,
           venue_cc_id,
           in_training_dataset,
           has_foh,
           foh_cc_id,
           has_boh,
           boh_cc_id,
           has_opening_calendar,
           cal_open_index,
           cal_close_index,
           cal_operating_hours,
           cal_is_carried,
           cal_row_published,
           cal_coverage_end,
           horizon_day,
           -- Already proxies of the CAL_* window in the daily view, so taking them
           -- from there rather than re-deriving keeps the proxy defined once.
           open_index,
           close_index,
           operating_hours,
           core_open_index,
           core_close_index,
           core_operating_hours
    from FNB_RETAIL_FUTURE_FACTS_DAILY_V4
),
hour_slots as (
    select 8 + seq4() as business_hour
    from table(generator(rowcount => 24))
),

spine as (
    select d.*, h.business_hour
    from daily d
    cross join hour_slots h
),
-- The calendar open-hour flag, computed ONCE. All three of the view's open-hour
-- flags are this same value, so it must not be written out three times.
flagged as (
    select s.*,
           -- close_index is the boundary the venue stops at, so the last hour it
           -- is actually open is close_index - 1. Same convention as the historical
           -- hourly view, and the future daily view publishes cal_close_index on
           -- the same exclusive boundary, so this is a transcription rather than a
           -- re-derivation.
           case when s.cal_open_index is not null
                     then iff(s.business_hour between s.cal_open_index
                                                  and s.cal_close_index - 1, 1, 0)
                -- A published CLOSURE is an asserted zero on every hour. The test
                -- is cal_row_published = false, NOT has_opening_calendar: the
                -- latter is venue-level and stays true past the end of the venue's
                -- published coverage, where nothing is known and a 0 would be an
                -- invented closure. Deferring to the daily view's flag also keeps
                -- the policy stated in exactly one place.
                when s.cal_row_published = false
                     then 0
           end                                                      as cal_is_open_hour
    from spine s
),

assembled as (
    select s.business_date,
           s.business_hour,
           mod(s.business_hour, 24)                                 as hour_of_day,
           s.business_hour >= 24                                    as is_after_midnight,
           s.park_code,
           s.servicing_venue_name,
           s.venue_category,
           s.concept,
           s.is_main,
           s.venue_cc_id,
           s.in_training_dataset,

           s.has_foh,
           s.foh_cc_id,
           s.has_boh,
           s.boh_cc_id,

           -- The two transaction-derived flags PROXY the calendar flag rather
           -- than going null, so a consumer reading CORE_IS_OPEN_HOUR -- which the
           -- panel does -- works unchanged. All three are therefore IDENTICAL
           -- here, where historically they differ; nothing downstream may read a
           -- difference between them as evidence of edge-trimming, and none of
           -- them is a statement that an hour will actually TRADE.
           s.cal_is_open_hour                                       as is_open_hour,
           s.cal_is_open_hour                                       as core_is_open_hour,
           s.cal_is_open_hour,

           s.open_index,
           s.close_index,
           s.operating_hours,
           s.core_open_index,
           s.core_close_index,
           s.core_operating_hours,
           s.has_opening_calendar,
           s.cal_open_index,
           s.cal_close_index,
           s.cal_operating_hours,
           s.cal_is_carried,

           -- The target and everything correlated with it, at hour grain.
           cast(null as number(37,4))                               as foh_serviced_revenue,
           cast(null as number(18,0))                               as foh_serviced_orders,
           cast(null as float)                                      as foh_serviced_items,
           cast(null as number(32,6))                               as foh_serviced_transactions,
           cast(null as number(37,4))                               as boh_serviced_revenue,
           cast(null as number(18,0))                               as boh_serviced_orders,
           cast(null as float)                                      as boh_serviced_items,
           cast(null as number(32,6))                               as boh_serviced_transactions,

           cast(null as number(37,4))                               as foh_taken_revenue,
           cast(null as number(18,0))                               as foh_taken_orders,
           cast(null as float)                                      as foh_taken_items,
           cast(null as number(32,6))                               as foh_taken_transactions,
           cast(null as number(37,4))                               as boh_taken_revenue,
           cast(null as number(18,0))                               as boh_taken_orders,
           cast(null as float)                                      as boh_taken_items,
           cast(null as number(32,6))                               as boh_taken_transactions,

           -- Appended after the historical columns, as in the future daily view.
           s.cal_row_published,
           s.cal_coverage_end,
           s.horizon_day

    from flagged s
)

-- Competition recomputed per hour: how many other training-set venues in the park
-- have this same hour inside their PUBLISHED window. The historical view counts
-- hours inside the TRADED window, so this is the same definitional skew the future
-- daily view carries -- see its header. A venue with no calendar contributes
-- nothing to the pool (coalesce to 0) but still receives a count, which is how the
-- daily view treats the same case.
select a.* exclude (cal_row_published, cal_coverage_end, horizon_day),

       case when a.in_training_dataset then
            sum(iff(a.in_training_dataset, coalesce(a.cal_is_open_hour, 0), 0))
              over (partition by a.park_code, a.business_date, a.business_hour)
            - iff(a.in_training_dataset, coalesce(a.cal_is_open_hour, 0), 0)
       end::number(14,0)                                            as other_venues_open,

       case when a.in_training_dataset then
            sum(iff(a.in_training_dataset, coalesce(a.cal_is_open_hour, 0), 0))
              over (partition by a.park_code, a.business_date, a.business_hour,
                                 coalesce(a.venue_category, 'OTHER'))
            - iff(a.in_training_dataset, coalesce(a.cal_is_open_hour, 0), 0)
       end::number(14,0)                                            as same_category_venues_open,

       a.cal_row_published,
       a.cal_coverage_end,
       a.horizon_day

from assembled a
