--!strict
--[[ Pure data. Per-kind body plans for the client rig.

	The gait and IK have computed foot and joint positions every frame since
	M7-1/M7-2 and drove nothing, because every entity rendered as a single box.
	This is the geometry those solutions finally move.

	`legs` are rest offsets in entity-local space, XZ from the body centre and Y
	at the foot's resting height (negative, below the body). `group` alternates
	so opposing legs never lift together — `StepPlanner` enforces that, and the
	grouping here is what tells it which legs oppose which.

	Leg counts are the silhouette: a two-legged Lancer striding, a six-legged
	Reclaimer scuttling, and a three-legged Sentry that is planted and never
	steps at all read differently at distance even before colour lands.
]]

return {
	Skitter = {
		bodySize = { x = 1.7, y = 1.0, z = 2.2 },
		bodyOffsetY = 0.35,
		upperLength = 0.95,
		lowerLength = 1.15,
		legThickness = 0.22,
		-- Diagonal pairs: the standard trot.
		legs = {
			{ offset = { x = 0.85, y = -1.05, z = 0.8 }, group = 1 },
			{ offset = { x = -0.85, y = -1.05, z = 0.8 }, group = 2 },
			{ offset = { x = 0.85, y = -1.05, z = -0.8 }, group = 2 },
			{ offset = { x = -0.85, y = -1.05, z = -0.8 }, group = 1 },
		},
	},

	-- Area denial: a planted tripod. Never steps, so the legs are structure
	-- rather than locomotion, and the body sits high on them.
	Sentry = {
		bodySize = { x = 2.0, y = 1.6, z = 2.0 },
		bodyOffsetY = 0.55,
		upperLength = 1.3,
		lowerLength = 1.5,
		legThickness = 0.34,
		legs = {
			{ offset = { x = 0, y = -1.5, z = 1.3 }, group = 1 },
			{ offset = { x = 1.15, y = -1.5, z = -0.9 }, group = 2 },
			{ offset = { x = -1.15, y = -1.5, z = -0.9 }, group = 1 },
		},
	},

	Hauler = {
		bodySize = { x = 3.4, y = 2.6, z = 4.0 },
		bodyOffsetY = 0.5,
		upperLength = 1.7,
		lowerLength = 1.9,
		legThickness = 0.62,
		legs = {
			{ offset = { x = 1.7, y = -2.2, z = 1.5 }, group = 1 },
			{ offset = { x = -1.7, y = -2.2, z = 1.5 }, group = 2 },
			{ offset = { x = 1.7, y = -2.2, z = -1.5 }, group = 2 },
			{ offset = { x = -1.7, y = -2.2, z = -1.5 }, group = 1 },
		},
	},

	-- A strider. Two long legs, high body, holds standoff and shoots.
	Lancer = {
		bodySize = { x = 1.4, y = 1.8, z = 1.6 },
		bodyOffsetY = 0.7,
		upperLength = 1.5,
		lowerLength = 1.7,
		legThickness = 0.26,
		legs = {
			{ offset = { x = 0.7, y = -1.9, z = 0 }, group = 1 },
			{ offset = { x = -0.7, y = -1.9, z = 0 }, group = 2 },
		},
	},

	Warden = {
		bodySize = { x = 4.0, y = 3.4, z = 4.0 },
		bodyOffsetY = 0.6,
		upperLength = 2.1,
		lowerLength = 2.3,
		legThickness = 0.8,
		legs = {
			{ offset = { x = 2.1, y = -2.8, z = 1.8 }, group = 1 },
			{ offset = { x = -2.1, y = -2.8, z = 1.8 }, group = 2 },
			{ offset = { x = 2.1, y = -2.8, z = -1.8 }, group = 2 },
			{ offset = { x = -2.1, y = -2.8, z = -1.8 }, group = 1 },
		},
	},

	-- Six legs, low and wide. Hunts the heaviest carrier, and should read as
	-- something you do not want to see coming.
	Reclaimer = {
		bodySize = { x = 2.6, y = 1.6, z = 3.4 },
		bodyOffsetY = 0.4,
		upperLength = 1.5,
		lowerLength = 1.7,
		legThickness = 0.34,
		legs = {
			{ offset = { x = 1.5, y = -1.8, z = 1.4 }, group = 1 },
			{ offset = { x = -1.5, y = -1.8, z = 1.4 }, group = 2 },
			{ offset = { x = 1.7, y = -1.8, z = 0 }, group = 2 },
			{ offset = { x = -1.7, y = -1.8, z = 0 }, group = 1 },
			{ offset = { x = 1.5, y = -1.8, z = -1.4 }, group = 1 },
			{ offset = { x = -1.5, y = -1.8, z = -1.4 }, group = 2 },
		},
	},
}
