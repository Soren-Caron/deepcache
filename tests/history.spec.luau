--!strict

local t = require("./framework")
local expect = t.expect

local History = require("../src/shared/core/net/History")
local Types = require("../src/shared/core/Types")

local TICK = 1 / 20

local function view(id: number, x: number, yaw: number?, state: Types.EntityStateName?, hp: number?): Types.EntityView
	return {
		id = id,
		pos = Types.vec3(x, 0, 0),
		yaw = yaw or 0,
		state = state or "move",
		hpPct = hp or 1,
	}
end

--- A history where entity 1 moves +1 stud per tick starting at x=0, t=0.
local function linearHistory(ticks: number): (History.History, number)
	local h = History.new()
	local time = 0
	for i = 0, ticks - 1 do
		time = i * TICK
		History.record(h, i, time, { view(1, i) })
	end
	return h, time
end

--------------------------------------------------------------------------------

t.describe("net/History recording", function()
	t.it("rejects a capacity too small to interpolate", function()
		expect(function()
			History.new(1)
		end).toThrow("capacity")
	end)

	t.it("returns nil before anything is recorded", function()
		expect(History.rewind(History.new(), 0, 0)).toBeNil()
	end)

	t.it("holds at most `capacity` frames", function()
		local h = History.new(20)
		for i = 0, 99 do
			History.record(h, i, i * TICK, { view(1, i) })
		end
		expect(History.frameCount(h)).toEqual(20)
		expect(History.newestTime(h)).approx(99 * TICK, 1e-9)
		expect(History.oldestTime(h)).approx(80 * TICK, 1e-9)
	end)

	t.it("deep-copies entities so later mutation cannot rewrite history", function()
		-- The bug this prevents is nasty: if frames alias the live simulation,
		-- every rewind silently agrees with the present and lag compensation
		-- looks like it works while doing nothing.
		local h = History.new()
		local live = view(1, 10)
		History.record(h, 0, 0, { live })
		live.pos = Types.vec3(999, 0, 0)
		live.hpPct = 0

		local result = History.rewind(h, 0, 0) :: History.RewindResult
		expect(result.entities[1].pos.x).toEqual(10)
		expect(result.entities[1].hpPct).toEqual(1)
	end)
end)

t.describe("net/History rewind", function()
	t.it("returns the exact frame when the target lands on a tick", function()
		local h, now = linearHistory(10)
		local result = History.rewind(h, 5 * TICK, now) :: History.RewindResult
		expect(result.entities[1].pos.x).approx(5, 1e-9)
		expect(result.clamped).toBeFalsy()
		expect(result.actualTime).approx(5 * TICK, 1e-9)
	end)

	t.it("interpolates between two ticks", function()
		local h, now = linearHistory(10)
		-- Halfway between tick 5 (x=5) and tick 6 (x=6).
		local result = History.rewind(h, 5.5 * TICK, now) :: History.RewindResult
		expect(result.entities[1].pos.x).approx(5.5, 1e-9)
		expect(result.clamped).toBeFalsy()
	end)

	t.it("interpolates at arbitrary fractions", function()
		-- Sample inside the compensation window. With 10 frames, now = 0.45s
		-- and a 0.25s window, anything before tick 4 is legitimately clamped —
		-- see the clamping test below.
		local h, now = linearHistory(10)
		for _, frac in { 0.1, 0.25, 0.75, 0.9 } do
			local result = History.rewind(h, (6 + frac) * TICK, now) :: History.RewindResult
			expect(result.entities[1].pos.x).approx(6 + frac, 1e-9)
			expect(result.clamped).toBeFalsy()
		end
	end)

	t.it("clamps a target just outside the window, and not one just inside", function()
		-- Guards the exact boundary, which the fraction test above tripped over.
		local h, now = linearHistory(10) -- now = 0.45, window 0.25 -> earliest 0.20
		expect((History.rewind(h, 0.21, now) :: History.RewindResult).clamped).toBeFalsy()
		expect((History.rewind(h, 0.19, now) :: History.RewindResult).clamped).toBeTruthy()
	end)

	t.it("does not extrapolate past the newest frame", function()
		-- The server knows the present; inventing a future position would let a
		-- client with a fast clock claim hits that never existed.
		local h, now = linearHistory(10)
		local result = History.rewind(h, now + 5, now) :: History.RewindResult
		expect(result.entities[1].pos.x).approx(9, 1e-9)
		expect(result.actualTime).approx(now, 1e-9)
	end)

	t.it("clamps a target older than the compensation window", function()
		local h = History.new(20, 0.25)
		for i = 0, 19 do
			History.record(h, i, i * TICK, { view(1, i) })
		end
		local now = 19 * TICK

		-- 0.5s back, but the window is 0.25s -> clamped to now - 0.25.
		local result = History.rewind(h, now - 0.5, now) :: History.RewindResult
		expect(result.clamped).toBeTruthy()
		expect(result.actualTime >= now - 0.25 - 1e-9).toBeTruthy()
		expect(result.entities[1].pos.x).approx(14, 1e-6)
	end)

	t.it("reports clamping when the target falls off the back of the buffer", function()
		-- Distinct from window clamping: the buffer simply does not go back
		-- that far. A high rate here means the buffer is undersized for the
		-- population's latency, which is a tuning signal worth measuring.
		local h = History.new(20, 10)
		for i = 0, 19 do
			History.record(h, i, i * TICK, { view(1, i) })
		end
		local now = 19 * TICK
		local result = History.rewind(h, now - 5, now) :: History.RewindResult
		expect(result.clamped).toBeTruthy()
		expect(result.entities[1].pos.x).approx(0, 1e-9)
	end)

	t.it("a target inside the window is never reported as clamped", function()
		local h, now = linearHistory(20)
		for back = 0, 4 do
			local result = History.rewind(h, now - back * TICK, now) :: History.RewindResult
			expect(result.clamped).toBeFalsy()
		end
	end)
end)

t.describe("net/History interpolation detail", function()
	t.it("takes the short way round on yaw", function()
		local h = History.new()
		History.record(h, 0, 0, { view(1, 0, math.rad(350)) })
		History.record(h, 1, TICK, { view(1, 0, math.rad(10)) })

		local result = History.rewind(h, TICK * 0.5, TICK) :: History.RewindResult
		-- Midpoint of 350 -> 10 the short way is 0 (or 360), not 180.
		local yaw = result.entities[1].yaw % (math.pi * 2)
		local distanceFromZero = math.min(yaw, math.pi * 2 - yaw)
		expect(distanceFromZero).approx(0, 1e-6)
	end)

	t.it("snaps discrete fields to the nearer frame instead of blending them", function()
		local h = History.new()
		History.record(h, 0, 0, { view(1, 0, 0, "move") })
		History.record(h, 1, TICK, { view(1, 0, 0, "death") })

		expect((History.rewind(h, TICK * 0.2, TICK) :: History.RewindResult).entities[1].state).toEqual("move")
		expect((History.rewind(h, TICK * 0.8, TICK) :: History.RewindResult).entities[1].state).toEqual("death")
	end)

	t.it("interpolates hp continuously", function()
		local h = History.new()
		History.record(h, 0, 0, { view(1, 0, 0, "move", 1.0) })
		History.record(h, 1, TICK, { view(1, 0, 0, "move", 0.0) })
		local result = History.rewind(h, TICK * 0.5, TICK) :: History.RewindResult
		expect(result.entities[1].hpPct).approx(0.5, 1e-9)
	end)

	t.it("carries an entity that spawned mid-window", function()
		local h = History.new()
		History.record(h, 0, 0, { view(1, 0) })
		History.record(h, 1, TICK, { view(1, 1), view(2, 50) })

		local result = History.rewind(h, TICK * 0.5, TICK) :: History.RewindResult
		expect(#result.entities).toEqual(2)
	end)

	t.it("carries an entity that despawned mid-window", function()
		-- The shooter saw it, so they must be able to hit it. Dropping it here
		-- would silently eat legitimate hits on a target that just died.
		local h = History.new()
		History.record(h, 0, 0, { view(1, 0), view(2, 50) })
		History.record(h, 1, TICK, { view(1, 1) })

		local result = History.rewind(h, TICK * 0.5, TICK) :: History.RewindResult
		expect(#result.entities).toEqual(2)

		local found = false
		for _, e in result.entities do
			if e.id == 2 then
				found = true
				expect(e.pos.x).approx(50, 1e-9)
			end
		end
		expect(found).toBeTruthy()
	end)

	t.it("handles many entities across the whole window", function()
		local h = History.new()
		for tick = 0, 19 do
			local entities: { Types.EntityView } = {}
			for id = 1, 40 do
				entities[id] = view(id, tick * 2 + id)
			end
			History.record(h, tick, tick * TICK, entities)
		end

		local now = 19 * TICK
		local result = History.rewind(h, now - 0.1, now) :: History.RewindResult
		expect(#result.entities).toEqual(40)
		-- 0.1s back = 2 ticks -> tick 17, so entity id N sits at 17*2 + N.
		expect(result.entities[1].pos.x).approx(35, 1e-6)
		expect(result.entities[40].pos.x).approx(74, 1e-6)
	end)

	t.it("tolerates a zero-duration span without dividing by zero", function()
		local h = History.new()
		History.record(h, 0, 1.0, { view(1, 5) })
		History.record(h, 1, 1.0, { view(1, 9) })
		local result = History.rewind(h, 1.0, 1.0) :: History.RewindResult
		expect(result.entities[1].pos.x == 5 or result.entities[1].pos.x == 9).toBeTruthy()
	end)
end)
