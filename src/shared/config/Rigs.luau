--!strict
--[[ Pure data. R6-shaped body plans for the client rig. See docs/14.

	Enemies use the same skeleton as the player character: rigid limbs that
	swing from fixed joints, no knee, no elbow. Matching the player's own
	silhouette is what makes an enemy read as the same kind of thing rather
	than as an abstract shape.

	Absolute proportions live in `client/EntityRig`, which scales Roblox's own
	R6 defaults (torso 2x2x1, limbs 1x2x1, head 1.25) by `height`. What varies
	per kind here is size, bulk, and posture.

	`build` widens without lengthening: a Hauler is broad, not stretched.
	Scaling both would just produce a larger Skitter.
]]

local Rigs = {}

--- Walk cycle. Legs swing further than arms, which is what real gaits do and
--- what stops the arms reading as flailing.
Rigs.WALK = {
	--- Peak swing from vertical, radians. 0.38 is about 22 degrees, which is
	--- roughly a real walking stride. The first pass used 0.62 (35 degrees)
	--- and read as a lurch rather than a walk.
	legSwing = 0.38,
	armSwing = 0.28,
	--- Speed at which the stride reaches full amplitude.
	fullStrideSpeed = 9,
	--- Seconds for the stride amplitude to follow a change in speed. Without
	--- smoothing, per-frame interpolation jitter makes the measured speed
	--- fluctuate and the swing amplitude pulses with it, which reads as the
	--- body pumping rather than walking.
	strideSmoothing = 0.18,
	--- Stride length is derived per kind from leg length rather than being a
	--- single constant: `cycleStuds = strideFactor * legLength * sin(legSwing)`.
	--- A fixed radians-per-stud makes a tall kind mince and a short kind skate,
	--- because the distance one step covers scales with the leg taking it.
	strideFactor = 4.0,
}

Rigs.kinds = {
	-- Small and light. Scurrying scavenger.
	Skitter = { height = 4.2, build = 0.9, hunch = 0.14 },

	-- Turret. Never walks, so it never swings.
	Sentry = { height = 4.6, build = 1.2, hunch = 0, static = true },

	-- Very wide, heavy. Immovable.
	Hauler = { height = 7.2, build = 1.9, hunch = 0.10 },

	-- Lean, upright, holds a weapon at range.
	Lancer = { height = 5.6, build = 1.0, hunch = 0.04 },

	-- Massive, armoured. Boss silhouette.
	Warden = { height = 8.2, build = 2.2, hunch = 0.07 },

	-- Broad, forward hunch. Built to run you down.
	Reclaimer = { height = 6.2, build = 1.4, hunch = 0.24 },
}

return Rigs
