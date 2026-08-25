--!strict
--[[ Sprint stamina.

	The cases that matter are the ones that let a player sprint for free:
	tapping the key on an empty bar, and regenerating while still sprinting.
]]

local t = require("./framework")
local expect = t.expect

local Stamina = require("../src/shared/core/sim/Stamina")
local Movement = require("../src/shared/config/Movement")

local P: Stamina.Params = {
	max = 100,
	drainPerSecond = 22,
	regenPerSecond = 14,
	regenDelay = 0.8,
	recoverFraction = 0.35,
	minToStart = 8,
}

--- Drain to exactly empty and stop. Holding sprint *past* empty is not the
--- same state: the player is no longer sprinting, so the bar regenerates while
--- the key is still down, and after ten seconds of "holding sprint" they are
--- back above the recovery threshold. Tests about the exhausted state have to
--- stop at empty or they are testing a recovered player.
local function drainToEmpty(state: Stamina.State)
	for _ = 1, 200 do
		Stamina.step(state, 0.05, true, P)
		if state.exhausted then
			return
		end
	end
	error("never exhausted")
end

--- Hold sprint for `seconds` at 20 Hz.
local function hold(state: Stamina.State, seconds: number, wants: boolean): number
	local sprintingTicks = 0
	for _ = 1, math.floor(seconds / 0.05) do
		if Stamina.step(state, 0.05, wants, P) then
			sprintingTicks += 1
		end
	end
	return sprintingTicks
end

--------------------------------------------------------------------------------

t.describe("Stamina drain", function()
	t.it("starts full and able to sprint", function()
		local s = Stamina.new(P)
		expect(Stamina.fraction(s, P)).approx(1, 1e-9)
		expect(Stamina.canSprint(s, P)).toBeTruthy()
	end)

	t.it("drains at the configured rate", function()
		local s = Stamina.new(P)
		hold(s, 1, true)
		expect(s.current).approx(78, 0.5)
	end)

	t.it("empties in about max/drain seconds", function()
		local s = Stamina.new(P)
		-- 100 / 22 = 4.55s
		hold(s, 4.4, true)
		expect(s.current > 0).toBeTruthy()
		hold(s, 0.4, true)
		expect(s.current).toEqual(0)
	end)

	t.it("never goes negative", function()
		local s = Stamina.new(P)
		drainToEmpty(s)
		expect(s.current).toEqual(0)
	end)

	t.it("holding sprint through exhaustion stutters rather than running forever", function()
		-- Worth pinning, because it is not obvious: an exhausted player is not
		-- sprinting, so the bar refills with the key still down, the lockout
		-- clears at the recovery threshold, and the sprint resumes on its own.
		-- Holding the key therefore produces a repeating drain/recover cycle,
		-- not continuous sprint and not a permanent stop.
		--
		-- The cost is real and that is what makes it acceptable: sprinting is a
		-- minority of the cycle, so holding the key is strictly worse than
		-- pacing it.
		local s = Stamina.new(P)
		local sprinted = hold(s, 30, true)
		local total = math.floor(30 / 0.05)
		expect(sprinted > 0).toBeTruthy()
		expect(sprinted < total * 0.6).toBeTruthy()
	end)
end)

t.describe("Stamina exhaustion", function()
	t.it("locks out sprinting once the bar empties", function()
		local s = Stamina.new(P)
		drainToEmpty(s)
		expect(s.exhausted).toBeTruthy()
		expect(Stamina.canSprint(s, P)).toBeFalsy()
		expect(s.sprinting).toBeFalsy()
	end)

	t.it("refuses to sprint while exhausted even with some stamina back", function()
		local s = Stamina.new(P)
		drainToEmpty(s)
		-- Recover a little, but not to the threshold.
		hold(s, 2, false)
		expect(s.current > 0).toBeTruthy()
		expect(s.current < P.max * P.recoverFraction).toBeTruthy()
		expect(hold(s, 1, true)).toEqual(0)
	end)

	t.it("allows sprinting again past the recovery threshold", function()
		local s = Stamina.new(P)
		drainToEmpty(s)
		hold(s, 6, false)
		expect(s.exhausted).toBeFalsy()
		expect(hold(s, 0.2, true) > 0).toBeTruthy()
	end)

	t.it("tapping sprint on an empty bar grants nothing", function()
		-- The exploit this closes: without an exhaustion latch, every tap would
		-- grant one frame of sprint and the average speed would stay above walk
		-- forever.
		local s = Stamina.new(P)
		drainToEmpty(s)
		-- Two seconds of tapping, well inside the recovery window. Long enough
		-- that an unlatched implementation would grant dozens of frames.
		local granted = 0
		for _ = 1, 20 do
			Stamina.step(s, 0.05, false, P)
			if Stamina.step(s, 0.05, true, P) then
				granted += 1
			end
		end
		expect(granted).toEqual(0)
		expect(s.exhausted).toBeTruthy()
	end)
end)

t.describe("Stamina regeneration", function()
	t.it("does not regenerate during the delay", function()
		local s = Stamina.new(P)
		hold(s, 1, true)
		local afterSprint = s.current
		hold(s, 0.7, false)
		expect(s.current).approx(afterSprint, 1e-9)
	end)

	t.it("regenerates after the delay", function()
		local s = Stamina.new(P)
		hold(s, 1, true)
		local afterSprint = s.current
		hold(s, 2, false)
		expect(s.current > afterSprint).toBeTruthy()
	end)

	t.it("never exceeds max", function()
		local s = Stamina.new(P)
		hold(s, 1, true)
		hold(s, 60, false)
		expect(s.current).toEqual(P.max)
	end)

	t.it("does not regenerate while sprinting", function()
		-- Sprinting resets the delay timer every frame, so a player holding
		-- sprint can never be gaining stamina.
		local s = Stamina.new(P)
		local previous = s.current
		for _ = 1, 40 do
			Stamina.step(s, 0.05, true, P)
			expect(s.current <= previous).toBeTruthy()
			previous = s.current
		end
	end)
end)

t.describe("Stamina hostile inputs", function()
	t.it("ignores non-positive and non-finite dt", function()
		local s = Stamina.new(P)
		for _, bad in { 0, -1, 0 / 0, math.huge } do
			Stamina.step(s, bad, true, P)
		end
		expect(s.current).toEqual(P.max)
	end)

	t.it("fraction stays in 0..1", function()
		local s = Stamina.new(P)
		for _ = 1, 400 do
			Stamina.step(s, 0.05, true, P)
			local f = Stamina.fraction(s, P)
			expect(f >= 0 and f <= 1).toBeTruthy()
		end
	end)

	t.it("reset restores a usable state", function()
		local s = Stamina.new(P)
		drainToEmpty(s)
		Stamina.reset(s, P)
		expect(s.current).toEqual(P.max)
		expect(s.exhausted).toBeFalsy()
		expect(Stamina.canSprint(s, P)).toBeTruthy()
	end)
end)

t.describe("Movement config", function()
	t.it("sprint is faster than walking but not a teleport", function()
		expect(Movement.SPRINT_MULTIPLIER > 1).toBeTruthy()
		expect(Movement.SPRINT_MULTIPLIER <= 2).toBeTruthy()
	end)

	t.it("a full bar lasts a usable but finite sprint", function()
		-- Between two and ten seconds: shorter is not worth pressing, longer
		-- and it may as well be permanent.
		local seconds = Movement.STAMINA_MAX / Movement.STAMINA_DRAIN_PER_SECOND
		expect(seconds >= 2 and seconds <= 10).toBeTruthy()
	end)

	t.it("recovering fully takes longer than draining fully", function()
		-- Sprint has to cost more than it gives back, or it is free.
		local drain = Movement.STAMINA_MAX / Movement.STAMINA_DRAIN_PER_SECOND
		local regen = Movement.STAMINA_MAX / Movement.STAMINA_REGEN_PER_SECOND
		expect(regen > drain).toBeTruthy()
	end)
end)
