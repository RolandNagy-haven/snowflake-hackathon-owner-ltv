"""Tiny CLI around the snowflake-query session: run SQL from args or stdin, print rows.

    python semantic-views/footfall/sf.py "select 1"
    python semantic-views/footfall/sf.py < file.sql        # multi-statement, prints last result of each
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / ".claude/skills/snowflake-query"))
from snowflake_session import get_or_create_session  # noqa: E402


def session():
    return get_or_create_session(database="HAVEN_DATA_SCIENCE_DEV", schema="PETERZENTAI_LOCAL")


if __name__ == "__main__":
    sql = " ".join(sys.argv[1:]) if len(sys.argv) > 1 else sys.stdin.read()
    s = session()
    for stmt in [q for q in sql.split(";\n") if q.strip()]:
        df = s.sql(stmt).to_pandas()
        import pandas as pd
        with pd.option_context("display.max_rows", 200, "display.max_columns", 50, "display.width", 250):
            print(df.to_string(index=False))
        print("---")
