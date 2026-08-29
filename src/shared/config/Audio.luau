--!strict
--[[ Sound cues. Pure data, per CLAUDE.md -- no functions, no requires.

	**Every `assetId` here is empty, and that is deliberate.** The audio layer
	is built and wired; the sounds are not chosen. Searching the Creator Store
	for free weapon audio returns user uploads with no usable provenance --
	the top results included one explicitly described as ripped from The Elder
	Scrolls IV: Oblivion. Shipping those into a portfolio project trades a
	silent game for a copyright problem, which is a worse trade than it looks.

	Filling these in is the whole remaining task. `AudioController` reads this
	table and needs no other change: a cue with an empty `assetId` is skipped
	and counted, so the `audioInfo` diagnostic reports exactly which cues are
	still silent rather than failing quietly.

	Picking them:
	  - Roblox's own first-party audio, or a licensed pack (Freesound CC0,
	    Kenney, ZapSplat) uploaded to the account that owns the place.
	  - Audio uploaded by another user cannot be used unless it is marked
	    reusable; check the asset's permissions, not just its price.
	  - Keep one-shots under ~2 seconds. `minInterval` below assumes short
	    sounds and will let a long one overlap itself.

	`minInterval` is the throttle from `core/audio/Cues`: the shortest gap
	between two plays of the same cue. Set it just under the fastest legitimate
	rate -- the Carbine fires at 9 rps, so its cue sits at 0.09s, while a hit
	confirmation from a swarm is capped far harder because forty of them in a
	tick is noise, not information.
]]

export type Cue = {
	assetId: string,
	volume: number,
	--- Pitch jitter as a fraction: 0.06 is +/-6%.
	jitter: number,
	--- Shortest gap between two plays, in seconds.
	minInterval: number,
	--- Positional cues attach to an emitter; flat ones play on the listener.
	positional: boolean,
	rollOffMaxDistance: number,
}

local CUES: { [string]: Cue } = {
	-- Weapons. One cue per weapon rather than one shared: a Slug and a Sidearm
	-- sounding identical is the fastest way to make four weapons feel like one.
	weaponFireSidearm = { assetId = "", volume = 0.5, jitter = 0.06, minInterval = 0.09, positional = false, rollOffMaxDistance = 120 },
	weaponFireCarbine = { assetId = "", volume = 0.45, jitter = 0.07, minInterval = 0.07, positional = false, rollOffMaxDistance = 120 },
	weaponFireSlug = { assetId = "", volume = 0.7, jitter = 0.05, minInterval = 0.4, positional = false, rollOffMaxDistance = 160 },
	weaponFireArc = { assetId = "", volume = 0.35, jitter = 0.03, minInterval = 0.25, positional = false, rollOffMaxDistance = 120 },

	weaponReloadStart = { assetId = "", volume = 0.45, jitter = 0.02, minInterval = 0.3, positional = false, rollOffMaxDistance = 40 },
	weaponReloadDone = { assetId = "", volume = 0.45, jitter = 0.02, minInterval = 0.3, positional = false, rollOffMaxDistance = 40 },
	weaponDryFire = { assetId = "", volume = 0.4, jitter = 0.04, minInterval = 0.35, positional = false, rollOffMaxDistance = 40 },

	-- Feedback. The hit confirmation is throttled hard: it carries "that
	-- landed", and it carries that just as well once per 80ms as forty times.
	hitConfirm = { assetId = "", volume = 0.35, jitter = 0.08, minInterval = 0.08, positional = false, rollOffMaxDistance = 30 },
	hitTaken = { assetId = "", volume = 0.6, jitter = 0.05, minInterval = 0.15, positional = false, rollOffMaxDistance = 30 },

	-- The world. Enemy fire and deaths are positional -- they are the cues
	-- that tell a player where something is, so playing them flat would throw
	-- away the information the damage indicator exists to supply.
	enemyShot = { assetId = "", volume = 0.5, jitter = 0.08, minInterval = 0.05, positional = true, rollOffMaxDistance = 140 },
	enemyDeath = { assetId = "", volume = 0.55, jitter = 0.10, minInterval = 0.06, positional = true, rollOffMaxDistance = 100 },

	meleeSwing = { assetId = "", volume = 0.5, jitter = 0.06, minInterval = 0.2, positional = true, rollOffMaxDistance = 70 },
	lootPickup = { assetId = "", volume = 0.4, jitter = 0.05, minInterval = 0.1, positional = false, rollOffMaxDistance = 30 },
	padOpen = { assetId = "", volume = 0.6, jitter = 0, minInterval = 1.0, positional = false, rollOffMaxDistance = 200 },
	runEnd = { assetId = "", volume = 0.6, jitter = 0, minInterval = 2.0, positional = false, rollOffMaxDistance = 200 },
}

local Audio = {}

Audio.CUES = CUES

--- Global scale applied on top of every cue's own volume, so the mix can be
--- pulled down in one place without touching fifteen numbers.
Audio.MASTER_VOLUME = 0.8

--- Ceiling on Sound instances alive at once. Roblox will start far more than
--- this and simply sound worse for it.
Audio.MAX_CONCURRENT = 24

return Audio
