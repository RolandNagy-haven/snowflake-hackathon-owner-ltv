"""Spike S6: triggered task on a stream -> proc that calls AI_COMPLETE (structured) and DATA_AGENT_RUN."""
import sys, time
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / ".claude/skills/snowflake-query"))
from snowflake_session import get_or_create_session
FQ = "HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL"
s = get_or_create_session()
def run(sql, show=True):
    try:
        r = s.sql(sql).collect()
        if show: print("  OK", [x.as_dict() for x in r][:3])
        return r
    except Exception as e:
        print("  ERR:", str(e)[:500]); return None
mode = sys.argv[1] if len(sys.argv) > 1 else "setup"
if mode == "setup":
    run(f"CREATE OR REPLACE TABLE {FQ}.SPIKE_T_SRC (ID INT, TXT VARCHAR)")
    run(f"CREATE OR REPLACE TABLE {FQ}.SPIKE_T_LOG (AT TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(), WHAT VARCHAR, OUT VARIANT)")
    run(f"CREATE OR REPLACE STREAM {FQ}.SPIKE_T_STREAM ON TABLE {FQ}.SPIKE_T_SRC APPEND_ONLY = TRUE")
    run(f"""CREATE OR REPLACE PROCEDURE {FQ}.SPIKE_T_PROC() RETURNS VARCHAR LANGUAGE PYTHON RUNTIME_VERSION='3.11'
PACKAGES=('snowflake-snowpark-python') HANDLER='run' EXECUTE AS OWNER AS $$
import json
def run(session):
    rows = session.sql("SELECT ID, TXT FROM {FQ}.SPIKE_T_STREAM").collect()
    txt = "; ".join(r["TXT"] for r in rows)
    try:
        out = session.sql(\"\"\"SELECT AI_COMPLETE(model => 'claude-sonnet-4-5', prompt => ?,
             response_format => {{'type':'json','schema':{{'type':'object','properties':{{'action':{{'type':'string','enum':['keep','reject']}},'reason':{{'type':'string'}}}},'required':['action','reason']}}}})\"\"\",
             params=["Decide keep or reject for: " + txt]).collect()[0][0]
    except Exception as e:
        out = json.dumps({{"error": str(e)[:1000]}})
    try:
        body = json.dumps({{"messages":[{{"role":"user","content":[{{"type":"text","text":"RECALL all: grain"}}]}}]}})
        ag = session.sql("SELECT SNOWFLAKE.CORTEX.DATA_AGENT_RUN('{FQ}.KNOWLEDGE_AGENT', ?)", params=[body]).collect()[0][0]
        ag = json.dumps({{"ok": True, "len": len(ag), "head": ag[:300]}})
    except Exception as e:
        ag = json.dumps({{"error": str(e)[:1000]}})
    session.sql("INSERT INTO {FQ}.SPIKE_T_LOG (WHAT, OUT) SELECT 'ai', TRY_PARSE_JSON(?)", params=[out if isinstance(out, str) else json.dumps(out)]).collect()
    session.sql("INSERT INTO {FQ}.SPIKE_T_LOG (WHAT, OUT) SELECT 'agent', TRY_PARSE_JSON(?)", params=[ag]).collect()
    # consume the stream
    session.sql("CREATE TEMPORARY TABLE IF NOT EXISTS SPIKE_T_SINK (ID INT)").collect()
    session.sql("INSERT INTO SPIKE_T_SINK SELECT ID FROM {FQ}.SPIKE_T_STREAM").collect()
    return f"processed {{len(rows)}}"
$$""")
    run(f"""CREATE OR REPLACE TASK {FQ}.SPIKE_T_TASK
  WAREHOUSE = HAVEN_DATA_SCIENCE_DEV_WAREHOUSE_XSMALL
  WHEN SYSTEM$STREAM_HAS_DATA('{FQ}.SPIKE_T_STREAM')
  AS CALL {FQ}.SPIKE_T_PROC()""")
    run(f"ALTER TASK {FQ}.SPIKE_T_TASK RESUME")
    run(f"INSERT INTO {FQ}.SPIKE_T_SRC VALUES (1, 'the arrivals table grain is one row per guest per on-park date')")
    print("inserted at", time.strftime("%X"))
elif mode == "check":
    run(f"SELECT AT, WHAT, OUT FROM {FQ}.SPIKE_T_LOG ORDER BY AT")
    run(f"SELECT NAME, STATE, SCHEDULED_TIME, COMPLETED_TIME, ERROR_MESSAGE, RETURN_VALUE FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(TASK_NAME=>'SPIKE_T_TASK')) ORDER BY SCHEDULED_TIME DESC LIMIT 3")
    run(f"SELECT SYSTEM$STREAM_HAS_DATA('{FQ}.SPIKE_T_STREAM')")
    run(f"SELECT CURRENT_TIMESTAMP()")
