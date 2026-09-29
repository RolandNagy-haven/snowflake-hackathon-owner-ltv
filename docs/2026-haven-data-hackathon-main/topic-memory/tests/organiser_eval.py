"""Organiser quality eval on a scratch topic (tests/memtest.yaml).

    python topic-memory/tests/organiser_eval.py            # deploy memtest, run fixtures, score, purge
    python topic-memory/tests/organiser_eval.py --review   # ... and also run the organiser agent review
    python topic-memory/tests/organiser_eval.py --keep     # don't purge (inspect with memctl status memtest)

Fixtures live in organiser_fixtures.yaml: seed items (expected to be activated), then test items, each with the
set of acceptable organiser decisions and, where relevant, the seed it should point at.
"""
import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

import yaml

HERE = Path(__file__).resolve().parent
TM = HERE.parent
sys.path.insert(0, str(TM))
import memctl  # noqa: E402

CONFIG = HERE / "memtest.yaml"


def save(sess, ctx, item):
    fq, n = ctx["fq"], ctx["n"]
    args = {"title": item["title"], "body": item["body"], "category": item.get("category", ""),
            "agent_type": item.get("agent_type", "eval_agent"), "tables": item.get("tables", "HAVEN_STORE.ARRIVAL.FCT_PARK_ARRIVAL"),
            "confidence": item.get("confidence", "verified"), "tags": item.get("tags", ""),
            "supersedes": item.get("supersedes", ""), "as_of_date": item.get("as_of_date", ""),
            "evidence_sql": item.get("evidence_sql", "")}
    named = ", ".join(f"{k} => ?" for k in args)  # by name: the argument order follows the topic config
    out = json.loads(sess.sql(f"CALL {fq}.{n['save']}({named})", params=list(args.values())).collect()[0][0])
    if not out.get("ok"):
        raise SystemExit(f"save failed for {item['key']}: {out}")
    return out["id"]


def organise(sess, ctx):
    t0 = time.time()
    out = json.loads(sess.call(f"{ctx['fq']}.MEM_ORGANISE", ctx["t"]["id"], "manual"))
    print(f"   organiser: {out.get('processed')} items in {time.time() - t0:.0f}s, errors={out.get('errors')}")
    return {a["item"]: a for a in out.get("actions", [])}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--review", action="store_true")
    ap.add_argument("--keep", action="store_true")
    a = ap.parse_args()
    fx = yaml.safe_load((HERE / "organiser_fixtures.yaml").read_text())
    ctx = memctl.build_context(memctl.load_config(CONFIG))
    py = sys.executable
    subprocess.run([py, str(TM / "memctl.py"), "teardown", str(CONFIG), "--purge"], check=True, capture_output=True)
    subprocess.run([py, str(TM / "memctl.py"), "deploy", str(CONFIG), "--skip-core"], check=True, capture_output=True)
    print(f"deployed scratch topic {ctx['t']['id']}")
    sess = memctl.session()

    ids = {}
    print("seeding:")
    for item in fx["seed"]:
        ids[item["key"]] = save(sess, ctx, item)
    seed_actions = organise(sess, ctx)
    results = []
    for item in fx["seed"]:
        act = seed_actions.get(ids[item["key"]], {})
        results.append((item["key"], "activate", {"activate"}, act.get("decision"), None, None, act.get("reason")))

    print("test items:")
    for item in fx["tests"]:
        if item.get("supersedes"):
            item["supersedes"] = ids[item["supersedes"]]
        ids[item["key"]] = save(sess, ctx, item)
    actions = organise(sess, ctx)
    for item in fx["tests"]:
        act = actions.get(ids[item["key"]], {})
        want_target = ids.get(item.get("target")) if item.get("target") else None
        reason = act.get("reason")
        if item.get("expect_category"):  # the organiser must replace 'uncategorised'
            cat = sess.sql(f"SELECT CATEGORY FROM {ctx['fq']}.MEM_ITEM WHERE ITEM_ID = ?", params=[ids[item["key"]]]).collect()[0][0]
            if cat == "uncategorised":
                act = {**act, "decision": f"{act.get('decision')} (still uncategorised)"}
            reason = f"[category -> {cat}] {reason}"
        results.append((item["key"], item["expect"][0], set(item["expect"]), act.get("decision"), want_target,
                        act.get("target"), reason))

    ok = 0
    print(f"\n{'item':22s} {'decision':10s} {'expected':28s} target  result")
    for key, _, allowed, got, want_t, got_t, reason in results:
        good = got in allowed and (want_t is None or got not in ("duplicate", "merge", "supersede") or got_t == want_t)
        ok += good
        tgt = "" if want_t is None else ("ok" if got_t == want_t else f"{got_t}!={want_t}")
        print(f"{key:22s} {str(got):10s} {'|'.join(sorted(allowed)):28s} {tgt:7s} {'PASS' if good else 'FAIL'}  {(reason or '')[:110]}")
    print(f"\nscore: {ok}/{len(results)}")

    if a.review:
        print("\nrunning organiser agent review (MEM_REVIEW)...")
        t0 = time.time()
        out = json.loads(sess.call(f"{ctx['fq']}.MEM_REVIEW", ctx["t"]["id"]))
        print(f"   {time.time() - t0:.0f}s, tools used: {out.get('tools_used')}, error: {out.get('error')}")
        print("   agent answer:\n" + "\n".join("     " + line for line in (out.get("answer") or "").splitlines()))
        print("\nindex after review:\n" + sess.call(f"{ctx['fq']}.{ctx['n']['index']}", "", "eval").split("## Overview")[-1][:3000])

    if not a.keep:
        subprocess.run([py, str(TM / "memctl.py"), "teardown", str(CONFIG), "--purge"], check=True, capture_output=True)
        print("\npurged scratch topic")
    sys.exit(0 if ok == len(results) else 1)


if __name__ == "__main__":
    main()
