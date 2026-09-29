"""Deploy a DDL file from this folder to HAVEN_DATA_SCIENCE_DEV.PETERZENTAI_LOCAL.

    python semantic-views/footfall/deploy.py FOOTFALL_ARRIVALS_SV_V1.sql
"""
import sys
from pathlib import Path

from sf import session

sql = (Path(__file__).parent / sys.argv[1]).read_text()
for cur in session()._conn._conn.execute_string(sql, remove_comments=True):
    print(cur.sfqid, cur.fetchone())
