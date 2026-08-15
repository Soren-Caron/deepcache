--!strict
--[[ M7-2. Procedural gait.

	Legs are grouped into alternating sets so opposing legs never lift at the
	same time — that alternation is what reads as a gait rather than a shuffle.
]]

local Types = require("../Types")

export type Leg = {
	restOffset: Types.Vec3,
	current: Types.Vec3,
	target: Types.Vec3,
	stepPhase: number, -- 0 = planted, (0,1) = mid-step
	group: number,
}

export type GaitState = {
	legs: { Leg },
	bodyHeight: number,
}

local StepPlanner = {}

StepPlanner.STEP_THRESHOLD = 1.2
StepPlanner.STEP_DURATION = 0.28
StepPlanner.STEP_LEAD = 0.35

function StepPlanner.new(restOffsets: { Types.Vec3 }, groups: { number }): GaitState
	error("unimplemented: StepPlanner.new (M7-2)")
end

--- Advance the gait. `groundAt` resolves a desired foot position to ground
--- (a raycast in the adapter, a plane in tests).
function StepPlanner.step(
	state: GaitState,
	bodyPos: Types.Vec3,
	velocity: Types.Vec3,
	dt: number,
	groundAt: (Types.Vec3) -> Types.Vec3
): GaitState
	error("unimplemented: StepPlanner.step (M7-2)")
end

--- Body height follows the mean of planted feet.
function StepPlanner.bodyHeight(state: GaitState): number
	error("unimplemented: StepPlanner.bodyHeight (M7-2)")
end

return StepPlanner
