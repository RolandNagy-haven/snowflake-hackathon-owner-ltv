-- Agent-to-agent delegation with conversation threads - copied from agent-orchestration/sql/02_agent_delegation.sql
-- (RUN_AGENT + AGENT_CALL_LOG), retargeted to {{DB}}.{{SCHEMA}} so this sample is self-contained.
-- Why: the built-in MCP tool type CORTEX_AGENT_RUN (and the agent handoff) takes only {"text"} - every call is a new,
-- stateless run. RUN_AGENT runs the target with SNOWFLAKE.CORTEX.DATA_AGENT_RUN and continues its server-side thread
-- (thread_id + parent_message_id) when given a thread_ref, returning the updated thread_ref with every answer.
-- EXECUTE AS CALLER keeps the end user's grants down the chain and keeps the sub-agent's code sandbox
-- (owner's-rights invocation strips code-execution tools, which SV_AGENT_5_PANDAS needs).

CREATE TABLE IF NOT EXISTS {{DB}}.{{SCHEMA}}.AGENT_CALL_LOG (
    CALLED_AT     TIMESTAMP_LTZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    CALLED_BY     VARCHAR       NOT NULL DEFAULT CURRENT_USER(),
    TARGET_AGENT  VARCHAR       NOT NULL,
    REQUEST       VARCHAR,
    ANSWER        VARCHAR,
    TOOLS_USED    ARRAY,
    WARNINGS      VARIANT,
    ELAPSED_S     NUMBER(10, 1),
    RUN_ID        VARCHAR,
    ERROR         VARCHAR
);
ALTER TABLE {{DB}}.{{SCHEMA}}.AGENT_CALL_LOG ADD COLUMN IF NOT EXISTS THREAD_ID NUMBER;
ALTER TABLE {{DB}}.{{SCHEMA}}.AGENT_CALL_LOG ADD COLUMN IF NOT EXISTS PARENT_MESSAGE_ID NUMBER;

CREATE OR REPLACE PROCEDURE {{DB}}.{{SCHEMA}}.RUN_AGENT(
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

LOG = "{{DB}}.{{SCHEMA}}.AGENT_CALL_LOG"


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
        texts = []  # keep only the text after the last tool call: the final answer, not the narration
        for part in resp.get("content", []):
            if part.get("type") == "text" and part.get("text", "").strip():
                texts.append(part["text"].strip())
            elif part.get("type") in ("tool_use", "tool_result"):
                texts = []
                name = (part.get("tool_use") or {}).get("name")
                if name:
                    tools.append(name)
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

-- Narrow tool for agent 5 (threaded). THREAD_REF: 'new' or '<thread_id>:<assistant_message_id>' from an earlier answer.
CREATE OR REPLACE PROCEDURE {{DB}}.{{SCHEMA}}.ASK_PANDAS_AGENT_THREADED(QUESTION VARCHAR, THREAD_REF VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS CALLER
AS
$$
def run(session, question, thread_ref):
    return session.call("{{DB}}.{{SCHEMA}}.RUN_AGENT",
                        "{{DB}}.{{SCHEMA}}.SV_AGENT_5_PANDAS", question, thread_ref or "new")
$$;
