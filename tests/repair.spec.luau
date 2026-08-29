--!strict
--[[ Field repair.

	The cases that matter are the ones that would make healing free: getting a
	charge back after cancelling, healing twice off one charge, or healing at
	full health.
]]

local t = require("./framework")
local expect = t.expect

local Repair = require("../src/shared/core/sim/Repair")

local P: Repair.Params = {
	charges = 2,
	healAmount = 45,
	channelSeconds = 2.5,
}

t.describe("sim/Repair starting", function()
	t.it("begins when hurt and holding a charge", function()
		local s = Repair.new(P)
		expect(Repair.begin(s, 100, 60, 100, P)).toBeTruthy()
		expect(Repair.isChannelling(s)).toBeTruthy()
	end)

	t.it("spends the charge up front", function()
		-- Not on completion: see the module header. A charge returned on
		-- interruption would make cancelling free, so the right play would be
		-- to start a repair every time you were hit and cancel it.
		local s = Repair.new(P)
		Repair.begin(s, 100, 60, 100, P)
		expect(s.chargesLeft).toEqual(1)
	end)

	t.it("refuses at full health", function()
		local s = Repair.new(P)
		local ok, reason = Repair.begin(s, 100, 100, 100, P)
		expect(ok).toBeFalsy()
		expect(reason).toEqual("already_full")
		expect(s.chargesLeft).toEqual(2)
	end)

	t.it("refuses while already repairing", function()
		local s = Repair.new(P)
		Repair.begin(s, 100, 60, 100, P)
		local ok, reason = Repair.begin(s, 100.5, 60, 100, P)
		expect(ok).toBeFalsy()
		expect(reason).toEqual("already_repairing")
		-- And crucially does not spend a second charge.
		expect(s.chargesLeft).toEqual(1)
	end)

	t.it("refuses once out of charges", function()
		local s = Repair.new(P)
		Repair.begin(s, 0, 50, 100, P)
		Repair.collect(s, 10, P)
		Repair.begin(s, 20, 50, 100, P)
		Repair.collect(s, 30, P)
		local ok, reason = Repair.begin(s, 40, 50, 100, P)
		expect(ok).toBeFalsy()
		expect(reason).toEqual("no_charges")
	end)

	t.it("refuses when dead", function()
		local s = Repair.new(P)
		local ok, reason = Repair.begin(s, 100, 0, 100, P)
		expect(ok).toBeFalsy()
		expect(reason).toEqual("dead")
	end)

	t.it("refuses a nonsense clock", function()
		local s = Repair.new(P)
		expect(Repair.begin(s, 0 / 0, 50, 100, P)).toBeFalsy()
		expect(s.chargesLeft).toEqual(2)
	end)
end)

t.describe("sim/Repair channelling", function()
	t.it("heals nothing before the channel finishes", function()
		local s = Repair.new(P)
		Repair.begin(s, 100, 50, 100, P)
		local done, heal = Repair.collect(s, 102, P)
		expect(done).toBeFalsy()
		expect(heal).toEqual(0)
		expect(Repair.isChannelling(s)).toBeTruthy()
	end)

	t.it("heals once the channel completes", function()
		local s = Repair.new(P)
		Repair.begin(s, 100, 50, 100, P)
		local done, heal = Repair.collect(s, 102.5, P)
		expect(done).toBeTruthy()
		expect(heal).toEqual(P.healAmount)
		expect(Repair.isChannelling(s)).toBeFalsy()
	end)

	t.it("cannot be collected twice off one charge", function()
		-- The obvious exploit: keep calling collect after it finished.
		local s = Repair.new(P)
		Repair.begin(s, 100, 50, 100, P)
		Repair.collect(s, 103, P)
		local done, heal = Repair.collect(s, 104, P)
		expect(done).toBeFalsy()
		expect(heal).toEqual(0)
	end)

	t.it("reports progress across the channel", function()
		local s = Repair.new(P)
		Repair.begin(s, 100, 50, 100, P)
		expect(Repair.progress(s, 100, P)).approx(0, 1e-9)
		expect(Repair.progress(s, 101.25, P)).approx(0.5, 1e-9)
		expect(Repair.progress(s, 999, P)).toEqual(1)
	end)

	t.it("reports no progress when not repairing", function()
		expect(Repair.progress(Repair.new(P), 100, P)).toEqual(0)
	end)
end)

t.describe("sim/Repair interruption", function()
	t.it("cancels an active channel and keeps the charge spent", function()
		local s = Repair.new(P)
		Repair.begin(s, 100, 50, 100, P)
		expect(Repair.cancel(s)).toBeTruthy()
		expect(Repair.isChannelling(s)).toBeFalsy()
		-- The whole point: interrupting costs you the charge.
		expect(s.chargesLeft).toEqual(1)
		expect(s.interrupted).toEqual(1)
	end)

	t.it("heals nothing after being cancelled", function()
		local s = Repair.new(P)
		Repair.begin(s, 100, 50, 100, P)
		Repair.cancel(s)
		local done, heal = Repair.collect(s, 999, P)
		expect(done).toBeFalsy()
		expect(heal).toEqual(0)
	end)

	t.it("reports nothing when there was no channel to cancel", function()
		-- Being told the repair was interrupted when you were not repairing is
		-- worse than silence.
		expect(Repair.cancel(Repair.new(P))).toBeFalsy()
	end)

	t.it("counts completions and interruptions separately", function()
		local s = Repair.new(P)
		Repair.begin(s, 0, 50, 100, P)
		Repair.collect(s, 10, P)
		Repair.begin(s, 20, 50, 100, P)
		Repair.cancel(s)
		expect(s.completed).toEqual(1)
		expect(s.interrupted).toEqual(1)
		expect(s.chargesLeft).toEqual(0)
	end)
end)

t.describe("config/Repair", function()
	local Melee = require("../src/shared/config/Melee")
	local RepairConfig = require("../src/shared/config/Repair")

	t.it("cannot fully undo a run's worth of damage", function()
		-- Finite by design: charges times heal must not exceed a couple of
		-- full health bars, or attrition stops mattering.
		expect(RepairConfig.charges * RepairConfig.healAmount <= 200).toBeTruthy()
	end)

	t.it("costs long enough to be a commitment", function()
		expect(RepairConfig.channelSeconds >= 1.5).toBeTruthy()
	end)

	t.it("takes longer than a sweep buys you", function()
		-- The two are meant to be used together: sweep to make space, then
		-- heal. If the channel were shorter than the sweep's cooldown the
		-- player would never have to think about the order.
		expect(RepairConfig.channelSeconds < Melee.cooldownSeconds).toBeTruthy()
	end)
end)
