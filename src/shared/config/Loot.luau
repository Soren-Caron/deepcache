--!strict
--[[ Pure data. `weight` feeds the movement penalty; `baseValue` feeds payout. ]]

return {
	rarities = {
		common = { valueMultiplier = 1.0, weightPerZone = { Perimeter = 70, Processing = 45, Vault = 20 } },
		uncommon = { valueMultiplier = 2.4, weightPerZone = { Perimeter = 25, Processing = 38, Vault = 32 } },
		rare = { valueMultiplier = 6.0, weightPerZone = { Perimeter = 5, Processing = 15, Vault = 33 } },
		prototype = { valueMultiplier = 15.0, weightPerZone = { Perimeter = 0, Processing = 2, Vault = 15 } },
	},

	items = {
		scrap_bundle = { rarity = "common", weight = 6, baseValue = 40, tradeable = true },
		cell_pack = { rarity = "common", weight = 4, baseValue = 55, tradeable = true },
		optics_module = { rarity = "uncommon", weight = 9, baseValue = 180, tradeable = true },
		coolant_flask = { rarity = "uncommon", weight = 7, baseValue = 160, tradeable = true },
		servo_array = { rarity = "rare", weight = 16, baseValue = 620, tradeable = true },
		archive_core = { rarity = "rare", weight = 22, baseValue = 780, tradeable = true },
		overseer_shard = { rarity = "prototype", weight = 30, baseValue = 2400, tradeable = false },
	},
}
