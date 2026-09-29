-- =============================================================================
-- Owner LTV — semantic view v1  (ACCOUNT_NO grain)
-- =============================================================================
-- Two lifetime metrics, both sourced from the monthly snapshot table
-- HAVEN_STORE.CARAVANS.OWNER_STATUS_TIME_SERIES_ANALYSIS (verified 2026-09-29,
-- 3.1M rows, unique on ACCOUNT_NO + MONTH_END_DATE, 60,102 accounts, 2016-01..2026-09):
--   1. overall rent ledger value  = the LATEST month's RENT_LEDGER_BALANCE per account.
--                                    RENT_LEDGER_BALANCE is a running BALANCE (verified:
--                                    it rises/falls month to month), so it is NOT summed
--                                    over months — that would double-count. Latest snapshot.
--   2. spend on park (lifetime)    = SUM(MONTH_SPEND) over all the account's months.
--                                    MONTH_SPEND is a monthly flow, so summing = lifetime.
--
-- GRAIN: ACCOUNT_NO. Not person/HAVEN_ID — one owner can hold several accounts
-- (knowledge-base/04). HAVEN_ID is a non-unique dimension. ACCOUNT_DETAIL is unique on
-- ACCOUNT_NO (228,012) and every time-series account joins to it (100%).
--
-- DESIGN: an account-grain helper view collapses the monthly rows to one row per
-- account (latest balance + summed spend). The semantic view's metrics are then simple
-- SUMs over that one-row-per-account fact, which roll up correctly by park / tier too.
--
-- Deploy:  python scripts/deploy_owner_ltv.py
-- Target:  NEXUS_HACKATHON_DB.OWNER_LTV_SV  (role NEXUS_SPIKE, wh NEXUS_HACKATHON_WH)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Account-grain fact: one row per owner account.
-- ---------------------------------------------------------------------------
create or replace view OWNER_LTV_ACCOUNT_FACTS as
select
    ACCOUNT_NO,
    -- Point-in-time: rent ledger balance at the account's most recent month.
    max_by(RENT_LEDGER_BALANCE, MONTH_END_DATE) as rent_ledger_balance_latest,
    max(MONTH_END_DATE)                         as latest_month_end_date,
    -- Flow: on-park owner-card spend accumulated over every month on record.
    sum(MONTH_SPEND)                            as lifetime_park_spend_amt,
    count(*)                                    as months_on_record
from HAVEN_STORE.CARAVANS.OWNER_STATUS_TIME_SERIES_ANALYSIS
group by ACCOUNT_NO;

-- ---------------------------------------------------------------------------
-- 2. Semantic view
-- ---------------------------------------------------------------------------
create or replace semantic view OWNER_LTV_SV_V1

  tables (
    accounts as HAVEN_STORE.CARAVANS.ACCOUNT_DETAIL
      primary key (ACCOUNT_NO)
      with synonyms = ('owner accounts', 'owners', 'accounts')
      comment = 'One row per owner account (unique on ACCOUNT_NO). ACCOUNT_NO is the grain of this view. HAVEN_ID identifies the person and is NOT unique here (one person can hold several accounts) — never count owners on ACCOUNT_NO if you mean people.',

    owner_ltv_facts as OWNER_LTV_ACCOUNT_FACTS
      primary key (ACCOUNT_NO)
      with synonyms = ('owner value facts', 'ltv facts')
      comment = 'One row per account: latest rent-ledger balance and lifetime on-park spend, collapsed from the monthly OWNER_STATUS_TIME_SERIES_ANALYSIS.',

    dim_park as HAVEN_STORE.COMMON.DIM_PARK
      primary key (PARK_CODE)
      with synonyms = ('park', 'site')
      comment = 'Park reference — name, tier (pitch strategy group) and region.'
  )

  relationships (
    facts_to_account as owner_ltv_facts (ACCOUNT_NO) references accounts,
    account_to_park  as accounts (PARK_CODE)          references dim_park
  )

  facts (
    owner_ltv_facts.rent_ledger_balance_latest as rent_ledger_balance_latest,
    owner_ltv_facts.lifetime_park_spend_amt    as lifetime_park_spend_amt
  )

  dimensions (
    owner_ltv_facts.account_no as ACCOUNT_NO
      with synonyms = ('account number', 'account')
      comment = 'The owner account — the grain of every metric here.',
    accounts.haven_id as HAVEN_ID
      with synonyms = ('owner', 'person', 'customer id')
      comment = 'Person identifier. NOT unique — one HID can span several accounts.',
    owner_ltv_facts.as_of_month as latest_month_end_date
      with synonyms = ('as of month', 'latest month', 'balance as of')
      comment = 'Month-end date of the latest snapshot the rent ledger balance is taken from.',
    dim_park.park_name as PARK_NAME
      with synonyms = ('park', 'site name'),
    dim_park.park_tier as PITCH_STRATEGY_GROUP
      with synonyms = ('tier', 'park tier', 'strategy group')
      comment = 'Park tier / pitch strategy group.',
    dim_park.region as DIRECTOR_REGION
      with synonyms = ('area', 'operating region')
      comment = 'Operating region of the park.'
  )

  metrics (
    owner_ltv_facts.overall_rent_ledger_value as sum(owner_ltv_facts.rent_ledger_balance_latest)
      with synonyms = ('rent ledger', 'total rent ledger', 'rent ledger value', 'overall rent ledger')
      comment = 'Overall rent ledger value: each account''s latest month-end RENT_LEDGER_BALANCE, summed across the accounts in scope. A balance (point in time), not a flow — can be negative (credit) or positive (arrears).',

    owner_ltv_facts.lifetime_park_spend as sum(owner_ltv_facts.lifetime_park_spend_amt)
      with synonyms = ('spend on park', 'on-park spend', 'owner spend', 'lifetime spend', 'park spend')
      comment = 'On-park owner-card spend over the ownership lifetime (SUM of monthly MONTH_SPEND). PARTIAL measure: some parks capture no identity at the till, and friends-&-family / private-let cards are mis-attributed (knowledge-base/13) — present as owner-card spend, not total spend.',

    owner_ltv_facts.account_count as count(owner_ltv_facts.account_no)
      with synonyms = ('accounts', 'number of accounts')
      comment = 'Number of owner accounts with LTV facts (accounts, not distinct people).'
  )

  comment = 'Owner LTV starter view — ACCOUNT_NO grain. Metrics: overall rent ledger value (latest balance per account) and lifetime on-park spend (summed MONTH_SPEND). Owner = account, not person; HAVEN_ID is non-unique. See knowledge-base/05 (playbook) and /04 (joins).'

  ai_sql_generation 'Grain is the owner ACCOUNT_NO. HAVEN_ID (the person) is NOT unique — one person can hold several accounts — so never count distinct owners on ACCOUNT_NO if the question means people; say the count is of accounts (account_count). overall_rent_ledger_value is a BALANCE: each account''s latest month-end rent-ledger balance, then summed over accounts; it can be negative and must never be summed across months (that is already handled). lifetime_park_spend is owner-card / on-park spend summed over the account''s months; it is a PARTIAL measure (some parks capture no identity at the till, friends-&-family / private-let cards) — never present it as an owner''s total spend. Group by park_name, park_tier or region for park breakdowns. Filters on park are safe.'
;
