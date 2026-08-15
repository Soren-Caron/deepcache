--!strict
--[[
	Ray-sphere intersection against entity hitboxes.

	Entities have no server-side Instance, so hit detection against them cannot
	use Roblox's raycaster — and that turns out to be an advantage: this is pure
	math, so the exact geometry that decides whether a shot landed is unit
	tested rather than trusted.

	World geometry is a separate concern. CombatService raycasts the level with
	the engine to find the nearest wall, then only accepts entity hits closer
	than that. Two systems, each doing what it is good at.
]]

local Types = require("../Types")

local Raycast = {}

export type SphereHit = {
	entityId: number,
	distance: number,
	point: Types.Vec3,
}

--- Distance along `direction` at which the ray first meets the sphere, or nil.
---
--- `direction` must be normalised. A ray starting inside the sphere returns 0:
--- point-blank contact is a hit, not a miss.
function Raycast.raySphere(
	origin: Types.Vec3,
	direction: Types.Vec3,
	center: Types.Vec3,
	radius: number
): number?
	if radius <= 0 then
		return nil
	end

	local toCenter = Types.subVec3(center, origin)
	local projection = toCenter.x * direction.x + toCenter.y * direction.y + toCenter.z * direction.z

	local centerDistanceSq = toCenter.x * toCenter.x + toCenter.y * toCenter.y + toCenter.z * toCenter.z
	local radiusSq = radius * radius

	-- Origin inside the hitbox.
	if centerDistanceSq <= radiusSq then
		return 0
	end

	-- Sphere is entirely behind the ray.
	if projection < 0 then
		return nil
	end

	local perpendicularSq = centerDistanceSq - projection * projection
	if perpendicularSq > radiusSq then
		return nil
	end

	local halfChord = math.sqrt(radiusSq - perpendicularSq)
	local entry = projection - halfChord
	if entry < 0 then
		return nil
	end
	return entry
end

--- Nearest entity the ray hits, within `maxDistance`.
---
--- `maxDistance` is normally the distance to the nearest wall, so a shot
--- cannot pass through level geometry to reach a target behind it.
function Raycast.nearestEntity(
	origin: Types.Vec3,
	direction: Types.Vec3,
	entities: { Types.EntityView },
	radiusById: { [number]: number },
	maxDistance: number,
	--- Entities in these states are not hittable (corpses, mid-spawn).
	skipStates: { [Types.EntityStateName]: boolean }?
): SphereHit?
	local skip = skipStates or {}
	local best: SphereHit? = nil

	for _, entity in entities do
		if not skip[entity.state] then
			local radius = radiusById[entity.id]
			if radius ~= nil then
				local distance = Raycast.raySphere(origin, direction, entity.pos, radius)
				if distance ~= nil and distance <= maxDistance then
					if best == nil or distance < best.distance then
						best = {
							entityId = entity.id,
							distance = distance,
							point = Types.addVec3(origin, Types.scaleVec3(direction, distance)),
						}
					end
				end
			end
		end
	end

	return best
end

--- Was the hit in the upper fraction of the hitbox? A cheap headshot test that
--- needs no per-entity bone data.
function Raycast.isHeadshot(hitPoint: Types.Vec3, center: Types.Vec3, radius: number, headFraction: number?): boolean
	local fraction = headFraction or 0.6
	return hitPoint.y >= center.y + radius * fraction
end

return Raycast
