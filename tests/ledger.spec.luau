--!strict
--[[ M6-1. core/economy/Ledger -- hand-verified against independently
	tracked expected values, not re-derived from the module's own math.
]]

local t = require("./framework")
local expect = t.expect

local Ledger = require("../src/shared/core/economy/Ledger")
local Rng = require("../src/shared/core/util/Rng")

t.describe("Ledger.apply", function()
	t.it("a fresh state has zero balance for anyone", function()
		local state = Ledger.new()
		expect(Ledger.balance(state, "p1")).toEqual(0)
	end)

	t.it("credits raise the balance by exactly delta", function()
		local state = Ledger.new()
		local _, applied = Ledger.apply(state, {
			pid = "p1",
			delta = 250,
			reason = "extract_payout",
			runId = "run1",
			idemKey = Ledger.makeKey("run1", "p1", "extract_payout", 1),
			ts = 0,
		})
		expect(applied).toBeTruthy()
		expect(Ledger.balance(state, "p1")).toEqual(250)
	end)

	t.it("a retried idemKey is a no-op, not an error", function()
		local state = Ledger.new()
		local key = Ledger.makeKey("run1", "p1", "extract_payout", 1)
		local _, first = Ledger.apply(state, {
			pid = "p1",
			delta = 250,
			reason = "extract_payout",
			runId = "run1",
			idemKey = key,
			ts = 0,
		})
		local _, second = Ledger.apply(state, {
			pid = "p1",
			delta = 250,
			reason = "extract_payout",
			runId = "run1",
			idemKey = key,
			ts = 1,
		})
		expect(first).toBeTruthy()
		expect(second).never().toBeTruthy()
		-- The retry did not double-apply.
		expect(Ledger.balance(state, "p1")).toEqual(250)
	end)

	t.it("an entry that would drive the balance negative is rejected, not clamped", function()
		local state = Ledger.new()
		Ledger.apply(state, {
			pid = "p1",
			delta = 100,
			reason = "extract_payout",
			runId = "run1",
			idemKey = Ledger.makeKey("run1", "p1", "extract_payout", 1),
			ts = 0,
		})
		local _, applied = Ledger.apply(state, {
			pid = "p1",
			delta = -150,
			reason = "market_purchase",
			runId = "run1",
			idemKey = Ledger.makeKey("run1", "p1", "market_purchase", 2),
			ts = 1,
		})
		expect(applied).never().toBeTruthy()
		-- Rejected, so balance is untouched at 100, not clamped to 0.
		expect(Ledger.balance(state, "p1")).toEqual(100)
	end)

	t.it("a rejected idemKey is not marked seen -- a corrected retry can still land", function()
		local state = Ledger.new()
		Ledger.apply(state, {
			pid = "p1",
			delta = 100,
			reason = "extract_payout",
			runId = "run1",
			idemKey = Ledger.makeKey("run1", "p1", "extract_payout", 1),
			ts = 0,
		})
		local key = Ledger.makeKey("run1", "p1", "market_purchase", 2)
		local _, rejected = Ledger.apply(state, {
			pid = "p1",
			delta = -150,
			reason = "market_purchase",
			runId = "run1",
			idemKey = key,
			ts = 1,
		})
		expect(rejected).never().toBeTruthy()
		-- Same idemKey, now affordable after topping up -- must be allowed to apply.
		Ledger.apply(state, {
			pid = "p1",
			delta = 100,
			reason = "extract_payout",
			runId = "run1",
			idemKey = Ledger.makeKey("run1", "p1", "extract_payout", 3),
			ts = 2,
		})
		local _, retried = Ledger.apply(state, {
			pid = "p1",
			delta = -150,
			reason = "market_purchase",
			runId = "run1",
			idemKey = key,
			ts = 3,
		})
		expect(retried).toBeTruthy()
		expect(Ledger.balance(state, "p1")).toEqual(50)
	end)

	t.it("balance equals the sum of applied deltas across 10,000 entries", function()
		local state = Ledger.new()
		local rng = Rng.new(4242)
		local pids = { "p1", "p2", "p3", "p4", "p5" }
		local expected: { [string]: number } = {}
		for _, pid in pids do
			expected[pid] = 0
		end

		for i = 1, 10000 do
			local pid = Rng.pick(rng, pids)
			local delta = Rng.nextRange(rng, 1, 1000)
			local _, applied = Ledger.apply(state, {
				pid = pid,
				delta = delta,
				reason = "extract_payout",
				runId = "sim",
				idemKey = Ledger.makeKey("sim", pid, "extract_payout", i),
				ts = i,
			})
			expect(applied).toBeTruthy()
			expected[pid] += delta
		end

		for _, pid in pids do
			expect(Ledger.balance(state, pid)).toEqual(expected[pid])
		end
	end)
end)

t.describe("Ledger.makeKey", function()
	t.it("is deterministic: same inputs, same key", function()
		local a = Ledger.makeKey("run1", "p1", "extract_payout", 3)
		local b = Ledger.makeKey("run1", "p1", "extract_payout", 3)
		expect(a).toEqual(b)
	end)

	t.it("differs when any single field differs", function()
		local base = Ledger.makeKey("run1", "p1", "extract_payout", 3)
		expect(Ledger.makeKey("run2", "p1", "extract_payout", 3)).never().toEqual(base)
		expect(Ledger.makeKey("run1", "p2", "extract_payout", 3)).never().toEqual(base)
		expect(Ledger.makeKey("run1", "p1", "objective_bonus", 3)).never().toEqual(base)
		expect(Ledger.makeKey("run1", "p1", "extract_payout", 4)).never().toEqual(base)
	end)
end)

t.describe("Ledger.totals", function()
	t.it("hand-computed: two faucets and one sink in-window, one entry out-of-window", function()
		local state = Ledger.new()
		Ledger.apply(state, {
			pid = "p1",
			delta = 250,
			reason = "extract_payout",
			runId = "run1",
			idemKey = "k1",
			ts = 10,
		})
		Ledger.apply(state, {
			pid = "p1",
			delta = 400,
			reason = "objective_bonus",
			runId = "run1",
			idemKey = "k2",
			ts = 20,
		})
		Ledger.apply(state, {
			pid = "p1",
			delta = -100,
			reason = "repair",
			runId = "run1",
			idemKey = "k3",
			ts = 30,
		})
		-- Outside [0, 30].
		Ledger.apply(state, {
			pid = "p1",
			delta = 999,
			reason = "extract_payout",
			runId = "run1",
			idemKey = "k4",
			ts = 999,
		})
		local totals = Ledger.totals(state, 0, 30)
		expect(totals.faucet).toEqual(650) -- 250 + 400
		expect(totals.sink).toEqual(100) -- abs(-100)
	end)

	t.it("admin_adjust counts toward neither total", function()
		local state = Ledger.new()
		Ledger.apply(state, {
			pid = "p1",
			delta = 500,
			reason = "admin_adjust",
			runId = "run1",
			idemKey = "k1",
			ts = 5,
		})
		local totals = Ledger.totals(state, 0, 10)
		expect(totals.faucet).toEqual(0)
		expect(totals.sink).toEqual(0)
	end)
end)
