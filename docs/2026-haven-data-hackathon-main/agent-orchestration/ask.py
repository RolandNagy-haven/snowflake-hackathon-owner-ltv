"""Ask one of the orchestration agents a question and print its tool trace + answer.

    python agent-orchestration/ask.py master   "How many guests arrived last weekend, and how many bookings did we take?"
    python agent-orchestration/ask.py arrivals "..." --save agent-orchestration/runs/x
    python agent-orchestration/ask.py knowledge "RECALL all: anything about snapshots"
    python agent-orchestration/ask.py master "follow-up ..." --thread demo         # continue a conversation
    python agent-orchestration/ask.py --memory                                    # dump AGENT_MEMORY
    python agent-orchestration/ask.py --log 20                                    # last N agent-to-agent calls

Reuses the cortex-agent skill's REST client (EXTERNALBROWSER SSO, server-side threads).
The trace shows the agent's own tool calls; nested sub-agent calls are in AGENT_CALL_LOG (--log).
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

import requests

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / ".claude/skills/cortex-agent"))
import cortex_agent as ca  # noqa: E402

FQ = "HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL"
AGENTS = {
    "master": f"{FQ}.HAVEN_MASTER_AGENT",
    "arrivals": f"{FQ}.ARRIVALS_AGENT",
    "bookings": f"{FQ}.BOOKINGS_AGENT",
    "knowledge": f"{FQ}.KNOWLEDGE_AGENT",
}


def short(x, n=300) -> str:
    s = x if isinstance(x, str) else json.dumps(x)
    s = " ".join(s.split())
    return s if len(s) <= n else s[:n] + " ..."


def trace(resp: dict) -> None:
    for part in resp.get("content", []):
        t = part.get("type")
        if t == "tool_use":
            u = part["tool_use"]
            inp = u.get("input") or {}
            ref = f" [thread_ref={inp['thread_ref']}]" if "thread_ref" in inp else ""
            print(f"  -> {u.get('name')}{ref}: {short(inp.get('sql') or inp.get('command') or inp.get('question') or inp.get('request') or inp, 600)}")
        elif t == "tool_result":
            r = part["tool_result"]
            for c in r.get("content", []):
                body = c.get("text") or (c.get("json") or {}).get("result") or c.get("json")
                if isinstance(body, str) and body.startswith("{"):
                    try:
                        j = json.loads(body)
                        ref = f", thread_ref={j['thread_ref']}" if "thread_ref" in j else ""
                        body = f"[{j.get('elapsed_s')}s{ref}, tools={j.get('tools_used')}] {j.get('error') or j.get('answer')}"
                    except json.JSONDecodeError:
                        pass
                print(f"  <- {r.get('name')} ({r.get('status')}): {short(body, 500)}")


def answer_text(resp: dict) -> str:
    return "\n\n".join(p["text"].strip() for p in resp.get("content", []) if p.get("type") == "text" and p["text"].strip())


def recover(client, thread_id: int, since: float, wait_s: int = 900) -> dict:
    """The run finished (or is finishing) server-side but the stream broke: poll the thread for
    the assistant message written after `since` and rebuild a response from it."""
    print("  !! stream lost; recovering the answer from the thread ...", flush=True)
    deadline = time.time() + wait_s
    while time.time() < deadline:
        r = requests.get(f"{client.base}/cortex/threads/{thread_id}", headers=client.headers,
                         params={"page_size": 10}, timeout=60)
        r.raise_for_status()
        for m in r.json().get("messages", []):
            if m.get("role") != "assistant" or m.get("created_on", 0) < since * 1000:
                continue
            payload = m.get("message_payload")
            payload = json.loads(payload) if isinstance(payload, str) else (payload or {})
            if any(p.get("type") == "text" for p in payload.get("content", [])):
                return {"content": payload["content"], "status": "recovered",
                        "metadata": {"thread_id": thread_id, "assistant_message_id": m["message_id"]}}
        time.sleep(15)
    sys.exit(f"no assistant message appeared in thread {thread_id} within {wait_s}s")


def ask(agent_key: str, question: str, thread: str | None = None, reset: bool = False,
        save: Path | None = None) -> dict:
    agent = AGENTS.get(agent_key, agent_key)
    client = ca.Client()
    state = None if reset else ca.load_thread(thread, agent)
    if state is None:
        state = {"agent": agent, "thread_id": client.new_thread(), "parent_message_id": 0, "turns": 0}
    print(f"\n### {agent_key}: {question}", flush=True)
    t0 = time.time()
    try:
        resp = client.run(agent, question, state["thread_id"], state["parent_message_id"])
    except requests.exceptions.RequestException:
        resp = recover(client, state["thread_id"], t0)
    except SystemExit as e:
        if not str(e).startswith("stream ended"):
            raise
        resp = recover(client, state["thread_id"], t0)
    meta = resp.get("metadata") or {}
    print(f"  ({time.time() - t0:.0f}s, status={resp.get('status')})")
    trace(resp)
    print("\n" + answer_text(resp) + "\n", flush=True)
    if save:
        save.mkdir(parents=True, exist_ok=True)
        (save / "response.json").write_text(json.dumps(resp, indent=1))
        (save / "answer.md").write_text(f"# {agent_key}: {question}\n\n{answer_text(resp)}\n")
    if thread and meta.get("assistant_message_id"):
        state.update(parent_message_id=meta["assistant_message_id"], turns=state["turns"] + 1, last_question=question)
        ca.save_thread(thread, state)
    return resp


def show(sql: str) -> None:
    import pandas as pd
    df = ca.get_or_create_session().sql(sql).to_pandas()
    with pd.option_context("display.max_colwidth", 160, "display.width", 250):
        print(df.to_string(index=False))


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("agent", nargs="?", help=f"one of {list(AGENTS)} or DB.SCHEMA.AGENT")
    p.add_argument("question", nargs="?")
    p.add_argument("--thread")
    p.add_argument("--reset", action="store_true")
    p.add_argument("--save")
    p.add_argument("--memory", action="store_true", help="print active AGENT_MEMORY notes")
    p.add_argument("--log", type=int, metavar="N", help="print the last N rows of AGENT_CALL_LOG")
    a = p.parse_args()
    if a.memory:
        show(f"SELECT LEFT(MEMORY_ID, 8) ID, TO_VARCHAR(CREATED_AT, 'MM-DD HH24:MI') AT, DOMAIN, SOURCE_AGENT, TOPIC, OBSERVATION "
             f"FROM {FQ}.AGENT_MEMORY WHERE IS_ACTIVE ORDER BY CREATED_AT")
    if a.log:
        show(f"SELECT TO_VARCHAR(CALLED_AT, 'MM-DD HH24:MI:SS') AT, SPLIT_PART(TARGET_AGENT, '.', 3) TARGET, ELAPSED_S, TO_VARCHAR(THREAD_ID) THREAD_ID, TO_VARCHAR(PARENT_MESSAGE_ID) PARENT, "
             f"LEFT(REQUEST, 110) REQUEST, LEFT(COALESCE(ERROR, ANSWER), 140) ANSWER "
             f"FROM {FQ}.AGENT_CALL_LOG ORDER BY CALLED_AT DESC LIMIT {a.log}")
    if a.memory or a.log:
        return
    if not (a.agent and a.question):
        p.error("agent and question are required")
    ask(a.agent, a.question, a.thread, a.reset, Path(a.save) if a.save else None)


if __name__ == "__main__":
    main()
