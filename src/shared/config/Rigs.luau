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
	legSwing = 0.62,
	armSwing = 0.45,
	--- Radians of cycle per stud travelled. Tuned so a Skitter at 22 studs/s
	--- takes strides rather than sprinting on the spot.
	radiansPerStud = 0.55,
	--- Speed at which the stride reaches full amplitude.
	fullStrideSpeed = 9,
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
