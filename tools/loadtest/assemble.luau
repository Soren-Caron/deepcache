--!strict
--[[
	Level assembly benchmark and budget assertion.

		lune run tools/loadtest/assemble

	Runs in CI. The unit tests prove a layout is *valid*; this proves the
	generator is still *usable*: that it succeeds on every seed, fills the level
	to the size the design asked for rather than hugging the bottom of the
	tolerance window, and produces genuinely different levels from different
	seeds. A generator that returned the same minimal layout every time would
	pass every correctness test in the suite.

	Fails the build if any budget is missed.
]]

local process = require("@lune/process")
local stdio = require("@lune/stdio")

local Assemble = require("../../src/shared/core/level/Assemble")
local Rooms = require("../../src/shared/config/Rooms")

local CATALOGUE = Rooms.modules :: { Assemble.ModuleDef }
local TARGET = Rooms.targetArea

local SEEDS = 1000
local VARIETY_SEEDS = 200

--- Distinct layouts required over VARIETY_SEEDS. Well below the observed 190:
--- this is a "the seed still matters" guard, not a target to tune against.
local VARIETY_FLOOR = 150

--- The mean must sit near target, not merely inside the window. Accepting the
--- first count that qualifies produces levels ~13% smaller than asked for,
--- which is a silent 13% change to how long a run takes to cross.
local MEAN_ERROR_BUDGET = 0.06

local failures: { string } = {}
local areas: { number } = {}
local counts: { [number]: number } = {}

local t0 = os.clock()
for seed = 1, SEEDS do
	local ok, result = pcall(function()
		return Assemble.generate(seed, CATALOGUE, TARGET)
	end)
	if not ok then
		if #failures < 5 then
			table.insert(failures, `seed {seed}: {tostring(result)}`)
		end
	else
		local layout = result :: Assemble.Layout
		local valid, why = Assemble.validate(layout, TARGET)
		if not valid and #failures < 5 then
			table.insert(failures, `seed {seed} invalid: {tostring(why)}`)
		end
		table.insert(areas, layout.totalArea)
		local n = #layout.modules
		counts[n] = (counts[n] or 0) + 1
	end
end
local elapsed = os.clock() - t0

local seen: { [string]: boolean } = {}
local distinct = 0
for seed = 1, VARIETY_SEEDS do
	local layout = Assemble.generate(seed, CATALOGUE, TARGET)
	local parts: { string } = {}
	for _, m in layout.modules do
		table.insert(parts, `{m.id}@{m.at.x},{m.at.z}`)
	end
	local key = table.concat(parts, "|")
	if not seen[key] then
		seen[key] = true
		distinct += 1
	end
end

table.sort(areas)
local function pct(p: number): number
	return areas[math.max(1, math.ceil(#areas * p))]
end
local sum = 0
for _, a in areas do
	sum += a
end
local mean = sum / math.max(1, #areas)
local meanError = (mean - TARGET) / TARGET

stdio.write(`\nLevel assembly — {SEEDS} seeds, target {TARGET} studs^2\n\n`)
stdio.write(string.format("  generated        %d ok, %d failed  (%.2f ms/seed)\n", #areas, #failures, elapsed / SEEDS * 1000))
stdio.write(string.format(
	"  total area       min %.0f   p05 %.0f   mean %.0f   p95 %.0f   max %.0f\n",
	areas[1],
	pct(0.05),
	mean,
	pct(0.95),
	areas[#areas]
))
stdio.write(string.format(
	"  window           %.0f .. %.0f  (+/-%.0f%%)   mean is %+.1f%% off target\n",
	TARGET * (1 - Assemble.AREA_TOLERANCE),
	TARGET * (1 + Assemble.AREA_TOLERANCE),
	Assemble.AREA_TOLERANCE * 100,
	meanError * 100
))

local keys: { number } = {}
for k in counts do
	table.insert(keys, k)
end
table.sort(keys)
local parts: { string } = {}
for _, k in keys do
	table.insert(parts, `{k}:{counts[k]}`)
end
stdio.write(`  module counts    {table.concat(parts, "  ")}\n`)
stdio.write(`  distinct layouts {distinct} of {VARIETY_SEEDS} seeds\n`)

-- Cross-runtime fingerprint. A run is meant to be reproducible from its seed,
-- and the server assembles the level while tooling replays it under Lune — so
-- "deterministic" has to mean identical in Roblox too, not just identical
-- twice in the same interpreter. Printed rather than asserted because only a
-- Studio session can supply the other half of the comparison.
do
	local layout = Assemble.generate(42, CATALOGUE, TARGET)
	local ids: { string } = {}
	for _, m in layout.modules do
		table.insert(ids, `{m.id}@{m.at.x},{m.at.z},{m.rotation}`)
	end
	stdio.write(`\n  seed 42 fingerprint  {#layout.modules} modules, area {layout.totalArea}\n`)
	stdio.write(`  {table.concat(ids, " ")}\n\n`)
end

local problems: { string } = {}
for _, f in failures do
	table.insert(problems, f)
end
if distinct < VARIETY_FLOOR then
	table.insert(problems, `only {distinct} distinct layouts over {VARIETY_SEEDS} seeds, floor is {VARIETY_FLOOR}`)
end
if math.abs(meanError) > MEAN_ERROR_BUDGET then
	table.insert(
		problems,
		string.format(
			"mean area is %+.1f%% off target, budget is +/-%.0f%%",
			meanError * 100,
			MEAN_ERROR_BUDGET * 100
		)
	)
end

if #problems > 0 then
	stdio.write(stdio.color("red") .. `assembly budget FAILED ({#problems} problem(s))` .. stdio.color("reset") .. "\n")
	for _, p in problems do
		stdio.write(`  - {p}\n`)
	end
	stdio.write("\n")
	process.exit(1)
end

stdio.write(stdio.color("green") .. "assembly budgets met" .. stdio.color("reset") .. "\n")
process.exit(0)
