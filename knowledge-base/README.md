# Owner Big Brain — Knowledge Base

Hackathon: **Tuesday 29 September 2026**, Hemel office. 09:00 start, demo at 17:00.

This knowledge base distills the briefing pack (Donovan's hackathon briefing, the two
briefing emails from Donovan and Gary, Donovan Ransome's "How We Join the Three Domains"
evidence paper, and the `additional_sql` BBV query) into an organised reference for the day.

> **Personal note for this KB:** Roland (that's me) is on the **Owner LTV** team and is the
> **team lead** for it (taking the lead role in place of Rida). See
> [03 — Teams and Roles](03-teams-and-roles.md).

## The one-line goal

Build three domain agents (Owner LTV, Top of Funnel, Performance Marketing) over a **shared
owner definition**, all reachable from one prompt, plus a knowledge agent — so the business
can finally answer: **"Which acquisition routes produce the owners worth having?"**

## Contents

| # | File | What's in it |
|---|------|--------------|
| 01 | [Project overview](01-project-overview.md) | Why we're doing this, what we're building, what we keep, what it is *not* |
| 02 | [Agenda & logistics](02-agenda-and-logistics.md) | The full day timetable, environment, pre-Tuesday prep |
| 03 | [Teams & roles](03-teams-and-roles.md) | All four teams, leads, who built what (Roland = Owner LTV lead) |
| 04 | [Owner definition & joins](04-owner-definition-and-joins.md) | The `HAVEN_ID` spine, the join map, the 09:45 decisions |
| 05 | [Owner LTV playbook](05-owner-ltv-playbook.md) | Deep dive for my team — tables, grain, proxies, the v4 SQL |
| 06 | [Other domains](06-other-domains.md) | Top of Funnel, Performance Marketing, Platform |
| 07 | [Business questions](07-business-questions.md) | The questions each domain must answer at 17:00 |
| 08 | [Traps & gotchas](08-traps-and-gotchas.md) | Every verified trap, by team |
| 09 | [Benchmark & divergence](09-benchmark-and-divergence.md) | The demo benchmark + the divergence problem we want to show |
| 10 | [Churn-model repo](10-churn-model-repo.md) | Joe's `service-haven-data-ownerchurn` — risk-score definitions, `OWNER_RISK_SCORES`, and Joe's static LTV view |
| 11 | [Tooling & build method](11-tooling-and-build-method.md) | Peter's deck — semantic views, Cortex Agents, MCP, and the 5-step Claude Code build flow |
| 12 | [Reference implementation](12-reference-implementation.md) | Peter's working repo (`2026-haven-data-hackathon-main`) — code patterns, agent orchestration, the knowledge agent, the shared-owner-view topics |
| 13 | [Definitions meeting](13-definitions-meeting.md) | Whiteboard transcript — owner lifecycle statuses, routes into ownership, lead vs prospect, Amplitude/consent caveats, owner-spend tracking |

## The single most important hour

**09:45–10:30, whole team.** Two things get decided that cannot be parallelised: *what counts
as an owner*, and *how we join across the three domains*. Get these wrong and the three agents
confidently disagree — the exact failure the day exists to prevent. See
[04 — Owner definition & joins](04-owner-definition-and-joins.md).
