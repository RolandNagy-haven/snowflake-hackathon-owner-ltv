---
name: snowflake-query
description: Establish a Snowflake Snowpark session and run read-only queries
trigger_patterns:
  - user pastes or references a SQL statement
  - "look into snowflake"
  - "query snowflake"
  - "check the stage"
  - "what tables exist in …"
  - "show me … from snowflake"
  - "describe table/view …"
  - "run this on snowflake"
  - any request that implies reading data from or inspecting objects in Snowflake
---

# Snowflake Query Skill

## Purpose

Provide a reusable way to establish a **Snowflake Snowpark session** from local
development and execute **read-only** operations (SELECT, SHOW, DESCRIBE, LIST).

## Session helper

A ready-made session module lives at:

```
.claude/skills/snowflake-query/snowflake_session.py
```

It exposes `get_or_create_session(*, database=None, schema=None)` which:

- Uses **EXTERNALBROWSER** SSO auth (will open a browser tab on first call).
- Defaults to `HAVEN_DATA_SCIENCE_DEV` / `PETERZENTAI_LOCAL` but accepts any
  database/schema override.
- Reuses a singleton session across calls within the same process.
- Runs `USE SECONDARY ROLES ALL` after connecting.

### Environment variables (all optional)

| Variable      | Default                                | Notes                |
|---------------|----------------------------------------|----------------------|
| `SF_USER`     | `peter.zentai@haven.com`    | Snowflake login      |
| `SF_SCHEMA`   | `PETERZENTAI_LOCAL`                    | Default schema       |
| `SF_DATABASE` | `HAVEN_DATA_SCIENCE_DEV`              | Default database     |

## How to use this skill

When the user's request requires Snowflake access, **you** decide the best
execution approach based on the complexity of the task:

### Option A — Inline script (simple, one-off queries)

Write a short inline Python snippet and run it via Bash. Good for quick lookups,
single SQL statements, or exploratory checks.

```python
import sys; sys.path.insert(0, ".claude/skills/snowflake-query")
from snowflake_session import get_or_create_session

session = get_or_create_session()
rows = session.sql("SELECT * FROM my_table LIMIT 10").collect()
for r in rows:
    print(r)
```

### Option B — Standalone script (multi-step or reusable work)

Create a `.py` file (in `sandbox/` or wherever fits the task), import the
session helper, and run it. Good when the logic is non-trivial, needs iteration,
or the user may want to re-run it later.

```python
# my_script.py
import sys; sys.path.insert(0, ".claude/skills/snowflake-query")
from snowflake_session import get_or_create_session

session = get_or_create_session(database="PROD_DB", schema="PUBLIC")
# ... your logic ...
```

### Choosing between A and B

- **You decide.** The skill is unopinionated about output handling, formatting,
  or file organisation — adapt to the task.
- For quick "show me X" requests, prefer inline (Option A).
- For anything the user might revisit, or that spans multiple queries with
  intermediate logic, prefer a script (Option B).

## Constraints

- **Read-only.** Do not execute DDL or DML (CREATE, INSERT, UPDATE, DELETE,
  DROP, etc.) unless the user explicitly asks and confirms.
- Always use the `sys.path.insert` pattern shown above so the session module is
  importable regardless of the working directory.

## Dependencies

Requires these Python packages (already available in the project venv):

- `snowflake-snowpark-python`
- `cryptography`
