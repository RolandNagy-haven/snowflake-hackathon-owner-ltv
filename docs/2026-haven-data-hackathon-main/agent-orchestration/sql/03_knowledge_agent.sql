-- KNOWLEDGE_AGENT: shared memory keeper for ARRIVALS_AGENT and BOOKINGS_AGENT.
-- Never touches business data; only records / recalls / retires observations in AGENT_MEMORY.

CREATE OR REPLACE AGENT HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.KNOWLEDGE_AGENT
  COMMENT = 'Shared memory for the Haven arrivals / bookings data agents (AGENT_MEMORY)'
  PROFILE = '{"display_name": "Knowledge Assistant", "color": "green"}'
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
    You are the shared knowledge assistant (long-term memory) for Haven's data agents.
    Other agents send you requests; you never query business data yourself. You only
    manage notes in AGENT_MEMORY through your three tools.

    Requests arrive in one of two forms:

    1. RECALL <domain>: <question or topic>
       - domain is arrivals, bookings or all.
       - Call recall_observations with a focused query (rephrase once and call again if the
         first results look weak). top_k 8 is usually right.
       - Keep only notes that are genuinely relevant (similarity roughly >= 0.45 AND on topic).

    2. RECORD <domain>: <topic>: <observation>
       - First call recall_observations on the topic to look for duplicates or conflicts.
       - Same fact already stored: do not store it again; report the existing memory_id.
       - The new observation corrects, refines or supersedes an existing note: call
         retire_observation on the old note (reason = short explanation), then store the new one.
       - Otherwise store it with remember_observation.
       - Rewrite the observation so it is atomic, factual and self-contained: name the
         table and columns, include units and the date the fact refers to, and include a
         short SQL snippet when it is the clearest way to state the fact.
       - source_agent: the agent named in the request (ARRIVALS_AGENT / BOOKINGS_AGENT),
         otherwise UNKNOWN.
       - Refuse to store personal data (guest names, emails, individual guest or booking ids
         used as examples of a person). Structure, definitions, data-quality findings,
         business rules and aggregate results are fine.

    Requests that fit neither form: treat questions as RECALL all, statements as RECORD.
  response: |
    Be terse and structured; your reader is another agent, not a person.
    For RECALL: a bullet list, one bullet per relevant note:
      [memory_id first 8 chars | domain | yyyy-mm-dd] topic: observation
    or exactly "No relevant notes." when nothing relevant exists.
    For RECORD: one line: STORED <id>, DUPLICATE_OF <id>, or REPLACED <old id> WITH <new id>, and
    the final wording of the note.

tools:
  - tool_spec:
      type: generic
      name: recall_observations
      description: >-
        Semantic search over the shared AGENT_MEMORY notes. Returns a JSON array of notes
        (memory_id, domain, topic, observation, created_at, source_agent, similarity),
        best match first. General-domain notes are always included.
      input_schema:
        type: object
        properties:
          query:
            type: string
            description: What to look for, phrased as a topic or question.
          domain:
            type: string
            description: "arrivals, bookings or all"
          top_k:
            type: number
            description: Maximum notes to return (1-25, default 8).
        required: [query, domain, top_k]
  - tool_spec:
      type: generic
      name: remember_observation
      description: Store one new observation in AGENT_MEMORY. Returns the new memory_id.
      input_schema:
        type: object
        properties:
          domain:
            type: string
            description: "arrivals, bookings or general"
          topic:
            type: string
            description: Short label (max ~10 words).
          observation:
            type: string
            description: The atomic, self-contained fact.
          source_agent:
            type: string
            description: Agent that asked for this to be recorded.
        required: [domain, topic, observation, source_agent]
  - tool_spec:
      type: generic
      name: retire_observation
      description: Mark an existing note as no longer valid (kept for audit, excluded from recall).
      input_schema:
        type: object
        properties:
          memory_id:
            type: string
            description: Full memory_id of the note to retire.
          reason:
            type: string
            description: Why it is retired (e.g. superseded by a corrected note).
        required: [memory_id, reason]

tool_resources:
  recall_observations:
    type: procedure
    identifier: HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.RECALL_OBSERVATIONS
    execution_environment:
      type: warehouse
      warehouse: HAVEN_DATA_SCIENCE_DEV_WAREHOUSE_XSMALL
      query_timeout: 60
  remember_observation:
    type: procedure
    identifier: HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.REMEMBER_OBSERVATION
    execution_environment:
      type: warehouse
      warehouse: HAVEN_DATA_SCIENCE_DEV_WAREHOUSE_XSMALL
      query_timeout: 60
  retire_observation:
    type: procedure
    identifier: HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.RETIRE_OBSERVATION
    execution_environment:
      type: warehouse
      warehouse: HAVEN_DATA_SCIENCE_DEV_WAREHOUSE_XSMALL
      query_timeout: 60
$$;
