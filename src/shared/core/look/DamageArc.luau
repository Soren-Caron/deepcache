--!strict
--[[ Where the hit came from, as an angle the HUD can draw.

	Enemies attack from up to 55 studs and the Sentry never moves, so "I am
	being hurt" (the vignette) leaves the player with the wrong question
	answered. The one they actually have is *which way do I turn*, and until
	now nothing on screen could tell them.

	Pure, and deliberately 2D. Pitch is not useful here: an indicator that
	points slightly up because the shooter is on a ledge reads as noise, and
	the player's answer is a yaw either way. Working in the ground plane also
	means this needs no camera object, just its facing — so it tests without an
	engine.

	Angles are screen-relative and signed: 0 is dead ahead, +pi/2 is to the
	player's right, +/-pi is directly behind. That convention is what lets the
	HUD rotate one arc sprite by the returned radians and be done.
]]

local DamageArc = {}

--- Bearing of `delta` relative to a camera facing `(lookX, lookZ)`.
---
--- Both vectors are in the world ground plane; `delta` points *from* the
--- player *to* whatever hit them. Returns radians in [-pi, pi], clockwise
--- positive when viewed from above, which is the direction a GUI `Rotation`
--- turns.
---
--- Returns 0 for degenerate input — a zero-length delta means the attacker is
--- standing exactly where the player is, and pointing anywhere is as good as
--- pointing anywhere else. Nil would push that decision onto every caller for
--- a case none of them can act on.
function DamageArc.bearing(lookX: number, lookZ: number, deltaX: number, deltaZ: number): number
	local lookLength = math.sqrt(lookX * lookX + lookZ * lookZ)
	local deltaLength = math.sqrt(deltaX * deltaX + deltaZ * deltaZ)
	if lookLength < 1e-6 or deltaLength < 1e-6 then
		return 0
	end

	local fx, fz = lookX / lookLength, lookZ / lookLength
	local dx, dz = deltaX / deltaLength, deltaZ / deltaLength

	-- Forward component, and the component along the camera's right. A Roblox
	-- CFrame with LookVector (0, 0, -1) has RightVector (1, 0, 0), so in the
	-- ground plane right is (-look.Z, look.X) -- not (look.Z, -look.X), which
	-- is what this had first and which mirrors every indicator. That is worse
	-- than having none, because the player learns to trust it and then turns
	-- into the shot.
	local forward = fx * dx + fz * dz
	local right = fx * dz - fz * dx

	return math.atan2(right, forward)
end

--- Opacity for an indicator that appeared `age` seconds ago.
---
--- Squared falloff rather than linear: a linear fade spends half its life
--- faintly visible, which reads as a smear when several hits land in a row.
--- Returns 0 once expired, so a caller can hide on exactly that.
function DamageArc.opacity(age: number, lifetime: number): number
	if lifetime <= 0 or age ~= age or age < 0 or age >= lifetime then
		return 0
	end
	local remaining = 1 - age / lifetime
	return remaining * remaining
end

--- Merge a new hit into an existing indicator, or nil if there is none.
---
--- Two attackers on nearly the same bearing should refresh one arrow rather
--- than stack two on top of each other, which just looks like a rendering
--- bug. Beyond the threshold they are genuinely different directions and both
--- deserve to be drawn.
function DamageArc.shouldMerge(existingBearing: number, newBearing: number, thresholdRadians: number): boolean
	local difference = math.abs(existingBearing - newBearing)
	-- Shortest way round the circle: -3.0 and 3.0 rad are 0.28 apart, not 6.0.
	if difference > math.pi then
		difference = math.pi * 2 - difference
	end
	return difference <= thresholdRadians
end

return DamageArc
