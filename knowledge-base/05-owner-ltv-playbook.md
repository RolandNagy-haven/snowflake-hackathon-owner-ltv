# 05 — Owner LTV Playbook (my team)

**Lead: Roland.** Team: Rida, Victor, Abdul, Joe, Elisha.
Domain expertise: Roland + Rida worked owner data through **Pitch Perfect**; **Joe** owns the
**churn model** that feeds it.

**Domain:** What an owner is worth and how long they stay — owner account history + the churn
model.

## Start here, not with table exploration

`Product_Mgmt/product_scratchpad/High_risk_owner_extract_v4.sql` (the `additional_sql` query in
this pack) **already contains our join path, our grain, and the data caveats.** Don't
re-discover them.

⚠️ **An agent that doesn't know the caveats below will answer confidently and wrongly.** Put them
in the semantic view's **description and instructions** — that's exactly what the field is for.

## The data caveats that MUST go in the semantic view

| Field | Reality | Why it matters |
|---|---|---|
| `ASSUMED_FINANCE_BALANCE` → `FINANCE_SETTLEMENT` | A **proxy** for settlement — no real settlement field exists | Agent must not present it as the true settlement figure |
| `MONTHLY_INCOME_TOTAL` → `LETTINGS_CASH_MONTHLY` | A **proxy** for lettings cash | Same — label it as a proxy |
| `PEX_BASE_TRADE_VALUE` → `BOTTOM_BOOK_VALUE` | The **correct** bottom-book-value column after Joseph's fix (`#1343`). PEX column always treats the van as used, fixing the `is_new` flag issue | Use this column, not other BBV columns |

## Main tables

- `HAVEN_DATA_SCIENCE.OWNER_CHURN.OWNER_RISK_SCORES` — monthly risk scores per account
  (`MONTH_START_DATE`, `RISK_GROUP`, `RISK_NORMALIZED`, `RISK_DRIVERS_JSON`,
  `OWNERSHIP_LENGTH_BUCKET`, `IS_ACTIVE_CURRENTLY`, `PARK_CODE`). **This is Joe's churn-model
  output — see [10](10-churn-model-repo.md) for the exact definitions behind each column, the
  scored population, and a schema discrepancy to `DESCRIBE`-check before relying on
  `RISK_DRIVERS_JSON`.**
- `HAVEN_STORE.CARAVANS.OWNER_STATUS_TIME_SERIES_ANALYSIS` — van + financial snapshot per
  account per month (van make/model/grade/dimensions, finance balance, rent ledger, monthly
  income).
- `HAVEN_STORE.CARAVANS.FCT_ACCOUNT_HISTORY` — account/pitch history fact. **350M rows, 7
  columns.**
- `HAVEN_STORE.CARAVANS.DIM_OWNER_ACCOUNT_HISTORY`, `DIM_PITCH_HISTORY`, `DIM_PITCH_STATUS` —
  dims joined off the account-history fact for current pitch.
- `HAVEN_STORE.CARAVANS.VAN_BOTTOM_BOOK_VALUE` — BBV (production table, GGO leak fix + PEX
  columns per `#1343`).
- `HAVEN_STORE.CARAVANS.CURRENT_PITCH_SITE_FEE_ANALYSIS` — site fee fields (pitch + current owner).
- `HAVEN_STORE.COMMON.DIM_PARK` — park name + `PITCH_STRATEGY_GROUP` (park tier).
- `HAVEN_STORE.CARAVANS.ACCOUNT_DETAIL` — the **join key to identity** (`HAVEN_ID`); the domain
  anchor for the shared spine.

⚠️ **Agree 4–6 tables, not twenty.** Semantic views get hard fast and you have one day.

## ⚠️ The big performance trap

`FCT_ACCOUNT_HISTORY` is **350 million rows with only 7 columns.** **Filter to the latest
snapshot in a view first, or every query crawls.** The `current_pitch` CTE in
`High_risk_owner_extract_v4.sql` already does this:

```sql
WHERE fah.SNAPSHOT_DATE = (SELECT MAX(SNAPSHOT_DATE) FROM HAVEN_STORE.CARAVANS.FCT_ACCOUNT_HISTORY)
```

## How the v4 extract is structured (the reference query)

`High_risk_owner_extract_v4.sql` builds a high-risk owner extract and pulls in BBV, van, finance,
pitch and site-fee fields. Its logic:

1. **`current_month`** — `MAX(MONTH_START_DATE)` from `OWNER_RISK_SCORES`.
2. **`high_risk_stability`** — for each account, count how many of the last 3 months were
   classified `'high'` (`HIGH_COUNT_3M`).
3. **`current_risk`** — keep owners who are **currently `'high'`, currently active
   (`IS_ACTIVE_CURRENTLY = 1`), AND `'high'` in ≥2 of the last 3 months** (`HIGH_COUNT_3M >= 2`).
   This is the v4 stability filter — avoids reacting to one-off spikes.
4. **`prev_risk`** — risk 3 months ago, to compute `RISK_CHANGE_PCT_3M`.
5. **`current_pitch`** — latest-snapshot pitch via `FCT_ACCOUNT_HISTORY` + the three pitch dims.
6. Final `SELECT` joins: `prev_risk`, `DIM_PARK` (name + tier),
   `OWNER_STATUS_TIME_SERIES_ANALYSIS` (latest month van/finance), `VAN_BOTTOM_BOOK_VALUE` (BBV),
   `current_pitch`, `CURRENT_PITCH_SITE_FEE_ANALYSIS`, and `ACCOUNT_DETAIL` → identity
   (`HID_TO_PROFILE`, `HID_TO_EMAIL`). Ordered by `RISK_NORMALIZED DESC`.

**Note:** the contact/name/phone/email joins (`HID_TO_PROFILE`, `HID_TO_EMAIL`) are **commented
out** in the v4 query — that's PII we should keep out of the semantic layer unless there's a
clear need (see the email/PII argument in [04](04-owner-definition-and-joins.md)).

## Owner-definition decisions that specifically affect us

- **Person vs account.** LTV should default to **person (`HAVEN_ID`)** per Donovan's proposal —
  but a person with 3 caravans has 3× the site fees, so decide and label it. Counting accounts
  vs people differs by **1.7%** (319 of ~19k active).
- **Active vs leavers.** Scope the demo to **active owners** (99.4% HID coverage) and state it.
  Historic-churn questions are a genuine limitation, not something to paper over.
- **Many-to-many.** Pre-aggregate `ACCOUNT_DETAIL` to `DISTINCT HAVEN_ID` before declaring any
  cross-domain relationship, or the semantic view rejects it / double-counts.

## The questions we own (from Rachel Gregory)

1. What is an owner worth over their lifetime, **by park, pitch grade and van grade**?
2. Which owners are **high-risk AND high-value**? (Today the churn programme treats all
   high-risk owners equally — it shouldn't. Our risk scores + value fields answer this —
   join `OWNER_RISK_SCORES` to Joe's static value view, see [10](10-churn-model-repo.md).)
3. What does an owner **cost to acquire vs what they're worth**? (needs Marketing too)
4. Which acquisition profiles systematically produce **short-tenure owners**? (needs ToF too)
5. What's the **LTV impact of a pitch move, a part exchange, or an owner taking up lettings**?

Draft our **five verified queries** from these (15:00 slot). Pre-reading:
`haven_data_science_artefacts/CLV/Owner_LTV_Development_Specification.md` — especially **§4.1**,
the value components and our confidence in each — plus the LTV brainstorm meeting notes
(`Owner LTV Brainstorm - Meeting Notes 20260731.md`).
