# 03 — Teams & Roles

> **Change for this KB:** Roland is on **Owner LTV** and is the **lead** of that team (taking
> the lead role in place of Rida). The briefing originally listed Rida as lead; for our
> purposes Roland leads and Rida is a team member.

## The four teams

| Owner LTV | Top of Funnel | Performance Marketing | Platform |
|---|---|---|---|
| **Roland (lead)** | **Matt (lead)** | **Dan C (lead)** | **Peter (lead)** |
| Rida | Balint | Alina | Sarunas |
| Victor | Lewis | Judy | Gary |
| Abdul | Kirsty | Dan G | John P |
| Joe | Donovan | Jade | Charan |
| Elisha | Fraser | Ahsan | Ian |

Every team deliberately mixes **engineers and scientists**. Go to your lead first with anything.

## Who built what (domain expertise)

- **Matt** built the top-of-funnel report *and* its Tableau front end.
- **Dan C** built the facts and dimensions in Performance Marketing plus the Sigma reporting.
- **Roland and Rida** have worked the owner data through **Pitch Perfect**, with **Joe** on the
  **churn model** that feeds it.
- **Peter** built and tested the entire agentic chain (semantic views → agents → orchestration)
  on 23–24 September; he demos it at 09:25.
- **Giedrius** created the reference `SEM_EPOS_SALES` semantic view used for prep.
- **Gary** (Lead Engineer, Data Foundations) provisioned the role/database/warehouse.
- **Donovan Ransome** (Senior Product Manager – Data) organises the day and wrote the join
  evidence paper.

## What each team owns

| Team | Domain | Main tables |
|---|---|---|
| **Owner LTV** | What an owner is worth and how long they stay. Owner account history + churn model | `OWNER_RISK_SCORES`, `OWNER_STATUS_TIME_SERIES_ANALYSIS`, `FCT_ACCOUNT_HISTORY`, `DIM_PARK` |
| **Top of Funnel** | The prospect-to-owner journey (enquiry → appointment → signup → completion) | `FCT_TOP_OF_THE_FUNNEL`, `DIM_TOP_OF_THE_FUNNEL`, the `BRIDGE_*_TO_CS_TIERED_XID` family |
| **Performance Marketing** | Which channels/campaigns touch an owner on the way in. Bloomreach + attribution | `FCT_ATTRIBUTION_JOURNEY_SUMMARY`, `FCT_ATTRIBUTION_CHANNEL_JOURNEY_ROLE`, `DIM_BLOOMREACH_CUSTOMER` |
| **Platform** | Orchestration, MCP server, CoWork, the knowledge agent, the demo | No semantic view of its own — owns integration |

## Key business stakeholders

- **Rachel Gregory** — Pitch Profitability Director. Owns the LTV ask; opens the day at 09:10
  presenting the questions the business will actually ask.
- **Caravan Sales** — owns the Top of Funnel / funnel-efficiency questions.
- **Marketing** — owns the spend-allocation / attribution questions.
