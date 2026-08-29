--!strict
--[[ The loading screen. Pure data, per CLAUDE.md -- no functions, no requires.

	`steps` is ordered, and the order is the order the gates actually open in:
	the engine loads, the server hands us a level, the geometry streams, the
	character spawns, the client's own controllers come up. The label shown is
	the first one still shut, so a player stuck on a slow connection sees which
	part is slow rather than a bar that stopped.

	`weight` is roughly how long each takes, measured loosely rather than
	precisely -- its only job is stopping the bar from moving in five equal
	jumps when one step is most of the wait. Geometry dominates because the
	level is built server-side in one pass and parented to Workspace whole.
]]

local Boot = {}

local STEPS: { { id: string, label: string, weight: number } } = {
	{ id = "engine", label = "LINKING TO OVERSEER", weight = 1 },
	{ id = "world", label = "GENERATING FACILITY", weight = 3 },
	{ id = "assets", label = "STREAMING GEOMETRY", weight = 3 },
	{ id = "avatar", label = "DEPLOYING OPERATIVE", weight = 1 },
	{ id = "systems", label = "ARMING SYSTEMS", weight = 1 },
}

Boot.steps = STEPS

Boot.readyLabel = "READY"

--- Minimum time on screen. Long enough that a warm client does not get a
--- single-frame flash, short enough not to be a tax on every join.
Boot.minSeconds = 0.7

--- Hard ceiling. If a gate is broken the player gets the game anyway, and the
--- adapter warns -- a loading screen that never leaves is worse than the black
--- room it exists to hide.
Boot.timeoutSeconds = 25

--- Fade out. Covers the first rendered frame, which is often still settling.
Boot.fadeSeconds = 0.45

--- How hard the bar chases its target. Higher is snappier; at 6 a jump is
--- mostly covered inside a third of a second.
Boot.barRate = 6

return Boot
