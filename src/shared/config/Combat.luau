--!strict
--[[ Pure data. Melee spacing and crowd behaviour.

	Deliberately not a key inside `config/Enemies.luau`: several services
	iterate that table as `for kind, config in Enemies`, so a non-kind entry
	there would be read as an enemy called "PLAYER_RADIUS" and spawned.
]]

return {
	--- The player's health pool.
	---
	--- Roblox's Humanoid default is 100, which is what this was for every
	--- milestone up to now -- not by decision, just by never being set. 150
	--- against a roster that hits for 8 (Skitter) to 30 (Hauler) turns a bad
	--- room from fatal into expensive, which is the same thing field repair
	--- was added for and works with it rather than instead of it.
	---
	--- Applied to the Humanoid on spawn; nothing else in the game reads a
	--- hardcoded 100, and the survivability guards in
	--- `tests/enemyAttack.spec.luau` read this so the two cannot drift.
	PLAYER_MAX_HEALTH = 150,

	--- Fraction of a zone's visible distance that an enemy may attack from.
	---
	--- Enemy reach is capped at `fogEnd * this`. The Vault's fog ends at 45
	--- studs and a Lancer's authored range is 55, so before this it attacked
	--- from inside the fog -- from a place the renderer deliberately hides.
	--- Being hit by something you could never have seen reads as the game
	--- cheating rather than as a threat you misplayed. Below 1 rather than
	--- exactly 1, so the attacker is properly visible when it opens fire rather
	--- than a silhouette dissolving at the boundary.
	ATTACK_VISIBILITY_FRACTION = 0.8,

	--- Effective radius of a player character, for personal-space purposes.
	--- Roblox's default rig is roughly 2 wide and 5 tall; this is the XZ
	--- footprint an enemy should refuse to stand inside.
	PLAYER_RADIUS = 2.5,

	--- Fraction of its normal speed an entity may use while attacking. Not
	--- zero: an attacking crowd still has to unstack itself, and a player who
	--- walks into a frozen huddle would otherwise stay interpenetrated with it
	--- indefinitely. Not one either — an attacker that repositions at full
	--- sprint reads as fleeing rather than as adjusting its footing.
	--- Lowered from 0.35. Neighbour separation is applied at this speed, and
	--- with seven entities crowding one player the crowd mutually repels hard
	--- enough to push everyone back out of attack range. Unstacking should be a
	--- shuffle, not a shove.
	ATTACK_SHUFFLE_FRACTION = 0.12,

	--- Standoff distance as a fraction of a kind's attack range. Caps the
	--- personal-space push so an entity cannot shove itself out of the range it
	--- is attacking from — the raw hitbox+player sum exceeds `atkRange` for a
	--- Skitter and ties it for a Hauler.
	STANDOFF_FRACTION = 0.7,

	--- An engaged entity keeps attacking out to this multiple of its attack
	--- range. Hysteresis: at 22 studs/s an entity moves 1.1 studs per tick and
	--- would otherwise flicker across the boundary, swapping a full-speed seek
	--- for a slow shuffle every few frames.
	DISENGAGE_FRACTION = 1.5,

	--- Arrival damping. An entity begins slowing this many attack-ranges out,
	--- so it eases to a stop instead of overshooting and being pushed back.
	ARRIVAL_BAND = 1.5,
	--- Floor on the damped approach speed, so an entity still closes the last
	--- stud rather than creeping forever.
	ARRIVAL_MIN_FRACTION = 0.22,

	--- Neighbour separation radius while attacking, as a multiple of hitbox
	--- radius. Tighter than the 2.5 used while moving: six Skitters separating
	--- at 2.5x need about four studs of radius around their target, which is
	--- exactly their four-stud attack range — so the crowd pushed itself to the
	--- edge of the band and hunted in and out of it. An engaged crowd should
	--- pack in, not hold formation.
	ATTACK_SEPARATION_FACTOR = 1.5,
}
