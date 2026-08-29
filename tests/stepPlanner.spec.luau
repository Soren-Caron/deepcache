--!strict
--[[ M7-2. core/anim/StepPlanner -- the three properties docs/08 §Tests names:
	opposing legs never lift simultaneously, a step commits only past the
	threshold, and body height tracks the mean of planted feet.

	The first one is checked as an invariant held across a whole simulated
	walk, not as a single snapshot: a gait that alternates correctly for one
	frame and then desynchronises is exactly the bug worth catching, and only
	a continuous check finds it.
]]

local t = require("./framework")
local expect = t.expect

local StepPlanner = require("../src/shared/core/anim/StepPlanner")
local Types = require("../src/shared/core/Types")

local v3 = Types.vec3

--- A quadruped: front-left and back-right in group 1, front-right and
--- back-left in group 2. That diagonal pairing is the standard trot, and it
--- is what "opposing legs" means below.
local function quadruped(): StepPlanner.GaitState
	return StepPlanner.new({
		v3(1, 0, 1), -- front-left
		v3(-1, 0, 1), -- front-right
		v3(1, 0, -1), -- back-left
		v3(-1, 0, -1), -- back-right
	}, { 1, 2, 2, 1 })
end

--- Flat ground at y = 0.
local function flatGround(p: Types.Vec3): Types.Vec3
	return v3(p.x, 0, p.z)
end

t.describe("StepPlanner.new", function()
	t.it("starts every foot planted at its rest offset", function()
		-- A first frame should be a stance. Feet starting at the origin would
		-- have every leg instantly past the step threshold.
		local state = quadruped()
		expect(#state.legs).toEqual(4)
		for i, leg in state.legs do
			expect(leg.stepPhase).toEqual(0)
			expect(leg.current.x).toEqual(leg.restOffset.x)
			expect(leg.current.z).toEqual(leg.restOffset.z)
		end
		expect(StepPlanner.legsInFlight(state)).toEqual(0)
	end)

	t.it("assigns the groups it was given", function()
		local state = quadruped()
		expect(state.legs[1].group).toEqual(1)
		expect(state.legs[2].group).toEqual(2)
		expect(state.legs[3].group).toEqual(2)
		expect(state.legs[4].group).toEqual(1)
	end)
end)

t.describe("StepPlanner: a step commits only past the threshold", function()
	t.it("a stationary body never lifts a foot", function()
		local state = quadruped()
		for _ = 1, 60 do
			state = StepPlanner.step(state, v3(0, 0, 0), v3(0, 0, 0), 1 / 60, flatGround)
			expect(StepPlanner.legsInFlight(state)).toEqual(0)
		end
	end)

	t.it("drift below the threshold does not trigger a step", function()
		-- STEP_LEAD * velocity is the whole displacement here. Keep it under
		-- STEP_THRESHOLD (1.2) and nothing should move.
		local state = quadruped()
		local velocity = v3(StepPlanner.STEP_THRESHOLD * 0.5 / StepPlanner.STEP_LEAD, 0, 0)
		state = StepPlanner.step(state, v3(0, 0, 0), velocity, 1 / 60, flatGround)
		expect(StepPlanner.legsInFlight(state)).toEqual(0)
	end)

	t.it("drift past the threshold does trigger a step", function()
		local state = quadruped()
		local velocity = v3(StepPlanner.STEP_THRESHOLD * 2 / StepPlanner.STEP_LEAD, 0, 0)
		state = StepPlanner.step(state, v3(0, 0, 0), velocity, 1 / 60, flatGround)
		expect(StepPlanner.legsInFlight(state) > 0).toBeTruthy()
	end)

	t.it("a committed step runs to completion without being re-planned", function()
		-- Re-targeting a foot in flight produces a visible stutter exactly when
		-- the body changes direction, which is when it is most noticeable.
		local state = quadruped()
		local fast = v3(20, 0, 0)
		state = StepPlanner.step(state, v3(0, 0, 0), fast, 1 / 60, flatGround)

		local moving = nil
		for _, leg in state.legs do
			if leg.stepPhase > 0 then
				moving = leg
				break
			end
		end
		expect(moving).never().toEqual(nil :: any)
		local committedTarget = (moving :: StepPlanner.Leg).target
		local targetX = committedTarget.x

		-- Yank the body the other way mid-step; the target must not move.
		for _ = 1, 3 do
			state = StepPlanner.step(state, v3(-50, 0, 0), v3(-40, 0, 0), 1 / 60, flatGround)
			if (moving :: StepPlanner.Leg).stepPhase > 0 then
				expect((moving :: StepPlanner.Leg).target.x).toEqual(targetX)
			end
		end
	end)

	t.it("a completed step leaves the foot exactly on its target", function()
		local state = quadruped()
		state = StepPlanner.step(state, v3(0, 0, 0), v3(20, 0, 0), 1 / 60, flatGround)
		local moving: StepPlanner.Leg? = nil
		for _, leg in state.legs do
			if leg.stepPhase > 0 then
				moving = leg
				break
			end
		end
		expect(moving).never().toEqual(nil :: any)
		local leg = moving :: StepPlanner.Leg
		local target = v3(leg.target.x, leg.target.y, leg.target.z)

		-- Watch for `current` reaching the committed target, rather than for
		-- `stepPhase` returning to 0. Two things make the phase unobservable
		-- here: with the body left at the origin the foot is now far from its
		-- rest offset, so it legitimately wants to step straight back, and a
		-- leg that lands can re-commit inside the *same* `step` call — so the
		-- planted moment never appears to a caller polling between frames.
		-- What the accept criterion actually claims is that a completed step
		-- puts the foot exactly on the position it committed to, and that is
		-- what is checked.
		local landedOnTarget = false
		for _ = 1, 40 do
			state = StepPlanner.step(state, v3(0, 0, 0), v3(0, 0, 0), 1 / 60, flatGround)
			if math.abs(leg.current.x - target.x) < 1e-9 and math.abs(leg.current.z - target.z) < 1e-9 then
				landedOnTarget = true
				break
			end
		end
		expect(landedOnTarget).toBeTruthy()
	end)
end)

t.describe("StepPlanner: opposing legs never lift together", function()
	--- The invariant, checked every frame of a real walk rather than once.
	local function assertNeverBothGroups(state: StepPlanner.GaitState)
		local inFlight: { [number]: boolean } = {}
		for _, leg in state.legs do
			if leg.stepPhase > 0 then
				inFlight[leg.group] = true
			end
		end
		local groupsMoving = 0
		for _ in inFlight do
			groupsMoving += 1
		end
		expect(groupsMoving <= 1).toBeTruthy()
	end

	t.it("holds across 600 frames of walking forward", function()
		local state = quadruped()
		local body = v3(0, 0, 0)
		local velocity = v3(6, 0, 0)
		for frame = 1, 600 do
			body = Types.addVec3(body, Types.scaleVec3(velocity, 1 / 60))
			state = StepPlanner.step(state, body, velocity, 1 / 60, flatGround)
			assertNeverBothGroups(state)
		end
	end)

	t.it("holds while the body changes direction repeatedly", function()
		-- Direction changes are when a naive planner desynchronises, because
		-- several legs cross the threshold on the same frame.
		local state = quadruped()
		local body = v3(0, 0, 0)
		for frame = 1, 600 do
			local angle = frame * 0.05
			local velocity = v3(math.cos(angle) * 8, 0, math.sin(angle) * 8)
			body = Types.addVec3(body, Types.scaleVec3(velocity, 1 / 60))
			state = StepPlanner.step(state, body, velocity, 1 / 60, flatGround)
			assertNeverBothGroups(state)
		end
	end)

	t.it("holds at very high speed, where every leg wants to step at once", function()
		local state = quadruped()
		local body = v3(0, 0, 0)
		local velocity = v3(80, 0, 0)
		for _ = 1, 300 do
			body = Types.addVec3(body, Types.scaleVec3(velocity, 1 / 60))
			state = StepPlanner.step(state, body, velocity, 1 / 60, flatGround)
			assertNeverBothGroups(state)
		end
	end)

	t.it("holds on a staircase, not just flat ground", function()
		-- The reason the gait is procedural at all: it has to adapt to terrain
		-- the animator never saw.
		local function stairs(p: Types.Vec3): Types.Vec3
			return v3(p.x, math.floor(p.x / 4) * 0.8, p.z)
		end
		local state = StepPlanner.new({
			v3(1, 0, 1), v3(-1, 0, 1), v3(1, 0, -1), v3(-1, 0, -1),
		}, { 1, 2, 2, 1 })
		local body = v3(0, 0, 0)
		local velocity = v3(6, 0, 0)
		for _ = 1, 600 do
			body = Types.addVec3(body, Types.scaleVec3(velocity, 1 / 60))
			state = StepPlanner.step(state, body, velocity, 1 / 60, stairs)
			assertNeverBothGroups(state)
		end
	end)

	t.it("a walk actually produces steps -- the invariant is not held vacuously", function()
		-- A planner that never lifted a foot would pass every check above.
		local state = quadruped()
		local body = v3(0, 0, 0)
		local velocity = v3(6, 0, 0)
		local framesWithFlight = 0
		for _ = 1, 600 do
			body = Types.addVec3(body, Types.scaleVec3(velocity, 1 / 60))
			state = StepPlanner.step(state, body, velocity, 1 / 60, flatGround)
			if StepPlanner.legsInFlight(state) > 0 then
				framesWithFlight += 1
			end
		end
		expect(framesWithFlight > 100).toBeTruthy()
	end)

	t.it("both groups get used -- the gait alternates rather than favouring one side", function()
		local state = quadruped()
		local body = v3(0, 0, 0)
		local velocity = v3(6, 0, 0)
		local stepsByGroup: { [number]: number } = { [1] = 0, [2] = 0 }
		local wasInFlight: { [number]: boolean } = {}
		for _ = 1, 900 do
			body = Types.addVec3(body, Types.scaleVec3(velocity, 1 / 60))
			state = StepPlanner.step(state, body, velocity, 1 / 60, flatGround)
			for index, leg in state.legs do
				local flying = leg.stepPhase > 0
				if flying and not wasInFlight[index] then
					stepsByGroup[leg.group] += 1
				end
				wasInFlight[index] = flying
			end
		end
		expect(stepsByGroup[1] > 0).toBeTruthy()
		expect(stepsByGroup[2] > 0).toBeTruthy()
		-- Neither group should be starved: a planner that let one group hog
		-- the gate would still pass the "never together" check.
		local ratio = stepsByGroup[1] / stepsByGroup[2]
		expect(ratio > 0.5 and ratio < 2.0).toBeTruthy()
	end)
end)

t.describe("StepPlanner.bodyHeight tracks the mean of planted feet", function()
	t.it("is the mean of foot heights when all are planted", function()
		local state = StepPlanner.new({ v3(1, 0, 0), v3(-1, 0, 0) }, { 1, 2 })
		state.legs[1].current = v3(1, 2, 0)
		state.legs[2].current = v3(-1, 4, 0)
		expect(StepPlanner.bodyHeight(state)).approx(3, 1e-9)
	end)

	t.it("ignores feet in flight", function()
		-- A swinging foot is not supporting the body; averaging it in makes
		-- the body bob upward every time a leg passes through its arc.
		local state = StepPlanner.new({ v3(1, 0, 0), v3(-1, 0, 0) }, { 1, 2 })
		state.legs[1].current = v3(1, 2, 0)
		state.legs[2].current = v3(-1, 100, 0)
		state.legs[2].stepPhase = 0.5
		expect(StepPlanner.bodyHeight(state)).approx(2, 1e-9)
	end)

	t.it("holds the previous height when every foot is airborne", function()
		-- Falling to zero would drop the body through the floor for a frame.
		local state = StepPlanner.new({ v3(1, 0, 0), v3(-1, 0, 0) }, { 1, 2 })
		state.legs[1].current = v3(1, 5, 0)
		state.legs[2].current = v3(-1, 5, 0)
		state.bodyHeight = 5
		state.legs[1].stepPhase = 0.5
		state.legs[2].stepPhase = 0.5
		expect(StepPlanner.bodyHeight(state)).approx(5, 1e-9)
	end)

	t.it("rises with the terrain when walking up stairs", function()
		local function stairs(p: Types.Vec3): Types.Vec3
			return v3(p.x, math.floor(math.max(p.x, 0) / 4) * 0.8, p.z)
		end
		local state = StepPlanner.new({
			v3(1, 0, 1), v3(-1, 0, 1), v3(1, 0, -1), v3(-1, 0, -1),
		}, { 1, 2, 2, 1 })
		local startHeight = StepPlanner.bodyHeight(state)

		local body = v3(0, 0, 0)
		local velocity = v3(6, 0, 0)
		for _ = 1, 600 do
			body = Types.addVec3(body, Types.scaleVec3(velocity, 1 / 60))
			state = StepPlanner.step(state, body, velocity, 1 / 60, stairs)
		end
		expect(state.bodyHeight > startHeight + 1).toBeTruthy()
	end)
end)

t.describe("StepPlanner.footPosition", function()
	t.it("a planted foot is exactly where it is planted", function()
		local state = quadruped()
		state.legs[1].current = v3(3, 1, 4)
		local position = StepPlanner.footPosition(state.legs[1])
		expect(position.x).toEqual(3)
		expect(position.y).toEqual(1)
		expect(position.z).toEqual(4)
	end)

	t.it("a foot mid-step arcs above the straight line between its endpoints", function()
		local leg: StepPlanner.Leg = {
			restOffset = v3(0, 0, 0),
			current = v3(0, 0, 0),
			target = v3(4, 0, 0),
			stepPhase = 0.5,
			group = 1,
		}
		local position = StepPlanner.footPosition(leg)
		-- Peak of the arc: 4 * 0.5 * 0.5 = 1, times the arc height.
		expect(position.y).approx(StepPlanner.STEP_ARC_HEIGHT, 1e-9)
		expect(position.x).approx(2, 1e-9) -- smoothstep(0.5) = 0.5
	end)

	t.it("the arc is zero at both ends, so the foot does not jump on lift or land", function()
		local leg: StepPlanner.Leg = {
			restOffset = v3(0, 0, 0),
			current = v3(0, 0, 0),
			target = v3(4, 0, 0),
			stepPhase = 0.001,
			group = 1,
		}
		expect(StepPlanner.footPosition(leg).y < 0.01).toBeTruthy()
		leg.stepPhase = 0.999
		expect(StepPlanner.footPosition(leg).y < 0.01).toBeTruthy()
	end)
end)

t.describe("StepPlanner.step edge cases", function()
	t.it("a non-positive dt is a no-op rather than a divide-by-zero", function()
		local state = quadruped()
		local before = state.legs[1].stepPhase
		state = StepPlanner.step(state, v3(100, 0, 0), v3(50, 0, 0), 0, flatGround)
		expect(state.legs[1].stepPhase).toEqual(before)
		state = StepPlanner.step(state, v3(100, 0, 0), v3(50, 0, 0), -1, flatGround)
		expect(state.legs[1].stepPhase).toEqual(before)
	end)

	t.it("a single-leg entity still walks", function()
		-- Degenerate grouping: with one group there is no opposing group to
		-- wait for, so the gate must not deadlock the only leg.
		local state = StepPlanner.new({ v3(0, 0, 0) }, { 1 })
		local body = v3(0, 0, 0)
		local velocity = v3(10, 0, 0)
		local stepped = false
		for _ = 1, 120 do
			body = Types.addVec3(body, Types.scaleVec3(velocity, 1 / 60))
			state = StepPlanner.step(state, body, velocity, 1 / 60, flatGround)
			if state.legs[1].stepPhase > 0 then
				stepped = true
			end
		end
		expect(stepped).toBeTruthy()
	end)

	t.it("an entity with no legs does not error", function()
		local state = StepPlanner.new({}, {})
		state = StepPlanner.step(state, v3(0, 0, 0), v3(5, 0, 0), 1 / 60, flatGround)
		expect(#state.legs).toEqual(0)
	end)
end)

t.describe("StepPlanner foot reach", function()
	-- Found in Studio: fast kinds looked like spiders. `TwoBoneIk` correctly
	-- clamps an out-of-range target and extends the leg toward it, but a foot
	-- the body has outrun is out of range *every* frame, so the limb is
	-- permanently straight rather than momentarily reaching.
	local OFFSETS = {
		v3(0.6, -0.85, 0.65),
		v3(-0.6, -0.85, 0.65),
		v3(0.6, -0.85, -0.65),
		v3(-0.6, -0.85, -0.65),
	}
	local GROUPS = { 1, 2, 2, 1 }

	--- Worst planted-foot distance from where that foot should be standing.
	--- Planted only: a leg in flight is by definition travelling to its next
	--- spot, and measuring it would report the stride as over-extension.
	local function worstPlanted(maxOffset: number?, speed: number, frames: number): number
		local state = StepPlanner.new(OFFSETS, GROUPS, maxOffset)
		local pos = v3(0, 0, 0)
		for _ = 1, frames do
			pos = v3(pos.x, pos.y, pos.z + speed * 0.05)
			StepPlanner.step(state, pos, v3(0, 0, speed), 0.05, function(p)
				return v3(p.x, 0, p.z)
			end)
		end
		local worst = 0
		for _, leg in state.legs do
			if leg.stepPhase <= 0 then
				local dx = leg.current.x - (pos.x + leg.restOffset.x)
				local dz = leg.current.z - (pos.z + leg.restOffset.z)
				worst = math.max(worst, math.sqrt(dx * dx + dz * dz))
			end
		end
		return worst
	end

	t.it("keeps a planted foot inside the leg's reach at sprint speed", function()
		-- A Skitter at 22 studs/s against about 1.2 studs of horizontal reach.
		expect(worstPlanted(1.2, 22, 120) <= 1.2 + 1e-6).toBeTruthy()
	end)

	t.it("over-extends without a reach limit, which is the bug", function()
		-- Pinned so the fix cannot be silently reverted: 2.20 studs measured,
		-- against a leg that reaches 1.2.
		expect(worstPlanted(nil, 22, 120) > 1.2 * 1.5).toBeTruthy()
	end)

	t.it("leaves slow kinds untouched", function()
		-- A Hauler at 8 studs/s never outruns its own feet, so the clamp must
		-- be inert rather than subtly reshaping its gait.
		expect(worstPlanted(1.2, 8, 120)).approx(worstPlanted(nil, 8, 120), 1e-9)
	end)

	t.it("treats nil, zero, negative or NaN reach as unlimited", function()
		for _, bad in { 0, -5, 0 / 0 } do
			expect(StepPlanner.new(OFFSETS, GROUPS, bad).maxFootOffset).toEqual(math.huge)
		end
		expect(StepPlanner.new(OFFSETS, GROUPS).maxFootOffset).toEqual(math.huge)
	end)

	t.it("still alternates groups with the clamp active", function()
		-- The clamp moves feet directly, so it could in principle mask the
		-- starvation bug M7-2 exists to prevent.
		local state = StepPlanner.new(OFFSETS, GROUPS, 1.2)
		local pos = v3(0, 0, 0)
		for _ = 1, 400 do
			pos = v3(pos.x, pos.y, pos.z + 22 * 0.05)
			StepPlanner.step(state, pos, v3(0, 0, 22), 0.05, function(p)
				return v3(p.x, 0, p.z)
			end)
			local inFlight = {}
			for _, leg in state.legs do
				if leg.stepPhase > 0 then
					inFlight[leg.group] = true
				end
			end
			expect(not (inFlight[1] and inFlight[2])).toBeTruthy()
		end
	end)
end)
