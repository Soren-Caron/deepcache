--!strict
--[[ Pure data.

	This is the whitelist the director may choose from. The model picks an id
	and supplies params; it can never invent an objective, and every param is
	clamped to the range declared here. See docs/05.
]]

return {
	purge_node = {
		cooldownSeconds = 120, rewardCredits = 400,
		params = { count = { min = 1, max = 3, default = 1 } },
	},
	hold_terminal = {
		cooldownSeconds = 150, rewardCredits = 550,
		params = { durationS = { min = 30, max = 75, default = 45 } },
	},
	escort_cart = {
		cooldownSeconds = 240, rewardCredits = 1100,
		params = { distanceStuds = { min = 60, max = 200, default = 120 } },
	},
	no_loot_window = {
		cooldownSeconds = 180, rewardCredits = 0, rewardMultiplier = 1.35,
		params = { durationS = { min = 45, max = 120, default = 90 } },
	},
	hunt_warden = {
		cooldownSeconds = 300, rewardCredits = 900,
		params = { count = { min = 1, max = 2, default = 1 } },
	},
}
