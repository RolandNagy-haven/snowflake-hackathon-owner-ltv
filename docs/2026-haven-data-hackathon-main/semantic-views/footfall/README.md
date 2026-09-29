# Footfall arrivals semantic view

A semantic-view replacement for the hand-built cube in
`data-views/DAILY_FOOTFALL_FACTS_V3.sql`, built in versions. Deployed to
`HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL`.

Run everything from this folder with the project venv
(`/Users/z/Dev/haven/cortex-semantic-spike/.venv/bin/python3`):

```bash
python deploy.py FOOTFALL_ARRIVALS_SV_V1.sql   # base views + semantic view
python parity_v1.py                            # vs DAILY_FOOTFALL_FACTS_V3, exit 1 on mismatch
python spine_experiment_v1.py                  # do days with no guests survive?
python deploy.py FOOTFALL_ARRIVALS_SV_V2.sql   # v2
python parity_v2.py                            # v2 vs V3 (takes ~9 min), exit 1 on unexplained mismatch
python check_query_examples_v2.py              # every query in query_examples_v2.sql
python deploy.py FOOTFALL_ARRIVALS_SV_V3.sql   # v3: v2 + owners from Fraser
python parity_v3.py                            # owners vs V3 + v2 metrics unchanged (~5 min), exit 1 on unexplained mismatch
python check_query_examples_v3.py              # every query in query_examples_v3.sql
python sf.py "select ..."                      # ad-hoc SQL
```

## The idea

V3 hand-writes ~50 columns that are all one of two counts (guest-nights, bookings)
filtered by a few conditions (stay type, age, play pass, first day, last full day,
leaving day, self-catering). The semantic view keeps one row per guest per night and
exposes the conditions as dimensions, so every V3 column becomes a query.

## Roadmap

| Version | Adds | Status |
|---|---|---|
| **v1** | Booked guests (Holiday Maker + Private Let) per night; park, date, stay type, age, play pass; park x day spine | **done, parity OK** |
| **v2** | First day, last full day, leavers (departure-day rows), bookings, self-catering, ratios, park sample values, more verified queries | **done, parity OK** |
| **v3** | Owners from Fraser only (transacted + estimated), as a separate park x day table; never added to guests | **done, parity OK** |
| v4 | Holiday calendar, park season, 7-day avg / same day last year | |
| v5 | Future: on-the-books holiday makers, forecasts; what is known ahead per stay type | |

Owner rows of the arrival table are dropped at the source in every version: no
`first_day_owners`, `leavers_owners` or `*_booking_count_owners`. Owners exist only as
Fraser's figures (from v3), and are never added to guests.

## v1 objects

| Object | What |
|---|---|
| `FOOTFALL_SV_GUEST_NIGHTS_V1` | view: one row per booked guest per night, 2023-01-01..yesterday |
| `FOOTFALL_SV_PARK_DAYS_V1` | view: spine, every park (that ever had arrivals) x every day |
| `FOOTFALL_ARRIVALS_SV_V1` | semantic view: `guests` -> `park_days` -> `parks` (DIM_PARK) |

## v1 results

**Parity with V3** (2023-01-01..yesterday, 55,883 park-days): all 8 `TOTAL_*` guest
columns identical on every park-day - one semantic query grouped by park x date x stay
type x age x play pass, re-pivoted in plain SQL.

**Spine experiment** - 14,007 of the 55,883 park-days have no guests:

| Query | Rows | Days with no guests |
|---|---|---|
| spine dims + `guest_nights` only | 41,876 | dropped |
| + filter `stay_type = 'Holiday Maker'` | 36,365 | dropped |
| spine dims + `guest_nights` + spine metric `park_days` | 55,883 | kept, `guest_nights` NULL |
| wrapper: spine `LEFT JOIN SEMANTIC_VIEW(...)` | 55,883 | kept, coalesce to 0 |

| derived `coalesce(guests.guest_nights, 0)` alone | 41,876 | dropped (coalesce alone does nothing) |
| **`guests_on_park`** = `iff(park_days.park_days > 0, coalesce(guest_nights, 0), null)` | 55,883 | **kept, 0** |
| `guests_on_park` + filter `stay_type = 'Holiday Maker'` | 36,365 | dropped |
| `guests_on_park` grouped by `stay_type` | 89,029 | kept, as one row with NULL stay_type |

So the semantic view only returns rows for a park-day when a metric from the spine
table is in the query. `guests_on_park` is the zero-padded metric.

**Trap:** a `WHERE` on a guests dimension (stay type, age, play pass) also removes spine
days - `park_days` drops from 55,883 to 36,365 - so averages divide by the wrong number
of days. Per-segment averages must use the segment metrics (`holiday_maker_nights /
park_days`), not a filter. This is in `AI_SQL_GENERATION`, and Cortex Analyst followed
it on the first try. `avg_guests_per_day` divides by all calendar days (`park_days`),
so zero days count - e.g. WM January 2025 averages 0.4 guests/day, not 11.

## v2 objects

| Object | What |
|---|---|
| `FOOTFALL_SV_GUEST_DAYS_V2` | view: one row per booked guest per DAY on park (nights + departure morning), 2023-01-01..yesterday, with `is_first_day`, `is_last_full_day`, `is_departure_day`, `grade_group`, `grade`, `is_self_catering` |
| `FOOTFALL_SV_PARK_DAYS_V2` | view: spine, same as v1 |
| `FOOTFALL_ARRIVALS_SV_V2` | semantic view: `guests` -> `park_days` -> `parks`; v1 metrics + arrivals, leavers, bookings, 12 ratios |

Teaching material: `QUERY_EXAMPLES_V2.md` (6 scenarios), `query_examples_v2.sql`,
`check_query_examples_v2.py`. v1 objects and files are unchanged.

## v2 design

- **One guest table, nights and departure days together.** Departure-day rows are
  flagged `is_departure_day`, so stay type, age, play pass and self-catering apply to
  leavers too ("leavers by age" is one query; V3 has no such column). Every night metric
  sums the fact `guest_night`, which is 0 on a departure day. That one fact keeps the
  departure rows out of `guest_nights` and every v1 metric. A separate leavers table would
  need a second copy of every guest dimension (`leavers.stay_type`), which is confusing
  for people and for Analyst.
- **Three separate flags**, because they overlap: a one-night stay's night is both
  `is_first_day` and `is_last_full_day`. `is_first_day` also requires a night: a
  same-day stay (arrival = departure; 45,818 Private Let rows since 2023) has only a
  departure row, so it is a leaver and never a first day, as in V3.
- **Bookings** are `count(distinct booking_id)` over night rows (`bookings_on_park`),
  first nights (`first_day_bookings`) and departure rows (`leaver_bookings`). They are not
  additive over days, parks or ages, so the view recounts at each grain (see S3 in the
  examples). They are additive over `stay_type` and `is_self_catering`: no booking has two
  stay types (0 of 4.9M bookings since 2023, owners included), and self-catering is a
  booking attribute. First-day and leaver bookings also add up over days, because no
  booking has two arrival or departure dates (0 of 4.39M).
- **Self-catering** = Holiday Maker whose accommodation `grade_group` is not Touring, read
  from the arrival row's own `GRADE_XID` (`HOLIDAY.DIM_GRADE`, unique on its key, so no
  duplication). V3 gets it from the package type on today's snapshot of
  `FCT_HOLIDAY_BOOKINGS`; the first v2 build did the same. Switched to the grade because the
  two agree on all 3,568,324 holiday-maker bookings since 2023 (0 disagree, re-checked in
  `parity_v2.py`), and the grade needs no big snapshot join, no booking-id parsing, and
  cannot drift when today's snapshot changes (the package route moved 2 of 3.57M bookings in
  a week). `grade_group` and `grade` are dimensions too. Grade is reliable for Holiday
  Makers only: 'No Match' on over half of Private Let rows.
- **Ratios** are guests-table metrics `div0(x, guest_nights)`, evaluated after grouping, so
  they are recomputed at every grain. `AI_SQL_GENERATION` says never to average them.
  OWNERS_RATIO waits for v3.
- **Parks:** `park_name` is now `trim(park_name)`. Two DIM_PARK names have trailing spaces
  (`'Berwick  '`, `'Blue Dolphin '`), so in v1 `where park_name = 'Berwick'` returns
  nothing (measured: v1 0 rows, v2 1 row). `park_code`, `park_name`, `stay_type`,
  `guest_age` and `play_pass` have `SAMPLE_VALUES (...) IS_ENUM`.
- **No zero-padded versions of the new metrics.** Any query that includes `park_days` (or
  `guests_on_park`) already returns every calendar day, with the other metrics NULL on
  empty days. Coalesce outside the clause. A padded twin for each new metric would add
  many metrics for no new capability.

## v2 results

**Parity with V3** (`parity_v2.py`, 2023-01-01..2026-09-24, 55,883 park-days, 0 only in SV,
0 only in V3). Three semantic queries (guest dims x day flags; stay type x self-catering
for bookings; park x day for booking totals and ratios), re-pivoted in SQL:

- **Identical on every park-day (44 columns):** the 8 `TOTAL_*`; `FIRST_DAY`, `FIRST_DAY_{HOLIDAY_MAKERS,
  PRIVATE_LETS, ADULTS, CHILDREN, INFANTS, PLAY_PASS, NO_PLAY_PASS}`; `LAST_FULL_DAY`;
  `LEAVERS`, `LEAVERS_{HOLIDAY_MAKERS, PRIVATE_LETS}`; the 9 HM / HM self-catering / PL booking
  columns (total, first day, leavers); the 3 booking totals vs V3's HM + PL; and the 12
  non-owner ratios (tolerance 1e-6, all 0 differing). Example totals: `TOTAL_NIGHTS`
  63,951,113; `FIRST_DAY` 15,673,222; `LAST_FULL_DAY` 15,662,446; `LEAVERS` 15,668,057;
  `TOTAL_BOOKINGS` HM+PL 16,676,056.
- **v1 metrics unchanged:** the V1 and V2 views give the same `guest_nights`, `holiday_maker_nights`,
  `private_let_nights`, `guests_with_play_pass`, `park_days_with_guests`, `distinct_guests` and
  `park_days` on all 55,883 park-days.
- **Expected differences, explained by the numbers:**

  | V3 column (includes owners) | park-days differing | V3 total | SV total | V3 - SV | V3 `*_OWNERS` | park-days where the gap is not exactly owners |
  |---|---|---|---|---|---|---|
  | `TOTAL_BOOKINGS` | 43,083 | 19,861,010 | 16,676,056 | 3,184,954 | 3,184,954 | 0 |
  | `FIRST_DAY_BOOKING_COUNT` | 36,004 | 4,458,568 | 4,051,078 | 407,490 | 407,490 | 0 |
  | `LEAVERS_BOOKING_COUNT` | 39,682 | 4,561,775 | 4,056,331 | 505,444 | 505,444 | 0 |

  HM + PL distinct counts add up exactly to the non-owner total on every park-day,
  because no booking has two stay types.
- **V3's `leavers` CTE has no `< current_date` filter.** The arrival table has 1,264,451
  booked-guest departure rows dated today or later. They do not matter: V3 left-joins its
  leavers onto a spine that ends yesterday, so no V3 row has leavers on or after today, and
  v2 filters them out in the base view.
- **Package snapshot:** V3 and v2 read the same snapshot on the same day, so they match.
  Both can shift a little from day to day (see the design notes).

**Side effects of the single-table design** (measured, all history):

| | v1 | v2 |
|---|---|---|
| rows for spine dims + `guest_nights` only | 41,876 | 42,409 (533 days with only leavers now return `guest_nights = 0` instead of no row) |
| `park_days` with `WHERE stay_type = 'Holiday Maker'` | 36,365 | 36,521 (days with Holiday Maker leavers but no Holiday Maker nights are kept) |
| `park_days` with `WHERE is_first_day` / `WHERE is_departure_day` | - | 35,464 / 36,011 (of 55,883) |

The WHERE-filter trap is the same as in v1 and now also applies to the day flags and
`is_self_catering`. `AI_SQL_GENERATION` covers it. Verified query
`avg_arrivals_per_day` and example S6 show the right pattern.

**Sample values work on this account.** `SAMPLE_VALUES ('...') IS_ENUM` after `COMMENT`
(June 2026 DDL) deployed without error and shows in `DESCRIBE SEMANTIC VIEW` as
`SAMPLE_VALUES` / `IS_ENUM` rows. Analyst resolved "Craig Tara" to `park_code = 'CT'` and
"Hafan y Mor" / "Berwick" to `park_name`. For an invented name ("Sunny Sands Bay") it said
"not in the list of valid park names ... this park is not in the data". Oddly, it then
wrote plain SQL over the base views instead of a `SEMANTIC_VIEW(...)` query, filtering on
that name, so the result is empty. v1 returned nothing and gave no explanation.

**Cortex Analyst smoke test** (`cortex_analyst.py --view ...FOOTFALL_ARRIVALS_SV_V2 --run`):

| Question | Analyst's choice | Result |
|---|---|---|
| How many guests arrived at Craig Tara in the week starting 3 August 2026? | `first_day_guests` (+ `first_day_bookings`), `park_code = 'CT'` | right: 7,622 guests, 1,691 bookings |
| How many guests left Devon Cliffs each day from 1 to 7 August 2026? | `leavers` by `on_park_date` | right (e.g. Mon 3 Aug 3,735) |
| How many bookings were on park at Haggerston over the week starting 3 August 2026? | `bookings_on_park` for the whole week, recounted, not summed | right: 1,737 |
| What was the children ratio at Craig Tara in August 2026? | `children_ratio` at month grain; said "not averaged from daily ratios" | right: 0.336 |
| Average private let guests per day at Hafan y Mor in November 2025? | `private_let_nights / park_days`, no stay_type filter | right: 2,027 / 30 = 68 |
| Average private let **arrivals** per day at Hafan y Mor in November 2025? | round 0: its first SQL had `SUM(...)` outside the clause and failed. It then corrected itself automatically: 426 / 30 = 14 | right after its own correction |
| Self-catering bookings arriving at Berwick in July 2026? | `first_day_bookings` + `WHERE is_self_catering`, `park_name = 'Berwick'` (works now that the name is trimmed) | right: 2,719 |

Round 1 fix: one sentence in `AI_SQL_GENERATION` saying that a metric for a missing
combination is defined inside METRICS and divided there. After redeploying, the
private-let arrivals question worked on the first attempt (426, 30, 14). A new question,
"average holiday makers leaving Craig Tara per day in August 2026", also worked first time
(29,343 / 31 = 947). No verified query was matched (`verified query used: none`) in any of
these. Analyst generated the right SQL from the metric comments and instructions.

**Examples check:** `check_query_examples_v2.py` -> ALL SCENARIOS OK (S1-S6 + S3b; old, A
and B match; the 6 documented pitfalls/recounts differ as expected).


## v3 objects

| Object | What |
|---|---|
| `FOOTFALL_SV_GUEST_DAYS_V3` | view: identical copy of `FOOTFALL_SV_GUEST_DAYS_V2` (same rows, checked by hash) |
| `FOOTFALL_SV_PARK_DAYS_V3` | view: spine, identical copy of the v2 spine; now shared by guests and owners |
| `FOOTFALL_SV_OWNER_DAYS_V3` | view: one row per park per day WITH a Fraser owner figure, 2023-02-20..yesterday: `transacted_heads`, `estimated_heads` (heads x 7). Not padded to the spine |
| `FOOTFALL_ARRIVALS_SV_V3` | semantic view: `guests` -> `park_days` <- `owners`, `park_days` -> `parks`; all v2 metrics + `owner_heads_indicative`, `owner_heads_estimated`, `park_days_with_owner_data`, `avg_owner_heads_per_day`, `owners_ratio` |

Teaching material: `QUERY_EXAMPLES_V3.md` (6 scenarios + 2 "b" parts), `query_examples_v3.sql`,
`check_query_examples_v3.py`. v1 and v2 objects are unchanged. `QUERY_EXAMPLES_V1.md` got one
correction note (S5 and S8): ad-hoc conditional aggregates work inside `METRICS` too.

## The Fraser source (measured 2026-09-25)

`haven_store.heads_on_park.fct_heads_on_park` + `dim_on_park_guest_type` + `dim_calendar` + `dim_park`.

- **Grain.** The table comment says date x park x guest_type x logic x break_duration x
  product x van_type. For `guest_type = 'Owners'` every (park, date, calculation_logic) has
  exactly one row (van_type always 'Owner', break_duration 0, no package or grade). No
  NULL or negative heads. `dim_calendar` and `dim_park` join without loss.
- **Why x 7.** `heads` is 1/7 of a daily person count. Proof from the same table: Holiday
  Makers' `heads x 7` equals the arrival table's holiday-maker guest-nights within 0.5 on
  41,855 of 42,409 park-days since 2023 (57.08M both; total absolute difference 4,349).
  Owner heads / `van_count` = 3.96 (Transacted), 3.86 (Estimated): "about 4 people per van".
- **Owner logics** (owner-head-days, 2023..yesterday): Transacted 18.5M (the figure),
  Estimated 10.5M, `Registered & transacted` 5.8M, Registered 2.5M. Other guest types:
  Holiday Makers and Private Letting (Booking logic), Prospective Owner and Day Pass (in the
  dimension, no rows). Documented only, not added.
- **V3's case bug.** V3 filters `calculation_logic in ('Transacted', 'Registered & Transacted')`,
  but the value is `'Registered & transacted'` (lower-case t). The comparison is
  case-sensitive, so **V3's TOTAL_OWNERS is Transacted only**. v3 reproduces that and writes
  `= 'Transacted'`. `Registered & transacted` is not a subset of Transacted (larger on 3,099
  park-days), so it looks like a separate bucket that V3's author meant to include; adding it
  would raise owner heads by ~31%. **Open question for the data owner.**
- **Coverage.** Owner rows from 2023-02-20, and a few days into the future (cut at
  yesterday). 36 of the 41 spine parks have Transacted rows. CW and GW have only Registered
  owner rows, PC 18 days of Registered, RV and SV none: owner metrics are NULL there. Every
  park with Fraser rows is already in the spine (0 missing).

## v3 design

- **Owners are a second fact table on the spine**, joined on (park_code, on_park_date). So
  guests and owners share `park_code`, the dates and the `parks` attributes, and nothing
  else: owners have no stay type, age, play pass, flags or bookings.
- **New _V3 copies of the guest view and the spine** instead of reusing the v2 views, so v3
  deploys and drops on its own and a v2 change cannot silently change v3 (the choice v2 made
  for v1). The copies are identical (`parity_v3.py` compares every row by `hash_agg`).
- **No total, no share.** There is no metric adding owners to guests, and `owners_ratio`
  (V3 OWNERS_RATIO, owner heads per booked guest night, can exceed 1) is described as not a
  share. Comments on the table, the facts and each metric say what an owner head is.
  `AI_SQL_GENERATION` says: never add them, even when asked; present side by side; call them
  "booked guests" and "estimated owner heads"; per-day averages for multi-day periods; no
  guest dimensions in queries with owner metrics. All v2 instructions are kept (parity checks
  every sentence; only the two "owners are not included" sentences were rewritten).
- **Naming.** `owner_heads_indicative`: "indicative" because it is inferred from spending at a
  fixed people-per-van rate. It stays next to the number in every result and keeps it from
  looking like a sibling of `guest_nights`. `owner_heads_estimated` is the Estimated *logic*,
  labelled diagnostics-only; the instructions tell Analyst to use it only when that logic
  is asked for by name.
- **Missing is NULL, not 0.** V3 coalesces a missing Fraser row to 0. v3 keeps no row, so
  owner metrics are NULL. `avg_owner_heads_per_day` divides by `park_days_with_owner_data`,
  not by calendar days. Where missing days are: before 2023-02-20 (no data), the winter
  closed season (mid Nov-Feb: Fraser's figure winds down and stops, and the arrival table's
  own owner rows fall from ~84 to ~13 per park-day, so "closed", near zero but not measured),
  and the 5 uncovered parks (no data). From March to October every Fraser park has every day.
  Fraser's explicit zeros (309 park-days) stay 0.
- **owners_ratio** returns NULL (not V3's 0) with no Fraser figure, and NULL (not V3's
  div0 0) when there are owners but no booked guests.
- **Grain.** Summed over days, owner heads are owner-head-days, like guest_nights are
  person-nights. Said in the comments and instructions.

## v3 results

**Parity** (`parity_v3.py`, 2023-01-01..2026-09-24, 55,883 park-days, 0 only in V3, 0 only in SV):

| column | park-days differing | V3 / reference total | SV total |
|---|---|---|---|
| `TOTAL_OWNERS` vs `owner_heads_indicative` (NULL as 0) | 0 | 18,516,120 | 18,516,120 |
| `OWNERS_RATIO` vs `owners_ratio` (NULL as 0) | 0 | 282,739.85 | 282,739.85 |
| `owner_heads_estimated` vs the Fraser source directly | 0 | 10,495,778 | 10,495,778 |
| 27 v2 metrics, V2 view vs V3 view (all 12 ratios, bookings, `park_days`, `guests_on_park`, ...) | 0 each | e.g. `guest_nights` 63,951,113 | 63,951,113 |

Explained (V3 0, v3 NULL): no Fraser figure on 17,408 park-days (all of them 0 in V3);
`owners_ratio` NULL because there are no booked guests on 1,685 park-days, 1,445 of them
with owner heads > 0. Fraser's own zeros: 309. `owners_ratio` > 1 on 4,099 park-days (max
3,399). Base views: guest days 79,619,170 rows and spine 55,883 rows, `hash_agg` equal to v2.
DESCRIBE: of 349 v2 properties, only 3 changed (view comment, `AI_SQL_GENERATION`, guests
table comment), all on purpose. Assumptions: 0 duplicate Fraser rows per park x date x logic,
0 owner rows without a spine row, 0 owner rows without a Transacted figure.

**Estimated spikes** (not fixed): DF Nov 2023 189,248 estimated vs 3,117 transacted owner-head-days
(week of 20 Nov: 188,240 vs 868; 25 Nov: 38,863 vs 179); LS Nov 2024 196,670 vs 13,365 (23 Nov:
44,241 vs 1,924); DF Mar 2026 14,407 vs 3,961, all on 1 Mar (13,158). More: RP Dec 2023 142,365
vs 8,188, LY Dec 2025, AH Dec 2023, TW Nov 2024, PV Dec 2024. Median daily estimated/transacted
0.42, correlation 0.22. Transacted daily max 5,497.

**Combining owner and guest metrics** (all history, spine dims = park x date):

| query | rows / park_days | owner heads |
|---|---|---|
| owners only | 38,475 rows (days with a Fraser figure) | 18,516,120 |
| owners + `guest_nights` | 43,896 rows (union of owner days and guest days) | 18,516,120 |
| owners + `guest_nights` + `park_days` | 55,883 rows, every day | 18,516,120 |
| owners + `WHERE stay_type = 'Holiday Maker'` | 33,747 rows; with `park_days` 36,521 | **16,658,483 (-10%)** |
| no dims, `WHERE is_first_day` | `park_days_with_owner_data` 32,895, `park_days` 35,464 | 16,693,626 |
| grouped by `stay_type` | Holiday Maker row 16,658,483, Private Let row 18,053,550 | **repeated per group** |
| `WHERE owners.owner_heads_transacted_day > 0` (owner fact filter) | `park_days` 38,166, `guest_nights` 62,075,498 | 18,516,120 |

So the WHERE-filter trap now also cuts owners: a guest filter keeps only spine days with
matching guests, and the owners hang off those days. Grouping owners by a guest dimension
repeats them. A filter on an owner fact cuts the guests the same way. Rule (in
`AI_SQL_GENERATION` and S2b): queries with owner metrics group and filter on park and date only;
guest segments go in segment metrics or metrics defined inside METRICS.

**Metric inside METRICS (loose end from v2).** `metrics sum(iff(guests.stay_type = 'Private Let' and
guests.is_first_day, guests.guest_night, 0)) as pl_arrivals, park_days.park_days, pl_arrivals /
park_days.park_days as avg_pl_arrivals_per_day` for CT, August 2025: 4,204, 31, 135.61 (= V3). As a
WHERE instead: 30 days, 140.13. **Flavour B supports it too:** `sum(iff(stay_type = 'Private Let' and
is_first_day, guest_night, 0)) / agg(park_days)` gives the same 4,204 / 31 / 135.61 (B cannot name
and reuse the ad-hoc aggregate, so the expression is repeated). V1 check: in V1, `sum(iff(stay_type =
'Holiday Maker', ...)) / park_days` for HA 6-12 Nov 2025 gives 7,544 / 7 / 1,077.71 in A and B.

**Cortex Analyst smoke test** (`cortex_analyst.py --view ...FOOTFALL_ARRIVALS_SV_V3 --run`):

Round 1 (owner instructions as in the design above, including the "no guest dimensions with owner
metrics" rule):

| Question | What Analyst did | Result |
|---|---|---|
| How many people were on park at Craig Tara last Saturday? | side by side: `guest_nights` + `owner_heads_indicative` for 2026-09-19; interpretation says "cannot be added" | 3,442 booked guests, 557 owner heads. Did not add |
| Total population of Devon Cliffs in August 2025 | side by side + `owners_ratio`, "cannot be added" | 169,025 / 38,792 / 0.230. Did not add, but gave month sums (person-nights), not per day |
| What share of people on park at Haggerston were owners in August 2025? | side by side + `owners_ratio`, did not compute owners/(owners+guests) | 103,334 / 18,697 / 0.181 |
| How many owners were on park at Hopton each day in the first week of August 2025? | `owner_heads_indicative` + `park_days_with_owner_data` by day | right metric; date slip: said 1-7 Aug, queried the week of 4 Aug |
| Average owners per day at Craig Tara in January 2026? | `avg_owner_heads_per_day` with `park_days_with_owner_data` | 369.1 over 4 days, as designed |
| Average private let arrivals per day at Hafan y Mor in November 2025? (v2) | metric inside METRICS / `park_days`, no filter | 426 / 30 = 14, as in v2 |

Round 1 fix: one sentence: keep them separate even when asked to add, and for multi-day periods report
per-day averages side by side. Round 2:

| Question | What Analyst did | Result |
|---|---|---|
| Total population of Devon Cliffs in August 2025 | per-day averages side by side. Two semantic attempts failed (`guests.avg_guests_per_day`, `park_days.park_name`: wrong prefixes), then it fell back to plain SQL over the base views | 5,452 booked guests/day, 1,251 owner heads/day (31 of 31 days). Right, separate |
| How many people in total were at Craig Tara last Saturday? Add guests and owners together. | refused to add: "returned side by side and cannot be added together, as they come from different sources" | 3,442 / 557 |
| What percentage of the people at Haggerston in August 2025 were owners? | side by side, per-day averages, `owners_ratio`; no percentage | 3,333 guests/day, 603 owner heads/day, ratio 0.181 |
| Show owners and holiday makers at Far Grange in August 2025 | holiday makers as a metric inside METRICS, **not** a `stay_type` filter, so FG's owners survive | 31,695 owner heads (1,022/day), 0 holiday makers |
| Owners at Craig Tara by stay type in August 2025 | did not group owners by stay_type: "Owners cannot be grouped by stay_type", used `holiday_maker_nights` / `private_let_nights` columns | 21,749 owner heads; 113,631 HM, 17,340 PL |

In no question did Analyst add owners to guests. No verified query was used (`none`) in any answer.
Left as is: the fallback to plain SQL after qualifying derived metrics with a table prefix (it happened
in v2 too), and the "first week" date interpretation.

**Examples check:** `check_query_examples_v3.py` -> ALL SCENARIOS OK (S1-S6 + S2b, S4b; old, A and B
match; 8 pitfalls/differences differ as expected). `check_query_examples_v1.py` -> ALL SCENARIOS OK
(only the .md changed).
