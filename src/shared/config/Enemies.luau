--!strict
--[[ Pure data. `budget` is the currency the director spends. See docs/01.

	`turnRate` is radians/second and caps how fast a kind may change facing.
	Without a cap, yaw is assigned straight from atan2 and an entity can
	reverse completely between two ticks, which at 20 Hz reads as a violent
	spin rather than as a turn. Values are ordered by mass: a Skitter whips
	round, a Hauler does not.
]]

return {
	Skitter = {
		hp = 45, speed = 22, dmg = 8, atkRange = 4, atkCooldown = 0.8,
		budget = 1, hitboxRadius = 1.6, behavior = "SwarmNearest", turnRate = 8.0,
		zones = { "Perimeter", "Processing", "Vault" }, capPerWave = 24,
	},
	-- Cooldown was 0.35 (31.4 dps). At capPerWave 6 that is 188 dps against a
	-- 100 HP player -- a wave of five killed a stationary player in 0.64s while
	-- taking 7.4s to kill with a Sidearm. Area denial should make a sightline
	-- expensive to cross, not make it fatal before you can react.
	Sentry = {
		hp = 130, speed = 0, dmg = 11, atkRange = 45, atkCooldown = 0.75,
		budget = 2, hitboxRadius = 2.2, behavior = "Static", turnRate = 2.5,
		falloffStart = 14, minMultiplier = 0.45,
		zones = { "Perimeter", "Processing", "Vault" }, capPerWave = 6,
	},
	-- capPerWave was 4. A 30-damage swing suits a heavy — four hits is a kill,
	-- which is the threat it should pose — but four of them in contact at once
	-- is 75 dps and a 1.33 s death, faster than a player can disengage. The
	-- per-hit damage is its identity, so the pile-on is what gives.
	Hauler = {
		hp = 420, speed = 8, dmg = 30, atkRange = 6, atkCooldown = 1.6,
		budget = 5, hitboxRadius = 3.4, behavior = "PushObjective", turnRate = 1.2,
		zones = { "Processing", "Vault" }, capPerWave = 3,
	},
	Lancer = {
		hp = 90, speed = 12, dmg = 14, atkRange = 55, atkCooldown = 1.2,
		budget = 3, hitboxRadius = 2.0, behavior = "KeepDistance", turnRate = 4.0,
		projectile = "Slug", preferredDistance = 40,
		-- Holds standoff at 40, so full damage would mean it always hits for
		-- full. The falloff makes closing on it the correct answer.
		falloffStart = 18, minMultiplier = 0.5,
		zones = { "Processing", "Vault" }, capPerWave = 8,
	},
	Warden = {
		hp = 700, speed = 10, dmg = 22, atkRange = 8, atkCooldown = 1.4,
		budget = 9, hitboxRadius = 4.0, behavior = "ShieldNearby", turnRate = 1.5,
		shieldRadius = 30, shieldReduction = 0.5,
		zones = { "Vault" }, capPerWave = 2,
	},
	Reclaimer = {
		hp = 550, speed = 16, dmg = 26, atkRange = 6, atkCooldown = 1.0,
		budget = 8, hitboxRadius = 3.0, behavior = "HuntHeaviest", turnRate = 5.0,
		zones = { "Perimeter", "Processing", "Vault" }, capPerWave = 2,
		directorOnly = true, -- never spawned by the baseline budget planner
	},
}
