# 09 — Testing & Simulation

This doc is the reason the project can be built with little human input. Read it before writing code.

## Three problems it solves

1. **Studio is a human-in-the-loop bottleneck.** Anything requiring "open Studio, press play, look at it" cannot be iterated on autonomously.
2. **A portfolio game has no players.** The economy controller, the matchmaker, and the recommender all need data that doesn't exist yet.
3. **Netcode bugs are invisible at low load.** A snapshot format that works with 5 entities and breaks at 60 must be caught before a playtest, not during.

Each gets a harness.

## Harness 1 — Pure-core unit tests (Lune)

Because `src/shared/core/` touches no Roblox globals, it runs under **Lune**, a standalone Luau runtime. That means:

```bash
lune run tests
```

runs the entire gameplay-logic test suite in a terminal, in under two seconds, with no Studio, no place file, and no human.

This is the single highest-leverage architectural decision in the project. It's why `CLAUDE.md` makes the pure-core rule non-negotiable.

**Runner:** `tests/init.luau` — a ~60-line runner (describe/it/expect, deep-equal, float tolerance). No dependency needed; a test framework for a project this size is more surface than value.

**Coverage targets by module:**

| Module | The cases that matter |
|---|---|
| `net/Quantize` | roundtrip error bounded over 10k random values across the full range; boundary values; negative coordinates |
| `net/Snapshot` | encode→decode identity; 81 entities fits / 82 asserts; delta reconstruction over a 200-tick recorded sequence matches keyframes |
| `net/Interpolator` | known sequence → expected samples; gap handling; extrapolation cutoff at exactly 80 ms; out-of-order arrivals dropped |
| `net/History` | rewind to exact tick, between ticks, before window (nil), after now (clamp) |
| `sim/Budget` | spend never exceeds budget; per-type caps respected; deterministic under a fixed seed |
| `sim/Steering` | seek converges; separation prevents overlap; obstacle avoidance at a wall |
| `sim/DamageModel` | falloff boundaries; armor; zero/negative guards |
| `director/Clamp` | **every malformed input shape returns a valid decision** — null, empty object, wrong types, out-of-range, unknown enum, missing fields, extra fields, deeply nested garbage |
| `director/Fsm` | state transitions on known pacing inputs; no state is unreachable; no infinite ping-pong |
| `economy/Ledger` | duplicate idemKey no-op; balance = sum of deltas over 10k entries; negative balance rejected |
| `economy/Controller` | converges from ±30% imbalance; daily delta cap; sample-size floor; clamps hold over 365 adversarial days |
| `economy/Market` | price-time priority; partial fills; self-trade rejected; band rejection; **fuzz: 100k random orders conserve currency and items exactly** |
| `discovery/Rating` | matches hand-computed values; rd shrinks with play, grows with absence; new-player fast convergence |
| `discovery/Bucket` | widening schedule boundaries; no player ever in two buckets |
| `discovery/Recommend` | shrinkage suppresses rare pairs; cold-start returns baseline; owned items excluded |
| `anim/TwoBoneIk` | reachable / exact / unreachable / degenerate; pole plane |

**Determinism rule:** every test that involves randomness passes a seeded `Rng`. A test that can flake is worse than no test, because it teaches you to ignore failures.

## Harness 2 — Headless run simulator (`sim/`)

The unlock for every data-dependent system.

A TypeScript program that plays thousands of runs *as data* and posts real telemetry to the local backend. It does not run the game — it models it well enough to exercise the pipeline.

```bash
npm --prefix sim run generate -- --runs 2000 --days 30 --lambda 0.8
```

**Player archetypes** — each with distinct behavioral parameters:

| Archetype | Behavior |
|---|---|
| `greedy` | loots past safe weight, extracts late, high death rate, high value when successful |
| `efficient` | extracts at first pad, low value, very high success rate |
| `aggressive` | high kill count, moderate loot, medium deaths |
| `explorer` | high map coverage, inconsistent outcomes |
| `new` | poor at everything, improves along a learning curve over their first 20 runs |

Population mix and skill distribution are configurable. Runs generate the full event catalogue from [04](04-TELEMETRY-BACKEND.md) — including plausible `combat.fire` latency distributions and `director.decision` records — so downstream systems see realistically shaped data.

**What this makes possible before a single human plays:**

- Economy controller convergence, validated against a *known* seeded imbalance (the ground truth is known because the simulator created it — this is a stronger test than live data would give).
- Recommender training and offline `recall@3` evaluation on a real split.
- Matchmaking wait-time curves across population levels the game will never actually see.
- Rollup worker correctness and idempotency at volume.
- Dashboard populated with realistic-looking data from day one.

**The honesty requirement:** simulated data validates *plumbing, statistics, and convergence*. It does not validate *fun*, and it does not prove the director improves the player experience. Every claim built on simulated data must be labeled as such — in the postmortem, on the dashboard, and in interviews. That distinction is itself a credibility signal.

## Harness 3 — Load and performance

`tools/loadtest/` — two parts.

**Serialization throughput (Lune, no engine):** generate 60 synthetic entities, encode/decode 10,000 snapshots, report ns/op and bytes/snapshot. Catches format regressions instantly and runs in CI.

**In-engine tick budget (Studio via MCP `execute_luau`):**

```lua
-- spawn N entities, run 600 ticks, report per-phase timings
local report = require(ServerScriptService.tools.TickBench).run({ entities = 60, ticks = 600 })
-- → { p50, p95, p99, phases = { sim = .., history = .., replication = .. } }
```

Asserted against the 12 ms budget. Run at M1 and re-run at every milestone, because tick cost creeps.

**Latency injection:** Studio's `NetworkSettings.IncomingReplicationLag` lets hit-registration be measured at 50 / 150 / 300 ms simulated RTT without a second machine. This is how lag compensation gets validated before any real multiplayer test.

## Harness 4 — Studio smoke checks (MCP)

For adapter code, which by design is thin. Each adapter gets a smoke script under `tools/smoke/` invoked through `execute_luau`:

- Boot order completes without error; every service reports ready.
- One entity spawns, appears in a snapshot, renders on the client.
- One fire request round-trips and produces a hit event.
- One telemetry batch reaches the local backend (assert a row lands in Postgres).
- One director tick round-trips and applies a clamped decision.

Smoke checks answer "is it wired up," not "is it correct." Correctness lives in the pure-core tests. Keeping that boundary clean is what keeps the Studio-dependent surface small.

## CI

`.github/workflows/ci.yml`:

```yaml
jobs:
  luau:     rokit install → lune run tests → rojo build --output /tmp/out.rbxl
  backend:  npm ci → npm test → npm run typecheck
  sim:      npm ci → npm run generate -- --runs 50 --dry-run   # smoke, not full volume
```

Studio-dependent checks are not in CI — they run locally via MCP and their output is quoted in commit messages. Pretending otherwise would be a lie in the workflow file.

## The testing rule

**Every bug found in Studio gets a pure-core test before it gets a fix.** If the bug can't be expressed as a pure-core test, that's evidence the logic is in the wrong layer, and the fix is to move it. Over the project's life this ratchets the Studio-dependent surface down, which is exactly the direction that makes further work faster.
