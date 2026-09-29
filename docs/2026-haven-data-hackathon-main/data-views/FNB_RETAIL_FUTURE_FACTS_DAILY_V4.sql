-- Future known covariates for the PDHH/PDFN models: the same daily grain and the
-- same column order as FNB_RETAIL_FACTS_DAILY_V4, over the 60 DAYS FOLLOWING THE
-- LAST BUSINESS DAY THAT VIEW COVERS, with every genuinely unknown quantity nulled
-- out. Read it as "the historical view continued forward, with the facts erased" --
-- and note that "continued" is literal: the two are CONTIGUOUS by construction, not
-- by both happening to agree with today's date. See the `horizon` CTE.
--
-- WHAT SURVIVES INTO THE FUTURE
--   identity      park / venue / category / concept / is_main / cost-centre ids
--   scope         in_training_dataset
--   opening       the CAL_* family -- the PUBLISHED opening calendar, which is a
--                 forward-looking rota and therefore the only window that exists
--                 in advance
--   competition   the four park-day counts, RECOMPUTED off cal_operating_hours
--
-- THE TWO TRANSACTION-DERIVED WINDOWS PROXY THE CALENDAR RATHER THAN GOING NULL.
--   OPEN_*/CLOSE_*/OPERATING_HOURS/TRADING_HOURS and the whole CORE_* family are
--   all set to the corresponding CAL_* value, so the view is a drop-in for a
--   consumer that reads CORE_* -- which the panel does. Consequences worth knowing
--   before relying on them are stated at the columns themselves; the short version
--   is that OPEN_* and CORE_* are now IDENTICAL to each other and to CAL_*, they
--   describe the PUBLISHED rather than the traded window, and OPERATING_HOURS can
--   be null here where history guarantees a number.
--
-- WHAT IS STILL NULLED
--   CAL_TRADING_HOURS, and every revenue / orders / items / transactions column in
--   both the SERVICED and TAKEN families. Types are cast so the schema matches the
--   historical view column for column; a union of the two is well-typed.
--
-- THE SPINE: (transacting park x venue) x 60 days, one row per day.
-- A venue is transacting if, over its most recent (up to) 30 ACTIVE days -- days
-- with operating_hours > 0 -- inside the past 60 calendar days, it took at least
-- £1,000 of SERVICED revenue. Measured 2026-09-02: 272 venues over 38 parks, so
-- 16,320 rows. The threshold is a soft cut (271 venues at £2,000), and what it
-- actually removes is dead stubs and near-dormant kiosks, not marginal traders.
--
-- MISSING CALENDAR ROW = CLOSED, NOT UNKNOWN. This is the one place this view
-- departs from the historical one, and it is a deliberate reading of the data.
-- The historical view carries a published window forward across days that have no
-- row of their own; doing that here would fabricate openings, because forward
-- publication is COMPLETE rather than progressive. The evidence: published venues
-- per day follow an exactly repeating weekly cycle (Mon 176 / Tue 168 / Wed 184 /
-- Thu 189 / Fri 231 / Sat 277 / Sun 238) identical for every week from 2026-09-07
-- to 2026-10-17, then jump to a flat ~275 for the 2026-10-24..11-08 autumn half
-- term, then revert to the same cycle. That is a seasonal trading pattern, not a
-- rota someone has not filled in yet. So a venue that is in the calendar but has
-- no row for a given future day reads as CLOSED: cal_operating_hours = 0 with a
-- null window, which is the same contract the historical view states for trade
-- ("a closure reads as a zero rather than a missing row").
--   That rule holds only INSIDE the range a venue is actually published over --
--   see cal_venue below for why, and for the two venues it already bites.
--
-- TELLING "CLOSED" APART FROM "NOTHING KNOWN". Two appended columns give a
-- complete 4-state encoding, and HAS_OPENING_CALENDAR alone is not enough:
--
--   HAS_OPENING_CALENDAR  CAL_ROW_PUBLISHED  CAL_OPERATING_HOURS  meaning
--   true                  TRUE               > 0                 window published
--   true                  FALSE              0                   CLOSURE published
--   true                  NULL               null                beyond coverage
--   false                 NULL               null                no calendar ever
--
-- Only the second row is a closure. Both NULL rows mean unknown, and
-- CAL_COVERAGE_END (the venue's last published day) separates them: it is
-- non-null in the third case and null in the fourth. Anything that treats a
-- null CAL_OPERATING_HOURS as zero is asserting a closure the feed never made.
--   Measured 2026-09-02: 12,267 published windows, 2,887 published closures over
--   145 venues, 1,166 unknown cells (1,140 over the 19 no-calendar venues, 26
--   beyond coverage over 2 venues).
--
-- THE NO-CALENDAR HOLE IS CONCENTRATED, AND IT LANDS ON TREATS. 15 of those 19
-- venues are in_training_dataset, and 13 of the 15 are Ice Cream Vans -- there is
-- no rota feed for a van. In revenue terms it is small overall (GBP 339,817 of
-- GBP 57.3m in-training spine revenue over the past 60 days, 0.59%) but it is
-- NOT small where it lands:
--       TREATS      16.96% of category revenue has no calendar
--       BAR          0.48%   (DE Pop-Up Bar, TW Caravel Bar)
--       FASTFOOD     0.00%
--       RESTAURANT   0.00%
-- So for these venues the future view can say who they are but not whether they
-- are open, and TREATS is already the smallest and worst-served population in
-- the model. Anything downstream that gates on an open window will either drop
-- them or need a fallback (a dow/seasonal profile from their own history is the
-- obvious one). This is a data gap upstream, not something this view can fix.
--
-- FOH_CC_OWNED / BOH_CC_OWNED are the handover arbitration over actual rings, so
-- they cannot be derived forward. They are set to the map's has_foh / has_boh
-- flags: the side the venue runs. Where two venues front the same primary cost
-- centre this OVERSTATES ownership -- both will claim it -- because there is no
-- future evidence to break the tie.
--
-- CAVEAT, competition columns: historically these count TRADED hours, here they
-- count PUBLISHED hours. The definitions do not agree, so a model trained on the
-- historical columns and served these sees a shifted feature. Closing that gap
-- means adding cal-based competition columns to the historical view too; it is not
-- fixed here.
create or replace view FNB_RETAIL_FUTURE_FACTS_DAILY_V4 as
with map as (
    select park_code,
           servicing_venue_name,
           venue_category,
           concept,
           is_main,
           venue_cc_id,
           in_training_dataset,
           has_bar_cc                                             as has_foh,
           has_retail_cc                                          as has_boh,
           -- the flag is the authority: an id present without its flag set is
           -- not a side this venue runs, so it must not claim that cost centre
           case when has_bar_cc    then primary_bar_cc_id    end  as foh_cc_id,
           case when has_retail_cc then primary_retail_cc_id end  as boh_cc_id,
           last_transaction_date
    from FNB_RETAIL_VENUE_CC_MAP_V4
),

-- ---------------------------------------------------------------------------
-- RECENT TRADE, built straight off FNB_RETAIL_LINES_V4 rather than off
-- FNB_RETAIL_FACTS_DAILY_V4. This is a performance decision with a correctness
-- argument behind it, not a shortcut.
--
-- Reading the daily view costs 110s+ and cannot be pruned by date: it takes
-- min/max business_date per venue over all history to build its dense spine, so
-- a 60-day predicate still scans every line since 2023. The lines view, by
-- contrast, is a plain date-filtered scan of FCT_EPOS_SALES. Off lines this
-- runs in ~5s.
--
-- It is EXACT, not an approximation, because the handover arbitration is
-- DAY-LOCAL: claims_ranked partitions by (business_date, park_code,
-- cost_centre_code), so which venue owns a cost centre on a given day depends
-- only on that day's lines plus the map's global last_transaction_date. Cutting
-- lines to the window therefore cannot change the answer inside it. The
-- arbitration below is a transcription of the daily view's, with the same
-- tie-break, so the two cannot drift on the days both cover.
--
-- Verified against the daily view on 2026-09-02 over the same window: the
-- eligible venue SET is identical (272 venues, 38 parks, zero either-way
-- difference), per-venue revenue agrees to 6e-11, and per-venue active-day
-- counts agree exactly.
--
-- One knowingly-accepted divergence: a venue whose primary bar and primary
-- retail cost centre are THE SAME code has that cost centre's revenue counted
-- once here and twice by the daily view (which adds foh_serviced + boh_serviced
-- independently). It affects the threshold only, never a published column.
--
-- ACTIVE DAY. The rule's "operation time > 0" is operating_hours > 0, which in
-- the daily view means at least one business hour with >= 1 positive-net-sales
-- order. That is equivalent to "the venue rang at least one line with
-- net_sales_amount > 0 that business day", which is what w_active tests.
-- ---------------------------------------------------------------------------
-- Wide enough on transaction_date to cover the business_date window at both
-- edges: business day d draws hours 08-23 from transaction_date d and hours
-- 00-07 from transaction_date d+1.
win_lines as (
    select park_code,
           servicing_venue_name,
           cost_centre_code,
           net_sales_amount,
           case when transaction_hour <= 7
                then dateadd(day, -1, transaction_date)
                else transaction_date end                        as business_date
    from FNB_RETAIL_LINES_V4
    where transaction_date >= dateadd(day, -61, current_date)
),
-- business_date < current_date: today is partial, so it is not an active day.
w as (
    select * from win_lines
    where business_date >= dateadd(day, -60, current_date)
      and business_date <  current_date
),

-- ---------------------------------------------------------------------------
-- THE HORIZON, ANCHORED ON THE FACTS RATHER THAN THE CLOCK. Whatever reads this
-- view has to join it end-to-end onto the historical one, and current_date does
-- not know when the facts end.
--
-- A BUSINESS DAY ENDS AT 07:00 THE NEXT MORNING (hours 00-07 of d+1 belong to
-- d), so business day current_date - 1 is still IN PROGRESS until 07:00 today
-- and cannot reach the historical view until after that plus the EPOS load.
-- Starting at current_date therefore left a one-day hole on any run before then:
-- measured 2026-09-12 01:06, the historical feed ended 2026-09-10 while this view
-- started 2026-09-12, so 09-11 was in neither. pdfn refuses to run on that
-- (densify_hourly spans a single date_range, so the missing day fills with closed
-- zero-revenue rows and forecasts a shut park), and it recurred nightly rather
-- than being one stale snapshot.
--
-- Anchored off win_lines, which is ALREADY the scan above and already carries the
-- 07:00 business-date expression -- the same lines FNB_RETAIL_FACTS_DAILY_V4 is
-- built from, so this is that view's last business day without paying its 110s
-- dense-spine scan (see the note above) and without a second pass over lines. The
-- seam then holds at any hour of the day with no clock shared between the two.
--
-- THE ANCHOR IS THE LAST *COMPLETE* BUSINESS DAY, hence `< current_date`, and that
-- bound is load-bearing rather than cosmetic. EPOS lands SAME DAY: measured
-- 2026-09-12 10:18, lines already carried 494 rows dated today. Without the bound
-- the anchor would follow them onto the in-progress day the moment any 08:00+ trade
-- arrives, which would (a) treat a few hours of trade as the last full day and
-- (b) push the horizon to tomorrow, so TODAY would never be forecast at all.
--
-- Taking `< current_date` rather than testing the 07:00 boundary is deliberate. A
-- business day is not strictly complete until 07:00 the next morning, so at 01:00
-- "yesterday" is still open -- but its remaining hours are the after-midnight tail,
-- measured at GBP -13 to GBP 1,372 against GBP 340k-875k of day revenue, i.e. 0.0-0.2%.
-- The material distinction is "a whole day" vs "a few morning hours", and the date
-- bound draws exactly that line. Availability binds anyway: if yesterday has not
-- loaded, max() simply returns the last day that has.
--
-- Off win_lines and NOT w: the two bounds differ at the lower edge (w keeps only the
-- trailing 60 days), and the anchor must not inherit that window.
--
-- CONSEQUENCE, and it is the honest reading: the first horizon day may already have
-- TRADED without being loaded, so it is a nowcast, and horizon_day goes 0 or negative
-- on it. That is why horizon_day is published rather than assumed positive.
-- ---------------------------------------------------------------------------
horizon as (
    select dateadd(day, seq4() + 1,
                   (select max(business_date) from win_lines
                     where business_date < current_date))::date     as business_date
    from table(generator(rowcount => 60))
),
w_cc_day as (
    select business_date, park_code, cost_centre_code,
           sum(net_sales_amount)                                 as revenue
    from w group by all
),
w_venue_cc_day as (
    select distinct business_date, park_code, servicing_venue_name, cost_centre_code
    from w
),
w_active as (
    select distinct business_date, park_code, servicing_venue_name
    from w where net_sales_amount > 0
),
w_claims as (
    select d.business_date,
           d.park_code,
           d.cost_centre_code,
           m.servicing_venue_name,
           vcd.servicing_venue_name is not null                  as rang_today,
           m.last_transaction_date
    from w_cc_day d
    join map m
      on  m.park_code = d.park_code
      and d.cost_centre_code in (m.foh_cc_id, m.boh_cc_id)
    left join w_venue_cc_day vcd
      on  vcd.business_date        = d.business_date
      and vcd.park_code            = d.park_code
      and vcd.cost_centre_code     = d.cost_centre_code
      and vcd.servicing_venue_name = m.servicing_venue_name
),
w_ranked as (
    select *,
           row_number() over (
               partition by business_date, park_code, cost_centre_code
               order by case when rang_today then 0 else 1 end,
                        case
                            when rang_today
                                then datediff(day, last_transaction_date, date '2100-01-01')
                            when last_transaction_date >= business_date
                                then datediff(day, business_date, last_transaction_date)
                            else 100000 + datediff(day, last_transaction_date, business_date)
                        end,
                        servicing_venue_name)                     as claim_rank
    from w_claims
),
w_owned as (
    select business_date, park_code, servicing_venue_name, cost_centre_code
    from w_ranked where claim_rank = 1
),
-- Serviced revenue: every cost centre this venue owned that day, whoever rang
-- it. w_owned holds only cost centres that are the venue's own foh/boh primary,
-- so this sum is exactly foh_serviced_revenue + boh_serviced_revenue.
w_rev as (
    select o.business_date, o.park_code, o.servicing_venue_name,
           sum(cd.revenue)                                       as revenue
    from w_owned o
    join w_cc_day cd
      on  cd.business_date    = o.business_date
      and cd.park_code        = o.park_code
      and cd.cost_centre_code = o.cost_centre_code
    group by all
),
-- Rank over ACTIVE days only, so "last 30 active days" skips closures rather
-- than counting them, and a venue with fewer than 30 active days in the window
-- is judged on however many it has.
recent as (
    select a.park_code,
           a.servicing_venue_name,
           a.business_date,
           coalesce(r.revenue, 0)                                as revenue,
           row_number() over (
               partition by a.park_code, a.servicing_venue_name
               order by a.business_date desc)                     as active_day_rank
    from w_active a
    left join w_rev r
      on  r.business_date        = a.business_date
      and r.park_code            = a.park_code
      and r.servicing_venue_name = a.servicing_venue_name
),
transacting as (
    select park_code, servicing_venue_name
    from recent
    where active_day_rank <= 30
    group by all
    having sum(revenue) >= 1000
),
spine as (
    select t.park_code, t.servicing_venue_name, h.business_date
    from transacting t
    cross join horizon h
),

-- Published opening calendar. Parsed exactly as the historical view parses it --
-- same session envelope, same boundary-to-last-hour conversion, same sanity drop --
-- so the two views cannot disagree about what a published window means.
cal_raw as (
    select park_code,
           workforce_venue_code,
           day_date,
           try_to_number(split_part(open,  ':', 1))               as open_h,
           try_to_number(split_part(close, ':', 1))               as close_h,
           try_to_number(split_part(close, ':', 2))               as close_m
    from HAVEN_BASE.COMMON.PARK_VENUE_OPENING_CALENDAR
    where opening_type = 'venue'
      and open  is not null
      and close is not null
),
cal_hour as (
    select park_code,
           workforce_venue_code,
           day_date,
           open_h                                                 as open_index,
           -- A published close is a boundary time, but every other window in the
           -- historical view is a last-traded hour, so convert: a boundary on the
           -- hour means the previous hour was the last one, a boundary at :30
           -- means trade ran into that hour. A close at or before the opening
           -- time has run past midnight, but only inside the 07:00 business-day
           -- boundary -- a close at a daytime hour before its own opening is
           -- contradictory data, dropped below rather than read as a 23-hour day.
           ceil(case when close_h + close_m / 60.0 <= 7
                     then close_h + close_m / 60.0 + 24
                     else close_h + close_m / 60.0 end) - 1       as close_index
    from cal_raw
),
cal_sane as (
    select * from cal_hour where close_index > open_index
),
-- Some venue-days publish more than one session (305 of 14,049 in the horizon);
-- take the outer envelope. This must happen on the wrapped indices, not the raw
-- strings, or a midnight close would sort as the earliest time of the day.
cal_day as (
    select park_code,
           workforce_venue_code,
           day_date,
           min(open_index)                                        as open_index,
           max(close_index)                                       as close_index
    from cal_sane
    group by all
),
-- Whether the venue has an opening calendar AT ALL, over its whole published
-- history and not just the horizon -- same definition as the historical view's
-- has_opening_calendar -- PLUS the span it is published over.
--
-- The span is what makes "missing row = closed" safe. That rule is only a valid
-- reading INSIDE the range a venue is actually published over; past the end of
-- its coverage there is no rota to be absent from, so a missing row means
-- UNKNOWN and must not be reported as a closure. Without this, a venue whose
-- rota simply has not been loaded yet reads as 60 consecutive published
-- closures, and a model would confidently predict zero revenue for it.
--
-- This is not hypothetical. Measured 2026-09-02: BR Box Bar and BR Seaside
-- Treats (both in_training) are published only to 2026-10-18 against a horizon
-- ending 2026-10-31, which is 26 daily cells. It grows without bound as
-- current_date advances past a venue's last publication.
cal_venue as (
    select park_code,
           workforce_venue_code,
           min(day_date)                                          as cal_coverage_start,
           max(day_date)                                          as cal_coverage_end
    from cal_day
    group by all
),
-- The window for a future day is the row published FOR that day. No carry-forward:
-- see the header.
cal_window as (
    select s.business_date,
           s.park_code,
           s.servicing_venue_name,
           cd.open_index                                          as cal_open_index,
           cd.close_index                                         as cal_close_index
    from spine s
    join map m
      on  m.park_code            = s.park_code
      and m.servicing_venue_name = s.servicing_venue_name
    join cal_day cd
      on  cd.park_code            = s.park_code
      and cd.workforce_venue_code = m.venue_cc_id
      and cd.day_date             = s.business_date
),
-- Every published-calendar output column, computed ONCE here so the raw and core
-- families below can proxy them by reference. Repeating the expressions instead is
-- exactly how the three families would silently drift apart.
cal_cols as (
    select s.business_date,
           s.park_code,
           s.servicing_venue_name,
           cv.workforce_venue_code is not null                    as has_opening_calendar,
           mod(cw.cal_open_index, 24)                             as cal_open_hour,
           case when cw.cal_close_index + 1 >= 25 then 1
                when cw.cal_close_index + 1  = 24 then 0
                else cw.cal_close_index + 1 end                   as cal_close_hour,
           -- A window if one is published; an asserted 0 if the day falls inside
           -- the venue's published coverage with no row (a closure); null if the
           -- day is outside that coverage, or the venue has no calendar at all.
           case when cw.cal_open_index is not null
                     then cw.cal_close_index - cw.cal_open_index + 1
                when s.business_date between cv.cal_coverage_start and cv.cal_coverage_end
                     then 0
           end                                                    as cal_operating_hours,
           case when cw.cal_open_index is not null
                     then cw.cal_close_index >= 24
                when s.business_date between cv.cal_coverage_start and cv.cal_coverage_end
                     then false
           end                                                    as cal_closes_after_midnight,
           cw.cal_open_index                                      as cal_open_index,
           cw.cal_close_index + 1                                 as cal_close_index,
           -- Nothing is carried in this view, so a window is never inherited.
           case when cw.cal_open_index is not null then false end  as cal_is_carried,
           case when cw.cal_open_index is not null
                then s.business_date end                          as cal_published_date,
           case when cw.cal_open_index is not null
                     then true
                when s.business_date between cv.cal_coverage_start and cv.cal_coverage_end
                     then false
           end                                                    as cal_row_published,
           cv.cal_coverage_end                                    as cal_coverage_end
    from spine s
    join map m
      on  m.park_code            = s.park_code
      and m.servicing_venue_name = s.servicing_venue_name
    left join cal_venue cv
      on  cv.park_code            = s.park_code
      and cv.workforce_venue_code = m.venue_cc_id
    left join cal_window cw
      on  cw.business_date        = s.business_date
      and cw.park_code            = s.park_code
      and cw.servicing_venue_name = s.servicing_venue_name
),

assembled as (
select s.business_date,
       s.park_code,
       s.servicing_venue_name,

       -- Constant true, as in the historical view: the map join is an inner join,
       -- so a venue absent from the map is dropped rather than flagged.
       m.park_code is not null                                      as venue_is_mapped,

       m.venue_category,
       m.concept,
       m.is_main,
       m.venue_cc_id,
       m.in_training_dataset,

       m.has_foh,
       m.foh_cc_id,
       m.has_boh,
       m.boh_cc_id,

       -- PROXIED FROM THE CALENDAR, not null. There is no transaction-derived
       -- window in the future, so rather than publish nulls these two families
       -- mirror CAL_* exactly, which makes the view a drop-in for anything reading
       -- OPEN_* or CORE_* -- notably the panel, which reads CORE_*.
       --
       -- Read them as "the best available statement of the window", not as a
       -- measurement, because three things differ from history:
       --   * this is the PUBLISHED window, so it includes hours that will not
       --     trade and excludes any unpublished overrun. CORE_* historically is
       --     the TRADED window with quiet edges trimmed, so it is systematically
       --     tighter than what appears here.
       --   * OPEN_* and CORE_* are IDENTICAL here, where historically they differ.
       --     Nothing downstream may infer the edge-trimming from their difference.
       --   * unlike history, OPERATING_HOURS can be NULL -- on the 19 venues with
       --     no calendar. History coalesces it to 0 and so never has a null there,
       --     which makes this view the first place a non-null assumption breaks.
       --     It is deliberately NOT coalesced: 0 would assert a closure.
       --
       -- TRADING_HOURS has no future-known analogue at all -- it counts hours that
       -- actually took an order. It is proxied with the published span, i.e. on the
       -- assumption that every published open hour trades. That is an assumption,
       -- not a fact, which is why CAL_TRADING_HOURS below stays null: it is the
       -- measured version of the same quantity and there is nothing to measure.
       c.cal_open_hour::number(3,0)                                 as open_hour,
       c.cal_close_hour::number(4,0)                                as close_hour,
       c.cal_operating_hours::number(5,0)                           as operating_hours,
       c.cal_closes_after_midnight                                  as closes_after_midnight,
       c.cal_open_index::number(3,0)                                as open_index,
       c.cal_close_index::number(4,0)                               as close_index,
       c.cal_operating_hours::number(18,0)                          as trading_hours,

       -- Core window: the same proxy, hence identical to the raw family above by
       -- construction. Both have exactly one source.
       c.cal_open_hour::number(3,0)                                 as core_open_hour,
       c.cal_close_hour::number(4,0)                                as core_close_hour,
       c.cal_operating_hours::number(5,0)                           as core_operating_hours,
       c.cal_closes_after_midnight                                  as core_closes_after_midnight,
       c.cal_open_index::number(3,0)                                as core_open_index,
       c.cal_close_index::number(4,0)                               as core_close_index,
       c.cal_operating_hours::number(18,0)                          as core_trading_hours,

       -- The published calendar itself: the single source everything above proxies.
       c.has_opening_calendar,
       c.cal_open_hour,
       c.cal_close_hour,
       c.cal_operating_hours,
       c.cal_closes_after_midnight,
       c.cal_open_index,
       c.cal_close_index,
       -- Hours that actually transacted inside the published window: a fact.
       cast(null as number(18,0))                                   as cal_trading_hours,
       c.cal_is_carried,
       c.cal_published_date,

       -- No future evidence for the handover arbitration, so fall back to the side
       -- the venue runs. Overstates ownership on shared primaries -- see header.
       m.has_foh                                                    as foh_cc_owned,
       m.has_boh                                                    as boh_cc_owned,

       -- The target and everything correlated with it.
       cast(null as number(37,4))                                   as foh_serviced_revenue,
       cast(null as number(18,0))                                   as foh_serviced_orders,
       cast(null as float)                                          as foh_serviced_items,
       cast(null as number(32,6))                                   as foh_serviced_transactions,
       cast(null as number(37,4))                                   as boh_serviced_revenue,
       cast(null as number(18,0))                                   as boh_serviced_orders,
       cast(null as float)                                          as boh_serviced_items,
       cast(null as number(32,6))                                   as boh_serviced_transactions,

       cast(null as number(38,4))                                   as foh_taken_revenue,
       cast(null as number(30,0))                                   as foh_taken_orders,
       cast(null as float)                                          as foh_taken_items,
       cast(null as number(38,6))                                   as foh_taken_transactions,
       cast(null as number(38,4))                                   as boh_taken_revenue,
       cast(null as number(30,0))                                   as boh_taken_orders,
       cast(null as float)                                          as boh_taken_items,
       cast(null as number(38,6))                                   as boh_taken_transactions,

       -- Appended after the historical columns, so a by-name reader is unaffected.
       -- Crossed with has_opening_calendar this is a complete 4-state encoding:
       --   has_cal   published   meaning
       --   true      TRUE        a window is published for this venue-day
       --   true      FALSE       a CLOSURE is published: an asserted zero
       --   true      NULL        beyond this venue's published coverage: UNKNOWN
       --   false     NULL        venue has no opening calendar at all: UNKNOWN
       c.cal_row_published,
       -- The last day this venue is published for. Exposed so the two UNKNOWN
       -- states are distinguishable and so a shrinking rota horizon is visible
       -- from the data rather than only from a coverage query.
       c.cal_coverage_end,
       -- Deliberately still measured from CURRENT_DATE and not from the anchor: the
       -- question this answers is "how far ahead of NOW is this row", which is what
       -- makes a stale snapshot visible. It goes 0 or NEGATIVE on the first day or
       -- two of the horizon, because those business days have already happened but
       -- have not been loaded yet -- re-anchoring it would force it to 1..60 and hide
       -- exactly that. A consumer wanting position in the horizon should subtract the
       -- minimum, not read this as an offset.
       datediff(day, current_date, s.business_date)                 as horizon_day

from spine s
join map m
  on  m.park_code            = s.park_code
  and m.servicing_venue_name = s.servicing_venue_name
join cal_cols c
  on  c.business_date        = s.business_date
  and c.park_code            = s.park_code
  and c.servicing_venue_name = s.servicing_venue_name
)

-- Competition, mirroring the historical view's shape exactly: park-day totals via
-- window functions minus the row's own contribution, populated only for rows that
-- are themselves in the training set. The one substitution is the openness test --
-- cal_operating_hours rather than operating_hours -- because the published window
-- is the only one that exists here. A venue with no calendar contributes nothing
-- to the pool, the same way a venue that did not trade contributes nothing in the
-- historical view.
select a.* exclude (cal_row_published, cal_coverage_end, horizon_day),

       case when a.in_training_dataset then
            count(case when a.in_training_dataset and a.cal_operating_hours > 0
                       then 1 end) over (partition by a.park_code, a.business_date)
            - iff(a.in_training_dataset and a.cal_operating_hours > 0, 1, 0)
       end                                                          as other_venues_open,

       case when a.in_training_dataset then
            coalesce(sum(case when a.in_training_dataset then a.cal_operating_hours end)
                     over (partition by a.park_code, a.business_date), 0)
            - coalesce(iff(a.in_training_dataset, a.cal_operating_hours, 0), 0)
       end::number(18,0)                                            as other_venues_open_hours,

       case when a.in_training_dataset then
            count(case when a.in_training_dataset and a.cal_operating_hours > 0
                       then 1 end) over (partition by a.park_code, a.business_date,
                                                      coalesce(a.venue_category, 'OTHER'))
            - iff(a.in_training_dataset and a.cal_operating_hours > 0, 1, 0)
       end                                                          as same_category_venues_open,

       case when a.in_training_dataset then
            coalesce(sum(case when a.in_training_dataset then a.cal_operating_hours end)
                     over (partition by a.park_code, a.business_date,
                                        coalesce(a.venue_category, 'OTHER')), 0)
            - coalesce(iff(a.in_training_dataset, a.cal_operating_hours, 0), 0)
       end::number(18,0)                                            as same_category_venues_open_hours,

       a.cal_row_published,
       a.cal_coverage_end,
       a.horizon_day

from assembled a
