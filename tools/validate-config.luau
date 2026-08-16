--!strict
--[[
	Config schema and range validation.

		lune run tools/validate-config

	Runs in CI and at server boot (via the adapter). Config is pure data, so
	nothing type-checks it at runtime — this does. A bad tunable should fail
	loudly here rather than produce a subtly wrong game three hours in.
]]

local process = require("@lune/process")
local stdio = require("@lune/stdio")

local Netcode = require("../src/shared/config/Netcode")
local Enemies = require("../src/shared/config/Enemies")
local Weapons = require("../src/shared/config/Weapons")
local Zones = require("../src/shared/config/Zones")
local Objectives = require("../src/shared/config/Objectives")
local Economy = require("../src/shared/config/Economy")
local Loot = require("../src/shared/config/Loot")
local Branding = require("../src/shared/config/Branding")
local Rooms = require("../src/shared/config/Rooms")

local problems: { string } = {}

local function fail(where: string, message: string)
	table.insert(problems, `{where}: {message}`)
end

local function requireNumber(where: string, value: any, min: number, max: number)
	if typeof(value) ~= "number" then
		fail(where, `expected number, got {typeof(value)}`)
		return
	end
	if value ~= value then
		fail(where, "is NaN")
		return
	end
	if value < min or value > max then
		fail(where, `{value} outside [{min}, {max}]`)
	end
end

local function requireString(where: string, value: any)
	if typeof(value) ~= "string" or #value == 0 then
		fail(where, `expected non-empty string, got {typeof(value)}`)
	end
end

local function requireOneOf(where: string, value: any, allowed: { string })
	for _, a in allowed do
		if value == a then
			return
		end
	end
	fail(where, `{tostring(value)} not in [{table.concat(allowed, ", ")}]`)
end

--------------------------------------------------------------------------------
-- Netcode
--------------------------------------------------------------------------------

requireNumber("Netcode.TICK_RATE", Netcode.TICK_RATE, 10, 60)
requireNumber("Netcode.SNAPSHOT_MAX_BYTES", Netcode.SNAPSHOT_MAX_BYTES, 1, 1000)
requireNumber("Netcode.INTEREST_MAX", Netcode.INTEREST_MAX, 1, 200)
requireNumber("Netcode.LAGCOMP_WINDOW", Netcode.LAGCOMP_WINDOW, 0.05, 0.5)
requireNumber("Netcode.EXTRAPOLATE_MAX", Netcode.EXTRAPOLATE_MAX, 0, 0.25)
requireNumber("Netcode.SPEED_MARGIN", Netcode.SPEED_MARGIN, 1.0, 2.0)

-- Cross-checks that a range test alone would not catch.
if Netcode.SNAPSHOT_MAX_BYTES > 1000 then
	fail("Netcode.SNAPSHOT_MAX_BYTES", "above the UnreliableRemoteEvent drop threshold (~1000 bytes)")
end
do
	local capacity = math.floor(
		(Netcode.SNAPSHOT_MAX_BYTES - Netcode.SNAPSHOT_HEADER_BYTES) / Netcode.SNAPSHOT_ENTITY_BYTES
	)
	if Netcode.INTEREST_MAX > capacity then
		fail("Netcode.INTEREST_MAX", `{Netcode.INTEREST_MAX} exceeds packet capacity of {capacity} entities`)
	end
end
-- The interest cap and the bandwidth budget must be mutually satisfiable.
-- They were not: 32 entities at 20Hz costs 6.97 KB/s worst case against a
-- 6 KB/s budget, which only showed up when a live session was measured.
do
	local perTick = Netcode.SNAPSHOT_HEADER_BYTES + Netcode.INTEREST_MAX * Netcode.SNAPSHOT_ENTITY_BYTES
	local worstKbps = perTick * Netcode.TICK_RATE / 1024
	if worstKbps > Netcode.BANDWIDTH_BUDGET_KBPS then
		fail(
			"Netcode.BANDWIDTH_BUDGET_KBPS",
			string.format(
				"%d entities at %dHz costs %.2f KB/s worst case, over the %.2f KB/s budget. "
					.. "Lower INTEREST_MAX to %d or raise the budget.",
				Netcode.INTEREST_MAX,
				Netcode.TICK_RATE,
				worstKbps,
				Netcode.BANDWIDTH_BUDGET_KBPS,
				math.floor((Netcode.BANDWIDTH_BUDGET_KBPS * 1024 / Netcode.TICK_RATE - Netcode.SNAPSHOT_HEADER_BYTES) / Netcode.SNAPSHOT_ENTITY_BYTES)
			)
		)
	end
end
if Netcode.RENDER_DELAY_MIN > Netcode.RENDER_DELAY_MAX then
	fail("Netcode.RENDER_DELAY_MIN", "greater than RENDER_DELAY_MAX")
end
if Netcode.HISTORY_TICKS / Netcode.TICK_RATE < Netcode.LAGCOMP_WINDOW then
	fail("Netcode.HISTORY_TICKS", "history buffer is shorter than the lag-compensation window")
end
if Netcode.VIOLATION_CORRECT_AT >= Netcode.VIOLATION_KICK_AT then
	fail("Netcode.VIOLATION_CORRECT_AT", "must be below VIOLATION_KICK_AT")
end

--------------------------------------------------------------------------------
-- Enemies
--------------------------------------------------------------------------------

local VALID_ZONES = { "Perimeter", "Processing", "Vault" }
local enemyCount = 0

for name, e in Enemies do
	enemyCount += 1
	local w = `Enemies.{name}`
	requireNumber(`{w}.hp`, e.hp, 1, 100000)
	requireNumber(`{w}.speed`, e.speed, 0, 100)
	requireNumber(`{w}.dmg`, e.dmg, 0, 1000)
	requireNumber(`{w}.atkRange`, e.atkRange, 0, 500)
	requireNumber(`{w}.budget`, e.budget, 1, 100)
	requireNumber(`{w}.hitboxRadius`, e.hitboxRadius, 0.1, 20)
	requireNumber(`{w}.capPerWave`, e.capPerWave, 1, 200)
	requireString(`{w}.behavior`, e.behavior)

	if typeof(e.zones) ~= "table" or #e.zones == 0 then
		fail(`{w}.zones`, "must list at least one zone")
	else
		for _, z in e.zones do
			requireOneOf(`{w}.zones`, z, VALID_ZONES)
		end
	end

	-- A static enemy that is expected to chase would never reach anything.
	if e.behavior ~= "Static" and e.speed == 0 then
		fail(`{w}.speed`, `is 0 but behavior is "{e.behavior}" (only "Static" may be immobile)`)
	end
end

if enemyCount == 0 then
	fail("Enemies", "catalogue is empty")
end

--------------------------------------------------------------------------------
-- Weapons
--------------------------------------------------------------------------------

for name, wep in Weapons do
	local w = `Weapons.{name}`
	requireOneOf(`{w}.kind`, wep.kind, { "hitscan", "projectile", "beam" })
	requireNumber(`{w}.range`, wep.range, 1, 1000)
	requireNumber(`{w}.magazine`, wep.magazine, 1, 1000)
	requireNumber(`{w}.reloadSeconds`, wep.reloadSeconds, 0.1, 20)
	requireNumber(`{w}.weight`, wep.weight, 0, 100)
	requireNumber(`{w}.falloffStart`, wep.falloffStart, 0, 1000)
	requireNumber(`{w}.falloffEnd`, wep.falloffEnd, 0, 1000)
	requireNumber(`{w}.minMultiplier`, wep.minMultiplier, 0, 1)

	if wep.falloffStart > wep.falloffEnd then
		fail(`{w}.falloffStart`, "greater than falloffEnd")
	end
	if wep.kind == "beam" then
		requireNumber(`{w}.damagePerSecond`, wep.damagePerSecond, 1, 10000)
	else
		requireNumber(`{w}.damage`, wep.damage, 1, 10000)
		requireNumber(`{w}.rps`, wep.rps, 0.05, 60)
	end
	if wep.kind == "projectile" then
		requireNumber(`{w}.projectileSpeed`, wep.projectileSpeed, 10, 2000)
	end
end

--------------------------------------------------------------------------------
-- Zones
--------------------------------------------------------------------------------

local seenDepths: { [number]: string } = {}
for name, z in Zones do
	local w = `Zones.{name}`
	requireOneOf(w, name, VALID_ZONES)
	requireNumber(`{w}.depth`, z.depth, 1, 10)
	requireNumber(`{w}.budgetMultiplier`, z.budgetMultiplier, 0.1, 10)
	requireNumber(`{w}.lootMultiplier`, z.lootMultiplier, 0.1, 20)
	requireNumber(`{w}.padOpensAt`, z.padOpensAt, 0, Branding.runLengthSeconds)

	if seenDepths[z.depth] then
		fail(`{w}.depth`, `duplicate depth {z.depth}, also used by {seenDepths[z.depth]}`)
	end
	seenDepths[z.depth] = name

	local L = z.lighting
	for _, key in { "tintR", "tintG", "tintB" } do
		requireNumber(`{w}.lighting.{key}`, L[key], 0, 1)
	end
	requireNumber(`{w}.lighting.saturation`, L.saturation, -1, 1)
	requireNumber(`{w}.lighting.contrast`, L.contrast, -1, 1)
	requireNumber(`{w}.lighting.bloom`, L.bloom, 0, 10)
	requireNumber(`{w}.lighting.fogEnd`, L.fogEnd, 10, 5000)
end

--------------------------------------------------------------------------------
-- Objectives — the director whitelist
--------------------------------------------------------------------------------

for name, o in Objectives do
	local w = `Objectives.{name}`
	requireNumber(`{w}.cooldownSeconds`, o.cooldownSeconds, 0, 600)
	requireNumber(`{w}.rewardCredits`, o.rewardCredits, 0, 100000)

	if typeof(o.params) ~= "table" then
		fail(`{w}.params`, "missing")
	else
		for pname, p in o.params do
			local pw = `{w}.params.{pname}`
			requireNumber(`{pw}.min`, p.min, 0, 100000)
			requireNumber(`{pw}.max`, p.max, 0, 100000)
			requireNumber(`{pw}.default`, p.default, 0, 100000)
			if p.min > p.max then
				fail(pw, "min greater than max")
			end
			if p.default < p.min or p.default > p.max then
				fail(pw, `default {p.default} outside [{p.min}, {p.max}]`)
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Economy
--------------------------------------------------------------------------------

do
	local c = Economy.controller
	requireNumber("Economy.controller.targetRatio", c.targetRatio, 0.1, 1.5)
	requireNumber("Economy.controller.kp", c.kp, 0, 5)
	requireNumber("Economy.controller.ki", c.ki, 0, 5)
	requireNumber("Economy.controller.multiplierMin", c.multiplierMin, 0.1, 2)
	requireNumber("Economy.controller.multiplierMax", c.multiplierMax, 0.1, 5)
	requireNumber("Economy.controller.maxDailyDelta", c.maxDailyDelta, 0.001, 0.5)
	requireNumber("Economy.controller.minRuns", c.minRuns, 1, 100000)

	if c.multiplierMin >= c.multiplierMax then
		fail("Economy.controller.multiplierMin", "must be below multiplierMax")
	end
	requireNumber("Economy.payoutMultiplier", Economy.payoutMultiplier, c.multiplierMin, c.multiplierMax)

	requireNumber("Economy.sinks.marketFeeRate", Economy.sinks.marketFeeRate, 0, 0.5)
	requireNumber("Economy.sinks.insuranceRecoveryRate", Economy.sinks.insuranceRecoveryRate, 0, 1)
	requireNumber("Economy.market.priceBand", Economy.market.priceBand, 0.05, 1)

	-- Insurance must not be a money printer: paying the premium and dying
	-- should never be worth more than the premium cost.
	if Economy.sinks.insuranceRecoveryRate > 1 - Economy.sinks.insurancePremiumRate then
		fail(
			"Economy.sinks.insuranceRecoveryRate",
			"recovery exceeds 1 - premium; insurance would be a faucet, not a sink"
		)
	end

	local tiers = Economy.weight.tiers
	local prevWeight, prevSpeed = -1, math.huge
	for i, tier in tiers do
		local maxWeight, speed = tier[1], tier[2]
		if maxWeight <= prevWeight then
			fail(`Economy.weight.tiers[{i}]`, "thresholds must strictly increase")
		end
		if speed > prevSpeed then
			fail(`Economy.weight.tiers[{i}]`, "speed multiplier must not increase with weight")
		end
		requireNumber(`Economy.weight.tiers[{i}].speed`, speed, 0.1, 1.0)
		prevWeight, prevSpeed = maxWeight, speed
	end
	if tiers[#tiers][1] ~= math.huge then
		fail("Economy.weight.tiers", "final tier must be unbounded (math.huge) or heavy loads are unhandled")
	end
end

--------------------------------------------------------------------------------
-- Loot
--------------------------------------------------------------------------------

for name, item in Loot.items do
	local w = `Loot.items.{name}`
	requireNumber(`{w}.weight`, item.weight, 0, 200)
	requireNumber(`{w}.baseValue`, item.baseValue, 1, 1000000)
	if Loot.rarities[item.rarity] == nil then
		fail(`{w}.rarity`, `unknown rarity "{tostring(item.rarity)}"`)
	end
	if typeof(item.tradeable) ~= "boolean" then
		fail(`{w}.tradeable`, "must be a boolean")
	end
end

for rname, r in Loot.rarities do
	requireNumber(`Loot.rarities.{rname}.valueMultiplier`, r.valueMultiplier, 0.1, 100)
	for _, z in VALID_ZONES do
		requireNumber(`Loot.rarities.{rname}.weightPerZone.{z}`, r.weightPerZone[z], 0, 1000)
	end
end

for _, z in VALID_ZONES do
	local total = 0
	for _, r in Loot.rarities do
		total += r.weightPerZone[z] or 0
	end
	if total <= 0 then
		fail(`Loot.rarities.weightPerZone.{z}`, "all rarity weights are zero; nothing can drop in this zone")
	end
end

--------------------------------------------------------------------------------
-- Rooms — the module catalogue Assemble walks
--------------------------------------------------------------------------------

do
	local VALID_FACES = { "N", "S", "E", "W" }
	local VALID_SIZES = { "small", "large" }

	requireNumber("Rooms.targetArea", Rooms.targetArea, 1000, 1000000)
	requireNumber("Rooms.connectorWidths.small", Rooms.connectorWidths.small, 1, 100)
	requireNumber("Rooms.connectorWidths.large", Rooms.connectorWidths.large, 1, 100)
	if Rooms.connectorWidths.small >= Rooms.connectorWidths.large then
		fail("Rooms.connectorWidths", "small must be narrower than large")
	end

	local seenIds: { [string]: boolean } = {}
	local perZone: { [string]: number } = {}
	local padsPerZone: { [string]: number } = {}
	local minArea, maxArea = math.huge, 0

	for i, m in Rooms.modules do
		local w = `Rooms.modules[{i}]`
		requireString(`{w}.id`, m.id)
		if typeof(m.id) == "string" then
			if seenIds[m.id] then
				fail(`{w}.id`, `duplicate module id "{m.id}"`)
			end
			seenIds[m.id] = true
			w = `Rooms.{m.id}`
		end

		requireNumber(`{w}.width`, m.width, 1, 1000)
		requireNumber(`{w}.depth`, m.depth, 1, 1000)
		if typeof(m.hasPad) ~= "boolean" then
			fail(`{w}.hasPad`, "must be a boolean")
		end

		-- Studio geometry is authored on a 4-stud grid; an off-grid module
		-- lines up in the layout maths and visibly does not in the level.
		if m.width % 4 ~= 0 or m.depth % 4 ~= 0 then
			fail(`{w}`, `extents {m.width}x{m.depth} are not multiples of 4 studs`)
		end

		local area = m.width * m.depth
		minArea = math.min(minArea, area)
		maxArea = math.max(maxArea, area)

		-- 2-4 tagged connectors, at most one per face. Assemble identifies a
		-- module's mating door by face alone, so two on one face would be
		-- ambiguous rather than merely unusual.
		if typeof(m.connectors) ~= "table" then
			fail(`{w}.connectors`, "missing")
		else
			local n = #m.connectors
			if n < 2 or n > 4 then
				fail(`{w}.connectors`, `{n} connectors, expected 2 to 4`)
			end
			local seenFaces: { [string]: boolean } = {}
			for j, c in m.connectors do
				requireOneOf(`{w}.connectors[{j}].face`, c.face, VALID_FACES)
				requireOneOf(`{w}.connectors[{j}].size`, c.size, VALID_SIZES)
				if seenFaces[c.face] then
					fail(`{w}.connectors`, `two connectors on face {c.face}`)
				end
				seenFaces[c.face] = true
			end
		end

		if typeof(m.zones) ~= "table" or #m.zones == 0 then
			fail(`{w}.zones`, "must list at least one zone")
		else
			for _, z in m.zones do
				requireOneOf(`{w}.zones`, z, VALID_ZONES)
				perZone[z] = (perZone[z] or 0) + 1
				if m.hasPad then
					padsPerZone[z] = (padsPerZone[z] or 0) + 1
				end
			end
		end
	end

	if #Rooms.modules == 0 then
		fail("Rooms.modules", "catalogue is empty")
	end

	for _, z in VALID_ZONES do
		-- One pad room per zone: the three extraction pads are one per depth
		-- band, and Assemble places exactly one from each.
		if (padsPerZone[z] or 0) ~= 1 then
			fail(`Rooms.modules`, `zone {z} has {padsPerZone[z] or 0} pad module(s), expected exactly 1`)
		end
		-- Fewer than three and consecutive placements in that band cannot
		-- differ, which deadlocks the no-repeat-within-2-hops rule.
		if (perZone[z] or 0) < 3 then
			fail(`Rooms.modules`, `zone {z} has {perZone[z] or 0} module(s), at least 3 are needed`)
		end
	end

	-- The area target has to be reachable at some legal module count, or every
	-- seed fails at runtime rather than here.
	if #Rooms.modules > 0 then
		local minTotal = 12 -- SPINE_MIN + BRANCH_MIN
		local maxTotal = 18 -- SPINE_MAX + BRANCH_MAX
		local floorArea = minTotal * minArea
		local ceilArea = maxTotal * maxArea
		if Rooms.targetArea < floorArea or Rooms.targetArea > ceilArea then
			fail(
				"Rooms.targetArea",
				string.format(
					"%.0f is outside what %d-%d modules can cover (%.0f to %.0f)",
					Rooms.targetArea,
					minTotal,
					maxTotal,
					floorArea,
					ceilArea
				)
			)
		end
	end
end

--------------------------------------------------------------------------------
-- Branding
--------------------------------------------------------------------------------

requireString("Branding.gameName", Branding.gameName)
requireString("Branding.directorName", Branding.directorName)
requireNumber("Branding.runLengthSeconds", Branding.runLengthSeconds, 60, 3600)
requireNumber("Branding.squadSizeDefault", Branding.squadSizeDefault, 1, 8)
requireNumber("Branding.squadSizeMax", Branding.squadSizeMax, 1, 8)
if Branding.squadSizeDefault > Branding.squadSizeMax then
	fail("Branding.squadSizeDefault", "greater than squadSizeMax")
end

--------------------------------------------------------------------------------

if #problems > 0 then
	stdio.write(stdio.color("red") .. `config validation FAILED ({#problems} problem(s))` .. stdio.color("reset") .. "\n")
	for _, p in problems do
		stdio.write(`  - {p}\n`)
	end
	stdio.write("\n")
	process.exit(1)
end

stdio.write(stdio.color("green") .. "config validation passed" .. stdio.color("reset") .. "\n")
process.exit(0)
