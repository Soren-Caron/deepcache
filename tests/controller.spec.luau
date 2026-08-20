--!strict
--[[ M6-4. core/economy/Controller -- values hand-computed via an
	independent (Node.js) reimplementation of the exact formula in
	docs/07-ECONOMY.md, not re-derived from this module's own code.
]]

local t = require("./framework")
local expect = t.expect

local Controller = require("../src/shared/core/economy/Controller")

t.describe("Controller.new", function()
	t.it("starts at multiplier 1.0, zero integral, zero clamped days", function()
		local state = Controller.new()
		expect(state.multiplier).toEqual(1.0)
		expect(state.integral).toEqual(0)
		expect(state.clampedDays).toEqual(0)
	end)
end)

t.describe("Controller.step -- single-step hand computation", function()
	t.it("ratio=0.75 (under target): err=0.10, integral=0.10, multiplier 1.0 -> 0.97", function()
		local state = Controller.new()
		local newState, decision = Controller.step(state, { faucetTotal = 1000, sinkTotal = 750, runCount = 300 }, true)
		expect(decision.applied).toBeTruthy()
		expect(decision.ratio).approx(0.75, 1e-9)
		expect(newState.integral).approx(0.10, 1e-9)
		expect(newState.multiplier).approx(0.97, 1e-9)
		expect(decision.multiplier).approx(0.97, 1e-9)
	end)
end)

t.describe("Controller.step -- guardrails", function()
	t.it("below the 200-run sample floor, the update is skipped entirely", function()
		local state = { multiplier = 1.1, integral = 0.5, clampedDays = 0 }
		local newState, decision =
			Controller.step(state, { faucetTotal = 1000, sinkTotal = 500, runCount = 199 }, true)
		expect(decision.applied).never().toBeTruthy()
		expect(decision.reason).toEqual("sample too small (199 < 200)")
		-- Skipped means untouched, not just "multiplier unchanged" -- integral
		-- must not silently accumulate on a day that didn't count.
		expect(newState.multiplier).toEqual(1.1)
		expect(newState.integral).toEqual(0.5)
	end)

	t.it("the kill switch freezes the multiplier regardless of the ratio", function()
		local state = { multiplier = 1.1, integral = 0.5, clampedDays = 0 }
		local newState, decision =
			Controller.step(state, { faucetTotal = 1000, sinkTotal = 1, runCount = 5000 }, false)
		expect(decision.applied).never().toBeTruthy()
		expect(decision.reason).toEqual("autotune disabled")
		expect(newState.multiplier).toEqual(1.1)
		expect(newState.integral).toEqual(0.5)
	end)

	t.it("a single step never moves the multiplier by more than MAX_DAILY_DELTA, even under an extreme ratio", function()
		local state = Controller.new()
		local newState = Controller.step(state, { faucetTotal = 1000000, sinkTotal = 1, runCount = 1000 }, true)
		expect(math.abs(newState.multiplier - state.multiplier) <= Controller.MAX_DAILY_DELTA + 1e-9).toBeTruthy()
	end)

	t.it("clamps hold over 365 adversarial days: multiplier never leaves [MULT_MIN, MULT_MAX], never jumps more than the daily cap", function()
		local state = Controller.new()
		for day = 1, 365 do
			-- Alternate between a near-zero ratio (push the multiplier down)
			-- and a very high ratio (push it up) every day.
			local obs = if day % 2 == 0
				then { faucetTotal = 1000000, sinkTotal = 1, runCount = 1000 }
				else { faucetTotal = 1, sinkTotal = 1000000, runCount = 1000 }
			local newState = Controller.step(state, obs, true)
			expect(newState.multiplier >= Controller.MULT_MIN - 1e-9).toBeTruthy()
			expect(newState.multiplier <= Controller.MULT_MAX + 1e-9).toBeTruthy()
			expect(math.abs(newState.multiplier - state.multiplier) <= Controller.MAX_DAILY_DELTA + 1e-9).toBeTruthy()
			state = newState
		end
	end)
end)

t.describe("Controller.step -- convergence from a seeded imbalance", function()
	t.it(
		"multiplier drifted 30% high against a calibrated economy converges to the target ratio (0.85) by day 100 and holds",
		function()
			-- baseFaucetRate=1000 is calibrated so ratio=0.85 exactly at
			-- multiplier=1.0 with sink=850. Seed multiplier at 1.30 (30% high)
			-- and confirm the controller walks it back.
			local state = Controller.new()
			state = { multiplier = 1.30, integral = 0, clampedDays = 0 }
			local baseFaucetRate = 1000
			local sink = 850
			for day = 1, 100 do
				local faucetTotal = baseFaucetRate * state.multiplier
				state = Controller.step(state, { faucetTotal = faucetTotal, sinkTotal = sink, runCount = 300 }, true)
			end
			expect(state.multiplier).approx(1.0, 1e-4)
			local finalRatio = sink / (baseFaucetRate * state.multiplier)
			expect(finalRatio).approx(0.85, 1e-4)
		end
	)

	t.it(
		"real, measured: the same scenario does NOT settle into the +-0.05 target band before day 24 -- the 3%/day rate cap, not the PI gains, is the binding constraint (docs/07 exit target of <14 days is not met by these exact defaults)",
		function()
			local state = { multiplier = 1.30, integral = 0, clampedDays = 0 }
			local baseFaucetRate = 1000
			local sink = 850
			local lastOutsideBand = 0
			for day = 1, 30 do
				local faucetTotal = baseFaucetRate * state.multiplier
				local ratio = sink / faucetTotal
				if math.abs(ratio - Controller.TARGET_RATIO) > 0.05 then
					lastOutsideBand = day
				end
				state = Controller.step(state, { faucetTotal = faucetTotal, sinkTotal = sink, runCount = 300 }, true)
			end
			expect(lastOutsideBand).toEqual(23)
			expect(lastOutsideBand >= 14).toBeTruthy()
		end
	)

	t.it(
		"a faucet genuinely 30% too generous (not just multiplier-drifted) cannot be fully corrected within [MULT_MIN, MULT_MAX] -- the multiplier hits and holds the floor, and clampedDays crosses the 3-day alert threshold, exactly the guardrail docs/07 describes",
		function()
			local state = Controller.new()
			local baseFaucetRate = 1300 -- 30% above the 1000 that would be calibrated
			local sink = 850
			for day = 1, 30 do
				local faucetTotal = baseFaucetRate * state.multiplier
				state = Controller.step(state, { faucetTotal = faucetTotal, sinkTotal = sink, runCount = 300 }, true)
			end
			expect(state.multiplier).approx(Controller.MULT_MIN, 1e-9)
			expect(state.clampedDays).toEqual(24)
			expect(state.clampedDays >= 3).toBeTruthy()
		end
	)
end)
