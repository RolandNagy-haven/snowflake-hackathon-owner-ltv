"""Talk to a Snowflake Cortex Agent (default FNB_RETAIL_AGENT) over its REST API.

Auth reuses the snowflake-query skill's EXTERNALBROWSER session (no PAT needed).
Conversations are server-side threads; --thread NAME remembers the thread id and the
last assistant message id locally so follow-ups continue the same conversation.

    python .claude/skills/cortex-agent/cortex_agent.py "revenue per open venue-day by category, Aug 2026"
    python .claude/skills/cortex-agent/cortex_agent.py "..." --thread fnb --reset
    python .claude/skills/cortex-agent/cortex_agent.py "how does that compare with 2025?" --thread fnb
    python .claude/skills/cortex-agent/cortex_agent.py "..." --show-sql --save sandbox/tmp/agent_run
    python .claude/skills/cortex-agent/cortex_agent.py --threads

Progress (tool calls, status) streams to stderr; the answer goes to stdout.
Exit codes: 0 ok, 1 HTTP / agent error.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

import pandas as pd
import requests

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "snowflake-query"))
from snowflake_session import get_or_create_session  # noqa: E402

DEFAULT_AGENT = "HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FNB_RETAIL_AGENT"
THREAD_DIR = HERE / ".threads"


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


# ---------------------------------------------------------------- thread bookkeeping
def thread_file(name: str) -> Path:
    return THREAD_DIR / f"{name}.json"


def load_thread(name: str | None, agent: str) -> dict | None:
    if not name or not thread_file(name).exists():
        return None
    state = json.loads(thread_file(name).read_text())
    if state.get("agent") != agent:
        sys.exit(f"thread '{name}' belongs to {state.get('agent')}; use --reset or another name")
    return state


def save_thread(name: str, state: dict) -> None:
    THREAD_DIR.mkdir(exist_ok=True)
    thread_file(name).write_text(json.dumps(state, indent=1))


def list_threads() -> None:
    files = sorted(THREAD_DIR.glob("*.json")) if THREAD_DIR.exists() else []
    if not files:
        print("no saved threads")
    for f in files:
        s = json.loads(f.read_text())
        print(f"{f.stem:20s} turns={s.get('turns', 0):<3d} thread_id={s['thread_id']}  last: {s.get('last_question', '')[:70]}")


# ---------------------------------------------------------------- REST calls
def sse_events(resp: requests.Response):
    """Yield (event, data) per server-sent event. Per the SSE spec an event may carry
    several `data:` lines (joined with newlines) and ends at a blank line."""
    event, data = None, []
    for raw in resp.iter_lines(decode_unicode=True):
        if raw is None:
            continue
        if raw == "":
            if data:
                yield event, "\n".join(data)
            event, data = None, []
        elif raw.startswith("event:"):
            event = raw[6:].strip()
        elif raw.startswith("data:"):
            data.append(raw[5:].lstrip(" "))
    if data:
        yield event, "\n".join(data)


class Client:
    def __init__(self) -> None:
        conn = get_or_create_session()._conn._conn
        self.base = f"https://{conn.host}/api/v2"
        self.headers = {
            "Authorization": f'Snowflake Token="{conn.rest.token}"',
            "Content-Type": "application/json",
        }

    def new_thread(self) -> int:
        r = requests.post(f"{self.base}/cortex/threads", headers=self.headers,
                          json={"origin_application": "claude_code"}, timeout=60)
        if r.status_code != 200:
            sys.exit(f"create thread HTTP {r.status_code}: {r.text[:1000]}")
        return r.json()["thread_id"]

    def run(self, agent: str, question: str, thread_id: int, parent_id: int) -> dict:
        db, schema, name = agent.split(".")
        url = f"{self.base}/databases/{db}/schemas/{schema}/agents/{name}:run"
        body = {
            "thread_id": thread_id,
            "parent_message_id": parent_id,
            "stream": True,
            "messages": [{"role": "user", "content": [{"type": "text", "text": question}]}],
        }
        headers = {**self.headers, "Accept": "text/event-stream"}
        final = None
        with requests.post(url, headers=headers, json=body, stream=True, timeout=600) as r:
            if r.status_code != 200:
                sys.exit(f"agent HTTP {r.status_code}: {r.text[:2000]}")
            r.encoding = "utf-8"  # the SSE stream declares no charset; requests would assume latin-1
            for event, payload in sse_events(r):
                try:
                    data = json.loads(payload)
                except json.JSONDecodeError:
                    continue  # e.g. a bare [DONE] marker
                if event == "response":
                    final = data
                    break  # final event; the server may keep the connection open afterwards
                elif event == "response.status":
                    log(f"  .. {data.get('message') or data.get('status')}")
                elif event == "response.tool_use":
                    log(f"  -> tool {data.get('name')}")
                elif event == "error":
                    sys.exit(f"agent error: {json.dumps(data)[:2000]}")
        if final is None:
            sys.exit("stream ended without a final 'response' event")
        return final


# ---------------------------------------------------------------- rendering
def table_df(result_set: dict) -> pd.DataFrame:
    cols = [c["name"] for c in result_set["resultSetMetaData"]["rowType"]]
    df = pd.DataFrame(result_set.get("data") or [], columns=cols)
    for c in df.columns:  # values arrive as strings
        conv = pd.to_numeric(df[c], errors="coerce")
        if conv.notna().sum() == df[c].notna().sum():
            df[c] = conv
    return df


def render(resp: dict, show_sql: bool, save: Path | None, max_rows: int) -> None:
    n_tab = n_chart = 0
    sqls = []
    mcp_results = {}  # MCP run_sql results by query_id; agent tables built from them only reference the id
    for part in resp.get("content", []):
        for c in part.get("tool_result", {}).get("content", []) if part.get("type") == "tool_result" else []:
            try:
                rs = json.loads((c.get("json") or {}).get("result") or "")
                mcp_results[rs["query_id"]] = rs["result_set"]
            except (ValueError, TypeError, KeyError):
                pass
    for part in resp.get("content", []):
        t = part.get("type")
        if t == "text" and part["text"].strip():
            print(part["text"].strip() + "\n")
        elif t == "tool_use" and part["tool_use"].get("type") == "server_mcp" and (part["tool_use"].get("input") or {}).get("sql"):
            sqls.append(("mcp " + part["tool_use"]["name"], part["tool_use"]["input"]["sql"]))
        elif t == "tool_result":
            status = part["tool_result"].get("status", "?")
            for c in part["tool_result"].get("content", []):
                sql = (c.get("json") or {}).get("sql")
                if sql:
                    sqls.append((status, sql))
        elif t == "table":
            n_tab += 1
            rs = part["table"].get("result_set") or mcp_results.get(part["table"].get("tool_use_id"))
            if rs is None:
                print(f"[table {n_tab}: no rows found]\n{json.dumps(part['table'], indent=1)[:2000]}\n")
                continue
            df = table_df(rs)
            print(f"[table {n_tab}: {len(df)} rows]")
            print(df.head(max_rows).to_string(index=False) + "\n")
            if save:
                df.to_parquet(save / f"table_{n_tab}.parquet", index=False)
        elif t == "chart":
            n_chart += 1
            if save:
                spec = part["chart"].get("chart_spec")
                (save / f"chart_{n_chart}.vl.json").write_text(spec if isinstance(spec, str) else json.dumps(spec))
            print(f"[chart {n_chart}{' saved' if save else ''}]\n")
        elif t == "suggested_queries":
            print("Suggested follow-ups:")
            for q in part.get("suggested_queries", []):
                print(f"  - {q.get('query')}")
            print()
    if show_sql and sqls:
        print("## SQL executed")
        for i, (status, s) in enumerate(sqls, 1):
            print(f"-- [{i}] {status}\n{s.strip()}\n")
    if save:
        (save / "response.json").write_text(json.dumps(resp, indent=1))
        if sqls:
            (save / "queries.sql").write_text("\n\n".join(f"-- [{i}] {st}\n{s.strip()}" for i, (st, s) in enumerate(sqls, 1)) + "\n")
        print(f"saved -> {save}/")


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("question", nargs="?")
    p.add_argument("--agent", default=DEFAULT_AGENT, help=f"DB.SCHEMA.AGENT (default {DEFAULT_AGENT})")
    p.add_argument("--thread", help="named conversation to continue (kept in .threads/<name>.json)")
    p.add_argument("--reset", action="store_true", help="with --thread: start a fresh server-side thread")
    p.add_argument("--show-sql", action="store_true", help="print every SQL statement the agent ran")
    p.add_argument("--save", help="directory for response.json, queries.sql, table_N.parquet, chart_N.vl.json")
    p.add_argument("--max-rows", type=int, default=30)
    p.add_argument("--threads", action="store_true", help="list saved threads and exit")
    a = p.parse_args()

    if a.threads:
        list_threads()
        return
    if not a.question:
        p.error("question is required")

    client = Client()
    state = None if a.reset else load_thread(a.thread, a.agent)
    if state is None:
        state = {"agent": a.agent, "thread_id": client.new_thread(), "parent_message_id": 0, "turns": 0}

    log(f"agent {a.agent}  thread {state['thread_id']}  turn {state['turns'] + 1}")
    t0 = time.time()
    resp = client.run(a.agent, a.question, state["thread_id"], state["parent_message_id"])
    meta = resp.get("metadata") or {}
    models = sorted({u.get("model_name") for u in (meta.get("usage") or {}).get("tokens_consumed", []) if u.get("model_name")})
    log(f"  done in {time.time() - t0:.1f}s  status={resp.get('status')}  models={models}\n")

    save = Path(a.save) if a.save else None
    if save:
        save.mkdir(parents=True, exist_ok=True)
    render(resp, a.show_sql, save, a.max_rows)

    if a.thread and meta.get("assistant_message_id"):
        state.update(parent_message_id=meta["assistant_message_id"], turns=state["turns"] + 1,
                     last_question=a.question)
        save_thread(a.thread, state)
    if resp.get("status") not in (None, "completed"):
        sys.exit(1)


if __name__ == "__main__":
    main()
