-- DAILY_HOLIDAY_FEATURES_V3
-- The school-holiday / bank-holiday / holiday-period feature block of the
-- nn_footfall training panel, as a single date-grain view.
--
-- WHAT THIS IS. save_training_data.py merges three calendar sources into both
-- historical_values.parquet and future_values.parquet, by date, identically in
-- both paths (create_footfall_facts_snapshot lines 146-164 and
-- create_footfall_future_snapshot lines 241-257):
--
--   school_holiday_features   join on TS = DATE, DATE dropped   10 columns
--   bank_holiday_features     join on TS = DATE, DATE dropped   17 columns
--                             + 3 *_AS_CATEGORY columns derived in pandas
--   DAILY_PERIODS_HOLIDAYS    join on TS = DAY_DATE             HOLIDAY_PERIOD only
--
-- This view reproduces that block exactly: same 34 column names, same order, same
-- values, same types. Every column here is park-independent -- none of the three
-- sources carries a park_code -- so the grain is one row per date, and the join to
-- a park-day frame stays a plain date join.
--
-- The key column is named DATE, matching two of the three sources, so the existing
-- merge idiom (left_on=['TS'], right_on=['DATE'], then drop DATE) still works. It
-- is deliberately NOT also exposed as TS: a right-hand TS would collide with the
-- footfall frame's own TS and pandas would silently produce TS_x / TS_y.
--
-- FROM DAILY_PERIODS_HOLIDAYS, ONLY HOLIDAY_PERIOD IS TAKEN. That view also has
-- ENGLAND_AND_WALES / SCOTLAND / NORTHERN_IRELAND booleans; the script selects
-- just DAY_DATE and HOLIDAY_PERIOD, so carrying them here would add three features
-- the model has never seen.
--
-- THE SCRIPT'S 2026-10-01 CUTOFF IS NOT REPRODUCED, ON PURPOSE. SQL_DATE_PERIOD_FEATURES
-- filters `day_date < '2026-10-01'`, which is why future_values.parquet has a NULL
-- HOLIDAY_PERIOD on 2026-10-01 (37 rows, one per park). That is a hardcoded literal
-- going stale, not a data limit: DAILY_PERIODS_HOLIDAYS runs 1900-01-01 to
-- 2049-12-31, dense, with zero nulls anywhere in 2022-2027. Removing the cutoff
-- fixes a defect rather than changing a definition.
--
-- COVERAGE, AND THE ONE REAL CLIFF (measured 2026-09-02):
--   school_holiday_features   2022-01-01 .. 2026-11-02   1,767 dates, dense
--   bank_holiday_features     2022-01-01 .. 2027-12-28   2,188 dates, dense
--   DAILY_PERIODS_HOLIDAYS    1900-01-01 .. 2049-12-31  23,742 dates, dense
--
-- The school feed ends 2026-11-02 -- 61 days out from today, and shrinking by a day
-- every day. Past that date the 10 school columns have no source row at all. This
-- view carries the pipeline's own contract for that case (see below) but the honest
-- reading is that school-holiday features EXPIRE, and a horizon longer than the
-- remaining coverage is being served zeros. HAS_SCHOOL_HOLIDAY_FEATURES and
-- SCHOOL_HOLIDAY_COVERAGE_END are appended so this is visible from the data
-- instead of only from a coverage query. Fixing it means loading next year's term
-- dates upstream; it is not something this view can do.
--
-- MISSING-ROW SEMANTICS ARE THE PIPELINE'S, NOT SQL'S. After all merges the script
-- runs `fillna(0)` over every numeric column, so a date with no source row trains
-- as ZERO, not as null. This view therefore coalesces the numeric school/bank
-- columns to 0 -- matching what the model was actually fitted on. It is a lie about
-- the world (0 days until the next holiday) but it is the SAME lie train-side and
-- serve-side, which is the property that matters. The string columns
-- (*_HOLIDAY_TYPE, *_BANK_HOLIDAY_PERIOD) are left NULL, because fillna(0) does not
-- touch object columns -- so a categorical encoder sees a missing level there, again
-- exactly as in training.
--
-- THE *_AS_CATEGORY COLUMNS are pandas `astype(str)` over the three
-- IS_*_BANK_HOLIDAY_PERIOD columns, which arrive as NUMBER(1,0) and land in pandas
-- as int8 -- so the vocabulary is the two strings '0' and '1', NOT 'True'/'False'.
-- TO_VARCHAR over the raw column reproduces that exactly (verified). They are built
-- off the PRE-COALESCE value, so beyond bank coverage they are NULL rather than a
-- fabricated '0'. Bank coverage runs to 2027-12-28, so no plausible serving horizon
-- reaches that case.
create or replace view DAILY_HOLIDAY_FEATURES_V3 as
with school as (
    select * from HAVEN_DATA_SCIENCE.DATA_SCIENCE.SCHOOL_HOLIDAY_FEATURES
),
bank as (
    select * from HAVEN_DATA_SCIENCE.DATA_SCIENCE.BANK_HOLIDAY_FEATURES
),

-- The span worth publishing: from the earliest date either feature view covers to
-- the latest. Derived, not hardcoded, so the view extends itself as the upstream
-- feeds are loaded further forward.
bounds as (
    select min(d) as date_from, max(d) as date_to
    from (
        select "DATE" as d from school
        union all
        select "DATE" as d from bank
    )
),

-- DAILY_PERIODS_HOLIDAYS is the date backbone rather than a generator: it is
-- already dense over 1900-2049 at one row per date, so using it as the spine
-- guarantees no gaps AND guarantees HOLIDAY_PERIOD is non-null on every row of the
-- output. Only the two columns the training script reads are taken.
spine as (
    select p.day_date                                             as "DATE",
           p.holiday_period
    from HAVEN_DATA_SCIENCE.DATA_SCIENCE.DAILY_PERIODS_HOLIDAYS p
    cross join bounds b
    where p.day_date between b.date_from and b.date_to
),

-- The venue's last published school-holiday day, exposed below so the coverage
-- cliff is readable without a second query.
school_coverage as (
    select max("DATE") as school_holiday_coverage_end from school
)

select s."DATE",

       -- ---- school_holiday_features (10) ------------------------------------
       -- Strings stay NULL past coverage: fillna(0) does not touch object columns.
       sc.england_wales_holiday_type                              as england_wales_holiday_type,
       coalesce(sc.england_wales_current_holiday_remaining_days, 0)
                                                                  as england_wales_current_holiday_remaining_days,
       coalesce(sc.england_wales_days_until_next_holiday, 0)      as england_wales_days_until_next_holiday,
       sc.scotland_holiday_type                                   as scotland_holiday_type,
       coalesce(sc.scotland_current_holiday_remaining_days, 0)    as scotland_current_holiday_remaining_days,
       coalesce(sc.scotland_days_until_next_holiday, 0)           as scotland_days_until_next_holiday,
       sc.northern_ireland_holiday_type                           as northern_ireland_holiday_type,
       coalesce(sc.northern_ireland_current_holiday_remaining_days, 0)
                                                                  as northern_ireland_current_holiday_remaining_days,
       coalesce(sc.northern_ireland_days_until_next_holiday, 0)   as northern_ireland_days_until_next_holiday,
       coalesce(sc.number_of_regions_with_holiday, 0)             as number_of_regions_with_holiday,

       -- ---- bank_holiday_features (17) -------------------------------------
       coalesce(bk.is_england_wales_bank_holiday, 0)              as is_england_wales_bank_holiday,
       coalesce(bk.is_scotland_bank_holiday, 0)                   as is_scotland_bank_holiday,
       coalesce(bk.is_northern_ireland_bank_holiday, 0)           as is_northern_ireland_bank_holiday,
       coalesce(bk.days_to_next_england_wales_bank_holiday, 0)    as days_to_next_england_wales_bank_holiday,
       coalesce(bk.days_to_next_scotland_bank_holiday, 0)         as days_to_next_scotland_bank_holiday,
       coalesce(bk.days_to_next_northern_ireland_bank_holiday, 0) as days_to_next_northern_ireland_bank_holiday,
       coalesce(bk.days_since_last_england_wales_bank_holiday, 0) as days_since_last_england_wales_bank_holiday,
       coalesce(bk.days_since_last_scotland_bank_holiday, 0)      as days_since_last_scotland_bank_holiday,
       coalesce(bk.days_since_last_northern_ireland_bank_holiday, 0)
                                                                  as days_since_last_northern_ireland_bank_holiday,
       coalesce(bk.number_of_regions_with_bank_holiday, 0)        as number_of_regions_with_bank_holiday,
       coalesce(bk.is_england_wales_bank_holiday_period, 0)       as is_england_wales_bank_holiday_period,
       coalesce(bk.is_scotland_bank_holiday_period, 0)            as is_scotland_bank_holiday_period,
       coalesce(bk.is_northern_ireland_bank_holiday_period, 0)    as is_northern_ireland_bank_holiday_period,
       bk.england_wales_bank_holiday_period                       as england_wales_bank_holiday_period,
       bk.scotland_bank_holiday_period                            as scotland_bank_holiday_period,
       bk.northern_ireland_bank_holiday_period                    as northern_ireland_bank_holiday_period,
       coalesce(bk.number_of_regions_with_bank_holiday_period, 0) as number_of_regions_with_bank_holiday_period,

       -- ---- derived in pandas by the training script (3) -------------------
       -- astype(str) over an int8 column: the vocabulary is '0' / '1'.
       to_varchar(bk.is_england_wales_bank_holiday_period)        as is_england_wales_bank_holiday_period_as_category,
       to_varchar(bk.is_scotland_bank_holiday_period)             as is_scotland_bank_holiday_period_as_category,
       to_varchar(bk.is_northern_ireland_bank_holiday_period)     as is_northern_ireland_bank_holiday_period_as_category,

       -- ---- DAILY_PERIODS_HOLIDAYS (1) -------------------------------------
       s.holiday_period                                           as holiday_period,

       -- ---- appended diagnostics, not part of the training schema ----------
       -- Uniquely named, so a by-name feature lookup ignores them and a pandas
       -- merge cannot produce a suffix collision.
       sc."DATE" is not null                                      as has_school_holiday_features,
       bk."DATE" is not null                                      as has_bank_holiday_features,
       cv.school_holiday_coverage_end                             as school_holiday_coverage_end

from spine s
     cross join school_coverage cv
     left join school sc on sc."DATE" = s."DATE"
     left join bank   bk on bk."DATE" = s."DATE"
order by s."DATE"
