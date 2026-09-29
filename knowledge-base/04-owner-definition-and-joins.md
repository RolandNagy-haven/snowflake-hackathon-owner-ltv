# 04 — Owner Definition & Joins

Source: Donovan Ransome's evidence paper *"How We Join the Three Domains"* (28 Sep 2026),
measured on account `BD78472`, `AWS_EU_WEST_1`, role `BOURNE_GOVERNANCE_DONOVANRANSOME`.
This is the material for the **09:45 whole-team session** — the most important decisions of the day.

## The answer: `HAVEN_ID` is the spine

**`HAVEN_ID` reaches 99.6% of active owners across all three domains. Email adds nothing. Use
`HAVEN_ID` and stop there.**

| Domain | Table to anchor on | Active owners reached |
|---|---|---|
| **Owner LTV** | `HAVEN_STORE.CARAVANS.ACCOUNT_DETAIL` | 19,179 of 19,291 — **99.4%** |
| **Top of Funnel** | `HAVEN_STORE.PROSPECTS.BRIDGE_HAVEN_ID_TO_CS_TIERED_XID` | 19,110 — **99.6%** |
| **Performance Marketing** | `HAVEN_STORE.PERFORMANCE_MARKETING.BRIDGE_BLOOMREACH_CUSTOMER_IDENTITY` | 19,173 — **99.97%** |
| **All three at once** | — | **19,105 — 99.6%** |

```sql
WITH active AS (
  SELECT DISTINCT ACCOUNT_NO FROM HAVEN_DATA_SCIENCE.OWNER_CHURN.OWNER_RISK_SCORES
  WHERE IS_ACTIVE_CURRENTLY = 1),
owner_hid AS (
  SELECT DISTINCT a.ACCOUNT_NO, ad.HAVEN_ID
  FROM active a JOIN HAVEN_STORE.CARAVANS.ACCOUNT_DETAIL ad ON a.ACCOUNT_NO = ad.ACCOUNT_NO
  WHERE ad.HAVEN_ID IS NOT NULL),
br     AS (SELECT DISTINCT HAVEN_ID FROM HAVEN_STORE.PERFORMANCE_MARKETING.BRIDGE_BLOOMREACH_CUSTOMER_IDENTITY),
funnel AS (SELECT DISTINCT HAVEN_ID FROM HAVEN_STORE.PROSPECTS.BRIDGE_HAVEN_ID_TO_CS_TIERED_XID)
SELECT COUNT(DISTINCT CASE WHEN b.HAVEN_ID IS NOT NULL AND f.HAVEN_ID IS NOT NULL
                           THEN o.ACCOUNT_NO END) AS in_all_three
FROM owner_hid o
LEFT JOIN br b     ON o.HAVEN_ID = b.HAVEN_ID
LEFT JOIN funnel f ON o.HAVEN_ID = f.HAVEN_ID;
-- 19,105
```

## ⚠️ The one thing that will bite you: `HAVEN_ID` is NOT unique per account

**One person can own several caravans.** 4,629 Haven IDs map to more than one account — up to 8
on a single ID. The relationship runs **one HID → many accounts**, never the reverse (every
account has exactly one HID).

| Accounts per Haven ID | Haven IDs |
|---|---|
| 1 | 28,902 |
| 2 | 3,738 |
| 3 | 633 |
| 4 | 163 |
| 5–8 | 77 |

Among **active** owners: **317 people hold 636 accounts.**

- Counting **accounts** → 19,179
- Counting **people** → 18,860
- Difference: **319 — a 1.7% overstatement**

**Why it matters technically:** a Snowflake semantic view **rejects many-to-many relationships
outright.** If Owner LTV declares `ACCOUNT_DETAIL` joined to a marketing table on `HAVEN_ID`
without handling this, either the view fails validation or — worse — it validates and silently
**double-counts spend** for anyone with two caravans.

**Why it matters for the business:** "What is an owner worth over their lifetime" has two
legitimate answers. A person with three caravans has three times the site fees. This is a
**business definition question, not a technical one** → belongs in the 09:45 session.

## ❌ Email does not work — and why

`HAVEN_BASE.IDENTITY.HID_TO_EMAIL` holds 6,404,878 rows and is **perfectly 1:1** (6,404,878
distinct HIDs = 6,404,878 distinct emails). So email is not a *worse* key than HID — it's an
**exact alias** for it. Joining on email gets exactly what joining on HID gets, plus costs:

- It's **personal data** → drags PII into three semantic layers an LLM will query.
- It's **text with case/whitespace variation** → needs normalising.
- It **cannot resolve anything HID cannot** — the mapping is already 1:1.

**Do not use email as a join key.** If a record has a matchable email, it already has a HID.

## The three verified domain paths

### 1. Owner LTV — anchor `ACCOUNT_DETAIL`

`HAVEN_STORE.CARAVANS.ACCOUNT_DETAIL` carries `ACCOUNT_NO`, `HAVEN_ID`, `PARK_CODE`,
`PARK_SHORT_DESC`, `SITE_FEE_DATE`, `LICENSE_START_DATE`, `LICENSE_END_DATE`, `LEAVING_DATE`.

⚠️ **Coverage depends entirely on which owners you mean:**

| Population | HID coverage |
|---|---|
| **All** accounts ever (227,994) | 41,813 — **18.3%** |
| **Active** owners (19,291) | 19,179 — **99.4%** |

The 18% is real but misleading — dragged down by decades of closed accounts pre-dating the
Haven ID. For **current owners** coverage is effectively complete; for **historic churn** it is
not — state that as a limitation rather than working around it.

### 2. Top of Funnel — anchor the HID bridge

**Use `HAVEN_STORE.PROSPECTS.BRIDGE_HAVEN_ID_TO_CS_TIERED_XID`** — 991,560 rows, **1:1 on
`HAVEN_ID`**, clean for a semantic view, no fan-out.

⚠️ **Do NOT join `DIM_TOP_OF_THE_FUNNEL.PLOT_OWNER_XID` to
`HAVEN_BASE.IDENTITY.HID_TO_PLOT_OWNER.PLOT_OWNER_ID`.** They look identical and are not:

| Column | Type | Example |
|---|---|---|
| `DIM_TOP_OF_THE_FUNNEL.PLOT_OWNER_XID` | `TEXT` | `fffffa6bed6b7780465149fab05cf406` |
| `HID_TO_PLOT_OWNER.PLOT_OWNER_ID` | `NUMBER` | `1817898` |

The `XID` is an **MD5 hash** of the ID. Attempting the join raises
`100038 (22018): Numeric value 'b03398e3…' is not recognized`. Hashed forms only join to other
hashed forms. **A team will hit this today if nobody warns them.**

`DIM_TOP_OF_THE_FUNNEL` identifier coverage across 1,485,110 rows: `FRESHSALES_CONTACT_XID`
99.1%, `PLOT_OWNER_XID` 71.1%, `WEB_SOURCE_UID` 38.6%, `ANALYTICS_ID` 10.4%.

### 3. Performance Marketing — anchor the Bloomreach bridge

**Use `HAVEN_STORE.PERFORMANCE_MARKETING.BRIDGE_BLOOMREACH_CUSTOMER_IDENTITY`** — purpose-built,
resolves five identifier types onto `HAVEN_ID`:

| `ID_TYPE` | Rows | Distinct HIDs |
|---|---|---|
| `bloomreach_cookie` | 15,349,997 | 2,641,102 |
| `amplitude_id` | 11,054,966 | 2,509,240 |
| `seaware_client_id` | 3,622,124 | 3,318,133 |
| `freshsales_contact_id` | 205,193 | 205,101 |
| `plot_owner_id` | 42,468 | 41,476 |

⚠️ **Keyed on `ID_TYPE` + `ID_VALUE`, so it fans out badly** — one HID has many cookies. **Filter
to one `ID_TYPE`, or pre-aggregate to `DISTINCT HAVEN_ID`, before declaring a relationship on
it.** Left as-is in a semantic view it will multiply row counts.

## The "wrong table = bad join rate" lesson

Donovan's first marketing attempt used `FCT_ATTRIBUTION_JOURNEY_SUMMARY` and got only **12.8%**
match — nearly written up as the headline constraint. It was the wrong table: that one is keyed
on `HOLIDAY_BOOKING_REF` — **holidaymaker** attribution; owners only appear when they also book
a Haven holiday. `FCT_ATTRIBUTION_CARAVAN_SALES_PATH_TO_WEB_ENQUIRY` gave 8.7% — also wrong,
because it only holds people who made a *web enquiry* (excludes park visits and existing-owner
upgrades). The Bloomreach identity bridge gave **99.97%**.

> **Lesson: a low match rate usually means the wrong table, not a broken identifier.** If a team
> reports a bad join rate at the 12:30 checkpoint, this is the first thing to check.

## Two more identity traps

- **`ATTRIBUTION_CARAVAN_SALES_TOUCHPOINTS` has 0 rows.** Its near-namesake
  `FCT_ATTRIBUTION_CARAVAN_SALES_PATH_TO_WEB_ENQUIRY` has 10,045,889. A team could model an
  empty table all morning.
- **`HAVEN_BASE.IDENTITY.HID_TO_PLOT_OWNER` has only 33,559 rows** against 6.4M HIDs. It maps
  owners, not everyone — do not use it as a general identity table.

## What to agree at 09:45 (Donovan's proposals for the room)

1. **`HAVEN_ID` is the spine.** Every team's semantic layer exposes it. No team joins on email.
2. **Each team anchors on the bridge table named above**, not on a raw fact table.
3. **Decide whether an owner is a person or an account** — and say which on every metric.
   Suggestion: **person (`HAVEN_ID`) for LTV and marketing questions, account (`ACCOUNT_NO`)
   for park operational questions.**
4. **Pre-aggregate to `DISTINCT HAVEN_ID` before declaring cross-domain relationships**, so
   validation passes and nothing double-counts.
5. **Scope to active owners for the demo.** Coverage is 99.6% there vs 18% across all history.
   State the scope in the answer rather than quietly applying it.
6. **Agree the phrase the agents use.** "Owners" meaning accounts vs people produces two numbers
   1.7% apart and the room will notice.

## Verification caveats

- **Row counts move** — `ACCOUNT_DETAIL` and churn scores refresh on a schedule. The
  **proportions** are stable; exact counts drift day to day.
- **Not tested:** whether `HAVEN_ID` coverage differs by acquisition channel. If owners from one
  route are systematically less likely to carry a HID, that biases exactly the channel-by-channel
  LTV comparison Rachel wants. Worth checking before presenting a channel LTV number as fact.
