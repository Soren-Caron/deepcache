--!strict
--[[ M4-1. Director response shape: enum guards, and sync against
	schema/director-decision.json -- the hand-maintained source both this
	module and backend/src/llm/schema.ts are written to match.
]]

local t = require("./framework")
local expect = t.expect

local fs = require("@lune/fs")
local serde = require("@lune/serde")

local Schema = require("../src/shared/core/director/Schema")

local canonical = serde.decode("json", fs.readFile("schema/director-decision.json"))

local function sameStringList(a: { string }, b: { any }): boolean
	if #a ~= #b then
		return false
	end
	for i, value in a do
		if value ~= b[i] then
			return false
		end
	end
	return true
end

t.describe("Schema: enum guards", function()
	t.it("isIntent accepts every declared intent and rejects garbage", function()
		for _, intent in Schema.INTENTS do
			expect(Schema.isIntent(intent)).toBeTruthy()
		end
		expect(Schema.isIntent("not_a_real_intent")).toBeFalsy()
		expect(Schema.isIntent(nil)).toBeFalsy()
		expect(Schema.isIntent(42)).toBeFalsy()
		expect(Schema.isIntent({})).toBeFalsy()
	end)

	t.it("isSpawnPattern accepts every declared pattern and rejects garbage", function()
		for _, pattern in Schema.SPAWN_PATTERNS do
			expect(Schema.isSpawnPattern(pattern)).toBeTruthy()
		end
		expect(Schema.isSpawnPattern("diagonal")).toBeFalsy()
		expect(Schema.isSpawnPattern(nil)).toBeFalsy()
	end)

	t.it("isObjectiveId accepts every declared id and rejects garbage", function()
		for _, id in Schema.OBJECTIVE_IDS do
			expect(Schema.isObjectiveId(id)).toBeTruthy()
		end
		expect(Schema.isObjectiveId("invent_an_objective")).toBeFalsy()
		expect(Schema.isObjectiveId(false)).toBeFalsy()
	end)
end)

t.describe("Schema: sync with schema/director-decision.json", function()
	t.it("intents match exactly, same order", function()
		expect(sameStringList(Schema.INTENTS, canonical.intents)).toBeTruthy()
	end)

	t.it("spawn patterns match exactly, same order", function()
		expect(sameStringList(Schema.SPAWN_PATTERNS, canonical.spawnPatterns)).toBeTruthy()
	end)

	t.it("objective ids match exactly, same order", function()
		expect(sameStringList(Schema.OBJECTIVE_IDS, canonical.objectiveIds)).toBeTruthy()
	end)

	t.it("bounds match field by field", function()
		local b = Schema.DEFAULT_BOUNDS
		local c = canonical.bounds
		expect(b.spawnMultiplierMin).toEqual(c.spawnMultiplierMin)
		expect(b.spawnMultiplierMax).toEqual(c.spawnMultiplierMax)
		expect(b.spawnMultiplierMaxDelta).toEqual(c.spawnMultiplierMaxDelta)
		expect(b.threatTierMin).toEqual(c.threatTierMin)
		expect(b.threatTierMax).toEqual(c.threatTierMax)
		expect(b.threatTierMaxDelta).toEqual(c.threatTierMaxDelta)
		expect(b.barkMaxChars).toEqual(c.barkMaxChars)
	end)
end)
