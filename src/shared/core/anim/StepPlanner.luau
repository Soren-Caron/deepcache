--!strict
--[[ M7-2. Procedural gait.

	Legs are grouped into alternating sets so opposing legs never lift at the
	same time — that alternation is what reads as a gait rather than a shuffle.

	Each frame, every leg computes where it *wants* to be: its rest offset in
	body space, pushed forward by `velocity * STEP_LEAD` so the foot lands
	where the body is going rather than where it has been, then resolved to
	ground by the caller's `groundAt`. If that desired spot has drifted more
	than `STEP_THRESHOLD` from where the foot actually is, the leg wants to
	step.

	**Wanting to step and being allowed to step are different things**, and the
	gap between them is the whole design. A leg only commits if its group is
	clear — no leg in the *other* group is mid-step. Without that gate, four
	legs that all drift past the threshold on the same frame all lift on the
	same frame, and the entity hops. docs/08 calls this out as the difference
	between a gait and a shuffle, and it is the invariant the tests pin down.

	Once committed, a step is *atomic*: it runs to completion over
	`STEP_DURATION` along a parabolic arc, and nothing re-plans it partway. A
	planner that re-targeted a foot in flight produces a visible stutter every
	time the body changes direction, which is exactly when it is most visible.

	Pure: no raycasts, no clock. `groundAt` is injected — a real raycast in the
	adapter, a plane or a staircase function in tests — which is what makes a
	gait testable on arbitrary terrain without a running game.
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
	--- Which group started the most recent step. The next step prefers a
	--- different group; see `step` for why that is load-bearing rather than
	--- cosmetic.
	lastSteppedGroup: number,
}

local StepPlanner = {}

StepPlanner.STEP_THRESHOLD = 1.2
StepPlanner.STEP_DURATION = 0.28
StepPlanner.STEP_LEAD = 0.35

--- Peak height of the swing arc. Enough to clear the lip of a stair without
--- looking like the entity is prancing.
StepPlanner.STEP_ARC_HEIGHT = 0.45

--- A foot is "planted" at phase 0 exactly. Anything above is in flight.
local function isPlanted(leg: Leg): boolean
	return leg.stepPhase <= 0
end

function StepPlanner.new(restOffsets: { Types.Vec3 }, groups: { number }): GaitState
	local legs: { Leg } = {}
	for index, offset in restOffsets do
		local position = Types.vec3(offset.x, offset.y, offset.z)
		legs[index] = {
			restOffset = Types.vec3(offset.x, offset.y, offset.z),
			-- Feet start planted at their rest offsets rather than at the
			-- origin: an entity's first frame should be a stance, not every
			-- leg simultaneously deciding it is 5 studs from where it belongs
			-- and trying to step.
			current = position,
			target = Types.vec3(position.x, position.y, position.z),
			stepPhase = 0,
			group = groups[index] or 1,
		}
	end
	local seed: GaitState = { legs = legs, bodyHeight = 0, lastSteppedGroup = 0 }
	seed.bodyHeight = StepPlanner.bodyHeight(seed)
	return seed
end

--- Where this leg would like its foot, in world space, before grounding.
local function desiredFoot(leg: Leg, bodyPos: Types.Vec3, velocity: Types.Vec3): Types.Vec3
	return Types.addVec3(
		Types.addVec3(bodyPos, leg.restOffset),
		Types.scaleVec3(velocity, StepPlanner.STEP_LEAD)
	)
end

--- Is any leg outside `group` currently in flight?
local function opposingGroupInFlight(state: GaitState, group: number): boolean
	for _, leg in state.legs do
		if leg.group ~= group and not isPlanted(leg) then
			return true
		end
	end
	return false
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
	if dt <= 0 then
		return state
	end
	local phaseRate = dt / StepPlanner.STEP_DURATION

	-- Advance every step already in flight first. Doing this before deciding
	-- new steps means a leg that lands this frame frees its group for the
	-- other side immediately, instead of costing a frame of stalled gait.
	for _, leg in state.legs do
		if not isPlanted(leg) then
			local phase = leg.stepPhase + phaseRate
			if phase >= 1 then
				leg.stepPhase = 0
				leg.current = Types.vec3(leg.target.x, leg.target.y, leg.target.z)
			else
				leg.stepPhase = phase
			end
		end
	end

	-- Then consider new steps. Collect everyone who wants one first, because
	-- the choice of *which* group moves cannot be made one leg at a time.
	local wantingLegs: { Leg } = {}
	local wantingTargets: { Types.Vec3 } = {}
	for _, leg in state.legs do
		if not isPlanted(leg) then
			continue
		end
		local desired = groundAt(desiredFoot(leg, bodyPos, velocity))
		if Types.distance(desired, leg.current) > StepPlanner.STEP_THRESHOLD then
			table.insert(wantingLegs, leg)
			table.insert(wantingTargets, desired)
		end
	end

	if #wantingLegs > 0 then
		-- **Prefer a group other than the one that stepped last.** Serving
		-- whoever asks first instead starves the other side completely: a leg
		-- lands and, still inside this same call, is planted again and
		-- immediately past the threshold, so it re-commits before any other
		-- group is ever considered. Its group is then permanently in flight,
		-- the opposing gate below never opens, and the other legs simply never
		-- move. Measured before this fix, walking a quadruped 900 frames: 2
		-- steps for group 1, zero for group 2, with group 2's feet left 90
		-- studs behind the body. Alternation has to be chosen, not hoped for.
		local serveGroup = wantingLegs[1].group
		for _, leg in wantingLegs do
			if leg.group ~= state.lastSteppedGroup then
				serveGroup = leg.group
				break
			end
		end

		-- The opposing set still has to be fully planted. With one group this
		-- is vacuously true, so a single-legged entity still walks.
		if not opposingGroupInFlight(state, serveGroup) then
			for index, leg in wantingLegs do
				if leg.group == serveGroup then
					leg.target = wantingTargets[index]
					-- Nudged off zero rather than set to zero, so the leg reads
					-- as in flight on this very frame. Leaving it at 0 would let
					-- the opposing group see a fully planted set and lift on the
					-- same frame -- the exact simultaneity the gate prevents.
					leg.stepPhase = math.min(phaseRate, 0.999)
				end
			end
			state.lastSteppedGroup = serveGroup
		end
	end

	state.bodyHeight = StepPlanner.bodyHeight(state)
	return state
end

--- Current world position of a foot, including the swing arc when in flight.
--- The arc is a parabola peaking at mid-step, eased so the foot leaves and
--- lands slowly rather than snapping.
function StepPlanner.footPosition(leg: Leg): Types.Vec3
	if isPlanted(leg) then
		return leg.current
	end
	local phase = leg.stepPhase
	-- Smoothstep along the ground path: constant-speed interpolation makes
	-- the foot appear to jerk at both ends of the step.
	local eased = phase * phase * (3 - 2 * phase)
	local flat = Types.lerpVec3(leg.current, leg.target, eased)
	-- 4*p*(1-p) peaks at exactly 1 when p = 0.5, and is 0 at both ends.
	local lift = 4 * phase * (1 - phase) * StepPlanner.STEP_ARC_HEIGHT
	return Types.vec3(flat.x, flat.y + lift, flat.z)
end

--- Body height follows the mean of planted feet.
---
--- Planted feet only, deliberately: a foot in flight is by definition not
--- supporting the body, and averaging it in would make the body bob upward
--- every time a leg swung through the top of its arc. With every foot in
--- flight there is nothing supporting the body, so the previous height is the
--- only honest answer -- falling to zero would drop the body through the floor
--- for a frame.
function StepPlanner.bodyHeight(state: GaitState): number
	local total, count = 0, 0
	for _, leg in state.legs do
		if isPlanted(leg) then
			total += leg.current.y
			count += 1
		end
	end
	if count == 0 then
		return state.bodyHeight
	end
	return total / count
end

--- How many legs are mid-step. Diagnostics and the LOD scheduler use this.
function StepPlanner.legsInFlight(state: GaitState): number
	local count = 0
	for _, leg in state.legs do
		if not isPlanted(leg) then
			count += 1
		end
	end
	return count
end

return StepPlanner
