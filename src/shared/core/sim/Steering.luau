--!strict
--[[
	Steering behaviours. Pure vector math — no pathfinding, no raycasts.

	Long-range routing is the waypoint graph's job (built at level assembly);
	these handle the last few studs: closing distance, not overlapping, not
	walking into a wall. Roblox PathfindingService per-entity is far too slow
	at 40+ entities, which is why routing and steering are separate layers.

	All behaviours work in the XZ plane. Entities are ground-bound; y is
	carried through untouched rather than steered.
]]

local Types = require("../Types")

local Steering = {}

local EPSILON = 1e-6

local function flatten(v: Types.Vec3): Types.Vec3
	return { x = v.x, y = 0, z = v.z }
end

--- Desired velocity straight at a target. Zero when already there, rather
--- than a NaN from normalising a zero-length vector.
function Steering.seek(pos: Types.Vec3, target: Types.Vec3, maxSpeed: number): Types.Vec3
	local offset = flatten(Types.subVec3(target, pos))
	if Types.magnitude(offset) < EPSILON then
		return { x = 0, y = 0, z = 0 }
	end
	return Types.scaleVec3(Types.normalize(offset), maxSpeed)
end

--- Push away from crowding neighbours, weighted by closeness so contact
--- pushes hard and the edge of the radius barely pushes at all.
function Steering.separate(pos: Types.Vec3, neighbours: { Types.Vec3 }, radius: number): Types.Vec3
	if radius <= EPSILON then
		return { x = 0, y = 0, z = 0 }
	end

	local accum = { x = 0, y = 0, z = 0 }
	for _, other in neighbours do
		local offset = flatten(Types.subVec3(pos, other))
		local distance = Types.magnitude(offset)
		if distance < radius then
			if distance < EPSILON then
				-- Exactly co-located. Any direction works, but it must be
				-- deterministic or a replayed simulation diverges.
				accum = Types.addVec3(accum, { x = 1, y = 0, z = 0 })
			else
				local strength = 1 - distance / radius
				accum = Types.addVec3(accum, Types.scaleVec3(Types.normalize(offset), strength))
			end
		end
	end
	return accum
end

--- Steer laterally around an obstacle that lies ahead. Returns zero when the
--- obstacle is behind, beside, or out of range — an entity should not swerve
--- around something it has already passed.
function Steering.avoid(
	pos: Types.Vec3,
	velocity: Types.Vec3,
	obstacle: Types.Vec3,
	radius: number
): Types.Vec3
	local forward = flatten(velocity)
	if Types.magnitude(forward) < EPSILON then
		return { x = 0, y = 0, z = 0 }
	end
	forward = Types.normalize(forward)

	local toObstacle = flatten(Types.subVec3(obstacle, pos))
	local distance = Types.magnitude(toObstacle)
	if distance < EPSILON or distance > radius then
		return { x = 0, y = 0, z = 0 }
	end

	local direction = Types.normalize(toObstacle)
	local ahead = forward.x * direction.x + forward.z * direction.z
	if ahead <= 0 then
		return { x = 0, y = 0, z = 0 }
	end

	-- Left-hand perpendicular in XZ.
	local left = { x = -forward.z, y = 0, z = forward.x }
	-- Steer away from whichever side the obstacle sits on. Dead-centre
	-- (side == 0) resolves to the left rather than deadlocking head-on.
	local side = left.x * direction.x + left.z * direction.z
	local away = if side > 0 then Types.scaleVec3(left, -1) else left

	-- Closer and more head-on both increase urgency.
	local urgency = (1 - distance / radius) * ahead
	return Types.scaleVec3(away, urgency)
end

--- Hold a preferred standoff distance — Lancer behaviour. The dead band stops
--- an entity oscillating across the exact preferred radius every tick.
function Steering.keepDistance(
	pos: Types.Vec3,
	target: Types.Vec3,
	preferred: number,
	maxSpeed: number
): Types.Vec3
	local offset = flatten(Types.subVec3(target, pos))
	local distance = Types.magnitude(offset)
	if distance < EPSILON then
		return { x = 0, y = 0, z = 0 }
	end

	local direction = Types.normalize(offset)
	local inner = preferred * 0.9
	local outer = preferred * 1.1

	if distance < inner then
		return Types.scaleVec3(direction, -maxSpeed)
	elseif distance > outer then
		return Types.scaleVec3(direction, maxSpeed)
	end
	return { x = 0, y = 0, z = 0 }
end

--- Weighted sum, clamped to maxSpeed.
function Steering.combine(forces: { { force: Types.Vec3, weight: number } }, maxSpeed: number): Types.Vec3
	local accum = { x = 0, y = 0, z = 0 }
	for _, entry in forces do
		accum = Types.addVec3(accum, Types.scaleVec3(entry.force, entry.weight))
	end

	local magnitude = Types.magnitude(accum)
	if magnitude > maxSpeed and magnitude > EPSILON then
		accum = Types.scaleVec3(accum, maxSpeed / magnitude)
	end
	return accum
end

--- Yaw an entity should face while moving with `velocity`. Returns
--- `currentYaw` when nearly stationary, so a stopped entity keeps facing where
--- it was rather than snapping to zero.
---
--- `minMagnitude` guards against a hypersensitive direction: the raw EPSILON
--- floor only rejects a *numerically* degenerate vector, but a 0.3-stud offset
--- is numerically fine and directionally violent — sub-stud movement by the
--- target swings its angle through tens of degrees per tick. Callers facing a
--- nearby target pass a real standoff distance here instead.
function Steering.facingYaw(velocity: Types.Vec3, currentYaw: number, minMagnitude: number?): number
	local flat = flatten(velocity)
	local floor = math.max(minMagnitude or 0, EPSILON)
	if Types.magnitude(flat) < floor then
		return currentYaw
	end
	return math.atan2(flat.x, flat.z)
end

--- Shortest signed angular difference from `from` to `to`, in (-pi, pi].
--- Turning 350 degrees left is really 10 degrees right, and an entity that does
--- not know that spins the long way round every time it crosses the seam.
function Steering.angleDelta(from: number, to: number): number
	local delta = (to - from) % (math.pi * 2)
	if delta > math.pi then
		delta -= math.pi * 2
	end
	return delta
end

--- Rotate `currentYaw` toward `desiredYaw`, capped at `maxTurnRate` rad/s.
---
--- Without this, yaw is assigned straight from `atan2` and an entity can
--- reverse its facing completely between two ticks. Nothing in the world turns
--- instantly, and at 20 Hz an instant reversal reads as a violent spin rather
--- than as a turn. The cap is what makes a crowded melee legible.
function Steering.slewYaw(currentYaw: number, desiredYaw: number, maxTurnRate: number, dt: number): number
	if currentYaw ~= currentYaw or desiredYaw ~= desiredYaw then
		return currentYaw
	end
	if dt <= 0 or dt ~= dt or dt == math.huge then
		return currentYaw
	end
	if maxTurnRate <= 0 or maxTurnRate ~= maxTurnRate then
		return currentYaw
	end

	local delta = Steering.angleDelta(currentYaw, desiredYaw)
	local maxStep = maxTurnRate * dt
	if math.abs(delta) <= maxStep then
		return desiredYaw
	end
	return currentYaw + (if delta > 0 then maxStep else -maxStep)
end

return Steering
