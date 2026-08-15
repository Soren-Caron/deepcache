# 06 — Matchmaking & Discovery

Two problems that look different and share a data source: *who should play together* and *what should they bring*.

## Part 1 — Skill-based matchmaking

### Architecture

Roblox gives three primitives that compose into a real cross-server matchmaker:

- **`MemoryStoreService`** — cross-server shared state with TTLs. Sorted maps give ordered reads, which is what makes skill bucketing work.
- **`TeleportService:ReserveServer`** — allocates a private server instance and returns an access code.
- **`TeleportService:TeleportAsync`** — moves a group of players into it together.

```
Lobby place                                    Run place (reserved)
┌────────────────────────────────┐
│ player joins queue             │
│   ↓                            │
│ MemoryStoreSortedMap           │
│   key: "q:<bucket>"            │
│   entry: {pid, rating, ts}     │
│   ↓                            │
│ Coordinator loop (2 s)         │
│  - elected via MemoryStore     │
│    lock, 10 s TTL              │
│  - reads buckets, forms squads │
│  - ReserveServer()             │──────────► accessCode
│  - writes match to HashMap     │
│  - TeleportAsync(players)      │──────────► players arrive together
└────────────────────────────────┘
```

**Coordinator election** matters: every lobby server runs the same loop, so without a lock they'd form conflicting matches from the same queue entries. A `MemoryStoreHashMap` key holds a 10-second lease; the holder coordinates, others idle and watch. Lease expiry means a crashed coordinator is replaced within 10 s. This is the distributed-systems core of the feature and it's worth building carefully.

**Atomicity:** queue entries are removed with `MemoryStoreSortedMap:UpdateAsync` (compare-and-set) before the teleport is issued. A double-matched player is the failure this prevents.

### Skill rating

Glicko-style: a rating `r` plus a deviation `rd` that represents uncertainty. Plain Elo is wrong here because it's a co-op PvE game with no opponent — the "opponent" is the run's difficulty.

```
expectedPerformance = f(runDifficulty, squadRatings)
actualPerformance   = w1*extracted + w2*normalizedValue + w3*(1-deathRate) + w4*objectiveRate
r'  = r + K(rd) * (actual - expected)
rd' = shrink(rd) after each run, grow with time since last seen
```

- New players start at `r = 1200, rd = 350` — high uncertainty means fast early movement and wide initial matching.
- `K(rd)` scales with deviation: uncertain players move fast, established players move slowly.
- `rd` grows with inactivity, so a returning player re-calibrates instead of being stuck.

All of this is `core/discovery/Rating.luau` — pure, deterministic, unit-tested against hand-computed expected values. Ratings are computed backend-side from `run.end` telemetry (authoritative), cached to DataStore for the player and mirrored into MemoryStore for fast queue reads.

### Bucketing and widening

Buckets are 100 rating points wide. A player at 1250 starts in bucket 12.

| Wait time | Search |
|---|---|
| 0–15 s | own bucket only |
| 15–30 s | ±1 bucket |
| 30–45 s | ±2 buckets |
| 45 s+ | any bucket, fill by closest rating |
| 75 s+ | start the run undersized rather than keep waiting |

The last row is the important one. A matchmaker that optimizes purely for match quality produces a queue nobody finishes waiting in. **Target: p95 wait < 30 s, p99 < 60 s** — measured, and on the dashboard.

**Backfill:** runs with an open slot in the first 4 minutes register in a `MemoryStoreHashMap` of joinable runs. New queuers with compatible ratings can be routed into an in-progress run instead of a fresh one, which shortens waits at low population — the condition this game will actually be in.

### Testing without players

The population problem is real: a portfolio project has no concurrent users. `sim/matchmaking.ts` simulates arrival processes (Poisson, configurable λ) against a synthetic rating distribution and measures wait-time percentiles and match-quality (mean intra-squad rating spread) across population levels from 5 to 500 concurrent. That produces defensible curves without needing a live audience, and the honest framing — "simulated arrivals, real algorithm" — is stronger than a vague claim.

## Part 2 — Loadout recommendations

### Scope, honestly

This is **item-item collaborative filtering with cosine similarity**, not a neural model. It's small, it's correct, it's evaluated against a baseline, and it can be explained end to end in ninety seconds. That's a better interview artifact than an unexplainable model.

### Data

From `loot.pickup`, `run.start` loadouts, and `run.end` outcomes, build a player × item interaction matrix. An interaction is weighted:

```
w(player, item) = 1.0 * timesEquipped
                + 2.0 * timesEquippedInSuccessfulExtraction
```

Successful runs count double — the signal is "what works," not just "what's popular."

### Similarity

```
sim(a, b) = cooccur(a,b) / sqrt(count(a) * count(b))          -- cosine on the co-occurrence matrix
```

with **shrinkage** to suppress noise from rare pairs:

```
sim'(a, b) = sim(a, b) * cooccur(a,b) / (cooccur(a,b) + λ),   λ = 10
```

Without shrinkage, a pair that co-occurred twice gets a similarity of 1.0 and dominates the recommendations. This is the single most common failure in naive CF and fixing it is worth calling out.

Computed nightly by `backend/src/workers/recommend.ts` into `loadout_pairs`. The item catalogue is small (~40 items), so the full matrix is 1600 cells — it fits in memory and recomputes in milliseconds. No approximation needed, and saying "I chose exact computation because N=40" demonstrates knowing when *not* to reach for a library.

### Serving

```
GET /v1/recommend/loadout?pid=a3f9

{
  "recommendations": [
    { "itemId": "carbine_mk2", "score": 0.71, "reason": "pairs_with_owned" },
    { "itemId": "light_rig",   "score": 0.64, "reason": "similar_players" },
    { "itemId": "arc",         "score": 0.52, "reason": "popular_at_your_rating" }
  ],
  "fallback": false
}
```

Score for a candidate item = sum of `sim'(candidate, owned)` over the player's owned/recently-used items, minus items already equipped.

**Cold start** — a player with fewer than 3 runs gets the popularity baseline for their rating bucket, with `fallback: true`. Roughly half of all recommendation requests in a small game will be cold-start, so the fallback path is the main path and gets tested first.

### Offline evaluation

The part that makes this defensible:

1. Split runs by time: the last 20% is the held-out set.
2. For each held-out run, hide the player's actual loadout; generate top-3 from the training data only.
3. **recall@3** = fraction of held-out runs where at least one actually-equipped item appears in the top 3.
4. Compare against a **popularity baseline** (global top-3 by equip count).

**Success = recall@3 beats the popularity baseline by a meaningful margin on a held-out split.** If it doesn't, report that. A recommender that ties popularity is a genuinely interesting finding for a small catalogue and a small population — and reporting a negative result honestly is worth more in an interview than a fabricated win.

Evaluation runs as `npm --prefix backend run eval:recommend` and prints a comparison table. It is checked in and reproducible.

### Also recommended: map variant

Same machinery, different item space. Zone-layout seeds are tagged with feature vectors (corridor density, vertical spread, pad distribution). Players who extract more often from certain layout profiles get matched to similar seeds. Small feature, nearly free once the CF pipeline exists, and it demonstrates the pipeline generalizes.

## Metrics

| Metric | Target |
|---|---|
| Queue wait p50 / p95 / p99 | < 12 s / 30 s / 60 s at simulated λ=1/s |
| Intra-squad rating spread (mean) | < 120 points |
| Coordinator failover time | < 12 s (lease TTL + loop interval) |
| Double-match rate | 0 — asserted, not tolerated |
| recall@3 vs popularity baseline | measured and reported either way |
| Cold-start share of requests | tracked (expected high) |
