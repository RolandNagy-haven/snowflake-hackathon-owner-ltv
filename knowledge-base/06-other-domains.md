# 06 — Other Domains

Context for the teams we integrate with. Our leg (Owner LTV) is in
[05](05-owner-ltv-playbook.md); the shared spine is in [04](04-owner-definition-and-joins.md).

## Top of Funnel — lead Matt

Team: Balint, Lewis, Kirsty, Donovan, Fraser. Matt built the top-of-funnel report + Tableau
front end.

**Domain:** the prospect-to-owner journey — enquiry → appointment → signup → completion.

**Main tables:** `FCT_TOP_OF_THE_FUNNEL`, `DIM_TOP_OF_THE_FUNNEL`, the
`BRIDGE_*_TO_CS_TIERED_XID` family.

**Join anchor:** `HAVEN_STORE.PROSPECTS.BRIDGE_HAVEN_ID_TO_CS_TIERED_XID` — 991,560 rows, 1:1 on
`HAVEN_ID`, clean.

**Traps:**
- `FCT_TOP_OF_THE_FUNNEL` has **six date columns pointing at one calendar** → a **multi-path
  rejection** in a semantic view. Pick the two or three the demo needs.
- Do **not** join `DIM_TOP_OF_THE_FUNNEL.PLOT_OWNER_XID` (MD5 hash, TEXT) to
  `HID_TO_PLOT_OWNER.PLOT_OWNER_ID` (NUMBER) — see [04](04-owner-definition-and-joins.md).
- **Identity problem to raise at 09:45:** the dbt model keys **89.3% of prospects on email
  address, not Haven ID.** Net-new vs returning leads can't currently be separated, which
  **inflates the CPA denominator.** (Appendix A of the LTV spec.)

**Pre-reading:** `core-dbt#1426` and `#1427` (gold fact + dimension models).

**Questions owned (Caravan Sales — funnel efficiency):**
- Where in the funnel do prospects drop out, by park and by source?
- Which lead sources convert to a **completion**, not just an appointment?
- How long does first enquiry → completion actually take?
- Which appointments show, and does the advisor make a difference?

## Performance Marketing — lead Dan C

Team: Alina, Judy, Dan G, Jade, Ahsan. Dan C built the facts/dimensions + Sigma reporting.

**Domain:** which channels and campaigns touch an owner on the way in — Bloomreach + attribution.

**Main tables:** `FCT_ATTRIBUTION_JOURNEY_SUMMARY`, `FCT_ATTRIBUTION_CHANNEL_JOURNEY_ROLE`,
`DIM_BLOOMREACH_CUSTOMER`.

**Join anchor:** `HAVEN_STORE.PERFORMANCE_MARKETING.BRIDGE_BLOOMREACH_CUSTOMER_IDENTITY` —
resolves five id types onto `HAVEN_ID`, **99.97%** owner coverage.

**Traps:**
- `BRIDGE_BLOOMREACH_CUSTOMER_IDENTITY` is a **30M-row bridge** keyed `ID_TYPE` + `ID_VALUE` →
  **many-to-many, which semantic views reject.** Flatten it: filter to one `ID_TYPE` or
  pre-aggregate to `DISTINCT HAVEN_ID`.
- ⚠️ **Several `ATTRIBUTION_*` tables are empty while `FCT_ATTRIBUTION_*` have data.**
  `ATTRIBUTION_CARAVAN_SALES_TOUCHPOINTS` = 0 rows;
  `FCT_ATTRIBUTION_CARAVAN_SALES_PATH_TO_WEB_ENQUIRY` = 10M. **Start from
  `FCT_ATTRIBUTION_JOURNEY_SUMMARY`** — don't model an empty table.
- Beware wrong-table low-match-rate: `FCT_ATTRIBUTION_JOURNEY_SUMMARY` is keyed on
  `HOLIDAY_BOOKING_REF` (holidaymaker attribution) — for owner joins, go via the Bloomreach
  identity bridge (see [04](04-owner-definition-and-joins.md)).

**Pre-reading:** `haven_data_artefacts/Performance_marketing/Attribution model for Haven
Holidays.docx`, `product_scratchpad/Attribution/`.

**Questions owned (spend allocation):**
- Which channels bring owners with the **highest lifetime value**, not just the most leads?
- What's the **LTV-to-CPA ratio** by channel?
- Where should next quarter's budget go?
- Which campaigns touch owners who stay **five years or more**?

## Platform — lead Peter

Team: Sarunas, Gary, John P, Charan, Ian.

**Domain:** orchestration, MCP server, CoWork, the **knowledge agent**, and the demo. **No
semantic view of its own — owns integration.**

Peter built and tested the full chain on 23–24 Sep and demos it at 09:25. The knowledge agent
is Peter's idea — persists validated findings so repeated questions get consistent answers (see
[01](01-project-overview.md) and [09](09-benchmark-and-divergence.md)).

**Pre-reading:** Snowflake `CREATE AGENT` reference (how one agent references another), Cortex
Agents MCP server, CoWork; `haven_data_science_artefacts/Planning/ai_enablement_strategy.md`
§2.3. Talk to Peter — he knows where the friction is.

## The integration question (the demo) — needs all three domains

> **"Show me acquisition channels ranked by the lifetime value of the owners they produced,
> against what we spent to get them."**

No single domain answers this. It needs Performance Marketing's channel data, Top of Funnel's
journey and cost, and Owner LTV's value — **joined on the shared `HAVEN_ID` owner definition.**
That's the demo.
