--!strict
--[[ M4-5. Clamp.apply is the entire safety boundary between the LLM and the
	game: it must be total (never throws) and always return a valid
	DirectorDecision. These tests are written against a hostile caller on
	purpose -- the input is exactly what an LLM response looks like when
	something has gone wrong.
]]

local t = require("./framework")
local expect = t.expect

local Clamp = require("../src/shared/core/director/Clamp")
local Schema = require("../src/shared/core/director/Schema")

local BOUNDS = Schema.DEFAULT_BOUNDS

local function baseline(): Schema.DirectorDecision
	return {
		intent = "hold_steady",
		spawnMultiplier = 1.0,
		spawnPattern = "even",
		objective = { id = "hold_terminal", params = { durationS = 45 } },
		threatTier = 3,
		bark = "Steady state.",
	}
end

--- A decision is only valid if every field is in-range and in-enum. This is
--- the property every malformed-input case has to satisfy, not just "didn't
--- throw" -- a function that returns garbage without throwing is still
--- broken.
local function assertValidDecision(d: Schema.DirectorDecision)
	expect(Schema.isIntent(d.intent)).toBeTruthy()
	expect(Schema.isSpawnPattern(d.spawnPattern)).toBeTruthy()
	expect(Schema.isObjectiveId(d.objective.id)).toBeTruthy()
	expect(type(d.objective.params)).toEqual("table")
	expect(d.spawnMultiplier >= BOUNDS.spawnMultiplierMin).toBeTruthy()
	expect(d.spawnMultiplier <= BOUNDS.spawnMultiplierMax).toBeTruthy()
	expect(d.threatTier >= BOUNDS.threatTierMin).toBeTruthy()
	expect(d.threatTier <= BOUNDS.threatTierMax).toBeTruthy()
	expect(math.floor(d.threatTier) == d.threatTier).toBeTruthy()
	expect(type(d.bark)).toEqual("string")
	expect(#d.bark <= BOUNDS.barkMaxChars).toBeTruthy()
end

t.describe("Clamp.apply: happy path", function()
	t.it("passes through a well-formed, in-range proposal close to unchanged", function()
		local d = Clamp.apply({
			intent = "punish_greed",
			spawnMultiplier = 1.1,
			spawnPattern = "flank",
			objective = { id = "no_loot_window", params = { durationS = 90 } },
			threatTier = 4,
			bark = "The heavy one. Second level.",
		}, baseline(), BOUNDS)

		assertValidDecision(d)
		expect(d.intent).toEqual("punish_greed")
		expect(d.spawnPattern).toEqual("flank")
		expect(d.objective.id).toEqual("no_loot_window")
		expect(d.objective.params.durationS).toEqual(90)
		expect(d.bark).toEqual("The heavy one. Second level.")
	end)
end)

t.describe("Clamp.apply: 20+ malformed inputs, all return a valid decision", function()
	local cases: { { name: string, proposal: any } } = {
		{ name = "nil", proposal = nil },
		{ name = "empty table", proposal = {} },
		{ name = "a string", proposal = "not a proposal" },
		{ name = "a number", proposal = 42 },
		{ name = "a boolean", proposal = true },
		{ name = "an array, not a map", proposal = { 1, 2, 3 } },
		{ name = "wrong-type intent", proposal = { intent = 5 } },
		{ name = "unknown intent enum value", proposal = { intent = "rampage" } },
		{ name = "wrong-type spawnMultiplier (string)", proposal = { spawnMultiplier = "1.5" } },
		{ name = "NaN spawnMultiplier", proposal = { spawnMultiplier = 0 / 0 } },
		{ name = "+inf spawnMultiplier", proposal = { spawnMultiplier = math.huge } },
		{ name = "-inf spawnMultiplier", proposal = { spawnMultiplier = -math.huge } },
		{ name = "wildly out-of-range spawnMultiplier", proposal = { spawnMultiplier = 999999 } },
		{ name = "negative spawnMultiplier", proposal = { spawnMultiplier = -50 } },
		{ name = "unknown spawnPattern enum value", proposal = { spawnPattern = "diagonal" } },
		{ name = "wrong-type spawnPattern", proposal = { spawnPattern = 7 } },
		{ name = "objective not a table", proposal = { objective = "hold_terminal" } },
		{ name = "objective missing id", proposal = { objective = { params = {} } } },
		{ name = "objective unknown id", proposal = { objective = { id = "invent_an_objective", params = {} } } },
		{ name = "objective params not a table", proposal = { objective = { id = "hold_terminal", params = "none" } } },
		{
			name = "objective params with unknown keys",
			proposal = { objective = { id = "hold_terminal", params = { durationS = 60, madeUpKey = 12345 } } },
		},
		{
			name = "objective params out of range",
			proposal = { objective = { id = "hold_terminal", params = { durationS = 999999 } } },
		},
		{
			name = "objective params wrong type",
			proposal = { objective = { id = "hold_terminal", params = { durationS = "sixty" } } },
		},
		{ name = "wrong-type threatTier (string)", proposal = { threatTier = "five" } },
		{ name = "threatTier way out of range", proposal = { threatTier = 500 } },
		{ name = "negative threatTier", proposal = { threatTier = -3 } },
		{ name = "NaN threatTier", proposal = { threatTier = 0 / 0 } },
		{ name = "fractional threatTier", proposal = { threatTier = 3.7 } },
		{ name = "wrong-type bark (number)", proposal = { bark = 12345 } },
		{ name = "wrong-type bark (table)", proposal = { bark = { "nested", "garbage" } } },
		{ name = "empty-string bark falls back to baseline", proposal = { bark = "" } },
		{
			name = "huge bark string, far past the char limit",
			proposal = { bark = string.rep("a", 10000) },
		},
		{
			name = "bark full of control characters",
			proposal = { bark = "\0\1\2\27[31mred\27[0m\7" },
		},
		{
			name = "every field simultaneously malformed",
			proposal = {
				intent = {},
				spawnMultiplier = "NaN",
				spawnPattern = 0 / 0,
				objective = 12345,
				threatTier = {},
				bark = false,
			},
		},
		{ name = "deeply nested garbage", proposal = { objective = { id = { { { "nested" } } } } } },
	}

	for _, case in cases do
		t.it(`"{case.name}" returns a valid decision without throwing`, function()
			local d = Clamp.apply(case.proposal, baseline(), BOUNDS)
			assertValidDecision(d)
		end)
	end

	t.it("covers at least 20 distinct malformed-input cases", function()
		expect(#cases >= 20).toBeTruthy()
	end)
end)

t.describe("Clamp.rateLimited", function()
	t.it("clamps to the absolute range when the delta window doesn't bind", function()
		-- A large maxDelta isolates the absolute-range clamp from the
		-- delta-from-previous clamp, which otherwise always applies too.
		expect(Clamp.rateLimited(999, 1.0, 0.6, 1.6, 100)).toEqual(1.6)
		expect(Clamp.rateLimited(-999, 1.0, 0.6, 1.6, 100)).toEqual(0.6)
	end)

	t.it("limits movement away from `previous` even when within absolute range", function()
		-- Requesting the max (1.6) from a previous value of 1.0 with maxDelta
		-- 0.25 should land at 1.25, not 1.6 -- the whole point of rate limiting.
		expect(Clamp.rateLimited(1.6, 1.0, 0.6, 1.6, 0.25)).toEqual(1.25)
		expect(Clamp.rateLimited(0.6, 1.0, 0.6, 1.6, 0.25)).toEqual(0.75)
	end)

	t.it("passes through a value already within both the range and the delta window", function()
		expect(Clamp.rateLimited(1.1, 1.0, 0.6, 1.6, 0.25)).toEqual(1.1)
	end)

	t.it("falls back to `previous` unchanged for non-finite input, since previous is already valid", function()
		expect(Clamp.rateLimited(0 / 0, 1.0, 0.6, 1.6, 0.25)).toEqual(1.0)
		expect(Clamp.rateLimited(math.huge, 1.0, 0.6, 1.6, 0.25)).toEqual(1.0)
		expect(Clamp.rateLimited(-math.huge, 1.0, 0.6, 1.6, 0.25)).toEqual(1.0)
	end)

	t.it("threatTier-shaped bounds: max +-1 change per tick", function()
		expect(Clamp.rateLimited(5, 3, 1, 5, 1)).toEqual(4)
		expect(Clamp.rateLimited(1, 3, 1, 5, 1)).toEqual(2)
	end)
end)

t.describe("Clamp.sanitizeBark", function()
	t.it("returns an empty string for non-string input", function()
		expect(Clamp.sanitizeBark(nil, 180)).toEqual("")
		expect(Clamp.sanitizeBark(42, 180)).toEqual("")
		expect(Clamp.sanitizeBark({}, 180)).toEqual("")
		expect(Clamp.sanitizeBark(true, 180)).toEqual("")
	end)

	t.it("strips control characters but keeps normal punctuation", function()
		local result = Clamp.sanitizeBark("Pressure's building.\7\0\27[31m", 180)
		expect(result).toEqual("Pressure's building.[31m")
	end)

	t.it("truncates to maxChars", function()
		local result = Clamp.sanitizeBark(string.rep("x", 500), 180)
		expect(#result).toEqual(180)
	end)

	t.it("leaves a short, clean string untouched", function()
		expect(Clamp.sanitizeBark("The heavy one.", 180)).toEqual("The heavy one.")
	end)
end)

t.describe("Clamp.apply: objective cooldown scope (docs/05 split)", function()
	t.it("keeps the baseline objective when the proposal's id is unknown, regardless of cooldown state", function()
		local d = Clamp.apply({ objective = { id = "not_real", params = {} } }, baseline(), BOUNDS)
		expect(d.objective.id).toEqual(baseline().objective.id)
	end)

	t.it("accepts any in-whitelist objective id -- cooldown enforcement is the caller's job (M4-8), not Clamp's", function()
		local d = Clamp.apply({ objective = { id = "hunt_warden", params = { count = 2 } } }, baseline(), BOUNDS)
		expect(d.objective.id).toEqual("hunt_warden")
	end)
end)
