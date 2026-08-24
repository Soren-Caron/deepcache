# 14 — Humanoid rigs

**Status:** planned, not started. Supersedes the box-with-legs rig in
`config/Rigs.luau` / `client/EntityRig.luau` (commits `22fd807`, `870a534`).

The current rig is a body box with two-segment legs. It reads as an insect,
and two rounds of tuning did not fix that — the failure is structural, not
cosmetic. This is the plan for replacing it with an upright humanoid form.

---

## 1. Why the current rig reads wrong

Three findings, all measured rather than eyeballed. They are the constraints
the humanoid rig has to satisfy.

**Limb straightness is 0.990 of full extension** (1.0 is a rigid stick). A
Skitter's leg spans `upper + lower = 1.45` studs while the hip-to-foot drop is
`0.97` — **67% of the total length is spent just reaching the floor**, leaving
almost nothing to bend with. The IK is working; there is no slack for it to
express. Making legs stouter in the last pass also made them shorter, which
made this worse.

> **The rule that falls out:** total limb span must exceed the hip-to-foot
> distance by roughly **40–50%**. For a hip at height *h*, want
> `upper + lower ≈ 1.45h`, split near evenly. A visibly bent knee is the
> single biggest difference between "machine" and "bug".

**The knee pole must be perpendicular to the limb axis.** A standing leg is
near-vertical, so `(0,1,0)` is near-*parallel*: its perpendicular component
collapses, `TwoBoneIk` falls back to `anyPerpendicular`, and the bend
direction flips between cardinal axes on numerical noise. Already fixed
(`870a534`) by using the body's forward axis — the humanoid rig must keep
that, and should bend knees **forward** and elbows **backward**.

**Leg count is most of the silhouette.** Six legs read as a spider whatever
the colour or proportion. Two legs plus two arms reads as a person.

---

## 2. Target body plan

One shared humanoid skeleton, scaled and proportioned per kind. Fifteen parts:

```
                head          1
                torso         1   (upper + lower reads better: 2)
   shoulder ──  upperArm  ×2  2
      elbow ──  lowerArm  ×2  2
        hip ──  upperLeg  ×2  2
       knee ──  lowerLeg  ×2  2
              foot      ×2    2
```

Roughly **13–15 parts per entity**, against 9–13 now. See §5 for the budget.

**Proportions**, as fractions of total height *H* — standard figure-drawing
ratios, which is what makes a shape read as a person at a glance:

| Segment | Fraction of *H* |
|---|---|
| Head | 0.13 |
| Torso (shoulder → hip) | 0.32 |
| Upper leg | 0.24 |
| Lower leg | 0.23 |
| Upper arm | 0.16 |
| Lower arm | 0.15 |
| Shoulder width | 0.25 |
| Hip width | 0.17 |

Leg span is then `0.47H` against a hip height of `0.47H`… which is exactly
the trap above. **Deliberately set hip height to `0.44H`** so the legs carry
about 7% slack and the knee sits visibly bent. Verify with the straightness
probe in §6 before calling it done.

---

## 3. Per-kind differentiation without changing the skeleton

Kinds must stay readable at distance, and that came free from leg count
before. With one skeleton, silhouette has to come from proportion:

| Kind | Height | Build | Read |
|---|---|---|---|
| Skitter | 0.75× | Thin, long-limbed, head low | Scurrying scavenger |
| Lancer | 1.0× | Lean, long arms | Holds a weapon at range |
| Sentry | 0.9× | **Legless — mounted on the tripod it already has** | Turret, must be flanked |
| Hauler | 1.4× | Very wide shoulders, short legs, no neck | Immovable |
| Reclaimer | 1.15× | Broad, long arms, forward hunch | Hunter |
| Warden | 1.6× | Massive, armour slabs over torso | Boss silhouette |

The Sentry keeping its tripod is the point: it is the one kind that genuinely
never walks (`speed = 0`, `behavior = "Static"`), so giving it legs it never
uses is a lie the animation would have to keep telling.

---

## 4. Animation

The arms are the real win: they need no IK at all.

- **Legs** — existing `StepPlanner` + `TwoBoneIk`, unchanged. Two legs, groups
  `{1, 2}`. This already works; only the geometry changes.
- **Arms** — procedural counter-swing driven by leg phase. Left arm swings
  with right leg. `armAngle = legPhase * ARM_SWING`, no solver. This is what
  sells "walking" more than the legs do.
- **Torso** — bob and lean from `StepPlanner.bodyHeight` (already computed and
  currently only used for height) plus a small roll into turns.
- **Head** — track the player when in `attack` range. Cheap, and it is the
  single strongest signal that something has noticed you.

Attack state should visibly differ: a raised arm, a lunge, or a recoil. Right
now `attack` looks identical to `idle`, which is why enemy damage felt like it
came from nowhere even after it was wired.

---

## 5. Performance budget — the real risk

Current measured cost, and the headroom left:

| | Parts/entity | animation + IK | Budget |
|---|---:|---:|---:|
| Boxes (M7-10) | 1 | 0.439 ms | 2.0 ms |
| Legged rig, 32 entities | 9–13 | **1.494 ms** | 2.0 ms |
| Humanoid, projected | 13–15 | **~1.8–2.1 ms** | 2.0 ms |

**This will not fit at 32 entities without changes.** Plan for it up front
rather than discovering it:

1. **Tighten the `full` LOD band** from 40 studs. 25 of 32 entities currently
   qualify for full IK; at 25 studs that should roughly halve.
2. **Arms only at `full`.** They are the cheapest thing to drop and the
   least missed at distance.
3. **Consider `reduced` = torso + legs, no arms/head.**
4. Re-run the M7-10 profile and update `docs/metrics/m7.md`, which is already
   stale at 0.439 ms.

---

## 6. Verification

Do these *before* judging the look, since two rounds of eyeballing have now
been wrong where a measurement was right:

- **Straightness probe.** Sample `direct / (upper + lower)` per limb across
  ~60 frames. Target **mean 0.75–0.90**; anything above 0.95 is a stick. This
  is the single number that decides whether it reads as a machine.
- **Stranded limbs.** Zero limbs more than one body-length from their body,
  across 100 frames. Already a known failure mode at `reduced` tier.
- **Group alternation** still holds every frame (`tests/stepPlanner.spec`).
- **Frame profile** at 32 entities against the 2.0 ms budget.
- **Screenshot each kind individually**, spaced apart, not in a pile — every
  previous screenshot was a crowd and hid the per-kind silhouette.

---

## 7. Sequencing

1. `config/Rigs.luau` → humanoid proportions, one skeleton scaled per kind.
   Keep the Sentry's tripod as a special case.
2. `client/EntityRig.luau` → build/pool 15 parts; extend `placeLimb` usage to
   arms; park all limbs on hide (already done for legs).
3. `EntityRenderer` → drive arms from leg phase; head tracking in `attack`.
4. Re-tune the LOD bands and re-profile.
5. Run §6 in full.

Steps 1–2 are the bulk. Nothing here touches the server, the netcode, or
pure-core gameplay logic — `kind` already arrives in the snapshot's spare
state bits, and `StepPlanner`/`TwoBoneIk` need no changes at all.
