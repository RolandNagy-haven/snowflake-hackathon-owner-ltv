"""Reusable Snowflake Snowpark session for the Owner LTV work.

Uses the named connection in ~/.snowflake/connections.toml (default: "myconnection",
externalbrowser SSO). Optionally switches role/warehouse/schema after connecting.

    from sf_session import get_session
    s = get_session()                       # connection defaults
    s = get_session(role="NEXUS_SPIKE")     # switch role for source reads / owning objects
"""
import os

from snowflake.snowpark import Session

_CONNECTION = os.environ.get("SF_CONNECTION", "myconnection")
_session: Session | None = None


def get_session(*, role=None, warehouse=None, database=None, schema=None,
                secondary_roles=True) -> Session:
    global _session
    if _session is None:
        _session = Session.builder.config("connection_name", _CONNECTION).create()
        if secondary_roles:
            _session.sql("use secondary roles all").collect()
    if role:
        _session.sql(f"use role {role}").collect()
    if warehouse:
        _session.sql(f"use warehouse {warehouse}").collect()
    if database:
        _session.sql(f"use database {database}").collect()
    if schema:
        _session.sql(f"use schema {schema}").collect()
    return _session
