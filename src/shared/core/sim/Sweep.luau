--!strict
--[[ The melee sweep: one arc, several targets, on a cooldown.

	Every weapon in the roster is a ray. That leaves one hole in the fight: a
	Skitter swarm closing to four studs is a target you cannot miss and cannot
	efficiently clear, because a hitscan round kills exactly one of them. The
	sweep is the answer to being surrounded, which is why it is an area
	attack on a long cooldown rather than another gun.

	Pure, and the interesting part is entirely geometric:

	  - **The arc is measured from the player's facing**, not from the camera.
	    A sweep is a body movement; letting it follow the camera would let a
	    player hit something behind them by flicking the mouse.
	  - **A target's hitbox counts.** Reach is measured to the *surface* of the
	    hitbox, not its centre, so a Warden four studs wide is caught from
	    further out than a Skitter. Measuring to centres makes big enemies
	    harder to hit with a sweep than small ones, which is backwards.
	  - **Damage is flat inside the arc.** A sweep connects or it does not.
	    Distance falloff on a twelve-stud swing would be a number nobody can
	    perceive, and it would make the edge of the arc feel broken rather than
	    marginal.

	Time is injected, so the cooldown is testable without a clock.
]]

local Types = require("../Types")

local Sweep = {}

export type Params = {
	damage: number,
	--- Full width of the arc in radians; a target is hit if it lies within
	--- half of this either side of the facing.
	arcRadians: number,
	--- Reach from the player, to the near surface of a target's hitbox.
	radius: number,
	cooldownSeconds: number,
}

export type Hit = {
	entityId: number,
	distance: number,
	damage: number,
}

export type Visibility = (from: Types.Vec3, to: Types.Vec3) -> boolean

--- Is the sweep off cooldown?
---
--- Returns `(false, reason)` rather than throwing, matching how every other
--- refusal in this project reports itself. `lastUsedAt` is nil when the player
--- has never swung.
function Sweep.ready(lastUsedAt: number?, now: number, cooldownSeconds: number): (boolean, string?)
	if now ~= now or now == math.huge or now == -math.huge then
		return false, "bad_clock"
	end
	if lastUsedAt == nil then
		return true
	end
	-- A clock that ran backwards must not grant a free swing.
	local elapsed = now - lastUsedAt
	if elapsed < 0 then
		return false, "cooling_down"
	end
	if elapsed < cooldownSeconds then
		return false, "cooling_down"
	end
	return true
end

--- Seconds until the sweep is available again, 0 when ready. For a HUD.
function Sweep.remaining(lastUsedAt: number?, now: number, cooldownSeconds: number): number
	if lastUsedAt == nil or now ~= now then
		return 0
	end
	return math.clamp(cooldownSeconds - (now - lastUsedAt), 0, cooldownSeconds)
end

--- Signed angle between a facing yaw and the direction to a point, in radians,
--- always in [0, pi] because only the magnitude matters for an arc.
local function angleTo(facingYaw: number, dx: number, dz: number): number
	local targetYaw = math.atan2(dx, dz)
	local delta = targetYaw - facingYaw
	-- Wrap into -pi..pi so an arc straddling the yaw discontinuity behaves.
	while delta > math.pi do
		delta -= math.pi * 2
	end
	while delta < -math.pi do
		delta += math.pi * 2
	end
	return math.abs(delta)
end

--- Everything the swing connects with.
---
--- `origin` is the player's position and `facingYaw` the direction they face,
--- both supplied by the server from the character -- never by the client, which
--- would otherwise be able to sweep the whole level from anywhere.
---
--- Results are sorted nearest-first so a caller applying a kill limit takes the
--- closest targets, and so the order does not depend on table iteration.
function Sweep.resolve(
	origin: Types.Vec3,
	facingYaw: number,
	targets: { Types.EntityView },
	radiusById: { [number]: number },
	params: Params,
	skipStates: { [Types.EntityStateName]: boolean }?,
	canSee: Visibility?
): { Hit }
	local skip = skipStates or {}
	local out: { Hit } = {}
	local halfArc = params.arcRadians / 2

	for _, target in targets do
		if skip[target.state] then
			continue
		end
		local hitboxRadius = radiusById[target.id]
		if hitboxRadius == nil then
			continue
		end

		local dx = target.pos.x - origin.x
		local dz = target.pos.z - origin.z
		local centreDistance = math.sqrt(dx * dx + dz * dz)

		-- Reach to the hitbox surface, so a wide enemy is caught from further
		-- out than a narrow one standing in the same place.
		local surfaceDistance = centreDistance - hitboxRadius
		if surfaceDistance > params.radius then
			continue
		end

		-- A target the player is standing inside has no meaningful bearing, so
		-- it is always in the arc rather than being decided by float noise.
		if centreDistance > 1e-4 and angleTo(facingYaw, dx, dz) > halfArc then
			continue
		end

		-- Walls stop a sword too. Optional so the pure tests need no engine.
		if canSee ~= nil and not canSee(origin, target.pos) then
			continue
		end

		table.insert(out, {
			entityId = target.id,
			distance = math.max(0, surfaceDistance),
			damage = params.damage,
		})
	end

	table.sort(out, function(a, b)
		if a.distance == b.distance then
			return a.entityId < b.entityId
		end
		return a.distance < b.distance
	end)
	return out
end

return Sweep
