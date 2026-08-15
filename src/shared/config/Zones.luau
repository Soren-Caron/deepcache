--!strict
--[[ Pure data. Lighting presets drive the look pipeline — see docs/08. ]]

return {
	Perimeter = {
		depth = 1, budgetMultiplier = 1.0, lootMultiplier = 1.0, padOpensAt = 180,
		lighting = { tintR = 0.95, tintG = 0.98, tintB = 1.00, saturation = -0.10, contrast = 0.12, bloom = 0.6, fogEnd = 180 },
	},
	Processing = {
		depth = 2, budgetMultiplier = 1.5, lootMultiplier = 1.9, padOpensAt = 360,
		lighting = { tintR = 1.00, tintG = 0.92, tintB = 0.82, saturation = -0.25, contrast = 0.22, bloom = 1.1, fogEnd = 90 },
	},
	Vault = {
		depth = 3, budgetMultiplier = 2.2, lootMultiplier = 3.4, padOpensAt = 540,
		lighting = { tintR = 0.82, tintG = 0.86, tintB = 1.00, saturation = -0.40, contrast = 0.35, bloom = 1.8, fogEnd = 45 },
	},
}
