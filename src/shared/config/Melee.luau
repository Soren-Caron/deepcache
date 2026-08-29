--!strict
--[[ The sweep. Pure data, per CLAUDE.md -- no functions, no requires.

	Every weapon in the roster is a ray, which leaves one hole in the fight: a
	Skitter swarm at four studs is a target you cannot miss and cannot clear,
	because one hitscan round kills one of them. This is the answer to being
	surrounded, so it is deliberately shaped as an escape rather than a
	damage-per-second upgrade.

	Balanced against the roster it exists to answer:

	  - `damage` kills a Skitter (45 hp) outright and takes a third off a
	    Lancer (90). It does not meaningfully dent a Warden (700) -- the sweep
	    buys you space, it does not win a fight with an elite.
	  - `radius` clears every melee attacker's own reach (Skitter 4, Hauler 6,
	    Reclaimer 6, Warden 8), so anything that has closed on you is inside
	    it. A shorter sweep would be a button you press and miss with.
	  - `cooldownSeconds` is long on purpose. At 55 damage across an arc, a
	    short cooldown would make it the best DPS in the game against crowds
	    and turn every fight into melee.
]]

local Melee = {}

--- Full width of the arc, in degrees. Wide enough to catch a crowd that has
--- surrounded you from the front, narrow enough that turning still matters.
Melee.arcDegrees = 120

--- Reach from the player to the near surface of a target's hitbox.
Melee.radius = 12

Melee.damage = 55

Melee.cooldownSeconds = 3.5

--- How long the swing animation and its arc effect last, client-side. Purely
--- cosmetic: the damage resolves the instant the server accepts the request,
--- because a windup on a panic button is a windup you die during.
Melee.swingSeconds = 0.28

--- Ceiling on targets damaged by one swing. Not a balance knob so much as a
--- blast radius on a bug: an arc that somehow matched fifty entities should
--- cost fifty times nothing, not fifty times a kill.
Melee.maxTargets = 12

return Melee
