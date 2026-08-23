--!strict
--[[ Pure data. Wave scheduling tunables — see docs/01-GAME-DESIGN.md §Scaling.

	docs/01 specifies the *budget formula* and is silent on cadence: how often
	the budget is re-spent, and what stops it spending forever. These are that
	missing half, recorded here rather than inlined so the pacing can be tuned
	without touching tested logic.
]]

return {
	--- Seconds between top-ups. The budget formula describes a *standing*
	--- pressure level, not a per-wave allowance, so a wave tops the live
	--- population back up toward it rather than adding to it.
	INTERVAL_SECONDS = 12,

	--- Longer than INTERVAL_SECONDS: dropping into a fight before the player
	--- has their bearings reads as unfair rather than tense.
	FIRST_WAVE_DELAY_SECONDS = 20,

	--- Hard ceiling on live entities, independent of budget.
	---
	--- **Must not exceed `Netcode.INTEREST_MAX`.** Replication sends a client at
	--- most that many entities, and `EntityRenderer` releases anything absent
	--- from a snapshot — so an entity over the cap is alive, pathing and
	--- attacking while never being drawn for anyone. At the previous value of
	--- 40 against an interest cap of 32, up to eight attackers were invisible,
	--- reported from a play session as taking damage from an enemy that was not
	--- there. A test asserts the two stay equal.
	MAX_ALIVE = 32,

	--- Don't spawn for less than a Lancer's worth. Without a floor, a single
	--- kill re-opens the budget and the next tick trickles one Skitter back in,
	--- which reads as enemies popping into existence rather than as a wave.
	MIN_WAVE_BUDGET = 3,
}
