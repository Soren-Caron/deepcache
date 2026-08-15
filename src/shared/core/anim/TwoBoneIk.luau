--!strict
--[[ M7-1. Two-bone IK solve, law of cosines with a pole vector. ]]

local Types = require("../Types")

local TwoBoneIk = {}

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
	error("unimplemented: TwoBoneIk.solve (M7-1)")
end

return TwoBoneIk
