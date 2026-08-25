--!strict
--[[ Pure data. Sprint and stamina tunables.

	`SPRINT_MULTIPLIER` multiplies whatever walk speed the weight system has
	already produced (`core/sim/Loot.speedMultiplier`), so sprinting while
	loaded is still slower than sprinting while empty — carrying has to keep
	costing something or the loot decision stops mattering.

	The movement guard has to know about this. `MovementGuard` budgets
	horizontal speed against a provider, and a sprint that the guard is not
	told about looks exactly like a speed hack: see
	`MovementGuardService.setSpeedProvider`.
]]

return {
	--- Applied on top of the weight multiplier, not instead of it.
	SPRINT_MULTIPLIER = 1.6,

	STAMINA_MAX = 100,
	--- Full bar to empty in 100 / 22 ≈ 4.5 seconds of continuous sprint.
	STAMINA_DRAIN_PER_SECOND = 22,
	--- Empty to full in about 7 seconds once regeneration starts.
	STAMINA_REGEN_PER_SECOND = 14,
	--- Pause before recovery begins, so disengaging costs something.
	STAMINA_REGEN_DELAY = 0.8,
	--- After exhausting the bar, sprinting is locked out until this fraction
	--- has recovered. Without a lockout, tapping sprint every frame averages
	--- well above walk speed forever.
	STAMINA_RECOVER_FRACTION = 0.35,
	--- Minimum stamina needed to begin a sprint.
	STAMINA_MIN_TO_START = 8,
}
