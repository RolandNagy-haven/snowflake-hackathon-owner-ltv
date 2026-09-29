# Owner Big Brain — How We Join the Three Domains

**Date:** Monday 28 September 2026
**Author:** Donovan Ransome
**For:** The 09:45–10:30 whole-team session, Tuesday 29 September
**Status:** Evidence, not instruction. Queries are included so anyone can re-run them and disagree.

---

## The question this answers

Three teams will each build a semantic layer over their own domain. Unless they agree a single spine, we end up with three agents that confidently disagree about how many owners we have — the same failure we are living through on F&B revenue reconciliation.

The question is: **what do we join on?**

The two candidates put forward were **email address** and the **Haven Identifier** in the identity tables. This paper tests both, and a third that nobody proposed.

---

## ✅ The answer: `HAVEN_ID`

**`HAVEN_ID` reaches 99.6% of active owners across all three domains.** Email address adds nothing. Use `HAVEN_ID` and stop there.

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

---

## ⚠️ The one thing that will bite you: `HAVEN_ID` is not unique per account

This is the most important finding in the paper, and it is not obvious.

**One person can own several caravans.** Across the full owner base, 4,629 Haven IDs map to more than one account — up to 8 accounts on a single ID. The relationship runs **one HID → many accounts**, never the reverse (every account has exactly one HID).

| Accounts per Haven ID | Haven IDs |
|---|---|
| 1 | 28,902 |
| 2 | 3,738 |
| 3 | 633 |
| 4 | 163 |
| 5–8 | 77 |

Among **active** owners specifically: **317 people hold 636 accounts.** So:

- Counting accounts gives **19,179**
- Counting people gives **18,860**
- The difference is **319 — a 1.7% overstatement**

**Why it matters for the day.** A Snowflake semantic view **rejects many-to-many relationships outright.** If the Owner LTV team declares `ACCOUNT_DETAIL` joined to a marketing table on `HAVEN_ID` without handling this, either the view fails validation or — worse — it validates and silently double-counts spend for anyone with two caravans.

**Why it matters for Rachel's question.** "What is an owner worth over their lifetime" has two legitimate answers depending on whether an owner is a person or a licence. A person with three caravans has three times the site fees. ⚠️ **This is a business definition question, not a technical one, and it belongs in the 09:45 session.**

---

## ❌ Email address does not work — and the reason is interesting

`HAVEN_BASE.IDENTITY.HID_TO_EMAIL` holds 6,404,878 rows. It is **perfectly 1:1**: 6,404,878 distinct HIDs and 6,404,878 distinct emails.

```sql
SELECT COUNT(*), COUNT(DISTINCT HID), COUNT(DISTINCT EMAIL)
FROM HAVEN_BASE.IDENTITY.HID_TO_EMAIL;
-- 6404878 | 6404878 | 6404878
```

So email is not a *worse* key than HID — it is an **exact alias** for it. Joining on email gets you precisely what joining on HID gets you, with these costs:

- It is **personal data**, dragging PII into three semantic layers an LLM will query
- It is **text with case and whitespace variation**, so it needs normalising
- It **cannot resolve anything HID cannot**, because the mapping is already one-to-one

**Recommendation: do not use email as a join key.** If a record has an email we can match, it already has a HID.

---

## The three domain paths, verified

### 1. Owner LTV — anchor `ACCOUNT_DETAIL`

`HAVEN_STORE.CARAVANS.ACCOUNT_DETAIL` carries `ACCOUNT_NO`, `HAVEN_ID`, `PARK_CODE`, `PARK_SHORT_DESC`, `SITE_FEE_DATE`, `LICENSE_START_DATE`, `LICENSE_END_DATE`, `LEAVING_DATE`.

⚠️ **Coverage depends entirely on which owners you mean:**

| Population | HID coverage |
|---|---|
| **All** accounts ever (227,994) | 41,813 — **18.3%** |
| **Active** owners (19,291) | 19,179 — **99.4%** |

The 18% figure is real but misleading — it is dragged down by decades of closed accounts that pre-date the Haven ID. **For any question about current owners, coverage is effectively complete.** For a question about historic churn, it is not, and that is a genuine limitation to state rather than work around.

### 2. Top of Funnel — anchor the HID bridge

**Use `HAVEN_STORE.PROSPECTS.BRIDGE_HAVEN_ID_TO_CS_TIERED_XID`.** 991,560 rows, and **1:1 on `HAVEN_ID`** — clean for a semantic view, no fan-out.

⚠️ **Do not try to join `DIM_TOP_OF_THE_FUNNEL.PLOT_OWNER_XID` to `HAVEN_BASE.IDENTITY.HID_TO_PLOT_OWNER.PLOT_OWNER_ID`.** They look like the same thing and are not:

| Column | Type | Example |
|---|---|---|
| `DIM_TOP_OF_THE_FUNNEL.PLOT_OWNER_XID` | `TEXT` | `fffffa6bed6b7780465149fab05cf406` |
| `HID_TO_PLOT_OWNER.PLOT_OWNER_ID` | `NUMBER` | `1817898` |

The `XID` is an **MD5 hash** of the ID. Attempting the join raises `100038 (22018): Numeric value 'b03398e3…' is not recognized`. The hashed form only joins to other hashed forms. **A team will hit this today if nobody warns them.**

`DIM_TOP_OF_THE_FUNNEL` identifier coverage across its 1,485,110 rows: `FRESHSALES_CONTACT_XID` 99.1%, `PLOT_OWNER_XID` 71.1%, `WEB_SOURCE_UID` 38.6%, `ANALYTICS_ID` 10.4%.

### 3. Performance Marketing — anchor the Bloomreach bridge

**Use `HAVEN_STORE.PERFORMANCE_MARKETING.BRIDGE_BLOOMREACH_CUSTOMER_IDENTITY`.** This table is purpose-built for this problem and resolves five identifier types onto `HAVEN_ID`:

| `ID_TYPE` | Rows | Distinct HIDs |
|---|---|---|
| `bloomreach_cookie` | 15,349,997 | 2,641,102 |
| `amplitude_id` | 11,054,966 | 2,509,240 |
| `seaware_client_id` | 3,622,124 | 3,318,133 |
| `freshsales_contact_id` | 205,193 | 205,101 |
| `plot_owner_id` | 42,468 | 41,476 |

⚠️ **It is `ID_TYPE` + `ID_VALUE` keyed, so it fans out badly** — one HID has many cookies. **Filter to one `ID_TYPE`, or pre-aggregate to `DISTINCT HAVEN_ID`, before declaring a relationship on it.** Left as-is in a semantic view it will multiply row counts.

---

## ⚠️ A trap I walked into, recorded so nobody repeats it

My first attempt used `FCT_ATTRIBUTION_JOURNEY_SUMMARY` for the marketing leg and found **only 12.8% of owners matched.** I nearly wrote that up as the headline constraint.

It was the wrong table. `FCT_ATTRIBUTION_JOURNEY_SUMMARY` is keyed on `HOLIDAY_BOOKING_REF` — it is **holidaymaker** attribution. Owners only appear in it when they also book a Haven holiday, which most do not. The table is fine; it answers a different question.

Retrying against `FCT_ATTRIBUTION_CARAVAN_SALES_PATH_TO_WEB_ENQUIRY` gave 8.7%, which is also not the answer — that table only holds people who made a *web enquiry*, so it excludes everyone who came through a park visit or existing-owner upgrade.

The Bloomreach identity bridge gave 99.97%.

**The lesson for the day: a low match rate usually means the wrong table, not a broken identifier.** Before concluding the data does not join, check whether the table you picked is scoped to the population you think it is. ⚠️ **If a team reports a bad join rate at the 12:30 checkpoint, this is the first thing to check.**

---

## Two more traps in these tables

**`ATTRIBUTION_CARAVAN_SALES_TOUCHPOINTS` has 0 rows.** Its near-namesake `FCT_ATTRIBUTION_CARAVAN_SALES_PATH_TO_WEB_ENQUIRY` has 10,045,889. A team could spend the morning modelling an empty table.

**`HAVEN_BASE.IDENTITY.HID_TO_PLOT_OWNER` has only 33,559 rows** against 6.4m HIDs. It maps owners, not everyone — correct, but do not use it as a general identity table.

---

## What I recommend we agree at 09:45

These are proposals for the room, not decisions I have taken.

1. **`HAVEN_ID` is the spine.** Every team's semantic layer exposes it. No team joins on email.
2. **Each team anchors on the bridge table named above**, not on a raw fact table.
3. **Decide whether an owner is a person or an account** — and say which on every metric. My suggestion: **person (`HAVEN_ID`) for LTV and marketing questions, account (`ACCOUNT_NO`) for park operational questions**, because a park cares about the pitch and Rachel cares about the human.
4. **Pre-aggregate to `DISTINCT HAVEN_ID` before declaring cross-domain relationships**, so semantic-view validation passes and nothing double-counts.
5. **Scope to active owners for the demo.** Coverage is 99.6% there against 18% across all history. State the scope in the answer rather than quietly applying it.
6. **Agree the phrase the agents use.** If one says "owners" meaning accounts and another means people, the demo shows two numbers 1.7% apart and the room will notice.

---

## Verification

Every figure here is reproducible. Environment: account `BD78472`, `AWS_EU_WEST_1`, role `BOURNE_GOVERNANCE_DONOVANRANSOME`, measured 28 September 2026.

⚠️ **Row counts move.** `ACCOUNT_DETAIL` and the churn scores are refreshed on a schedule, so re-running tomorrow will give slightly different numbers. The **proportions** are what matter, and those are stable.

**Not tested, and worth knowing:** whether `HAVEN_ID` coverage differs by acquisition channel. If owners acquired through one route are systematically less likely to carry a HID, that biases exactly the comparison Rachel wants to make. ⚠️ **Worth a check before anyone presents a channel-by-channel LTV number as fact.**
