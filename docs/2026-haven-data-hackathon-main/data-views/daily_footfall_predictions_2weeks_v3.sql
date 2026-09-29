-- daily_footfall_predictions_2weeks_v3
-- Identical in every respect to daily_footfall_predictions_v3 EXCEPT the source
-- table: this one reads ...FOOTFALL_PREDICTION_RESULTS_PUBLISHED_2WEEKS, the
-- 2-week publication, where that view reads ...FOOTFALL_PREDICTION_RESULTS_PUBLISHED.
-- Same columns, same grain, same tie-break, same derivations. Any change to the
-- logic belongs in both files.
--
-- The predicted counterpart to daily_footfall_facts_v3: the published footfall
-- predictions pivoted from long metric rows into the same column names the
-- historical view uses, at the same (park_code, on_park_date) grain.
--
-- SOURCE. HAVEN_DATA_SCIENCE.ROTA_SCHEDULING.FOOTFALL_PREDICTION_RESULTS_PUBLISHED_2WEEKS,
-- one row per (prediction_head, park, metric, on_park_date). METRIC values are the
-- historical view's column names verbatim, which is what makes the pivot a rename
-- rather than a mapping.
--
-- SPAN. Every on_park_date the table holds -- measured 2026-09-02, 2025-09-06 to
-- 2026-09-15. That is a rolling 14-day forward block (current_date .. +13, 41 parks,
-- 11 metrics, complete) preceded by a year of already-elapsed predictions still
-- carrying their original values. IS_FUTURE separates the two; the elapsed rows are
-- what makes the view usable for back-testing against daily_footfall_facts_v3.
--
-- NOT UNION-COMPATIBLE WITH daily_footfall_facts_v3, by decision. Columns that are
-- neither predicted nor cleanly derivable are OMITTED rather than nulled:
-- total_nights_legacy, total_owners_estimated, first_day_owners, leavers_owners,
-- the first_day / leavers holiday-maker and private-let splits, the first_day
-- play-pass split, and every booking-count column except the one predicted
-- self-catering count. Consumers must select by name, not by position.
--
-- ONE ROW PER METRIC, CHOSEN. The table is ALMOST a single timeline -- 39 duplicate
-- (park, metric, on_park_date) keys out of 111,381, including PS TOTAL_ADULTS on
-- three future dates -- so a tie-break is still required. Newest prediction_date
-- wins; model_id breaks the remainder deterministically. Without this a pivot using
-- max() would silently pick the larger value.
--
-- A MISSING METRIC IS NULL, NEVER ZERO. Coverage is uneven: TOTAL_NIGHTS /
-- TOTAL_ADULTS / TOTAL_CHILDREN cover all 41 parks over the forward block, but
-- FIRST_DAY, LEAVERS and the booking count cover 37 and TOTAL_OWNERS /
-- TOTAL_PLAY_PASS / TOTAL_HOLIDAY_MAKERS cover 38. Coalescing to 0 would assert an
-- empty park where the truth is an unrun head. METRICS_PRESENT counts how many of
-- the 11 heads resolved, so a partially-covered park-day is visible without
-- null-checking every column.
--
-- HEADS ARE INDEPENDENT AND ARE NOT RECONCILED. Predicted total_adults +
-- total_children + total_infants does not equal predicted total_nights, and neither
-- does holiday_makers + private_lets. Each head is published as predicted and the
-- ratios are computed from the raw values, so the age ratios do not sum to exactly
-- 1. The discrepancy is the model's, and it is left visible rather than scaled away.
--
-- THREE COLUMNS ARE DERIVED, NOT PREDICTED -----------------------------------
--
-- LAST_FULL_DAY = LEAVERS(d+1). A guest whose last full day is d departs on d+1, so
-- the historical view's last_full_day (on_park rows with departure = d+1) and its
-- leavers on d+1 (rows with on_park = departure = d+1) count the same population.
-- Measured over 18,482 park-days since 2025-01-01: 74.8% exact agreement, mean
-- absolute difference 0.90 guests on park-days in the hundreds. The residual is
-- arrival-table noise, not a definition mismatch. The lead is guarded on the next
-- row actually being d+1, so the gap between the elapsed block and the forward block
-- does not leak a value across it -- which costs each park its final horizon day.
--
-- TOTAL_NO_PLAY_PASS = TOTAL_NIGHTS - TOTAL_PLAY_PASS. The head existed until
-- 2026-07-14 and is absent forward, so the complement is the only way to carry the
-- column. Being a difference of two independent heads it can go slightly negative;
-- left unclamped, because flooring it at zero would hide a disagreement between
-- heads that is worth seeing.
--
-- FIRST_DAY_{ADULTS,CHILDREN,INFANTS} = FIRST_DAY x the stay-wide age share. The
-- apportionment was measured against the historical view over park-days with
-- first_day > 50 since 2025-01-01: correlation 0.88 between the first-day adult
-- share and the stay-wide adult share, mean bias +0.005 adults, -0.004 children,
-- -0.002 infants. Small enough to publish.
--
-- The same trick was measured and REJECTED for three other splits, which is why
-- those columns are absent rather than estimated:
--   first_day_play_pass          corr 0.47, bias -0.123  -- first-day play-pass
--                                share runs 12pp below the stay-wide share
--   first_day_holiday_makers     corr 0.63, bias -0.037
--   leavers_holiday_makers       corr 0.39, bias -0.069
-- The play-pass one is the omission worth revisiting: the bias is large but looks
-- stable, so a fitted park-level correction would probably recover it. That needs
-- its own measurement, not a guess here.
--
-- Values are FLOAT, not integer. Single-model heads happen to emit whole numbers but
-- ensemble rows do not (1170.595...), and rounding would be a second opinion on top
-- of the model's.
create or replace view daily_footfall_predictions_2weeks_v3 as
with ranked as (
    select park_code,
           on_park_date,
           metric,
           predicted,
           prediction_date,
           model_id,
           row_number() over (
               partition by park_code, metric, on_park_date
               order by prediction_date desc, model_id)          as pick_rank
    from HAVEN_DATA_SCIENCE.ROTA_SCHEDULING.FOOTFALL_PREDICTION_RESULTS_PUBLISHED_2WEEKS
),
best as (
    select * from ranked where pick_rank = 1
),

-- One row per park-day, each metric landing in its historical column name.
-- max() over a single surviving row per metric is a pivot, not an aggregation.
pivoted as (
    select park_code,
           on_park_date,
           max(case when metric = 'TOTAL_NIGHTS'          then predicted end) as total_nights,
           max(case when metric = 'TOTAL_HOLIDAY_MAKERS'  then predicted end) as total_holiday_makers,
           max(case when metric = 'TOTAL_PRIVATE_LETS'    then predicted end) as total_private_lets,
           max(case when metric = 'TOTAL_OWNERS'          then predicted end) as total_owners,
           max(case when metric = 'TOTAL_ADULTS'          then predicted end) as total_adults,
           max(case when metric = 'TOTAL_CHILDREN'        then predicted end) as total_children,
           max(case when metric = 'TOTAL_INFANTS'         then predicted end) as total_infants,
           max(case when metric = 'TOTAL_PLAY_PASS'       then predicted end) as total_play_pass,
           max(case when metric = 'FIRST_DAY'             then predicted end) as first_day,
           max(case when metric = 'LEAVERS'               then predicted end) as leavers,
           max(case when metric = 'FIRST_DAY_BOOKING_COUNT_HOLIDAY_MAKERS_SELF_CATERING'
                                                          then predicted end) as first_day_booking_count_holiday_makers_self_catering,
           max(prediction_date)                                               as prediction_date,
           -- Counts the heads that land in a column, so the ceiling is 11. A plain
           -- count(*) would reach 12 on elapsed rows, where the retired
           -- TOTAL_NO_PLAY_PASS head is still present in the source but is not
           -- pivoted (total_no_play_pass is derived instead).
           count(case when metric in (
                    'TOTAL_NIGHTS', 'TOTAL_HOLIDAY_MAKERS', 'TOTAL_PRIVATE_LETS',
                    'TOTAL_OWNERS', 'TOTAL_ADULTS', 'TOTAL_CHILDREN', 'TOTAL_INFANTS',
                    'TOTAL_PLAY_PASS', 'FIRST_DAY', 'LEAVERS',
                    'FIRST_DAY_BOOKING_COUNT_HOLIDAY_MAKERS_SELF_CATERING')
                then 1 end)                                                    as metrics_present,
           array_to_string(array_sort(array_agg(distinct model_id)), ',')      as model_ids
    from best
    group by all
),

-- LEAVERS at d+1 becomes LAST_FULL_DAY at d. The date guard is what stops the
-- elapsed block's last day from borrowing the forward block's first.
derived as (
    select p.*,
           case when lead(p.on_park_date) over (partition by p.park_code
                                                order by p.on_park_date)
                     = dateadd(day, 1, p.on_park_date)
                then lead(p.leavers) over (partition by p.park_code
                                           order by p.on_park_date)
           end                                                    as last_full_day
    from pivoted p
)

select d.on_park_date                                             as ts,
       d.on_park_date                                             as on_park_date,
       d.park_code,

       -- Predicted heads, as published.
       d.total_nights,
       d.total_holiday_makers,
       d.total_private_lets,
       d.total_owners,
       d.total_adults,
       d.total_children,
       d.total_infants,
       d.total_play_pass,
       -- Complement of an independent head: can go slightly negative. See header.
       d.total_nights - d.total_play_pass                         as total_no_play_pass,
       d.first_day,
       d.leavers,
       -- Derived from next day's leavers; null on each park's last covered day.
       d.last_full_day,
       d.first_day_booking_count_holiday_makers_self_catering,

       -- First-day age split, apportioned by the stay-wide age share (corr 0.88).
       d.first_day * div0(d.total_adults,   d.total_nights)       as first_day_adults,
       d.first_day * div0(d.total_children, d.total_nights)       as first_day_children,
       d.first_day * div0(d.total_infants,  d.total_nights)       as first_day_infants,

       -- Ratios, denominator total_nights throughout, exactly as the historical
       -- view defines them: div0 so a zero total_nights gives 0, while a missing
       -- numerator still propagates null.
       div0(d.total_adults,         d.total_nights)               as adults_ratio,
       div0(d.total_children,       d.total_nights)               as children_ratio,
       div0(d.total_infants,        d.total_nights)               as infants_ratio,
       div0(d.total_play_pass,      d.total_nights)               as playpass_ratio,
       div0(d.total_holiday_makers, d.total_nights)               as holiday_makers_ratio,
       div0(d.total_private_lets,   d.total_nights)               as private_lets_ratio,
       div0(d.total_owners,         d.total_nights)               as owners_ratio,
       div0(d.first_day,            d.total_nights)               as first_day_ratio,
       div0(d.leavers,              d.total_nights)               as leavers_ratio,
       div0(d.last_full_day,        d.total_nights)               as last_full_day_ratio,
       -- Algebraically div0(first_day_adults, total_nights); written as the product
       -- of two ratios so the apportionment stays visible.
       div0(d.first_day, d.total_nights) * div0(d.total_adults,   d.total_nights)
                                                                  as first_day_adults_ratio,
       div0(d.first_day, d.total_nights) * div0(d.total_children, d.total_nights)
                                                                  as first_day_children_ratio,
       div0(d.first_day, d.total_nights) * div0(d.total_infants,  d.total_nights)
                                                                  as first_day_infants_ratio,

       -- Provenance, appended after the historical column names so a by-name
       -- reader is unaffected.
       d.prediction_date,
       d.model_ids,
       datediff(day, d.prediction_date, d.on_park_date)           as horizon_day,
       d.on_park_date >= current_date                             as is_future,
       d.metrics_present

from derived d
order by d.park_code, d.on_park_date desc
