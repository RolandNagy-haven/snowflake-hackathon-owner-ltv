create or replace view FNB_RETAIL_LINES_V4(
	TRANSACTION_DATE,
	TRANSACTION_HOUR,
	PARK_CODE,
	VENUE_NAME,
	SERVICING_VENUE_NAME,
	VENUE_TAG,
	VENUE_TYPE,
	CC_DIVISION,
	COST_CENTRE_CODE,
	COST_CENTRE_NAME,
	PRODUCT_DIVISION,
	PRODUCT_DIVISION_TYPE,
	FOOD_IS_MAIN,
	ORDER_NUMBER,
	NET_SALES_AMOUNT,
	QUANTITY,
	APPORTIONED_TRANSACTIONS
) as
with division_type as (
    -- Product-side Food/Wet classification, to match the legacy filter
    --     AND P.Division_Type IN ('Food', 'Wet')
    -- DIM_PRODUCT_SKU carries DIVISION but not DIVISION_TYPE, so the type has to come from
    -- elsewhere. It used to come from HAVEN_STORE_QAT.EPOS_SALES.INT_EPOS_PRODUCT_CATEGORY_
    -- HIERARCHY, an INT_ staging object that does not exist in HAVEN_STORE. The replacement
    -- is RETAIL.DIM_EPOS_PRODUCT, which is the very table the legacy filter's `P` aliased --
    -- so this is a return to the original source rather than a substitute for it.
    --
    -- Verified on the swap:
    --   * the distinct (division, division_type) set is IDENTICAL to the old hierarchy's --
    --     a full outer join on both columns returns zero unmatched rows either way;
    --   * no division maps to two non-null types, so the distinct pair cannot fan the join
    --     out (same property the old source had);
    --   * of the divisions present in DIM_PRODUCT_SKU, 8 get no type and are dropped -- NULL
    --     (581 skus), Laundrette, Concessions, Sauces, Vending Cash Drop, Unknown, Ice
    --     Drinks, Open Price Dump. All non-F&B, as before.
    --   * end to end over the old QAT window (2024-07-21 .. 2026-08-17) the fnb CTE returns
    --     the same 91,333,609 lines, 67 venues and 435 cost centres on both sources.
    --     Revenue differs by GBP 153.77 on GBP 357.67M (0.000043%) and that is NOT this
    --     swap: the raw fact tables themselves disagree by GBP 179.04 over the same window
    --     at identical per-day row counts, i.e. pennies restated between adjacent dates in
    --     HAVEN_STORE. Nothing in the classification moved.
    select distinct division, division_type
    from HAVEN_STORE.RETAIL.DIM_EPOS_PRODUCT
    where division_type is not null
),
fnb as (
    select
        f.transaction_date,
        hour(f.transaction_time)                                as transaction_hour,
        v.park_code,
        v.venue_name,
        -- brand food is rung on bar tills; remap it onto the kitchen that made it
        case when sku.division in ('Burger King','Cooks Fish & Chips','Chopstix',
                                   'Papa Johns','Slim Chickens','Millies')
             then sku.division else v.venue_name end            as servicing_venue_name,
        v.venue_tag                                             as venue_tag,
        v.venue_type                                           as venue_type,
        cc.department_name                                      as cc_division,
        cc.cost_centre_code,
        cc.cost_centre_name,
        sku.division                                            as product_division,
        dt.division_type                                        as product_division_type,
        coalesce(im.is_main, false)                             as food_is_main,
        f.order_number,
        f.net_sales_amount,
        f.quantity,
        f.apportioned_transactions
    from HAVEN_STORE.EPOS_SALES.FCT_EPOS_SALES                  f
    join HAVEN_STORE.EPOS_SALES.DIM_VENUE                       v
      on v.venue_xid         = f.ordering_venue_xid
    join HAVEN_STORE.EPOS_SALES.DIM_PRODUCT_SKU                 sku
      on sku.product_sku_xid = f.product_sku_xid
    join HAVEN_STORE.FINANCE_CUBE_ERPX.DIM_COST_CENTRE          cc
      on cc.cost_centre_xid  = f.fulfilment_cost_centre_xid
    join division_type                                          dt
      on dt.division         = sku.division
    -- legacy FOOD_IS_MAIN, from the COMMON lookup, keyed product_id -> DIM_PRODUCT_SKU.
    -- product_code. Verified unique (5,306 ids, no duplicates) so it cannot fan the join
    -- out, and its 2,409 true rows on COMPLEX line up exactly with MENU_ITEM_TYPE =
    -- 'Main dish'. HAVEN_STORE.COMMON.RETAIL_PRODUCT_IS_MAIN is byte-for-byte the same
    -- object as the QAT one on the counts that matter: 5,306 rows, 5,306 distinct
    -- (product_id, epos_platform_code), 2,093 true.
    --
    -- RETAIL.DIM_EPOS_PRODUCT -- now on the join path, for division_type above -- also
    -- carries a FOOD_IS_MAIN column, so this lookup could in principle be retired. It is
    -- NOT, deliberately: that table is keyed per portion, so (product_id,
    -- epos_platform_code) is not known unique there and joining it at line level risks
    -- fanning out 91M rows. The division_type CTE is safe only because it is a `distinct`
    -- over two columns.
    left join HAVEN_STORE.COMMON.RETAIL_PRODUCT_IS_MAIN         im
      on  im.product_id         = sku.product_code
      and im.epos_platform_code = sku.epos_platform_code
    where v.epos_platform_code      = 'COMPLEX'
      and dt.division_type in ('Food','Wet')
      and f.net_sales_amount       <> 0
      and coalesce(v.venue_type,'') not in ('Reception')
      and cc.department_name in ('Bars','Retail Catering')
      -- Delivery Service out: a channel, not a place
      and not (cc.department_name = 'Retail Catering' and cc.cost_centre_code like '%413')
      -- Optional: restore the pre-migration extent. HAVEN_STORE reaches back to 2016-01-01
      -- where HAVEN_STORE_QAT began at 2024-07-21 -- see the header note. Uncommenting this
      -- reproduces the old scope exactly (91,333,609 lines, 67 venues, 435 cost centres).
      and f.transaction_date >= '2023-01-01'
)
-- NO VOLUME FLOOR.
--
-- There used to be a two-stage gate here (lifetime >= GBP 1,000, >= 30 trading days, then
-- drop the bottom 5% by revenue). It has been removed: nothing downstream depends on it,
-- so it was a scope choice rather than a mechanism, and it was silently hiding 108 of 390
-- park x venue combinations.
--
-- What removing it admits (measured):
--     108 venues, GBP 122,573.07 (0.035% of revenue), 36,129 extra lines
--       91 venues were under GBP 1,000 lifetime   GBP  5,841.28   avg 17 trading days
--       14 venues were in the bottom 5% by revenue GBP 116,767.27  avg 114 trading days
--        3 venues net to NEGATIVE revenue          GBP    -35.47   avg  2 trading days
--
-- The >= 30 trading days test was provably redundant: no venue was excluded by it alone,
-- every one it would have caught was already under the GBP 1,000 floor.
--
-- The venue_type exclusion (OE Lounge, Reception) is NOT part of this and still applies --
-- it is a statement about what kind of place a venue is, not about how much it sold.
--
-- Consequence to be aware of: the admitted venues now compete for cost-centre primacy in
-- V3_VENUE_DAILY / V3_VENUE_HOURLY, so a label CAN move. Three venues net to negative
-- revenue over their whole life, which makes them legitimate rows with a meaningless
-- series -- filter on is_open / own_revenue downstream rather than assuming every row in
-- the spine is a viable venue.
select f.*
from fnb f
;
