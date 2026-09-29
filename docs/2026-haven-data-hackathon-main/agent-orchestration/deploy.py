"""Deploy the agent-orchestration objects to HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.

    python agent-orchestration/deploy.py                                   # all sql/0*.sql in order
    python agent-orchestration/deploy.py --specialist-mode threaded        # ... with threaded specialists
    python agent-orchestration/deploy.py 06 --specialist-mode stateless    # switch the master back
    python agent-orchestration/deploy.py 04_arrivals_agent                 # one or more scripts (prefix match)
    python agent-orchestration/deploy.py 06 --specialist-mode threaded --dry-run   # print rendered SQL only
    python agent-orchestration/deploy.py 99_teardown                       # remove agents + procedures

--specialist-mode (how HAVEN_MASTER_AGENT talks to ARRIVALS_AGENT / BOOKINGS_AGENT):
    stateless  single-pass request -> response; the master restates all context in every question
    threaded   each specialist keeps a conversation thread (thread_ref); the master continues it
               only for follow-ups that build on that specialist's earlier answer
When omitted, the mode currently deployed (recorded in the master agent's COMMENT) is kept;
stateless if there is none.

Scripts are small templates: {{SPECIALIST_MODE}} is substituted and lines between
`#@<mode>` and `#@end` are kept only for that mode. Each script is run with the connector's
execute_string, which keeps $$ ... $$ bodies intact. After deploying it prints each agent's
tools as a smoke check.
"""
import argparse
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / ".claude/skills/snowflake-query"))
from snowflake_session import get_or_create_session  # noqa: E402

FQ = "HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL"
MODES = ("stateless", "threaded")
AGENTS = ("HAVEN_MASTER_AGENT", "ARRIVALS_AGENT", "BOOKINGS_AGENT", "KNOWLEDGE_AGENT")


def scripts(args: list[str]) -> list[Path]:
    all_files = sorted((HERE / "sql").glob("*.sql"))
    if not args:
        return [f for f in all_files if not f.name.startswith("99_")]
    picked = [f for a in args for f in all_files if f.name.startswith(a)]
    if len(picked) < len(args):
        sys.exit(f"no script matches one of {args}; have {[f.name for f in all_files]}")
    return picked


def render(sql: str, mode: str, name: str) -> str:
    out, block = [], None
    for n, line in enumerate(sql.splitlines(), 1):
        tag = re.fullmatch(r"\s*#@(\w+)\s*", line)
        if tag:
            t = tag.group(1)
            if t == "end":
                if block is None:
                    sys.exit(f"{name}:{n}: #@end without an open block")
                block = None
            elif t in MODES:
                if block is not None:
                    sys.exit(f"{name}:{n}: nested #@{t} block")
                block = t
            else:
                sys.exit(f"{name}:{n}: unknown template tag #@{t}")
            continue
        if block is None or block == mode:
            out.append(line)
    if block is not None:
        sys.exit(f"{name}: unclosed #@{block} block")
    text = "\n".join(out).replace("{{SPECIALIST_MODE}}", mode) + "\n"
    if "{{" in text:
        sys.exit(f"{name}: unresolved placeholder {re.search(r'{{.*?}}', text).group(0)}")
    return text


def deployed_mode(session) -> str | None:
    rows = session.sql(f"SHOW AGENTS LIKE 'HAVEN_MASTER_AGENT' IN SCHEMA {FQ}").collect()
    m = re.search(r"specialist_mode=(\w+)", (rows[0]["comment"] or "") if rows else "")
    return m.group(1) if m else None


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("scripts", nargs="*", help="script name prefixes (default: all 0*.sql)")
    p.add_argument("--specialist-mode", choices=MODES, help="default: keep the deployed mode (else stateless)")
    p.add_argument("--dry-run", action="store_true", help="print the rendered SQL, deploy nothing")
    a = p.parse_args()

    files = scripts(a.scripts)
    session = None if (a.dry_run and a.specialist_mode) else \
        get_or_create_session(database="HAVEN_DATA_SCIENCE_DEV", schema="PETERZENTAI_LOCAL")
    mode = a.specialist_mode or deployed_mode(session) or "stateless"
    print(f"specialist mode: {mode}{'' if a.specialist_mode else ' (kept from deployment / default)'}")

    rendered = [(f, render(f.read_text(), mode, f.name)) for f in files]
    if a.dry_run:
        for f, sql in rendered:
            print(f"\n-- ==== {f.name} ({mode}) ====\n{sql}")
        return

    conn = session._conn._conn
    for f, sql in rendered:
        print(f"== {f.name}")
        for cur in conn.execute_string(sql, remove_comments=False):
            print(f"   {cur.sfqid}  {cur.fetchone()}")
    for row in session.sql(f"SHOW AGENTS IN SCHEMA {FQ}").collect():
        if row["name"] not in AGENTS:
            continue
        spec = json.loads(session.sql(f"DESCRIBE AGENT {FQ}.{row['name']}").collect()[0]["agent_spec"])
        tools = [t["tool_spec"]["type"] + ":" + t["tool_spec"]["name"] for t in spec.get("tools", [])]
        procs = sorted({r["identifier"].split(".")[-1] for r in spec.get("tool_resources", {}).values()
                        if isinstance(r, dict) and r.get("type") == "procedure"})
        print(f"   {row['name']:20s} tools={tools}  procs={procs}")
    print(f"   master specialist mode now: {deployed_mode(session)}")


if __name__ == "__main__":
    main()
