# 03 — Netcode

The spine. Nothing else in this project works if this doesn't.

## What Roblox gives you, and what it doesn't

Roblox replicates `Instance` property changes and hands character physics to the client that owns it. That's a replication system, not netcode. It gives you no tick alignment, no snapshot history, no rewind, and no way to reclaim ownership of a player's own character without destroying the feel of movement.

So the design works *with* that boundary rather than against it:

| Thing | Who owns it | Approach |
|---|---|---|
| AI entities | Server, totally | Custom non-`Humanoid` rigs. Server simulates at fixed 20 Hz, sends snapshots, client interpolates. Roblox replication is bypassed entirely for these. |
| Local player character | Roblox/client | Leave it. Add a **server-side plausibility guard** instead of fighting for ownership. |
| Weapon fire | Server authoritative | Client predicts presentation; server validates with **lag compensation**; client reconciles. |
| Projectiles | Server | They're entities. Same snapshot path. No rewind needed — they exist in the same timeline as the target. |

Calling this "rollback netcode" would be wrong and an interviewer would catch it. Calling it *authoritative fixed-tick simulation with snapshot interpolation and server-side lag compensation* is accurate, and it's the same family of techniques Source and Overwatch use for exactly the same reasons.

## Entities are not Humanoids

Deliberate. A `Humanoid` drags in Roblox's own physics, replication, and network ownership — which is precisely the thing that would make server authority impossible. Entities here are:

- A `Model` with an unanchored-free, **anchored** root part positioned by the client each frame from interpolated snapshot data.
- No `Humanoid`, no `HumanoidRootPart` physics, no `Motor6D` animator on the server side.
- Server-side, an entity is a **plain Luau table** in `core/sim/EntityState.luau` — no Instance at all. Instances exist only on clients, for rendering.

This means the server can simulate 60 entities without touching the physics engine, and the wire format is whatever we choose.

## Wire format

`UnreliableRemoteEvent` drops payloads over ~1000 bytes. Budget: **900 bytes hard**, asserted in `Snapshot.encode`.

Snapshots go out at 20 Hz on an unreliable channel — losing one is fine, the next arrives in 50 ms and interpolation covers the gap. Hit results, state changes, and run events go on a **reliable** `RemoteEvent` because ordering and delivery matter there.

### Per-entity record — 11 bytes

| Field | Bytes | Encoding |
|---|---|---|
| entityId | 2 | `uint16` |
| x, z | 4 | 2 × `int16`, 0.05-stud grid, relative to level origin (±1638 studs) |
| y | 2 | `int16`, 0.05-stud grid |
| yaw | 1 | `uint8`, 256 steps ≈ 1.4° |
| state | 1 | `uint8` — enum: idle/move/attack/stagger/death/spawn |
| hpPct | 1 | `uint8` — 0–255 mapped to 0–100% |

Header: `tick` (`uint32`, 4 B) + `count` (`uint8`, 1 B) = 5 bytes.
**Capacity: (900 − 5) / 11 = 81 entities per packet.** Interest management caps at 32, so there's headroom for adding fields later without a format break.

Quantization error is bounded at 0.025 studs positionally and 0.7° angularly — both well under perceptual threshold at gameplay distances, and both asserted in `Quantize` tests.

### Delta compression

Full snapshot every 20th tick (1 s). Between keyframes, send only entities whose quantized state changed since the last acknowledged keyframe, with a 4-byte changed-entity bitfield prefix per 32 entities. Typical steady state: 8–14 moving entities per packet ≈ 100–160 bytes.

**Bandwidth target: < 6 KB/s per client** at 3 players + 40 entities. Measured, not assumed.

## Interest management

Per client, per tick:

1. Filter entities to a 150-stud radius around the player.
2. Score by `1/(distance+1) + 0.5*isAttackingThisPlayer + 0.3*ticksSinceLastSent`.
3. Take top 32.

The `ticksSinceLastSent` term is anti-starvation: a distant entity still gets an update occasionally, so it isn't frozen when the player turns around. Entities that fall out of interest get an explicit despawn on the reliable channel so the client doesn't leave a ghost.

## Client interpolation

The client renders entities **100 ms in the past**. That's 2 ticks (100 ms) plus a jitter allowance — enough that a single dropped packet is invisible.

```
renderTime = clientNow - RENDER_DELAY        -- RENDER_DELAY = 0.10
Interpolator:sample(renderTime) -> position, yaw, state
```

- Two snapshots bracketing `renderTime` → linear position lerp, shortest-arc yaw lerp.
- No bracketing snapshot available → **extrapolate along last velocity, max 80 ms**, then freeze in place and fade opacity slightly. Extrapolation beyond 80 ms produces visible rubber-banding, so it's better to stop.
- State changes (attack windup, death) are applied at their snapshot's timestamp, not immediately, so animation stays in sync with position.

`RENDER_DELAY` is adaptive: measure inter-arrival jitter over a 3-second window, set delay to `max(0.10, p95_jitter + 0.05)`, clamped to 0.20. High-jitter clients trade a little responsiveness for smoothness automatically.

## Lag compensation — the centerpiece

The problem: the player shoots at where they *see* an entity, which is `renderTime`, which is ~100 ms + their latency behind the server's present. Validating against the server's current position means every shot at a moving target misses. Trusting the client means aimbots.

The fix: the server rewinds.

**Server keeps a ring buffer** — `core/net/History.luau`, 20 ticks (1 second) of every entity's position and hitbox radius.

**Fire request** (reliable channel):
```lua
{ seq: uint32, clientTime: number, origin: Vector3, dir: Vector3, weaponId: uint8 }
```

**Server validation pipeline** — in order, cheapest rejections first:

1. **Fire rate.** Token bucket per weapon. Refill = weapon RPS, capacity = 2. Empty bucket → reject, increment cheat counter.
2. **Ammo.** Server-side count. Zero → reject.
3. **Origin plausibility.** `|origin − serverKnownPlayerPos|` ≤ 8 studs. Beyond that, the client is lying or desynced badly; substitute the server position rather than rejecting, so honest desync doesn't punish the player.
4. **Rewind.** `targetTime = clamp(clientTime, now − 0.25, now)`. 250 ms is the compensation window — beyond it, high-ping players start "shooting around corners" from the victim's perspective. Clamping is what bounds that unfairness.
5. **Raycast** against rewound hitboxes plus *current* static geometry (walls don't move; rewinding them is unnecessary and wrong).
6. **Range and falloff** from weapon config; apply `DamageModel`.
7. **Apply damage**, emit hit event on reliable channel, log telemetry.

**Client reconciliation.** The client already drew the tracer, the muzzle flash, the recoil, and a hitmarker if it predicted a hit. When the authoritative result arrives:

- Predicted hit, server confirms → nothing to do. This is the common case.
- Predicted hit, server says miss → remove the hitmarker, no damage number. Do **not** rewind the tracer; the visual already happened and un-drawing it looks worse than the inconsistency.
- Predicted miss, server says hit → play the hitmarker late. Slightly odd, extremely rare.
- Ammo mismatch → snap to the server value.

The design principle: **reconcile state, never un-play presentation.**

## Movement guard

The client owns its character, so the server checks plausibility rather than authority:

- **Speed:** distance moved per second ≤ `maxSpeed(weight) * 1.35`. The 35% margin absorbs slopes, knockback, and latency spikes.
- **Teleport:** any single-frame delta > 40 studs → snap back and log.
- **Vertical:** y-position outside the level's bounding volume → snap to nearest valid point.
- **Budget, not binary:** each violation adds to a decaying score (decay 1.0/s). Score > 5 → correction. Score > 20 → kick + telemetry event. Single-frame violations from ordinary network hiccups never trigger anything.

This will not stop a determined cheater, and the plan says so honestly. It stops the trivial ones and it produces the telemetry needed to detect the rest.

## Configuration

`src/shared/config/Netcode.luau`:

```lua
return {
    TICK_RATE          = 20,
    SNAPSHOT_MAX_BYTES = 900,
    KEYFRAME_INTERVAL  = 20,
    INTEREST_RADIUS    = 150,
    INTEREST_MAX       = 32,
    RENDER_DELAY_MIN   = 0.10,
    RENDER_DELAY_MAX   = 0.20,
    EXTRAPOLATE_MAX    = 0.08,
    HISTORY_TICKS      = 20,
    LAGCOMP_WINDOW     = 0.25,
    ORIGIN_TOLERANCE   = 8,
    SPEED_MARGIN       = 1.35,
}
```

## What gets measured

These are the numbers that go on the dashboard and into the interview:

| Metric | Target | How |
|---|---|---|
| Server tick time p95 | < 12 ms (of 50) | per-phase timers in `TickService` |
| Snapshot bytes/s/client | < 6 KB/s | counter in `ReplicationService` |
| Hit-registration RTT p50 / p95 / p99 | < 60 / 140 / 250 ms | `seq` echoed in hit event; client measures |
| Prediction mispredict rate | < 2% | client counts confirm-vs-predict disagreements |
| Rewind window overrun rate | < 1% | count of `clientTime` clamps in `CombatService` |
| Entities simulated | 40 sustained, 60 peak | `EntityService` gauge |
| Fire requests rejected (rate/ammo/origin) | tracked per reason | anti-cheat telemetry |

All of them emit as telemetry events, so the dashboard is populated by the same pipeline everything else uses.

## Test plan

Pure-core tests (`lune run tests`), no Studio needed:

- `Quantize`: roundtrip error bounded for 10,000 random positions across the full ±1638 range.
- `Snapshot`: encode→decode identity; 81 entities fits, 82 asserts; delta reconstruction matches full snapshot for a 200-tick recorded sequence.
- `Interpolator`: known input sequence → expected sample values; gap handling; extrapolation cutoff at exactly 80 ms; out-of-order arrival dropped correctly.
- `History`: rewind to exact tick, between ticks (lerped), before window start (nil), after now (clamped).
- `DamageModel`: falloff curve boundaries, armor, zero and negative guards.

In-Studio verification (MCP `execute_luau`):

- 40 entities spawned, tick time logged for 30 s, p95 asserted under budget.
- Two-client play test with artificial latency injected (`NetworkSettings` incoming/outgoing lag) at 50/150/300 ms — hit registration measured at each.

Load harness (`tools/loadtest`): synthetic 4-player, 60-entity snapshot stream, measures pure serialization throughput independent of the engine.
