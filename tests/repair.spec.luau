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
	channelSeconds = 2.0,
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
	t.it("pays out continuously rather than only at the end", function()
		-- An all-or-nothing channel feels dead for its whole duration: you hold
		-- a key and nothing happens until it either works or does not.
		local s = Repair.new(P)
		Repair.begin(s, 100, 50, 100, P)
		local done, heal = Repair.collect(s, 101, P)
		expect(done).toBeFalsy()
		expect(heal > 0).toBeTruthy()
		expect(Repair.isChannelling(s)).toBeTruthy()
	end)

	t.it("accelerates, so most of the value lands late", function()
		-- Half way through has paid a quarter. That is what keeps the payout
		-- responsive without making an early bail as good as finishing.
		expect(Repair.healedFraction(0)).toEqual(0)
		expect(Repair.healedFraction(0.5)).approx(0.25, 1e-9)
		expect(Repair.healedFraction(1)).toEqual(1)
		-- The final third carries more than the first two thirds combined.
		local lastThird = Repair.healedFraction(1) - Repair.healedFraction(2 / 3)
		expect(lastThird > Repair.healedFraction(2 / 3)).toBeTruthy()
	end)

	t.it("clamps a progress outside 0..1", function()
		expect(Repair.healedFraction(-3)).toEqual(0)
		expect(Repair.healedFraction(9)).toEqual(1)
	end)

	t.it("pays exactly the deficit across a channel, no more", function()
		-- Also pins the contract the server adapter depends on: the deltas sum
		-- to the whole heal. Banking only the completing tick's delta -- which
		-- the adapter did -- pays a few percent of it.
		local s = Repair.new(P)
		Repair.begin(s, 100, 10, 100, P)
		local total = 0
		for step = 0, 40 do
			local _, heal = Repair.collect(s, 100 + step * 0.1, P)
			total += heal
		end
		expect(total).approx(90, 1e-6)
	end)

	t.it("pays a small slice on the completing tick when polled often", function()
		-- The shape of the adapter bug, stated directly: at a realistic tick
		-- rate the final delta is a rounding error next to the whole heal, so a
		-- caller that applies only `done` deltas heals almost nothing.
		local s = Repair.new(P)
		Repair.begin(s, 100, 10, 100, P)
		local last = 0
		for step = 1, 40 do
			local _, heal = Repair.collect(s, 100 + step * 0.05, P)
			last = heal
		end
		expect(last < 90 * 0.1).toBeTruthy()
	end)

	t.it("keeps what it already paid when interrupted", function()
		-- The other half of the accelerating curve: bailing early is weak, not
		-- worthless. The charge is still gone.
		local s = Repair.new(P)
		Repair.begin(s, 100, 50, 100, P)
		local _, paid = Repair.collect(s, 101, P)
		Repair.cancel(s)
		expect(paid > 0).toBeTruthy()
		expect(paid < 50).toBeTruthy()
		expect(s.chargesLeft).toEqual(1)
	end)

	t.it("completes at the end of the channel", function()
		local s = Repair.new(P)
		Repair.begin(s, 100, 50, 100, P)
		local done, heal = Repair.collect(s, 102, P)
		expect(done).toBeTruthy()
		-- Nothing collected in between, so the whole heal arrives in one delta.
		expect(heal).approx(50, 1e-9)
		expect(Repair.isChannelling(s)).toBeFalsy()
	end)

	t.it("heals to full from any deficit", function()
		-- The charge is the cost, not the number of points. A player on 5 HP
		-- and a player on 95 HP both get a full bar out of one charge, so
		-- nobody is rewarded for walking around hurt to make one worth more.
		for _, hp in { 5, 50, 95, 149 } do
			local s = Repair.new(P)
			Repair.begin(s, 100, hp, 150, P)
			local _, heal = Repair.collect(s, 102, P)
			expect(hp + heal).approx(150, 1e-9)
		end
	end)

	t.it("does not grow to cover damage taken mid-channel", function()
		-- The deficit is fixed when the channel begins. Otherwise being hit
		-- during a repair would be free, and the interrupt rule is what makes
		-- the channel a commitment.
		local s = Repair.new(P)
		Repair.begin(s, 100, 120, 150, P)
		local _, heal = Repair.collect(s, 102, P)
		expect(heal).approx(30, 1e-9)
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
		expect(Repair.progress(s, 101, P)).approx(0.5, 1e-9)
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
		-- Each charge is now a full heal, so `charges` is the only thing left
		-- holding healing in check -- this bound is doing all the work the old
		-- charges-times-points one used to share.
		expect(RepairConfig.charges <= 2).toBeTruthy()
	end)

	t.it("costs long enough to be a commitment", function()
		expect(RepairConfig.channelSeconds >= 1.2).toBeTruthy()
	end)

	t.it("takes longer than a sweep buys you", function()
		-- The two are meant to be used together: sweep to make space, then
		-- heal. If the channel were shorter than the sweep's cooldown the
		-- player would never have to think about the order.
		expect(RepairConfig.channelSeconds < Melee.cooldownSeconds).toBeTruthy()
	end)
end)
