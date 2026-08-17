# Backlog

Atomic, dependency-ordered tasks. Each names its dependencies, the files it touches, and a **machine-checkable** acceptance test. A task is done when its acceptance command passes — not when the code looks right.

Work top to bottom. Tasks at the same indent level with no shared dependency can be done in any order or in parallel.

Legend: `[ ]` todo · `[~]` in progress · `[x]` done · **⚠ human** = needs a person

---

## M0 — Skeleton ✅ complete (except M0-8, human)

- [x] **M0-1** Toolchain. rokit 1.2.0 installed; `rokit.toml` pins `rojo@7.7.0`, `lune@0.10.5`. `git init` + `.gitignore` done.
  *Verified:* `rojo --version` → 7.7.0, `lune --version` → 0.10.5. Note: rokit gates new tools behind `rokit trust <tool>`, which is interactive — script it explicitly.

- [x] **M0-2** Rojo project. `default.project.json` maps `src/shared`→ReplicatedStorage.Shared, `src/server`→ServerScriptService.Server, `src/client`→StarterPlayerScripts.Client.
  *Verified:* `rojo build` exits 0, produces a place file.

- [x] **M0-3** Test runner. `tests/framework.luau` + `tests/init.luau` (auto-discovers `*.spec.luau`). describe/it/expect, deepEqual, approx, toThrow, `never()`, todo.
  *Verified:* `lune run tests` → exit 0 clean, exit 1 with a failing spec present.
  **Divergence from spec:** the original acceptance called for "one deliberately failing test" living in the suite. A permanently-red suite means green carries no information, so the failure-detection check moved to `tools/selftest.luau` (13 checks) and the suite stays green. Unimplemented work is tracked with `todo`, which reports as pending and never fails.

- [x] **M0-4** Core module stubs. 21 modules across net/sim/director/economy/discovery/anim/level/util, all `--!strict` with real type contracts.
  *Verified:* `lune run tests` → 43 passed, 24 todo, exit 0.
  **Divergence:** `util/{Rng,Ring,Result,Clock}` and `core/Types` are fully implemented rather than stubbed — everything depends on them, they're ~60 lines each, and a seeded RNG is required by every deterministic test. They have real specs (38 assertions).

- [x] **M0-5** Config tables + validator. 8 config modules; `tools/validate-config.luau` checks types, ranges, and cross-invariants.
  *Verified:* passes clean; rejects `SNAPSHOT_MAX_BYTES=1200` (two ways), `INTEREST_MAX=120` (exceeds packet capacity), `HISTORY_TICKS=2` (shorter than the lag-comp window). Also catches an insurance config that would make insurance a faucet, and non-monotonic weight tiers.

- [x] **M0-6** Backend skeleton. Fastify 5 + TS strict + vitest. `/healthz`, `/readyz`, `/metrics`, structured 404/500. `docker-compose.yml` with postgres:16-alpine.
  *Verified:* `npm run typecheck` clean, 8 vitest tests pass, server boots and returns `{"status":"ok","version":"0.1.0"}` over HTTP on 8787.
  **Blocked:** Docker Desktop was not running, so Postgres was not started. Nothing in M0 depends on it — `/healthz` deliberately does not touch the DB so a DB outage never triggers a restart. **Start Docker Desktop and run `docker compose up -d` before M3.**

- [x] **M0-7** CI. `.github/workflows/ci.yml` — `luau` job (encoding, config, selftest, tests, rojo build, artifact upload) and `backend` job (typecheck, test, build). rokit installed from the pinned release rather than a third-party action.
  *Not yet verified on GitHub* — no remote configured. Verify on first push.
  **Divergence:** no `sim` job; `sim/` doesn't exist until M3. Added rather than omitted: an encoding guard (below).

- [x] **M0-9** *(added during M0)* `tools/check-encoding.luau` — fails if any `.luau` file carries a UTF-8 BOM. Added after hitting the BOM problem twice: PowerShell 5.1 has no `utf8NoBOM`, and Luau's error points at line 1 of the victim file rather than at whatever wrote it.
  *Verified:* passes across 41 `.luau` files; wired into CI.

- [ ] **⚠ human M0-8** Create the Roblox experience, note universe + place IDs, enable *Allow HTTP Requests* and *Studio Access to API Services*. Put IDs in `backend/.env`.

### Verified in Studio during M0

Relative string requires (`./Sibling`, `../dir/Module`, chained across subdirectories) work identically in Roblox and Lune. `@self/` works **only** in Lune. This is the require convention for all of `src/` — recorded in CLAUDE.md.

---

## M1 — Netcode core

**Pure core: complete.** 181 assertions green, benchmark and budget check in CI.
Measured numbers in [docs/metrics/m1.md](../docs/metrics/m1.md). What remains is
adapter code, which needs Studio.

- [x] **M1-1** `core/net/Quantize.luau` — position int16 on a 0.05 grid, yaw uint8, unit uint8.
  *Verified:* 10k-sample roundtrip within 0.025 studs and 0.703°; grid multiples exact; saturates at the int16 boundary instead of wrapping; NaN rejected. Added `yawDelta` for shortest-arc interpolation and `snap*` helpers so delta comparison happens on quantized values rather than floats.

- [x] **M1-2** `core/net/Snapshot.luau` — 5 B header + 11 B/entity, 900-byte assert.
  *Verified:* identity roundtrip at 1/40/81 entities; **896 bytes at 81**; 82 refuses; truncated and short packets rejected rather than read as garbage.

- [x] **M1-3** Delta compression + keyframes.
  *Verified:* 200-tick replay reconstructs exactly what full snapshots would carry; sub-grid jitter costs nothing; delta is <½ keyframe size in steady state.
  **Divergence:** the plan specified a 4-byte changed-entity bitfield indexed by baseline position. That requires client and server to agree on entity ordering — fragile, and unnecessary since every record already carries its own uint16 id. A delta is simply the changed subset. The keyframe flag went into the spare high bit of the count byte, which keeps the header at the documented 5 bytes and capacity at the documented 81.
  **Also:** deltas never remove entities. Omission from an unreliable packet is indistinguishable from packet loss, so despawns travel on the reliable channel.

- [x] **M1-4** `core/sim/EntityState.luau` + `core/sim/Steering.luau`.
  *Verified:* transition table enforced and `death` terminal (corpses cannot stand up); overkill clipped so a kill credits exactly once; seek converges; 20 co-located entities separate to >0.5 studs; avoidance ignores obstacles behind; `keepDistance` dead band stops Lancer jitter.
  **Divergence:** `create` takes a `Stats` parameter instead of reading config, keeping core free of any dependency the adapter owns. Added `applyDamage` and `isAlive`, which `CombatService` needs.

- [x] **M1-5** `core/net/History.luau` — record + rewind.
  *Verified:* exact tick, interpolated between ticks, window clamping at the exact boundary, buffer-underrun clamping, wraparound at 100 pushes into a 20-frame buffer. Entities that spawned *or despawned* mid-window remain hittable — dropping them would silently eat legitimate hits.
  **Divergence:** `rewind` returns a result table (`entities`, `requestedTime`, `actualTime`, `clamped`) rather than a bare list, because `CombatService` needs `clamped` to emit the rewind-overrun metric named in docs/03.
  **Note:** frames are deep-copied on record. Aliasing the live simulation would make every rewind silently agree with the present — lag compensation would look like it worked while doing nothing.

- [x] **M1-6** `core/sim/DamageModel.luau`.
  *Verified:* falloff boundaries, monotonicity across 0–200 studs, degenerate `start == end` config handled as a step rather than a divide-by-zero, negative distance/damage guarded.
  **Divergence:** armor saturates at 0.95. Total immunity is an unwinnable softlock, so no config or buff stack can reach it.

### Adapters — verified in a live Studio session ✅

Rojo synced (49 scripts), server and client bootstrapped clean, all measurements
taken through `ServerStorage.DeepcacheDiagnostics`. Numbers in
[docs/metrics/m1.md](../docs/metrics/m1.md).

**Three findings that only running it could surface:**

1. **Cross-service relative requires do not resolve.** Every adapter used
   `require("../shared/...")`, which compiles and syncs but fails at boot —
   `src/shared` maps to ReplicatedStorage while server code lives under
   ServerScriptService, and relative paths cannot cross services. Fixed with
   Instance requires; `check-syntax` now lints it; CLAUDE.md documents it.
2. **The command bar has its own module registry.** `require`ing a service from
   the MCP bridge returns a fresh idle copy reporting zero ticks while the
   server runs, and `_G` does not cross either. Added
   `services/Diagnostics.luau`, a BindableFunction bridge registered from the
   running context — the verification hook every later milestone needs.
3. **Corpses were reaped one tick after death** (reap clock derived from
   `spawnedAtTick`). The client never saw the `death` state and a shot fired
   just before a kill had nothing to rewind onto. Moved the rule into
   `core/sim/EntityState` (`markDeath`/`shouldReap`) with 5 regression tests.

**Spec correction:** the 6 KB/s bandwidth budget was unsatisfiable alongside a
32-entity interest cap (worst case 6.97 KB/s; only 27 entities fit 6 KB/s).
Raised to 8 KB/s and cross-checked in `validate-config`; the benchmark now reads
the constants from config instead of redeclaring them.

Additional pure-core modules extracted so the adapters stay thin, all tested:
`core/net/Interest`, `core/sim/FireValidation`, `core/sim/MovementGuard`,
`core/sim/Raycast`.

- [x] **M1-7** `server/services/TickService.luau` — 20 Hz accumulator, per-phase timers, p50/p95/p99 gauge, overrun logging, catch-up capped at 5 steps/frame.
  *Verified:* 502 ticks with a player connected, **p95 1.16 ms of a 12 ms budget, 0 overruns**.

- [x] **M1-8** `server/services/EntityService.luau` — owns the entity table, steers via `core/sim`, records history, reaps corpses.
  *Verified:* 40–300 entities spawned and stepped; history buffer holds 20 contiguous frames; corpse lifetime correct after the fix above.

- [x] **M1-9** `server/services/ReplicationService.luau` — per-client interest selection, keyframe/delta scheduling, despawn batching, bandwidth sampling.
  *Verified:* **6.10 KB/s measured** with 40 entities all chasing one player (worst case), against the corrected 8 KB/s budget.
  **Documented tradeoff:** the server assumes every delta arrived. A lost delta leaves entities that then stop changing stale until the next keyframe (≤1 s). Per-client acknowledgement would cost an uplink message per tick per client to fix a one-second cosmetic issue.

- [x] **M1-16** `src/server/smoke/TickBench.luau` — in-engine tick benchmark and entity-count sweep.
  *Verified:* budget breaks between 120 and 200 entities; **4× headroom at the 40-entity design point**. `sim` scales super-linearly, matching the documented O(n²) neighbour loop.

- [x] **M1-10** `core/net/Interpolator.luau` — render-delay buffer, adaptive delay, 80 ms extrapolation cap.
  *Verified:* a single dropped packet is invisible (interpolates straight through the gap); extrapolation freezes at exactly 80 ms and stays frozen 100 s later; out-of-order and duplicate-timestamp arrivals dropped; adaptive delay clamped to [0.10, 0.20]; jitter p95 measured from observed inter-arrival times.
  **Note:** an entity present in only one frame of a bracketing pair is carried rather than dropped — dropping it makes a newly visible entity flicker for one frame.

- [x] **M1-11** `client/controllers/EntityRenderer.luau` — pooled parts, interpolated transforms, adaptive render delay, corrupt packets dropped rather than crashing.
  *Verified:* renders entities from live snapshots; the client-side aim used for every combat test came from the rendered (interpolated) position.
  *Remaining for M1-17:* two simultaneous clients, which needs a second human.

- [x] **M1-12** `server/services/CombatService.luau` — all 8 validation steps, cheapest rejection first; requests queued and resolved at a tick boundary.
  *Verified in-engine:* **5/5 hits on a static target**, 22 damage matching config, 39.6 on a headshot (×1.8), overkill clipped to exactly the remaining 20 HP on the killing blow, ammo exhaustion rejected correctly at magazine 14. Added a 20-entry resolution trace ring — without it a shot that "just misses" gives nothing to debug, since every metric reads clean when no rule rejected it.
  **Design note:** entity hit detection is pure ray-sphere math (`core/sim/Raycast`), not an engine raycast — entities have no server Instance. The engine raycast finds the nearest wall only, and an entity hit must be nearer than it.

- [x] **M1-13** `client/controllers/PredictionController.luau` — predicts presentation, reconciles state, tracks RTT and mispredict rate.
  *Verified:* fire → authoritative result round trip at p50 99 ms in a local session.
  **Design note:** M1 predicts "miss" locally and lets the server confirm hits, so a mispredict can never show a hitmarker for a shot that missed. Local hit prediction needs the client-side entity positions the renderer already holds — an M2 refinement.

- [x] **M1-14** `core/sim/MovementGuard.luau` + `server/services/MovementGuardService.luau`.
  *Verified:* a single spike does not trigger; a sustained pattern escalates to correction; score decays at 1.0/s and returns to clean; penalty scales with how far past budget the frame went; a non-finite position kicks immediately; the guard uses the caller's max speed, so a weight-slowed player is not flagged for moving normally.

- [x] **M1-15b** *(added)* `tools/check-syntax.luau` — compiles every `.luau` file with the Luau compiler.
  *Why:* adapter code cannot be required by the test suite (Roblox globals) and `rojo build` packages source without parsing it. Without this, a syntax error in a service sits undetected until someone opens Studio. Wired into CI; 66 files.

- [x] **M1-15** `tools/loadtest/serialize.luau` — benchmark + budget assertion, wired into CI.
  *Verified:* 11.06 bytes/entity, 896 B at the packet max, **1.87 KB/s per client** projected at the 32-entity interest cap against a 6 KB/s budget. Fails CI if the format regresses past either budget.

- [ ] **M1-16** `tools/smoke/TickBench.luau` — spawn N entities, run 600 ticks, report p50/p95/p99 + per-phase.
  *deps: M1-9 · Accept:* via MCP `execute_luau` at 60 entities — **p95 < 12 ms**. Quote the output in the commit.

- [x] **M1-17a** Injected-latency test (single client, driven through the MCP bridge).
  *Verified:* 6/6 hits on a **moving** target at 0, 150, and 300 ms. At 300 ms the server rewinds exactly 250 ms (`LAGCOMP_WINDOW`) and clamps every shot — the documented design bounding how far a high-ping player may shoot around a corner.
  **Caveat recorded:** a Hauler moves 3.2 studs in 400 ms against a 3.4-stud hitbox, so hit rate alone cannot separate "compensation worked" from "forgiving hitbox". The rewind-age and clamp counters are the real evidence. A sharper test (fast/small target plus a no-compensation control) is queued for M2.
  **Found while measuring:** ammo exhaustion masquerading as latency failure (added a `reload` diagnostic), and a misleading `rewindClamped` trace field sourced from the wrong layer.

- [x] **M1-18** *(added)* Client reconstruction fix.
  `EntityRenderer` rebuilt its delta baseline by sampling the interpolator, which extrapolates past the newest frame — so deltas were applied to a baseline the server never had, and rendered entities froze at positions they had not reached. **Every prior combat test used a static target, which hid it entirely** (extrapolating zero velocity is a no-op). Fixed to keep the raw authoritative state; two regression tests added.

- [ ] **⚠ human M1-17b** Two-client test — two players in one session, both seeing smooth entity motion and correct hit registration. Needs a second person.

---

## M2 — Playable loop

- [x] **M2-1** `core/level/Assemble.luau` — seeded graph walk, connector matching, constraint check (pads reachable, no repeat within 2 hops, area ±15%).
  *Verified:* **1,000/1,000 seeds valid**; same seed reproduces the layout exactly; 11 broken-catalogue mutations each fail with a named reason, against an unmutated control that passes. Constraints are re-derived from the placed geometry in the spec rather than read back from the generator, and 9 corruption tests prove `validate` rejects what it claims to check. Numbers in [docs/metrics/m2.md](../docs/metrics/m2.md).
  **Divergence — module count is searched, not drawn.** The spec's two constraints (counts in fixed ranges, area within ±15%) are not independent: module areas span 1024–10752 studs², so a blindly drawn count misses the area window on ~13% of seeds. The walk now measures its own achieved mean area on the first pass and recomputes the count from it. No tuning constant, counts still land in 8–12 / 4–6.
  **Divergence — `zones` list, not a single `zone`.** Corridors serve all three bands; one zone each would mean authoring four dedicated rooms per band purely to satisfy the no-repeat rule. Mirrors `Enemies.zones`.
  **Divergence — `area` is derived** (`width * depth`), not authored, so the two cannot drift. `Layout.padPositions` became `Layout.pads` carrying zone and module index, which is what the pad-open schedule needs.
  **Added:** at most one connector per face (the generator identifies a mating door by face, so two would be ambiguous); connectors sit at face midpoints, which is now an authoring constraint on the Studio geometry — an off-centre doorway lines up in the maths and visibly not in the level.
  **Found while measuring:** three earlier versions produced *valid* layouts on every seed while filling levels to only 87% of the requested area. Correctness tests cannot see that, so `tools/loadtest/assemble` asserts mean area and layout variety alongside validity, and runs in CI.

- [x] **M2-2** Room modules (12 for M2, 24 by M7) with tagged connector attachments.
  *Data:* `src/shared/config/Rooms.luau` — 12 modules, 2–4 tagged connectors each, one pad room per zone, plus geometry constants. `validate-config` asserts connector counts and sizes, one connector per face, 4-stud grid alignment, exactly one pad per zone, ≥3 modules per zone, and that `targetArea` is reachable at a legal module count. *Verified:* all five rejection cases fire (table in docs/metrics/m2.md).
  *Adapter:* `server/services/LevelService.luau` builds floors, walls, doorways with jambs and lintels, pads, spawn points and the drop point from a `Layout`, and is the only place core's `{x,y,z}` becomes a `Vector3`.
  *Verified in a live Play session:* seed 1 → 17 modules, **149 parts, built in 5 ms**, pads at **60 / 236 / 532 studs**, and a **sealed check with 0 leaks over 17 modules** — a ray from each module centre toward all four faces must hit geometry, which is the only way to catch a doorway-arithmetic bug that leaves the layout data looking perfectly valid.
  **Found in Studio — a pad on the drop point.** The Perimeter pad could land on module 1, so players dropped straight onto the 3:00 extraction. Roughly one seed in four. Invisible to the pure-core suite: the layout was valid and "pad reachable" was satisfied by a distance of zero. Fixed in `Assemble` and asserted in both specs.
  **Added — the default Baseplate and SpawnLocation are suppressed, not deleted,** and restored by `clear`. The Baseplate's top surface is at exactly y = 0, where module floors go, so leaving it z-fights across every floor.
  *Remaining for M7:* authored art per module. The boxes are placeholder geometry with a zone tint; the look pipeline is M7-5.

- [x] **M2-3** Coarse waypoint nav graph built at assembly; `core/level/Path.luau` A* over it (not `PathfindingService`).
  *Verified:* **every waypoint reachable from the entrance in 1,000/1,000 layouts**; **0 of 94,737 pairs disagree with an independent Dijkstra**; routes are contiguous graph edges with no repeated node; symmetric costs both directions; degenerate inputs (same node, out-of-range id, disconnected graph) return nil rather than throwing or looping. Studio matched Lune exactly over 47,205 pairs. Numbers in [docs/metrics/m2.md](../docs/metrics/m2.md).
  **Spec correction — "within 1.4× euclidean" is not achievable and never was.** Two rooms either side of a shared wall are 60 studs apart in a straight line and several hundred studs of walking; measured worst is 9.53×. That is the level's geometry, not the search. The number survives as a **median and mean** bound (measured 1.33 and 1.36) and is joined by the check it was really a proxy for — optimality against Dijkstra — plus a 12× ceiling to catch a layout that has folded in half. Ratio statistics alone cannot detect a lazy search: a uniformly 20%-too-long path would pass a 1.4× median.
  **Found while measuring — levels are trees.** 17 connections for 18 modules, no loops, so every route backtracks. Free loop closure was implemented, measured at **0 loops across 300 layouts** (face-midpoint connectors almost never leave two unused doors coincident), and removed rather than kept as decoration. Real loops need placement steered to mate against two doors at once, which changes level topology — a design call, flagged in docs/01 rather than built.
  *Remaining for the adapter:* entities following these routes lands with M2-4.

- [x] **M2-4** Full enemy roster from `Enemies.luau`, behaviors wired to `Steering`.
  *Verified in Studio* — one of each spawned in a ring at 70 studs, live tick loop, 5 s:

  ```
  Skitter   SwarmNearest  state=attack dist 70.0 ->  4.0 (-66.0)  shielded=true
  Sentry    Static        state=idle   dist 70.0 -> 70.0  (+0.0)
  Hauler    PushObjective state=move   dist 70.0 -> 29.6 (-40.4)  speed=8.0
  Lancer    KeepDistance  state=attack dist 70.0 -> 54.7 (-15.3)
  Warden    ShieldNearby  state=move   dist 70.0 -> 22.4 (-47.6)  speed=10.0
  Reclaimer HuntHeaviest  state=move   dist 70.0 -> 60.9  (-9.1)  speed=16.0
  ```

  Each matches its row: the Sentry never moves (area denial, must be flanked), the Lancer stops at 54.7 and attacks from range rather than closing, the Hauler lumbers at 8, and `shielded=true` on the Skitter is the Warden actively protecting it.
  **Nav pathing (closes out M2-3's adapter half):** a Skitter spawned in `Vault_Core` — module 9, hop 8, **414 studs away** — closed **290 studs in 14 s at full speed with 0 stalled samples**, routing through eight rooms of doorways. Steering alone would have pressed it into the first wall; the probe reports the per-second trace precisely so "stuck on geometry" and "walking the long way round" cannot be confused.
  **Added — routes are cached and recomputed on room transition,** not per tick and not on a timer. A stale route is only wrong once an endpoint changes room, so that is exactly when it is rebuilt: a few A* calls per second across the whole population.
  **Added — `Warden` shields are queried at the moment damage lands** (`EntityService.damageMultiplierFor`), not cached, so a Warden dying mid-fight stops protecting its escort on the same tick. Shields do not stack.
  **Added — `HuntHeaviest` reads carried weight** through the target provider, falling back to nearest before anyone is carrying anything.

- [ ] **M2-5** Remaining three weapons. Slug as a server-simulated projectile entity; Arc as per-tick continuous validation.
  *deps: M1-12 · Accept:* test — Arc ramp curve; Slug travel/drop math. Studio — all four fire and deal damage.

- [x] **M2-6** `LootService` — spawn tables by zone, pickup/drop, weight → speed multiplier, claim tokens.
  *Pure core (`core/sim/Loot`) verified:* tier boundaries exact at every edge (20 free, 21 not); 100 simultaneous claimants on one item yield exactly one winner; Vault rarity curve within 2 points over 20k rolls; `overseer_shard` never drops in the Perimeter.
  *Adapter verified in Studio* — the weight ladder, measured by taking items one at a time:

  ```
  take cell_pack      4kg -> carried= 4kg WalkSpeed=16.00   (x1.00)
  take servo_array   16kg -> carried=20kg WalkSpeed=16.00   (x1.00, boundary)
  take optics_module  9kg -> carried=29kg WalkSpeed=14.72   (x0.92)
  take cell_pack      4kg -> carried=42kg WalkSpeed=13.12   (x0.82)
  take optics_module  9kg -> carried=61kg WalkSpeed=11.20   (x0.70)
  grab from 151 studs away -> false tooFar
  ```

  Every tier lands on the exact multiple of the 16-stud base. The reach rule is checked server-side against the item's recorded position: a `ProximityPrompt` is client-side convenience, not a security boundary.
  **Found in Studio — extraction did not clear the carry.** `Run.tryExtract` zeroed the run's ledger while `LootService` still held the items, so an extracted player kept the movement penalty, kept reporting 91 kg to the enemy budget, and could have banked the same loot at a second pad. Added `LootService.bank`, distinct from the `scatter` death path.

- [x] **M2-5** Remaining three weapons. Slug as a server-simulated projectile entity; Arc as per-tick continuous validation.
  *Pure core* — `core/sim/Ballistics`: Arc ramp (compounding, capped, decaying faster than it builds) and Slug travel/drop (3.11 studs over 120 at 180 studs/s, g=14), closed form pinned against the integration step the server ticks.
  *Adapter verified in Studio:*

  ```
  Sidearm  hitscan     3 req at 16.9 studs ->   66.0 damage   (22 x 3, exact)
  Carbine  hitscan     3 req at 16.9 studs ->   51.0 damage   (17 x 3, exact)
  Slug     projectile  3 req at 16.9 studs ->  136.0 damage   (68 x 2 landed)
  Arc      beam       40 req at 16.9 studs ->  156.2 damage   (ramped)
  requests=49 hits=48 rejectedRate=1
  ```

  **Fixed — the Carbine could not fire its own burst.** The rate bucket held 2 tokens while the weapon fires 3-round bursts faster than its sustained rate, so the third round of every burst was rejected as a rate violation. Capacity now covers `burst`. The exact 51 = 17 × 3 above is that fix.
  **Divergence — projectile and beam skip lag compensation, deliberately.** A Slug is an object in the world, so a hit is decided by where the projectile *is*, not by rewinding to where a target *was*; an Arc is contact evaluated this tick. Rewinding either answers a question nobody asked. Only hitscan rewinds.
  **Added — a shared `damageEntity` path** for all three, so falloff, headshot and the Warden shield cannot drift between weapons. Beams take no headshot multiplier: a bonus flickering as the beam drifts across a hitbox is noise, not skill.
  **Added — `CombatService.submit`,** so diagnostics probes travel the identical queue/rate/ammo/rewind path a real request does. A probe that bypassed the queue would be testing a path no player can reach.
  **Found while measuring — the probe was shooting a wall.** The first run read 0 damage for both hitscan weapons and looked like a broken adapter. The trace ring said `wall=25.4 (Modules.001_Junction_Cross.Wall_N_Solid)`: the target spawned 40 studs away, through the room's north wall, and the wall check was doing its job. Slug and Arc appeared to "work" only because the Hauler walked closer during their longer probes. The probe now measures the clear distance first. This is exactly the failure the M1 trace ring was added for — every metric read clean because no rule had rejected anything.

- [x] **M2-7** `RunLifecycleService` — 12:00 timer, pad open schedule, extraction, death, individual extraction.
  *Renamed* from `RunService_`: the trailing underscore existed only to dodge the clash with Roblox's `RunService`, and a descriptive name does that better.
  *Verified in Studio — a full run start to finish:*

  ```
  LOOT     6 items, 46 kg, 4749 credits, speed x0.82
  CLOCK    t= 196s  padOpened Perimeter
  EXTRACT  pad=Perimeter  carried 46 kg, 4749 credits -> 0 kg, 0 credits  WalkSpeed=16.00
  RUN      extracted=1 died=0 active=0 banked=4749 complete=true reason=squadResolved
  ```

  Pure core covers the rules (individual extraction, budget headcount never scaling down, clock expiry treated as death); this drives them from the tick loop, in a phase placed **after** combat and movement so extraction and death see the same tick's outcomes.
  **Found in Studio — an empty run resolved before it began.** The server creates the run at boot, before the first client connects, so `activeCount == 0` fired `squadResolved` on tick one; every later arrival was then refused because the run was over, leaving a level full of loot nobody could extract from. `squadResolved` now requires that someone actually dropped. Regression test added.
  **Found in Studio — the roster raced the boot order.** A `PlayerAdded` landing before the run existed dropped that player permanently. The tick phase now reconciles the roster instead of trusting event ordering.
  **Found in Studio — the movement guard kicked server-initiated teleports.** The guard cannot tell a server reposition from a client one by position alone, so extraction and respawn moves read as the exact signature it exists to catch. Added `MovementGuardService.forgive`, and latched the kick so one incident is one kick rather than a wall of identical warnings every tick while the socket closes.
  **Also wired:** the guard's speed provider now uses the weight-derived speed rather than a flat 16, which the M1 comment had flagged as M2's job.

- [ ] **⚠ human M2-11** Informal 3-player playtest. Record what's confusing, what's boring, what's broken.

- [x] **M2-8** `core/sim/Budget.luau` + spawn director scaling formulas from [01 §Scaling].
  *Verified:* `timeRamp` and `headcountMul` checked against hand-computed values from the design doc (1.0 / 1.45 / 1.9 and 1.0 / 1.4 / 1.8 / 2.2), not against a re-implementation of themselves; spend never exceeds budget across 3,000 plan calls; leftover is always smaller than the cheapest remaining option, so "never exceeds" cannot pass by spending nothing; per-type caps and caps overrides respected; zone availability respected; identical for a fixed seed and varied across seeds; `spent` equals the exact sum of what was placed.
  **Divergence — `compute` takes `zoneMultiplier: number`, not a `Zone`,** and `PlanParams` gains a `roster`. Core cannot read config, so the zone multiplier and the enemy table arrive as arguments and the adapter owns the mapping. Same reasoning as M1-4's `Stats` parameter.
  **Added — the director multiplier is clamped here too,** even though M4's `Clamp` already bounds it. This is the last arithmetic before spawn counts; an unclamped multiplier turns a bad model response into an unplayable wave instead of a logged warning. A test asserts the bounds match `Schema.DEFAULT_BOUNDS` (duplicated rather than required, because `core/sim` depending on `core/director` would invert the layering).
  **Added — `timeRamp` clamps at the run length.** A run ticks past 12:00 while the last player extracts, and an unclamped ramp would keep raising the budget during exactly the moment the level should be emptying.
  **Added — loud failures for two adapter bugs that would otherwise hide:** no spawn points supplied, and a zero-cost enemy (which would make the spend loop non-terminating).
  *Not built:* `spawnPattern` (even / flank / chokepoint / hunt_heaviest) — spawn points are picked uniformly for now. The patterns are director-driven and land with M4.

- [x] **M2-9** `core/director/Fsm.luau` — BUILD→PRESSURE→SPIKE→LULL with the pacing curve.
  *Verified:* every state reached in a 36-tick run and the cycle runs in order; **no state re-entered within 3 ticks across 200 adversarial trials** driving health and quiet-time randomly to force oscillation; `spawnMultiplier` stays in `[0.6, 1.6]` and `threatTier` in `[1, 5]` over 2,000 ticks fed NaN health and NaN dt; per-tick deltas never exceed the schema's rate limits; the emitted decision always satisfies the schema; identical input sequences produce identical output.
  **Design added (docs/05 specified the FSM's role and bounds, not its transition table):** dwell floors per state, a critical-health escape to LULL from anywhere, and a boredom escape that skips ahead when nothing has happened for 75 s. The no-ping-pong rule is enforced explicitly by recording the tick each state was left, rather than being left to emerge from the dwell floors.
  **Found while testing — the lull was a lull in name only.** With the multiplier rate limited to ±0.25/tick, a 35 s LULL is two ticks, which is not enough to fall from the spike ceiling (1.6) to the lull floor (0.72): it bottomed out at 1.10, harder than BUILD. Every bounds test passed and the pacing curve was still wrong. Lull raised to 80 s so the curve can actually reach its floor, and the M2 exit criterion ("measurable lulls and spikes, not a flat line") is now asserted directly — range, standard deviation, and direction reversals across a run.
  *Not built:* barks. The FSM emits `""`; canned barks are M4-7, and a placeholder here would put unfiltered text on a path to a player. Objective params are empty — the per-objective ranges live in `Objectives.luau`, which core does not read, and M4-8 fills them.

- [x] **M2-10** HUD — timer, weight, HP, pad status.
  `client/controllers/HudController`. Clock (red under a minute), carried weight with its speed multiplier **and the design's own tier vocabulary** — "47 kg · x0.82 · committed" — because a number alone does not tell a player whether to drop something. Pad status shows which are open, or counts down to the next. Every value arrives from the server; the clock is interpolated between 1 Hz pushes purely so it ticks smoothly, and every push overwrites it. Two sources for one number is how a HUD ends up confidently lying.
  *Remaining:* ammo, which needs the M2-5 weapon adapter.

---

## M3 — Telemetry & dashboard

- [~] **M3-1** Event envelope types + ring buffer with 200-event/5 s flush and drop counters.
  *Pure core done* — `core/telemetry/Buffer.luau`. *Verified:* overflow drops the oldest and increments the counter; the buffer never grows past capacity over 10,000 pushes into a 100-slot ring; flush triggers on **both** conditions independently (200 events, or 5 s with a single event) and never on an empty buffer; a drain caps at the batch size and leaves the remainder queued.
  **Divergence — the envelope lives in `core/telemetry`, not `shared/net/Wire`.** `Wire` is the Roblox↔core boundary and is full of `Vector3` conversions; the envelope is plain data that has to be testable under Lune and serialisable to NDJSON. Putting it in `Wire` would drag engine types into the one payload that must never contain them.
  **Added — `seq` is assigned on push, not on flush.** The rollup worker detects loss by comparing max `seq` against event count, so numbering at flush time would renumber around a gap and hide exactly what it exists to reveal. A test asserts the gap survives: after 10 pushes into a 4-slot ring, the batch reads seq 7–10 with `dropped = 6`.
  **Added — `drain`/`commit`/`requeue` split.** The drop counter clears on `commit`, not `drain`, so a batch that fails to post can be retried without losing the count; `requeue` puts a failed batch back ahead of newer events and stays bounded when retries pile up.
  **Added — `Ring.shift`** for FIFO drain. The history buffer only ever reads by age, but draining oldest-first into a batch then clearing would lose anything pushed in between.
  *Adapter done* — `server/services/TelemetryService.luau`: NDJSON serialisation, HMAC-signed POST, the documented 1/2/4/8 s backoff, a circuit breaker, and a `BindToClose` flush with a 3 s grace.
  **Added — `core/telemetry/Hmac.luau`,** SHA-256 and HMAC-SHA256 in pure Luau. Roblox has no hashing primitive and docs/04 requires both a signed batch and a pseudonymous `pid = HMAC(userId, salt)`. Verified against the NIST vectors (empty, `abc`, 56-byte, 112-byte, one million `a`) and RFC 4231 cases 1, 2, 3, 6, 7, plus two values cross-checked against .NET. **Never against itself:** a self-consistently wrong hash would verify every signature locally and none on the backend, and would present as a network fault.
  **Added — a circuit breaker.** `HttpService` allows 500 requests/minute per server; a backend that is down must not spend that budget rediscovering the fact. Three consecutive failed flushes open it for 60 s.
  **Divergence — a failed batch is requeued, not dropped.** docs/04 says drop after four attempts. `Buffer.requeue` is already bounded and drops the oldest when full, so keeping the events costs nothing the ring was not going to cost anyway, and a transient outage stops being data loss.
  **Found while measuring — `queued` read zero during a retry.** The retry ladder takes 15 s, and for that whole window the ring is empty while the batch sits in limbo: a dashboard would have shown a healthy `queued = 0` with 200 events unaccounted for. Added a separate `inFlight` counter.
  *Verified in Studio with the backend deliberately down:* `HttpError: ConnectFail`, failures climbing 2 → 3, the breaker opening for 60 s, and **`dropped = 0`** — nothing lost while unreachable. That is most of M3-8's failure drill, ahead of schedule.

- [~] **M3-2** Emit every event in the [04 §Event catalogue] from its owning service.
  *Emitting:* `run.start`, `run.end`, `player.death`, `extract.success`, `loot.pickup`, `loot.drop`, `combat.fire`, `combat.hit`, `perf.tick`, `telemetry.dropped`, `server.shutdown`.
  *Remaining:* `player.spawn`, `extract.attempt`, `objective.*` and `director.*` (M4), `economy.txn` and `market.*` (M6), `anticheat.flag`. The assertion that a full run produces one of each cannot be written until those exist.
  **Note on `perf.tick`:** sampled every 30 s, not per tick. A per-tick event would be twenty events a second describing the cost of emitting events.

- [ ] **M3-3** Backend `/v1/ingest` — NDJSON, HMAC verify, per-line validation, partial-batch accept, `(run_id, server_id, seq)` dedupe.
  *deps: M0-6 · Accept:* vitest — valid batch, malformed line rejected while siblings commit, replayed batch inserts zero rows, 10k lines < 500 ms.

- [ ] **M3-4** Postgres migrations for all tables in [04 §Schema].
  *deps: M0-6 · Accept:* `npm run migrate` up and down cleanly; `idem_key` uniqueness enforced by a test that attempts a duplicate.

- [ ] **M3-5** Rollup worker — `run_summary`, `player_stats`, `loadout_pairs`.
  *deps: M3-4 · Accept:* vitest — run three times over identical input, output byte-identical (idempotency).

- [ ] **M3-6** `sim/` run simulator with the five archetypes.
  *deps: M3-3 · Accept:* `npm --prefix sim run generate -- --runs 2000 --days 30` completes; ingest reports 2000 `run.end` rows.

- [ ] **M3-7** Dashboard page at `/` — the charts listed in [04 §Dashboard].
  *deps: M3-5, M3-6 · Accept:* loads with simulated data, every chart renders non-empty.

- [ ] **M3-8** Failure drill: kill the backend mid-run, confirm gameplay continues and the drop counter appears in the next successful batch.
  *deps: M3-2, M3-3 · Accept:* documented in `docs/metrics/m3.md` with the counter value.

---

## M4 — OVERSEER

- [ ] **M4-1** `backend/src/llm/schema.ts` + `core/director/Schema.luau` from a shared `schema.json`. Sync test.
  *deps: M0-6 · Accept:* vitest + lune both assert field names and enum members match `schema.json`.

- [ ] **M4-2** System prompt `prompts/overseer.v1.md` — lore, whitelist with param semantics, voice, 4 worked examples (2 good, 2 bad).
  *deps: M4-1 · Accept:* `countTokens` ≥ 4200 (cache eligibility on Haiku 4.5), asserted in a test.

- [ ] **M4-3** `POST /v1/director/tick` — Haiku 4.5, `output_config.format`, `cache_control` on system, 1200 ms timeout, token logging.
  *deps: M4-2 · Accept:* vitest with a mocked client — happy path, timeout, 429, malformed JSON, empty body all return a valid response shape.

- [ ] **M4-4** `llm/fallback.ts` — balanced-brace JSON extraction from free text.
  *deps: M4-3 · Accept:* vitest — extracts from prose-wrapped JSON, nested braces, JSON inside a code fence; returns null on genuinely unparseable input.

- [ ] **M4-5** `core/director/Clamp.luau` — every rule in [05 §Clamping].
  *deps: M4-1, M2-9 · Accept:* **test with ≥20 malformed inputs** (null, `{}`, wrong types, out-of-range, unknown enum, missing fields, extra fields, nested garbage, huge strings) — all return a valid `DirectorDecision`, none throw.

- [ ] **M4-6** `DirectorService` — async tick, in-flight guard, circuit breaker (3 failures → 60 s open), apply at tick boundary.
  *deps: M4-3, M4-5 · Accept:* Studio smoke — tick timing unaffected during a director call; unplug backend → FSM continues, breaker opens, recovers.

- [ ] **M4-7** Bark filtering — `FilterStringAsync` + `GetNonChatStringForBroadcastAsync`, both pcall-wrapped, canned-bark pool (40 per intent).
  *deps: M4-6 · Accept:* Studio smoke — force filter failure, assert a canned bark displays and no raw text reaches the UI.

- [ ] **M4-8** Objective system — whitelist, cooldowns, param clamping, issue/complete events.
  *deps: M4-5, M2-7 · Accept:* test — cooldown respected; params clamped per-objective; unknown ID keeps the active objective.

- [ ] **M4-9** Comms HUD panel + threat-tier → lighting hook.
  *deps: M4-7 · Accept:* Studio — barks appear, threat tier 5 visibly shifts the post stack.

- [ ] **M4-10** A/B assignment by `hash(runId)`, arm recorded in `run.start`.
  *deps: M4-6, M3-2 · Accept:* over 1,000 simulated runs, arm split within 48–52%.

- [ ] **M4-11** Director metrics on the dashboard — latency, fallback rate, cost/run, A/B comparison.
  *deps: M4-10, M3-7 · Accept:* charts render; fallback rate reads < 3% over 200 runs.

---

## M5 — Matchmaking & discovery

- [ ] **M5-1** `core/discovery/Rating.luau` — Glicko-style update. *Accept:* test vs. hand-computed values; rd shrinks with play, grows with absence.
- [ ] **M5-2** `core/discovery/Bucket.luau` — bucketing + widening schedule. *Accept:* test — boundaries exact, no player in two buckets, 75 s triggers undersized start.
- [ ] **M5-3** Lobby place + queue UI. **⚠ human** to create the place. *Accept:* player can join/leave the queue.
- [ ] **M5-4** MemoryStore queue (sorted map per bucket) + CAS removal. *Accept:* Studio — two coordinators cannot claim the same entry.
- [ ] **M5-5** Lease-based coordinator election (10 s TTL). *Accept:* kill the holder, another takes over within 12 s; logged.
- [ ] **M5-6** Squad formation + `ReserveServer` + `TeleportAsync`. *Accept:* Studio — 2 players queue, land in the same reserved server.
- [ ] **M5-7** Backfill into in-progress runs (first 4 minutes). *Accept:* a queuer joins a running match.
- [ ] **M5-8** `sim/matchmaking.ts` — Poisson arrivals, populations 5–500, wait percentiles + spread. *Accept:* report generated; p95 < 30 s at λ=1/s.
- [ ] **M5-9** `core/discovery/Recommend.luau` — cosine + shrinkage (λ=10). *Accept:* test — shrinkage suppresses a 2-count pair; owned items excluded; cold start returns baseline.
- [ ] **M5-10** Recommender worker + `/v1/recommend/loadout`. *Accept:* endpoint returns 3 items with reason codes for a known pid.
- [ ] **M5-11** Offline eval script (time split, recall@3 vs popularity). *Accept:* `npm run eval:recommend` prints a comparison table; result recorded in `docs/metrics/m5.md` **whatever it says**.

---

## M6 — Economy

- [ ] **M6-1** `core/economy/Ledger.luau` — apply, idempotency set, deterministic key construction. *Accept:* test — duplicate key no-op; balance = sum over 10k entries; negative balance rejected.
- [ ] **M6-2** `DataService` write-behind queue (≤1 write/player/6 s, coalesced). *Accept:* test on the pure queue — coalescing correct, ordering preserved, flush on shutdown.
- [ ] **M6-3** Faucets + sinks + insurance. *Accept:* Studio — each reason code produces a ledger entry with the right sign.
- [ ] **M6-4** `core/economy/Controller.luau` — PI with all guardrails. *Accept:* test — converges from ±30%; daily cap; sample floor; clamps hold over 365 adversarial days.
- [ ] **M6-5** Nightly economy worker + `/v1/config` with version guard and schema validation. *Accept:* out-of-range config rejected wholesale; older version ignored.
- [ ] **M6-6** `EconomyService` config pull with compiled-in defaults. *Accept:* Studio — backend down at boot → defaults used, no error.
- [ ] **M6-7** Reconciliation job. *Accept:* over 2,000 simulated runs, zero mismatches.
- [ ] **M6-8** `core/economy/Market.luau` matching engine. *Accept:* test — price-time priority; partial fills; self-trade rejected; band rejected; **fuzz 100k orders conserves currency and items exactly**.
- [ ] **M6-9** Escrow + order lifecycle + abuse caps. *Accept:* test — item cannot be in escrow and inventory simultaneously; cancel returns exact escrow.
- [ ] **M6-10** Market UI. *Accept:* Studio — list, bid, fill, cancel all work.
- [ ] **⚠ human M6-11** Deploy backend (Fly.io/Railway), set env, point the published place at it. *Accept:* published place reaches the deployed backend.

---

## M7 — Presentation & writeup

- [ ] **M7-1** `core/anim/TwoBoneIk.luau`. *Accept:* test — reachable / exact / unreachable / degenerate; pole plane correct.
- [ ] **M7-2** `core/anim/StepPlanner.luau`. *Accept:* test — opposing legs never lift together; step commits only past threshold; body height tracks foot mean.
- [ ] **M7-3** Wire locomotion into `EntityRenderer` with the 4-tier LOD and a 24-raycast/frame cap. *Accept:* Studio — 40 entities, no popping at boundaries; raycast counter never exceeds 24.
- [ ] **M7-4** Ragdoll pool (12), collision group, impulse from hit direction, 8 s recycle. *Accept:* Studio — kill 20 entities in 2 s, pool recycles, no error.
- [ ] **M7-5** Zone lighting presets + 1.5 s transitions + threat-tier modulation. *Accept:* Studio — screenshots at each zone and at threat tier 1 vs 5.
- [ ] **M7-6** Inverted-hull outlines; `tools/genhulls.ts` build step. *Accept:* hulls generated offline; enemies readable at 100 studs against busy geometry.
- [ ] **M7-7** `LookController` `EditableImage` budget manager (8 cap, 2 reserved). *Accept:* Studio — 9th allocation refused cleanly, no error thrown.
- [ ] **M7-8** Audio pass — weapons, impacts, OVERSEER comms VO treatment, zone ambience.
- [ ] **M7-9** Remaining 12 room modules. *Accept:* `Assemble` still passes 1,000-seed validation.
- [ ] **M7-10** Client frame profiling at 40 entities. *Accept:* per-subsystem numbers recorded in `docs/metrics/m7.md`, total within budget.
- [ ] **⚠ human M7-11** Real playtest, 4+ players, full session. Record feedback.
- [ ] **M7-12** Postmortem. **Write section 3 (what broke) incrementally from M1 onward — do not reconstruct it at the end.**
- [ ] **M7-13** Demo video, 3–5 min: one run with the dashboard alongside.

---

## Running metrics log

Create `docs/metrics/` at M1 and append per milestone. Every number in [11-INTERVIEW-ARTIFACTS §Numbers to have memorized] lands here as it's measured. Do not defer this — numbers captured late are numbers captured wrong.
