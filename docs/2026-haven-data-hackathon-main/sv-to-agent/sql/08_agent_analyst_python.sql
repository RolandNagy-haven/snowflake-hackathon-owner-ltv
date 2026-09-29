-- Agent 6: combined route. Cortex Analyst (cortex_analyst_text_to_sql) answers everything SQL can express over the
-- semantic view; the single-tool Python sandbox (code_execution) takes over only for analysis SQL can't do well.
-- Documented combination: code_execution runs "alongside other agent tools"; it has no Snowflake access of its own -
-- the agent runs SQL with its SQL tools (Analyst + the auto-added system_execute_sql) and passes the results in.
-- Only documented spec fields are used (no instructions.system), so it stays editable in Snowsight.
-- permission_policy always_allow: the REST client in this repo can't answer tool-approval prompts.
-- Note: code execution is not supported when the agent is called with owner's rights.
CREATE OR REPLACE AGENT {{DB}}.{{SCHEMA}}.SV_AGENT_6_ANALYST_PYTHON
  COMMENT = 'sv-to-agent: Cortex Analyst over the semantic view + code_execution (pandas) for post-processing'
  PROFILE = '{"display_name": "Footfall 6 - Analyst + Python"}'
  FROM SPECIFICATION
$$
models:
  orchestration: claude-opus-4-8

orchestration:
  budget:
    seconds: 600
    tokens: 150000

instructions:
  orchestration: |
    You answer questions about Haven park footfall from the FOOTFALL_ARRIVALS_SV_V3 semantic view.
    - Get all data through footfall_analyst. Ask it for what SQL can express directly: totals, averages, ratios,
      rankings, and also medians, percentiles, std dev and correlations over a daily series.
    - When a per-day series or a per-day average is involved, ask footfall_analyst for the zero-filled daily
      metric (guests_on_park for guests) or to include days with no guests as zero - a day with no guest rows
      means zero, not missing data - and check the returned day counts are complete for the period.
    - Use code_execution only when the analysis can't reasonably be done in one SQL query: multi-step
      transformations, reshaping or joining several results, modelling / forecasting, regressions,
      simulations, or anything needing numpy / scipy. In that case ask footfall_analyst for the data at the
      grain you need (e.g. park x day, all days included) and do the rest in pandas on those results.
    - Never add owner heads to guest numbers.
  response: |
    Answer concisely with a small table when there are several rows. State the period, the metric definition,
    and whether a figure was computed in SQL or in Python.

tools:
  - tool_spec:
      type: cortex_analyst_text_to_sql
      name: footfall_analyst
      description: >-
        Text-to-SQL over the FOOTFALL_ARRIVALS_SV_V3 semantic view: booked guests (Holiday Makers + Private Lets)
        on park per night, arrivals, last full day, leavers, distinct bookings, self-catering, ratios, by park,
        region, date, stay type, age and play pass; plus separately estimated owner heads (indicative only).
        Can also compute medians, percentiles, std dev and correlations over daily series.
  - tool_spec:
      type: code_execution
      name: code_execution

tool_resources:
  footfall_analyst:
    semantic_view: {{DB}}.{{SCHEMA}}.FOOTFALL_ARRIVALS_SV_V3
    execution_environment:
      type: warehouse
      warehouse: {{WH}}
      query_timeout: 120
  code_execution:
    permission_policy:
      type: always_allow
$$;
