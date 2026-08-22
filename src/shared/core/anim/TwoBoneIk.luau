--!strict
--[[ M7-1. Two-bone IK solve, law of cosines with a pole vector.

	Given a root (hip/shoulder), a target (foot/hand), and two bone lengths,
	find where the joint (knee/elbow) has to be. Pure math -- no Roblox types
	-- so the whole thing is unit-tested against hand-computed values rather
	than eyeballed in a viewport.

	The solve: place the joint on the circle of points that are `upperLength`
	from the root and `lowerLength` from the target. That circle is centred on
	the root->target axis, and the pole vector picks *which* point on it, which
	is what stops a knee from snapping inside out between frames.

	    a = (L1^2 + d^2 - L2^2) / (2d)     -- distance along the axis
	    h = sqrt(L1^2 - a^2)               -- perpendicular offset
	    joint = root + axis*a + perp*h

	**Out-of-range targets are handled by clamping `d`, not by branching.**
	A target further than `L1 + L2` clamps to exactly that, which makes
	`a = L1` and `h = 0` -- the leg straightens toward the target, which is
	precisely the documented "extend straight toward it" behaviour, and it
	falls out of the same arithmetic instead of needing its own code path. A
	target closer than `|L1 - L2|` clamps the other way and folds the leg flat
	along the axis. Both report `reachable = false` so the caller can decide
	between stretching and taking a step; docs/08 leaves that decision to the
	step planner deliberately.

	Two genuinely degenerate inputs have to be caught before the arithmetic,
	because both make the axis undefined rather than merely extreme:
	  - root and target coincide, so there is no direction to build an axis
	    from. `poleDir` becomes the axis, which keeps the result deterministic
	    and pointing somewhere sensible rather than NaN.
	  - `poleDir` parallel to the axis, so its perpendicular component is zero
	    and there is no plane to solve in. Any perpendicular will do; one is
	    constructed from whichever cardinal axis is least aligned, which is
	    stable frame to frame because it depends only on the axis itself.
]]

local Types = require("../Types")

local TwoBoneIk = {}

local EPSILON = 1e-6

--- Some unit vector perpendicular to `v`. Used only when the caller's pole
--- vector is unusable; picking the least-aligned cardinal axis avoids the
--- near-parallel case that would make the cross product tiny and unstable.
local function anyPerpendicular(v: Types.Vec3): Types.Vec3
	local ax, ay, az = math.abs(v.x), math.abs(v.y), math.abs(v.z)
	local reference: Types.Vec3
	if ax <= ay and ax <= az then
		reference = Types.vec3(1, 0, 0)
	elseif ay <= az then
		reference = Types.vec3(0, 1, 0)
	else
		reference = Types.vec3(0, 0, 1)
	end
	-- cross(v, reference), normalised.
	local cross = Types.vec3(
		v.y * reference.z - v.z * reference.y,
		v.z * reference.x - v.x * reference.z,
		v.x * reference.y - v.y * reference.x
	)
	return Types.normalize(cross)
end

--- Returns the joint (knee/elbow) position and whether the target was
--- reachable. When unreachable, extends straight toward the target so the
--- caller can decide between stretching and stepping.
function TwoBoneIk.solve(
	rootPos: Types.Vec3,
	targetPos: Types.Vec3,
	upperLength: number,
	lowerLength: number,
	poleDir: Types.Vec3
): (Types.Vec3, boolean)
	local toTarget = Types.subVec3(targetPos, rootPos)
	local distance = Types.magnitude(toTarget)

	local minReach = math.abs(upperLength - lowerLength)
	local maxReach = upperLength + lowerLength
	local reachable = distance >= minReach - EPSILON and distance <= maxReach + EPSILON

	-- Root and target coincide: there is no axis. Fall back to the pole
	-- direction so the answer is deterministic instead of NaN.
	local axis: Types.Vec3
	if distance < EPSILON then
		local poleLength = Types.magnitude(poleDir)
		axis = if poleLength < EPSILON then Types.vec3(0, 1, 0) else Types.normalize(poleDir)
	else
		axis = Types.scaleVec3(toTarget, 1 / distance)
	end

	-- Clamp into the annulus the two bones can actually span. Outside it the
	-- clamp produces the straight-extension / fully-folded poses described in
	-- the header, using the same arithmetic as the general case.
	local solveDistance = math.clamp(distance, minReach, maxReach)

	local along: number
	if solveDistance < EPSILON then
		-- Both bones equal length and the target is on the root: the joint sits
		-- anywhere on a sphere of radius L1. Put it out along the axis.
		along = 0
	else
		along = (upperLength * upperLength + solveDistance * solveDistance - lowerLength * lowerLength)
			/ (2 * solveDistance)
	end

	-- Guard the sqrt: floating point can push this a hair negative at the
	-- exactly-reachable boundary, where it is mathematically exactly zero.
	local perpendicularSquared = upperLength * upperLength - along * along
	local perpendicularLength = if perpendicularSquared > 0 then math.sqrt(perpendicularSquared) else 0

	-- The pole vector's component perpendicular to the axis chooses the point
	-- on the solution circle. Its component *along* the axis says nothing
	-- about which way the joint bends, so it is projected out.
	local poleAlongAxis = poleDir.x * axis.x + poleDir.y * axis.y + poleDir.z * axis.z
	local poleProjected = Types.subVec3(poleDir, Types.scaleVec3(axis, poleAlongAxis))
	local perpendicular: Types.Vec3
	if Types.magnitude(poleProjected) < EPSILON then
		perpendicular = anyPerpendicular(axis)
	else
		perpendicular = Types.normalize(poleProjected)
	end

	local joint = Types.addVec3(
		Types.addVec3(rootPos, Types.scaleVec3(axis, along)),
		Types.scaleVec3(perpendicular, perpendicularLength)
	)
	return joint, reachable
end

return TwoBoneIk
