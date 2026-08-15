--!strict

local t = require("./framework")
local expect = t.expect

local Interest = require("../src/shared/core/net/Interest")
local FireValidation = require("../src/shared/core/sim/FireValidation")
local MovementGuard = require("../src/shared/core/sim/MovementGuard")
local Types = require("../src/shared/core/Types")

local v3 = Types.vec3

local function view(id: number, x: number, z: number): Types.EntityView
	return { id = id, pos = v3(x, 0, z), yaw = 0, state = "move", hpPct = 1 }
end

--------------------------------------------------------------------------------
-- Interest
--------------------------------------------------------------------------------

t.describe("net/Interest scoring", function()
	t.it("ranks nearer entities higher", function()
		expect(Interest.score(5, false, 0) > Interest.score(50, false, 0)).toBeTruthy()
	end)

	t.it("boosts an entity attacking the viewer", function()
		expect(Interest.score(50, true, 0) > Interest.score(50, false, 0)).toBeTruthy()
	end)

	t.it("boosts a starved entity, saturating at the cap", function()
		local fresh = Interest.score(50, false, 0)
		local stale = Interest.score(50, false, Interest.STARVATION_FULL_TICKS)
		local ancient = Interest.score(50, false, Interest.STARVATION_FULL_TICKS * 10)

		expect(stale > fresh).toBeTruthy()
		expect(ancient).approx(stale, 1e-12)
		expect(stale - fresh).approx(Interest.STARVATION_BONUS, 1e-9)
	end)

	t.it("never lets starvation outrank a close threat", function()
		-- The bug the normalisation prevents: with an unbounded starvation
		-- term, a distant idle entity eventually outranks one attacking you.
		local closeAttacker = Interest.score(3, true, 0)
		local distantStarved = Interest.score(140, false, 100000)
		expect(closeAttacker > distantStarved).toBeTruthy()
	end)

	t.it("handles zero and negative distance without dividing by zero", function()
		expect(Interest.score(0, false, 0)).toEqual(1)
		expect(Interest.score(-5, false, 0)).toEqual(1)
	end)
end)

t.describe("net/Interest selection", function()
	local function manyEntities(count: number): { Types.EntityView }
		local out: { Types.EntityView } = {}
		for i = 1, count do
			out[i] = view(i, i * 2, 0)
		end
		return out
	end

	t.it("excludes entities beyond the radius", function()
		local selected = Interest.select(manyEntities(100), v3(0, 0, 0), {
			radius = 20,
			maxCount = 32,
			currentTick = 0,
		})
		for _, e in selected do
			expect(Types.distance(e.pos, v3(0, 0, 0)) <= 20).toBeTruthy()
		end
	end)

	t.it("caps at maxCount", function()
		local selected = Interest.select(manyEntities(100), v3(0, 0, 0), {
			radius = 1000,
			maxCount = 32,
			currentTick = 0,
		})
		expect(#selected).toEqual(32)
	end)

	t.it("prefers the nearest when nothing else differs", function()
		local selected = Interest.select(manyEntities(100), v3(0, 0, 0), {
			radius = 1000,
			maxCount = 5,
			currentTick = 0,
		})
		expect({ selected[1].id, selected[2].id, selected[3].id }).toEqual({ 1, 2, 3 })
	end)

	t.it("pulls in a distant attacker over a marginally nearer idle entity", function()
		local entities = { view(1, 30, 0), view(2, 31, 0) }
		local selected = Interest.select(entities, v3(0, 0, 0), {
			radius = 1000,
			maxCount = 1,
			currentTick = 0,
			attacking = { [2] = true },
		})
		expect(selected[1].id).toEqual(2)
	end)

	t.it("is deterministic when scores tie", function()
		-- Unstable ordering makes deltas churn between equivalent sets and
		-- wastes the byte budget re-sending unchanged entities.
		local entities = { view(7, 10, 0), view(3, 10, 0), view(5, 10, 0) }
		local params = { radius = 1000, maxCount = 3, currentTick = 0 }
		local first = Interest.select(entities, v3(0, 0, 0), params)
		local second = Interest.select(entities, v3(0, 0, 0), params)
		expect({ first[1].id, first[2].id, first[3].id }).toEqual({ 3, 5, 7 })
		expect({ second[1].id, second[2].id, second[3].id }).toEqual({ 3, 5, 7 })
	end)

	t.it("eventually gives a starved distant entity a turn", function()
		-- Anti-starvation: an entity behind you must not freeze permanently.
		local entities = { view(1, 10, 0), view(2, 60, 0) }
		local fresh = Interest.select(entities, v3(0, 0, 0), {
			radius = 1000,
			maxCount = 1,
			currentTick = 100,
			lastSentTick = { [1] = 100, [2] = 100 },
		})
		expect(fresh[1].id).toEqual(1)

		local starved = Interest.select(entities, v3(0, 0, 0), {
			radius = 1000,
			maxCount = 1,
			currentTick = 100,
			lastSentTick = { [1] = 100, [2] = 40 },
		})
		expect(starved[1].id).toEqual(2)
	end)

	t.it("returns everything when under the cap", function()
		expect(#Interest.select(manyEntities(5), v3(0, 0, 0), {
			radius = 1000,
			maxCount = 32,
			currentTick = 0,
		})).toEqual(5)
	end)

	t.it("handles an empty entity list", function()
		expect(#Interest.select({}, v3(0, 0, 0), { radius = 100, maxCount = 32, currentTick = 0 })).toEqual(0)
	end)
end)

--------------------------------------------------------------------------------
-- FireValidation
--------------------------------------------------------------------------------

t.describe("sim/FireValidation token bucket", function()
	t.it("allows a burst up to capacity", function()
		local bucket = FireValidation.newBucket(4, 2, 0)
		expect(FireValidation.tryConsume(bucket, 0)).toBeTruthy()
		expect(FireValidation.tryConsume(bucket, 0)).toBeTruthy()
		expect(FireValidation.tryConsume(bucket, 0)).toBeFalsy()
	end)

	t.it("refills at the weapon's rate", function()
		local bucket = FireValidation.newBucket(4, 2, 0) -- 4 shots/sec
		FireValidation.tryConsume(bucket, 0)
		FireValidation.tryConsume(bucket, 0)
		expect(FireValidation.tryConsume(bucket, 0.1)).toBeFalsy()
		-- 0.25s buys exactly one token back.
		expect(FireValidation.tryConsume(bucket, 0.25)).toBeTruthy()
	end)

	t.it("does not accumulate beyond capacity while idle", function()
		-- Otherwise a player who holds fire for a minute unloads instantly.
		local bucket = FireValidation.newBucket(4, 2, 0)
		FireValidation.tryConsume(bucket, 60)
		FireValidation.tryConsume(bucket, 60)
		expect(FireValidation.tryConsume(bucket, 60)).toBeFalsy()
	end)

	t.it("sustains exactly the configured rate over time", function()
		local bucket = FireValidation.newBucket(10, 2, 0)
		local allowed = 0
		-- Request every 50ms for 2s = 40 requests; 10/sec should pass ~20.
		for i = 1, 40 do
			if FireValidation.tryConsume(bucket, i * 0.05) then
				allowed += 1
			end
		end
		expect(allowed >= 19 and allowed <= 22).toBeTruthy()
	end)

	t.it("tolerates a non-monotonic clock without granting free shots", function()
		local bucket = FireValidation.newBucket(4, 2, 0)
		FireValidation.tryConsume(bucket, 10)
		FireValidation.tryConsume(bucket, 10)
		expect(FireValidation.tryConsume(bucket, 5)).toBeFalsy()
	end)

	t.it("rejects a non-positive rate", function()
		expect(function()
			FireValidation.newBucket(0)
		end).toThrow("positive")
	end)
end)

t.describe("sim/FireValidation origin reconciliation", function()
	t.it("accepts a plausible origin unchanged", function()
		local origin, substituted = FireValidation.reconcileOrigin(v3(1, 0, 1), v3(0, 0, 0), 8)
		expect(substituted).toBeFalsy()
		expect(origin.x).toEqual(1)
	end)

	t.it("substitutes the server position when implausible", function()
		-- Substituting rather than rejecting: honest clients desync briefly all
		-- the time, and eating their shots feels worse than firing from the
		-- right place.
		local origin, substituted = FireValidation.reconcileOrigin(v3(500, 0, 0), v3(0, 0, 0), 8)
		expect(substituted).toBeTruthy()
		expect(origin).toEqual(v3(0, 0, 0))
	end)

	t.it("treats the tolerance boundary as acceptable", function()
		local _, substituted = FireValidation.reconcileOrigin(v3(8, 0, 0), v3(0, 0, 0), 8)
		expect(substituted).toBeFalsy()
	end)
end)

t.describe("sim/FireValidation time clamping", function()
	t.it("passes a time inside the window through", function()
		local time, clamped = FireValidation.clampFireTime(9.9, 10, 0.25)
		expect(clamped).toBeFalsy()
		expect(time).approx(9.9, 1e-9)
	end)

	t.it("clamps a time older than the window", function()
		local time, clamped = FireValidation.clampFireTime(5, 10, 0.25)
		expect(clamped).toBeTruthy()
		expect(time).approx(9.75, 1e-9)
	end)

	t.it("clamps a future time to now", function()
		-- A client claiming the future would otherwise get to shoot at
		-- positions the server has not simulated yet.
		local time, clamped = FireValidation.clampFireTime(50, 10, 0.25)
		expect(clamped).toBeTruthy()
		expect(time).approx(10, 1e-9)
	end)

	t.it("turns NaN into now rather than poisoning comparisons", function()
		local time, clamped = FireValidation.clampFireTime(0 / 0, 10, 0.25)
		expect(clamped).toBeTruthy()
		expect(time).toEqual(10)
	end)
end)

t.describe("sim/FireValidation direction and range", function()
	t.it("normalises a valid direction", function()
		local dir = FireValidation.sanitizeDirection(v3(0, 0, 5)) :: Types.Vec3
		expect(Types.magnitude(dir)).approx(1, 1e-9)
	end)

	t.it("rejects a zero-length direction", function()
		expect(FireValidation.sanitizeDirection(v3(0, 0, 0))).toBeNil()
	end)

	t.it("rejects NaN components", function()
		expect(FireValidation.sanitizeDirection(v3(0 / 0, 0, 1))).toBeNil()
	end)

	t.it("allows a small slack past max range", function()
		-- Quantization and interpolation both nudge the target position, so an
		-- exact range test would eat hits at the edge.
		expect(FireValidation.inRange(v3(0, 0, 0), v3(0, 0, 121), 120, 2)).toBeTruthy()
		expect(FireValidation.inRange(v3(0, 0, 0), v3(0, 0, 130), 120, 2)).toBeFalsy()
	end)
end)

--------------------------------------------------------------------------------
-- MovementGuard
--------------------------------------------------------------------------------

t.describe("sim/MovementGuard", function()
	local P = MovementGuard.DEFAULT_PARAMS
	local DT = 1 / 20
	local SPEED = 16

	t.it("passes ordinary movement", function()
		local state = MovementGuard.new()
		local verdict = MovementGuard.check(state, v3(0, 0, 0), v3(0, 0, SPEED * DT), DT, SPEED, P)
		expect(verdict.action).toEqual("ok")
		expect(#verdict.reasons).toEqual(0)
		expect(state.score).toEqual(0)
	end)

	t.it("allows movement inside the margin", function()
		-- Slopes, knockback, and latency all produce brief legitimate overshoot.
		local state = MovementGuard.new()
		local distance = SPEED * P.speedMargin * DT * 0.99
		local verdict = MovementGuard.check(state, v3(0, 0, 0), v3(0, 0, distance), DT, SPEED, P)
		expect(verdict.action).toEqual("ok")
		expect(#verdict.reasons).toEqual(0)
	end)

	t.it("does not act on a single speed violation", function()
		-- One bad frame is ordinary. Punishing it would flag honest players on
		-- bad connections.
		local state = MovementGuard.new()
		local verdict = MovementGuard.check(state, v3(0, 0, 0), v3(0, 0, 3), DT, SPEED, P)
		expect(#verdict.reasons).toEqual(1)
		expect(verdict.action).toEqual("ok")
		expect(state.score > 0).toBeTruthy()
	end)

	t.it("escalates to correction under a sustained pattern", function()
		local state = MovementGuard.new()
		local action = "ok"
		for i = 1, 20 do
			local from = v3(0, 0, i * 3)
			local verdict = MovementGuard.check(state, from, v3(0, 0, i * 3 + 3), DT, SPEED, P)
			action = verdict.action
			if action ~= "ok" then
				break
			end
		end
		expect(action).toEqual("correct")
	end)

	t.it("flags an outright teleport immediately", function()
		local state = MovementGuard.new()
		local verdict = MovementGuard.check(state, v3(0, 0, 0), v3(0, 0, 500), DT, SPEED, P)
		expect(verdict.reasons).toEqual({ "teleport" })
		expect(state.score >= 5).toBeTruthy()
		expect(verdict.action).toEqual("correct")
		expect(verdict.correctedPos).toEqual(v3(0, 0, 0))
	end)

	t.it("kicks on a non-finite position without waiting", function()
		-- Not a lag spike: a malformed or malicious packet.
		local state = MovementGuard.new()
		local verdict = MovementGuard.check(state, v3(0, 0, 0), v3(0 / 0, 0, 0), DT, SPEED, P)
		expect(verdict.action).toEqual("kick")
		expect(verdict.reasons).toEqual({ "non_finite_position" })
	end)

	t.it("scales the penalty with how far past budget the frame went", function()
		local mild = MovementGuard.new()
		MovementGuard.check(mild, v3(0, 0, 0), v3(0, 0, 1.5), DT, SPEED, P)

		local severe = MovementGuard.new()
		MovementGuard.check(severe, v3(0, 0, 0), v3(0, 0, 30), DT, SPEED, P)

		expect(severe.score > mild.score).toBeTruthy()
	end)

	t.it("decays the score over time", function()
		local state = MovementGuard.new()
		MovementGuard.check(state, v3(0, 0, 0), v3(0, 0, 500), DT, SPEED, P)
		local peak = state.score

		MovementGuard.decay(state, 1.0, P)
		expect(state.score).approx(peak - P.decayPerSecond, 1e-9)

		MovementGuard.decay(state, 100, P)
		expect(state.score).toEqual(0)
	end)

	t.it("returns to clean after a spike, given time", function()
		-- The property that keeps a laggy honest player from accumulating a
		-- kick over a long session.
		local state = MovementGuard.new()
		for _ = 1, 3 do
			MovementGuard.check(state, v3(0, 0, 0), v3(0, 0, 3), DT, SPEED, P)
			MovementGuard.decay(state, 5, P)
		end
		expect(state.score).toEqual(0)
	end)

	t.it("clamps a position outside the world volume", function()
		local params = table.clone(P)
		params.worldMin = v3(-100, -50, -100)
		params.worldMax = v3(100, 200, 100)

		local state = MovementGuard.new()
		local verdict = MovementGuard.check(state, v3(0, 0, 0), v3(0, -900, 0), DT, SPEED, params)
		expect(table.find(verdict.reasons, "out_of_bounds")).never().toBeNil()
	end)

	t.it("uses the caller's max speed, so weight is respected", function()
		-- The guard must use the same number the movement code does, or a
		-- heavily loaded player gets flagged for moving normally.
		local slow = MovementGuard.new()
		local fast = MovementGuard.new()
		local distance = 10 * (1 / 20)

		MovementGuard.check(slow, v3(0, 0, 0), v3(0, 0, distance), DT, 5, P)
		MovementGuard.check(fast, v3(0, 0, 0), v3(0, 0, distance), DT, 20, P)

		expect(slow.score > 0).toBeTruthy()
		expect(fast.score).toEqual(0)
	end)

	t.it("ignores a zero or negative dt", function()
		local state = MovementGuard.new()
		expect(MovementGuard.check(state, v3(0, 0, 0), v3(0, 0, 999), 0, SPEED, P).action).toEqual("ok")
		expect(state.score).toEqual(0)
	end)

	t.it("counts total violations for telemetry", function()
		local state = MovementGuard.new()
		MovementGuard.check(state, v3(0, 0, 0), v3(0, 0, 500), DT, SPEED, P)
		MovementGuard.check(state, v3(0, 0, 0), v3(0, 0, 500), DT, SPEED, P)
		expect(state.totalViolations).toEqual(2)
	end)
end)
