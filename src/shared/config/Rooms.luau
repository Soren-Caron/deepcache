--!strict
--[[ Pure data. The room module catalogue consumed by core/level/Assemble.

	Each module is a sealed axis-aligned box with 2-4 tagged connectors, at most
	one per face. A connector sits at the midpoint of its face, which is what
	makes placement arithmetic exact: two modules joined on matching faces have
	coincident doorways by construction, with no per-module offset table to keep
	in sync. Studio geometry (M2-2) must honour that — the doorway is centred on
	the face or the synced level will not line up with the layout the server
	computed.

	`small` connectors are 8 studs wide, `large` are 16. A connector only mates
	with one of the same size.

	Area is derived as width * depth, never authored, so the two cannot drift.
]]

return {
	--- Total floor area an assembled level aims for, in square studs.
	--- Assemble steers module choice toward this and validates within +/-15%.
	targetArea = 68000,

	--- Doorway widths in studs, for the Studio geometry pass.
	connectorWidths = { small = 8, large = 16 },

	modules = {
		-- Connective tissue. Available in every zone, which is what gives each
		-- band enough distinct modules to satisfy the no-repeat-within-2-hops
		-- rule without authoring four dedicated rooms per zone.
		{
			id = "Corridor_Straight",
			zones = { "Perimeter", "Processing", "Vault" },
			width = 16, depth = 64, hasPad = false,
			connectors = { { face = "N", size = "large" }, { face = "S", size = "large" } },
		},
		{
			id = "Corridor_Bend",
			zones = { "Perimeter", "Processing", "Vault" },
			width = 40, depth = 40, hasPad = false,
			connectors = { { face = "N", size = "large" }, { face = "E", size = "large" } },
		},
		{
			id = "Junction_T",
			zones = { "Perimeter", "Processing", "Vault" },
			width = 48, depth = 48, hasPad = false,
			connectors = {
				{ face = "N", size = "large" },
				{ face = "E", size = "small" },
				{ face = "W", size = "small" },
			},
		},
		{
			id = "Junction_Cross",
			zones = { "Perimeter", "Processing", "Vault" },
			width = 56, depth = 56, hasPad = false,
			connectors = {
				{ face = "N", size = "large" },
				{ face = "S", size = "large" },
				{ face = "E", size = "large" },
				{ face = "W", size = "large" },
			},
		},

		-- Perimeter: open, bright, cheap loot. The 3:00 pad lives in the Dock.
		{
			id = "Perimeter_Dock",
			zones = { "Perimeter" },
			width = 80, depth = 64, hasPad = true,
			connectors = {
				{ face = "N", size = "large" },
				{ face = "S", size = "large" },
				{ face = "E", size = "small" },
			},
		},
		{
			id = "Perimeter_Yard",
			zones = { "Perimeter" },
			width = 96, depth = 80, hasPad = false,
			connectors = {
				{ face = "N", size = "large" },
				{ face = "S", size = "large" },
				{ face = "W", size = "large" },
			},
		},
		{
			id = "Perimeter_Locker",
			zones = { "Perimeter" },
			width = 40, depth = 32, hasPad = false,
			connectors = { { face = "N", size = "small" }, { face = "E", size = "small" } },
		},

		-- Processing: tight sightlines, Hauler and Lancer country. 6:00 pad.
		{
			id = "Processing_Vats",
			zones = { "Processing" },
			width = 96, depth = 96, hasPad = false,
			connectors = {
				{ face = "N", size = "large" },
				{ face = "S", size = "large" },
				{ face = "E", size = "small" },
				{ face = "W", size = "small" },
			},
		},
		{
			id = "Processing_Catwalk",
			zones = { "Processing" },
			width = 112, depth = 48, hasPad = true,
			connectors = { { face = "N", size = "large" }, { face = "S", size = "large" } },
		},
		{
			id = "Processing_Sorting",
			zones = { "Processing" },
			width = 64, depth = 64, hasPad = false,
			connectors = {
				{ face = "N", size = "small" },
				{ face = "S", size = "small" },
				{ face = "E", size = "large" },
			},
		},

		-- Vault: the deep band. 9:00 pad, best loot, Wardens.
		{
			id = "Vault_Core",
			zones = { "Vault" },
			width = 112, depth = 96, hasPad = true,
			connectors = {
				{ face = "N", size = "large" },
				{ face = "S", size = "large" },
				{ face = "W", size = "large" },
			},
		},
		{
			id = "Vault_Archive",
			zones = { "Vault" },
			width = 72, depth = 56, hasPad = false,
			connectors = {
				{ face = "N", size = "small" },
				{ face = "S", size = "large" },
				{ face = "E", size = "small" },
			},
		},
	},
}
