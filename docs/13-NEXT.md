# 13 — Next

Working notes for picking this back up. Ordered by what most changes the
experience, not by what is easiest.

Branch: **`feat/wave-spawner`**, five commits ahead of `master`, unmerged.

```
06618ce  Game feel pass: per-kind enemies, crosshair, hitmarker, hit feedback
091c16c  Fix unwinnable difficulty and invisible attackers
4cb65eb  Fix enemy grounding, facing, and crowd spacing
ff9f3b1  Make enemies actually deal damage (M2-4 adapter half)
a0d484d  Wire the enemy budget into real spawns (M2-8 adapter half)
```

State: **885 pure-core · 139 backend · 18 sim** tests green, 138 files pass
syntax and encoding, `rojo build` clean.

---

## 1. Unverified, verify first

**The hurt vignette has never been seen firing.** It is built, wired, and
present in the HUD (confirmed clear at rest), but the damage probe did not
land a hit on the run it was tested (HP 100 → 100), so the trigger path is
unproven. Re-run with a live wave rather than a probe:

```lua
bridge:Invoke("enemyDamageProbe", "Skitter", 3, 8)
```

and sample `BackgroundTransparency` on the full-screen frame from the
**Client** datamodel while it runs.

**The hitmarker has never been seen firing either.** It cannot be triggered
from the server: `weaponProbe` calls `CombatService.submit` directly, so the
resulting `FireResult` carries a `seq` the client never sent, and
`PredictionController.onFireResult` correctly drops it as unknown. It needs a
human clicking, or a `VirtualInputManager` path the command bar cannot reach.

---

## 2. Things that are wired but hollow

**No audio at all.** M7-8. Every hit, shot, death, and zone transition is
silent, and this is now the single largest gap between how the game plays and
how it feels. Needs real sound assets, which is the blocker — the structure
around them is not hard.

**No damage direction indicator.** You know you were hit (vignette) but not
from where. Enemies attack from up to 55 studs and the Sentry is static, so
"which way do I turn" is the question the HUD currently cannot answer.
Requires the attacker position, which `EnemyCombatService` already has — it
would need a remote, or to ride an existing one.

**Entities are still boxes.** The gait and IK compute every frame, are LOD'd,
and are inside budget — but nothing consumes the solved joint positions
because there is no limb geometry. Per-kind rigs are M7-6/M7-8 asset work.
Until then M7-3's "no popping at LOD transitions" stays unverifiable, and the
client draws one silhouette per kind rather than a real body.

---

## 3. Known bugs and rough edges

**A run ends permanently on player death.** `endReason="squadResolved"`,
`active=0`, and the wave scheduler then correctly reports `run_inactive`
forever. A single-player Studio session is one death and done, and the HUD
keeps showing `LOST — everything you carried is on the floor` after respawn,
which also suppresses the crosshair. Correct for an extraction shooter,
actively painful for playtesting. A `runRestart` diagnostic is the cheap fix;
a real lobby/redeploy loop is the honest one.

**`onDespawn` releases the part but never removes the entity from
`baseline`.** Harmless today because the next snapshot re-adds it, but it
means the client's baseline can only grow within a run. Worth tightening
before it becomes the cause of something.

**`spawn` diagnostic rings the world origin, not the player.** Every
positional test using it is confounded when the player is far from origin —
entities land outside interest and never replicate. Prefer `losProbe` or
`enemyDamageProbe`, which place relative to the character.

---

## 4. Balance, now that it is playable

The numbers were set to clear the guards in
`tests/enemyAttack.spec.luau` (documented in docs/01 §Scaling →
Survivability), not from play. They deserve a real pass:

| Knob | Current | Note |
|---|---|---|
| Player HP | 100 | No armour, no mitigation, ~1 HP/s regen |
| Sentry cooldown | 0.75 s | Was 0.35 (31.4 dps); may still be high in packs |
| Hauler `capPerWave` | 3 | Was 4; a 30-damage swing means 4 hits is a kill |
| Wave interval | 12 s | A *minimum*, not a guarantee — gated on outstanding budget |
| `MAX_ALIVE` | 32 | Pinned to `INTEREST_MAX`; do not raise independently |

**Elites beat a Sidearm one-on-one by design** (Warden 700 HP at 15.7 dps,
Reclaimer 550 at 26). That is fine *because* weapons 1–4 are now switchable —
but nothing teaches the player that, and there is no ammo economy pressure
pushing them to switch.

---

## 5. Still open from earlier milestones

- **M0-8** — publish the place; enable *Allow HTTP Requests* and *Studio
  Access to API Services*; create the `Lobby` place. Blocks M5-3/M5-6/M5-7
  (the matchmaking teleport path has never run against two real places) and
  the `EditableImage` ramps, which compute correctly but cannot be displayed.
- **M6-11** — deploy the backend. Roblox production servers cannot reach
  `localhost`.
- **M7-6 / M7-8** — outlines and audio. Both asset work.
- **M7-11 / M7-13** — playtest with 4+ humans, and the demo video.

---

## 6. The pattern worth remembering

Five separate features in this branch were **fully built and never
connected**: the budget planner, enemy damage, `entity.targetId`, weapon
switching, and the hitmarker hooks. Each looked complete from the code and was
invisible in play.

Two more were **dropped in transit**: `kind` and `hpPct`, both silently
discarded by `Interpolator`'s hand-built `Sample` while every snapshot
round-trip test passed.

When something seems missing in-game, check the wiring before the logic — and
prefer a probe registered from the live context over anything `require`d from
the command bar, which returns a fresh idle copy whose entities no tick phase
ever steps. That trap produced two invalid test results in this branch alone.
