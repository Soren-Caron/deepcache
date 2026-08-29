--!strict

local t = require("./framework")
local expect = t.expect

local Interpolator = require("../src/shared/core/net/Interpolator")
local Types = require("../src/shared/core/Types")

local TICK = 1 / 20

local function view(
	id: number,
	x: number,
	yaw: number?,
	state: Types.EntityStateName?,
	kind: Types.EntityKind?
): Types.EntityView
	return {
		id = id,
		-- Not "Skitter": a fixture that matches the renderer's fallback makes a
		-- dropped field indistinguishable from a carried one. That is exactly
		-- how kind went missing here in the first place.
		kind = kind or "Warden",
		pos = Types.vec3(x, 0, 0),
		yaw = yaw or 0,
		state = state or "move",
		hpPct = 1,
	}
end

local function hurtView(id: number, x: number, hp: number): Types.EntityView
	local v = view(id, x)
	v.hpPct = hp
	return v
end

--- Entity 1 moving +1 stud per tick, frames at t = 0, TICK, 2*TICK, ...
local function linear(ticks: number): Interpolator.Interpolator
	local interp = Interpolator.new()
	for i = 0, ticks - 1 do
		Interpolator.push(interp, i * TICK, { view(1, i) })
	end
	return interp
end

--------------------------------------------------------------------------------

t.describe("net/Interpolator buffering", function()
	t.it("returns nil before any frame arrives", function()
		expect(Interpolator.sample(Interpolator.new(), 1, 0)).toBeNil()
	end)

	t.it("accepts frames in order", function()
		local interp = Interpolator.new()
		expect(Interpolator.push(interp, 0, { view(1, 0) })).toBeTruthy()
		expect(Interpolator.push(interp, TICK, { view(1, 1) })).toBeTruthy()
		expect(Interpolator.frameCount(interp)).toEqual(2)
	end)

	t.it("drops out-of-order arrivals instead of splicing them in", function()
		-- On an unreliable channel a late packet is stale by definition;
		-- inserting it behind the newest frame makes entities step backwards.
		local interp = Interpolator.new()
		Interpolator.push(interp, 0, { view(1, 0) })
		Interpolator.push(interp, 2 * TICK, { view(1, 2) })
		expect(Interpolator.push(interp, TICK, { view(1, 1) })).toBeFalsy()
		expect(Interpolator.frameCount(interp)).toEqual(2)
	end)

	t.it("drops a duplicate timestamp", function()
		local interp = Interpolator.new()
		Interpolator.push(interp, TICK, { view(1, 1) })
		expect(Interpolator.push(interp, TICK, { view(1, 9) })).toBeFalsy()
	end)

	t.it("trims frames beyond the retention window", function()
		local interp = Interpolator.new()
		for i = 0, 199 do
			Interpolator.push(interp, i * TICK, { view(1, i) })
		end
		-- 1s retention at 20Hz is ~20 frames, plus the minimum kept for velocity.
		expect(Interpolator.frameCount(interp) <= 24).toBeTruthy()
		expect(Interpolator.frameCount(interp) >= 3).toBeTruthy()
		expect(Interpolator.newestTime(interp)).approx(199 * TICK, 1e-9)
	end)

	t.it("reports the ids in the newest frame", function()
		local interp = Interpolator.new()
		Interpolator.push(interp, 0, { view(1, 0), view(2, 0) })
		Interpolator.push(interp, TICK, { view(1, 1), view(2, 1), view(3, 5) })
		expect(#Interpolator.knownIds(interp)).toEqual(3)
	end)
end)

t.describe("net/Interpolator sampling", function()
	t.it("returns the exact value on a frame boundary", function()
		local interp = linear(10)
		local sample = Interpolator.sample(interp, 1, 5 * TICK) :: Interpolator.Sample
		expect(sample.pos.x).approx(5, 1e-9)
		expect(sample.extrapolated).toBeFalsy()
	end)

	t.it("interpolates between frames", function()
		local interp = linear(10)
		expect((Interpolator.sample(interp, 1, 5.5 * TICK) :: Interpolator.Sample).pos.x).approx(5.5, 1e-9)
		expect((Interpolator.sample(interp, 1, 5.25 * TICK) :: Interpolator.Sample).pos.x).approx(5.25, 1e-9)
		expect((Interpolator.sample(interp, 1, 5.75 * TICK) :: Interpolator.Sample).pos.x).approx(5.75, 1e-9)
	end)

	t.it("returns nil for an unknown entity", function()
		expect(Interpolator.sample(linear(10), 999, 5 * TICK)).toBeNil()
	end)

	t.it("clamps behind the oldest retained frame", function()
		local interp = linear(10)
		local sample = Interpolator.sample(interp, 1, -5) :: Interpolator.Sample
		expect(sample.pos.x).approx(0, 1e-9)
	end)

	t.it("takes the short way round on yaw", function()
		local interp = Interpolator.new()
		Interpolator.push(interp, 0, { view(1, 0, math.rad(350)) })
		Interpolator.push(interp, TICK, { view(1, 0, math.rad(10)) })

		local sample = Interpolator.sample(interp, 1, 0.5 * TICK) :: Interpolator.Sample
		local yaw = sample.yaw % (math.pi * 2)
		expect(math.min(yaw, math.pi * 2 - yaw)).approx(0, 1e-6)
	end)

	t.it("snaps state to the nearer frame instead of blending", function()
		local interp = Interpolator.new()
		Interpolator.push(interp, 0, { view(1, 0, 0, "move") })
		Interpolator.push(interp, TICK, { view(1, 1, 0, "attack") })
		expect((Interpolator.sample(interp, 1, 0.2 * TICK) :: Interpolator.Sample).state).toEqual("move")
		expect((Interpolator.sample(interp, 1, 0.8 * TICK) :: Interpolator.Sample).state).toEqual("attack")
	end)

	t.it("hides a single dropped packet", function()
		-- The entire reason for render delay: with a 100ms buffer, one missing
		-- 50ms frame still has a future frame to interpolate toward.
		local interp = Interpolator.new()
		Interpolator.push(interp, 0, { view(1, 0) })
		Interpolator.push(interp, TICK, { view(1, 1) })
		-- tick 2 lost
		Interpolator.push(interp, 3 * TICK, { view(1, 3) })

		local sample = Interpolator.sample(interp, 1, 2 * TICK) :: Interpolator.Sample
		expect(sample.extrapolated).toBeFalsy()
		-- Straight-line motion, so the gap interpolates to the true value.
		expect(sample.pos.x).approx(2, 1e-9)
	end)

	t.it("carries an entity present in only one frame of the pair", function()
		-- Dropping it would make a newly-visible entity flicker for one frame.
		local interp = Interpolator.new()
		Interpolator.push(interp, 0, { view(1, 0) })
		Interpolator.push(interp, TICK, { view(1, 1), view(2, 50) })
		local sample = Interpolator.sample(interp, 2, 0.5 * TICK) :: Interpolator.Sample
		expect(sample.pos.x).approx(50, 1e-9)
	end)
end)

t.describe("net/Interpolator extrapolation", function()
	t.it("extrapolates along last-known velocity past the newest frame", function()
		local interp = linear(10)
		local newest = 9 * TICK
		-- Half a tick past the end: velocity is 1 stud/tick, so x ~= 9.5.
		local sample = Interpolator.sample(interp, 1, newest + TICK * 0.5) :: Interpolator.Sample
		expect(sample.pos.x).approx(9.5, 1e-9)
		expect(sample.extrapolated).toBeTruthy()
	end)

	t.it("stops extrapolating at exactly EXTRAPOLATE_MAX", function()
		local interp = linear(10)
		local newest = 9 * TICK
		local cap = Interpolator.EXTRAPOLATE_MAX -- 0.08s = 1.6 ticks

		local atCap = Interpolator.sample(interp, 1, newest + cap) :: Interpolator.Sample
		local wellPast = Interpolator.sample(interp, 1, newest + cap * 10) :: Interpolator.Sample

		-- 0.08s at 1 stud per 0.05s tick = 1.6 studs past x=9.
		expect(atCap.pos.x).approx(10.6, 1e-9)
		-- Frozen: far beyond the cap gives the same answer, not a runaway.
		expect(wellPast.pos.x).approx(atCap.pos.x, 1e-9)
	end)

	t.it("never rubber-bands arbitrarily far", function()
		local interp = linear(10)
		local newest = 9 * TICK
		local far = Interpolator.sample(interp, 1, newest + 100) :: Interpolator.Sample
		expect(far.pos.x < 11).toBeTruthy()
	end)

	t.it("flags extrapolated samples", function()
		local interp = linear(10)
		expect((Interpolator.sample(interp, 1, 5 * TICK) :: Interpolator.Sample).extrapolated).toBeFalsy()
		expect((Interpolator.sample(interp, 1, 9 * TICK + 0.01) :: Interpolator.Sample).extrapolated).toBeTruthy()
	end)

	t.it("handles an entity seen in only one frame without extrapolating", function()
		local interp = Interpolator.new()
		Interpolator.push(interp, 0, { view(1, 0) })
		Interpolator.push(interp, TICK, { view(1, 1), view(2, 50) })
		-- Entity 2 has no velocity history, so it holds position.
		local sample = Interpolator.sample(interp, 2, TICK + 0.02) :: Interpolator.Sample
		expect(sample.pos.x).approx(50, 1e-9)
		expect(sample.extrapolated).toBeTruthy()
	end)

	t.it("returns nil past the end for an entity that is gone", function()
		local interp = Interpolator.new()
		Interpolator.push(interp, 0, { view(1, 0), view(2, 5) })
		Interpolator.push(interp, TICK, { view(1, 1) })
		expect(Interpolator.sample(interp, 2, TICK + 0.01)).toBeNil()
	end)
end)

t.describe("net/Interpolator adaptive delay", function()
	t.it("starts at the minimum", function()
		expect(Interpolator.new().renderDelay).toEqual(Interpolator.RENDER_DELAY_MIN)
	end)

	t.it("stays at the minimum on a clean connection", function()
		expect(Interpolator.updateDelay(Interpolator.new(), 0)).toEqual(Interpolator.RENDER_DELAY_MIN)
	end)

	t.it("grows with jitter", function()
		local interp = Interpolator.new()
		local delay = Interpolator.updateDelay(interp, 0.09)
		expect(delay).approx(0.14, 1e-9)
		expect(delay > Interpolator.RENDER_DELAY_MIN).toBeTruthy()
	end)

	t.it("clamps at the maximum", function()
		-- Unbounded delay would trade away all responsiveness on a bad line.
		expect(Interpolator.updateDelay(Interpolator.new(), 5)).toEqual(Interpolator.RENDER_DELAY_MAX)
	end)

	t.it("reports no jitter from too few samples", function()
		local interp = Interpolator.new()
		Interpolator.observeArrival(interp, 0)
		Interpolator.observeArrival(interp, TICK)
		expect(Interpolator.jitterP95(interp, TICK)).toEqual(0)
	end)

	t.it("measures near-zero jitter on perfectly spaced arrivals", function()
		local interp = Interpolator.new()
		for i = 0, 40 do
			Interpolator.observeArrival(interp, i * TICK)
		end
		expect(Interpolator.jitterP95(interp, TICK)).approx(0, 1e-9)
	end)

	t.it("measures jitter on irregular arrivals", function()
		local interp = Interpolator.new()
		local time = 0
		for i = 0, 40 do
			-- Every fifth packet arrives 40ms late.
			time += if i % 5 == 0 then TICK + 0.04 else TICK
			Interpolator.observeArrival(interp, time)
		end
		expect(Interpolator.jitterP95(interp, TICK) > 0.02).toBeTruthy()
	end)

	t.it("bounds the jitter sample window", function()
		local interp = Interpolator.new()
		for i = 0, 500 do
			Interpolator.observeArrival(interp, i * TICK)
		end
		expect(#interp.arrivals <= Interpolator.JITTER_SAMPLES).toBeTruthy()
	end)
end)

t.describe("net/Interpolator carries hpPct", function()
	-- Same class of bug as `kind`, found the same way: the renderer's hit
	-- flash did `sample.hpPct - epsilon` and threw every frame because the
	-- Sample never carried health. The render loop died partway through, so
	-- some entities silently stopped being drawn at all.
	t.it("carries hpPct when interpolating", function()
		local interp = Interpolator.new()
		Interpolator.push(interp, 0, { hurtView(1, 0, 0.8) })
		Interpolator.push(interp, TICK, { hurtView(1, 1, 0.8) })
		local sample = Interpolator.sample(interp, 1, 0.5 * TICK)
		expect((sample :: any).hpPct).approx(0.8, 1e-9)
	end)

	t.it("carries hpPct when extrapolating", function()
		local interp = Interpolator.new()
		Interpolator.push(interp, 0, { hurtView(1, 0, 0.3) })
		Interpolator.push(interp, TICK, { hurtView(1, 1, 0.3) })
		local sample = Interpolator.sample(interp, 1, TICK + 0.04)
		expect((sample :: any).extrapolated).toBeTruthy()
		expect((sample :: any).hpPct).approx(0.3, 1e-9)
	end)

	t.it("never returns a sample with a nil hpPct", function()
		-- The guard that would have caught this before Studio did.
		local interp = linear(4)
		for _, t_ in { -10, 0, 0.5 * TICK, 2 * TICK, 3 * TICK + 0.04 } do
			local sample = Interpolator.sample(interp, 1, t_)
			if sample ~= nil then
				expect(type((sample :: any).hpPct)).toEqual("number")
				expect(type((sample :: any).kind)).toEqual("string")
			end
		end
	end)
end)

t.describe("net/Interpolator carries kind", function()
	-- Found in Studio: every enemy rendered as the same grey box because the
	-- interpolator built its own Sample and silently dropped `kind`. The
	-- snapshot round-trip tests all passed -- they never went through here.
	t.it("keeps kind when interpolating between two frames", function()
		local interp = linear(4)
		local sample = Interpolator.sample(interp, 1, 1.5 * TICK)
		expect(sample).never().toBeNil()
		expect((sample :: any).kind).toEqual("Warden")
	end)

	t.it("keeps kind when extrapolating past the newest frame", function()
		local interp = linear(3)
		local sample = Interpolator.sample(interp, 1, 2 * TICK + 0.04)
		expect(sample).never().toBeNil()
		expect((sample :: any).extrapolated).toBeTruthy()
		expect((sample :: any).kind).toEqual("Warden")
	end)

	t.it("keeps kind when clamping behind the oldest frame", function()
		local interp = linear(3)
		local sample = Interpolator.sample(interp, 1, -10)
		expect(sample).never().toBeNil()
		expect((sample :: any).kind).toEqual("Warden")
	end)

	t.it("reports the kind the entity actually is, not the first one seen", function()
		local interp = Interpolator.new()
		Interpolator.push(interp, 0, { view(1, 0, 0, "move", "Hauler"), view(2, 0, 0, "move", "Lancer") })
		Interpolator.push(interp, TICK, { view(1, 1, 0, "move", "Hauler"), view(2, 1, 0, "move", "Lancer") })
		expect((Interpolator.sample(interp, 1, 0.5 * TICK) :: any).kind).toEqual("Hauler")
		expect((Interpolator.sample(interp, 2, 0.5 * TICK) :: any).kind).toEqual("Lancer")
	end)
end)
