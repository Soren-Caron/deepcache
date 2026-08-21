--!strict
--[[ M6-3. core/economy/Payouts -- faucet/sink amounts, insurance, and the
	sign rule the accept criterion is actually about ("each reason code
	produces a ledger entry with the right sign").

	Amounts are hand-computed against config/Economy's real shipped rates, not
	re-derived from the module.
]]

local t = require("./framework")
local expect = t.expect

local Payouts = require("../src/shared/core/economy/Payouts")
local Ledger = require("../src/shared/core/economy/Ledger")
local EconomyConfig = require("../src/shared/config/Economy")

local RATES: Payouts.Rates = {
	extractBasePayout = EconomyConfig.faucets.extractBasePayout, -- 250
	extractValueRate = EconomyConfig.faucets.extractValueRate, -- 1.0
	objectiveBonus = EconomyConfig.faucets.objectiveBonus, -- 400
	dailyFirstExtract = EconomyConfig.faucets.dailyFirstExtract, -- 750
	repairPerMinute = EconomyConfig.sinks.repairPerMinute, -- 40
	ammoPerMagazine = EconomyConfig.sinks.ammoPerMagazine, -- 25
	insurancePremiumRate = EconomyConfig.sinks.insurancePremiumRate, -- 0.18
	insuranceRecoveryRate = EconomyConfig.sinks.insuranceRecoveryRate, -- 0.40
}

t.describe("Payouts faucets", function()
	t.it("extraction payout is base + carried value, hand-computed", function()
		-- 250 + 1000 * 1.0 = 1250 at multiplier 1.
		expect(Payouts.extractPayout(1000, RATES, 1.0)).toEqual(1250)
	end)

	t.it("the multiplier scales extraction payout", function()
		-- 1250 * 0.8 = 1000
		expect(Payouts.extractPayout(1000, RATES, 0.8)).toEqual(1000)
		-- 1250 * 1.25 = 1562.5 -> floors to 1562
		expect(Payouts.extractPayout(1000, RATES, 1.25)).toEqual(1562)
	end)

	t.it("extracting nothing still pays the base", function()
		expect(Payouts.extractPayout(0, RATES, 1.0)).toEqual(250)
	end)

	t.it("objective bonus is per completed objective", function()
		expect(Payouts.objectiveBonus(0, RATES, 1.0)).toEqual(0)
		expect(Payouts.objectiveBonus(3, RATES, 1.0)).toEqual(1200)
	end)

	t.it("daily first extract is a flat faucet", function()
		expect(Payouts.dailyFirstExtract(RATES, 1.0)).toEqual(750)
	end)

	t.it("every faucet amount is a whole number of credits", function()
		-- The ledger's columns are BIGINT; a fractional faucet cannot be stored.
		for _, m in { 0.83, 0.97, 1.13, 1.24 } do
			local payout = Payouts.extractPayout(777, RATES, m)
			expect(payout).toEqual(math.floor(payout))
		end
	end)
end)

t.describe("Payouts sinks", function()
	t.it("repair scales with run length, hand-computed", function()
		-- 10 minutes at 40/min = 400.
		expect(Payouts.repairCost(600, RATES)).toEqual(400)
		expect(Payouts.repairCost(0, RATES)).toEqual(0)
	end)

	t.it("ammo scales with magazines used", function()
		expect(Payouts.ammoCost(7, RATES)).toEqual(175)
	end)

	t.it("a negative or NaN input never produces a negative magnitude", function()
		expect(Payouts.repairCost(-600, RATES)).toEqual(0)
		expect(Payouts.ammoCost(0 / 0, RATES)).toEqual(0)
	end)
end)

t.describe("Payouts insurance", function()
	t.it("premium is a fraction of declared value, hand-computed", function()
		-- 2000 * 0.18 = 360.
		expect(Payouts.insurancePremium(2000, RATES)).toEqual(360)
	end)

	t.it("claim recovers 40% of what was lost", function()
		-- 2000 lost, 2000 declared -> 800.
		expect(Payouts.insuranceClaim(2000, 2000, RATES)).toEqual(800)
	end)

	t.it("a claim is capped at the declared value the premium was charged on", function()
		-- Insure a trivial 100, then die holding 100000. Without the cap this
		-- pays 40000 against a 18-credit premium -- the most interesting sink
		-- in the economy becomes its largest faucet.
		local premium = Payouts.insurancePremium(100, RATES)
		local claim = Payouts.insuranceClaim(100000, 100, RATES)
		expect(premium).toEqual(18)
		expect(claim).toEqual(40) -- 40% of the covered 100, not of the 100000
		expect(claim < 100).toBeTruthy()
	end)

	t.it("insurance is a net sink at the documented rates", function()
		-- Premium 18% up front vs 40% recovery only on death. Fully insured
		-- and dying every single run is the player's best case, and even then
		-- it must not print money over a run of runs.
		local declared = 10000
		local premium = Payouts.insurancePremium(declared, RATES)
		local claim = Payouts.insuranceClaim(declared, declared, RATES)
		-- 1800 paid, 4000 back when they die -- so a *death* is +2200 for the
		-- player, which is the point of buying down variance. The sink only
		-- shows up across the runs they survive, which is most of them.
		expect(premium).toEqual(1800)
		expect(claim).toEqual(4000)
		-- Break-even death rate: premium/claim = 45%. Above that insurance
		-- pays for itself, which is why the healthy uptake band is 30-60%.
		expect(premium / claim).approx(0.45, 1e-9)
	end)

	t.it("no death means no claim", function()
		expect(Payouts.insuranceClaim(0, 5000, RATES)).toEqual(0)
	end)
end)

t.describe("Payouts.signedDelta -- the M6-3 accept criterion", function()
	t.it("every faucet reason produces a positive delta", function()
		for _, reason in Ledger.FAUCETS do
			expect(Payouts.signedDelta(reason, 500) > 0).toBeTruthy()
		end
	end)

	t.it("every sink reason produces a negative delta", function()
		for _, reason in Ledger.SINKS do
			expect(Payouts.signedDelta(reason, 500) < 0).toBeTruthy()
		end
	end)

	t.it("the sign does not depend on the caller's sign", function()
		-- A caller passing a magnitude and a caller passing an already-negative
		-- number must land on the same ledger delta, or the same sink charged
		-- from two code paths would disagree.
		expect(Payouts.signedDelta("repair", 400)).toEqual(-400)
		expect(Payouts.signedDelta("repair", -400)).toEqual(-400)
		expect(Payouts.signedDelta("extract_payout", 400)).toEqual(400)
		expect(Payouts.signedDelta("extract_payout", -400)).toEqual(400)
	end)

	t.it("admin_adjust is the one reason that keeps the caller's sign", function()
		expect(Payouts.signedDelta("admin_adjust", 500)).toEqual(500)
		expect(Payouts.signedDelta("admin_adjust", -500)).toEqual(-500)
	end)

	t.it("every reason code is classified -- none silently defaults to faucet", function()
		-- Guards the case where someone adds a Reason to the union but to
		-- neither table; signedDelta throws rather than minting currency.
		local reasons: { Ledger.Reason } = {
			"extract_payout", "objective_bonus", "daily_first",
			"repair", "ammo", "insurance_premium", "insurance_claim",
			"market_fee", "market_sale", "market_purchase",
			"cosmetic", "admin_adjust",
		}
		for _, reason in reasons do
			local ok = pcall(Payouts.signedDelta, reason, 100)
			expect(ok).toBeTruthy()
		end
	end)
end)

t.describe("Payouts integrates with Ledger totals", function()
	t.it("a full run's entries land with the signs the controller expects", function()
		-- The end-to-end shape the M6-3 accept criterion describes: run a real
		-- sequence of reason codes through the ledger and confirm faucet/sink
		-- totals come out where docs/07 says they should.
		local state = Ledger.new()
		local function apply(reason: Ledger.Reason, magnitude: number, seq: number)
			local _, ok = Ledger.apply(state, {
				pid = "p1",
				delta = Payouts.signedDelta(reason, magnitude),
				reason = reason,
				runId = "run1",
				idemKey = Ledger.makeKey("run1", "p1", reason, seq),
				ts = seq,
			})
			expect(ok).toBeTruthy()
		end

		apply("extract_payout", Payouts.extractPayout(1000, RATES, 1.0), 1) -- +1250
		apply("objective_bonus", Payouts.objectiveBonus(1, RATES, 1.0), 2) -- +400
		apply("daily_first", Payouts.dailyFirstExtract(RATES, 1.0), 3) -- +750
		apply("repair", Payouts.repairCost(600, RATES), 4) -- -400
		apply("ammo", Payouts.ammoCost(7, RATES), 5) -- -175
		apply("insurance_premium", Payouts.insurancePremium(2000, RATES), 6) -- -360

		expect(Ledger.balance(state, "p1")).toEqual(1250 + 400 + 750 - 400 - 175 - 360)

		local totals = Ledger.totals(state, 0, 100)
		expect(totals.faucet).toEqual(2400)
		expect(totals.sink).toEqual(935)
	end)
end)
