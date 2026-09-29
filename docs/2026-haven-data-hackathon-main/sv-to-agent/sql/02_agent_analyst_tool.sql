-- Agent 1: the semantic view IS the tool. Cortex Analyst (cortex_analyst_text_to_sql) writes the SQL
-- from the view's metadata, verified queries and custom instructions, and the agent runs it on the warehouse.
CREATE OR REPLACE AGENT {{DB}}.{{SCHEMA}}.SV_AGENT_1_ANALYST
  COMMENT = 'sv-to-agent: semantic view as a Cortex Analyst tool'
  PROFILE = '{"display_name": "Footfall 1 - Analyst tool"}'
  FROM SPECIFICATION
$$
models:
  orchestration: auto

orchestration:
  budget:
    seconds: 240
    tokens: 60000

instructions:
  orchestration: |
    You answer questions about Haven park footfall: booked guests on park, arrivals (first day),
    last full day, leavers, bookings, self-catering, age and play-pass mix, and the separate,
    indicative owner heads. Use the footfall_analyst tool for every data question.
  response: |
    Answer concisely with a small table when there are several rows. State the period and the metric
    definition. Never add owner heads to guest numbers.

tools:
  - tool_spec:
      type: cortex_analyst_text_to_sql
      name: footfall_analyst
      description: >-
        Text-to-SQL over the FOOTFALL_ARRIVALS_SV_V3 semantic view: booked guests (Holiday Makers + Private Lets)
        on park per night, arrivals, last full day, leavers, distinct bookings, self-catering, ratios, by park,
        region, date, stay type, age and play pass; plus separately estimated owner heads (indicative only).

tool_resources:
  footfall_analyst:
    semantic_view: {{DB}}.{{SCHEMA}}.FOOTFALL_ARRIVALS_SV_V3
    execution_environment:
      type: warehouse
      warehouse: {{WH}}
      query_timeout: 120
$$;
