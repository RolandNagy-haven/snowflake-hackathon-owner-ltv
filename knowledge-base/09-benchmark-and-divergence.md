# 09 — The Benchmark & The Divergence Problem

## The demo has a benchmark

At 17:00 we don't just show it works. We take the **first question** and ask it two ways:

1. **Through the framework we built** — semantic layers, domain agents, orchestrator.
2. **Straight to Claude connected to Snowflake, with no semantic layer.**

Then compare the answers **and how long each took**.

⚠️ **This is a real test and it might not flatter us.** Claude-on-raw-Snowflake may be faster and
may even get the right answer. What we *expect* is that it's slower on complex questions, less
consistent between runs, and unable to explain *which definition it used* — which is exactly the
argument for a governed semantic layer.

✅ **If the simple approach turns out better, that's a genuinely valuable finding and we report
it.** Nobody is being asked to make the framework look good.

## The divergence problem (Peter's — the most important point in the briefing)

Peter asked Claude to correlate a heatwave against F&B consumption using two parallel agents.
One decided a "warm year" meant the **maximum temperature recorded**; the other counted **days
above 20°C**. Same question, two defensible methods, different answers.

> "It's not really about data quality or what you show… It's derived procedures when the AI has
> multiple choices of getting really a more complicated result."

⚠️ **A semantic layer does not fix this.** Curating the data fixes *which numbers* an agent uses.
It does **not** fix *which method* it picks. Three agents answering owner questions
independently is precisely the setup that produces divergence — the same failure we lived
through on F&B revenue.

## Three consequences for the day

1. **This is what verified queries are for.** Pin a known question to a known method and the
   agent has no choice to make. → the **15:00** slot. Draft five per team.
2. ✅ **This is what the knowledge agent is for.** If a validated finding persists, the next
   person asking gets the same answer rather than a freshly re-derived one.
3. ✅ **We should show it failing — deliberately.** Ask the orchestrator something the owner
   definition doesn't pin down, and let it diverge in front of the business.

That last one is intentional. Three agents agreeing **by luck** teaches nobody anything.

> ⚠️ Overselling AI-on-data is how good ideas lose credibility — being straight about where it
> needs care is what earns the right to build more.

## Where our owner definition prevents divergence

The 09:45 decisions ([04](04-owner-definition-and-joins.md)) are the concrete defence:
- One spine (`HAVEN_ID`), so all three agents count the same population.
- One agreed person-vs-account rule, so "owner" means the same thing everywhere (the 1.7% gap
  otherwise shows two numbers and the room notices).
- Pre-aggregation to `DISTINCT HAVEN_ID`, so nothing double-counts.
- Stated scope (active owners, 99.6% coverage), so the agent can explain the population it used.
