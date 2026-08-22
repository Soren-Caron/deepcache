--!strict
--[[ M7-1. core/anim/TwoBoneIk -- the five cases docs/08 §Tests names:
	reachable, exactly-reachable, unreachable, degenerate coincident points,
	and pole-vector plane correctness.

	Expected values are hand-computed from the law of cosines and verified
	independently before being written down here, not read back out of the
	module. The 3-4-5 case is chosen because every number in it is exact in
	binary floating point, so an assertion that fails is a real failure and
	not a rounding artifact.
]]

local t = require("./framework")
local expect = t.expect

local TwoBoneIk = require("../src/shared/core/anim/TwoBoneIk")
local Types = require("../src/shared/core/Types")

local v3 = Types.vec3
local EPS = 1e-9

--- The property that actually defines a correct solve: the joint is exactly
--- `upperLength` from the root and exactly `lowerLength` from the target.
--- Checked independently of how the module computed it.
local function expectBoneLengths(
	joint: Types.Vec3,
	root: Types.Vec3,
	target: Types.Vec3,
	upper: number,
	lower: number
)
	expect(Types.distance(root, joint)).approx(upper, 1e-6)
	expect(Types.distance(joint, target)).approx(lower, 1e-6)
end

t.describe("TwoBoneIk.solve -- reachable", function()
	t.it("the 3-4-5 case lands on the hand-computed joint", function()
		-- L1=3, L2=4, d=5:
		--   along = (9 + 25 - 16) / (2*5) = 1.8
		--   perp  = sqrt(9 - 1.8^2)       = 2.4
		local root, target = v3(0, 0, 0), v3(5, 0, 0)
		local joint, reachable = TwoBoneIk.solve(root, target, 3, 4, v3(0, 1, 0))

		expect(reachable).toBeTruthy()
		expect(joint.x).approx(1.8, EPS)
		expect(joint.y).approx(2.4, EPS)
		expect(joint.z).approx(0, EPS)
		expectBoneLengths(joint, root, target, 3, 4)
	end)

	t.it("holds the bone lengths regardless of orientation", function()
		-- Same limb, target swung to an arbitrary direction. The exact joint
		-- position changes; the invariant does not.
		local root = v3(3, -2, 7)
		for _, target in { v3(8, -2, 7), v3(3, 3, 7), v3(3, -2, 12), v3(6, 1, 10) } do
			local joint, reachable = TwoBoneIk.solve(root, target, 3, 4, v3(0, 1, 0))
			expect(reachable).toBeTruthy()
			expectBoneLengths(joint, root, target, 3, 4)
		end
	end)

	t.it("a target inside the annulus but very close still solves", function()
		-- d = 1.5, comfortably above minReach of |3-4| = 1.
		local root, target = v3(0, 0, 0), v3(1.5, 0, 0)
		local joint, reachable = TwoBoneIk.solve(root, target, 3, 4, v3(0, 1, 0))
		expect(reachable).toBeTruthy()
		expectBoneLengths(joint, root, target, 3, 4)
	end)
end)

t.describe("TwoBoneIk.solve -- exactly reachable", function()
	t.it("at d = L1 + L2 the limb is straight and still reports reachable", function()
		-- The boundary case: perp is mathematically exactly zero, and float
		-- error at the sqrt is what a naive implementation turns into NaN.
		local root, target = v3(0, 0, 0), v3(7, 0, 0)
		local joint, reachable = TwoBoneIk.solve(root, target, 3, 4, v3(0, 1, 0))

		expect(reachable).toBeTruthy()
		expect(joint.x).approx(3, 1e-9)
		expect(joint.y).approx(0, 1e-9)
		expect(joint.z).approx(0, 1e-9)
		-- Not NaN: a NaN would pass a naive `== 0` check but fails this.
		expect(joint.y == joint.y).toBeTruthy()
		expectBoneLengths(joint, root, target, 3, 4)
	end)

	t.it("at d = |L1 - L2| the limb is fully folded and still reachable", function()
		-- The inner boundary. along = (9 + 1 - 16)/2 = -3, so the joint sits
		-- *behind* the root, folded back along the axis.
		local root, target = v3(0, 0, 0), v3(1, 0, 0)
		local joint, reachable = TwoBoneIk.solve(root, target, 3, 4, v3(0, 1, 0))

		expect(reachable).toBeTruthy()
		expect(joint.x).approx(-3, 1e-9)
		expectBoneLengths(joint, root, target, 3, 4)
	end)
end)

t.describe("TwoBoneIk.solve -- unreachable", function()
	t.it("a target past L1 + L2 extends straight toward it and reports false", function()
		-- docs/08: "extend straight toward it and return reachable = false so
		-- the caller can decide whether to stretch or step."
		local root, target = v3(0, 0, 0), v3(100, 0, 0)
		local joint, reachable = TwoBoneIk.solve(root, target, 3, 4, v3(0, 1, 0))

		expect(reachable).never().toBeTruthy()
		-- Straight along the axis at exactly L1 from the root.
		expect(joint.x).approx(3, 1e-9)
		expect(joint.y).approx(0, 1e-9)
		expect(joint.z).approx(0, 1e-9)
		expect(Types.distance(root, joint)).approx(3, 1e-9)
	end)

	t.it("a target closer than |L1 - L2| folds flat and reports false", function()
		local root, target = v3(0, 0, 0), v3(0.25, 0, 0)
		local joint, reachable = TwoBoneIk.solve(root, target, 3, 4, v3(0, 1, 0))

		expect(reachable).never().toBeTruthy()
		expect(joint.x).approx(-3, 1e-9)
		-- The upper bone keeps its length even when the pose is impossible;
		-- a solver that let it stretch would show as a visibly long limb.
		expect(Types.distance(root, joint)).approx(3, 1e-9)
	end)

	t.it("equal bone lengths have no inner limit, so nothing is too close", function()
		-- minReach = |3-3| = 0, so even a coincident target is reachable.
		local _, reachable = TwoBoneIk.solve(v3(0, 0, 0), v3(0.01, 0, 0), 3, 3, v3(0, 1, 0))
		expect(reachable).toBeTruthy()
	end)
end)

t.describe("TwoBoneIk.solve -- degenerate", function()
	t.it("coincident root and target produce a finite, correct-length pose", function()
		-- There is no axis to build from. The result must still be a real
		-- vector with the right bone lengths, not NaN.
		local root, target = v3(4, 4, 4), v3(4, 4, 4)
		local joint, reachable = TwoBoneIk.solve(root, target, 3, 3, v3(0, 1, 0))

		expect(joint.x == joint.x).toBeTruthy()
		expect(joint.y == joint.y).toBeTruthy()
		expect(joint.z == joint.z).toBeTruthy()
		expect(reachable).toBeTruthy() -- equal lengths, so d=0 is in range
		expectBoneLengths(joint, root, target, 3, 3)
	end)

	t.it("coincident points with unequal bones report unreachable but stay finite", function()
		local root, target = v3(0, 0, 0), v3(0, 0, 0)
		local joint, reachable = TwoBoneIk.solve(root, target, 3, 4, v3(0, 1, 0))
		expect(reachable).never().toBeTruthy()
		expect(joint.x == joint.x and joint.y == joint.y and joint.z == joint.z).toBeTruthy()
	end)

	t.it("a zero-length pole vector does not produce NaN", function()
		local root, target = v3(0, 0, 0), v3(5, 0, 0)
		local joint = TwoBoneIk.solve(root, target, 3, 4, v3(0, 0, 0))
		expect(joint.x == joint.x and joint.y == joint.y and joint.z == joint.z).toBeTruthy()
		expectBoneLengths(joint, root, target, 3, 4)
	end)

	t.it("a pole vector parallel to the axis still yields a valid solve", function()
		-- The perpendicular component is exactly zero, so there is no plane
		-- the caller asked for. Any perpendicular is acceptable; the bone
		-- lengths are not negotiable.
		local root, target = v3(0, 0, 0), v3(5, 0, 0)
		local joint, reachable = TwoBoneIk.solve(root, target, 3, 4, v3(1, 0, 0))
		expect(reachable).toBeTruthy()
		expectBoneLengths(joint, root, target, 3, 4)
	end)
end)

t.describe("TwoBoneIk.solve -- pole vector controls the joint plane", function()
	t.it("the joint bends toward the pole direction", function()
		local root, target = v3(0, 0, 0), v3(5, 0, 0)

		local up = TwoBoneIk.solve(root, target, 3, 4, v3(0, 1, 0))
		expect(up.y).approx(2.4, EPS)
		expect(up.z).approx(0, EPS)

		local down = TwoBoneIk.solve(root, target, 3, 4, v3(0, -1, 0))
		expect(down.y).approx(-2.4, EPS)

		local sideways = TwoBoneIk.solve(root, target, 3, 4, v3(0, 0, 1))
		expect(sideways.z).approx(2.4, EPS)
		expect(sideways.y).approx(0, EPS)
	end)

	t.it("only the pole's perpendicular component matters, not its length", function()
		-- Scaling the pole, or sliding it along the axis, must not move the
		-- joint: both leave the perpendicular direction unchanged. A solver
		-- that skipped the projection would drift as the limb rotated.
		local root, target = v3(0, 0, 0), v3(5, 0, 0)
		local reference = TwoBoneIk.solve(root, target, 3, 4, v3(0, 1, 0))

		for _, pole in { v3(0, 50, 0), v3(0, 0.001, 0), v3(9, 1, 0), v3(-9, 1, 0) } do
			local joint = TwoBoneIk.solve(root, target, 3, 4, pole)
			expect(joint.x).approx(reference.x, 1e-6)
			expect(joint.y).approx(reference.y, 1e-6)
			expect(joint.z).approx(reference.z, 1e-6)
		end
	end)

	t.it("the joint lies in the plane through root, target and the pole", function()
		-- Plane normal = axis x pole. The joint's offset from the root must
		-- have no component along that normal.
		local root, target = v3(1, 2, 3), v3(6, 2, 3)
		local pole = v3(0, 1, 1)
		local joint = TwoBoneIk.solve(root, target, 3, 4, pole)

		local axis = Types.normalize(Types.subVec3(target, root))
		local normal = v3(
			axis.y * pole.z - axis.z * pole.y,
			axis.z * pole.x - axis.x * pole.z,
			axis.x * pole.y - axis.y * pole.x
		)
		local offset = Types.subVec3(joint, root)
		local outOfPlane = offset.x * normal.x + offset.y * normal.y + offset.z * normal.z
		expect(outOfPlane).approx(0, 1e-6)
	end)

	t.it("is deterministic -- the same inputs always give the same joint", function()
		-- Frame-to-frame stability is the whole reason a pole vector exists;
		-- a solver that picked an arbitrary point on the circle would make a
		-- knee snap inside out between identical frames.
		local first = TwoBoneIk.solve(v3(0, 0, 0), v3(5, 0, 0), 3, 4, v3(0, 1, 0))
		for _ = 1, 20 do
			local again = TwoBoneIk.solve(v3(0, 0, 0), v3(5, 0, 0), 3, 4, v3(0, 1, 0))
			expect(again.x).toEqual(first.x)
			expect(again.y).toEqual(first.y)
			expect(again.z).toEqual(first.z)
		end
	end)
end)
