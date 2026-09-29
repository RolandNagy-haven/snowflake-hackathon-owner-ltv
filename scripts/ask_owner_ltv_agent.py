"""Ask the Owner LTV Cortex Agent a question over its REST API and print the answer.

Reuses our sf_session (connection_name auth) for the bearer token, so no extra login.
Streams tool calls / status to stderr; prints text, tables and the SQL Analyst ran.

    python scripts/ask_owner_ltv_agent.py "Which park tier has the highest lifetime on-park spend?"
"""
from __future__ import annotations

import json
import sys

import requests

from sf_session import get_session

AGENT = "NEXUS_HACKATHON_DB.OWNER_LTV_SV.OWNER_LTV_AGENT"


def sse_events(resp):
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


def main():
    question = " ".join(sys.argv[1:]) or "How many owner accounts are there, and how many distinct people do they represent?"
    conn = get_session(role="NEXUS_SPIKE", warehouse="NEXUS_HACKATHON_WH").connection
    base = f"https://{conn.host}/api/v2"
    headers = {"Authorization": f'Snowflake Token="{conn.rest.token}"', "Content-Type": "application/json"}

    tid = requests.post(f"{base}/cortex/threads", headers=headers,
                        json={"origin_application": "claude_code"}, timeout=60).json()["thread_id"]
    db, schema, name = AGENT.split(".")
    url = f"{base}/databases/{db}/schemas/{schema}/agents/{name}:run"
    body = {"thread_id": tid, "parent_message_id": 0, "stream": True,
            "messages": [{"role": "user", "content": [{"type": "text", "text": question}]}]}

    print(f"Q: {question}\n", file=sys.stderr, flush=True)
    final = None
    with requests.post(url, headers={**headers, "Accept": "text/event-stream"},
                       json=body, stream=True, timeout=600) as r:
        if r.status_code != 200:
            sys.exit(f"agent HTTP {r.status_code}: {r.text[:2000]}")
        r.encoding = "utf-8"
        for event, payload in sse_events(r):
            try:
                data = json.loads(payload)
            except json.JSONDecodeError:
                continue
            if event == "response":
                final = data
                break
            elif event == "response.status":
                print(f"  .. {data.get('message') or data.get('status')}", file=sys.stderr, flush=True)
            elif event == "response.tool_use":
                print(f"  -> tool {data.get('name')}", file=sys.stderr, flush=True)
            elif event == "error":
                sys.exit(f"agent error: {json.dumps(data)[:2000]}")
    if final is None:
        sys.exit("stream ended without a final 'response' event")

    sqls = []
    for part in final.get("content", []):
        t = part.get("type")
        if t == "text" and part["text"].strip():
            print(part["text"].strip() + "\n")
        elif t == "table":
            rs = part["table"].get("result_set")
            if rs:
                cols = [c["name"] for c in rs["resultSetMetaData"]["rowType"]]
                print("[table] " + " | ".join(cols))
                for row in (rs.get("data") or [])[:30]:
                    print("        " + " | ".join(str(v) for v in row))
                print()
        elif t == "tool_result":
            for c in part["tool_result"].get("content", []):
                sql = (c.get("json") or {}).get("sql")
                if sql:
                    sqls.append(sql)
    if sqls:
        print("## SQL executed")
        for i, sq in enumerate(sqls, 1):
            print(f"-- [{i}]\n{sq.strip()}\n")


if __name__ == "__main__":
    main()
