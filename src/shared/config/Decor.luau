--!strict
--[[ Set dressing. Pure data, per CLAUDE.md -- no functions, no requires.

	Placement rules live in `core/level/Decor`; this is what the rules operate
	on and what the parts are made of.

	**Props are solid but transparent to raycasts.** `CanCollide = true` so a
	crate stops the player -- set dressing you walk through is worse than no
	set dressing, because it reads as a bug rather than as sparseness. But
	`CanQuery = false`, so nothing here changes combat: shots and enemy
	line-of-sight behave exactly as they did before the level had props in it.

	That split is deliberate and it is a compromise. Real cover is a better
	game, and this geometry is the obvious place to put it -- but turning props
	into cover moves damage numbers, invalidates the difficulty pass in
	docs/13, and is a design change wearing a set-dressing costume. Kept out of
	a "make it look better" pass on purpose; see docs/13 for the follow-up.
]]

local Decor = {}

--- Fed to `core/level/Decor`. See that module for what each rule protects.
Decor.placement = {
	--- How far from the inner wall face a prop may sit.
	bandWidth = 7,
	--- Clearance kept around every doorway centre.
	doorClearance = 16,
	studsPerProp = 200,
	maxProps = 16,
	studsPerLight = 1100,
	maxLights = 12,
	minDimension = 20,
}

export type PropKind = {
	size: { x: number, y: number, z: number },
	material: string,
	--- Tint applied to the zone's prop colour, 0 = zone colour, 1 = white.
	lighten: number,
}

local KINDS: { [string]: PropKind } = {
	crate = { size = { x = 4.5, y = 4.5, z = 4.5 }, material = "WoodPlanks", lighten = 0.10 },
	container = { size = { x = 9, y = 6, z = 5 }, material = "Metal", lighten = 0.00 },
	barrel = { size = { x = 3, y = 5, z = 3 }, material = "Metal", lighten = 0.18 },
	crateStack = { size = { x = 5, y = 8, z = 4.5 }, material = "WoodPlanks", lighten = 0.05 },
	console = { size = { x = 6, y = 3.5, z = 2.5 }, material = "DiamondPlate", lighten = 0.22 },
	pipeBundle = { size = { x = 2.5, y = 11, z = 2.5 }, material = "Metal", lighten = -0.10 },
}

Decor.kinds = KINDS

--- Which kinds appear in which zone. The progression is the run's arc: the
--- Perimeter is a loading area, Processing is machinery, the Vault is storage
--- nobody has opened in a while.
Decor.kindsByZone = {
	Perimeter = { "crate", "container", "crateStack", "console" },
	Processing = { "barrel", "pipeBundle", "console", "container" },
	Vault = { "container", "crateStack", "crate", "pipeBundle" },
}

--- Structure applied to every wall face.
Decor.structure = {
	--- Vertical pilasters no closer together than this.
	pilasterSpacing = 26,
	pilasterWidth = 3,
	pilasterDepth = 1.2,
	--- A band near the top of the wall, which is what stops a 24-stud wall
	--- reading as one flat slab.
	upperBandHeight = 1.6,
	--- Fraction of wall height the band sits at.
	upperBandAt = 0.78,
}

--- Ceilings and their fixtures.
Decor.ceiling = {
	thickness = 2,
	--- Fixture panel dimensions.
	fixtureWidth = 14,
	fixtureDepth = 3,
	fixtureThickness = 0.4,
	--- Real lights are expensive; the emissive panel carries most of the read
	--- and the PointLight does the rest. Shadows off: a shadow-casting light
	--- per fixture is the single fastest way to lose the frame budget.
	---
	--- **Range has to clear the room, not the fixture.** These are mounted at
	--- the 24-stud ceiling, so a range of 32 spends three quarters of itself
	--- getting to the floor and lands as a small pool directly underneath. A
	--- 112x96 Vault room lit by six of those rendered as pure black with six
	--- glowing panels floating in it -- the light was working exactly as
	--- configured and the configuration was measuring the wrong distance.
	---
	--- Brightness then has to come *down* to compensate, because range is set
	--- by the largest room and every fixture in a small one therefore covers
	--- all of it. Three overlapping range-60 lights in a 56x56 entrance hall
	--- at brightness 1.1 saturated every surface to white. Reach is a
	--- function of the room; intensity has to be a function of the overlap.
	lightRange = 60,
	lightBrightness = 0.5,
}

return Decor
