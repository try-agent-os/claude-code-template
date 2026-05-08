---
name: competitor-sweep
description: Sweep public sources (Google Maps, Yelp, TripAdvisor) for restaurants in a given radius around a client's address. Returns a structured comparison — pricing, ratings, signature dishes, hours. Use when the consultant asks "что у нас в районе" or "как мы стоим vs соседи".
---

# Competitor Sweep

Run a 500m / 1km / 2km radius scan around a client's address and return a structured competitor table.

## Input

- `client_slug` — pulls address from `memory/clients/<slug>/index.md`.
- `radius_m` — 500 / 1000 / 2000 (default 1000).
- `cuisine_filter` — optional, e.g. "italian", "pizza", "cafe". Pass through to the geo APIs.

## Behaviour

1. Read `memory/clients/<client_slug>/index.md` for the address. If missing — ask the consultant for lat/lng or full street address.
2. Use available tools (Google Maps Places API via WebFetch, or scraped Yelp / TripAdvisor pages) to gather:
   - Name, cuisine, address, opening hours
   - Rating (Google + Yelp where both exist) and review count
   - Price tier ($, $$, $$$)
   - Signature item if visible from menu listings
3. Build a markdown table:

   | Competitor | Distance | Rating | Reviews | Price | Notes |
   |------------|----------|--------|---------|-------|-------|

4. Add a 3-bullet summary:
   - **Direct competitors** (same cuisine + price tier) — count + names
   - **Where the client wins** (e.g. "rated higher, better reviews on service")
   - **Where the client is weak** (e.g. "no website, lower review velocity, missing on Yelp")

5. **Save the sweep output** to `memory/clients/<slug>/sweeps/YYYY-MM-DD.md` for trend tracking.

## Limits

- Public sources have rate limits — don't run the same client more than weekly without flagging cost to the consultant.
- Don't make claims you can't source — link every number / quote to the source URL.
- If a paid tool is available (e.g. SimilarWeb, Tripadvisor API), prefer it and note the source in the output.

## Trigger phrases the consultant might use

- "как мы стоим vs соседи"
- "competitor sweep для {client}"
- "кто у {client} в радиусе километра"
- "сделай compare {client_a} vs {client_b}"
