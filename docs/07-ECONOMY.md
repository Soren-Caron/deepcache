# 07 — Economy

Three things, in dependency order: a ledger you can trust, a control loop that tunes itself off telemetry, and a market with escrow.

## Part 1 — The ledger

**Every currency mutation is an immutable row.** Balance is a derived value, never a stored mutable number that code increments.

```
LedgerEntry = {
  pid, delta, reason, runId, idemKey, ts
}
```

`reason` is an enum: `extract_payout`, `objective_bonus`, `daily_first`, `repair`, `ammo`, `insurance_premium`, `insurance_claim`, `market_fee`, `market_sale`, `market_purchase`, `cosmetic`, `admin_adjust`.

### Why this shape

The bug this design eliminates is the one that kills game economies: a duplicate grant. It happens when a payout request times out, the client or server retries, and both land. With `idemKey UNIQUE` on the database and an idempotency set in `core/economy/Ledger.luau`, the second write is a no-op — detected, counted, and ignored. Not an error, just a fact.

```lua
Ledger.apply(state, entry) -> (newState, ok: boolean, status: ApplyStatus)
-- status: "applied" | "duplicate" | "insufficient_funds"
-- ok == true for both "applied" and "duplicate": in both cases the entry's
--   effect is accounted for in the ledger, which is the only thing a caller
--   needs to know before delivering whatever the entry paid for.
-- ok == false ONLY for "insufficient_funds". Caller must not deliver.
```

**Corrected during the M2–M6 audit pass.** This originally read
`-> (newState, applied: boolean)`, with "`applied == false` means idemKey was
already seen; caller treats this as success." That signature has no way to
express the rejection this same document requires two sections down
("negative balance is impossible (rejected, not clamped)"), so both outcomes
collapsed onto `false` — and a caller following the stated rule would treat a
*rejected* purchase as a success and hand over the goods without ever taking
the currency. That is the duplicate-grant bug the ledger exists to prevent,
arriving through the error path. The rejection now gets the distinct boolean
and `status` disambiguates the rest.

`idemKey` construction is deterministic so a retry produces the *same* key: `hash(runId .. pid .. reason .. sequenceWithinRun)`. A random UUID per attempt would defeat the entire mechanism — this is the detail to get right.

### Persistence

- **Authoritative store:** the `ledger` table in Postgres.
- **In-game:** `DataService` keeps a per-player balance in DataStore with a write-behind queue (batched, ≤1 write per player per 6 s, coalesced) because DataStore per-key write limits are real and will throttle under load.
- **Reconciliation job:** nightly, recompute each player's balance from the ledger sum and compare to the cached DataStore value. Any mismatch is logged with the delta and the run it likely came from. Target: **zero mismatches**; a nonzero count is a bug report, not a tuning knob.

This split — fast cache in-game, authoritative log in Postgres, nightly reconciliation — is a normal production shape and having built it is the point.

## Part 2 — The closed-loop tuner

### The target

A healthy economy's **sink-to-faucet ratio** sits slightly below 1.0. Above 1.0 and players deflate out of the game; far below and currency becomes meaningless. Target: **0.85**, meaning 85% of created currency is destroyed within the measurement window.

Most games tune this by hand, quarterly, from a spreadsheet. Here it's a control loop reading the same telemetry pipeline everything else uses.

### The controller

`core/economy/Controller.luau` — pure, testable, no I/O:

```lua
-- Nightly, over a trailing 24h window
ratio = sinkTotal / max(faucetTotal, 1)
error = TARGET_RATIO - ratio          -- positive error ⇒ too much currency entering

integral = clamp(integral + error, -I_MAX, I_MAX)
adjust   = KP * error + KI * integral

multiplier' = clamp(
    multiplier * (1 - adjust),
    MULT_MIN, MULT_MAX
)
multiplier' = clampDelta(multiplier', multiplier, MAX_DAILY_DELTA)
```

```lua
TARGET_RATIO    = 0.85
KP              = 0.35
KI              = 0.05
I_MAX           = 2.0
MULT_MIN        = 0.80
MULT_MAX        = 1.25
MAX_DAILY_DELTA = 0.03      -- never move more than 3% in a day
```

**Why PI and not PID:** the derivative term amplifies noise, and daily economy data from a small population is nothing but noise. Integral handles the steady-state offset, which is the actual problem — a persistent small imbalance compounds. Explaining *why the D term is absent* is a better interview answer than having included it.

### The guardrails

A self-tuning economy that can run away is worse than a static one. Non-negotiable:

- **Rate limit:** ±3% per day maximum, regardless of what the controller wants.
- **Hard clamps:** multiplier is confined to `[0.80, 1.25]`. Reaching a clamp for 3 consecutive days raises an alert rather than pushing further — sustained clamping means the model is wrong, not that the gain is too low.
- **Kill switch:** `economy.autotune_enabled` in config. Off means the multiplier freezes at its current value.
- **Minimum sample size:** fewer than 200 runs in the window → skip the update entirely. Small-sample noise is the most likely source of a bad adjustment.
- **Full audit:** every adjustment writes to `economy_daily` with inputs, output, and the reason it was or wasn't applied.
- **What the multiplier touches:** extraction payout and objective bonus only. It never touches sinks (players notice price changes far more than payout changes), and it never touches drop *rates* — only the credit conversion. Changing what drops changes gameplay; changing what it's worth changes the economy. Keeping those separate is the design discipline.

### Validating a controller with no players

`sim/economy.ts` runs the controller against synthetic populations with known biases — a faucet 30% too generous, a sink nobody uses, a sudden population spike — and asserts it converges to the target band within N days without oscillating. That's a real test of a real control loop, and it runs in a terminal in under a second.

## Part 3 — The market

### Why an order book instead of direct trading

Direct player-to-player trading is the natural design and the wrong one here. It's a scam surface (the classic "trust trade"), it's hard to price-discover, and it produces no useful data. An **escrowed consignment order book** is safer, generates genuine price signal, and is more interesting to build.

### Mechanics

```
SELL: player lists item at limit price → item moves to escrow immediately
BUY:  player places bid at limit price → credits move to escrow immediately
MATCH: server matching engine, price-time priority
FILL: item → buyer, credits → seller minus 5% fee (a sink), both escrows released
CANCEL: escrow returns to owner, always available on unfilled orders
```

`core/economy/Market.luau` is the matching engine, and it is pure:

```lua
Market.match(book: OrderBook, incoming: Order) -> (newBook, fills: {Fill})
```

Price-time priority: best price first, oldest first at equal price. Partial fills supported. Every fill is two ledger entries plus a fee entry — the ledger is the record, the book is just state.

### Abuse resistance

| Attack | Mitigation |
|---|---|
| Price manipulation via wash trading | Per-item price band: orders outside ±40% of the 7-day VWAP are rejected. Self-trades (same `pid` both sides) rejected outright. |
| Duping via race conditions | Escrow is transferred *before* the order enters the book. An item cannot be in escrow and in inventory simultaneously — enforced by a single server-authoritative transition. |
| RMT (real money trading) | Items are never purchasable with Robux and never gifted directly. Every transfer goes through the book at a market-band price with a fee. This doesn't eliminate RMT but makes it costly and legible. |
| Alt-account farming | Per-account daily trade volume cap; new accounts (< 5 runs) cannot sell. |
| Market cornering | Per-item, per-player open-order quantity cap. |

Every order and fill emits telemetry, so a manipulation attempt leaves a trail even when the guardrails allow it.

### Price discovery as a data product

The 7-day VWAP per item, published to the dashboard, is the market working. It also feeds back into the tuner: if an item's market price collapses, its drop rate is too high — a signal the drop tables can be tuned against manually, with data. (Automatic drop-rate tuning is deliberately *out* of scope; one closed loop is enough for one project.)

## Faucets and sinks

| Faucet | Approx. share of currency created | Multiplier applies |
|---|---|---|
| Extraction payout | 70% | ✔ |
| Objective bonus | 20% | ✔ |
| First extract of day | 10% | ✔ |

| Sink | Design intent |
|---|---|
| Gear repair | Scales with run length — a soft tax on playing |
| Ammo restock | Scales with usage — a tax on inefficiency |
| **Insurance premium** | Paid *before* the drop, recovers 40% of carried loot value on death. The most interesting sink: it lets players buy down variance, and its uptake rate is a direct readout of population risk appetite. |
| Market fee (5%) | Scales with economic activity — the sink that grows as the economy grows |
| Cosmetics | Fixed-price, unlimited demand, the long-tail sink |

Insurance uptake is the metric to watch. If it's near 100%, the premium is too cheap and risk has been designed out. If it's near 0%, it's too expensive or loot isn't valuable enough. The healthy band is 30–60%, and it's on the dashboard.

## Metrics

**Divergence, found by the M6-4 fuzz/convergence test (`tests/controller.spec.luau`), not fixed here:** the `< 14` days target below does not hold for the gains given in §The controller (`KP=0.35, KI=0.05`) together with the `MAX_DAILY_DELTA=0.03` rate cap. Measured, starting 30% away from target: the ratio does not settle into the ±0.05 band until **day 24**. The rate cap is the binding constraint, not the gains — 3%/day means at least 10 days just to physically close a 30-point multiplier gap, and integral windup during that forced climb causes overshoot that takes another ~10+ days to settle. Retuning the gains without a real population to validate against would be guessing, so the number below is left as the original target with this note rather than silently edited to match the measurement. See [tasks/BACKLOG.md](../tasks/BACKLOG.md) M6-4.

| Metric | Target |
|---|---|
| Sink/faucet ratio (24h) | 0.85 ± 0.05 after convergence |
| Days to converge from a 30% seeded imbalance (sim) | < 14 (not met by current defaults — see note above; measured 24) |
| Ledger reconciliation mismatches | 0 |
| Duplicate-grant attempts caught | tracked (nonzero is fine — it means the guard works) |
| Median credit balance, p10/p90 | monitored for wealth-gap blowout |
| Insurance uptake | 30–60% |
| Market fill rate / median time-to-fill | tracked |
| Orders rejected by price band | tracked (manipulation signal) |

## Tests

Pure-core:
- `Ledger`: duplicate `idemKey` is a no-op; balance equals the sum of deltas across 10,000 random entries; negative balance is impossible (rejected, not clamped).
- `Controller`: converges from ±30% imbalance; respects daily delta cap; refuses to update below the sample-size floor; clamps hold across 365 simulated days of adversarial input.
- `Market`: price-time priority ordering; partial fills sum correctly; self-trade rejected; out-of-band price rejected; cancel returns exact escrow; fuzz test with 100k random orders asserts no currency or items are created or destroyed.

That last one — a conservation invariant under fuzzing — is the test worth writing first.
