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

Four layers, all within engine capability.

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

In-Studio (MCP):
- Spawn 40 entities on varied terrain, capture screenshots at each LOD boundary, verify visually that no popping is visible at transitions.
- Ragdoll pool exhaustion: kill 20 entities in 2 seconds, assert the pool recycles and no error is thrown.
- `EditableImage` budget: attempt a 9th allocation, assert the controller refuses cleanly rather than erroring.
