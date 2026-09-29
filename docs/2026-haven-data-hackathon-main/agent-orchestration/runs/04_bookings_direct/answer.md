# bookings: How many live (not cancelled) bookings do we hold for the 2027 season as of the latest snapshot, and how does that compare with the 2026 season on the same day last year? Top 5 parks too.

Let me check what we already know about status codes and join keys, then build the comparison query.

No prior notes on status codes or join keys. Let me explore the dimension tables to understand how to filter live bookings and join parks.

Good — `BOOKING_STATUS_CATEGORY` looks promising, and parks join on `PARK_XID`. Let me check the status categories and confirm the latest snapshot date.

Status categories are clear: `FIRM` = live bookings, `CANCELLED` = cancelled, `OFFER` = quotes/offers. I'll treat `FIRM` as live. The latest snapshot is **2026-09-25** (a Friday), so the year-ago comparator is **2025-09-26** (also a Friday, 364 days back).

Let me run the headline comparison and top-5 parks in one go.

Here are the results.

## Live (FIRM) bookings — latest snapshot

| Season | Snapshot | Live bookings | Accommodation value (£) |
|--------|----------|---------------|------------------------|
| **2027** | 2026-09-25 | **137,527** | **£70.6 m** |
| **2026** | 2025-09-26 | **149,174** | **£72.4 m** |
| **Variance** | | **−11,647 (−7.8%)** | **−£1.8 m (−2.5%)** |

Season 2027 is tracking **7.8% behind** 2026 on volume at the equivalent point, though the value gap is narrower at −2.5%, suggesting a higher average booking value this year.

## Top 5 parks — 2027 season (by volume)

| Rank | Park | Live bookings | Accommodation value (£) |
|------|------|---------------|------------------------|
| 1 | Devon Cliffs | 8,128 | £5.69 m |
| 2 | Hafan y Mor | 7,383 | £4.81 m |
| 3 | Primrose Valley | 7,175 | £3.86 m |
| 4 | Craig Tara | 5,802 | £2.78 m |
| 5 | Perran Sands | 5,272 | £4.36 m |

**Notes:**
- "Live" = `BOOKING_STATUS_CATEGORY = 'FIRM'` (statuses: Booked, Closed, Terminated).
- Value column used: `TOTAL_ACCOMMODATION_VALUE`.
- YoY comparison uses Friday-to-Friday alignment (364-day gap).

Let me save the key findings for future use.

Findings saved for future questions. Let me know if you'd like to drill into any park, break out by channel, or look at the pace trend over recent weeks.
