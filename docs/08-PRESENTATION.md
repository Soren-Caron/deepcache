# 08 — Presentation: Animation, Ragdolls, and the Look

## The constraint that defines this work

**Roblox does not let you write shaders.** No vertex programs, no fragment programs, no custom render passes, no compute. Any plan that says "a stylized shader pass" is describing something the platform cannot do.

That constraint is the interesting part. Getting a distinctive look out of a fixed-function renderer is a real graphics problem — it's what stylized console games did for a decade. The techniques below are what the engine actually exposes, and choosing among them is the engineering.

## Procedural locomotion

Entities are non-`Humanoid` (see [03-NETCODE](03-NETCODE.md)), which means Roblox's animator is not driving them. That's a cost — everything must be authored — and a benefit: the animation can respond to the terrain and the netcode instead of playing a canned loop over an interpolated position.

### The step planner

For legged entities (Skitter, Hauler, Warden), a procedural gait:

1. Each leg has a **rest offset** in entity-local space and a **current foot position** in world space.
2. Each frame, compute the leg's desired position: rest offset projected forward by `velocity * stepLead`, raycast down to find ground.
3. If `|desired − current| > stepThreshold`, the leg **commits to a step**: a parabolic arc over `stepDuration`, easing in and out.
4. Legs are grouped into alternating sets so opposing legs never lift simultaneously — that's what reads as a gait rather than a shuffle.
5. Body height follows the mean of the planted feet, with a spring-damper for weight. Body pitch/roll follow the plane fit through the foot positions.

The result adapts to slopes, stairs, and arbitrary geometry for free, which authored clips never do. Cost is per-leg raycasts — budgeted below.

### Two-bone IK

`core/anim/TwoBoneIk.luau` — pure math, no Roblox types, unit-tested:

```lua
TwoBoneIk.solve(rootPos, targetPos, upperLen, lowerLen, poleDir)
  -> (jointPos, reachable: boolean)
```

Standard law-of-cosines solve with a pole vector controlling the joint's plane. When the target is out of reach, extend straight toward it and return `reachable = false` so the caller can decide whether to stretch or step.

Because it's pure, it's tested with hand-computed expected values across reachable, exactly-reachable, and unreachable cases — including the degenerate case where root and target coincide.

### Blending with authored clips

Upper-body actions (attack windup, stagger, death start) are short authored clips. They blend over the procedural locomotion by additive layering on the upper joints only — legs stay procedural throughout, so an entity attacking mid-stride still walks correctly.

Blend weight is driven by the snapshot `state` field, applied at the snapshot's timestamp rather than on arrival, so animation stays synchronized with interpolated position.

### LOD

Non-negotiable for 40+ entities:

| Distance | Treatment |
|---|---|
| < 40 studs | Full: procedural legs, IK, per-leg raycasts, clip blending |
| 40–90 | Reduced: procedural legs at half rate, no ground raycasts (use last known plane), clip blending |
| 90–150 | Clip-only: authored walk loop, no IK, no raycasts |
| > 150 | Not replicated (outside interest radius) |

Raycast budget: **max 24 leg raycasts per frame across all entities**, allocated by distance priority. Entities that don't get a raycast reuse their previous ground plane, which is invisible at those distances.

## Ragdolls

**Ragdoll physics is client-only and never replicated.** The server sends one reliable event:

```lua
{ entityId, deathPos, deathDir, impulseMag, killerWeapon }
```

The client then:
1. Removes the entity from the interpolated render set.
2. Instantiates a ragdoll rig (pre-pooled, 12 instances, recycled) at `deathPos`.
3. Applies an impulse along `deathDir` scaled by weapon and hit location.
4. Lets Roblox physics run it locally. `CollisionGroup` set so ragdolls collide with world geometry but not with players or each other — cheaper and it prevents corpse pileups from blocking corridors.
5. After 8 s, or when the pool is exhausted, fade and recycle.

Two players see different ragdoll poses for the same death. That is correct and desirable: it costs zero bandwidth, and nothing about the game depends on corpse position.

## The look pipeline

Five layers, all within engine capability.

### 0. Built geometry and practical light

The spec used to start at post-processing, which assumed the level itself was
already worth grading. It was not: `Assemble` produces sealed boxes — a floor,
four walls, a doorway per connector — so every room was an open-topped pen with
nothing in it, lit by the default afternoon sun through a missing ceiling. No
amount of colour grading fixes an empty room.

So the geometry pass now also builds:

- **Ceilings**, which is what turns the level from a dollhouse into an
  interior. They are queryable, unlike the rest of the decoration: a shot fired
  at the ceiling should stop there.
- **Ceiling fixtures** — an emissive panel plus a shadowless `PointLight`.
  Mandatory, not optional: sealing a room removes the only light it had, so
  `Decor.ceilingLights` is specified to always return at least one.
- **Wall structure** — a band near the top and evenly spaced pilasters, which
  is what stops a 24-stud wall reading as one flat slab.
- **Props** against the walls, per zone: crates and containers on the
  Perimeter, barrels and pipework in Processing, stacked storage in the Vault.

Placement is pure (`core/level/Decor`) and the constraints are the interesting
part, because each is a gameplay bug rather than an aesthetic one: nothing in
the middle of a room (entities steer by seek-and-separate, not a navmesh, so an
obstacle in open floor is something they wedge against), nothing within
clearance of a doorway, and deterministic per seed so a replayed run looks like
the run it replays.

**Props are solid but transparent to raycasts** — `CanCollide = true` so set
dressing does not read as a bug when you walk through it, `CanQuery = false` so
combat is bit-for-bit unchanged. Real cover would be a better game and this is
the obvious geometry for it, but it moves damage numbers and invalidates the
difficulty pass, which makes it a design change rather than a presentation one.

Two calibration facts worth keeping, both found by looking rather than
reasoning:

- **Light range is set by the room, brightness by the overlap.** Fixtures mount
  at the 24-stud ceiling, so a range of 32 spends three quarters of itself
  reaching the floor; a 112×96 Vault room lit by six of them rendered as pure
  black with six glowing panels floating in it. Range then has to be sized for
  the largest room, which means every fixture in a small one covers all of it —
  so brightness has to come down to compensate, or a 56×56 entrance hall
  saturates to white.
- **Brightness belongs with the palette, not the fixture.** One global value
  cannot serve both bands: what lit the Vault's near-black slate blew out the
  Perimeter's pale concrete. How much light a room needs is a property of what
  its surfaces are made of, so the multiplier lives in `Zones.palette`.

Measured cost: 528 parts and 63 lights for a 16-module level, with lights on
versus off differing by **0.004 ms of mean frame time** — the p95 jitter is
identical either way, so the lights are free at this count. Server tick p95
0.35 ms, 0 overruns; a Skitter pathed 166 studs through a dressed level with
0 stalled samples.

### 1. Post-processing stack

`ColorCorrection`, `Bloom`, `DepthOfField`, `Atmosphere`, `SunRays` — driven by a per-zone preset table and lerped on zone transition over 1.5 s.

```lua
Perimeter  = { tint = Color3(0.95,0.98,1.00), sat = -0.10, contrast = 0.12, bloom = 0.6, fog = 180 },
Processing = { tint = Color3(1.00,0.92,0.82), sat = -0.25, contrast = 0.22, bloom = 1.1, fog = 90  },
Vault      = { tint = Color3(0.82,0.86,1.00), sat = -0.40, contrast = 0.35, bloom = 1.8, fog = 45  },
```

Desaturation increasing with depth, fog closing in, contrast rising — the zones read as descent without any new art.

**Threat tier from OVERSEER modulates this in real time.** At `threatTier` 4–5 the tint pushes red, bloom rises, and fog tightens by 20%. The director's decisions are *visible in the lighting*, which is what makes it feel like a presence rather than a spawn multiplier.

### 2. Inverted-hull outlines

The closest thing to a toon shader the engine allows: a duplicate mesh, scaled up ~3%, with inverted normals and a flat dark unlit material, parented behind the original.

- Applied to enemies and interactables only — not world geometry (too expensive, and it reads as noise).
- Hull meshes are generated once at build time by `tools/genhulls.ts` and stored as assets, not computed at runtime.
- Outline thickness scales with distance so it stays perceptually constant.

The gameplay payoff is real: enemies stay readable against busy environments at distance, which matters in a shooter with 40 entities.

### 3. EditableImage ramp textures

`EditableImage` allows runtime pixel writes, which enables procedurally generated palette ramps and detail textures.

**The hard limit: 8 live `EditableImage` instances on the client.** This is a real budget and exceeding it fails at creation with a memory-budget error, not gracefully.

Allocation, fixed:

| # | Use |
|---|---|
| 1 | Zone palette ramp (regenerated on zone transition) |
| 2 | Damage-state ramp for entities (HP → color) |
| 3 | Threat-tier gradient for the HUD comms panel |
| 4 | Procedural noise for fog/atmosphere detail |
| 5–6 | Weapon heat/charge indicators |
| 7–8 | **Reserved** — spare capacity, deliberately unallocated |

`LookController` owns all eight, hands out handles, and releases them on zone change. Two spare slots exist because discovering the cap in production is a bad way to discover the cap.

### 4. PBR SurfaceAppearance

Hero assets (weapons, extraction pads, the Warden) get proper `SurfaceAppearance` with albedo/normal/roughness/metalness. Everything else uses `MaterialVariant` with tuned base materials. This is the cheap-but-effective layer.

## The boot screen

The first thing a player sees is a black room. Roblox's own loading screen
leaves once the *engine* is ready, which here is seconds before there is
anything to look at: the level is generated server-side and parented to
Workspace in one go, so until it lands the client renders an unlit facility
with the HUD floating over it. Measured in Studio — where the server is
local and the geometry is already resident — that gap is **1.66 s**. On a real
client over the network it is longer, and it reads as a broken game rather
than a loading one.

`src/replicatedfirst/LoadingScreen.client.luau` covers it. ReplicatedFirst is
the only place that runs before the DataModel fills in, and the backdrop is
created *before* `RemoveDefaultLoadingScreen` so there is never a frame with
neither screen up — that frame is the black room.

The decidable part lives in `core/boot/LoadGate`:

| Gate | Answered by |
|---|---|
| `engine` | `game:IsLoaded()` |
| `world` | `Workspace.Level` exists with its `seed` attribute |
| `assets` | `ContentProvider.RequestQueueSize == 0`, **only once `world` is open** |
| `avatar` | character has a HumanoidRootPart and a Humanoid |
| `systems` | `dcClientReady` attribute, set by `Bootstrap.client` after `main()` |

Three rules the module exists to enforce, each of which is a way a loading
screen gets worse than no loading screen:

- **Gates latch.** `RequestQueueSize` drops to zero and rises again as more
  geometry streams. Latching the answer rather than clamping the number is
  what keeps the bar monotonic, and it puts the reason in one place instead of
  in a `math.max` someone has to reverse-engineer.
- **The `assets` gate is not asked before `world` opens.** The queue is
  legitimately empty before the level exists, so asking early would latch it
  instantly and claim the geometry was ready before the server had sent it.
- **There is a floor and a ceiling.** `minSeconds` (0.7) stops a one-frame
  flash on a warm client; `timeoutSeconds` (25) releases regardless and warns,
  because a screen that never leaves is worse than the room it hides.

The bar also stops at 99% until genuinely complete — a full bar that is still
waiting is what makes a loading screen feel hung — and eases toward its target
rather than snapping, because the gates open in a few large jumps and a bar
that teleports from 10% to 70% reads as a glitch.

## Performance budget

Client frame budget at 3 players, 40 entities, 1080p, mid-range hardware:

| System | Budget |
|---|---|
| Entity interpolation + transform writes | 1.5 ms |
| Procedural animation + IK (LOD'd) | 2.0 ms |
| Leg raycasts (capped at 24) | 0.8 ms |
| Ragdoll physics (≤12 active) | 1.2 ms — Roblox physics, measured not controlled |
| VFX / particles | 1.0 ms |
| HUD | 0.5 ms |
| **Total script + render prep** | **~7 ms** — leaves room for a 60 fps frame |

Measured with `debug.profilebegin`/`profileend` around each block, surfaced through the MicroProfiler, and sampled into `perf.tick` telemetry so it lands on the dashboard alongside the server numbers.

## Tests

Pure-core:
- `TwoBoneIk`: reachable, exactly-reachable, unreachable, degenerate coincident points, pole-vector plane correctness.
- `StepPlanner`: gait phase never lifts opposing legs simultaneously; step commits only past threshold; body height tracks foot mean.
- `Ramp`: palette interpolation endpoints and midpoint values.
- `LoadGate`: a flickering gate never rewinds the bar; unknown gate ids do not
  count toward completion; the bar stops short of full while still waiting;
  the minimum holds and the timeout releases; easing is frame-rate independent
  and never overshoots.

In-Studio (MCP):
- Spawn 40 entities on varied terrain, capture screenshots at each LOD boundary, verify visually that no popping is visible at transitions.
- Ragdoll pool exhaustion: kill 20 entities in 2 seconds, assert the pool recycles and no error is thrown.
- `EditableImage` budget: attempt a 9th allocation, assert the controller refuses cleanly rather than erroring.
