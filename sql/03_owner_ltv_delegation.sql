-- =============================================================================
-- Owner LTV -- expose the agent as an orchestrator tool  (Peter's flow, step 5)
-- =============================================================================
-- OWNER_LTV_AGENT (an Analyst-tool Cortex Agent) is made callable by the master
-- orchestrator and by external MCP clients (Claude Code) as a threaded tool.
--
-- Why a procedure, not the built-in CORTEX_AGENT_RUN handoff: that tool type only
-- accepts {"text"} -- every call is a new, stateless run. RUN_AGENT invokes the
-- target with SNOWFLAKE.CORTEX.DATA_AGENT_RUN and continues its server-side thread
-- (thread_id + parent_message_id) when given a thread_ref, so follow-up questions
-- keep context. It returns the updated thread_ref with every answer.
--
-- EXECUTE AS CALLER keeps the end user's grants (and their role's visibility into
-- the semantic view's base tables) all the way down the chain -- every hop runs as
-- the user who called the orchestrator, logged in AGENT_CALL_LOG.CALLED_BY.
--
-- Pattern adapted from docs/.../sv-to-agent/sql/09_agent_delegation.sql + 10_pandas_agent_mcp.sql.
--
-- Deploy:  python scripts/deploy_owner_ltv_delegation.py
-- Objects: NEXUS_HACKATHON_DB.OWNER_LTV_SV.{AGENT_CALL_LOG, RUN_AGENT,
--          ASK_OWNER_LTV_AGENT, OWNER_LTV_AGENT_MCP}
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Call log: one row per delegated agent call (who asked what, answer, thread).
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS NEXUS_HACKATHON_DB.OWNER_LTV_SV.AGENT_CALL_LOG (
    CALLED_AT     TIMESTAMP_LTZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    CALLED_BY     VARCHAR       NOT NULL DEFAULT CURRENT_USER(),
    TARGET_AGENT  VARCHAR       NOT NULL,
    REQUEST       VARCHAR,
    ANSWER        VARCHAR,
    TOOLS_USED    ARRAY,
    WARNINGS      VARIANT,
    ELAPSED_S     NUMBER(10, 1),
    RUN_ID        VARCHAR,
    ERROR         VARCHAR,
    THREAD_ID         NUMBER,
    PARENT_MESSAGE_ID NUMBER
);

-- ---------------------------------------------------------------------------
-- 2. Generic delegation proc: run any agent, optionally continuing a thread.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE NEXUS_HACKATHON_DB.OWNER_LTV_SV.RUN_AGENT(
    AGENT_NAME VARCHAR, QUESTION VARCHAR, THREAD_REF VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS CALLER
AS
$$
import json
import re
import time

LOG = "NEXUS_HACKATHON_DB.OWNER_LTV_SV.AGENT_CALL_LOG"
# Rendering tools run AFTER the answer text is written (this Analyst agent draws the chart
# it just described via server_skill -> data_to_chart). They must not count as "the last
# tool", or the substantive answer emitted just before them is dropped as pre-tool narration.
# Only the data-producing tools (owner_ltv_analyst, system_execute_sql) should reset the buffer.
RENDER_TOOLS = {"data_to_chart", "server_skill"}


def run(session, agent_name, question, thread_ref):
    """thread_ref: 'stateless' (no thread), 'new' (start a thread) or '<thread_id>:<parent_message_id>'."""
    if not re.fullmatch(r"[A-Za-z0-9_$]+\.[A-Za-z0-9_$]+\.[A-Za-z0-9_$]+", agent_name or ""):
        return json.dumps({"error": f"invalid agent name {agent_name!r}"})
    ref = (thread_ref or "stateless").strip().lower()
    threaded = ref != "stateless"
    thread_id = parent_id = None
    if threaded and ref not in ("new", ""):
        m = re.fullmatch(r"(\d+):(\d+)", ref)
        if not m:
            return json.dumps({"error": f"invalid thread_ref {thread_ref!r}: use 'new' or the thread_ref from an earlier answer"})
        thread_id, parent_id = int(m.group(1)), int(m.group(2))

    body = {"messages": [{"role": "user", "content": [{"type": "text", "text": question}]}]}
    if thread_id is not None:
        body.update(thread_id=thread_id, parent_message_id=parent_id)
    # 3rd argument TRUE = create a thread when the body has none (only wanted for 'new')
    create = ", TRUE" if threaded and thread_id is None else ""

    t0 = time.time()
    answer, tools, warnings, run_id, error, new_ref = None, [], None, None, None, None
    try:
        raw = session.sql(f"SELECT SNOWFLAKE.CORTEX.DATA_AGENT_RUN('{agent_name}', ?{create})", params=[json.dumps(body)]).collect()[0][0]
        resp = json.loads(raw)
        if "content" not in resp:  # error payload: {code, message, request_id, ...}
            raise RuntimeError(resp.get("message") or raw[:2000])
        # Keep only the text after the last DATA tool call (the final answer, not the
        # pre-tool narration). Both tool_use and tool_result parts carry the tool name, so a
        # rendering tool (server_skill / data_to_chart) that fires after the answer does not
        # reset the buffer; only data-producing tools do.
        texts = []
        for part in resp.get("content", []):
            typ = part.get("type")
            if typ == "text" and part.get("text", "").strip():
                texts.append(part["text"].strip())
            elif typ in ("tool_use", "tool_result"):
                name = (part.get(typ) or {}).get("name")
                if typ == "tool_use" and name:
                    tools.append(name)
                if name not in RENDER_TOOLS:  # a data tool (or unnamed) -> pre-answer, reset
                    texts = []
        answer = "\n\n".join(texts).replace("</thinking>", "").strip() or None
        warnings = resp.get("warnings") or None
        meta = resp.get("metadata") or {}
        run_id = meta.get("run_id")
        if threaded:
            thread_id = meta.get("thread_id") or thread_id
            if thread_id and meta.get("assistant_message_id"):
                new_ref = f"{thread_id}:{meta['assistant_message_id']}"
        if answer is None:
            error = "agent returned no text: " + raw[:2000]
    except Exception as e:  # surface the failure to the calling agent instead of failing the tool call
        error = str(e)[:4000]
    elapsed = round(time.time() - t0, 1)
    session.sql(
        f"INSERT INTO {LOG} (TARGET_AGENT, REQUEST, ANSWER, TOOLS_USED, WARNINGS, ELAPSED_S, RUN_ID, ERROR, "
        "THREAD_ID, PARENT_MESSAGE_ID) "
        "SELECT ?, ?, NULLIF(?, ''), PARSE_JSON(?), PARSE_JSON(?), ?, NULLIF(?, ''), NULLIF(?, ''), "
        "TRY_TO_NUMBER(NULLIF(?, '')), TRY_TO_NUMBER(NULLIF(?, ''))",
        # None would bind as the string 'None'; pass '' and NULLIF it instead
        params=[agent_name, question, answer or "", json.dumps(tools), json.dumps(warnings), elapsed,
                run_id or "", error or "", str(thread_id or ""), str(parent_id or "")],
    ).collect()
    out = {"agent": agent_name, "answer": answer}
    if threaded:
        out["thread_ref"] = new_ref
    out.update(tools_used=tools, elapsed_s=elapsed)
    if warnings:
        out["warnings"] = warnings
    if error:
        out["error"] = error
    return json.dumps(out)
$$;

-- ---------------------------------------------------------------------------
-- 3. Narrow wrapper bound to OWNER_LTV_AGENT (threaded; defaults to a new thread).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE NEXUS_HACKATHON_DB.OWNER_LTV_SV.ASK_OWNER_LTV_AGENT(QUESTION VARCHAR, THREAD_REF VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS CALLER
AS
$$
def run(session, question, thread_ref):
    return session.call("NEXUS_HACKATHON_DB.OWNER_LTV_SV.RUN_AGENT",
                        "NEXUS_HACKATHON_DB.OWNER_LTV_SV.OWNER_LTV_AGENT", question, thread_ref or "new")
$$;

-- ---------------------------------------------------------------------------
-- 4. MCP server: expose the wrapper as a GENERIC tool for the orchestrator + Claude Code.
-- Endpoint: https://<account_url>/api/v2/databases/NEXUS_HACKATHON_DB/schemas/OWNER_LTV_SV/mcp-servers/OWNER_LTV_AGENT_MCP
-- ---------------------------------------------------------------------------
CREATE OR REPLACE MCP SERVER NEXUS_HACKATHON_DB.OWNER_LTV_SV.OWNER_LTV_AGENT_MCP
  FROM SPECIFICATION $$
tools:
  - title: "Ask the Owner LTV analyst (threaded)"
    name: "ask_owner_ltv_agent"
    type: "GENERIC"
    identifier: "NEXUS_HACKATHON_DB.OWNER_LTV_SV.ASK_OWNER_LTV_AGENT"
    description: >-
      Ask OWNER_LTV_AGENT, the Owner LTV analyst for Haven holiday-park owners, over the
      OWNER_LTV_SV_V1 semantic view. Answers what an owner is worth: overall rent ledger value
      (each owner account's latest month-end balance, summed -- a balance, can be negative) and
      lifetime on-park owner-card spend (a partial measure), broken down by park, park tier /
      pitch strategy group, and region. Grain is the owner ACCOUNT_NO, not the person; HAVEN_ID
      is a non-unique, ~58%-populated person dimension. Takes a question and a thread_ref ("new"
      or one returned earlier); returns JSON with its answer, the updated thread_ref, the tools
      it used and elapsed seconds.
    config:
      type: "procedure"
      warehouse: "NEXUS_HACKATHON_WH"
      input_schema:
        type: "object"
        properties:
          question:
            type: "string"
            description: >-
              The owner-value question. Self-contained with explicit parks, tiers, regions and
              definitions for a new thread; may refer back to earlier answers when continuing.
          thread_ref:
            type: "string"
            description: >-
              "new" to start a fresh conversation with the analyst, or the latest thread_ref
              returned by ask_owner_ltv_agent to continue that conversation.
        required: ["question", "thread_ref"]
$$;
