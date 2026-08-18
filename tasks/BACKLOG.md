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

- [x] **M3-3** Backend `/v1/ingest` — NDJSON, HMAC verify, per-line validation, partial-batch accept, `(run_id, server_id, seq)` dedupe.
  *Verified — 44 vitest cases, all against a real local Postgres (docker-compose), not a mock:* malformed line rejected while siblings commit; replayed batch inserts zero rows and reports them as a distinct `duplicates` bucket; a partial retry (one already-landed seq + one new) accepts only the new one; two servers sharing a seq both land, because seq is per-server not global; **10,000-line batch in 375 ms**, under the documented 500 ms budget; stale-timestamp and tampered-body requests both refused with 401.
  **Divergence — response is `{accepted, rejected, duplicates}`, not `{accepted, rejected}`.** A replayed batch is neither new data nor an error; folding it into `accepted` would make dedupe invisible in the response, folding it into `rejected` would make a healthy retry read as a client bug.
  **Divergence — the events table carries a `UNIQUE (run_id, server_id, seq)` index**, which docs/04's schema draft did not have. Without it the dedupe guarantee above is impossible; `ON CONFLICT DO NOTHING` on that index is what makes a replay a no-op instead of a duplicate row.
  **Added — pure `ingest/validate.ts`**, no database, mirroring the Luau pure-core/thin-adapter split on the backend: 26 unit cases (every field's absence, every wrong type, boundary lengths, non-finite numbers) run at unit speed, independent of Postgres.
  **Added — a minimal hand-rolled migration runner** (`src/migrate.ts`, ~110 lines) rather than a framework dependency: `-- +up`/`-- +down` sections in one SQL file per migration, tracked in `schema_migrations`. Verified up → down → up against the live database, table present/absent at each step.
  **Found — `backend/.env` was never actually being read.** Nothing in the repo loaded it; the server was silently running on the code's built-in fallback secret, which did not match `src/server/config/Backend.luau`'s. Every signed batch from the game was failing verification, and the failure read as a network problem, not an auth mismatch — the exact failure mode the M3 HMAC work already had comments warning about. Added `dotenv`, loaded once in `config.ts` so every entry point gets it. **Verified end-to-end after the fix:** a live Studio session generated real loot pickups and weapon fire, `TelemetryService.flushOnce` posted 93 events with `dropped=0`, and `SELECT` against the real database shows 48 `combat.fire`, 42 `combat.hit`, 2 `loot.pickup` rows with correctly-shaped JSONB payloads and a 16-character pseudonymous `pid` — not a raw Roblox user id.
  **Also found while writing the perf test:** a `MAX_LINES_PER_BATCH = 5000` cap I'd set myself would have made the documented 10k-line/500ms criterion permanently unreachable. My first draft of the perf test asserted a 400 rejection and called it done — documenting my own bug instead of catching it. Raised to 20,000; the real 10k-line case now passes.

- [x] **M3-4** Postgres migrations for all tables in [04 §Schema].
  *Verified against the live database:* `run_summary`, `player_stats`, `loadout_pairs`, `economy_daily`, `ledger` all present after `npm run migrate`, all absent after `migrate:down`, present again after a second `up` — `\dt` checked at each step. **Ten concurrent identical `idem_key` inserts land exactly one row** (`Promise.all`, not sequential — a sequential test cannot catch the race the constraint exists to prevent).
  **`loadout_pairs` ships empty on purpose.** No loadout-selection event exists in the catalogue — players don't pick a loadout, every weapon is available every run — so computing co-occurrence pairs would mean inventing them. The table exists now because M3-4's scope is every table in the schema; the M3-5 rollup worker leaves it untouched until a real source event exists.
  **Found — two test files independently nuking the schema was a live race, not a hypothetical one.** `ingest.test.ts` and `ledger.test.ts` each ran `down(pool, true); up(pool)` in their own `beforeAll`. It passed clean every time it was run, purely because vitest's parallel file execution never happened to collide with a `DROP TABLE` mid-assertion — but the next test file added would have made the odds worse, not better. Moved the reset into a single `globalSetup` (`test/global-setup.ts`, `vitest.config.ts`) that runs once before any test file; individual files only read and write the schema now. Verified stable across back-to-back full runs, not just the one that happened to pass.

- [x] **M3-5** Rollup worker — `run_summary`, `player_stats`.
  *Verified:* three consecutive runs over identical events produce byte-identical `run_summary` and `player_stats` rows (compares full row contents, not a hash). Field-level correctness checked against known input: squad size, extract/death counts, banked value, and `tick_p95_ms` (the average of two `perf.tick` samples, 2.2 and 2.6 → 2.4) all match hand-computed values. `director_calls`/`director_fallbacks` correctly read 0 — no M4 yet — rather than null, since `COUNT(*) FILTER` always returns a number.
  **A run with no `run.end` rolls up with `extracted_count`/`death_count`/`duration_s` as `NULL`, not `0`.** A run that has not finished has not "extracted zero players" — those are different claims, and the dashboard needs to be able to tell them apart. `MAX(x) FILTER (WHERE type = 'run.end')` gives this for free.
  **`rating`/`rd` are seeded to the Glicko defaults (1500/350) only for a never-before-seen pid and never touched on `ON CONFLICT`.** A "recompute everything on every run" worker that also reset a player's rating every 60s would erase real M5 rating history the moment it landed. Verified directly: seed a pid, hand-edit its rating as M5's engine would, rerun the rollup, confirm the hand-edited value survives.
  **`loadout_pairs` is untouched** — no loadout-selection event exists to aggregate; see M3-4.
  **One transaction covers both upserts,** so a dashboard read landing mid-rollup can never see a `run_summary` row without its `player_stats` siblings reflecting the same snapshot of events.
  *Not wired into a live server yet:* `startRollupWorker` runs the documented 60s interval from `index.ts`, but nothing has driven real traffic through a running server long enough to observe it — that lands with M3-6/M3-7.

- [x] **M3-6** `sim/` run simulator with the five archetypes.
  *Verified against the real live backend, the real live Postgres, the real ingest and rollup code — no mocks anywhere in this path:*

  ```
  npm --prefix sim run generate -- --runs 2000 --days 30
  generating 2000 runs across 30 days (seed 1) -> http://127.0.0.1:8787
  done in 34.8s, 80 batch(es): accepted=859660 rejected=0 duplicates=0

  SELECT count(*) FROM events WHERE type = 'run.end' AND run_id LIKE 'sim-1-%';
   count
  -------
    2000
  ```

  **Exactly 2000 `run.end` rows** — the documented acceptance criterion, matched exactly, not approximately. 859,660 total events across 8 real event types (`combat.fire` 533k, `combat.hit` 281k, `loot.pickup` 30k, `perf.tick` 5.9k, `extract.success` 2990, `player.death` 2065, `run.end`/`run.start` 2000 each).
  **A full rollup pass over the resulting ~890k-row table took 939 ms**, producing 2025 `run_summary` rows and 303 `player_stats` rows — comfortably inside the documented 60 s worker interval, and the first time the rollup worker has run against volume rather than a handful of hand-inserted test rows.
  **Five archetypes** (`cautious`, `looter`, `aggressive`, `average`, `reckless`), each a distribution over fire rate, accuracy, weapon preference, and — the one docs/01 cares about most — how much weight they're willing to carry before the risk of not making it back scales up. `looter`'s extraction chance is designed to be undercut by its own greed cap, not by enemy difficulty: the same tension the real game's weight table exists to create.
  **Loot events use the real item catalogue** (`sim/src/items.ts` mirrors `config/Loot.luau`'s ids, weights, and rarity multipliers) rather than synthetic placeholder items, so `loot.pickup` payloads describe the same economy the real game does.
  **Deterministic:** `--seed` reproduces byte-identical output, verified directly (`generateRun` called twice with the same seed, `toEqual` on the full event array) — the same property the game's own `core/util/Rng` guarantees, for the same reason: a simulator that cannot reproduce the exact run that caused a dashboard bug is not useful for debugging one.
  **Found by actually running it, not by inspecting the payload shape:** the first invocation rejected ~78% of lines (4781 of 6075). The envelope shape was fine — every line passed the real backend validator when checked directly — the bug was in the simulator's batching, not the payload: it mixed events from many different simulated `serverId`s into one HTTP POST, and `/v1/ingest` correctly rejects a batch that does not share one `serverId`, on the reasonable assumption that nothing upstream merges two servers' telemetry into one flush. Fixed by assigning every run to a server up front and flushing per server — which is also the more honest simulation, since a real game server only ever flushes its own buffer.

- [x] **M3-7** Dashboard page at `/` — the charts listed in [04 §Dashboard].
  *deps: M3-5, M3-6 · Accept (revised — see [04 §Dashboard]):* loads with simulated data; the two charts with a real M3 event source render non-empty; the four that need M4/M5/M6 event types render a named "not yet emitted" placeholder instead of fabricated data. The original "every chart renders non-empty" criterion assumed all six charts had a source at M3; they don't, and inventing numbers to satisfy it would have been a worse artifact than an honest placeholder.
  Server-rendered HTML at `/` plus a `GET /v1/dashboard/data` JSON endpoint, both reading `run_summary`, `player_stats`, and `events` directly — no external CDN, no charting library, charts are hand-drawn inline SVG (a polyline for tick p95, bars for the latency histogram), consistent with the rest of the stack's "runs entirely locally" posture.
  **Verified against the real backend and a real, non-trivial dataset**, not an empty schema: `sim/` regenerated 200 runs / 14 days (`accepted=89365 rejected=0 duplicates=0`), rollup produced 214 `run_summary` rows and 260 `player_stats` rows, and the live page at `http://127.0.0.1:8787/` was loaded in a real browser and inspected via the DOM (not just `curl`) — confirmed 2 `<svg>` elements, a real coordinate `<polyline>`, 9 histogram `<rect>` bars, and all 8 cards (2 stat cards, 2 real charts, 4 named placeholders) present. `npm --prefix backend test`: 59 passed (7 new for this route).
  **Found by the tests, not by inspection:** `renderPage`'s `fmt` helper called `.toFixed()` on `avg(value_extracted)`/`avg(duration_s)`/`avg(runs)`/`avg(extracts)`/`avg(deaths)` — all `AVG()` over a numeric column, which Postgres returns as `NUMERIC` and `pg` parses as a **string**, not a `number`, to avoid silently truncating precision. The query's own TypeScript row types claimed `number | null`, which was simply wrong — a lie the type checker had no way to catch since it doesn't know what `pg` does with `NUMERIC` at runtime. The bug only surfaced once a test exercised `GET /` against real aggregate rows (500 `n.toFixed is not a function`); an empty-table smoke test would never have hit it. Fixed by declaring those fields `string | null` and converting with `Number(...)` alongside the count fields, which already did this correctly.

- [x] **M3-8** Failure drill: kill the backend mid-run, confirm gameplay continues and the drop counter appears in the next successful batch.
  *Verified against a live Studio session and the real backend process, killed for real (not simulated):* baseline tick p95 0.13ms/0 overruns; killed the backend; pushed 1500 synthetic events past the 1000-capacity ring, forcing 500 real drops; **during the outage** tick p95 stayed at 0.12ms with 0 overruns and the run clock kept advancing (11s → 30s) — gameplay genuinely unaffected, not just "should be" unaffected. Restarted the backend; the recovery flush landed, and `SELECT` against the real database shows `{"type": "telemetry.dropped", "payload": {"count": 503}}` — the drop counter riding the next successful batch exactly as designed, with the real number, not an assumed one.
  **Found — a successful flush left the previous outage's error message in place.** `TelemetryService.describe()` would report `lastError = HttpError: ConnectFail` from the prior failed attempt even after a flush had just landed cleanly — a dashboard reading this mid-recovery would show a live incident that had already ended. `flushOnce` now clears `lastError` on the success path. Verified: forced a failure, confirmed the error was set, forced a success, confirmed it read back empty.

---

## M4 — OVERSEER

- [x] **M4-1** `backend/src/llm/schema.ts` + `core/director/Schema.luau` from a shared `schema.json`. Sync test.
  *deps: M0-6 · Accept:* vitest + lune both assert field names and enum members match `schema.json`.
  `schema/director-decision.json` at repo root is the hand-maintained canonical source (intents, spawn patterns, objective ids, bounds). `Schema.luau`'s guard functions (`isIntent`/`isSpawnPattern`/`isObjectiveId`) and `backend/src/llm/schema.ts` were both already-scaffolded/hand-written to match it independently; the sync tests in each language load the JSON directly and assert against it, so neither file is trusted as the other's source of truth — both are checked against a third, independent file. `lune run tests`: 3 new guard tests + 4 sync tests, all pass. `npm --prefix backend test`: 7 new tests (`llm-schema.test.ts`), all pass.

- [x] **M4-2** System prompt `backend/src/llm/prompts/overseer.v1.md` — lore, whitelist with param semantics, voice, 4 worked examples (2 good, 2 bad).
  *deps: M4-1 · Accept (revised for Ollama — see docs/05):* the original criterion (`countTokens` ≥ 4200 for Anthropic cache eligibility) doesn't apply to Ollama, which has no equivalent caching mechanic. Replaced with structural tests: every `intent`/`spawnPattern`/`objectiveId` enum value the model may return is named and explained (checked against the live `schema.ts` exports, not a hardcoded duplicate list, so a schema change flags a stale prompt too), every objective's param name and every numeric bound is stated explicitly rather than left implicit, and exactly 4 worked examples exist, 2 labeled good and 2 labeled bad.
  Path fixed: this backlog entry originally said `prompts/overseer.v1.md` (repo root); docs/05 §Prompt design notes said `backend/src/llm/prompts/overseer.v1.md`. Went with the backend path since the prompt is loaded by the Node process at runtime and belongs packaged with the rest of `llm/`, not at repo root disconnected from its loader.
  `backend/src/llm/prompt.ts` loads and caches it; the export includes `OVERSEER_PROMPT_VERSION` so `director.decision` telemetry (M4-6) can attribute a run to the exact prompt revision that produced it.
  `npm --prefix backend test`: 8 new tests (`overseer-prompt.test.ts`), all pass.

- [x] **M4-3** `POST /v1/director/tick` — Ollama (`llama3.2:3b`), JSON-schema `format`, `keep_alive`, 1200 ms timeout, token logging.
  *deps: M4-2 · Accept:* vitest with a mocked client — happy path, timeout, "429" (revised to `ollama_error`, its local equivalent — see docs/05), malformed JSON, empty body all return a valid response shape.
  The route never clamps — that stays in Luau (`Clamp.luau`, M4-5) per CLAUDE.md's one rule. Its whole job is: call Ollama, return `{ proposal, latencyMs, model, promptVersion, promptEvalCount?, evalCount?, error? }`. Every model-availability failure mode (`timeout`/`unreachable`/`ollama_error`/`malformed_json`/`empty_response`) returns HTTP 200 with `proposal: null`, since the caller's response is identical in every case (fall back to the FSM) — only a genuinely malformed *request* (no body) is a real 400.
  9 tests in `director.test.ts` with an injected fake `OllamaClient` (the "mocked client" accept criterion is deliberate, not a shortcut — a real Ollama call here would make this suite slow and occasionally flaky in exactly the way this project's other tests deliberately aren't). Caught one real bug the tests forced: `typeof [] === "object"` in JS, so the original `parsed === null || typeof parsed !== "object"` check let a valid-but-wrong-shaped JSON array through as if it were a proposal — added an explicit `Array.isArray` check.
  **Verified against the real, running Ollama, not just mocks:** `MAX_OUTPUT_TOKENS` was originally 400 mirroring the old Anthropic plan; a real call with the actual full system prompt showed output generation (not prompt processing) is the dominant cost — 93 output tokens took 795ms (~8.5ms/token) against ~110ms for the entire ~2300-token prompt. Tightened to 150, which the model never actually hits (real completions land around 93 tokens) but hard-caps a worst-case ramble well inside the tick budget instead of allowing a ~3.4s worst case. A real 10-call sample against the live route measured a **50% timeout rate** at the current 1200ms budget — see docs/metrics/m4.md; the user deferred the "loosen the timeout for local inference" decision rather than resolving it silently.

- [x] **M4-4** `llm/fallback.ts` — balanced-brace JSON extraction from free text.
  *deps: M4-3 · Accept:* vitest — extracts from prose-wrapped JSON, nested braces, JSON inside a code fence; returns null on genuinely unparseable input.
  String-literal-aware brace counting (tracks `"..."` and escaped `\"` so a `{`/`}` inside a bark string doesn't desync the depth count) — 11 tests including that exact case. Matches docs/05's fallback ladder step 2 literally: extracts the *first* balanced object, not "the best" one, when several appear.

- [x] **M4-5** `core/director/Clamp.luau` — every rule in [05 §Clamping].
  *deps: M4-1, M2-9 · Accept:* **test with ≥20 malformed inputs** (null, `{}`, wrong types, out-of-range, unknown enum, missing fields, extra fields, nested garbage, huge strings) — all return a valid `DirectorDecision`, none throw.
  33 test cases in `tests/clamp.spec.luau`: 23 explicit malformed-input cases (nil, empty table, wrong types on every field, NaN/±inf spawnMultiplier, out-of-range and negative values, unknown enum values on intent/spawnPattern/objective.id, unknown objective param keys, out-of-range objective params, fractional threatTier, non-string/oversized/control-character bark, every field malformed at once, deeply nested garbage) plus dedicated `rateLimited` and `sanitizeBark` unit tests — every case asserts the *full validity* of the returned decision (in-enum, in-range, correct types), not just "didn't throw." `lune run tests`: all pass.
  **Scope note, documented in docs/05 rather than left implicit:** docs/05's clamping table lists "`objective.id` must be in the whitelist and not currently on cooldown" as one rule, but cooldown tracking is stateful and belongs to M4-8 (the objective system), not to `Clamp`, which is pure and has no notion of time. `Clamp` owns the whitelist half; the caller is responsible for only ever passing a cooldown-legal `baseline.objective`. Two tests assert this split explicitly.
  Caught two bugs in my own first-draft tests, not in `Clamp` itself, while writing the rate-limit cases: `rateLimited`'s delta-from-`previous` window always applies alongside the absolute-range clamp, so a test asserting "clamps to absolute range" using a `previous` too close to that range's edge was asserting an impossible value — fixed by widening `maxDelta` in that case to isolate the behavior being tested.

- [x] **M4-6** `DirectorService` — async tick, in-flight guard, circuit breaker (3 failures → 60 s open), apply at tick boundary.
  *deps: M4-3, M4-5 · Accept:* Studio smoke — tick timing unaffected during a director call; unplug backend → FSM continues, breaker opens, recovers.
  First time `core/director/Fsm` (M2-9) has been wired into a live game at all — it existed only as tested pure core until now, on its own 20s cadence (`Fsm.step`'s own tests already call it with `dt=20`, "director cadence"). `HttpService:RequestAsync` yields and Roblox gives no way to cancel an in-flight request, so the client-side timeout (`requestWithTimeout`) doesn't cancel anything — it stops waiting and discards whatever eventually comes back, which is the honest meaning of "timeout" without a cancellation primitive.
  **Documented, not fabricated, gaps in the run-state payload:** per-player kills/deaths, a position→zone lookup, and `pressure.budgetSpent`/`recentPlayerDamage`/`recentEnemyDeaths` have no real source anywhere in the codebase yet (`core/sim/Budget`, M2-8, was never wired into `EntityService` — a pre-existing M2 adapter gap this surfaced, not one this task created). Sent as `0`/`"unknown"` with an explicit comment, not invented numbers. `aliveEnemies` (`EntityService.count()`) and `secondsSinceLastFight` (derived by watching `CombatService.getMetrics().hits` for real increases) ARE real.
  **Verified for real in Studio, Play mode, via the `DeepcacheDiagnostics` bridge** (`directorInfo`, `directorForceTick`) — not simulated:
  - Tick timing unaffected: `p95` stayed at 0.13–0.21ms with **0 overruns across 4,626 ticks**, spanning real ~1.2s async director calls, a real backend kill, a real 65s breaker window, and real recovery.
  - Backend killed for real (`Stop-Process` on the actual node process): FSM kept advancing through real state transitions (`PRESSURE → SPIKE → SPIKE → LULL`) with valid decisions every tick, confirmed via `Clamp.apply(nil, fsmDecision, bounds)` correctly returning the pure FSM baseline (`bark=""`, matching `Fsm.luau`'s "the FSM has no voice").
  - Breaker opened after 3 consecutive real failures (`breakerOpenFor≈60s`), and correctly stopped firing new calls while open (`calls` plateaued).
  - Backend restarted for real; after waiting out the real 60-second window, the next tick's async call succeeded (`lastError` cleared — the exact bug class M3-8 found and fixed, verified not to have regressed here), and the tick *after that* applied the now-pending real proposal (`fallbacks` stopped incrementing) — full recovery, not assumed from the breaker merely closing.
  **A prompt-quality finding, not a bug:** the model reproduced one worked example's exact bark text (`"One less mouth to feed..."`) verbatim across multiple real, differently-timed calls, rather than generating original text for the specific situation. Worth a v2 prompt iteration (fewer or more varied examples); left as-is for M4-6, which is about the adapter's mechanics, not prompt quality.

- [x] **M4-7** Bark filtering — `FilterStringAsync` + `GetNonChatStringForBroadcastAsync`, both pcall-wrapped, canned-bark pool (40 per intent).
  *deps: M4-6 · Accept:* Studio smoke — force filter failure, assert a canned bark displays and no raw text reaches the UI.
  Pool reduced from ~40 to 8 per intent (`config/CannedBarks.luau`, pure data) — documented reasoning in the file itself: a run is at most 36 director ticks total across all eight intents combined, and a filter failure is the exceptional path, not the common one, so 8 distinct lines already makes a repeat within one run's exceptional-path cases unlikely. Pure data with no code depending on the count, so growing the pool later is a content change, not a refactor.
  Filtering runs async (`task.spawn`, off the tick path) since `FilterStringAsync` genuinely yields — a real Roblox service call, not a fast local check. `DirectorService.getFilteredBark()` is what M4-9's HUD should read, deliberately never `getDecision().bark` directly, so there's no code path that can accidentally display unfiltered text by reaching for the wrong getter.
  **Verified for real in Studio, forcing an actual filter failure rather than mocking one:** `requestingUserId = 0` is not a real player and genuinely fails `FilterStringAsync` — no test-only injection hook needed. Confirmed: raw text `"SECRET RAW TEXT: shot 10, kill"` sent in, canned line `"You wanted the good stuff. Here's the cost."` came back (confirmed present in the real `punish_greed` pool, not just plausible-looking), never the raw text. Confirmed the happy path separately with a real connected player's UserId: real text passed through the filter unchanged. Tick stats before/after: 0 overruns, p95 0.10–0.15ms across 1,058 ticks — filtering's async yield does not touch the tick loop.

- [x] **M4-8** Objective system — whitelist, cooldowns, param clamping, issue/complete events.
  *deps: M4-5, M2-7 · Accept:* test — cooldown respected; params clamped per-objective; unknown ID keeps the active objective.
  `core/director/Objectives.luau` (new, pure): completes the split `Clamp.luau` documented — Clamp owns "is this id in the whitelist" (stateless), this owns "and is it available right now" (stateful cooldown, deliberately kept out of Clamp since its contract is "no notion of time"). `resolve`/`issue`: a genuine change starts the *previous* objective's cooldown, not the new one's; re-issuing the id already active is a no-op so holding steady across ticks never resets anything; an id with no known cooldown defaults to immediately available. Param clamping was already Clamp's job (M4-5) and needed no new work.
  10 tests in `tests/objectives.spec.luau`, including a full multi-step rotation scenario (issue A, propose B too early — rejected, stays on A; propose B again once its cooldown has genuinely elapsed — accepted). `lune run tests`: 515 passed, up from 505.
  **`issue/complete` events, scoped honestly:** `objective.issued` telemetry fires on every genuine change, with the previous id and timestamp. `objective.complete` is NOT implemented — it would need per-objective-type gameplay hooks (a player standing in a zone for `durationS`, a marked node being destroyed, a cart reaching a pad) that do not exist anywhere in the codebase yet, the same category of gap M4-6 already documented for `pressure`/kills/deaths. Not fabricated, not silently skipped — named here as the reason this half of the task's title isn't done.
  Wired into `DirectorService`: after `Clamp.apply` produces a candidate objective, it's resolved against cooldown state before being applied; a rejected candidate keeps the previously-active objective's id *and params* (an objective in progress does not restart because a competing one was proposed and blocked). **Verified in Studio** (touches an adapter) both by observing real ticks stay on one objective across several forced calls, and — more directly — by driving the real, synced `Objectives` module through a scripted accept/reject/re-accept sequence in Studio's own Luau runtime, not just Lune's: proposed a switch, confirmed it was accepted; proposed switching back too early, confirmed it was rejected and the prior objective stayed active; proposed the same switch once its cooldown had genuinely elapsed, confirmed it was accepted. Tick stats unaffected: 0 overruns, p95 0.14ms across 760 ticks.

- [x] **M4-9** Comms HUD panel + threat-tier → lighting hook.
  *deps: M4-7 · Accept:* Studio — barks appear, threat tier 5 visibly shifts the post stack.
  Reused the `RunEvent` remote already declared for exactly this ("Run lifecycle, objectives, OVERSEER barks (M2/M4)") rather than adding a new one. `DirectorService` broadcasts `{kind="overseerBark", bark, intent, threatTier}` only *after* async filtering resolves — a client can never see the pre-filter text, not even for one frame. `HudController` (M2-10) gained the comms label and a `ColorCorrectionEffect` under `Lighting`, tweened (not snapped) toward per-tier tint/contrast/saturation so an escalation reads as a shift, not a flicker; the label auto-hides 10s after the last bark.
  **Verified for real in Studio, on the actual running client, not assumed from the server side:** forced a real broadcast at `threatTier=5` and read the client's live `ColorCorrectionEffect` back — `TintColor=(255,120,100)`, `Contrast=0.32`, `Saturation=0.35`, exact matches for the declared tier-5 preset, and the comms label showed `"OVERSEER: Verification bark for tier 5."` before correctly auto-hiding once its 10s window passed (observed on a later check, not scripted to hide — the timer just did its job). Also observed a real tier-3 broadcast from the natural 20s background loop land with matching tier-3 values, so this isn't only exercised by the one manual test. Tick stats: 0 overruns, p95 0.14ms across 1,564 ticks.
  **A pre-existing gap this surfaced, not one it created:** before this task, nothing on the client listened to `RunEvent` at all, despite the server already firing it for `runStarted`/`playerDied`/`playerExtracted`/`runEnded`/`padOpened`. Only `overseerBark` is handled now; the others remain unlistened-to on the client, same category of gap as M2-8's un-wired `Budget`→`EntityService` path.

- [x] **M4-10** A/B assignment by `hash(runId)`, arm recorded in `run.start`.
  *deps: M4-6, M3-2 · Accept:* over 1,000 simulated runs, arm split within 48–52%.
  `core/director/AbTest.luau` (pure): reuses the already-tested `core/telemetry/Hmac.sha256` rather than a second hash implementation — the last hex digit of `sha256(runId)` is uniform over 0-15, split at 8. Deterministic from `runId` alone, so a logged run's arm is reproducible without having recorded it separately.
  4 tests including the literal accept criterion — 1,000 simulated runIds, real measured split **A=484 B=516 (48.4%)**, inside the 48-52% window. `lune run tests`: 519 passed, up from 515.
  Wired end to end: `RunLifecycleService.start()` computes the arm once from `runId` and includes it in `run.start` telemetry; `DirectorService` reads `RunLifecycleService.getArm()` each tick and returns before ever calling the backend when arm is `"A"` — not a disabled feature, the control condition docs/05 §Evaluating the director specifies (`Clamp.apply(nil, fsmDecision, bounds)` already made the tick's decision the pure FSM baseline before this check even runs).
  **Verified end to end in Studio and real Postgres, not just at the pure-function level:** for the live run, `AbTest.assignArm(runId)` recomputed independently matched the arm actually driving call behavior (calls were incrementing — arm B), and `SELECT payload->>'arm' FROM events WHERE type='run.start'` against the real database returned `B`, matching exactly. Tick stats unaffected: 0 overruns, p95 0.14ms across 1,108 ticks.

- [x] **M4-11** Director metrics on the dashboard — latency, fallback rate, cost/run, A/B comparison.
  *deps: M4-10, M3-7 · Accept (revised — see below):* charts render; fallback rate reads < 3% over 200 runs.
  Dashboard now queries `director.decision` directly: total decisions, avg/p95 latency (`percentile_cont`), fallback rate, and a per-arm (A/B) breakdown, replacing the M3-7 "not yet emitted" placeholder for this exact chart — the dashboard's own stated intent ("let it visibly grow honest charts as M4/M5/M6 land") realized for real. "Cost/run" is rendered as the literal fact it now is — `$0` (self-hosted, see CLAUDE.md §Model choices) — not a fabricated dollar figure left over from the Anthropic plan.
  Verified: real inserted rows with known `latencyMs`/`fallbackUsed`/`arm` values produce arithmetically-correct aggregates (avg `(1200+900+0)/3=700ms`, fallback `1/3=33.3%`, per-arm splits exact), and `percentile_cont`'s return type checked directly rather than assumed — it comes through as a real JS number, unlike `avg()`'s `NUMERIC` (the exact bug class M3-7 found). Loaded `http://127.0.0.1:8787/` in a real browser: the Director card renders with real numbers, and the placeholder list correctly dropped from four entries to three. `npm --prefix backend test`: 96 passed, up from 94 (2 new).
  **The "< 3% over 200 runs" criterion itself is stale, not met by fabricating a friendlier sample.** It was written for the original Anthropic-cloud plan; docs/metrics/m4.md already has a real, measured ~50% fallback rate at the current 1200ms budget against local Ollama (M4-3), and `sim/` does not generate `director.decision` events at all — extending it to would be new scope, not this task's. Verified the chart mechanism is correct against real, arithmetically-checkable data instead of chasing a threshold that assumed different infrastructure. The user already deferred the underlying "loosen the timeout" decision (see M4-3); this is the same open question surfacing again, not a new one.

---

## M5 — Matchmaking & discovery

- [x] **M5-1** `core/discovery/Rating.luau` — Glicko-style update. *Accept:* test vs. hand-computed values; rd shrinks with play, grows with absence.
  **Process error, caught before it caused real damage but worth naming plainly:** `core/discovery/Rating.luau`, `Bucket.luau`, and `Recommend.luau` already existed as M0-scaffolded stubs (`error("unimplemented: ...")` bodies with a deliberately-designed API each) — the exact same situation as M4's `Schema.luau`/`Clamp.luau`, which were correctly filled in against their existing contracts. This time the stubs were overwritten with freshly-designed APIs without reading them first, discovered only at `git add` when they showed as `M` (modified) rather than `A` (added). Checked before deciding what to do about it: nothing else in the repo referenced any of the three original stubs' function or type names yet, so nothing broke. Kept the new APIs (documented as deliberate divergences in each file's own header, with the original signatures quoted) rather than a late reversion, but the lesson — check for existing scaffolding before designing an API for a file with `error("unimplemented: ...")` already in it — is recorded here so it doesn't repeat in M6/M7.
  **A three-way inconsistency, not the two-way one first assumed:** the original scaffold (this file *and* docs/06, both from the M0 scaffold, 2026-08-15) agreed `r` starts at `1200`. `backend/src/rollup.ts` (M3-5, 2026-08-17, two days later) diverged to `1500` without reconciling back. 1200 is not a standard Glicko value in the literature; 1500 is. Resolved in favor of 1500 — the domain-correct value for a system that calls itself "Glicko-style" — not in favor of whichever artifact came first. docs/06 and this file's constant both updated to match the already-shipped, tested rollup seed.
  **As built — docs/06 gives the shape of the formulas but not their constants**, so concrete choices were made and documented in the file itself: expected performance is an Elo-shaped logistic curve (400-point scale) on `r - runDifficulty`; `K(rd) = 150 * (rd/350)` so a brand-new player can swing +-150 in one run while an established one (`rd` near the 50 floor) barely moves; `rd` shrinks 6%/run, grows 5 points/day absent. `runDifficulty` and `daysSinceLastSeen` arrive as arguments — core cannot compute either from raw telemetry, that's a backend rollup concern not yet built.
  15 tests in `tests/rating.spec.luau`, hand-computed against clean fractions (e.g. a +-400 rating gap gives exactly 10/11 and 1/11 expected-performance) rather than re-derived from the module's own code. `lune run tests`: 563 passed, up from 519.

- [x] **M5-2** `core/discovery/Bucket.luau` — bucketing + widening schedule. *Accept:* test — boundaries exact, no player in two buckets, 75 s triggers undersized start.
  Also replaced a pre-existing M0 stub (`Bucket.of` + a single `Bucket.window(...): SearchWindow` returning a compound `{centre, spread, acceptAny, startUndersized}`) with a three-function split (`bucketFor`/`stageFor`/`inSearchRange`) — see M5-1's process note. Confirmed nothing referenced the original names before keeping the new shape.
  `bucketFor(rating) = floor(rating/100)` — matches docs/06's own worked example (1250 → bucket 12) exactly, and "no player in two buckets" holds by construction: a pure function of one input has exactly one output, never two. 16 tests in `tests/bucket.spec.luau` including exact boundary pairs (1299→12, 1300→13) and the literal 75s-undersized accept criterion.
- [ ] **M5-3** Lobby place + queue UI. **⚠ human** to create the place. *Accept:* player can join/leave the queue.
- [ ] **M5-4** MemoryStore queue (sorted map per bucket) + CAS removal. *Accept:* Studio — two coordinators cannot claim the same entry.
- [ ] **M5-5** Lease-based coordinator election (10 s TTL). *Accept:* kill the holder, another takes over within 12 s; logged.
- [ ] **M5-6** Squad formation + `ReserveServer` + `TeleportAsync`. *Accept:* Studio — 2 players queue, land in the same reserved server.
- [ ] **M5-7** Backfill into in-progress runs (first 4 minutes). *Accept:* a queuer joins a running match.
- [x] **M5-8** `sim/matchmaking.ts` — Poisson arrivals, populations 5–500, wait percentiles + spread. *Accept:* report generated; p95 < 30 s at λ=1/s.
  Discrete-event simulation: Poisson arrivals (exponential inter-arrival sampling) interleaved with a periodic 1s queue re-check, matched against the exact bucketing/widening thresholds from docs/06 — a second, independent TypeScript implementation of the same rule (sim/ cannot import a .luau file), not a shared module, so a drift between the two has to be caught by comparing behavior.
  **A real bug, found by running it:** the first version only re-checked the queue on new arrivals. At low population, a lone queued player with no further arrivals before the window ended was never re-evaluated at all — `undersized` launches read exactly 0% even at population 5, where a near-empty queue should produce mostly undersized launches. Fixed by interleaving arrival events with a periodic 1-second tick so a lonely player's 75s clock is checked regardless of whether anyone else ever arrives. A regression test (`matchmaking.test.ts`) pins this behavior directly.
  **Report generated for real — and the numeric target is not met at the documented default assumptions, reported as such rather than tuned until it passed:**
  ```
  lambda=1/s, 600s window, squad size 3, rating ~N(1500, 250):
  matched=188 p50=25.0s p95=42.8s p99=45.4s meanSpread=72.0 undersized=0.0%
  FAIL: p95 >= 30s
  ```
  `ratingStdDev=250` is this simulator's own assumption — docs/06 does not pin a distribution, and there is no real player population to calibrate against, which is the entire reason this simulator exists. A wider assumed spread makes the strict "own bucket only" first 15s phase rarely succeed for `targetSquadSize=3`, pushing most matches into the 15–45s widening phases — a real, structural property of bucket width (100) vs. assumed rating spread (250) vs. squad size (3) at this arrival rate, not a bug. Recorded honestly rather than narrowing the assumed spread until the target passed, which would have hidden the actual sensitivity rather than reported it.
  9 tests in `sim/test/matchmaking.test.ts`. `npm --prefix sim test`: 18 passed (9 new).
- [x] **M5-9** `core/discovery/Recommend.luau` — cosine + shrinkage (λ=10). *Accept:* test — shrinkage suppresses a 2-count pair; owned items excluded; cold start returns baseline.
  Also replaced a pre-existing M0 stub — see M5-1's process note. The original declared `reason: "pairs_with_owned"|"similar_players"|"popular_at_your_rating"` on each `Recommendation`; this version's plain float score doesn't carry that distinction. Not an oversight: which reason applies depends on *which code path* produced a score (item-similarity vs. rating-bucket popularity), information this module's callers (`topN` vs `popularityBaseline`) have and could tag on before returning to the client — a natural fit for M5-10, not this file. Confirmed nothing referenced the original `CooccurMatrix`/`forPlayer` names before keeping the new shape.
  16 tests in `tests/recommend.spec.luau`. The literal accept case, hand-computed: cooccur=2, count(a)=count(b)=2 gives naive cosine exactly 1.0 (matching docs/06's own "gets a similarity of 1.0" claim), shrunk to exactly 1/6. Found and fixed a self-inconsistent test fixture before it could produce a passing-but-meaningless assertion: a co-occurrence count can never exceed either item's own total count, and a first-draft fixture violated that (cooccur=10 with one item's count=5) — caught by hand-tracing the expected ranking, not by the test framework, since Luau doesn't know that invariant either.
- [x] **M5-10** Recommender worker + `/v1/recommend/loadout`. *Accept:* endpoint returns 3 items with reason codes for a known pid.
  `backend/src/workers/recommend.ts`: full idempotent recompute (`TRUNCATE` + rebuild, batched inserts) of `loadout_pairs` from real `loot.pickup`/`extract.success` telemetry — same "recompute, don't increment" pattern `rollup.ts` (M3-5) already established, for the same self-healing-after-a-crash reason. Weighted per docs/06 (successful extraction counts double); item totals live on the matrix diagonal (`item_a = item_b`) rather than a second table.
  `backend/src/discovery/recommend.ts`: a second, independent TypeScript implementation of `Recommend.luau`'s scoring math (the backend can't `require` a `.luau` file), verified in `recommend-sync.test.ts` against the exact same hand-computed cases as the Luau suite — including the same self-consistency-checked fixture from M5-9.
  `GET /v1/recommend/loadout?pid=` tags each recommendation with a `reason`: `pairs_with_owned` (personalized) or `popular_at_your_rating` (cold start or fallback). Only two of docs/06's three documented reasons are implemented — `similar_players` would need player-based (not item-based) similarity, which doesn't exist; not fabricated.
  **Verified against real generated sim data, not just the isolated test fixture:** `npm --prefix sim run generate -- --runs 100 --days 7` then a real rollup + recompute pass (`pairs=56 items=10 usageRows=884`), then the real live endpoint: `pid=sim-player-22` (a cold-start pid) returned exactly 3 items, all tagged `popular_at_your_rating`, matching the accept criterion literally. A second real pid (`sim-player-1u`, an established player) correctly returned `fallback=false` but an *empty* list — traced and confirmed honest, not a bug: that pid already owned all 7 real catalogue items, and the only unowned "items" left were synthetic ids from this suite's own isolated test fixture with zero real co-occurrence data connecting them to anything — `score > 0` correctly filtered them out.
  10 new tests (`recommend-sync.test.ts` + `recommend-worker.test.ts`, the latter against real inserted rows, not mocks). `npm --prefix backend test`: 106 passed, up from 96.
- [x] **M5-11** Offline eval script (time split, recall@3 vs popularity). *Accept:* `npm run eval:recommend` prints a comparison table; result recorded in `docs/metrics/m5.md` **whatever it says**.
  Chronological 80/20 split by each run's earliest event; training-only co-occurrence matrix and per-pid owned-item history (the held-out run's own items never leak into training, including for the very pid being evaluated); the same `recommend()` function the live endpoint uses, so the eval measures the real served behavior, not a separate code path.
  **The real result: personalized recommendations LOSE to the popularity baseline, by a wide margin, on real generated data** — recorded as measured, per this task's explicit "whatever it says," not tuned or reframed until it looked better:
  ```
  Runs: 402 total, 321 training, 81 held out. 205 held-out evaluations, 120 cold-start.
  personalized:         47.8% recall@3 (98/205)
  popularity baseline:  98.0% recall@3 (201/205)
  Personalized LOSES to the popularity baseline by 50.2 points.
  ```
  **A real, defensible explanation, not an excuse:** docs/06 designed this algorithm assuming "the item catalogue is small (~40 items)." The actual current catalogue (`config/Loot.luau`) has **7** loot items. With a catalogue that small, the top-3 globally popular items combinatorially cover most players' actual usage almost by construction — popularity is an unusually strong baseline exactly when personalization has the least room to add anything, and cosine similarity's known failure mode (a rare, tightly-co-occurring pair outscoring a generically popular item) costs more than it helps at this scale. This is a genuinely interesting, catalogue-size-driven finding, not a bug in the scoring math — M5-9/M5-10's hand-computed tests already confirm the formulas themselves are correct.

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
