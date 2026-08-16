--!strict
--[[ M2-6. Carried weight, ground loot, and claim arbitration.

	Weight is the core tension of the design: what you carry slows you down and
	the extraction timer does not care. That makes the weight -> speed table a
	load-bearing piece of arithmetic rather than a cosmetic one, so it lives
	here where its boundaries can be tested exactly.

	Claiming is the other half. Two players reaching for the same item on the
	same tick must not both get it — duplicating loot is duplicating currency,
	and the ledger at M6 would have no way to tell. A claim removes the item
	from the store and returns it; the second caller gets a refusal, not a
	second copy.

	Pure: no Instances, no clock. The adapter owns Roblox parts and the
	character speed property.
]]

local Types = require("../Types")
local Rng = require("../util/Rng")

export type GroundItem = {
	uid: number,
	itemId: string,
	weight: number,
	value: number,
	at: Types.Vec3,
	--- Tick the item became available. Dropped loot is briefly unclaimable by
	--- the player who dropped it, or a fumbled keypress instantly re-picks it.
	availableAtTick: number,
	droppedBy: number?,
}

export type Store = {
	items: { [number]: GroundItem },
	nextUid: number,
}

--- `{ maxWeight, speedMultiplier }` pairs, ascending, last entry unbounded.
export type WeightTier = { number }

local Loot = {}

--- Ticks a dropped item stays unclaimable by the player who dropped it.
Loot.DROP_LOCKOUT_TICKS = 10

function Loot.newStore(): Store
	return { items = {}, nextUid = 1 }
end

--- Movement multiplier for a total carried weight.
---
--- Tier bounds are inclusive on `maxWeight`: the design table reads 0-20 at
--- 1.00 and 21-40 at 0.92, so exactly 20 is still unpenalised and anything
--- above it is not. Fractional weights land in the tier they fall inside, so
--- 20.5 is already penalised.
function Loot.speedMultiplier(totalWeight: number, tiers: { WeightTier }): number
	if #tiers == 0 then
		return 1
	end
	-- A negative or non-finite total is a bug upstream, but the movement system
	-- must still get a usable number rather than propagate a NaN into a
	-- character's WalkSpeed.
	local weight = if totalWeight == totalWeight and totalWeight ~= math.huge then math.max(0, totalWeight) else 0

	for _, tier in tiers do
		if weight <= tier[1] then
			return tier[2]
		end
	end
	return tiers[#tiers][2]
end

function Loot.totalWeight(carried: { GroundItem }): number
	local total = 0
	for _, item in carried do
		total += item.weight
	end
	return total
end

function Loot.totalValue(carried: { GroundItem }): number
	local total = 0
	for _, item in carried do
		total += item.value
	end
	return total
end

--- Put an item on the ground. `droppedBy` marks it as player-dropped, which
--- starts the re-pickup lockout.
function Loot.place(
	store: Store,
	itemId: string,
	weight: number,
	value: number,
	at: Types.Vec3,
	tick: number,
	droppedBy: number?
): GroundItem
	local item: GroundItem = {
		uid = store.nextUid,
		itemId = itemId,
		weight = weight,
		value = value,
		at = { x = at.x, y = at.y, z = at.z },
		availableAtTick = if droppedBy ~= nil then tick + Loot.DROP_LOCKOUT_TICKS else tick,
		droppedBy = droppedBy,
	}
	store.items[item.uid] = item
	store.nextUid += 1
	return item
end

--- Claim an item for a player. Success removes it from the store and hands it
--- back; there is no window in which two callers can both hold it.
---
--- Returns `(nil, reason)` on refusal rather than throwing: a player reaching
--- for loot another player just took is ordinary, not a programmer error.
function Loot.tryClaim(store: Store, uid: number, playerId: number, tick: number): (GroundItem?, string?)
	local item = store.items[uid]
	if item == nil then
		return nil, "gone"
	end
	if tick < item.availableAtTick then
		if item.droppedBy == playerId then
			return nil, "lockout"
		end
	end
	store.items[uid] = nil
	return item, nil
end

--- Items within `radius` of a point, nearest first. Deterministic ordering:
--- ties break by uid so two clients asked the same question agree.
function Loot.near(store: Store, at: Types.Vec3, radius: number): { GroundItem }
	local out: { GroundItem } = {}
	for _, item in store.items do
		if Types.distance(item.at, at) <= radius then
			table.insert(out, item)
		end
	end
	table.sort(out, function(a, b)
		local da, db = Types.distance(a.at, at), Types.distance(b.at, at)
		if math.abs(da - db) > 1e-9 then
			return da < db
		end
		return a.uid < b.uid
	end)
	return out
end

function Loot.count(store: Store): number
	local n = 0
	for _ in store.items do
		n += 1
	end
	return n
end

export type RarityDef = { valueMultiplier: number, weightPerZone: { [string]: number } }
export type ItemDef = { rarity: string, weight: number, baseValue: number }

--- Pick an item id for a zone: rarity first by its per-zone weight, then
--- uniformly among the items of that rarity.
---
--- Two stages rather than one weighted table over items so that adding an item
--- to a rarity does not silently make that rarity more common — the rarity
--- curve is the design knob, item count is content.
function Loot.rollItem(
	rng: Rng.Rng,
	zone: string,
	rarities: { [string]: RarityDef },
	items: { [string]: ItemDef }
): string?
	local names: { string } = {}
	for name in rarities do
		table.insert(names, name)
	end
	table.sort(names) -- determinism: pairs order is not stable across runtimes

	local total = 0
	for _, name in names do
		total += math.max(0, rarities[name].weightPerZone[zone] or 0)
	end
	if total <= 0 then
		return nil
	end

	local roll = Rng.nextNumber(rng) * total
	local chosenRarity = names[#names]
	local cumulative = 0
	for _, name in names do
		cumulative += math.max(0, rarities[name].weightPerZone[zone] or 0)
		if roll < cumulative then
			chosenRarity = name
			break
		end
	end

	local candidates: { string } = {}
	for id, def in items do
		if def.rarity == chosenRarity then
			table.insert(candidates, id)
		end
	end
	if #candidates == 0 then
		return nil
	end
	table.sort(candidates)
	return candidates[Rng.nextRange(rng, 1, #candidates)]
end

--- Value of one item, before the economy's payout multiplier.
function Loot.valueOf(itemId: string, rarities: { [string]: RarityDef }, items: { [string]: ItemDef }): number
	local def = items[itemId]
	if def == nil then
		return 0
	end
	local rarity = rarities[def.rarity]
	return def.baseValue * (if rarity then rarity.valueMultiplier else 1)
end

return Loot
