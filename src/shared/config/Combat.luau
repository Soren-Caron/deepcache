--!strict
--[[ Pure data. Melee spacing and crowd behaviour.

	Deliberately not a key inside `config/Enemies.luau`: several services
	iterate that table as `for kind, config in Enemies`, so a non-kind entry
	there would be read as an enemy called "PLAYER_RADIUS" and spawned.
]]

return {
	--- Effective radius of a player character, for personal-space purposes.
	--- Roblox's default rig is roughly 2 wide and 5 tall; this is the XZ
	--- footprint an enemy should refuse to stand inside.
	PLAYER_RADIUS = 2.5,

	--- Fraction of its normal speed an entity may use while attacking. Not
	--- zero: an attacking crowd still has to unstack itself, and a player who
	--- walks into a frozen huddle would otherwise stay interpenetrated with it
	--- indefinitely. Not one either — an attacker that repositions at full
	--- sprint reads as fleeing rather than as adjusting its footing.
	ATTACK_SHUFFLE_FRACTION = 0.35,
}
