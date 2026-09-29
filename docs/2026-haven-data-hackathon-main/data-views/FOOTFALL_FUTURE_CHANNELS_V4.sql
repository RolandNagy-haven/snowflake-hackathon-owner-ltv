-- FOOTFALL_FUTURE_CHANNELS_V4
-- The future known-covariate counterpart to the footfall training snapshot
-- src/data/training_data/footfall/historical_values.parquet, built entirely in SQL
-- so true-future inference no longer needs the pandas merge chain in
-- src/projects/nn_footfall/nn_footfall/data/save_training_data.py.
--
-- Read it as "historical_values.parquet continued forward": SAME COLUMN NAMES, same
-- order, minus every weather column, with the footfall channel filled from published
-- predictions where a head exists and left NULL where it does not.
--
-- THE SPINE: HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_PREDICTIONS_V3, restricted
-- to on_park_date >= current_date. That view already resolves one prediction per
-- (park, metric, day) and pivots the metrics into the historical column names, so
-- everything here is join-and-rename, never re-aggregation.
--   Measured 2026-09-03, after the source was repointed from
--   FOOTFALL_PREDICTION_RESULTS_PUBLISHED_2WEEKS to ..._PUBLISHED: 37 parks x 27 days
--   = 999 rows, 2026-09-03..2026-09-29, a COMPLETE grid.
--   The forward block is a ROLLING window of whatever the publisher last wrote -- 27
--   days on that date, up from 13 under _2WEEKS. No horizon is hardcoded below; the
--   view is exactly as long as the predictions are. If a consumer needs a guaranteed
--   span it must pad, and that padding is its decision, not this view's.
--   The elapsed prediction rows (a year of them, IS_FUTURE = false) are deliberately
--   EXCLUDED. This is a future frame. Back-testing reads the source view directly.
--
-- THE EXTRA SPAN IS STALE, NOT FRESHER -- the one thing to know before trusting this.
-- Under _2WEEKS the forward rows were short-horizon and current. Under _PUBLISHED
-- every forward row carries HORIZON_DAY of 24..27 and a PREDICTION_DATE 1..25 days
-- old (2026-08-09..2026-09-02 on the measurement date, stepping ~3-4 days at a time,
-- 5 distinct MODEL_IDS across the block). So the near days are NOT re-forecast: the
-- prediction for tomorrow was made 25 days ago at horizon 25, exactly like the
-- prediction for day 27. There is no short-horizon forecast anywhere in this view.
-- That is a publisher property, not something this view can fix; HORIZON_DAY and
-- PREDICTION_DATE are exposed so a consumer can weight or reject on it.
--
-- A MISSING PREDICTION IS NULL, NEVER ZERO -----------------------------------------
--
-- The training snapshot fillna(0)s every numeric column, which is safe for history
-- (an absent fact really is no guests) and wrong here (an absent head is an unrun
-- model, not an empty park). Under _2WEEKS forward coverage was ragged and
-- per-column (11 heads resolving on as few as 481 of 533 rows). Under _PUBLISHED it
-- is COMPLETE: METRICS_PRESENT = 11 on all 999 rows, so all 11 published heads resolve
-- everywhere. Twenty-nine columns here come off the predictions view -- those 11 heads,
-- 5 derived upstream (total_no_play_pass, the three first_day age splits, last_full_day)
-- and the 13 ratios -- and 27 of the 29 are fully populated. The two exceptions share
-- one structural cause, not a coverage gap:
--   last_full_day        962/999  = lead(leavers), guarded on the next row being d+1,
--                                 so null on each park's FINAL covered day: exactly 37
--                                 rows, one per park, all on the last day of the block
--   last_full_day_ratio  962/999  divides last_full_day, so it inherits those nulls
-- The null discipline is kept anyway: it is the source's raggedness that went away,
-- not the rule. A future repoint can bring it back, and the panel loader zero-fills
-- what it needs at read time regardless.
--
-- TWENTY-SEVEN FOOTFALL COLUMNS ARE STRUCTURALLY NULL. They have no predicted head
-- and no measured derivation -- the legacy nights column, the first_day and leavers
-- owner / holiday-maker / private-let splits, the first-day play-pass split, and every
-- booking-count column except the one self-catering count that IS published. They are
-- carried as typed NULL literals rather than dropped, so this view is column-for-column
-- unionable with the historical schema by name AND by position (weather aside).
-- DAILY_FOOTFALL_PREDICTIONS_V3's header records which of these were measured as
-- apportionments and rejected; do not resurrect one without re-measuring.
--
-- TYPES FOLLOW THE PARQUET, COLUMN FOR COLUMN. The 38 columns the parquet stores as
-- int64 are number(38,0) here; the 15 predicted ones are ROUNDED to get there, and the
-- 23 structurally-absent ones are typed null literals so a union with the historical
-- schema is well-typed on both sides. Everything else needs no cast: varchar stays
-- varchar, doubles stay float, and the date / holiday integer WIDTHS
-- (number(1,0) .. number(9,0), reproducing the parquet's int8/int16/int32) come through
-- unchanged because they are read straight off the feature views.
--
-- ROUNDING IS LOSSY AND THAT IS ACCEPTED. 64% of forward total_nights values arrive
-- fractional (644/999) because ensemble heads average, so round() is discarding real
-- sub-unit precision on every one of them -- a second opinion laid on top of the
-- model's. It is done anyway, deliberately, so this view is type-identical to the
-- training snapshot rather than merely name-compatible. Two consequences to know:
--   The unrounded FLOAT is still available upstream in DAILY_FOOTFALL_PREDICTIONS_V3
--   for anything that needs the model's exact output -- read it from there, not here.
--   number(38,0) is a DECLARED type, not a guarantee pandas can honour: last_full_day
--   is nullable, and one null widens the column to float64 on read regardless of what
--   Snowflake says. The declared type is the contract; the read dtype may differ.
--
-- WHICH COLUMNS STAY FLOAT, because the parquet stores them as double:
--   TOTAL_OWNERS            the one predicted count that is double upstream too
--   every *_RATIO           thirteen of them
--   GRAND_TOTAL             a 0.3/0.5-weighted sum, so fractional by construction
--   ACTIVE_OWNER_ACCOUNTS   number(18,0) upstream, double in the parquet because of
--                           the same fillna(0) that made the counts int64
--
-- THE FEATURE JOINS, all keyed on the calendar date and all verified complete over the
-- forward block (41/41 rows per day) unless noted:
--   static_park_features      park_code    lat/lon, director region, pitch strategy,
--                                          caravan sales region.  41/41 parks.
--   date_features_ext         date         year..quarter + the sin/cos pairs.
--                                          Coverage ends 2026-12-13.
--   school_holiday_features   date         the three regional school-holiday triples
--                                          and the region count.
--                                          COVERAGE ENDS 2026-11-02 -- the nearest
--                                          expiry of any feed here. Past it these nine
--                                          columns go null; the view does not pretend
--                                          otherwise. The 27-day window now reaches
--                                          that expiry from ~2026-10-06 -- two weeks
--                                          sooner than the old 13-day one did, so the
--                                          longer span brings this forward.
--   bank_holiday_features     date         flags, distances, period labels.  To 2027-12-28.
--   daily_periods_holidays    day_date     HOLIDAY_PERIOD only, matching the snapshot.
--                                          Holiday days only -- an ordinary day has no
--                                          row, so null means "not in a period", which
--                                          is how history reads too (string, never filled).
--   owner_accounts_monthly    park_code +  ACTIVE_OWNER_ACCOUNTS, forward-filled upstream
--                             month start  past the last known month.
--                                          35/37 kept parks: SV and RV have no rows at
--                                          all and go null, 945/999 non-null.
--
-- THE THREE _AS_CATEGORY COLUMNS reproduce the snapshot's astype(str) on the int flag,
-- so the vocabulary is '0'/'1' -- to_varchar, not a case expression, so it cannot drift
-- from the numeric column beside it. History can additionally contain the string 'nan'
-- where a bank-holiday row was missing; forward coverage is complete, so it cannot here.
--
-- GRAND_TOTAL IS COMPUTED, not nulled. It is the model target, and the snapshot defines
-- it as holiday_makers + 0.3*owners + 0.5*private_lets -- all three predicted. Carrying
-- the arithmetic forward gives a directly comparable published figure for the same
-- park-day, and it is null exactly when one of its three inputs is -- never, now that
-- all three heads resolve on every row (999/999).
-- A TFT reads the target from the encoder only, so a populated value in the decoder
-- frame cannot leak; it is there to be diffed against, not consumed.
--
-- PARK EXCLUSIONS mirror BASIC_PARK_EXCLUDE_LIST in save_training_data.py: CW, GW, FG,
-- PC. Kept in sync by hand -- if that list moves, this moves.
--
-- APPENDED PROVENANCE. PREDICTION_DATE, MODEL_IDS, HORIZON_DAY and METRICS_PRESENT come
-- after the parquet's last column so a by-name reader is unaffected and a by-position
-- reader can stop at GRAND_TOTAL. METRICS_PRESENT is the per-row head count (ceiling 11)
-- and is the cheap way to spot a thinly-covered park-day without null-checking each column.
create or replace view FOOTFALL_FUTURE_CHANNELS_V4 as
with spine as (
    select *
    from HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_FOOTFALL_PREDICTIONS_V3
       where park_code not in ('CW', 'GW', 'FG', 'PC')
)
select
       -- Identity. The snapshot's TS is a midnight timestamp, not a date, so cast.
       p.on_park_date::timestamp_ntz                                as ts,
       p.on_park_date::timestamp_ntz                                as on_park_date,
       p.park_code::varchar                                         as park_code,

       -- Footfall channel, in parquet order and at the parquet's number(38,0). The
       -- predicted heads are rounded off FLOAT (lossy -- see header); the rest are typed
       -- nulls. Nothing is coalesced to 0.
       round(p.total_nights)::number(38,0)                          as total_nights,
       null::number(38,0)                                           as total_nights_legacy,
       round(p.total_holiday_makers)::number(38,0)                  as total_holiday_makers,
       round(p.total_private_lets)::number(38,0)                    as total_private_lets,
       -- Double in the parquet, so this one is NOT rounded.
       p.total_owners,
       round(p.total_adults)::number(38,0)                          as total_adults,
       round(p.total_children)::number(38,0)                        as total_children,
       round(p.total_infants)::number(38,0)                         as total_infants,
       round(p.total_play_pass)::number(38,0)                       as total_play_pass,
       -- Complement of two independent heads upstream; can go slightly negative, and
       -- rounding does not clamp that.
       round(p.total_no_play_pass)::number(38,0)                    as total_no_play_pass,
       round(p.first_day)::number(38,0)                             as first_day,
       null::number(38,0)                                           as first_day_holiday_makers,
       null::number(38,0)                                           as first_day_owners,
       null::number(38,0)                                           as first_day_private_lets,
       -- Apportioned upstream by the stay-wide age share (corr 0.88), not predicted.
       -- Rounding hits these hardest: a share of a count is fractional by construction.
       round(p.first_day_adults)::number(38,0)                      as first_day_adults,
       round(p.first_day_children)::number(38,0)                    as first_day_children,
       round(p.first_day_infants)::number(38,0)                     as first_day_infants,
       -- The same apportionment was measured for play-pass and REJECTED (bias -0.123).
       null::number(38,0)                                           as first_day_play_pass,
       null::number(38,0)                                           as first_day_no_play_pass,
       -- lead(leavers) at d+1; null on each park's last covered day, hence 962 not 999.
       -- The only PREDICTED column carrying nulls (last_full_day_ratio inherits them),
       -- and the reason a declared number(38,0) can still read back as float64 in pandas.
       round(p.last_full_day)::number(38,0)                         as last_full_day,
       null::number(38,0)                                           as first_day_booking_count,
       null::number(38,0)                                           as first_day_booking_count_holiday_makers,
       -- The only booking count with a published head.
       round(p.first_day_booking_count_holiday_makers_self_catering)::number(38,0)
                                                                    as first_day_booking_count_holiday_makers_self_catering,
       null::number(38,0)                                           as first_day_booking_count_owners,
       null::number(38,0)                                           as first_day_booking_count_private_lets,
       null::number(38,0)                                           as total_bookings,
       null::number(38,0)                                           as total_bookings_holiday_makers,
       null::number(38,0)                                           as total_bookings_holiday_makers_self_catering,
       null::number(38,0)                                           as total_bookings_owners,
       null::number(38,0)                                           as total_bookings_private_lets,
       round(p.leavers)::number(38,0)                               as leavers,
       null::number(38,0)                                           as leavers_holiday_makers,
       null::number(38,0)                                           as leavers_owners,
       null::number(38,0)                                           as leavers_private_lets,
       null::number(38,0)                                           as leavers_booking_count,
       null::number(38,0)                                           as leavers_booking_count_holiday_makers,
       null::number(38,0)                                           as leavers_booking_count_holiday_makers_self_catering,
       null::number(38,0)                                           as leavers_booking_count_owners,
       null::number(38,0)                                           as leavers_booking_count_private_lets,

       -- Ratios, all denominated on total_nights upstream, all float per the parquet.
       -- Fully populated except last_full_day_ratio, which inherits its numerator's
       -- 37 final-day nulls.
       p.adults_ratio,
       p.children_ratio,
       p.infants_ratio,
       p.playpass_ratio,
       p.holiday_makers_ratio,
       p.private_lets_ratio,
       p.owners_ratio,
       p.first_day_ratio,
       p.leavers_ratio,
       p.last_full_day_ratio,
       p.first_day_adults_ratio,
       p.first_day_children_ratio,
       p.first_day_infants_ratio,

       -- Static park attributes.
       st.latitude,
       st.longitude,
       st.director_region,
       st.pitch_strategy_group,
       st.caravan_sales_region_name,

       -- Calendar features. Widths come through as-is so the parquet's int8/int16
       -- columns are reproduced without casting.
       d.year,
       d.month,
       d.week,
       d.dow,
       d.doy,
       d.quarter,
       d.month_sin,
       d.month_cos,
       d.week_sin,
       d.week_cos,
       d.dow_sin,
       d.dow_cos,
       d.doy_sin,
       d.doy_cos,
       d.quarter_sin,
       d.quarter_cos,

       -- School holidays. Feed ends 2026-11-02; these nine go null beyond it.
       sc.england_wales_holiday_type,
       sc.england_wales_current_holiday_remaining_days,
       sc.england_wales_days_until_next_holiday,
       sc.scotland_holiday_type,
       sc.scotland_current_holiday_remaining_days,
       sc.scotland_days_until_next_holiday,
       sc.northern_ireland_holiday_type,
       sc.northern_ireland_current_holiday_remaining_days,
       sc.northern_ireland_days_until_next_holiday,
       sc.number_of_regions_with_holiday,

       -- Bank holidays.
       b.is_england_wales_bank_holiday,
       b.is_scotland_bank_holiday,
       b.is_northern_ireland_bank_holiday,
       b.days_to_next_england_wales_bank_holiday,
       b.days_to_next_scotland_bank_holiday,
       b.days_to_next_northern_ireland_bank_holiday,
       b.days_since_last_england_wales_bank_holiday,
       b.days_since_last_scotland_bank_holiday,
       b.days_since_last_northern_ireland_bank_holiday,
       b.number_of_regions_with_bank_holiday,
       b.is_england_wales_bank_holiday_period,
       b.is_scotland_bank_holiday_period,
       b.is_northern_ireland_bank_holiday_period,
       b.england_wales_bank_holiday_period,
       b.scotland_bank_holiday_period,
       b.northern_ireland_bank_holiday_period,
       b.number_of_regions_with_bank_holiday_period,
       -- The snapshot's astype(str) of the flag beside it: vocabulary '0'/'1'.
       to_varchar(b.is_england_wales_bank_holiday_period)           as is_england_wales_bank_holiday_period_as_category,
       to_varchar(b.is_scotland_bank_holiday_period)                as is_scotland_bank_holiday_period_as_category,
       to_varchar(b.is_northern_ireland_bank_holiday_period)        as is_northern_ireland_bank_holiday_period_as_category,

       -- Haven trading period label. Null on a non-holiday day, as in history.
       ph.holiday_period,

       -- WEATHER OMITTED HERE. The parquet carries 110 columns between HOLIDAY_PERIOD
       -- and ACTIVE_OWNER_ACCOUNTS (the current-day block plus -1DAY..-10DAY lags);
       -- none of them are known covariates, so none are reproduced.

       -- Monthly owner accounts, forward-filled upstream. Null for SV and RV.
       oa.active_accounts::float                                    as active_owner_accounts,

       -- The target, recomputed from three predicted heads. Built off the ROUNDED
       -- holiday-maker and private-let counts, matching the snapshot, which computes it
       -- after its own int cast; total_owners is double in both. Stays float.
       (round(p.total_holiday_makers)
          + (0.3 * p.total_owners)
          + (0.5 * round(p.total_private_lets)))::float             as grand_total,

       -- Provenance, appended past the parquet's last column.
       p.prediction_date,
       p.model_ids,
       p.horizon_day,
       p.metrics_present

from spine p
left join HAVEN_DATA_SCIENCE.DATA_SCIENCE.static_park_features    st on st.park_code = p.park_code
left join HAVEN_DATA_SCIENCE.DATA_SCIENCE.date_features_ext       d  on d.date       = p.on_park_date
left join HAVEN_DATA_SCIENCE.DATA_SCIENCE.school_holiday_features sc on sc.date      = p.on_park_date
left join HAVEN_DATA_SCIENCE.DATA_SCIENCE.bank_holiday_features   b  on b.date       = p.on_park_date
left join HAVEN_DATA_SCIENCE.DATA_SCIENCE.daily_periods_holidays  ph on ph.day_date  = p.on_park_date
left join HAVEN_DATA_SCIENCE.DATA_SCIENCE.owner_accounts_monthly  oa
       on oa.park_code   = p.park_code
      and oa.month_start = date_trunc('month', p.on_park_date)
order by p.park_code, p.on_park_date
