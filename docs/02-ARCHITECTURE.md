# 02 — Architecture

## Source of truth is on disk

Files live in git, sync into Studio via Rojo. Studio is a *renderer and a test harness*, never the authority. Code typed into Studio is lost work.

```bash
rojo serve default.project.json    # then Connect from the Rojo Studio plugin
```

## Tree

```
default.project.json
rokit.toml
docker-compose.yml

src/
  shared/
    core/                  # PURE LUAU. No Roblox globals. Lune-testable. ← the important one
      net/
        Snapshot.luau            encode/decode entity snapshots (binary buffer)
        Quantize.luau            float↔fixed-point helpers, error bounds
        Interpolator.luau        render-delay buffer, sample(t) → transform
        History.luau             per-entity ring buffer + rewind(t)
      sim/
        EntityState.luau         entity struct, state enum, transitions
        Steering.luau            seek/separate/avoid, pure vector math
        DamageModel.luau         damage, falloff, armor
        Budget.luau              enemy budget → spawn plan
      director/
        Fsm.luau                 deterministic director; the safety net
        Clamp.luau               validates + clamps any LLM proposal
        Schema.luau              director response shape + validator
      economy/
        Ledger.luau              double-entry math, idempotency
        Controller.luau          PI controller for payout multiplier
        Market.luau              limit-order matching engine
      discovery/
        Rating.luau              skill rating update
        Bucket.luau              rating → queue bucket, widening schedule
        Recommend.luau           cosine similarity scoring
      util/
        Result.luau, Rng.luau (seeded), Ring.luau, Clock.luau (injected time)
    config/                # PURE DATA. No functions, no requires.
      Enemies.luau  Weapons.luau  Loot.luau  Zones.luau  Objectives.luau
      Economy.luau  Netcode.luau  Branding.luau
    net/
      Remotes.luau         single declaration point for every remote
      Wire.luau            shared payload type definitions
  server/
    Bootstrap.server.luau  ordered service startup
    services/
      TickService.luau         fixed 20 Hz accumulator loop; drives everything
      EntityService.luau       owns entity list; calls core/sim each tick
      ReplicationService.luau  interest mgmt + snapshot send
      CombatService.luau       validates fire requests, lag-comp via core/net/History
      MovementGuard.luau       server-side plausibility checks on player motion
      LootService.luau         spawn, claim tokens, weight
      RunService_.luau         run lifecycle, timer, extraction
      DirectorService.luau     calls proxy async, applies clamped result
      TelemetryService.luau    event buffer + batched flush
      EconomyService.luau      ledger writes, payouts, market orders
      DataService.luau         DataStore access, write-behind queue
    adapters/                  thin Roblox↔core translation. Keep these boring.
  client/
    Bootstrap.client.luau
    controllers/
      PredictionController.luau  local weapon prediction + reconciliation
      EntityRenderer.luau        interpolated entity rendering, LOD
      RagdollController.luau     client-only death physics
      LookController.luau        post stack, lighting presets, EditableImage budget
      HudController.luau         timer, weight, OVERSEER comms feed
      InputController.luau

backend/                   # Node 24 + TypeScript + Fastify + Postgres
  src/
    routes/ingest.ts  routes/director.ts  routes/config.ts  routes/recommend.ts
    workers/rollup.ts workers/economy.ts workers/recommend.ts
    db/migrations/    db/queries.ts
    llm/client.ts     llm/schema.ts       llm/fallback.ts
  test/

sim/                       # headless run simulator — generates telemetry without players
tests/                     # Lune test suites for src/shared/core
tools/                     # dev scripts (seed db, replay a run, dump metrics)
```

## Boot order (server)

Strict, because half of these have real dependencies:

```
1. Config validation      — assert every config table matches its schema; fail loud at boot
2. DataService            — DataStore handles, write-behind queue started
3. TelemetryService       — buffer up; it must be alive before anything can emit
4. EconomyService         — ledger warm, config pulled from backend (falls back to local defaults)
5. RunService_            — creates the run, assembles the level from seed
6. EntityService          — spawn budget computed, entities created
7. CombatService, LootService, MovementGuard
8. ReplicationService     — starts sending snapshots
9. DirectorService        — first briefing request fires async; run does not wait on it
10. TickService.start()   — the loop begins
```

Nothing between 1 and 9 may block on network I/O. `DirectorService` and the economy config pull are fire-and-forget with local defaults ready.

## The tick

One loop drives the server. `TickService` is an accumulator on `RunService.Heartbeat`:

```lua
local TICK = 1/20  -- 50 ms
accumulator += dt
while accumulator >= TICK do
    accumulator -= TICK
    tickIndex += 1
    EntityService:Step(tickIndex, TICK)       -- pure sim via core/sim
    CombatService:Step(tickIndex)             -- resolve queued fire requests
    History:Record(tickIndex, entities)       -- for lag compensation
    ReplicationService:Broadcast(tickIndex)   -- snapshot out
end
```

Fixed timestep is not a nicety here: lag compensation requires that tick N means the same thing on every machine, and deterministic simulation is what makes the pure-core tests meaningful.

**Budget: 12 ms of the 50 ms tick at 40 entities and 4 players.** Measured and asserted in the load harness. If a tick overruns, the frame is logged with a per-phase breakdown rather than silently dropped.

## Module contracts

These signatures are fixed. Write against them; parallel work composes only if they hold.

```lua
-- core/net/Snapshot.luau
Snapshot.encode(tick: number, entities: {EntityView}, origin: Vector3Like) -> buffer
Snapshot.decode(b: buffer) -> { tick: number, entities: {EntityView} }
Snapshot.MAX_BYTES = 900   -- hard assert on encode

-- core/net/History.luau
History.new(capacity: number) -> History          -- capacity = 20 ticks = 1s
History:record(tick: number, entities: {EntityView})
History:rewind(targetTime: number, now: number) -> {EntityView}?   -- nil if out of window

-- core/sim/Budget.luau
Budget.plan(params: {budget: number, zone: string, caps: {[string]: number}, rng: Rng})
  -> { spawns: {{kind: string, at: Vector3Like}}, spent: number }

-- core/director/Clamp.luau
Clamp.apply(proposal: unknown, bounds: DirectorBounds) -> DirectorDecision   -- never errors
                                                                            -- always returns a valid decision

-- core/economy/Ledger.luau
Ledger.apply(state: LedgerState, entry: LedgerEntry) -> (LedgerState, boolean)
  -- boolean = false when idempotencyKey was already seen (no-op, not an error)

-- core/discovery/Rating.luau
Rating.update(current: Rating, outcome: RunOutcome) -> Rating
```

Every one of these is a pure function of its arguments. Every one has a test file.

## Client/server split

| Concern | Owner |
|---|---|
| Entity position, HP, state | **Server.** Client renders interpolated snapshots. |
| Local player movement | Client (Roblox owns it) + **server plausibility guard**. |
| Weapon fire outcome | **Server**, with client prediction of presentation. |
| Ammo count | **Server** authoritative, client predicts, reconciles on mismatch. |
| Loot contents, weight, currency | **Server.** Client never computes these. |
| Ragdolls, particles, camera shake, tracers, hitmarkers | **Client only.** Never replicated. |
| Objective state, run timer | **Server**, broadcast on change (reliable). |

The rule for presentation: the server says *what happened*; the client decides *how it looks*. Presentation never waits on a round trip.

## Configuration fan-out

Economy tunables are the one thing that changes without a code deploy. `EconomyService` pulls `GET /v1/config` at boot and every 10 minutes, with:

- local defaults compiled in (`config/Economy.luau`) used if the fetch fails,
- a schema validation pass that rejects the whole payload if any field is out of range,
- a monotonic `version` field; older versions are ignored (protects against out-of-order responses).

This is deliberately the only remotely-mutable surface. Everything else ships with the place.
