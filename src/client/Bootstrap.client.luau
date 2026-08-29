--!strict
--[[
	Client startup.

	Presentation only. Nothing here decides anything the server cares about —
	it renders what the server says happened and predicts how it should look
	while the authoritative answer is in flight.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")

local Branding = require(Shared.config.Branding)
local Remotes = require(Shared.net.Remotes)
local Effects = require("./controllers/Effects")
local EntityRenderer = require("./controllers/EntityRenderer")
local PredictionController = require("./controllers/PredictionController")
local HudController = require("./controllers/HudController")
local CorrectionController = require("./controllers/CorrectionController")
local MarketController = require("./controllers/MarketController")
local LookController = require("./controllers/LookController")
local RagdollController = require("./controllers/RagdollController")
local SprintController = require("./controllers/SprintController")
local AudioController = require("./controllers/AudioController")
local MeleeController = require("./controllers/MeleeController")
local RepairController = require("./controllers/RepairController")

local function main()
	EntityRenderer.start()
	-- Before the HUD, which sets the baseline threat tier through
	-- LookController and so needs its effects to already exist.
	LookController.start()
	HudController.start()
	CorrectionController.start()
	MarketController.start()
	RagdollController.start()
	-- Before anything that can emit a cue, so the counters exist from boot and
	-- an absent folder means "never started" rather than "nothing played yet".
	AudioController.start()
	SprintController.setHooks({ onStaminaChanged = HudController.setStamina })
	SprintController.start()

	-- The sweep. Its arc is drawn from the numbers the server sends rather than
	-- from the local config, so the visual can never disagree with the hitbox
	-- that was actually used.
	MeleeController.setHooks({
		onCooldownChanged = HudController.setMeleeCooldown,
		onHit = function(_count: number)
			HudController.showHitmarker()
			AudioController.play("hitConfirm")
		end,
	})
	MeleeController.setSwingRenderer(function(payload)
		if typeof(payload.from) ~= "Vector3" then
			return
		end
		Effects.meleeSweep(payload.from, payload.facing or 0, payload.radius or 12, payload.arcDegrees or 120)
		AudioController.play("meleeSwing", payload.from)
	end)
	MeleeController.start()

	RepairController.setHooks({ onChanged = HudController.setRepair })
	RepairController.start()

	-- Which weapon is live, mirrored here so the fire cue can be per-weapon.
	-- Four weapons that sound identical read as one weapon.
	local currentWeapon = "Sidearm"

	PredictionController.setHooks({
		onTracer = function(origin: Vector3, target: Vector3)
			Effects.tracer(origin, target)
			Effects.muzzleFlash(origin)
			AudioController.play(`weaponFire{currentWeapon}`)
		end,
		-- `onHitmarker` and `onRemoveHitmarker` were declared in M1 and never
		-- wired to anything, so a landed shot produced no feedback at all.
		onHitmarker = function(_confirmed: boolean)
			HudController.showHitmarker()
			AudioController.play("hitConfirm")
		end,
		-- The HUD is the only feedback that a weapon switch took effect.
		onAmmoChanged = function(weaponId: string, ammo: number)
			HudController.setAmmo(weaponId, ammo)
			if ammo == 0 and weaponId == currentWeapon then
				AudioController.play("weaponDryFire")
			end
		end,
		onWeaponChanged = function(weaponId: string, ammo: number)
			currentWeapon = weaponId
			HudController.setWeapon(weaponId, ammo)
		end,
		onReloadStateChanged = function(weaponId: string, reloading: boolean, seconds: number)
			HudController.setReloading(weaponId, reloading, seconds)
			AudioController.play(if reloading then "weaponReloadStart" else "weaponReloadDone")
		end,
	})

	-- Ranged enemies: draw the shot. Server-side the damage has already
	-- landed; this is the only thing that tells a player where it came from.
	local ENEMY_BOLT_COLOUR: { [string]: Color3 } = {
		Sentry = Color3.fromRGB(120, 180, 255),
		Lancer = Color3.fromRGB(150, 255, 170),
	}
	Remotes.event("EnemyShot").OnClientEvent:Connect(function(payload)
		if typeof(payload) ~= "table" or typeof(payload.from) ~= "Vector3" or typeof(payload.to) ~= "Vector3" then
			return
		end
		Effects.enemyBolt(payload.from, payload.to, ENEMY_BOLT_COLOUR[payload.kind])
		-- Positional: this cue's whole job is telling the player where the
		-- shooter is, so playing it flat would throw that away.
		AudioController.play("enemyShot", payload.from)
	end)

	-- Taking a hit. The HUD arrow points at it; this makes it land without
	-- being read.
	Remotes.event("DamageFrom").OnClientEvent:Connect(function(payload)
		if typeof(payload) ~= "table" then
			return
		end
		AudioController.play("hitTaken")
	end)

	Remotes.event("Ragdoll").OnClientEvent:Connect(function(payload)
		if typeof(payload) ~= "table" or typeof(payload.deathPos) ~= "Vector3" then
			return
		end
		AudioController.play("enemyDeath", payload.deathPos)
	end)

	Remotes.event("RunEvent").OnClientEvent:Connect(function(payload)
		if typeof(payload) ~= "table" then
			return
		end
		if payload.kind == "padOpened" then
			AudioController.play("padOpen")
		elseif payload.kind == "runEnded" then
			AudioController.play("runEnd")
		end
	end)

	-- CarryUpdate fires on pickups, drops, *and* the refresh a run restart
	-- sends. Only a genuine increase is a pickup, so track the count rather
	-- than playing on every update and lying twice out of three times.
	local carriedCount = 0
	Remotes.event("CarryUpdate").OnClientEvent:Connect(function(payload)
		if typeof(payload) ~= "table" then
			return
		end
		local count = if typeof(payload.items) == "table" then #payload.items else 0
		if count > carriedCount then
			AudioController.play("lootPickup")
		end
		carriedCount = count
	end)

	PredictionController.start()

	print(`[{Branding.gameName}] client up — entities, prediction, HUD, corrections, market, look, ragdolls`)
end

main()
