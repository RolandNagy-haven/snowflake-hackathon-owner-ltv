# 02 — Agenda & Logistics

## The day

| Time | What | Who |
|---|---|---|
| 09:00 | Why we're here and what we're trying to do | Donovan |
| 09:10 | What the business is actually asking — customer lifetime value | **Rachel Gregory** |
| 09:25 | The tooling, and how it's set up — semantic views, agents, what Peter found | **Peter** |
| 09:45 | ⚠️ **Whole-team brainstorm: what is an owner, and how do we join this data?** | Everyone |
| 10:30 | Teams split. **Step 1 — build your semantic layer** | Domain teams |
| 12:30 | ⚠️ **Checkpoint** — every team has a semantic view answering one real question. 🍕 Working lunch | All |
| 13:15 | **Step 2 — build your agent** | Domain teams |
| 14:30 | ⚠️ **Checkpoint 2** — the orchestrator reaches all the agents | All |
| 15:00 | **Verified queries** for the demo questions | Domain teams |
| 16:00 | Rehearse. Fix what breaks | All |
| 17:00 | ⚠️ **Demo** — the business comes back in | All |

## Why 09:45 is the most important 45 minutes

Two things get decided that **cannot be parallelised**:

1. **What counts as an owner** — active only or including leavers? The account or the person?
   Joint owners as one or two? If three teams answer differently, we get three agents that
   confidently disagree.
2. **How we join across the three domains** — the harder half. Owner LTV keys on `ACCOUNT_NO`;
   Top of Funnel keys on `TOTF_TIERED_XID` (which resolves through email → Freshsales contact →
   analytics ID → plot owner); Performance Marketing keys on Bloomreach customer identity.
   Getting from a marketing touch to an owner account is the **single hardest technical problem
   of the day** and needs deciding by everyone, once, at the start.

Full analysis and the recommended answer: [04 — Owner definition & joins](04-owner-definition-and-joins.md).

## The 12:30 checkpoint — a view, not an agent

By pizza, every domain team should have a **working semantic view that answers one real
question**. Not an agent. If you don't, say so — that's what the checkpoint is for, and there's
still half a day.

## What's already set up (no setup on the day)

Peter tested end to end; Gary provisioned.

| Item | Detail |
|---|---|
| **Role** | `NEXUS_SPIKE` — use this on the day; everything you need is on it |
| **Target database** | `NEXUS_HACKATHON_DB` |
| **Warehouse** | `NEXUS_HACKATHON_WH` |
| **Capabilities** | Create semantic views, create agents, read source data — all tested by Peter |
| **Cortex** | Working, tested in our region |

### Access check (should already be done — was due Friday 25th)

```sql
USE ROLE NEXUS_SPIKE;
SELECT CURRENT_ROLE();
```

If it fails, that was a Donovan/Gary escalation for Friday 25th.

## Pre-Tuesday prep (everyone)

1. Read the briefing.
2. Check `NEXUS_SPIKE` works (two lines above).
3. Study a working semantic view on our own data — **the best ten minutes of prep available**:
   ```sql
   DESCRIBE SEMANTIC VIEW NEXUS_PLATINUM.EPOS_SALES.SEM_EPOS_SALES;
   ```
   (Real EPOS semantic view by Giedrius, with real business context — GBP, rounding, how
   refunds work. You'll write something this shape.)
4. Skim the Snowflake docs — semantic views overview + worked example (~20 min).
5. **Read the validation rules.** The two that bite: semantic views **reject many-to-many
   relationships**, and **reject joins where two tables can be reached by more than one path**.
   Knowing this before you model saves an afternoon.
6. Come with your domain's identifiers in your head for 09:45.

## Prep with your team + lead (before Tuesday)

1. **Agree your 4–6 tables.** Not twenty — semantic views get hard fast and you have one day.
2. **Pre-flatten the problem tables into views.** Each trap in
   [08 — Traps & gotchas](08-traps-and-gotchas.md) is a rejection or performance wall waiting to
   happen.
3. **Draft your five questions** — the ones your agent answers at 17:00. These become verified
   queries, the highest-value thing you'll do all day.

## Escalation

Ask your **lead** first, then Donovan. Flag by Friday 25th if: `NEXUS_SPIKE` doesn't work, your
tables won't fit the constraints, or your domain looks scoped wrong.
