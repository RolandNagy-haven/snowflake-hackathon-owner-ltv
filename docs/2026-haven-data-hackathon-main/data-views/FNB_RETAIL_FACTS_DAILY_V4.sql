create or replace view FNB_RETAIL_FACTS_DAILY_V4 as
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

-- 07:00 is a single business-day separator: hours 00-07 belong to the previous
-- day's operation, so late-night service stays whole and no hour is orphaned.
-- business_hour is a monotone index across the boundary, 08..31.
lines as (
    select park_code,
           servicing_venue_name,
           cc_division,
           cost_centre_code,
           order_number,
           net_sales_amount,
           quantity,
           apportioned_transactions,
           case when transaction_hour <= 7
                then dateadd(day, -1, transaction_date)
                else transaction_date end                          as business_date,
           case when transaction_hour <= 7
                then transaction_hour + 24
                else transaction_hour end                          as business_hour
    from FNB_RETAIL_LINES_V4
),

-- cost-centre-complete: the whole cost centre's trade for the day, whichever
-- venue rang it.
cc_day as (
    select business_date,
           park_code,
           cost_centre_code,
           sum(net_sales_amount)            as revenue,
           count(distinct order_number)     as orders,
           sum(quantity)                    as items,
           sum(apportioned_transactions)    as transactions
    from lines
    group by all
),

-- venue-complete: only the lines this venue rang, split by division, across
-- every cost centre it touched.
venue_div_day as (
    select business_date,
           park_code,
           servicing_venue_name,
           cc_division,
           sum(net_sales_amount)            as revenue,
           count(distinct order_number)     as orders,
           sum(quantity)                    as items,
           sum(apportioned_transactions)    as transactions
    from lines
    group by all
),
venue_day as (
    select business_date,
           park_code,
           servicing_venue_name,
           sum(case when cc_division = 'Bars'            then revenue      end) as foh_taken_revenue,
           sum(case when cc_division = 'Bars'            then orders       end) as foh_taken_orders,
           sum(case when cc_division = 'Bars'            then items        end) as foh_taken_items,
           sum(case when cc_division = 'Bars'            then transactions end) as foh_taken_transactions,
           sum(case when cc_division = 'Retail Catering' then revenue      end) as boh_taken_revenue,
           sum(case when cc_division = 'Retail Catering' then orders       end) as boh_taken_orders,
           sum(case when cc_division = 'Retail Catering' then items        end) as boh_taken_items,
           sum(case when cc_division = 'Retail Catering' then transactions end) as boh_taken_transactions
    from venue_div_day
    group by all
),

-- synthetic trading window. An hour trades on >= 1 positive order, which also
-- excludes hours holding nothing but refunds.
hour_txns as (
    select business_date,
           park_code,
           servicing_venue_name,
           business_hour,
           count(distinct case when net_sales_amount > 0 then order_number end) as pos_orders
    from lines
    group by all
),
trading_hour as (
    select * from hour_txns where pos_orders >= 1
),
venue_hours as (
    select business_date,
           park_code,
           servicing_venue_name,
           min(business_hour)               as open_index,
           max(business_hour)               as close_index,
           count(*)                         as trading_hours
    from trading_hour
    group by all
),

-- Guarded window. A volume threshold cannot separate a stray ring from a
-- genuine soft opening, so segment the day into runs of near-contiguous
-- trading hours -- a new run starts wherever a silent hour intervenes -- and
-- keep only the span from the first to the last run that sustains real trade
-- (an hour of >= 3 orders). Isolated low-volume edges are trimmed however many
-- there are; soft openings that flow into real trade are kept.
gapped as (
    select *,
           case when business_hour
                     - lag(business_hour) over (
                         partition by business_date, park_code, servicing_venue_name
                         order by business_hour) >= 2
                     or lag(business_hour) over (
                         partition by business_date, park_code, servicing_venue_name
                         order by business_hour) is null
                then 1 else 0 end            as is_run_start
    from trading_hour
),
runs as (
    select *,
           sum(is_run_start) over (
               partition by business_date, park_code, servicing_venue_name
               order by business_hour
               rows between unbounded preceding and current row) as run_id
    from gapped
),
run_agg as (
    select business_date,
           park_code,
           servicing_venue_name,
           run_id,
           max(pos_orders)                  as run_peak_orders,
           min(business_hour)               as run_open,
           max(business_hour)               as run_close
    from runs
    group by all
),
core_span as (
    select business_date,
           park_code,
           servicing_venue_name,
           min(run_open)                    as core_open_index,
           max(run_close)                   as core_close_index
    from run_agg
    where run_peak_orders >= 3
    group by all
),
core_hours as (
    select cs.business_date,
           cs.park_code,
           cs.servicing_venue_name,
           cs.core_open_index,
           cs.core_close_index,
           count(t.business_hour)           as core_trading_hours
    from core_span cs
    join trading_hour t
      on  t.business_date        = cs.business_date
      and t.park_code            = cs.park_code
      and t.servicing_venue_name = cs.servicing_venue_name
      and t.business_hour between cs.core_open_index and cs.core_close_index
    group by all
),

-- Which venue rang a given cost centre on a given day. Evidence for resolving
-- handovers where two venues front the same primary cost centre.
venue_cc_day as (
    select distinct business_date, park_code, servicing_venue_name, cost_centre_code
    from lines
),

-- Every (cost centre, day) that traded, paired with each venue fronting that
-- cost centre as a primary. Shared primaries are handovers, so exactly one
-- venue must own the day.
claims as (
    select d.business_date,
           d.park_code,
           d.cost_centre_code,
           m.servicing_venue_name,
           vcd.servicing_venue_name is not null                    as rang_today,
           m.last_transaction_date
    from cc_day d
    join map m
      on  m.park_code = d.park_code
      and d.cost_centre_code in (m.foh_cc_id, m.boh_cc_id)
    left join venue_cc_day vcd
      on  vcd.business_date         = d.business_date
      and vcd.park_code             = d.park_code
      and vcd.cost_centre_code      = d.cost_centre_code
      and vcd.servicing_venue_name  = m.servicing_venue_name
),
claims_ranked as (
    select *,
           row_number() over (
               partition by business_date, park_code, cost_centre_code
               order by case when rang_today then 0 else 1 end,
                        case
                            -- a venue that rang the cc today owns it; on a true
                            -- overlap the later last_transaction_date wins
                            when rang_today
                                then datediff(day, last_transaction_date, date '2100-01-01')
                            -- nobody rang it: nearest trading boundary wins, so
                            -- pre-handover days stay with the incumbent
                            when last_transaction_date >= business_date
                                then datediff(day, business_date, last_transaction_date)
                            else 100000 + datediff(day, last_transaction_date, business_date)
                        end,
                        servicing_venue_name)                       as claim_rank
    from claims
),
cc_owned as (
    select business_date, park_code, servicing_venue_name, cost_centre_code
    from claims_ranked
    where claim_rank = 1
),

-- Gapless spine: every day between a venue's first and last transacting day,
-- so a closure reads as a zero rather than a missing row. Days outside that
-- range are not invented, and cost-centre-owned days beyond it are still kept.
base_spine as (
    select business_date, park_code, servicing_venue_name from venue_day
    union
    select business_date, park_code, servicing_venue_name from cc_owned
),
venue_range as (
    select park_code,
           servicing_venue_name,
           min(business_date)               as first_day,
           max(business_date)               as last_day
    from base_spine
    group by all
),
day_seq as (
    select dateadd(day, seq4(), date '2022-12-01')::date as business_date
    from table(generator(rowcount => 2600))
),
dense_spine as (
    select r.park_code, r.servicing_venue_name, d.business_date
    from venue_range r
    join day_seq d
      on d.business_date between r.first_day and r.last_day
),
spine as (
    select business_date, park_code, servicing_venue_name from dense_spine
),

-- Published opening calendar, live from 2026-04-19 and rolled out gradually.
-- Only opening_type = 'venue' is the physical venue window; 'collection' and
-- 'delivery' are service channels over the same venue-day.
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
           -- A published close is a boundary time, but every other window in
           -- this view is a last-traded hour, so convert: a boundary on the
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
-- Some venue-days publish more than one session; take the outer envelope. This
-- must happen on the wrapped indices, not the raw strings, or a midnight close
-- would sort as the earliest time of the day rather than the latest.
cal_day as (
    select park_code,
           workforce_venue_code,
           day_date,
           min(open_index)                                        as open_index,
           max(close_index)                                       as close_index
    from cal_sane
    group by all
),
cal_venue as (
    select distinct park_code, workforce_venue_code from cal_day
),
-- Carry each published day forward until the next one supersedes it, so a
-- business day with no row of its own inherits the last published window.
-- Bounded deliberately: a window is never taken from a day later than the one
-- being described, which would leak future publications into past rows.
cal_span as (
    select park_code,
           workforce_venue_code,
           open_index,
           close_index,
           day_date                                               as valid_from,
           coalesce(lead(day_date) over (
                        partition by park_code, workforce_venue_code
                        order by day_date),
                    date '9999-12-31')                            as valid_to
    from cal_day
),
cal_window as (
    select s.business_date,
           s.park_code,
           s.servicing_venue_name,
           cs.open_index                                          as cal_open_index,
           cs.close_index                                         as cal_close_index,
           s.business_date <> cs.valid_from                       as cal_is_carried,
           cs.valid_from                                          as cal_published_date
    from spine s
    join map m
      on  m.park_code            = s.park_code
      and m.servicing_venue_name = s.servicing_venue_name
    join cal_span cs
      on  cs.park_code            = s.park_code
      and cs.workforce_venue_code = m.venue_cc_id
      and s.business_date >= cs.valid_from
      and s.business_date <  cs.valid_to
),
-- Hours that actually transacted inside the published window.
cal_trading as (
    select cw.business_date,
           cw.park_code,
           cw.servicing_venue_name,
           count(t.business_hour)                                 as cal_trading_hours
    from cal_window cw
    join trading_hour t
      on  t.business_date        = cw.business_date
      and t.park_code            = cw.park_code
      and t.servicing_venue_name = cw.servicing_venue_name
      and t.business_hour between cw.cal_open_index and cw.cal_close_index
    group by all
),

assembled as (
select s.business_date,
       s.park_code,
       s.servicing_venue_name,

       -- Constant true: the map join is an inner join, so a venue absent from
       -- the map is dropped rather than flagged. Kept as an explicit contract
       -- that every row here is a mapped venue.
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

       -- Trading window, every hour that took an order. open/close are clock
       -- labels: an hour-23 finish reads as midnight and anything past midnight
       -- reads uniformly as 01:00, whatever the true hour. Those labels wrap,
       -- so they cannot be subtracted -- operating_hours is computed off the
       -- monotone indices.
       -- open is a start time, so it reads straight off the clock: business hour
       -- 23 opened at 23:00, and an after-midnight first ring reads as its real
       -- hour rather than collapsing the way a close does.
       mod(h.open_index, 24)                                        as open_hour,
       -- close is the boundary the venue stopped trading at, not the last hour
       -- it traded in: a ring at 21:30 means it closed at 22:00. Hour 23 there-
       -- fore closes at midnight, and any close past midnight caps at 01:00.
       case when h.close_index + 1 >= 25 then 1
            when h.close_index + 1  = 24 then 0
            else h.close_index + 1 end                              as close_hour,
       coalesce(h.close_index - h.open_index + 1, 0)                as operating_hours,
       h.close_index >= 24                                          as closes_after_midnight,
       h.open_index,
       h.close_index + 1                                            as close_index,
       coalesce(h.trading_hours, 0)                                 as trading_hours,

       -- Same window with isolated low-volume edges trimmed. Null when no hour
       -- reached 3 orders, i.e. the day never sustained identifiable trade.
       mod(c.core_open_index, 24)                                   as core_open_hour,
       case when c.core_close_index + 1 >= 25 then 1
            when c.core_close_index + 1  = 24 then 0
            else c.core_close_index + 1 end                         as core_close_hour,
       coalesce(c.core_close_index - c.core_open_index + 1, 0)      as core_operating_hours,
       c.core_close_index >= 24                                     as core_closes_after_midnight,
       c.core_open_index,
       c.core_close_index + 1                                       as core_close_index,
       coalesce(c.core_trading_hours, 0)                            as core_trading_hours,

       -- Published opening calendar. Null where the venue has no calendar
       -- match at all, and for business days before its first publication.
       cv.workforce_venue_code is not null                          as has_opening_calendar,
       mod(cw.cal_open_index, 24)                                   as cal_open_hour,
       case when cw.cal_close_index + 1 >= 25 then 1
            when cw.cal_close_index + 1  = 24 then 0
            else cw.cal_close_index + 1 end                         as cal_close_hour,
       cw.cal_close_index - cw.cal_open_index + 1                    as cal_operating_hours,
       cw.cal_close_index >= 24                                     as cal_closes_after_midnight,
       cw.cal_open_index,
       cw.cal_close_index + 1                                       as cal_close_index,
       case when cw.cal_open_index is not null
            then coalesce(ct.cal_trading_hours, 0) end              as cal_trading_hours,
       cw.cal_is_carried,
       cw.cal_published_date,

       -- which side's cost centre this venue won for the day. Exposed so the
       -- hourly view can attribute cost-centre trade without re-deriving the
       -- handover arbitration and risking a different answer.
       ob.cost_centre_code  is not null                             as foh_cc_owned,
       orl.cost_centre_code is not null                             as boh_cc_owned,

       -- primary cost centre totals: everything booked to that cost centre,
       -- regardless of which venue rang it
       coalesce(bcc.revenue,      0) as foh_serviced_revenue,
       coalesce(bcc.orders,       0) as foh_serviced_orders,
       coalesce(bcc.items,        0) as foh_serviced_items,
       coalesce(bcc.transactions, 0) as foh_serviced_transactions,
       coalesce(rcc.revenue,      0) as boh_serviced_revenue,
       coalesce(rcc.orders,       0) as boh_serviced_orders,
       coalesce(rcc.items,        0) as boh_serviced_items,
       coalesce(rcc.transactions, 0) as boh_serviced_transactions,

       -- venue totals: everything this venue rang, across every cost centre
       coalesce(vd.foh_taken_revenue,         0) as foh_taken_revenue,
       coalesce(vd.foh_taken_orders,          0) as foh_taken_orders,
       coalesce(vd.foh_taken_items,           0) as foh_taken_items,
       coalesce(vd.foh_taken_transactions,    0) as foh_taken_transactions,
       coalesce(vd.boh_taken_revenue,      0) as boh_taken_revenue,
       coalesce(vd.boh_taken_orders,       0) as boh_taken_orders,
       coalesce(vd.boh_taken_items,        0) as boh_taken_items,
       coalesce(vd.boh_taken_transactions, 0) as boh_taken_transactions

from spine s
join map m
  on  m.park_code            = s.park_code
  and m.servicing_venue_name = s.servicing_venue_name
left join venue_hours h
  on  h.business_date        = s.business_date
  and h.park_code            = s.park_code
  and h.servicing_venue_name = s.servicing_venue_name
left join core_hours c
  on  c.business_date        = s.business_date
  and c.park_code            = s.park_code
  and c.servicing_venue_name = s.servicing_venue_name
left join cal_venue cv
  on  cv.park_code            = s.park_code
  and cv.workforce_venue_code = m.venue_cc_id
left join cal_window cw
  on  cw.business_date        = s.business_date
  and cw.park_code            = s.park_code
  and cw.servicing_venue_name = s.servicing_venue_name
left join cal_trading ct
  on  ct.business_date        = s.business_date
  and ct.park_code            = s.park_code
  and ct.servicing_venue_name = s.servicing_venue_name
left join cc_owned ob
  on  ob.business_date        = s.business_date
  and ob.park_code            = s.park_code
  and ob.servicing_venue_name = s.servicing_venue_name
  and ob.cost_centre_code     = m.foh_cc_id
left join cc_day bcc
  on  bcc.business_date    = s.business_date
  and bcc.park_code        = s.park_code
  and bcc.cost_centre_code = ob.cost_centre_code
left join cc_owned orl
  on  orl.business_date        = s.business_date
  and orl.park_code            = s.park_code
  and orl.servicing_venue_name = s.servicing_venue_name
  and orl.cost_centre_code     = m.boh_cc_id
left join cc_day rcc
  on  rcc.business_date    = s.business_date
  and rcc.park_code        = s.park_code
  and rcc.cost_centre_code = orl.cost_centre_code
left join venue_day vd
  on  vd.business_date        = s.business_date
  and vd.park_code            = s.park_code
  and vd.servicing_venue_name = s.servicing_venue_name
)

-- Competition: how much other trading capacity was live in the same park on the
-- same business day. Park-day totals via window functions minus the row's own
-- contribution, so no self-join is needed. The pool counts only venues in the
-- training set that actually traded that day, and the figures are only
-- populated for rows that are themselves in the training set -- comparing a
-- non-modelled venue against the pool would be meaningless.
select a.*,

       case when a.in_training_dataset then
            count(case when a.in_training_dataset and a.operating_hours > 0
                       then 1 end) over (partition by a.park_code, a.business_date)
            - iff(a.in_training_dataset and a.operating_hours > 0, 1, 0)
       end                                                          as other_venues_open,

       case when a.in_training_dataset then
            coalesce(sum(case when a.in_training_dataset then a.operating_hours end)
                     over (partition by a.park_code, a.business_date), 0)
            - coalesce(iff(a.in_training_dataset, a.operating_hours, 0), 0)
       end                                                          as other_venues_open_hours,

       case when a.in_training_dataset then
            count(case when a.in_training_dataset and a.operating_hours > 0
                       then 1 end) over (partition by a.park_code, a.business_date,
                                                      coalesce(a.venue_category, 'OTHER'))
            - iff(a.in_training_dataset and a.operating_hours > 0, 1, 0)
       end                                                          as same_category_venues_open,

       case when a.in_training_dataset then
            coalesce(sum(case when a.in_training_dataset then a.operating_hours end)
                     over (partition by a.park_code, a.business_date,
                                        coalesce(a.venue_category, 'OTHER')), 0)
            - coalesce(iff(a.in_training_dataset, a.operating_hours, 0), 0)
       end                                                          as same_category_venues_open_hours

from assembled a
