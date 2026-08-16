--!strict
--[[ M2-6. Carried weight, ground loot, claim arbitration. ]]

local t = require("./framework")
local expect = t.expect

local Loot = require("../src/shared/core/sim/Loot")
local Rng = require("../src/shared/core/util/Rng")
local Economy = require("../src/shared/config/Economy")
local LootConfig = require("../src/shared/config/Loot")

local TIERS = Economy.weight.tiers :: { { number } }
local ORIGIN = { x = 0, y = 0, z = 0 }

local function place(store: Loot.Store, weight: number, at: { x: number, y: number, z: number }?): Loot.GroundItem
	return Loot.place(store, "scrap_bundle", weight, 40, at or ORIGIN, 0, nil)
end

--------------------------------------------------------------------------------

t.describe("Loot.speedMultiplier", function()
	t.it("matches the design table at every tier", function()
		-- docs/01 §Weight: 0-20 free, 21-40 noticeable, 41-60 committed,
		-- 61-80 in trouble, 81+ you should have left.
		expect(Loot.speedMultiplier(0, TIERS)).toEqual(1.00)
		expect(Loot.speedMultiplier(10, TIERS)).toEqual(1.00)
		expect(Loot.speedMultiplier(30, TIERS)).toEqual(0.92)
		expect(Loot.speedMultiplier(50, TIERS)).toEqual(0.82)
		expect(Loot.speedMultiplier(70, TIERS)).toEqual(0.70)
		expect(Loot.speedMultiplier(200, TIERS)).toEqual(0.55)
	end)

	t.it("treats tier bounds as inclusive, exactly", function()
		-- The boundary is the whole point: 20 is free and 21 is not.
		expect(Loot.speedMultiplier(20, TIERS)).toEqual(1.00)
		expect(Loot.speedMultiplier(21, TIERS)).toEqual(0.92)
		expect(Loot.speedMultiplier(40, TIERS)).toEqual(0.92)
		expect(Loot.speedMultiplier(41, TIERS)).toEqual(0.82)
		expect(Loot.speedMultiplier(60, TIERS)).toEqual(0.82)
		expect(Loot.speedMultiplier(61, TIERS)).toEqual(0.70)
		expect(Loot.speedMultiplier(80, TIERS)).toEqual(0.70)
		expect(Loot.speedMultiplier(81, TIERS)).toEqual(0.55)
	end)

	t.it("penalises a fractional weight past the boundary", function()
		expect(Loot.speedMultiplier(20.0001, TIERS)).toEqual(0.92)
		expect(Loot.speedMultiplier(19.9999, TIERS)).toEqual(1.00)
	end)

	t.it("never returns a non-finite or non-positive multiplier", function()
		for _, weight in { -1, -1e9, 0, 0 / 0, math.huge, 1e300 } do
			local value = Loot.speedMultiplier(weight, TIERS)
			expect(value == value).toBeTruthy()
			expect(value > 0).toBeTruthy()
			expect(value <= 1).toBeTruthy()
		end
	end)

	t.it("decreases monotonically as weight climbs", function()
		local previous = math.huge
		for weight = 0, 150 do
			local value = Loot.speedMultiplier(weight, TIERS)
			expect(value <= previous).toBeTruthy()
			previous = value
		end
	end)

	t.it("falls back to 1 with no tiers rather than erroring", function()
		expect(Loot.speedMultiplier(500, {})).toEqual(1)
	end)
end)

t.describe("Loot claim arbitration", function()
	t.it("gives an item to exactly one of many simultaneous claimants", function()
		-- The race the design cares about: a squad converging on one drop.
		-- Two winners is duplicated currency the M6 ledger cannot detect.
		local store = Loot.newStore()
		local item = place(store, 6)

		local winners = 0
		local refusals = 0
		for playerId = 1, 100 do
			local claimed, reason = Loot.tryClaim(store, item.uid, playerId, 0)
			if claimed ~= nil then
				winners += 1
			else
				refusals += 1
				expect(reason).toEqual("gone")
			end
		end
		expect(winners).toEqual(1)
		expect(refusals).toEqual(99)
		expect(Loot.count(store)).toEqual(0)
	end)

	t.it("hands the winner the item it asked for", function()
		local store = Loot.newStore()
		local a = Loot.place(store, "servo_array", 16, 620, ORIGIN, 0, nil)
		local b = Loot.place(store, "cell_pack", 4, 55, ORIGIN, 0, nil)

		local claimed = Loot.tryClaim(store, b.uid, 7, 0) :: Loot.GroundItem
		expect(claimed.itemId).toEqual("cell_pack")
		expect(claimed.uid).toEqual(b.uid)
		-- The other item is untouched.
		expect(Loot.count(store)).toEqual(1)
		expect(store.items[a.uid].itemId).toEqual("servo_array")
	end)

	t.it("refuses an unknown uid", function()
		local store = Loot.newStore()
		local claimed, reason = Loot.tryClaim(store, 9999, 1, 0)
		expect(claimed).toBeNil()
		expect(reason).toEqual("gone")
	end)

	t.it("stops the dropper instantly re-taking their own drop", function()
		local store = Loot.newStore()
		local dropped = Loot.place(store, "archive_core", 22, 780, ORIGIN, 100, 42)

		local claimed, reason = Loot.tryClaim(store, dropped.uid, 42, 100)
		expect(claimed).toBeNil()
		expect(reason).toEqual("lockout")

		-- A teammate can take it immediately: the lockout is about fumbled
		-- keypresses, not about reserving loot.
		expect(Loot.tryClaim(store, dropped.uid, 43, 100)).never().toBeNil()
	end)

	t.it("lets the dropper reclaim once the lockout expires", function()
		local store = Loot.newStore()
		local dropped = Loot.place(store, "archive_core", 22, 780, ORIGIN, 100, 42)
		local claimed = Loot.tryClaim(store, dropped.uid, 42, 100 + Loot.DROP_LOCKOUT_TICKS)
		expect(claimed).never().toBeNil()
	end)
end)

t.describe("Loot store queries", function()
	t.it("finds items within a radius, nearest first", function()
		local store = Loot.newStore()
		local far = place(store, 6, { x = 40, y = 0, z = 0 })
		local near = place(store, 6, { x = 5, y = 0, z = 0 })
		local outside = place(store, 6, { x = 500, y = 0, z = 0 })

		local found = Loot.near(store, ORIGIN, 50)
		expect(#found).toEqual(2)
		expect(found[1].uid).toEqual(near.uid)
		expect(found[2].uid).toEqual(far.uid)
		for _, item in found do
			expect(item.uid).never().toEqual(outside.uid)
		end
	end)

	t.it("orders ties by uid so every caller agrees", function()
		local store = Loot.newStore()
		local a = place(store, 6, { x = 10, y = 0, z = 0 })
		local b = place(store, 6, { x = -10, y = 0, z = 0 })
		local found = Loot.near(store, ORIGIN, 50)
		expect(found[1].uid).toEqual(math.min(a.uid, b.uid))
	end)

	t.it("sums carried weight and value", function()
		local store = Loot.newStore()
		local carried = {
			Loot.place(store, "scrap_bundle", 6, 40, ORIGIN, 0, nil),
			Loot.place(store, "servo_array", 16, 620, ORIGIN, 0, nil),
		}
		expect(Loot.totalWeight(carried)).toEqual(22)
		expect(Loot.totalValue(carried)).toEqual(660)
		expect(Loot.speedMultiplier(Loot.totalWeight(carried), TIERS)).toEqual(0.92)
	end)

	t.it("gives every placed item a distinct uid", function()
		local store = Loot.newStore()
		local seen: { [number]: boolean } = {}
		for _ = 1, 500 do
			local item = place(store, 1)
			expect(seen[item.uid]).toBeFalsy()
			seen[item.uid] = true
		end
		-- uids are not reused after a claim, or a stale client reference could
		-- pick up whatever landed in the same slot.
		local reclaimed = Loot.tryClaim(store, 1, 1, 0) :: Loot.GroundItem
		local fresh = place(store, 1)
		expect(fresh.uid).never().toEqual(reclaimed.uid)
	end)
end)

t.describe("Loot.rollItem", function()
	local rarities = LootConfig.rarities :: any
	local items = LootConfig.items :: any

	t.it("only rolls items that can appear in the zone", function()
		-- Prototype has weight 0 in the Perimeter, so overseer_shard must never
		-- drop there however many times we roll.
		local rng = Rng.new(1)
		for _ = 1, 3000 do
			local id = Loot.rollItem(rng, "Perimeter", rarities, items)
			expect(id).never().toEqual("overseer_shard")
		end
	end)

	t.it("follows the per-zone rarity curve", function()
		local counts: { [string]: number } = {}
		local rng = Rng.new(99)
		local rolls = 20000
		for _ = 1, rolls do
			local id = Loot.rollItem(rng, "Vault", rarities, items) :: string
			local rarity = items[id].rarity
			counts[rarity] = (counts[rarity] or 0) + 1
		end
		-- Vault weights: common 20, uncommon 32, rare 33, prototype 15 (sum 100).
		expect(counts.common / rolls).approx(0.20, 0.02)
		expect(counts.uncommon / rolls).approx(0.32, 0.02)
		expect(counts.rare / rolls).approx(0.33, 0.02)
		expect(counts.prototype / rolls).approx(0.15, 0.02)
	end)

	t.it("gets rarer as the squad goes deeper", function()
		local function prototypeRate(zone: string): number
			local rng = Rng.new(7)
			local hits = 0
			for _ = 1, 8000 do
				local id = Loot.rollItem(rng, zone, rarities, items)
				if id ~= nil and items[id].rarity == "prototype" then
					hits += 1
				end
			end
			return hits / 8000
		end
		expect(prototypeRate("Perimeter")).toEqual(0)
		expect(prototypeRate("Vault") > prototypeRate("Processing")).toBeTruthy()
	end)

	t.it("is deterministic for a fixed seed", function()
		local function sequence(): string
			local rng = Rng.new(31337)
			local parts: { string } = {}
			for _ = 1, 40 do
				table.insert(parts, Loot.rollItem(rng, "Processing", rarities, items) :: string)
			end
			return table.concat(parts, ",")
		end
		expect(sequence()).toEqual(sequence())
	end)

	t.it("returns nil rather than erroring when a zone can drop nothing", function()
		local empty = { common = { valueMultiplier = 1, weightPerZone = { Perimeter = 0 } } }
		expect(Loot.rollItem(Rng.new(1), "Perimeter", empty :: any, items)).toBeNil()
	end)

	t.it("values an item through its rarity multiplier", function()
		-- servo_array: 620 base, rare x6.0
		expect(Loot.valueOf("servo_array", rarities, items)).approx(3720, 1e-6)
		expect(Loot.valueOf("nonexistent", rarities, items)).toEqual(0)
	end)
end)
