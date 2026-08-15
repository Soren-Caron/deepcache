--!strict
--[[ Pure data. Each weapon exercises a different netcode path — see docs/01. ]]

return {
	Sidearm = {
		kind = "hitscan", damage = 22, rps = 4.0, magazine = 14, reloadSeconds = 1.4,
		range = 120, falloffStart = 45, falloffEnd = 110, minMultiplier = 0.45,
		headshotMultiplier = 1.8, spreadDegrees = 1.2, weight = 4,
	},
	Carbine = {
		kind = "hitscan", damage = 17, rps = 9.0, burst = 3, magazine = 30, reloadSeconds = 2.1,
		range = 160, falloffStart = 60, falloffEnd = 150, minMultiplier = 0.40,
		headshotMultiplier = 1.6, spreadDegrees = 2.0, weight = 8,
	},
	Slug = {
		kind = "projectile", damage = 68, rps = 1.1, magazine = 6, reloadSeconds = 2.8,
		range = 200, projectileSpeed = 180, gravity = 14,
		falloffStart = 200, falloffEnd = 200, minMultiplier = 1.0,
		headshotMultiplier = 2.0, spreadDegrees = 0.4, weight = 12,
	},
	Arc = {
		kind = "beam", damagePerSecond = 40, rampPerSecond = 1.15, rampMax = 3.0,
		magazine = 100, reloadSeconds = 2.4, range = 70,
		falloffStart = 55, falloffEnd = 70, minMultiplier = 0.6,
		headshotMultiplier = 1.0, weight = 10,
	},
}
