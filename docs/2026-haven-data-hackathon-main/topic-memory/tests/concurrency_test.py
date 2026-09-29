"""Parallel saves over MCP into the scratch topic (run organiser_eval.py --keep first so memtest is deployed).

    python topic-memory/tests/concurrency_test.py [n_parallel]
Checks: every save succeeds, ids are unique, each item has exactly one history row; prints latency percentiles.
"""
import json
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import memctl  # noqa: E402
from mcp_http import McpClient  # noqa: E402

ctx = memctl.build_context(memctl.load_config(HERE / "memtest.yaml"))
tn = {k: v["name"] for k, v in ctx["t"]["tools"].items()}
N = int(sys.argv[1]) if len(sys.argv) > 1 else 8


def one(i):
    c = McpClient(ctx["t"]["mcp_url"])
    text, err, dt = c.call(tn["save"], {
        "title": f"Concurrency test item {i}", "category": "open_question", "agent_type": f"agent_{i % 3}",
        "body": f"Concurrency test body number {i}: parallel writers must each get a unique id.",
        "tables": "TEST.CONCURRENCY.T", "confidence": "hypothesis"})
    return json.loads(text) if not err else {"error": text}, dt


with ThreadPoolExecutor(N) as ex:
    res = list(ex.map(one, range(N)))
ids = [r.get("id") for r, _ in res]
lat = sorted(dt for _, dt in res)
sess = memctl.session()
hist = sess.sql(f"SELECT ITEM_ID, COUNT(*) N FROM {ctx['fq']}.MEM_ITEM_HISTORY WHERE TOPIC_ID = 'memtest' "
                f"AND ITEM_ID IN ({', '.join(repr(i) for i in ids if i)}) GROUP BY 1").collect()
print(f"{N} parallel saves: ok={sum(bool(r.get('ok')) for r, _ in res)}, unique ids={len(set(ids))}, "
      f"history rows={sorted(r['N'] for r in hist)}")
print(f"latency s: min {lat[0]}, p50 {lat[len(lat) // 2]}, max {lat[-1]}")
