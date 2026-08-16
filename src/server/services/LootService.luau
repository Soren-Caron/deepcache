--!strict
--[[ M2-6. Ground loot, pickup, drop, and the weight that slows you down.

	The store, the claim rules and the weight -> speed table are pure
	(`core/sim/Loot`). This owns the Instances, the proximity prompts, and the
	one Roblox property that makes weight matter: `Humanoid.WalkSpeed`.

	**Never trust the client for loot.** A pickup request names a uid and
	nothing else; the server decides whether that uid still exists, whether the
	player is close enough to reach it, and whether anyone else got there first.
	The client's own idea of what it is carrying is display only.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")

local Loot = require(Shared.core.sim.Loot)
local Rng = require(Shared.core.util.Rng)
local Types = require(Shared.core.Types)
local LootConfig = require(Shared.config.Loot)
local EconomyConfig = require(Shared.config.Economy)
local ZonesConfig = require(Shared.config.Zones)
local Remotes = require(Shared.net.Remotes)

local LevelService = require("./LevelService")

local LootService = {}

local FOLDER_NAME = "GroundLoot"

--- How close a player must be to take something, in studs. Checked server-side
--- on every request: a ProximityPrompt is a client-side convenience, not a
--- security boundary, and a modified client can fire the remote from anywhere.
local REACH_STUDS = 14

--- Ground loot per spawn point, by zone depth. Deeper is denser as well as
--- more valuable.
local DENSITY_PER_ZONE: { [string]: number } = {
	Perimeter = 0.55,
	Processing = 0.7,
	Vault = 0.85,
}

local TIERS = EconomyConfig.weight.tiers :: { { number } }

local store = Loot.newStore()
local carried: { [number]: { Loot.GroundItem } } = {}
local instances: { [number]: BasePart } = {}
local root: Folder? = nil
local currentTick = 0

--- Set by Bootstrap so run state can veto pickups after a player is out.
local canCarry: ((playerId: number) -> boolean)? = nil

function LootService.setCarryPredicate(predicate: (playerId: number) -> boolean)
	canCarry = predicate
end

local function folder(): Folder
	if root and root.Parent then
		return root
	end
	local existing = Workspace:FindFirstChild(FOLDER_NAME)
	if existing then
		existing:Destroy()
	end
	local created = Instance.new("Folder")
	created.Name = FOLDER_NAME
	created.Parent = Workspace
	root = created
	return created
end

local RARITY_COLOR: { [string]: Color3 } = {
	common = Color3.fromRGB(190, 190, 190),
	uncommon = Color3.fromRGB(110, 200, 130),
	rare = Color3.fromRGB(90, 150, 235),
	prototype = Color3.fromRGB(230, 150, 60),
}

local function makeInstance(item: Loot.GroundItem)
	local def = (LootConfig.items :: any)[item.itemId]
	local part = Instance.new("Part")
	part.Name = item.itemId
	part.Size = Vector3.new(2.2, 2.2, 2.2)
	part.Position = Vector3.new(item.at.x, item.at.y + 1.6, item.at.z)
	part.Anchored = true
	part.CanCollide = false
	part.Material = Enum.Material.Neon
	part.Color = RARITY_COLOR[def and def.rarity or "common"] or RARITY_COLOR.common
	part:SetAttribute("uid", item.uid)
	part:SetAttribute("itemId", item.itemId)
	part:SetAttribute("weight", item.weight)
	part:SetAttribute("value", item.value)
	CollectionService:AddTag(part, "GroundLoot")

	local prompt = Instance.new("ProximityPrompt")
	prompt.ObjectText = item.itemId
	prompt.ActionText = `Take ({item.weight}kg)`
	prompt.MaxActivationDistance = REACH_STUDS - 2
	prompt.RequiresLineOfSight = false
	prompt.Parent = part

	prompt.Triggered:Connect(function(player: Player)
		LootService.tryPickup(player, item.uid)
	end)

	part.Parent = folder()
	instances[item.uid] = part
end

local function destroyInstance(uid: number)
	local part = instances[uid]
	if part then
		part:Destroy()
	end
	instances[uid] = nil
end

--------------------------------------------------------------------------------

local function totalWeight(playerId: number): number
	return Loot.totalWeight(carried[playerId] or {})
end

local function pushCarry(player: Player)
	local list = carried[player.UserId] or {}
	local weight = Loot.totalWeight(list)
	local multiplier = Loot.speedMultiplier(weight, TIERS)

	-- The one place weight becomes something the player can feel.
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = LootService.BASE_WALK_SPEED * multiplier
	end

	local manifest: { { itemId: string, uid: number, weight: number, value: number } } = {}
	for _, item in list do
		table.insert(manifest, { itemId = item.itemId, uid = item.uid, weight = item.weight, value = item.value })
	end

	Remotes.event("CarryUpdate"):FireClient(player, {
		items = manifest,
		weight = weight,
		value = Loot.totalValue(list),
		speedMultiplier = multiplier,
	})
end

LootService.BASE_WALK_SPEED = 16

--------------------------------------------------------------------------------

--- Scatter loot across the level. Deterministic for a seed, so a replayed run
--- has the same loot in the same places.
function LootService.populate(seed: number)
	LootService.clear()
	local rng = Rng.new(seed * 7919 + 13)

	for _, zone in { "Perimeter", "Processing", "Vault" } do
		local points = LevelService.spawnPointsFor(zone)
		local density = DENSITY_PER_ZONE[zone] or 0.5
		for _, point in points do
			if not Rng.chance(rng, density) then
				continue
			end
			local itemId = Loot.rollItem(rng, zone, LootConfig.rarities :: any, LootConfig.items :: any)
			if itemId == nil then
				continue
			end
			local def = (LootConfig.items :: any)[itemId]
			local value = Loot.valueOf(itemId, LootConfig.rarities :: any, LootConfig.items :: any)
			-- Zone loot multiplier is a payout knob, applied here so a Vault
			-- item is worth more than the same item found on the Perimeter.
			value *= ZonesConfig[zone].lootMultiplier

			local item = Loot.place(store, itemId, def.weight, math.floor(value), point, currentTick, nil)
			makeInstance(item)
		end
	end
end

function LootService.clear()
	for uid in instances do
		destroyInstance(uid)
	end
	instances = {}
	store = Loot.newStore()
	carried = {}
	if root then
		root:Destroy()
		root = nil
	end
end

function LootService.setTick(tick: number)
	currentTick = tick
end

--- Server-authoritative pickup. Every refusal reason is a rule the client
--- cannot talk its way past.
function LootService.tryPickup(player: Player, uid: unknown): (boolean, string?)
	if typeof(uid) ~= "number" or uid ~= uid then
		return false, "badRequest"
	end
	if canCarry ~= nil and not canCarry(player.UserId) then
		return false, "notActive"
	end

	local character = player.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if rootPart == nil or not rootPart:IsA("BasePart") then
		return false, "noCharacter"
	end

	-- Reach is checked against the item's recorded position, not against
	-- anything the client sent.
	local pending = store.items[uid :: number]
	if pending == nil then
		return false, "gone"
	end
	local distance = Types.distance(pending.at, {
		x = rootPart.Position.X,
		y = rootPart.Position.Y,
		z = rootPart.Position.Z,
	})
	if distance > REACH_STUDS then
		return false, "tooFar"
	end

	local item, reason = Loot.tryClaim(store, uid :: number, player.UserId, currentTick)
	if item == nil then
		return false, reason
	end

	destroyInstance(item.uid)
	local list = carried[player.UserId]
	if list == nil then
		list = {}
		carried[player.UserId] = list
	end
	table.insert(list, item)
	pushCarry(player)
	return true, nil
end

--- Drop one carried item at the player's feet.
function LootService.tryDrop(player: Player, uid: unknown): (boolean, string?)
	if typeof(uid) ~= "number" then
		return false, "badRequest"
	end
	local list = carried[player.UserId]
	if list == nil then
		return false, "carryingNothing"
	end

	local character = player.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if rootPart == nil or not rootPart:IsA("BasePart") then
		return false, "noCharacter"
	end

	for index, item in list do
		if item.uid == uid then
			table.remove(list, index)
			local at = {
				x = rootPart.Position.X + math.random(-3, 3),
				y = 0,
				z = rootPart.Position.Z + math.random(-3, 3),
			}
			-- A fresh uid: the old one may still be referenced by a client that
			-- has not seen the drop yet, and reusing it would let a stale
			-- request claim the new instance.
			local placed = Loot.place(store, item.itemId, item.weight, item.value, at, currentTick, player.UserId)
			makeInstance(placed)
			pushCarry(player)
			return true, nil
		end
	end
	return false, "notCarried"
end

--- Everything a player was carrying hits the floor. Called on death and when
--- the clock runs out — teammates can pick it up, which is the point.
function LootService.scatter(playerId: number, at: Types.Vec3): number
	local list = carried[playerId]
	if list == nil or #list == 0 then
		return 0
	end

	local dropped = 0
	for index, item in list do
		local angle = (index / #list) * math.pi * 2
		local placed = Loot.place(store, item.itemId, item.weight, item.value, {
			x = at.x + math.cos(angle) * 5,
			y = 0,
			z = at.z + math.sin(angle) * 5,
		}, currentTick, nil)
		makeInstance(placed)
		dropped += item.value
	end

	carried[playerId] = {}
	local player = Players:GetPlayerByUserId(playerId)
	if player then
		pushCarry(player)
	end
	return dropped
end

--- Banked on extraction: the carry is gone, but nothing hits the floor.
---
--- Distinct from `scatter`, which is the death path. Extraction that only
--- cleared the run's ledger left the items in this service, so an extracted
--- player kept the movement penalty, kept reporting 91 kg to the enemy budget,
--- and would have banked the same loot twice on a second pad.
function LootService.bank(playerId: number): number
	local list = carried[playerId]
	if list == nil or #list == 0 then
		return 0
	end
	local value = Loot.totalValue(list)
	carried[playerId] = {}

	local player = Players:GetPlayerByUserId(playerId)
	if player then
		pushCarry(player)
	end
	return value
end

function LootService.carriedWeight(playerId: number): number
	return totalWeight(playerId)
end

function LootService.carriedValue(playerId: number): number
	return Loot.totalValue(carried[playerId] or {})
end

function LootService.carriedCount(playerId: number): number
	return #(carried[playerId] or {})
end

function LootService.groundCount(): number
	return Loot.count(store)
end

--- Refresh a player's speed after a respawn, when the Humanoid is new.
function LootService.refresh(player: Player)
	pushCarry(player)
end

function LootService.init()
	Remotes.event("LootRequest").OnServerEvent:Connect(function(player: Player, action: unknown, uid: unknown)
		if action == "pickup" then
			LootService.tryPickup(player, uid)
		elseif action == "drop" then
			LootService.tryDrop(player, uid)
		end
	end)
end

function LootService.describe(): { [string]: any }
	local perZone: { [string]: number } = {}
	local totalValue = 0
	for _, item in store.items do
		totalValue += item.value
		local part = instances[item.uid]
		local zone = part and part:GetAttribute("zone")
		perZone[tostring(zone)] = (perZone[tostring(zone)] or 0) + 1
	end

	local carrying: { string } = {}
	for playerId, list in carried do
		local player = Players:GetPlayerByUserId(playerId)
		table.insert(carrying, string.format(
			"%s: %d items, %.0f kg, %d credits, speed x%.2f",
			player and player.Name or tostring(playerId),
			#list,
			Loot.totalWeight(list),
			Loot.totalValue(list),
			Loot.speedMultiplier(Loot.totalWeight(list), TIERS)
		))
	end

	return {
		onGround = Loot.count(store),
		groundValue = totalValue,
		carrying = carrying,
	}
end

return LootService
