"""
Reusable Snowflake session helper.

Usage from other scripts:
    from snowflake_session import get_or_create_session
    session = get_or_create_session()
    session = get_or_create_session(database="OTHER_DB", schema="OTHER_SCHEMA")
    session = get_or_create_session(role="MY_ROLE")

Auth: EXTERNALBROWSER SSO (opens a browser tab on first use per session).

Environment variables (all optional — sensible defaults are provided):
    SF_USER     Snowflake username       (default: peter.zentai@haven.com)
    SF_SCHEMA   Default schema           (default: PETERZENTAI_LOCAL)
    SF_DATABASE Default database          (default: HAVEN_DATA_SCIENCE_DEV)
    SF_ROLE     Snowflake role           (default: HAVEN_DATA_SCIENCE_DEV)
"""

import os

from snowflake.snowpark import Session
from snowflake.snowpark.context import get_active_session

_SF_USER = os.environ.get("SF_USER", "peter.zentai@haven.com")
_SF_SCHEMA = os.environ.get("SF_SCHEMA", "PETERZENTAI_LOCAL")
_SF_DATABASE = os.environ.get("SF_DATABASE", "HAVEN_DATA_SCIENCE_DEV")
_SF_ROLE = os.environ.get("SF_ROLE", "HAVEN_DATA_SCIENCE_DEV")

_session: Session | None = None


def get_or_create_session(
    *,
    database: str | None = None,
    schema: str | None = None,
    role: str | None = None,
) -> Session:
    """Return an active Snowpark session, reusing one if it already exists.

    Accepts optional database/schema/role overrides. When omitted, falls back to
    environment variables or built-in defaults.  ``role`` is applied via
    ``USE ROLE`` after connecting, so it can override the connection-time default.
    """
    global _session

    try:
        return get_active_session()
    except Exception:
        pass

    if _session is not None:
        try:
            _session.sql("SELECT 1").collect()
            if role is not None:
                _session.sql(f"USE ROLE {role}").collect()
            return _session
        except Exception:
            _session = None

    params = {
        "user": _SF_USER,
        "account": "bd78472.eu-west-1",
        "role": _SF_ROLE,
        "warehouse": "HAVEN_DATA_SCIENCE_DEV_WAREHOUSE_XSMALL",
        "database": database or _SF_DATABASE,
        "schema": schema or _SF_SCHEMA,
        "authenticator": "EXTERNALBROWSER",
    }

    _session = Session.builder.configs(params).create()
    _session.sql("USE SECONDARY ROLES ALL").collect()
    if role is not None:
        _session.sql(f"USE ROLE {role}").collect()
    return _session
