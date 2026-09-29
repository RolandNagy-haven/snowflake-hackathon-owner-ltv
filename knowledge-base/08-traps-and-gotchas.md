# 08 — Traps & Gotchas

All verified against the real tables. Read before you model — each is a rejection or a
performance wall.

## Snowflake semantic-view validation rules (the two that bite)

1. **Many-to-many relationships are rejected outright.**
2. **Joins where two tables can be reached by more than one path are rejected** (multi-path).

Knowing these before modelling saves an afternoon. Study the working example first:
```sql
DESCRIBE SEMANTIC VIEW NEXUS_PLATINUM.EPOS_SALES.SEM_EPOS_SALES;
```

## Per-team traps

| Team | Problem | Why it matters / fix |
|---|---|---|
| **Owner LTV** | `FCT_ACCOUNT_HISTORY` = **350M rows, 7 columns** | Filter to latest snapshot in a view first, or every query crawls. The `current_pitch` CTE in `High_risk_owner_extract_v4.sql` already does this |
| **Top of Funnel** | `FCT_TOP_OF_THE_FUNNEL` has **six date columns** pointing at one calendar | **Multi-path rejection.** Pick the two or three the demo needs |
| **Perf. Marketing** | `BRIDGE_BLOOMREACH_CUSTOMER_IDENTITY` = **30M-row bridge** | **Many-to-many** → rejected. Flatten it (one `ID_TYPE`, or `DISTINCT HAVEN_ID`) |
| **Perf. Marketing** | Several `ATTRIBUTION_*` tables **empty** while `FCT_ATTRIBUTION_*` have data | `ATTRIBUTION_CARAVAN_SALES_TOUCHPOINTS` = 0; `FCT_ATTRIBUTION_CARAVAN_SALES_PATH_TO_WEB_ENQUIRY` = 10M. Start from `FCT_ATTRIBUTION_JOURNEY_SUMMARY` |

## Identity / join traps (from the evidence paper)

- **`HAVEN_ID` is one → many accounts** (never the reverse). 4,629 HIDs map to >1 account (up to
  8). Pre-aggregate to `DISTINCT HAVEN_ID` before cross-domain joins, or the view double-counts
  spend. Account count vs person count differs 1.7%.
- **Email is a 1:1 alias of HID** — adds nothing, adds PII + normalisation cost. Don't join on it.
- **`PLOT_OWNER_XID` (MD5 hash, TEXT) ≠ `PLOT_OWNER_ID` (NUMBER).** Joining raises
  `100038 (22018): Numeric value '…' is not recognized`. Hashed forms only join to hashed forms.
- **A low match rate usually means the wrong table, not a broken identifier.**
  `FCT_ATTRIBUTION_JOURNEY_SUMMARY` (keyed on `HOLIDAY_BOOKING_REF`) gave 12.8% owner match;
  `FCT_ATTRIBUTION_CARAVAN_SALES_PATH_TO_WEB_ENQUIRY` gave 8.7%; the Bloomreach identity bridge
  gave 99.97%. Check table scope before concluding data won't join. **First thing to check if a
  team reports a bad join rate at 12:30.**
- **`HID_TO_PLOT_OWNER` has only 33,559 rows** — maps owners, not everyone. Not a general
  identity table.
- **`ACCOUNT_DETAIL` HID coverage is 18.3% across all accounts ever, but 99.4% for active
  owners.** The 18% is closed accounts pre-dating the Haven ID. Scope to active for the demo;
  historic churn is a stated limitation.

## Owner LTV field-meaning traps (must go in the semantic view instructions)

- `ASSUMED_FINANCE_BALANCE` is a **proxy** for finance settlement — no real field exists.
- `MONTHLY_INCOME_TOTAL` is a **proxy** for lettings cash.
- `PEX_BASE_TRADE_VALUE` is the **correct** bottom-book-value column (after Joseph's `#1343`
  fix); it always treats the van as used.

**An agent that doesn't know these answers confidently and wrongly.**

## Spend & digital-data caveats (definitions meeting, [13](13-definitions-meeting.md))

- **Owner-card spend is partial.** F&B is reliable; **retail on a few parks captures no identity
  on scan**; **private-let** card use is unknown. **Friends & family cards** attach spend to
  extra accounts under one owner. Don't present card spend as total owner spend.
- **Owner events attendance is largely untracked**; owner-lounge spend is in retail/OE reports.
- **Digital/Amplitude data is never complete** — ad-blocking (unknown loss) + **GDPR consent
  (~80%)** mean it won't reconcile line-for-line. Say so.
- **Pitch-status codes for the owner lifecycle** (OW, private sale, PX, transfer of ownership)
  were named verbally — **verify against `DIM_PITCH_STATUS`** before encoding them.

## Process traps

- **Don't model twenty tables.** Agree 4–6.
- **Row counts move** (scheduled refreshes) — trust proportions, not exact counts.
- **Untested:** whether HID coverage differs by acquisition channel — could bias channel LTV
  comparisons.
