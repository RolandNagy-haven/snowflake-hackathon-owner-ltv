# 10 — The Churn-Model Repo (`service-haven-data-ownerchurn`)

This is **Joe's production churn model** — the thing that already produces `OWNER_RISK_SCORES`,
the "risk" half of our high-risk-AND-high-value question ([07](07-business-questions.md),
question 2). It also contains **Joe's static LTV view**, which is the most complete value
definition we have going into the day. Everything below is read from the repo source, so we can
put the *definitions the code actually uses* into the semantic view instead of guessing.

> This file summarises an external repo (not in this project dir). Paths below are
> repo-relative. If you need to re-read it, the repo is a normal checkout on Roland's machine.

## What the model is (one paragraph)

A **survival model** (`lifelines.CoxTimeVaryingFitter`) over monthly owner snapshots. It learns
a hazard of leaving from van grade, pitch grade, park, debt/site-fee, activity and economic
signals, then converts each account-month's partial hazard into a **normalised risk score** and a
**risk group**. Output is one row per account per month. It is *not* an LTV/value model — value
comes from Joe's static SQL view (below).

## What it produces — `OWNER_RISK_SCORES`

Written (overwrite) by `.../data/write_data.py`. **Grain: one row per `ACCOUNT_NO` per
`MONTH_START_DATE`.** Columns the code actually writes:

`ACCOUNT_NO`, `PARK_CODE`, `MONTH_START_DATE`, `RISK_NORMALIZED`, `RISK_GROUP`,
`OWNERSHIP_LENGTH_BUCKET`, `IS_ACTIVE_CURRENTLY`.

⚠️ **Reconcile with [05](05-owner-ltv-playbook.md).** File 05 lists this table with a
`RISK_DRIVERS_JSON` column and in the `OWNER_CHURN` schema. The repo's `write_data.py` writes the
seven columns above (no drivers JSON) to `DATA_SCIENCE.OWNER_RISK_SCORES`. Before wiring the
semantic view, **`DESCRIBE` the live table** and trust that — the production schema may have moved
past the repo. Don't promise the agent a `RISK_DRIVERS_JSON` field without checking it exists.

## The definitions the code uses (put these in the semantic view)

These are the ones an agent will otherwise re-derive differently every run — the divergence
problem ([09](09-benchmark-and-divergence.md)) in miniature. Pin them:

| Concept | Exact definition in code | Source file |
|---|---|---|
| **Churn event** (`EVENT`) | `IS_CHURN::INT` from the source time series | `data/load_data.py` |
| **`IS_ACTIVE_CURRENTLY`** | `1` if the account **never** had `EVENT==1` in its history, else `0` | `models/coxtimevarying.py` |
| **Ownership length (months)** | `((MONTH_END_DATE − JOINING_DATE).days / 30.44).round(0)` | `features/cleaning.py` |
| **Ownership length (years)** | `(OWNERSHIP_LENGTH_MONTH / 12).round(0)` | `models/coxtimevarying.py` |
| **`OWNERSHIP_LENGTH_BUCKET`** | bins on **years** `[-1, 3, 6, 9, 15, 1000]` (i.e. 0–3, 3–6, 6–9, 9–15, 15+) | `models/coxtimevarying.py` |
| **`RISK_NORMALIZED`** | percentile rank (`rank(pct=True)`) of hazard **within each `MONTH_START_DATE`**, rounded to 1 dp | `models/coxtimevarying.py` |
| **`RISK_GROUP`** | centerline method (below) — **not** a fixed quantile split | `models/coxtimevarying.py` |

### `RISK_GROUP` — the centerline method (the subtle one)

Two reference lines are learned from the data, then each account-month is bucketed against them:
- **lower line** = **median (0.5 quantile)** of the risk of *survivors* (`EVENT==0`)
- **upper line** = **0.4 quantile** of the risk of *leavers* (`EVENT==1`)
- below lower → `low`, between → `medium`, above upper → `high`.

⚠️ **There is an older, different method in the repo:** `src/features/risk_group_segmentation.py`
uses a plain quantile split `bins=[min, q0.70, q0.95, max]`. **That one is superseded.** The
centerline method in `coxtimevarying.py` is what production `OWNER_RISK_SCORES` uses. If anyone
quotes "70/95" group boundaries on the day, that's the stale definition.

## The population the model is trained on (matters for "which owners are scored")

From `features/cleaning.py` (`Preprocess.clean_data`) and the fitter's own filter:
- **Excludes `IS_241_PEX` accounts** (the 2-4-1 part-exchange accounts) — consistent with Joe's
  static view excluding PEX/PXU/OL sale types.
- Keeps only accounts with **> 6 ownership months**.
- Keeps **post-2016 joiners OR pre-2016 owners still active** (so early history is truncated —
  the same "historic churn is a stated limitation" caveat we already carry in
  [08](08-traps-and-gotchas.md)).
- Fitter filters `MONTH_START_DATE` to **2021-01-01 → current month**.
- **Inflation-adjusts money to a 2016 CPI base** before modelling (see CPI map below).
- `CoxTimeVaryingFitter(penalizer=0.0005)`; risk capped at the **0.998 quantile** to stop
  outliers dominating the percentile rank.

**So when the agent says "risk score", the scored population is: active-or-recent, >6-month,
non-241-PEX owners since 2021.** State that scope — it's not "all owners".

## The value/LTV logic — Joe's static view (this is the gold for our team)

`sql/OWNER_STATUS_STATIC_ANALYSIS_new_Joe.sql` creates
**`HAVEN_DATA_ENGINEERING.DATA_SCIENCE.OWNER_STATUS_STATIC_ANALYSIS`** — **one row per
`ACCOUNT_NO`** (owner type `'OW'` only). It is the most assembled owner-value object we have.
Value fields come from `HAVEN_STORE.CARAVANS.ACCOUNT_DETAIL`:

- **`LIFETIME_VALUE`**, **`NET_SITE_FEES_TOTAL`**, **`TOTAL_LETTING_INCOME`**,
  **`OWNER_SPEND_TOTAL`**, `LIFETIME_VAN_COUNT`, `HAS_RENT_REDUCTION`.
- Plus retail spend (`TOTAL_OWNER_MONEY_SPEND`, `TOTAL_ACTIVE_DAYS`, `NUM_OWNER_PASSES` from
  `FCT_RETAIL_SALES` via `DIM_OWNER_PASS`), site-fee ledger aggregates (`TOTAL_INVOICE`,
  `NUM_PAID_SITE_FEES`, `INVOICE_FREQ`), acquisition source (`OWNER_SOURCE_*`,
  `LETTING_PRODUCT_*` from `FCT_SIGNUP` / `SALE_DETAIL`), advocacy/NPS
  (`LAST_ADVOCACY`, `VALUE_FOR_MONEY_*`), demographics (`HOUSEHOLD_INCOME`, `FAMILY_TYPE`,
  `HAVEN_SEGMENT`, age, gender), and van/pitch first/last/mode/trend features.

**Definitions worth pinning from this view:**
- **`JOINING_DATE` = `MIN(snapshot_date)`** and `max_snapshot_date = MAX(snapshot_date)` from
  `FCT_ACCOUNT_HISTORY` — i.e. tenure is measured off account-history snapshots, matching the
  churn model's ownership-length basis.
- **`LEAVING_DATE`** comes from `HAVEN_STORE.CARAVANS.COMPLETED_LEAVER` (left join — null = not a
  completed leaver).
- **`JOINING_DATE_FIRST_COMPLETION`** = earliest genuine completion, excluding cancelled sales
  and `OFF` sale types, only `sale_status_code = 'C'`. Use this, not raw joining date, when the
  question is about *completed* acquisition.
- **Cancelled sales are filtered out**; **`PEX`/`PXU`/`OL` sale types are excluded** from the
  completion logic (`c_sale_type`), and park `'TG'` / deleted parks are excluded.

⚠️ This view is **account-grain**, so it has the same person-vs-account and one-HID→many-accounts
issue we flagged in [04](04-owner-definition-and-joins.md)/[08](08-traps-and-gotchas.md). To go
to person LTV, aggregate to `DISTINCT HAVEN_ID` (via `ACCOUNT_DETAIL`) — and remember a person
with 3 vans legitimately has 3× site fees.

## Supporting data sources the repo relies on

- **Owner time series (model input):** `haven_store.caravans.owner_status_time_series_analysis`
  — same table [05](05-owner-ltv-playbook.md) lists as `OWNER_STATUS_TIME_SERIES_ANALYSIS`; the
  monthly van/finance snapshot the Cox model consumes.
- **Economic indicators:** OECD tables under `haven_base.oecd.*` (macro features).
- **CPI map:** `sql/UK_CPI_MAP.sql` → `HAVEN_DATA_ENGINEERING.DATA_SCIENCE.UK_CPI_MAP`, a small
  year→index table (2016 = 100.0 base, up to 2025 = 132.1) used for the inflation adjustment.
  The model code reads it from `HAVEN_DATA_SCIENCE_DEV.DATA_SCIENCE.UK_CPI_MAP`.
- **Owner activity views (extra domain colour):** `sql/OWNER_EVENT_ACTIVITY.sql` and
  `OWNER_EXCLUSIVE_EVENT_LIST.sql` build owner activity/booking + session-fill features off
  `haven_store.activities.*`. Not core to LTV but available if an activity-engagement signal is
  wanted.

## Complete source-table inventory

Every fully-qualified table the repo's `sql/` and `src/` actually read/write, grouped by role.
This is the exhaustive list (from a grep of the repo) — the sections above call out only the
headline ones. ⚠️ Table availability under `NEXUS_SPIKE` is unverified; some (`HAVEN_STORE_QAT.*`,
`HAVEN_DATA_SCIENCE_DEV.*`) are QAT/dev variants — `DESCRIBE` before relying on them.

### Model output

| Table | Role |
|---|---|
| `…DATA_SCIENCE.OWNER_RISK_SCORES` | The model output (see grain/columns above). ⚠️ schema unresolved — [04](04-owner-definition-and-joins.md)/[12](12-reference-implementation.md) |
| `HAVEN_DATA_ENGINEERING.DATA_SCIENCE.OWNER_STATUS_STATIC_ANALYSIS` | **Joe's static LTV view** — the assembled value object |

### Account / owner / identity

| Table | Role |
|---|---|
| `HAVEN_STORE.CARAVANS.ACCOUNT_DETAIL` | Account → `HAVEN_ID` anchor + value fields; the join spine |
| `HAVEN_STORE.CARAVANS.OWNER_DETAIL` | Owner-level detail |
| `HAVEN_STORE.CARAVANS.DIM_OWNER_ACCOUNT_HISTORY` | Owner↔account history dim (also in the v4 SQL) |
| `HAVEN_STORE.CARAVANS.DIM_ACCOUNT_OWNER_TYPE` | Owner-type dim (used to filter to `'OW'`) |
| `HAVEN_STORE.CARAVANS.FCT_ACCOUNT_HISTORY` | 350M-row account/pitch history (tenure basis) |
| `HAVEN_STORE.CARAVANS.COMPLETED_LEAVER` | `LEAVING_DATE` source (completed leavers) |
| `HAVEN_BASE.SAS_COMMON.PERSON_CURRENT` | Person/demographic master |
| `HAVEN_STORE.COMMON.POSTCODE_DIRECTORY` | Geo/demographic enrichment by postcode |
| `HAVEN_BASE.PLOT.{OWNERS, ACCOUNTS, SALES, PARKS, SALES_TYPES, SALES_STATUSES}` | Raw PLOT source system (upstream of the STORE tables) |

### Value components (LTV)

| Table | Role |
|---|---|
| `HAVEN_STORE.CARAVANS.SITE_FEE_LEDGER` | **Site-fee invoices/payments** — core net-site-fee value + `INVOICE_FREQ`, `NUM_PAID_SITE_FEES` |
| `HAVEN_STORE.CARAVANS.FCT_SIGNUP` | Sign-up / acquisition source, letting product |
| `HAVEN_STORE.CARAVANS.SALE_DETAIL` | Sale + completion/cancellation logic (`sale_status_code='C'`, PEX/PXU/OL exclusion) |
| `HAVEN_STORE.CARAVANS.DIM_SALE_TYPE_SCD1` | Sale-type dim (drives the PEX/241 exclusions) |
| `HAVEN_STORE.RETAIL.FCT_RETAIL_SALES` | Owner retail spend (`OWNER_SPEND_TOTAL`, active days) |
| `HAVEN_STORE.RETAIL.DIM_OWNER_PASS` | Owner-pass link for retail spend + `NUM_OWNER_PASSES` |

### Van / pitch / park

| Table | Role |
|---|---|
| `HAVEN_STORE.CARAVANS.DIM_VAN_HISTORY` | Van make/model/grade/dimensions features |
| `HAVEN_STORE.CARAVANS.DIM_PITCH_HISTORY` | Pitch grade/area/zone features |
| `HAVEN_STORE.COMMON.DIM_PARK` | Park name + tier (`PITCH_STRATEGY_GROUP`) |

### Engagement (feature colour — not core LTV)

| Table | Role |
|---|---|
| `HAVEN_STORE.ACTIVITIES.{FCT_ACTIVITY_BOOKINGS, FCT_SESSION_CAPACITIES, DIM_ACTIVITY}` | Activity bookings + session-fill features |
| `HAVEN_BASE.AMPLITUDE.HAVEN_GUEST_AND_OWNERS` | App/web usage identity |
| `…DATA_SCIENCE.OWNER_AMPLITUDE_USAGE`, `…OWNER_AMPLITUDE_USAGE_SESSION_AGG` | Pre-aggregated Amplitude usage |
| `HAVEN_STORE.SURVEY.OWNERS_SURVEY_RESPONSE` | **Advocacy / NPS** (`LAST_ADVOCACY`, `VALUE_FOR_MONEY_*`) |

### Macro (churn hazard features only — not LTV)

| Table | Role |
|---|---|
| `HAVEN_BASE.OECD.{UNEMPLOYMENT, INTEREST_RATES, CONSUMER_PRICE_INDEX, CONSUMER_CONFIDENCE_INDEX_CPI}` | Economic indicators the Cox model uses |
| `…DATA_SCIENCE.UK_CPI_MAP` | Year→CPI index for the 2016-base inflation adjustment |

⚠️ **For the Owner LTV semantic view we do NOT need all of these** — the briefing says agree
**4–6 tables** ([02](02-agenda-and-logistics.md)). This inventory is the *menu*; the value-driving
core is `OWNER_RISK_SCORES` + Joe's `OWNER_STATUS_STATIC_ANALYSIS` (which already assembles most of
the above) + `ACCOUNT_DETAIL` (for the `HAVEN_ID` join) + `DIM_PARK`. Reach into `SITE_FEE_LEDGER`,
`OWNERS_SURVEY_RESPONSE` or the engagement tables only if a question needs a component the static
view doesn't already expose.

## Tech stack (for reproducing/extending on the day)

`lifelines==0.28.0` (Cox time-varying), `scikit-survival==0.24.1`, `snowflake-snowpark-python`,
`xgboost`, `shap` (the last two for driver explanation / the "why the model predicted that"
analysis in `main.ipynb`). `snowpark` reads and writes Snowflake directly, so a query-capable
Claude/`snow` session could re-run scoring — but for the demo we consume the **existing**
`OWNER_RISK_SCORES` output, we don't retrain.

## What to actually take into the hackathon

1. **Pin the definitions above** (active, ownership-length buckets, risk-group centerline,
   scored population) in the Owner LTV semantic view's instructions — they're the exact
   "which method did it use" answers the divergence test ([09](09-benchmark-and-divergence.md))
   punishes you for not having.
2. **Use Joe's static view as the value source** for question 1 (worth by park/pitch/van grade)
   and, joined to `OWNER_RISK_SCORES`, for question 2 (high-risk AND high-value).
3. **`DESCRIBE` the live `OWNER_RISK_SCORES` first** — resolve the schema/column difference noted
   above before promising fields.
4. Carry the **exclusions** (241-PEX, cancelled sales, >6-month, post-2021) into any LTV number
   so risk and value describe the *same* population.
