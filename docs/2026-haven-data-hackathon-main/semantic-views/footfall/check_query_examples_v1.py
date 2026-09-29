"""Runs every query in query_examples_v1.sql and checks old vs new per scenario.

    python semantic-views/footfall/check_query_examples_v1.py [-v]

Blocks are marked "-- [S<n>.<tag>]" in the .sql file:
  [S<n>.old]         the reference answer from DAILY_FOOTFALL_FACTS_V3
  any other tag      must return the same rows as old (compared by position, numbers
                     with a small tolerance, column names ignored)
  tag with "wrong"   must return DIFFERENT rows (a documented pitfall)
  tag with "demo"    only has to run
Exit code 1 on any mismatch or error.  -v prints every result.
"""
import datetime as dt
import math
import re
import sys
from pathlib import Path

from sf import session

SQL_FILE = Path(__file__).with_name("query_examples_v1.sql")
VERBOSE = "-v" in sys.argv


def blocks():
    out, cur = [], None
    for line in SQL_FILE.read_text().splitlines():
        m = re.match(r"--\s*\[(S\d+)\.(\w+)\]", line)
        if m:
            cur = [m.group(1), m.group(2), []]
            out.append(cur)
        elif cur is not None and not cur[2] and (not line.strip() or line.startswith("--")):
            continue
        elif cur is not None:
            cur[2].append(line)
            if line.rstrip().endswith(";"):
                cur = None
    return [(s, t, "\n".join(q).rstrip().rstrip(";")) for s, t, q in out]


def norm(v):
    # V3's ON_PARK_DATE is a TIMESTAMP_NTZ at midnight; the semantic view returns a DATE
    if isinstance(v, dt.datetime) and v.time() == dt.time(0):
        return v.date()
    return v


def same(a, b):
    if len(a) != len(b):
        return False
    for ra, rb in zip(a, b):
        if len(ra) != len(rb):
            return False
        for x, y in zip(map(norm, ra), map(norm, rb)):
            if isinstance(x, (int, float)) or isinstance(y, (int, float)):
                try:
                    if not math.isclose(float(x), float(y), rel_tol=1e-9, abs_tol=1e-6):
                        return False
                except (TypeError, ValueError):
                    return False
            elif str(x) != str(y):
                return False
    return True


s = session()
results, bad = {}, 0
scenarios = {}
for sc, tag, sql in blocks():
    scenarios.setdefault(sc, []).append((tag, sql))

for sc, items in scenarios.items():
    ref = None
    line = []
    for tag, sql in items:
        try:
            rows = [tuple(r) for r in s.sql(sql).collect()]
        except Exception as e:  # noqa: BLE001
            bad += 1
            line.append(f"{tag}=ERROR")
            print(f"{sc}.{tag} ERROR: {str(e).splitlines()[0][:300]}")
            continue
        if VERBOSE:
            print(f"  {sc}.{tag}: {rows}")
        if tag == "old":
            ref = rows
            line.append(f"old({len(rows)} rows)")
        elif "demo" in tag:
            line.append(f"{tag}=ran")
        elif "wrong" in tag:
            ok = ref is not None and not same(ref, rows)
            bad += not ok
            line.append(f"{tag}={'differs (expected)' if ok else 'SAME - pitfall not shown'}")
        else:
            ok = ref is not None and same(ref, rows)
            bad += not ok
            line.append(f"{tag}={'match' if ok else 'MISMATCH'}")
    print(f"{sc}: " + "  ".join(line))

print("\nALL SCENARIOS OK" if bad == 0 else f"\n{bad} PROBLEM(S)")
sys.exit(0 if bad == 0 else 1)
