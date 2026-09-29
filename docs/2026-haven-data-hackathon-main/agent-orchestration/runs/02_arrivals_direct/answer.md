# arrivals: How many distinct guests arrived (arrival date) at each park over the weekend of 19-21 September 2026? Give the 10 parks with the most arriving guests.

I'll search for relevant tables or semantic views that could answer this question about guest arrivals at parks.

I found the `NEXUS_BRONZE.DIG_ARRIVALS.ARRIVAL` view with `PARK_CODE` and `ARRIVAL_DATE` columns. Let me check its full schema, then run the query.

Each row is a single holiday stay. I'll count distinct arrivals per park for 19-21 Sep 2026, joining to get park names.

Here are the **top 10 parks by distinct arriving guests** over the weekend of 19–21 September 2026:

| Rank | Park Code | Park Name    | Arriving Guests |
|------|-----------|-------------|-----------------|
| 1    | BE        | Berwick      | 3               |
| 2    | PH        | Presthaven   | 3               |
| 3    | CG        | Cala Gran    | 3               |
| 4    | SA        | Seashore     | 2               |
| 5    | DE        | Devon Cliffs | 2               |
| 6    | HM        | Hafan y Mor  | 2               |
| 7    | AH        | Kent Coast   | 1               |
| 8    | HO        | Hopton       | 1               |
| 9    | LA        | Lakeland     | 1               |
| 10   | QW        | Quay West    | 1               |

The numbers are notably low — Berwick, Presthaven, and Cala Gran lead with just 3 arrivals each. This likely reflects that 19–21 Sep 2026 is a few days away and most bookings for that weekend may not yet have been loaded, or the season is winding down. I filtered out cancelled and deleted records.
