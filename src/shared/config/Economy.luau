--!strict
--[[ Pure data. These are the compiled-in defaults used when the backend is
	unreachable. The live values arrive from GET /v1/config. See docs/07. ]]

return {
	version = 0, -- local defaults are always version 0; remote config must exceed it

	payoutMultiplier = 1.0,

	controller = {
		targetRatio = 0.85,
		kp = 0.35,
		ki = 0.05,
		integralMax = 2.0,
		multiplierMin = 0.80,
		multiplierMax = 1.25,
		maxDailyDelta = 0.03,
		minRuns = 200,
		autotuneEnabled = true,
	},

	faucets = {
		extractBasePayout = 250,
		extractValueRate = 1.0,
		objectiveBonus = 400,
		dailyFirstExtract = 750,
	},

	sinks = {
		repairPerMinute = 40,
		ammoPerMagazine = 25,
		insurancePremiumRate = 0.18, -- fraction of declared carry value
		insuranceRecoveryRate = 0.40,
		marketFeeRate = 0.05,
	},

	market = {
		priceBand = 0.40,
		vwapWindowDays = 7,
		maxOpenOrdersPerItem = 5,
		dailyTradeVolumeCap = 25000,
		minRunsToSell = 5,
	},

	weight = {
		-- { maxWeight, speedMultiplier }; last entry is the floor
		tiers = { { 20, 1.00 }, { 40, 0.92 }, { 60, 0.82 }, { 80, 0.70 }, { math.huge, 0.55 } },
	},
}
