--!strict
--[[ Sound cue scheduling.

	The case worth the most here is a swarm: forty enemies landing hits in one
	tick must produce a handful of voices, not forty.
]]

local t = require("./framework")
local expect = t.expect

local Cues = require("../src/shared/core/audio/Cues")
local AudioConfig = require("../src/shared/config/Audio")

t.describe("audio/Cues throttling", function()
	t.it("always allows a cue never played before", function()
		local s = Cues.new()
		expect(Cues.shouldPlay(s, "weaponFireSidearm", 0, 10)).toBeTruthy()
	end)

	t.it("suppresses a repeat inside the interval", function()
		local s = Cues.new()
		Cues.shouldPlay(s, "hitConfirm", 100, 0.08)
		expect(Cues.shouldPlay(s, "hitConfirm", 100.04, 0.08)).toBeFalsy()
	end)

	t.it("allows again once the interval has passed", function()
		local s = Cues.new()
		Cues.shouldPlay(s, "hitConfirm", 100, 0.08)
		expect(Cues.shouldPlay(s, "hitConfirm", 100.09, 0.08)).toBeTruthy()
	end)

	t.it("throttles each cue independently", function()
		-- A burst of gunfire must not silence the hit confirmations it earns.
		local s = Cues.new()
		Cues.shouldPlay(s, "weaponFireCarbine", 5, 0.07)
		expect(Cues.shouldPlay(s, "hitConfirm", 5, 0.08)).toBeTruthy()
	end)

	t.it("collapses a swarm into a handful of voices", function()
		-- Forty strikes inside one 50ms tick.
		local s = Cues.new()
		local allowed = 0
		for i = 1, 40 do
			if Cues.shouldPlay(s, "hitTaken", 200 + i * 0.00125, 0.15) then
				allowed += 1
			end
		end
		expect(allowed).toEqual(1)
		expect(s.suppressed).toEqual(39)
	end)

	t.it("counts what it suppressed", function()
		-- A dropped cue that is never counted is indistinguishable from one
		-- that was never wired up, which is the failure this project keeps
		-- rediscovering.
		local s = Cues.new()
		Cues.shouldPlay(s, "a", 0, 1)
		Cues.shouldPlay(s, "a", 0.1, 1)
		expect(s.played).toEqual(1)
		expect(s.suppressed).toEqual(1)
	end)

	t.it("refuses a nonsense clock", function()
		local s = Cues.new()
		expect(Cues.shouldPlay(s, "a", 0 / 0, 1)).toBeFalsy()
		expect(Cues.shouldPlay(s, "a", math.huge, 1)).toBeFalsy()
	end)

	t.it("reset clears history", function()
		local s = Cues.new()
		Cues.shouldPlay(s, "a", 0, 10)
		Cues.reset(s)
		expect(Cues.shouldPlay(s, "a", 0, 10)).toBeTruthy()
	end)
end)

t.describe("audio/Cues pitch", function()
	t.it("centres on unity", function()
		expect(Cues.pitch(0.5, 0.06)).approx(1, 1e-9)
	end)

	t.it("spans the jitter band", function()
		expect(Cues.pitch(0, 0.06)).approx(0.94, 1e-9)
		expect(Cues.pitch(1, 0.06)).approx(1.06, 1e-9)
	end)

	t.it("never inverts or silences the sound", function()
		for step = 0, 20 do
			expect(Cues.pitch(step / 20, 0.5) > 0).toBeTruthy()
		end
	end)

	t.it("returns unity for degenerate input", function()
		expect(Cues.pitch(0.5, 0)).toEqual(1)
		expect(Cues.pitch(0 / 0, 0.06)).toEqual(1)
	end)

	t.it("clamps a roll outside 0..1", function()
		expect(Cues.pitch(5, 0.06)).approx(1.06, 1e-9)
		expect(Cues.pitch(-5, 0.06)).approx(0.94, 1e-9)
	end)
end)

t.describe("audio/Cues attenuation", function()
	t.it("is full at the listener", function()
		expect(Cues.attenuate(0, 100)).toEqual(1)
	end)

	t.it("is silent at and beyond the maximum", function()
		expect(Cues.attenuate(100, 100)).toEqual(0)
		expect(Cues.attenuate(500, 100)).toEqual(0)
	end)

	t.it("falls off gently near and steeply far", function()
		-- Squared falloff: at the halfway point it must be below linear's 0.5.
		expect(Cues.attenuate(50, 100)).approx(0.25, 1e-9)
	end)

	t.it("never increases with distance", function()
		local previous = math.huge
		for d = 0, 120, 5 do
			local v = Cues.attenuate(d, 100)
			expect(v <= previous).toBeTruthy()
			previous = v
		end
	end)
end)

t.describe("config/Audio", function()
	t.it("every cue is fully specified", function()
		for name, cue in AudioConfig.CUES do
			expect(typeof(cue.assetId) == "string").toBeTruthy()
			expect(cue.volume > 0 and cue.volume <= 1).toBeTruthy()
			expect(cue.jitter >= 0 and cue.jitter < 1).toBeTruthy()
			expect(cue.minInterval >= 0).toBeTruthy()
			expect(cue.rollOffMaxDistance > 0).toBeTruthy()
			expect(typeof(name) == "string").toBeTruthy()
		end
	end)

	t.it("has a cue for every weapon", function()
		local Weapons = require("../src/shared/config/Weapons")
		for id in Weapons :: any do
			expect(AudioConfig.CUES["weaponFire" .. id] ~= nil).toBeTruthy()
		end
	end)

	t.it("throttles hits harder than it throttles firing", function()
		-- Firing is player-paced and every shot is information; incoming hits
		-- from a swarm are not.
		expect(AudioConfig.CUES.hitTaken.minInterval > AudioConfig.CUES.weaponFireCarbine.minInterval).toBeTruthy()
	end)

	t.it("keeps the master volume sane", function()
		expect(AudioConfig.MASTER_VOLUME > 0 and AudioConfig.MASTER_VOLUME <= 1).toBeTruthy()
		expect(AudioConfig.MAX_CONCURRENT > 0).toBeTruthy()
	end)
end)
