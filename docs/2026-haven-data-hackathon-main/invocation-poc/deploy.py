"""Deploy invocation-poc objects to HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.

    python invocation-poc/deploy.py               # all sql/0*.sql in order
    python invocation-poc/deploy.py 02            # scripts by prefix
    python invocation-poc/deploy.py 99_teardown   # drop everything
"""
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / ".claude/skills/snowflake-query"))
from snowflake_session import get_or_create_session  # noqa: E402

FQ = "HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL"


def scripts(args: list[str]) -> list[Path]:
    all_files = sorted((HERE / "sql").glob("*.sql"))
    if not args:
        return [f for f in all_files if not f.name.startswith("99_")]
    picked = [f for a in args for f in all_files if f.name.startswith(a)]
    if len(picked) < len(args):
        sys.exit(f"no script matches one of {args}; have {[f.name for f in all_files]}")
    return picked


def main() -> None:
    session = get_or_create_session()
    conn = session._conn._conn
    for f in scripts(sys.argv[1:]):
        print(f"-- {f.name}")
        for cur in conn.execute_string(f.read_text()):
            print("  ", cur.fetchall())
    for row in session.sql(f"SHOW MCP SERVERS IN SCHEMA {FQ}").collect():
        print(row.as_dict())


if __name__ == "__main__":
    main()
