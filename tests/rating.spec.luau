--!strict
--[[ M5-1. core/discovery/Rating -- hand-computed values, not re-derived
	from the module's own formulas, per this project's "never test a
	function against itself" convention (see hmac.spec.luau's rationale).
]]

local t = require("./framework")
local expect = t.expect

local Rating = require("../src/shared/core/discovery/Rating")

t.describe("Rating.new", function()
	t.it("starts at the standard Glicko values", function()
		local rating = Rating.new()
		expect(rating.r).toEqual(1500)
		expect(rating.rd).toEqual(350)
	end)
end)

t.describe("Rating.expectedPerformance", function()
	t.it("is exactly 0.5 at parity", function()
		expect(Rating.expectedPerformance(1500, 1500)).toEqual(0.5)
		expect(Rating.expectedPerformance(900, 900)).toEqual(0.5)
	end)

	t.it("matches the hand-computed logistic value at +-400 (a clean 1/11 fraction)", function()
		-- 1 / (1 + 10^(-400/400)) = 1 / 1.1 = 10/11
		expect(Rating.expectedPerformance(1900, 1500)).approx(10 / 11, 1e-9)
		-- 1 / (1 + 10^(400/400)) = 1 / 11
		expect(Rating.expectedPerformance(1100, 1500)).approx(1 / 11, 1e-9)
	end)

	t.it("is monotonic in the rating gap", function()
		local low = Rating.expectedPerformance(1000, 1500)
		local mid = Rating.expectedPerformance(1500, 1500)
		local high = Rating.expectedPerformance(2000, 1500)
		expect(low < mid).toBeTruthy()
		expect(mid < high).toBeTruthy()
	end)
end)

t.describe("Rating.actualPerformance", function()
	t.it("a perfect run scores exactly 1.0", function()
		local score = Rating.actualPerformance({
			extracted = true,
			valueRatio = 1,
			survived = true,
			objectiveRate = 1,
		})
		expect(score).approx(1.0, 1e-9)
	end)

	t.it("the worst run scores exactly 0", function()
		local score = Rating.actualPerformance({
			extracted = false,
			valueRatio = 0,
			survived = false,
			objectiveRate = 0,
		})
		expect(score).toEqual(0)
	end)

	t.it("a hand-computed mixed case: 0.4*1 + 0.2*0.5 + 0.2*1 + 0.2*0 = 0.7", function()
		local score = Rating.actualPerformance({
			extracted = true,
			valueRatio = 0.5,
			survived = true,
			objectiveRate = 0,
		})
		expect(score).approx(0.7, 1e-9)
	end)
end)

t.describe("Rating.kFactor", function()
	t.it("is K_MAX (150) at the initial rd", function()
		expect(Rating.kFactor(350)).approx(150, 1e-9)
	end)

	t.it("scales down linearly with rd -- hand-computed at rd=50: 150 * 50/350", function()
		expect(Rating.kFactor(50)).approx(150 * 50 / 350, 1e-9)
		expect(Rating.kFactor(50)).approx(21.428571, 1e-4)
	end)
end)

t.describe("Rating.shrinkRd / Rating.growRd", function()
	t.it("rd shrinks with play: 350 * 0.94 = 329 exactly", function()
		expect(Rating.shrinkRd(350)).approx(329, 1e-9)
	end)

	t.it("shrinking never goes below the floor (50)", function()
		expect(Rating.shrinkRd(51)).toEqual(50)
		expect(Rating.shrinkRd(50)).toEqual(50)
	end)

	t.it("rd grows with absence: 200 + 5*10 days = 250", function()
		expect(Rating.growRd(200, 10)).approx(250, 1e-9)
	end)

	t.it("growth never exceeds the initial ceiling (350)", function()
		expect(Rating.growRd(250, 50)).toEqual(350)
	end)

	t.it("negative days (clock skew) is treated as zero, not a shrink", function()
		expect(Rating.growRd(300, -5)).toEqual(300)
	end)
end)

t.describe("Rating.update", function()
	t.it("a hand-computed full update at a clean rating gap", function()
		-- r=1500, runDifficulty=1100 -> gap +400 -> expected = 10/11.
		-- Perfect performance (actual=1), fresh player (rd=350, no absence).
		-- k = 150. newR = 1500 + 150*(1 - 10/11) = 1500 + 150/11 = 1513.636364
		-- newRd = shrinkRd(350) = 329.
		local result = Rating.update(
			{ r = 1500, rd = 350 },
			1100,
			{ extracted = true, valueRatio = 1, survived = true, objectiveRate = 1 },
			0
		)
		expect(result.r).approx(1500 + 150 / 11, 1e-6)
		expect(result.r).approx(1513.636364, 1e-4)
		expect(result.rd).approx(329, 1e-9)
	end)

	t.it("a bad run against an easy difficulty moves rating down", function()
		-- Expected performance is high (favoured), actual is the worst
		-- possible (0) -- rating must drop.
		local before = { r = 1500, rd = 200 }
		local result = Rating.update(
			before,
			1100, -- easier than the player, so expected performance is high
			{ extracted = false, valueRatio = 0, survived = false, objectiveRate = 0 },
			0
		)
		expect(result.r < before.r).toBeTruthy()
	end)

	t.it("rd shrinks after playing, compounding with absence growth first", function()
		-- 60 days absent grows rd from 100 to 100+300=350 (capped), then
		-- shrinks to 350*0.94=329 after the run -- ends up LARGER than the
		-- pre-absence 100, not smaller, because absence dominated.
		local result = Rating.update(
			{ r = 1500, rd = 100 },
			1500,
			{ extracted = true, valueRatio = 0.5, survived = true, objectiveRate = 0.5 },
			60
		)
		expect(result.rd).approx(329, 1e-9)
		expect(result.rd > 100).toBeTruthy()
	end)

	t.it("with zero absence, rd strictly shrinks from its pre-run value", function()
		local before = { r = 1500, rd = 200 }
		local result = Rating.update(
			before,
			1500,
			{ extracted = true, valueRatio = 1, survived = true, objectiveRate = 1 },
			0
		)
		expect(result.rd < before.rd).toBeTruthy()
		expect(result.rd).approx(200 * 0.94, 1e-9)
	end)

	t.it("an established, uncertain-free player barely moves even on a perfect run", function()
		local before = { r = 1800, rd = 50 }
		local result = Rating.update(
			before,
			1500,
			{ extracted = true, valueRatio = 1, survived = true, objectiveRate = 1 },
			0
		)
		-- k at rd=50 is only ~21.4, so even a maximal (actual-expected) swing
		-- moves r by well under 25 points.
		expect(math.abs(result.r - before.r) < 25).toBeTruthy()
	end)
end)
