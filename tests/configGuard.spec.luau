--!strict
--[[ M6-6. core/economy/ConfigGuard -- the two accept criteria from BACKLOG
	M6-5/M6-6: "out-of-range config rejected wholesale; older version
	ignored", and "backend down at boot -> defaults used, no error".
]]

local t = require("./framework")
local expect = t.expect

local ConfigGuard = require("../src/shared/core/economy/ConfigGuard")
local EconomyConfig = require("../src/shared/config/Economy")

local function defaults(): ConfigGuard.EconomyPayload
	return { version = EconomyConfig.version, payoutMultiplier = EconomyConfig.payoutMultiplier }
end

t.describe("ConfigGuard version guard", function()
	t.it("the shipped defaults really are version 0, which the guard depends on", function()
		-- If config/Economy ever shipped a nonzero version, no remote config
		-- below it would ever be adopted and the whole fan-out would silently
		-- stop working. Pinned here rather than assumed.
		expect(EconomyConfig.version).toEqual(0)
	end)

	t.it("adopts a newer version", function()
		local verdict = ConfigGuard.evaluate({ version = 1, payoutMultiplier = 1.0 }, 0)
		expect(verdict.accept).toBeTruthy()
	end)

	t.it("ignores an older version", function()
		local verdict = ConfigGuard.evaluate({ version = 3, payoutMultiplier = 1.0 }, 9)
		expect(verdict.accept).never().toBeTruthy()
		expect(verdict.reason).toEqual("not_newer")
	end)

	t.it("ignores the same version -- equal is not newer", function()
		local verdict = ConfigGuard.evaluate({ version = 9, payoutMultiplier = 1.0 }, 9)
		expect(verdict.accept).never().toBeTruthy()
		expect(verdict.reason).toEqual("not_newer")
	end)

	t.it("a stale replica cannot walk a server backwards", function()
		-- The scenario the guard exists for: server adopts 9, then a lagging
		-- replica answers the next pull with 8.
		local config = defaults()
		config = (ConfigGuard.adopt(config, { version = 9, payoutMultiplier = 0.9 }))
		expect(config.version).toEqual(9)

		local after, verdict = ConfigGuard.adopt(config, { version = 8, payoutMultiplier = 1.2 })
		expect(verdict.accept).never().toBeTruthy()
		expect(after.version).toEqual(9)
		expect(after.payoutMultiplier).approx(0.9, 1e-9)
	end)
end)

t.describe("ConfigGuard range validation", function()
	t.it("accepts the exact clamp boundaries", function()
		expect(ConfigGuard.evaluate({ version = 1, payoutMultiplier = 0.80 }, 0).accept).toBeTruthy()
		expect(ConfigGuard.evaluate({ version = 1, payoutMultiplier = 1.25 }, 0).accept).toBeTruthy()
	end)

	t.it("rejects just outside the boundaries", function()
		local low = ConfigGuard.evaluate({ version = 1, payoutMultiplier = 0.79 }, 0)
		local high = ConfigGuard.evaluate({ version = 1, payoutMultiplier = 1.26 }, 0)
		expect(low.accept).never().toBeTruthy()
		expect(low.reason).toEqual("multiplier_out_of_range")
		expect(high.accept).never().toBeTruthy()
	end)

	t.it("rejects wholesale: a bad multiplier does not adopt the version either", function()
		-- The accept criterion's own word. Half-adopting would leave the
		-- server on a version number that does not describe its behaviour.
		local config = defaults()
		local after, verdict = ConfigGuard.adopt(config, { version = 42, payoutMultiplier = 9.9 })
		expect(verdict.accept).never().toBeTruthy()
		expect(after.version).toEqual(0)
		expect(after.payoutMultiplier).approx(1.0, 1e-9)
	end)
end)

t.describe("ConfigGuard never throws on hostile input", function()
	-- This runs on a network response. A config pull that can error is a
	-- config pull that can take a server down at boot.
	local cases: { { name: string, payload: any } } = {
		{ name = "nil", payload = nil },
		{ name = "a string", payload = "not a config" },
		{ name = "a number", payload = 42 },
		{ name = "an array", payload = { 1, 2, 3 } },
		{ name = "empty table", payload = {} },
		{ name = "missing multiplier", payload = { version = 5 } },
		{ name = "missing version", payload = { payoutMultiplier = 1.0 } },
		{ name = "string version", payload = { version = "5", payoutMultiplier = 1.0 } },
		{ name = "string multiplier", payload = { version = 5, payoutMultiplier = "1.0" } },
		{ name = "NaN multiplier", payload = { version = 5, payoutMultiplier = 0 / 0 } },
		{ name = "inf multiplier", payload = { version = 5, payoutMultiplier = math.huge } },
		{ name = "NaN version", payload = { version = 0 / 0, payoutMultiplier = 1.0 } },
		{ name = "fractional version", payload = { version = 1.5, payoutMultiplier = 1.0 } },
		{ name = "negative version", payload = { version = -1, payoutMultiplier = 1.0 } },
		{ name = "nested garbage", payload = { version = { {} }, payoutMultiplier = { {} } } },
	}

	for _, case in cases do
		t.it(`"{case.name}" is rejected without throwing, defaults preserved`, function()
			local config = defaults()
			local after, verdict
			local ok = pcall(function()
				after, verdict = ConfigGuard.adopt(config, case.payload)
			end)
			expect(ok).toBeTruthy()
			expect((verdict :: ConfigGuard.Verdict).accept).never().toBeTruthy()
			-- The whole point of M6-6: defaults survive intact.
			expect((after :: ConfigGuard.EconomyPayload).version).toEqual(0)
			expect((after :: ConfigGuard.EconomyPayload).payoutMultiplier).approx(1.0, 1e-9)
		end)
	end
end)

t.describe("ConfigGuard.adopt", function()
	t.it("returns a fresh table rather than mutating the previous config", function()
		-- A caller mid-run may still hold the old reference; a config that
		-- changes underneath a reader is a race nobody finds twice.
		local original = defaults()
		local adopted = (ConfigGuard.adopt(original, { version = 4, payoutMultiplier = 1.1 }))
		expect(adopted).never().toEqual(original)
		expect(original.version).toEqual(0)
		expect(original.payoutMultiplier).approx(1.0, 1e-9)
		expect(adopted.version).toEqual(4)
	end)

	t.it("a sequence of pulls only ever moves forward", function()
		local config = defaults()
		local offered = { 3, 1, 5, 5, 2, 8, 7 }
		for _, version in offered do
			config = (ConfigGuard.adopt(config, { version = version, payoutMultiplier = 1.0 }))
		end
		expect(config.version).toEqual(8)
	end)
end)
