--!strict
--[[ M2-5. Beam ramp and projectile motion.

	The two weapons whose netcode profile differs from plain hitscan:

	  - **Arc** is a beam validated per tick rather than per shot. Damage ramps
	    while the beam stays on one target, which means the server has to carry
	    per-shooter, per-target state between ticks — there is no single "shot"
	    event to validate.
	  - **Slug** is a server-simulated projectile with travel time and drop. It
	    needs no lag compensation at all: the projectile is an entity in the
	    world, so a hit is decided by where the projectile *is*, not by
	    rewinding to where a target *was*.

	Pure motion and curve maths only. Hit resolution belongs to the caller,
	which owns the entity table and `core/sim/Raycast`.
]]

local Types = require("../Types")

local Ballistics = {}

--- How fast sustained-fire credit bleeds off once the beam leaves the target,
--- as a multiple of real time. Faster than it builds, so switching targets
--- costs you the ramp rather than letting you keep it by sweeping.
Ballistics.ARC_DECAY_RATE = 2.0

local function isFinite(value: number): boolean
	return value == value and value ~= math.huge and value ~= -math.huge
end

local function safe(value: number, fallback: number): number
	return if isFinite(value) then value else fallback
end

--------------------------------------------------------------------------------
-- Arc: continuous beam
--------------------------------------------------------------------------------

--- Damage multiplier for a beam that has held one target for `seconds`.
---
--- Compounding rather than linear: `rampPerSecond` reads as a growth factor, so
--- 1.15 means "15% more each second it stays on". Linear growth from the same
--- constant would reach the 3.0 cap in under two seconds and make the ramp
--- meaningless — the whole point is that holding a target is a commitment.
function Ballistics.arcRamp(secondsOnTarget: number, rampPerSecond: number, rampMax: number): number
	local seconds = math.max(0, safe(secondsOnTarget, 0))
	local rate = math.max(1, safe(rampPerSecond, 1))
	local cap = math.max(1, safe(rampMax, 1))
	return math.min(cap, rate ^ seconds)
end

--- Advance sustained-fire credit by one tick. Builds while the beam holds the
--- same target, bleeds off when it does not.
function Ballistics.arcTick(secondsOnTarget: number, dt: number, onTarget: boolean): number
	local current = math.max(0, safe(secondsOnTarget, 0))
	local step = math.max(0, safe(dt, 0))
	if onTarget then
		return current + step
	end
	return math.max(0, current - step * Ballistics.ARC_DECAY_RATE)
end

--- Damage dealt by one tick of beam contact.
function Ballistics.arcDamage(dt: number, damagePerSecond: number, ramp: number): number
	local step = math.max(0, safe(dt, 0))
	local dps = math.max(0, safe(damagePerSecond, 0))
	return dps * step * math.max(0, safe(ramp, 1))
end

--------------------------------------------------------------------------------
-- Slug: projectile with travel time and drop
--------------------------------------------------------------------------------

--- Closed-form position at time `t`. `direction` is expected normalised; it is
--- normalised again here because a caller passing an un-normalised aim vector
--- would otherwise silently change the muzzle velocity.
function Ballistics.positionAt(
	origin: Types.Vec3,
	direction: Types.Vec3,
	speed: number,
	gravity: number,
	t: number
): Types.Vec3
	local dir = Types.normalize(direction)
	local time = math.max(0, safe(t, 0))
	local v = math.max(0, safe(speed, 0))
	local g = math.max(0, safe(gravity, 0))
	return {
		x = origin.x + dir.x * v * time,
		y = origin.y + dir.y * v * time - 0.5 * g * time * time,
		z = origin.z + dir.z * v * time,
	}
end

function Ballistics.velocityAt(direction: Types.Vec3, speed: number, gravity: number, t: number): Types.Vec3
	local dir = Types.normalize(direction)
	local time = math.max(0, safe(t, 0))
	local v = math.max(0, safe(speed, 0))
	local g = math.max(0, safe(gravity, 0))
	return { x = dir.x * v, y = dir.y * v - g * time, z = dir.z * v }
end

--- One integration step, for the projectile entity the server actually ticks.
--- Semi-implicit Euler: velocity updates first, so the position uses the new
--- velocity. It is stable at fixed timesteps and matches the closed form to
--- within half a gravity-step, which at 20 Hz is under two studs at the Slug's
--- range.
function Ballistics.step(
	position: Types.Vec3,
	velocity: Types.Vec3,
	gravity: number,
	dt: number
): (Types.Vec3, Types.Vec3)
	local g = math.max(0, safe(gravity, 0))
	local step = math.max(0, safe(dt, 0))
	local nextVelocity = { x = velocity.x, y = velocity.y - g * step, z = velocity.z }
	local nextPosition = {
		x = position.x + nextVelocity.x * step,
		y = position.y + nextVelocity.y * step,
		z = position.z + nextVelocity.z * step,
	}
	return nextPosition, nextVelocity
end

--- Seconds for a flat shot to cover `distance`.
function Ballistics.timeOfFlight(distance: number, speed: number): number
	local v = safe(speed, 0)
	if v <= 0 then
		return math.huge
	end
	return math.max(0, safe(distance, 0)) / v
end

--- How far a flat shot falls over `distance`. This is the number that makes
--- the Slug feel like a Slug: at 180 studs/s and g = 14, a 120-stud shot drops
--- just over 3 studs, so a body shot at range becomes a leg shot.
function Ballistics.dropOverDistance(distance: number, speed: number, gravity: number): number
	local t = Ballistics.timeOfFlight(distance, speed)
	if t == math.huge then
		return math.huge
	end
	return 0.5 * math.max(0, safe(gravity, 0)) * t * t
end

--- Aim elevation, in radians, that lands a shot on a target `distance` away at
--- the same height. The low-angle solution: the flat one, not the mortar arc.
--- Returns nil when the target is out of ballistic reach.
function Ballistics.launchAngle(distance: number, speed: number, gravity: number): number?
	local d = math.max(0, safe(distance, 0))
	local v = math.max(0, safe(speed, 0))
	local g = math.max(0, safe(gravity, 0))
	if g <= 0 then
		return 0
	end
	if v <= 0 then
		return nil
	end
	local ratio = g * d / (v * v)
	if ratio > 1 or ratio < -1 then
		return nil -- beyond maximum range
	end
	return 0.5 * math.asin(ratio)
end

return Ballistics
