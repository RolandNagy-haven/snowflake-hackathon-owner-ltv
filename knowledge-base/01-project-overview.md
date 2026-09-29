# 01 — Project Overview

## Why we're doing this

Three separate requests about owners are open right now, across three business teams:

| The ask | Who asked | Status today |
|---|---|---|
| **Owner Lifetime Value** — what an owner is worth, including costs | Rachel Gregory, Pitch Profitability Director | Requested, spec written |
| **Top of Funnel** — the prospect-to-owner journey | Caravan Sales + Data Engineering | In progress |
| **Owner Attribution** — which routes a lead actually takes | Marketing | Built, but standalone |

Built **separately**, these three disagree — different owner definitions, different cost bases,
different attribution windows. Haven just lived through exactly this on **F&B revenue**, where
Data Science and reporting produced different numbers from one source and it took weeks to
reconcile.

Built **together**, they answer a question the business genuinely cannot answer today:

> **Which acquisition routes produce the owners worth having?**
> Not which produce the most leads — which produce owners who *stay, spend, and are worth the
> cost of acquiring*.

### The real problem (from the LTV spec)

> "Top-of-funnel volume growth without an LTV understanding is value-destructive — if they only
> last a year or two years, we're making life harder for ourselves."

- Owner acquisition is measured on **enquiry volume** because that's the only number available.
- CPA is measured **per gross sign-up**, not per completion — so a channel with a 20%
  cancellation rate and one with 50% look identical.
- The only levers to convert volume are **free site fees** or **caravan price reductions** —
  both destroy margin.

### The honest second reason

This team has **never all been in one room** — people in Budapest, Vilnius, Hemel and remote UK
who mostly met only on standups. Data Engineering and Data Science have spent the year handing
work over rather than building together. Until this week nobody on the team had built an
**agentic system or a semantic layer**; Peter built and tested the whole chain on 23–24
September. **Building that capability is a real objective of the day, not a side effect.**

> The team being in one room is most of the value. Nobody is judging this on how polished the
> models are.

## What we're building

Three domain agents over a shared owner definition, all reachable from one prompt — plus a
**knowledge agent** that remembers what gets asked and learned.

```
Snowflake CoWork   ← the business asks here, in plain language
        │
   Orchestrator agent
   ┌───────┼───────┬──────────────┐
Owner LTV  Top of  Performance   Knowledge
 agent     Funnel  Marketing     agent
           agent   agent         (what we learn about owners)
   └───────┼───────┘
     shared owner definition
```

Each domain agent sits on a **semantic view** — a Snowflake object describing your tables in
business language, so the agent can answer questions without anyone hand-writing SQL.

### Three steps, mapped onto the day

| Step | What | When |
|---|---|---|
| 1 | Build the **semantic layer** — tables, joins, metrics, business descriptions | Morning |
| 2 | Stand up an **agent** on your semantic layer | Afternoon |
| 3 | Connect everything to an **LLM via MCP** so one prompt reaches all agents | Platform team, all day |

All Snowflake-native: `CREATE SEMANTIC VIEW`, `CREATE AGENT`, MCP server, CoWork as front end.
No third-party tooling, no UI to build, no cross-vendor integration.

### The knowledge agent (Peter's idea — the most interesting piece)

As people ask the Big Brain questions, what it learns about owners gets **stored and reused**
rather than re-derived from scratch. If every question is answered fresh, two people asking the
same thing slightly differently get different answers. If validated findings persist — *"owners
acquired through this channel at this park last on average X"* — the system gets smarter and
more consistent with use. That's the difference between a query tool and something that
**accumulates corporate knowledge**.

## What we keep afterwards

| Deliverable | Why it lasts |
|---|---|
| The agreed **owner definition and join map** | What three teams would otherwise each invent differently. **The real deliverable** |
| Three **semantic views** with real business descriptions | Reusable by CoWork, Sigma, Tableau, or any future agent |
| A team that has **built an agentic system** | Two weeks ago that was nobody — the capability gap closing |
| Three agents, an orchestrator, a knowledge agent | The pattern, proven on our own data |
| The **benchmark result** | Framework vs raw Claude-on-Snowflake, honestly measured — useful either way |

## What this day is NOT

- **Not** three finished models. One working thread.
- **Not** a delivery commitment. Nothing goes to production on Wednesday.
- **Not** a competition between teams. Integration is the point — three brilliant agents that
  can't talk to each other is a failed day.
- **Not** a test of you. If your domain turns out harder than expected, say so at the 12:30
  checkpoint and narrow scope. **That's a finding, not a failure.**

## After the day

**Snowflake World Tour** at ExCeL, Wednesday 30 September. Free, not mandatory. The Cortex and
agentic tooling sessions are directly relevant — pick sessions in advance.
