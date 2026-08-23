--!strict
--[[ Pure data. Lighting presets drive the look pipeline — see docs/08.

	`palette` is the built geometry: surfaces and trim, as distinct from
	`lighting`, which is the post-processing stack over the top. The two are
	deliberately separate — lighting blends over 1.5 s at a zone transition
	while the geometry is baked at assembly time and never moves.

	The progression is the run's arc: Perimeter is cold, open and legible;
	Processing is warm, sodium-lit and industrial; the Vault is dark, blue and
	close. Trim is emissive and carries most of the read at distance, because
	the fog in the Vault eats surface colour long before it eats a light strip.
]]

return {
	Perimeter = {
		depth = 1, budgetMultiplier = 1.0, lootMultiplier = 1.0, padOpensAt = 180,
		lighting = { tintR = 0.95, tintG = 0.98, tintB = 1.00, saturation = -0.10, contrast = 0.12, bloom = 0.6, fogEnd = 180 },
		palette = {
			floor = { r = 96, g = 104, b = 116 },
			wall = { r = 122, g = 130, b = 141 },
			trim = { r = 90, g = 200, b = 220 },
			floorMaterial = "Concrete",
			wallMaterial = "Concrete",
		},
	},
	Processing = {
		depth = 2, budgetMultiplier = 1.5, lootMultiplier = 1.9, padOpensAt = 360,
		lighting = { tintR = 1.00, tintG = 0.92, tintB = 0.82, saturation = -0.25, contrast = 0.22, bloom = 1.1, fogEnd = 90 },
		palette = {
			floor = { r = 92, g = 78, b = 62 },
			wall = { r = 118, g = 96, b = 72 },
			trim = { r = 255, g = 170, b = 60 },
			floorMaterial = "DiamondPlate",
			wallMaterial = "CorrodedMetal",
		},
	},
	Vault = {
		depth = 3, budgetMultiplier = 2.2, lootMultiplier = 3.4, padOpensAt = 540,
		lighting = { tintR = 0.82, tintG = 0.86, tintB = 1.00, saturation = -0.40, contrast = 0.35, bloom = 1.8, fogEnd = 45 },
		palette = {
			floor = { r = 38, g = 42, b = 58 },
			wall = { r = 52, g = 56, b = 76 },
			trim = { r = 150, g = 110, b = 235 },
			floorMaterial = "Slate",
			wallMaterial = "Slate",
		},
	},
}
