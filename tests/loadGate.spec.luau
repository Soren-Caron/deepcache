--!strict
--[[ Boot sequencing.

	The cases that matter are the ones that make a loading screen worse than
	no loading screen: a bar that rewinds, a bar that sits full while waiting,
	and a screen that never leaves.
]]

local t = require("./framework")
local expect = t.expect

local LoadGate = require("../src/shared/core/boot/LoadGate")

local P: LoadGate.Params = {
	steps = {
		{ id = "a", label = "FIRST", weight = 1 },
		{ id = "b", label = "SECOND", weight = 3 },
		{ id = "c", label = "THIRD", weight = 1 },
	},
	minSeconds = 0.5,
	timeoutSeconds = 10,
	readyLabel = "READY",
}

local function allOpen(): { [string]: boolean }
	return { a = true, b = true, c = true }
end

t.describe("core/boot/LoadGate progress", function()
	t.it("starts at nothing and names the first gate", function()
		local s = LoadGate.new(100)
		local r = LoadGate.update(s, {}, 100, P)
		expect(r.progress).toEqual(0)
		expect(r.label).toEqual("FIRST")
		expect(r.complete).toBeFalsy()
	end)

	t.it("weights the steps rather than splitting evenly", function()
		-- Geometry is most of a real boot. Five equal jumps would misreport it.
		local s = LoadGate.new(100)
		local r = LoadGate.update(s, { a = true }, 100.1, P)
		expect(r.progress).approx(1 / 5, 1e-9)
		local r2 = LoadGate.update(s, { a = true, b = true }, 100.2, P)
		expect(r2.progress).approx(4 / 5, 1e-9)
	end)

	t.it("names the first gate still shut, not the last one opened", function()
		-- What makes a slow join diagnosable instead of just slow.
		local s = LoadGate.new(100)
		local r = LoadGate.update(s, { a = true, c = true }, 100.1, P)
		expect(r.label).toEqual("SECOND")
	end)

	t.it("never rewinds when a gate flickers shut again", function()
		-- ContentProvider's queue drops to zero and rises again as more
		-- geometry streams. Without latching the bar would visibly go
		-- backwards, which reads as a crash.
		local s = LoadGate.new(100)
		local up = LoadGate.update(s, { a = true, b = true }, 100.1, P)
		local down = LoadGate.update(s, { a = true, b = false }, 100.2, P)
		expect(down.progress).toEqual(up.progress)
		expect(down.label).toEqual("THIRD")
	end)

	t.it("ignores gate ids it does not know", function()
		-- A renamed or removed gate must not count toward completion.
		local s = LoadGate.new(100)
		local r = LoadGate.update(s, { nonsense = true }, 100.1, P)
		expect(r.progress).toEqual(0)
		expect(r.complete).toBeFalsy()
	end)

	t.it("stops short of full while still waiting", function()
		-- Every gate open but the minimum not yet served. A full bar that is
		-- still holding is what makes a loading screen feel hung.
		local s = LoadGate.new(100)
		local r = LoadGate.update(s, allOpen(), 100.1, P)
		expect(r.complete).toBeFalsy()
		expect(r.progress < 1).toBeTruthy()
		expect(r.progress > 0.9).toBeTruthy()
	end)

	t.it("reaches exactly full on completion", function()
		local s = LoadGate.new(100)
		local r = LoadGate.update(s, allOpen(), 101, P)
		expect(r.complete).toBeTruthy()
		expect(r.progress).toEqual(1)
		expect(r.label).toEqual("READY")
	end)
end)

t.describe("core/boot/LoadGate holding and letting go", function()
	t.it("holds for the minimum even when everything is instant", function()
		local s = LoadGate.new(100)
		expect(LoadGate.update(s, allOpen(), 100, P).complete).toBeFalsy()
		expect(LoadGate.update(s, allOpen(), 100.49, P).complete).toBeFalsy()
		expect(LoadGate.update(s, allOpen(), 100.5, P).complete).toBeTruthy()
	end)

	t.it("lets go on the timeout with gates still shut", function()
		-- Worse than the black room: a screen that never leaves.
		local s = LoadGate.new(100)
		expect(LoadGate.update(s, {}, 109.9, P).complete).toBeFalsy()
		local r = LoadGate.update(s, {}, 110, P)
		expect(r.complete).toBeTruthy()
		expect(r.timedOut).toBeTruthy()
		expect(r.progress).toEqual(1)
	end)

	t.it("does not report a timeout when it finished in time", function()
		-- The flag is a defect signal, so a normal boot must never raise it.
		local s = LoadGate.new(100)
		local r = LoadGate.update(s, allOpen(), 101, P)
		expect(r.complete).toBeTruthy()
		expect(r.timedOut).toBeFalsy()
	end)

	t.it("does not report a timeout for a slow but successful boot", function()
		-- Everything opens on the very last frame before the ceiling.
		local s = LoadGate.new(100)
		LoadGate.update(s, {}, 109.9, P)
		local r = LoadGate.update(s, allOpen(), 109.99, P)
		expect(r.complete).toBeTruthy()
		expect(r.timedOut).toBeFalsy()
	end)

	t.it("reports elapsed from the start, never negative", function()
		local s = LoadGate.new(100)
		expect(LoadGate.update(s, {}, 103, P).elapsed).approx(3, 1e-9)
		-- A clock that went backwards must not produce a negative bar.
		expect(LoadGate.update(s, {}, 99, P).elapsed).toEqual(0)
	end)

	t.it("survives a nonsense clock", function()
		local s = LoadGate.new(0 / 0)
		local r = LoadGate.update(s, {}, 0 / 0, P)
		expect(r.elapsed).toEqual(0)
		expect(r.complete).toBeFalsy()
	end)
end)

t.describe("core/boot/LoadGate bar easing", function()
	t.it("moves toward the target", function()
		local next_ = LoadGate.eased(0, 1, 1 / 60, 6)
		expect(next_ > 0).toBeTruthy()
		expect(next_ < 1).toBeTruthy()
	end)

	t.it("never overshoots", function()
		-- A large dt after a hitch is exactly when a linear step would sail
		-- past the target and show a bar past the end of its track.
		expect(LoadGate.eased(0, 1, 10, 6) <= 1).toBeTruthy()
		expect(LoadGate.eased(1, 0, 10, 6) >= 0).toBeTruthy()
	end)

	t.it("is frame-rate independent within a hair", function()
		-- One 0.1s step must land within a rounding error of ten 0.01s steps,
		-- or the bar visibly runs at different speeds on different machines.
		local coarse = LoadGate.eased(0, 1, 0.1, 6)
		local fine = 0
		for _ = 1, 10 do
			fine = LoadGate.eased(fine, 1, 0.01, 6)
		end
		expect(coarse).approx(fine, 1e-9)
	end)

	t.it("holds still on a zero or negative dt", function()
		expect(LoadGate.eased(0.4, 1, 0, 6)).toEqual(0.4)
		expect(LoadGate.eased(0.4, 1, -1, 6)).toEqual(0.4)
	end)

	t.it("holds still on a nonsense dt or value", function()
		expect(LoadGate.eased(0.4, 1, 0 / 0, 6)).toEqual(0.4)
		expect(LoadGate.eased(0.4, 0 / 0, 0.1, 6)).toEqual(0.4)
	end)
end)

t.describe("config/Boot", function()
	local BootConfig = require("../src/shared/config/Boot")

	t.it("declares every step with an id, a label and a weight", function()
		expect(#BootConfig.steps > 0).toBeTruthy()
		for _, step in BootConfig.steps do
			expect(typeof(step.id)).toEqual("string")
			expect(#step.label > 0).toBeTruthy()
			expect(step.weight > 0).toBeTruthy()
		end
	end)

	t.it("has no duplicate step ids", function()
		-- Two steps sharing an id would silently latch together, so opening one
		-- would report both.
		local seen: { [string]: boolean } = {}
		for _, step in BootConfig.steps do
			expect(seen[step.id]).toBeFalsy()
			seen[step.id] = true
		end
	end)

	t.it("lets go long before a player would give up", function()
		expect(BootConfig.timeoutSeconds <= 30).toBeTruthy()
		expect(BootConfig.minSeconds < BootConfig.timeoutSeconds).toBeTruthy()
	end)

	t.it("does not tax a fast join", function()
		expect(BootConfig.minSeconds <= 1.5).toBeTruthy()
	end)
end)
