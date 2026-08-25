--!strict
--[[ M2-10/M4-9. The run HUD, plus OVERSEER's comms panel and threat-tier
	lighting hook.

	Displays only. Every number here arrives from the server; nothing is
	computed locally that the server also computes, because two sources for one
	number is how a HUD ends up confidently lying.

	Four things the player is making decisions on:

	  - **Clock.** Turns red under a minute. The timer is the whole tension.
	  - **Weight.** Shown with the speed multiplier and the tier name, because
	    "47 kg" means nothing without "0.82x, committed". This is the number the
	    drop-or-run decision hangs on, so it is the largest element after the
	    clock.
	  - **Pads.** Which are open, and when the next one opens.
	  - **HP and ammo**, read from the character and the prediction controller.

	Built in code rather than as a StarterGui tree: the layout is data-driven
	off the config tables, and a .rbxmx of Frames would have to be kept in sync
	with them by hand.

	**M4-9 addition.** `RunEvent` carries `kind = "overseerBark"` messages
	(server-filtered, per docs/05 §Content filtering -- nothing here ever
	sees or could show unfiltered text). `threatTier` [1,5] still drives the
	lighting, but as of M7-5 this file forwards it to `LookController` rather
	than writing `ColorCorrectionEffect` itself -- see the note further down
	for why one owner per property is load-bearing here.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")

local Remotes = require(Shared.net.Remotes)
local LookController = require("./LookController")
local EconomyConfig = require(Shared.config.Economy)
local ZonesConfig = require(Shared.config.Zones)
local Branding = require(Shared.config.Branding)

local HudController = {}

local player = Players.LocalPlayer

--- Names for the weight tiers, from docs/01 §Weight. The table there is the
--- design's own vocabulary for how bad your situation is.
local TIER_LABELS: { string } = { "free", "noticeable", "committed", "in trouble", "you should have left" }

local ACCENT = Color3.fromRGB(235, 200, 120)
local DIM = Color3.fromRGB(160, 165, 175)
local ALERT = Color3.fromRGB(235, 110, 90)
local GOOD = Color3.fromRGB(120, 210, 150)
local COMMS_COLOR = Color3.fromRGB(180, 200, 235)

--- M7-5: the threat-tier tint/contrast/saturation tables that used to live
--- here are gone, and so is this file's ColorCorrectionEffect. They moved to
--- core/look/LightingBlend and client/controllers/LookController, which now
--- owns the entire post-processing stack.
---
--- The reason is not tidiness. M7-5 drives the same ColorCorrection from the
--- per-zone lighting preset, and two writers on one property means whichever
--- tween finishes last wins -- the stack would flicker between the zone
--- answer and the threat answer. That is the failure this file's own header
--- warns about: two sources for one number is how a HUD ends up confidently
--- lying. The tier still reaches the lighting, via LookController.setThreatTier
--- below, where it is composed with the zone preset instead of fighting it.
local COMMS_DISPLAY_SECONDS = 10

local gui: ScreenGui? = nil
local clockLabel: TextLabel
local weightLabel: TextLabel
local weightBar: Frame
local padLabel: TextLabel
local statusLabel: TextLabel
local vitalsLabel: TextLabel
local commsLabel: TextLabel

local staminaBar: Frame
local staminaBack: Frame
local staminaFraction = 1
local staminaExhausted = false

local crosshair: Frame
local hitmarker: Frame
local hurtVignette: Frame

--- Mirrored from PredictionController through a hook, not read from it: the
--- HUD displaying what the prediction layer believes is the whole point, and
--- two sources for one number is how a HUD ends up confidently lying.
local currentWeapon = "Sidearm"
local currentAmmo = 0

local reloadingWeapon: string? = nil
local reloadEndsAt = 0
local reloadSeconds = 0

local hitmarkerUntil = 0
local hurtUntil = 0
local lastHealth = -1

local HITMARKER_SECONDS = 0.12
local HURT_FLASH_SECONDS = 0.45
local HURT_PEAK_TRANSPARENCY = 0.62
local commsHideAt = 0

local latest = {
	remaining = Branding.runLengthSeconds,
	elapsed = 0,
	openPads = {} :: { string },
	status = "active",
	active = 0,
	complete = false,
	weight = 0,
	value = 0,
	speedMultiplier = 1,
	itemCount = 0,
}

local function makeLabel(parent: Instance, size: UDim2, position: UDim2, textSize: number, align: Enum.TextXAlignment): TextLabel
	local label = Instance.new("TextLabel")
	label.Size = size
	label.Position = position
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.Code
	label.TextSize = textSize
	label.TextColor3 = DIM
	label.TextXAlignment = align
	label.Text = ""
	label.Parent = parent
	return label
end

local function weightTier(weight: number): (number, string)
	local tiers = EconomyConfig.weight.tiers
	for index, tier in tiers do
		if weight <= tier[1] then
			return index, TIER_LABELS[index] or ""
		end
	end
	return #tiers, TIER_LABELS[#TIER_LABELS] or ""
end

local function formatClock(seconds: number): string
	local whole = math.max(0, math.floor(seconds))
	return string.format("%d:%02d", whole // 60, whole % 60)
end

--- Seconds until the next pad opens, and which. Nil once all three are open.
local function nextPad(): (string?, number)
	local best: string? = nil
	local bestAt = math.huge
	for zone, config in ZonesConfig do
		local isOpen = false
		for _, open in latest.openPads do
			if open == zone then
				isOpen = true
				break
			end
		end
		if not isOpen and config.padOpensAt < bestAt then
			bestAt = config.padOpensAt
			best = zone
		end
	end
	if best == nil then
		return nil, 0
	end
	return best, math.max(0, bestAt - latest.elapsed)
end

--- Tweens the post stack toward the tint/contrast/saturation for `tier`.
--- Tweened, not snapped, so an escalation reads as a shift, not a flicker --
--- and clamped, since a garbage tier must still resolve to *some* real
--- lighting state rather than erroring the HUD.
local function render()
	if commsLabel.Visible and os.clock() > commsHideAt then
		commsLabel.Visible = false
	end

	clockLabel.Text = formatClock(latest.remaining)
	clockLabel.TextColor3 = if latest.remaining <= 60 then ALERT else ACCENT

	local tierIndex, tierName = weightTier(latest.weight)
	weightLabel.Text = string.format(
		"%3.0f kg   x%.2f   %s",
		latest.weight,
		latest.speedMultiplier,
		tierName
	)
	-- The bar fills toward the last tier's threshold, so "how close am I to
	-- crawling" is readable without doing arithmetic.
	local tiers = EconomyConfig.weight.tiers
	local ceiling = tiers[#tiers - 1][1]
	weightBar.Size = UDim2.new(math.clamp(latest.weight / ceiling, 0, 1), 0, 1, 0)
	weightBar.BackgroundColor3 = if tierIndex <= 1 then GOOD elseif tierIndex >= 4 then ALERT else ACCENT
	weightLabel.TextColor3 = if tierIndex >= 4 then ALERT else DIM

	if #latest.openPads > 0 then
		padLabel.Text = "PADS OPEN  " .. table.concat(latest.openPads, "  ")
		padLabel.TextColor3 = GOOD
	else
		local zone, seconds = nextPad()
		padLabel.Text = if zone then string.format("%s pad in %s", zone, formatClock(seconds)) else "no pads"
		padLabel.TextColor3 = DIM
	end

	if latest.status == "extracted" then
		statusLabel.Text = string.format("EXTRACTED  +%d credits", latest.value)
		statusLabel.TextColor3 = GOOD
	elseif latest.status == "dead" then
		statusLabel.Text = "LOST — everything you carried is on the floor"
		statusLabel.TextColor3 = ALERT
	elseif latest.complete then
		statusLabel.Text = "RUN OVER"
		statusLabel.TextColor3 = DIM
	else
		statusLabel.Text = string.format("%d carried · %d credits at risk", latest.itemCount, latest.value)
		statusLabel.TextColor3 = DIM
	end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local hp = if humanoid then math.max(0, math.floor(humanoid.Health)) else 0
	-- Weapon rides on the vitals line rather than getting its own: switching is
	-- new (number keys 1-4) and a player who cannot see which weapon is live
	-- has no way to tell the switch worked.
	if reloadingWeapon == currentWeapon and reloadSeconds > 0 then
		local left = math.max(reloadEndsAt - os.clock(), 0)
		vitalsLabel.Text = string.format("HP %3d   %s RELOADING %.1fs", hp, currentWeapon, left)
		vitalsLabel.TextColor3 = ACCENT
	else
		vitalsLabel.Text = string.format("HP %3d   %s %d", hp, currentWeapon, currentAmmo)
		vitalsLabel.TextColor3 = if hp <= 25 then ALERT elseif currentAmmo == 0 then ALERT else DIM
	end

	local now = os.clock()

	-- Damage taken is detected from Humanoid health rather than a remote: the
	-- engine already replicates it, and a dedicated packet per hit would be
	-- bandwidth spent on something the client can see for free. Regeneration
	-- ticks health *up*, so only a decrease counts.
	if humanoid ~= nil then
		local current = humanoid.Health
		if lastHealth >= 0 and current < lastHealth - 0.01 then
			hurtUntil = now + HURT_FLASH_SECONDS
		end
		lastHealth = current
	end

	if now < hurtUntil then
		local t = (hurtUntil - now) / HURT_FLASH_SECONDS
		hurtVignette.BackgroundTransparency = 1 - HURT_PEAK_TRANSPARENCY * t * t
	else
		hurtVignette.BackgroundTransparency = 1
	end

	if now < hitmarkerUntil then
		hitmarker.Visible = true
		-- Contracts as it fades, so rapid hits read as distinct marks rather
		-- than one continuous smear. Position is set below, from the cursor.
		local t = (hitmarkerUntil - now) / HITMARKER_SECONDS
		local size = 16 + 10 * t
		hitmarker.Size = UDim2.new(0, size, 0, size)
	else
		hitmarker.Visible = false
	end

	-- The crosshair dims while dead or extracted: nothing to aim at, and a
	-- live-looking reticle over a corpse is a small lie.
	crosshair.Visible = not latest.complete and latest.status ~= "dead"

	-- Follows the cursor rather than sitting at screen centre. Shots are aimed
	-- where the mouse points, so a fixed centre reticle would be pointing at
	-- somewhere rounds do not go -- which is the whole complaint it exists to
	-- answer. `GetMouseLocation` and the GUI both include the inset, so the
	-- offset needs no correction.
	staminaBar.Size = UDim2.new(math.clamp(staminaFraction, 0, 1), 0, 1, 0)
	-- Red while locked out, not merely low: "empty" and "you may not sprint
	-- yet" are different states, and only the second one explains why the key
	-- is doing nothing.
	staminaBar.BackgroundColor3 = if staminaExhausted
		then ALERT
		elseif staminaFraction < 0.3 then Color3.fromRGB(220, 170, 90)
		else GOOD
	staminaBack.Visible = not latest.complete

	local mouse = UserInputService:GetMouseLocation()
	crosshair.Position = UDim2.new(0, mouse.X - crosshair.AbsoluteSize.X / 2, 0, mouse.Y - crosshair.AbsoluteSize.Y / 2)
	hitmarker.Position = UDim2.new(
		0,
		mouse.X - hitmarker.AbsoluteSize.X / 2,
		0,
		mouse.Y - hitmarker.AbsoluteSize.Y / 2
	)
end

--- Confirmed by the server, never predicted.
function HudController.showHitmarker()
	hitmarkerUntil = os.clock() + HITMARKER_SECONDS
end

--- Pushed by SprintController every frame it ticks.
function HudController.setStamina(fraction: number, exhausted: boolean)
	staminaFraction = fraction
	staminaExhausted = exhausted
end

--- Pushed by PredictionController when the player switches weapons.
function HudController.setWeapon(weaponId: string, ammo: number)
	currentWeapon = weaponId
	currentAmmo = ammo
end

--- Pushed on every ammo change, including server `AmmoSync` for weapons the
--- player is not currently holding — so it must not change which weapon is
--- displayed, only the count for the one that is.
function HudController.setAmmo(weaponId: string, ammo: number)
	if weaponId == currentWeapon then
		currentAmmo = ammo
	end
end

--- Pushed by PredictionController when the server starts or finishes a reload.
--- Without a readout the weapon simply stops firing for 1.4 seconds and
--- nothing on screen says why, which is indistinguishable from it being broken.
function HudController.setReloading(weaponId: string, reloading: boolean, seconds: number)
	if reloading then
		reloadingWeapon = weaponId
		reloadSeconds = seconds
		reloadEndsAt = os.clock() + seconds
	elseif reloadingWeapon == weaponId then
		reloadingWeapon = nil
	end
end

function HudController.start()
	local screen = Instance.new("ScreenGui")
	screen.Name = "DeepcacheHud"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.Parent = player:WaitForChild("PlayerGui")
	gui = screen

	local root = Instance.new("Frame")
	root.Size = UDim2.new(1, 0, 1, 0)
	root.BackgroundTransparency = 1
	root.Parent = screen

	clockLabel = makeLabel(root, UDim2.new(0, 200, 0, 54), UDim2.new(0.5, -100, 0, 12), 44, Enum.TextXAlignment.Center)
	padLabel = makeLabel(root, UDim2.new(0, 400, 0, 24), UDim2.new(0.5, -200, 0, 66), 18, Enum.TextXAlignment.Center)

	local weightPanel = Instance.new("Frame")
	weightPanel.Size = UDim2.new(0, 320, 0, 46)
	weightPanel.Position = UDim2.new(0, 24, 1, -80)
	weightPanel.BackgroundTransparency = 1
	weightPanel.Parent = root

	local barBack = Instance.new("Frame")
	barBack.Size = UDim2.new(1, 0, 0, 6)
	barBack.Position = UDim2.new(0, 0, 0, 30)
	barBack.BackgroundColor3 = Color3.fromRGB(48, 50, 56)
	barBack.BorderSizePixel = 0
	barBack.Parent = weightPanel

	weightBar = Instance.new("Frame")
	weightBar.Size = UDim2.new(0, 0, 1, 0)
	weightBar.BackgroundColor3 = GOOD
	weightBar.BorderSizePixel = 0
	weightBar.Parent = barBack

	-- Crosshair. A shooter without one asks the player to aim at the middle of
	-- their monitor from memory, and the tracer arriving somewhere unexpected
	-- reads as the weapon being broken rather than as the aim being off.
	crosshair = Instance.new("Frame")
	crosshair.Size = UDim2.new(0, 26, 0, 26)
	crosshair.Position = UDim2.new(0.5, -13, 0.5, -13)
	crosshair.BackgroundTransparency = 1
	crosshair.Parent = root
	for _, spec in
		{
			{ UDim2.new(0, 2, 0, 8), UDim2.new(0.5, -1, 0, 0) },
			{ UDim2.new(0, 2, 0, 8), UDim2.new(0.5, -1, 1, -8) },
			{ UDim2.new(0, 8, 0, 2), UDim2.new(0, 0, 0.5, -1) },
			{ UDim2.new(0, 8, 0, 2), UDim2.new(1, -8, 0.5, -1) },
		}
	do
		local tick_ = Instance.new("Frame")
		tick_.Size = spec[1]
		tick_.Position = spec[2]
		tick_.BackgroundColor3 = Color3.fromRGB(235, 240, 245)
		tick_.BackgroundTransparency = 0.25
		tick_.BorderSizePixel = 0
		tick_.Parent = crosshair
	end

	-- Hitmarker, drawn over the crosshair and hidden until a hit is confirmed
	-- by the *server*. Predicting it would defeat the point: the whole value of
	-- this mark is that it means the shot really landed.
	hitmarker = Instance.new("Frame")
	hitmarker.Size = UDim2.new(0, 22, 0, 22)
	hitmarker.Position = UDim2.new(0.5, -11, 0.5, -11)
	hitmarker.BackgroundTransparency = 1
	hitmarker.Visible = false
	hitmarker.Parent = root
	for _, rotation in { 45, -45 } do
		local stroke = Instance.new("Frame")
		stroke.Size = UDim2.new(0, 20, 0, 2)
		stroke.Position = UDim2.new(0.5, -10, 0.5, -1)
		stroke.BackgroundColor3 = Color3.fromRGB(255, 240, 200)
		stroke.BorderSizePixel = 0
		stroke.Rotation = rotation
		stroke.Parent = hitmarker
	end

	-- Full-screen red wash on taking damage. Health is a number in the corner;
	-- this is what makes "I am being hurt right now" land without reading it.
	hurtVignette = Instance.new("Frame")
	hurtVignette.Size = UDim2.new(1, 0, 1, 0)
	hurtVignette.BackgroundColor3 = Color3.fromRGB(150, 20, 20)
	hurtVignette.BackgroundTransparency = 1
	hurtVignette.BorderSizePixel = 0
	hurtVignette.ZIndex = 5
	hurtVignette.Parent = root

	weightLabel = makeLabel(weightPanel, UDim2.new(1, 0, 0, 26), UDim2.new(0, 0, 0, 0), 20, Enum.TextXAlignment.Left)
	-- Stamina sits directly under the weight bar: both answer "can I get out of
	-- here", and splitting them across the screen would make the player look in
	-- two places for one decision.
	staminaBack = Instance.new("Frame")
	staminaBack.Size = UDim2.new(0, 320, 0, 5)
	staminaBack.Position = UDim2.new(0, 24, 1, -44)
	staminaBack.BackgroundColor3 = Color3.fromRGB(48, 50, 56)
	staminaBack.BorderSizePixel = 0
	staminaBack.Parent = root

	staminaBar = Instance.new("Frame")
	staminaBar.Size = UDim2.new(1, 0, 1, 0)
	staminaBar.BackgroundColor3 = ACCENT
	staminaBar.BorderSizePixel = 0
	staminaBar.Parent = staminaBack

	statusLabel = makeLabel(root, UDim2.new(0, 520, 0, 22), UDim2.new(0, 24, 1, -30), 16, Enum.TextXAlignment.Left)
	vitalsLabel = makeLabel(root, UDim2.new(0, 200, 0, 30), UDim2.new(1, -224, 1, -60), 24, Enum.TextXAlignment.Right)

	-- M4-9 comms panel: OVERSEER's filtered barks, top-of-screen, below the
	-- clock so it never overlaps the number the player is reading fastest.
	commsLabel = makeLabel(root, UDim2.new(0, 600, 0, 28), UDim2.new(0.5, -300, 0, 96), 17, Enum.TextXAlignment.Center)
	commsLabel.TextColor3 = COMMS_COLOR
	commsLabel.Font = Enum.Font.Code
	commsLabel.RichText = false -- server text is filtered, not markup-safe; never interpret it as rich text
	commsLabel.Visible = false

	-- M4-9's threat-tier lighting is still driven, but by LookController now;
	-- see the note where the tier tables used to be. BUILD's baseline tier is
	-- set here so the level does not open at whatever the default happens to be.
	LookController.setThreatTier(2)

	Remotes.event("RunEvent").OnClientEvent:Connect(function(payload: any)
		if typeof(payload) ~= "table" or payload.kind ~= "overseerBark" then
			return
		end
		local bark = payload.bark
		if typeof(bark) == "string" and bark ~= "" then
			commsLabel.Text = "OVERSEER: " .. bark
			commsLabel.Visible = true
			commsHideAt = os.clock() + COMMS_DISPLAY_SECONDS
		end
		if typeof(payload.threatTier) == "number" then
			LookController.setThreatTier(payload.threatTier)
		end
	end)

	Remotes.event("RunState").OnClientEvent:Connect(function(payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		latest.remaining = payload.remaining or latest.remaining
		latest.elapsed = payload.elapsed or latest.elapsed
		latest.openPads = payload.openPads or latest.openPads
		latest.status = payload.status or latest.status
		latest.active = payload.active or 0
		latest.complete = payload.complete == true
		-- M7-5: zone drives the lighting transition. setZone is a no-op when
		-- the zone has not changed, so forwarding it at the RunState cadence
		-- (~1Hz) costs nothing and does not restart the 1.5s blend.
		if typeof(payload.zone) == "string" then
			LookController.setZone(payload.zone)
		end
	end)

	Remotes.event("CarryUpdate").OnClientEvent:Connect(function(payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		latest.weight = payload.weight or 0
		latest.value = payload.value or 0
		latest.speedMultiplier = payload.speedMultiplier or 1
		latest.itemCount = if payload.items then #payload.items else 0
	end)

	-- The clock is interpolated between the server's 1 Hz pushes so it ticks
	-- smoothly, but it is never the source of truth — every push overwrites it.
	RunService.Heartbeat:Connect(function(dt)
		if not latest.complete then
			latest.remaining = math.max(0, latest.remaining - dt)
			latest.elapsed += dt
		end
		render()
	end)

	render()
end

return HudController
