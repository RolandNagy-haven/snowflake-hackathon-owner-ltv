# 13 — Definitions Meeting (whiteboard transcript)

Source: `docs/transcription.rtf` — the whole-team **definitions whiteboard session** (owner,
lead/prospect, acquisition routes, spend). Speech-to-text, so names/terms are approximate
(e.g. "Aptitude" = **Amplitude**, "Noida"/"NO" = **owner**). Captured as the starting document
for the agents. This is **business context that is not in any table** — put the load-bearing
parts into the semantic-view descriptions and the 09:45 owner-definition decision
([04](04-owner-definition-and-joins.md)).

## An owner, and the lifecycle statuses

- An **owner** is someone who has **one or more caravans** (one owner can own several — this is
  the one-HID-to-many-accounts fact from [04](04-owner-definition-and-joins.md), stated in
  business terms).
- **"Complete"** = keys in hand and paid. But you can be counted as an owner on **pitch status
  alone** — you can hold an owner pitch status without being "complete".
- **Pitch status marks where an owner is in their lifecycle**, and the edges are genuinely
  ambiguous: someone who has *started the leaving process* is arguably still an owner. **Decide
  and label the boundary** — this is a 09:45 decision, not a data fact.

Key pitch statuses named in the room:

| Status | Meaning |
|---|---|
| **OW** | The main owner status ("OW = owner") |
| **Registered to private sale** | Still an owner, but leaving via the private-sale route |
| **Part exchange (PX)** | In the process of part-exchanging as an owner |
| **Transfer of ownership** | A distinct status/figure for ownership changing hands |

⚠️ These are business statuses raised verbally — **verify the exact status codes/values against
the pitch-status dimension** (`DIM_PITCH_STATUS`) before encoding them in the semantic view.

## Routes into ownership

Ownership is reached by more paths than "Haven sells you a van":

- **Through Haven means** — targeted marketing / new-customer offering.
- **Bring your own caravan** — arrive from a PDR park (Parks & Party Resorts) or "knock on the
  door" with your own van; Haven can also bring you one.
- **NPX — New customer Park eXchange** — bring a caravan and part-exchange it immediately.
- **NTO — New customer Take On** — bring your caravan and Haven gives you the pitch.
- **Private sale** — like-for-like owner-to-owner sale. Haven has **first dibs**; if Haven
  declines, the owner may find their own buyer.
- **Tora** — a further bring-on route (mentioned, not certain — confirm before relying on it).

➡️ Acquisition-route matters for the demo question ("which routes produce owners worth having").
It also cross-checks the untested worry in [04](04-owner-definition-and-joins.md) — whether HID
coverage varies by route.

## Lead vs prospect — deliberately unresolved

- **There is no agreed definition of "lead" vs "prospect".** "Everybody you ask is completely
  different"; some use the words interchangeably. This must be pinned down before "what is an
  owner" can be fully answered — it's a Top-of-Funnel decision ([06](06-other-domains.md)).
- **One inquirer can have multiple deals, and each deal can have a different source** — so
  source is a per-deal, not per-person, attribute.
- Channels split into:
  - **Park leads** — people walking into the **show ground** (each park has one), served by
    **HHAs / Holiday Home Advisors**. Attributed to the park.
  - **Pre-booked** — digital websites, partner websites, CRM, responses to Kirsty's emails,
    "want a caravan" web forms (MHC). Performance-marketing traffic generally lands here. Fill
    out a form → pre-booked appointment / arrange-a-visit (higher intent).
  - **Organic** — turn up at a show without booking; may have prior activity that was never
    captured.

## Digital / Amplitude identity caveats

- Marketing leans heavily on **Amplitude** (Amplitude ID). Before a website login, a person may
  be known **only by device/Amplitude ID**; identity is merged/rejoined later — a "huge issue
  about identification". (Ties to the Bloomreach `amplitude_id` bridge in
  [04](04-owner-definition-and-joins.md).)
- **Do not expect 100% coverage of digital data:**
  - Ad-blocking technology can block tracking (loss size **unknown**, maybe ~10% extra).
  - **GDPR consent** is required — if a user declines, there is no data. Consent rates are
    **~80%**.
  - **Digital figures won't reconcile line-for-line** with other sources — state it, don't
    paper over it. (This is the divergence problem in [09](09-benchmark-and-divergence.md).)

## Owner spend tracking (LTV value components)

Directly relevant to the Owner LTV value picture — see [05](05-owner-ltv-playbook.md):

- **Owner cards** (now a **digital pass**) are how on-park owner spend is tracked — owners get
  **20% off** (same as staff discount).
- ⚠️ **One owner → multiple accounts, from cards too:** **friends and family also get owner
  cards** attributed to an account number. Spend can spread across several accounts under one
  owner — reinforces the "aggregate to the person" caution.
- **F&B** spend via cards is reliable. **Retail** is not fully: a few parks run a different EPOS
  that captures **no identity on scan**, so that spend is invisible.
- **Private lets** are harder — private letters used to use the owner card; Haven tried to stop
  it, and **how often they still do is unknown**.
- **Owner lounges** — spend surfaces in the retail/OE transaction reports; the retail team has
  already analysed lounge spend.
- **Owner events** (entertainment) — **attendance is largely not tracked**; sign-up events are
  partially capturable via click-through/activity (Kirsty), walk-ups are not. A data-collection
  gap, not a value we can currently measure.

## How to use this file

Qualitative, verbal, and partly uncertain. Treat it as **direction for descriptions and the
09:45 decisions**, not as verified schema. Anything encoded in a semantic view (status codes,
route flags, spend sources) must be **checked against the actual tables first**.
