"""Ask Snowflake Cortex Analyst a question over a semantic view, optionally run the SQL.

Auth reuses the snowflake-query skill's EXTERNALBROWSER session (no PAT needed): the
REST call is authorised with that session's token.

    python .claude/skills/cortex-analyst/cortex_analyst.py "revenue by category last 4 weeks"
    python .claude/skills/cortex-analyst/cortex_analyst.py "..." --run --out /tmp/x.parquet
    python .claude/skills/cortex-analyst/cortex_analyst.py "now split by weekend" --thread fnb --run
    python .claude/skills/cortex-analyst/cortex_analyst.py --describe

Exit codes: 0 ok, 2 Analyst returned no SQL (ambiguous question -> see suggestions),
1 HTTP / SQL error.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

import requests

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "snowflake-query"))
from snowflake_session import get_or_create_session  # noqa: E402

DEFAULT_VIEW = "HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.FNB_RETAIL_SV"
THREAD_DIR = HERE / ".threads"


def _thread_path(name: str) -> Path:
    return THREAD_DIR / f"{name}.json"


def load_thread(name: str | None) -> list[dict]:
    if not name or not _thread_path(name).exists():
        return []
    return json.loads(_thread_path(name).read_text())


def save_thread(name: str, messages: list[dict]) -> None:
    THREAD_DIR.mkdir(exist_ok=True)
    _thread_path(name).write_text(json.dumps(messages, indent=1))


def ask(session, question: str, view: str, history: list[dict]) -> dict:
    conn = session._conn._conn
    messages = history + [{"role": "user", "content": [{"type": "text", "text": question}]}]
    resp = requests.post(
        f"https://{conn.host}/api/v2/cortex/analyst/message",
        headers={
            "Authorization": f'Snowflake Token="{conn.rest.token}"',
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
        json={"messages": messages, "semantic_view": view, "stream": False},
        timeout=180,
    )
    if resp.status_code != 200:
        sys.exit(f"Cortex Analyst HTTP {resp.status_code}: {resp.text[:2000]}")
    body = resp.json()
    body["_messages"] = messages
    return body


def describe(session, view: str) -> None:
    for kind in ("METRICS", "DIMENSIONS"):
        rows = session.sql(f"show semantic {kind} in {view}").collect()
        print(f"\n## {kind.lower()}")
        for r in rows:
            d = r.as_dict()
            syn = d.get("synonyms") or ""
            print(f"  {d['table_name'].lower()}.{d['name'].lower():32s} {syn}")


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("question", nargs="?", help="natural-language question")
    p.add_argument("--view", default=DEFAULT_VIEW, help=f"fully qualified semantic view (default {DEFAULT_VIEW})")
    p.add_argument("--run", action="store_true", help="execute the generated SQL and print the result")
    p.add_argument("--out", help="with --run: save the result (.parquet or .csv)")
    p.add_argument("--max-rows", type=int, default=50, help="rows to print with --run (default 50)")
    p.add_argument("--thread", help="name of a multi-turn conversation; history kept in .threads/<name>.json")
    p.add_argument("--reset", action="store_true", help="with --thread: start the conversation over")
    p.add_argument("--raw", action="store_true", help="also dump the full Analyst JSON response")
    p.add_argument("--describe", action="store_true", help="list the view's metrics and dimensions and exit")
    a = p.parse_args()

    session = get_or_create_session()

    if a.describe:
        describe(session, a.view)
        return
    if not a.question:
        p.error("question is required unless --describe")

    history = [] if a.reset else load_thread(a.thread)
    t0 = time.time()
    body = ask(session, a.question, a.view, history)
    elapsed = time.time() - t0

    content = body.get("message", {}).get("content", [])
    sql = None
    for part in content:
        if part["type"] == "text":
            print(f"## interpretation\n{part['text']}\n")
        elif part["type"] == "sql":
            sql = part["statement"]
            vq = (part.get("confidence") or {}).get("verified_query_used")
            print(f"## sql  (verified query used: {vq['name'] if vq else 'none'})\n{sql}\n")
        elif part["type"] == "suggestions":
            print("## suggestions (question was ambiguous)")
            for s in part["suggestions"]:
                print(f"  - {s}")
            print()

    for w in body.get("warnings") or []:
        print(f"## WARNING\n{w.get('message')}\n")
    meta = body.get("response_metadata") or {}
    print(f"## meta\nrequest_id={body.get('request_id')}  models={meta.get('model_names')}  "
          f"category={meta.get('question_category')}  analyst={elapsed:.1f}s\n")
    if a.raw:
        print("## raw\n" + json.dumps({k: v for k, v in body.items() if k != "_messages"}, indent=1))

    if a.thread:
        save_thread(a.thread, body["_messages"] + [body["message"]])

    if sql is None:
        sys.exit(2)
    if not a.run:
        return

    t0 = time.time()
    try:
        df = session.sql(sql.strip().rstrip(";")).to_pandas()
    except Exception as e:  # surface Snowflake's message, not a stack trace
        sys.exit(f"SQL failed: {e}")
    print(f"## result  ({len(df)} rows, {time.time() - t0:.1f}s)")
    print(df.head(a.max_rows).to_string(index=False))
    if len(df) > a.max_rows:
        print(f"... {len(df) - a.max_rows} more rows")
    if a.out:
        out = Path(a.out)
        out.parent.mkdir(parents=True, exist_ok=True)
        df.to_parquet(out, index=False) if out.suffix == ".parquet" else df.to_csv(out, index=False)
        print(f"\nsaved -> {out}")


if __name__ == "__main__":
    main()
