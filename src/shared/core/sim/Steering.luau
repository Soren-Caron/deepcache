--!strict
--[[ M1-4. Steering behaviours. Pure vector math, no pathfinding. ]]

local Types = require("../Types")

local Steering = {}

--- Desired velocity toward a target.
function Steering.seek(pos: Types.Vec3, target: Types.Vec3, maxSpeed: number): Types.Vec3
	error("unimplemented: Steering.seek (M1-4)")
end

--- Push away from neighbours within `radius`, weighted by closeness.
function Steering.separate(pos: Types.Vec3, neighbours: { Types.Vec3 }, radius: number): Types.Vec3
	error("unimplemented: Steering.separate (M1-4)")
end

--- Steer around an obstacle directly ahead.
function Steering.avoid(pos: Types.Vec3, velocity: Types.Vec3, obstacle: Types.Vec3, radius: number): Types.Vec3
	error("unimplemented: Steering.avoid (M1-4)")
end

--- Hold a preferred distance from a target — Lancer behaviour.
function Steering.keepDistance(
	pos: Types.Vec3,
	target: Types.Vec3,
	preferred: number,
	maxSpeed: number
): Types.Vec3
	error("unimplemented: Steering.keepDistance (M1-4)")
end

--- Weighted blend, clamped to maxSpeed.
function Steering.combine(forces: { { force: Types.Vec3, weight: number } }, maxSpeed: number): Types.Vec3
	error("unimplemented: Steering.combine (M1-4)")
end

return Steering
