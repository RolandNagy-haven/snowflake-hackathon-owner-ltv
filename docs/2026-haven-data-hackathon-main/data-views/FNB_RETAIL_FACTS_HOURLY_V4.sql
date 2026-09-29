create or replace view FNB_RETAIL_FACTS_HOURLY_V4 as
-- Hourly counterpart of V3_VENUE_DAILY_V4. Every venue-day is expanded to the
-- full 24 business hours (index 08..31 under the 07:00 separator), so closed
-- hours read as zeros rather than absent rows. Daily context -- windows, cost
-- centre ownership, map attributes -- is taken from the daily view so the two
-- can never disagree.
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
           foh_cc_owned,
           has_boh,
           boh_cc_id,
           boh_cc_owned,
           open_index,
           close_index,
           operating_hours,
           core_open_index,
           core_close_index,
           core_operating_hours,
           has_opening_calendar,
           cal_open_index,
           cal_close_index,
           cal_operating_hours,
           cal_is_carried
    from FNB_RETAIL_FACTS_DAILY_V4
),
hour_slots as (
    select 8 + seq4() as business_hour
    from table(generator(rowcount => 24))
),

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

-- venue-complete, per hour: only what this venue rang.
taken_hour as (
    select business_date,
           park_code,
           servicing_venue_name,
           business_hour,
           sum(case when cc_division = 'Bars'            then net_sales_amount end)         as foh_taken_revenue,
           count(distinct case when cc_division = 'Bars' then order_number end)             as foh_taken_orders,
           sum(case when cc_division = 'Bars'            then quantity end)                 as foh_taken_items,
           sum(case when cc_division = 'Bars'            then apportioned_transactions end) as foh_taken_transactions,
           sum(case when cc_division = 'Retail Catering' then net_sales_amount end)         as boh_taken_revenue,
           count(distinct case when cc_division = 'Retail Catering' then order_number end)  as boh_taken_orders,
           sum(case when cc_division = 'Retail Catering' then quantity end)                 as boh_taken_items,
           sum(case when cc_division = 'Retail Catering' then apportioned_transactions end) as boh_taken_transactions
    from lines
    group by all
),

-- cost-centre-complete, per hour: the whole cost centre's trade whoever rang it.
cc_hour as (
    select business_date,
           park_code,
           cost_centre_code,
           business_hour,
           sum(net_sales_amount)            as revenue,
           count(distinct order_number)     as orders,
           sum(quantity)                    as items,
           sum(apportioned_transactions)    as transactions
    from lines
    group by all
),

spine as (
    select d.*, h.business_hour
    from daily d
    cross join hour_slots h
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

           -- close_index is the boundary the venue stopped at, so the last hour
           -- it was actually open is close_index - 1.
           iff(s.open_index is not null
               and s.business_hour between s.open_index and s.close_index - 1, 1, 0) as is_open_hour,
           iff(s.core_open_index is not null
               and s.business_hour between s.core_open_index and s.core_close_index - 1, 1, 0) as core_is_open_hour,
           -- null, not 0, where nothing was published: the calendar is silent
           -- rather than asserting the venue was shut.
           case when s.cal_open_index is not null
                then iff(s.business_hour between s.cal_open_index and s.cal_close_index - 1, 1, 0)
           end                                                      as cal_is_open_hour,

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

           coalesce(fcc.revenue,      0)                            as foh_serviced_revenue,
           coalesce(fcc.orders,       0)                            as foh_serviced_orders,
           coalesce(fcc.items,        0)                            as foh_serviced_items,
           coalesce(fcc.transactions, 0)                            as foh_serviced_transactions,
           coalesce(bcc.revenue,      0)                            as boh_serviced_revenue,
           coalesce(bcc.orders,       0)                            as boh_serviced_orders,
           coalesce(bcc.items,        0)                            as boh_serviced_items,
           coalesce(bcc.transactions, 0)                            as boh_serviced_transactions,

           coalesce(t.foh_taken_revenue,      0)                    as foh_taken_revenue,
           coalesce(t.foh_taken_orders,       0)                    as foh_taken_orders,
           coalesce(t.foh_taken_items,        0)                    as foh_taken_items,
           coalesce(t.foh_taken_transactions, 0)                    as foh_taken_transactions,
           coalesce(t.boh_taken_revenue,      0)                    as boh_taken_revenue,
           coalesce(t.boh_taken_orders,       0)                    as boh_taken_orders,
           coalesce(t.boh_taken_items,        0)                    as boh_taken_items,
           coalesce(t.boh_taken_transactions, 0)                    as boh_taken_transactions

    from spine s
    left join taken_hour t
      on  t.business_date        = s.business_date
      and t.park_code            = s.park_code
      and t.servicing_venue_name = s.servicing_venue_name
      and t.business_hour        = s.business_hour
    -- cost centre trade only reaches the venue that won the day's arbitration,
    -- so a handover pair never both claim the same hour
    left join cc_hour fcc
      on  s.foh_cc_owned
      and fcc.business_date    = s.business_date
      and fcc.park_code        = s.park_code
      and fcc.cost_centre_code = s.foh_cc_id
      and fcc.business_hour    = s.business_hour
    left join cc_hour bcc
      on  s.boh_cc_owned
      and bcc.business_date    = s.business_date
      and bcc.park_code        = s.park_code
      and bcc.cost_centre_code = s.boh_cc_id
      and bcc.business_hour    = s.business_hour
)

-- Competition recomputed per hour: how many other training-set venues in the
-- park had this same hour inside their trading window.
select a.*,

       case when a.in_training_dataset then
            sum(iff(a.in_training_dataset, a.is_open_hour, 0))
              over (partition by a.park_code, a.business_date, a.business_hour)
            - iff(a.in_training_dataset, a.is_open_hour, 0)
       end                                                          as other_venues_open,

       case when a.in_training_dataset then
            sum(iff(a.in_training_dataset, a.is_open_hour, 0))
              over (partition by a.park_code, a.business_date, a.business_hour,
                                 coalesce(a.venue_category, 'OTHER'))
            - iff(a.in_training_dataset, a.is_open_hour, 0)
       end                                                          as same_category_venues_open

from assembled a
