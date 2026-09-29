# arrivals: How many distinct guests arrived (arrival date) at each park over the weekend of 19-21 September 2026? Give the 10 parks with the most arriving guests.

Let me check what we already know about this table and then run the query.

No prior notes found. Let me check the DIM_PARK join key first, then run the main query.

Good — join on `PARK_XID`. Now let me run the main query. The weekend of 19–21 September 2026 is Friday 19th to Sunday 21st, so ARRIVAL_DATE_XID IN (20260919, 20260920, 20260921).

Here are the **top 10 parks by distinct arriving guests over the weekend of 19–21 September 2026**:

| Rank | Park | Distinct Guests |
|-----:|------|----------------:|
| 1 | Devon Cliffs | 2,297 |
| 2 | Hafan y Mor | 2,217 |
| 3 | Craig Tara | 2,199 |
| 4 | Primrose Valley | 2,101 |
| 5 | Haggerston | 1,746 |
| 6 | Cleethorpes Beach | 1,599 |
| 7 | Presthaven | 1,491 |
| 8 | Blue Dolphin | 1,476 |
| 9 | Golden Sands | 1,428 |
| 10 | Perran Sands | 1,421 |

Devon Cliffs leads with nearly 2,300 distinct guests arriving that weekend, closely followed by Hafan y Mor and Craig Tara. The count uses `ARRIVAL_DATE_XID` (the scheduled arrival date) across all three days (Fri 19th – Sun 21st), counting each guest once per park regardless of how many on-park-date rows they have.

Noted the DIM_PARK join pattern for future use.
