"""Deploy the sv-to-agent sample to NEXUS_HACKATHON_DB.PZ_CORTEX_SPIKE.

    python sv-to-agent/deploy.py               # all sql/0*.sql in order
    python sv-to-agent/deploy.py 03 04         # scripts by prefix
    python sv-to-agent/deploy.py 99_teardown   # drop everything
    python sv-to-agent/deploy.py 01 --dry-run  # print the rendered SQL only

Scripts are templates: {{DB}}, {{SCHEMA}} and {{WH}} are substituted, and a line
`--@include <path>` is replaced by that file (relative to the script), retargeted from
HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL to {{DB}}.{{SCHEMA}}. Everything runs as the
schema owner role NEXUS_SPIKE with secondary roles off, so objects are owned by NEXUS_SPIKE
and only work if that role alone can read the sources.
"""
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / ".claude/skills/snowflake-query"))
from snowflake_session import get_or_create_session  # noqa: E402

DB, SCHEMA, WH, ROLE = "NEXUS_HACKATHON_DB", "PZ_CORTEX_SPIKE", "NEXUS_HACKATHON_WH", "NEXUS_SPIKE"
SOURCE_FQ = "HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL"


def scripts(args: list[str]) -> list[Path]:
    all_files = sorted((HERE / "sql").glob("*.sql"))
    if not args:
        return [f for f in all_files if not f.name.startswith("99_")]
    picked = [f for a in args for f in all_files if f.name.startswith(a)]
    if len(picked) < len(args):
        sys.exit(f"no script matches one of {args}; have {[f.name for f in all_files]}")
    return picked


def include(m: re.Match, base: Path) -> str:
    text = (base / m.group(1).strip()).resolve().read_text()
    text = re.sub(re.escape(SOURCE_FQ), "{{DB}}.{{SCHEMA}}", text, flags=re.I)
    text = re.sub(r"(?im)^use database \w+;", "use database {{DB}};", text)
    return re.sub(r"(?im)^use schema \w+;", "use schema {{SCHEMA}};", text)


def render(f: Path) -> str:
    text = re.sub(r"(?m)^--@include (.+)$", lambda m: include(m, f.parent), f.read_text())
    text = text.replace("{{DB}}", DB).replace("{{SCHEMA}}", SCHEMA).replace("{{WH}}", WH)
    if "{{" in text:
        sys.exit(f"{f.name}: unresolved placeholder {re.search(r'{{.*?}}', text).group(0)}")
    if re.search(re.escape(SOURCE_FQ), text, flags=re.I):
        sys.exit(f"{f.name}: still references {SOURCE_FQ}")
    return text


def main() -> None:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    files = scripts(args)
    if "--dry-run" in sys.argv:
        for f in files:
            print(f"-- ===== {f.name}\n{render(f)}")
        return
    session = get_or_create_session(role=ROLE)
    for stmt in ("USE SECONDARY ROLES NONE", f"USE WAREHOUSE {WH}", f"USE SCHEMA {DB}.{SCHEMA}"):
        session.sql(stmt).collect()
    conn = session._conn._conn
    for f in files:
        print(f"-- {f.name}")
        # comments only in the included semantic-view file, as semantic-views/footfall/deploy.py does
        for cur in conn.execute_string(render(f), remove_comments="--@include" in f.read_text()):
            print("  ", cur.sfqid, str(cur.fetchone())[:120])
    rows = session.sql(f"SHOW AGENTS IN SCHEMA {DB}.{SCHEMA}").collect()
    print("agents:", [r["name"] for r in rows])
    rows = session.sql(f"SHOW SEMANTIC VIEWS IN SCHEMA {DB}.{SCHEMA}").collect()
    print("semantic views:", [r["name"] for r in rows])


if __name__ == "__main__":
    main()
