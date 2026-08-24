--!strict
--[[ Pure data. Per-kind body plans for the client rig.

	The gait and IK have computed foot and joint positions every frame since
	M7-1/M7-2 and drove nothing, because every entity rendered as a single box.
	This is the geometry those solutions finally move.

	`legs` are rest offsets in entity-local space, XZ from the body centre and Y
	at the foot's resting height (negative, below the body). `group` alternates
	so opposing legs never lift together — `StepPlanner` enforces that, and the
	grouping here is what tells it which legs oppose which.

	**Proportions are deliberately stout.** The first pass used thin limbs on a
	wide splayed stance, which reads as an insect no matter what colour it is —
	long spindly legs reaching out well past the body is the arachnid
	silhouette, and players said so immediately. These are walking machines:
	legs are thick relative to the body, tucked close underneath it rather than
	splayed out from it, and short enough that the knee stays below the chassis.
	Leg count still differentiates the kinds, but nothing gets more than four,
	because six is spider-shaped however it is proportioned.
]]

return {
	Skitter = {
		bodySize = { x = 2.0, y = 1.1, z = 2.4 },
		bodyOffsetY = 0.3,
		upperLength = 0.7,
		lowerLength = 0.75,
		legThickness = 0.5,
		-- Diagonal pairs: the standard trot. Feet sit close under the hull.
		legs = {
			{ offset = { x = 0.6, y = -0.85, z = 0.65 }, group = 1 },
			{ offset = { x = -0.6, y = -0.85, z = 0.65 }, group = 2 },
			{ offset = { x = 0.6, y = -0.85, z = -0.65 }, group = 2 },
			{ offset = { x = -0.6, y = -0.85, z = -0.65 }, group = 1 },
		},
	},

	-- Area denial: a planted tripod. Never steps, so the legs are structure
	-- rather than locomotion — short, thick and braced.
	Sentry = {
		bodySize = { x = 2.2, y = 1.7, z = 2.2 },
		bodyOffsetY = 0.45,
		upperLength = 0.85,
		lowerLength = 0.9,
		legThickness = 0.62,
		legs = {
			{ offset = { x = 0, y = -1.2, z = 0.85 }, group = 1 },
			{ offset = { x = 0.75, y = -1.2, z = -0.6 }, group = 2 },
			{ offset = { x = -0.75, y = -1.2, z = -0.6 }, group = 1 },
		},
	},

	Hauler = {
		bodySize = { x = 3.6, y = 2.8, z = 4.2 },
		bodyOffsetY = 0.4,
		upperLength = 1.1,
		lowerLength = 1.15,
		legThickness = 1.15,
		legs = {
			{ offset = { x = 1.2, y = -1.8, z = 1.2 }, group = 1 },
			{ offset = { x = -1.2, y = -1.8, z = 1.2 }, group = 2 },
			{ offset = { x = 1.2, y = -1.8, z = -1.2 }, group = 2 },
			{ offset = { x = -1.2, y = -1.8, z = -1.2 }, group = 1 },
		},
	},

	-- A strider. Two legs, but thick ones — the height comes from the body
	-- riding high, not from stilts.
	Lancer = {
		bodySize = { x = 1.7, y = 2.0, z = 1.9 },
		bodyOffsetY = 0.55,
		upperLength = 0.95,
		lowerLength = 1.0,
		legThickness = 0.62,
		legs = {
			{ offset = { x = 0.5, y = -1.5, z = 0 }, group = 1 },
			{ offset = { x = -0.5, y = -1.5, z = 0 }, group = 2 },
		},
	},

	Warden = {
		bodySize = { x = 4.2, y = 3.6, z = 4.2 },
		bodyOffsetY = 0.5,
		upperLength = 1.3,
		lowerLength = 1.35,
		legThickness = 1.4,
		legs = {
			{ offset = { x = 1.45, y = -2.2, z = 1.45 }, group = 1 },
			{ offset = { x = -1.45, y = -2.2, z = 1.45 }, group = 2 },
			{ offset = { x = 1.45, y = -2.2, z = -1.45 }, group = 2 },
			{ offset = { x = -1.45, y = -2.2, z = -1.45 }, group = 1 },
		},
	},

	-- Was six legs, which read as a spider however it was coloured. Four
	-- heavy ones and a long low hull instead: it should look like something
	-- built to run you down, not something that lives in a drain.
	Reclaimer = {
		bodySize = { x = 2.8, y = 1.8, z = 3.8 },
		bodyOffsetY = 0.35,
		upperLength = 1.0,
		lowerLength = 1.05,
		legThickness = 0.85,
		legs = {
			{ offset = { x = 1.0, y = -1.5, z = 1.1 }, group = 1 },
			{ offset = { x = -1.0, y = -1.5, z = 1.1 }, group = 2 },
			{ offset = { x = 1.0, y = -1.5, z = -1.1 }, group = 2 },
			{ offset = { x = -1.0, y = -1.5, z = -1.1 }, group = 1 },
		},
	},
}
