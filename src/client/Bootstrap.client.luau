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

local function main()
	EntityRenderer.start()
	-- Before the HUD, which sets the baseline threat tier through
	-- LookController and so needs its effects to already exist.
	LookController.start()
	HudController.start()
	CorrectionController.start()
	MarketController.start()
	RagdollController.start()
	SprintController.setHooks({ onStaminaChanged = HudController.setStamina })
	SprintController.start()

	PredictionController.setHooks({
		onTracer = function(origin: Vector3, target: Vector3)
			Effects.tracer(origin, target)
			Effects.muzzleFlash(origin)
		end,
		-- `onHitmarker` and `onRemoveHitmarker` were declared in M1 and never
		-- wired to anything, so a landed shot produced no feedback at all.
		onHitmarker = function(_confirmed: boolean)
			HudController.showHitmarker()
		end,
		-- The HUD is the only feedback that a weapon switch took effect.
		onAmmoChanged = HudController.setAmmo,
		onWeaponChanged = HudController.setWeapon,
		onReloadStateChanged = HudController.setReloading,
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
	end)

	PredictionController.start()

	print(`[{Branding.gameName}] client up — entities, prediction, HUD, corrections, market, look, ragdolls`)
end

main()
