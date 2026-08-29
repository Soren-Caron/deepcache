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
local DamageArc = require(Shared.core.look.DamageArc)
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
local meleeBar: Frame
local meleeBack: Frame
local meleeReadiness = 1
local repairCharges = 0
local repairProgress = 0
local repairing = false
local staminaFraction = 1
local staminaExhausted = false

local crosshair: Frame
local hitmarker: Frame
local hurtVignette: Frame

local redeployButton: TextButton
local hintLabel: TextLabel
local summaryPanel: Frame
local summaryTitle: TextLabel
local summaryBody: TextLabel
local bannerLabel: TextLabel
local bannerUntil = 0
local BANNER_SECONDS = 4.5

--- Damage-direction indicators, newest last.
---
--- The attacker's *world* position is stored, not a screen angle. A stored
--- angle would keep pointing at where the shooter was relative to where the
--- player used to be facing, so turning toward the arrow would swing it
--- further away -- worse than no arrow at all. Re-deriving the bearing each
--- frame against the live camera makes the arrow behave like a compass.
type DamageMark = { fromX: number, fromZ: number, at: number, frame: Frame }
local damageMarks: { DamageMark } = {}
local damageLayer: Frame

--- How long an arrow lives, and how close two hits have to be before they
--- refresh one arrow instead of stacking two.
local DAMAGE_MARK_SECONDS = 1.6
local DAMAGE_MERGE_RADIANS = 0.45
--- Cap on simultaneous arrows. A swarm otherwise rings the player in arrows,
--- which conveys less than three do.
local DAMAGE_MARK_LIMIT = 4

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
--- The controls legend shows for a while after joining and then gets out of
--- the way. Permanent would be clutter; never would leave weapon switching and
--- reload undiscoverable, and both decide fights against elites.
local hintUntil = 0
local HINT_SECONDS = 45

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
	canRedeploy = false,
	endReason = nil :: string?,
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
	elseif repairing then
		vitalsLabel.Text = string.format("HP %3d   REPAIRING %.0f%%", hp, repairProgress * 100)
		vitalsLabel.TextColor3 = GOOD
	else
		vitalsLabel.Text = string.format("HP %3d   %s %d   [G]x%d", hp, currentWeapon, currentAmmo, repairCharges)
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

	-- Damage arrows. Each is one frame rotated about screen centre, so a single
	-- shape serves every direction.
	local camera = workspace.CurrentCamera
	local look = if camera then camera.CFrame.LookVector else Vector3.zAxis
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local here = if root and root:IsA("BasePart") then root.Position else Vector3.zero
	for index = #damageMarks, 1, -1 do
		local mark = damageMarks[index]
		local opacity = DamageArc.opacity(now - mark.at, DAMAGE_MARK_SECONDS)
		if opacity <= 0 then
			mark.frame:Destroy()
			table.remove(damageMarks, index)
		else
			local bearing = DamageArc.bearing(look.X, look.Z, mark.fromX - here.X, mark.fromZ - here.Z)
			mark.frame.Rotation = math.deg(bearing)
			for _, child in mark.frame:GetChildren() do
				if child:IsA("Frame") then
					child.BackgroundTransparency = 1 - opacity
				end
			end
		end
	end

	-- The crosshair dims while dead or extracted: nothing to aim at, and a
	-- live-looking reticle over a corpse is a small lie.
	crosshair.Visible = not latest.complete and latest.status ~= "dead"

	bannerLabel.Visible = now < bannerUntil
	-- The summary rides with the redeploy control: both belong to the moment the
	-- run resolves, and showing one without the other reads as half a screen.
	summaryPanel.Visible = latest.canRedeploy == true

	-- Redeploy. Offered only when the server says so, so the button cannot
	-- appear a moment before the server would honour it.
	redeployButton.Visible = latest.canRedeploy == true
	if redeployButton.Visible then
		-- The summary card owns the payout number now. This line used to repeat
		-- it from `latest.value`, which is *carried* value -- already banked and
		-- zeroed by the time the run resolves, so the screen read "+542 credits
		-- banked" and "EXTRACTED +0 credits" at the same time. Two sources for
		-- one number, exactly as this file's header warns.
		statusLabel.Text = ""
	end

	-- Contextual hints. The systems that decide fights are the two nobody is
	-- told about: an elite beats a Sidearm one-on-one by design, and the answer
	-- is a different weapon or a full magazine.
	local hint = ""
	if reloadingWeapon == nil and currentAmmo == 0 then
		hint = "[R]  RELOAD"
	elseif now < hintUntil then
		hint = "[1-4] weapons  [R] reload  [SHIFT] sprint  [F] sweep  [G] repair"
	end
	hintLabel.Text = hint
	hintLabel.Visible = hint ~= "" and not latest.complete

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

	-- Melee cooldown, directly under stamina. All three bars answer the same
	-- question in different currencies: what can I still do right now.
	meleeBar.Size = UDim2.new(math.clamp(meleeReadiness, 0, 1), 0, 1, 0)
	meleeBar.BackgroundColor3 = if meleeReadiness >= 1 then ACCENT else DIM
	meleeBack.Visible = not latest.complete

	local mouse = UserInputService:GetMouseLocation()
	crosshair.Position = UDim2.new(0, mouse.X - crosshair.AbsoluteSize.X / 2, 0, mouse.Y - crosshair.AbsoluteSize.Y / 2)
	hitmarker.Position = UDim2.new(
		0,
		mouse.X - hitmarker.AbsoluteSize.X / 2,
		0,
		mouse.Y - hitmarker.AbsoluteSize.Y / 2
	)
end

--- Fill the end-of-run card.
---
--- Extraction and death are the two ways a run ends and they deserve to read
--- completely differently: one is the thing the whole twelve minutes was for,
--- the other is losing everything you were carrying.
function HudController.showSummary(extracted: boolean, zone: string?, credits: number)
	if extracted then
		summaryTitle.Text = "EXTRACTED"
		summaryTitle.TextColor3 = GOOD
		summaryBody.Text = string.format(
			"+%d credits banked\nout via %s at %s",
			credits,
			tostring(zone or "a pad"),
			formatClock(latest.elapsed)
		)
	else
		summaryTitle.Text = "LOST"
		summaryTitle.TextColor3 = ALERT
		summaryBody.Text = string.format(
			"%d credits left on the floor\nsurvived %s",
			credits,
			formatClock(latest.elapsed)
		)
	end
end

--- Confirmed by the server, never predicted.
function HudController.showHitmarker()
	hitmarkerUntil = os.clock() + HITMARKER_SECONDS
end

--- Build one arrow: a wedge sitting above centre, rotated into place by
--- `render`. Two stacked bars rather than an image, so it needs no asset.
local function makeArrow(): Frame
	local arrow = Instance.new("Frame")
	arrow.Size = UDim2.new(0, 0, 0, 0)
	arrow.Position = UDim2.new(0, 0, 0, 0)
	arrow.BackgroundTransparency = 1
	arrow.ZIndex = 6
	arrow.Parent = damageLayer

	for _, spec in
		{
			-- { size, offset from centre } -- a short thick bar with a longer
			-- thin one behind it reads as a chevron pointing outward.
			{ UDim2.new(0, 46, 0, 5), -120 },
			{ UDim2.new(0, 26, 0, 5), -134 },
		}
	do
		local bar = Instance.new("Frame")
		bar.Size = spec[1] :: UDim2
		bar.Position = UDim2.new(0, -(spec[1] :: UDim2).X.Offset / 2, 0, spec[2] :: number)
		bar.BackgroundColor3 = ALERT
		bar.BorderSizePixel = 0
		bar.ZIndex = 6
		bar.Parent = arrow
	end

	return arrow
end

--- A hit arrived from `from` (world space).
---
--- Attackers on nearly the same bearing refresh one arrow rather than stacking
--- two on top of each other, which just looks like a rendering fault. The
--- merge test runs against the bearing *at the time of the hit*, which is the
--- only moment the two are comparable.
function HudController.showDamageFrom(from: Vector3)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root == nil or not root:IsA("BasePart") then
		return
	end
	local camera = workspace.CurrentCamera
	local look = if camera then camera.CFrame.LookVector else Vector3.zAxis
	local incoming = DamageArc.bearing(look.X, look.Z, from.X - root.Position.X, from.Z - root.Position.Z)

	for _, mark in damageMarks do
		local existing = DamageArc.bearing(
			look.X,
			look.Z,
			mark.fromX - root.Position.X,
			mark.fromZ - root.Position.Z
		)
		if DamageArc.shouldMerge(existing, incoming, DAMAGE_MERGE_RADIANS) then
			mark.fromX, mark.fromZ, mark.at = from.X, from.Z, os.clock()
			return
		end
	end

	-- Oldest out first once the cap is reached: a swarm otherwise rings the
	-- player in arrows, which conveys less than three do.
	if #damageMarks >= DAMAGE_MARK_LIMIT then
		local oldest = table.remove(damageMarks, 1)
		if oldest then
			oldest.frame:Destroy()
		end
	end

	table.insert(damageMarks, { fromX = from.X, fromZ = from.Z, at = os.clock(), frame = makeArrow() })
end

--- Pushed by MeleeController every frame. 0..1, 1 = ready.
---
--- A cooldown the player cannot see is a button that randomly does nothing,
--- which is indistinguishable from a bug -- the same reason the reload readout
--- exists.
function HudController.setMeleeCooldown(fraction: number, _ready: boolean)
	meleeReadiness = fraction
end

--- Pushed by RepairController every frame.
---
--- Charges ride the vitals line rather than getting their own element: a
--- resource you have two of, all run, does not need a bar -- it needs a
--- number next to the health it restores.
function HudController.setRepair(chargesLeft: number, progress: number, isRepairing: boolean)
	repairCharges = chargesLeft
	repairProgress = progress
	repairing = isRepairing
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

	-- Damage arrows live in their own centred, full-height layer: rotating a
	-- child about the screen centre only works if its parent is centred, and
	-- giving them a layer keeps that fact in one place.
	damageLayer = Instance.new("Frame")
	damageLayer.Size = UDim2.new(0, 0, 0, 0)
	damageLayer.Position = UDim2.new(0.5, 0, 0.5, 0)
	damageLayer.BackgroundTransparency = 1
	damageLayer.ZIndex = 6
	damageLayer.Parent = root

	-- Redeploy. A button rather than a keybind: every letter that reads as
	-- "again" is already taken (R reloads, 1-4 switch, shift sprints), and a
	-- control that only appears when the run is over does not need to be
	-- memorised.
	redeployButton = Instance.new("TextButton")
	redeployButton.Size = UDim2.new(0, 260, 0, 52)
	redeployButton.Position = UDim2.new(0.5, -130, 0.5, 40)
	redeployButton.BackgroundColor3 = Color3.fromRGB(28, 30, 36)
	redeployButton.BorderSizePixel = 0
	redeployButton.Font = Enum.Font.Code
	redeployButton.TextSize = 22
	redeployButton.TextColor3 = ACCENT
	redeployButton.Text = "REDEPLOY  [ENTER]"
	redeployButton.AutoButtonColor = true
	redeployButton.Visible = false
	redeployButton.ZIndex = 7
	redeployButton.Parent = root

	local buttonStroke = Instance.new("UIStroke")
	buttonStroke.Color = ACCENT
	buttonStroke.Thickness = 1
	buttonStroke.Transparency = 0.4
	buttonStroke.Parent = redeployButton

	--- Ask, do not assume. The server owns whether this is allowed; the button
	--- hides itself on the next RunState if the run really restarted.
	local function askToRedeploy()
		if not redeployButton.Visible then
			return
		end
		Remotes.event("RedeployRequest"):FireServer()
	end

	redeployButton.Activated:Connect(askToRedeploy)

	-- Enter does the same thing. Partly because a player who just died reaches
	-- for a key before a mouse, and partly for a duller reason: GuiObject
	-- events cannot be driven by the Studio automation bridge -- a synthetic
	-- click lands inside the button's rect without emitting so much as
	-- MouseEnter -- so a button is the one control shape that cannot be
	-- verified without a human. Given how much of this branch turned out to be
	-- built-but-never-connected, the primary path should be one that can be
	-- tested. Enter is free during play: R reloads, 1-4 switch, shift sprints.
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or input.KeyCode ~= Enum.KeyCode.Return then
			return
		end
		askToRedeploy()
	end)

	-- Run summary. Extraction is the win condition and until now it produced
	-- nothing on screen at all: the server fired `playerExtracted` with the
	-- banked value and this handler dropped it, so succeeding was quieter than
	-- dying. The card is the payoff moment.
	summaryPanel = Instance.new("Frame")
	summaryPanel.Size = UDim2.new(0, 420, 0, 132)
	summaryPanel.Position = UDim2.new(0.5, -210, 0.5, -110)
	summaryPanel.BackgroundColor3 = Color3.fromRGB(20, 22, 27)
	summaryPanel.BackgroundTransparency = 0.12
	summaryPanel.BorderSizePixel = 0
	summaryPanel.Visible = false
	summaryPanel.ZIndex = 7
	summaryPanel.Parent = root

	local summaryStroke = Instance.new("UIStroke")
	summaryStroke.Color = ACCENT
	summaryStroke.Thickness = 1
	summaryStroke.Transparency = 0.5
	summaryStroke.Parent = summaryPanel

	summaryTitle = makeLabel(summaryPanel, UDim2.new(1, -32, 0, 40), UDim2.new(0, 16, 0, 14), 28, Enum.TextXAlignment.Center)
	summaryTitle.ZIndex = 8
	summaryBody = makeLabel(summaryPanel, UDim2.new(1, -32, 0, 66), UDim2.new(0, 16, 0, 56), 17, Enum.TextXAlignment.Center)
	summaryBody.ZIndex = 8
	summaryBody.TextWrapped = true

	-- Transient banner for things that happen mid-run and matter: a pad opening
	-- is a state change the player has been counting down to, and it was only
	-- ever visible as the pad line quietly changing colour.
	bannerLabel = makeLabel(root, UDim2.new(0, 620, 0, 30), UDim2.new(0.5, -310, 0, 128), 22, Enum.TextXAlignment.Center)
	bannerLabel.TextColor3 = GOOD
	bannerLabel.Visible = false
	bannerLabel.ZIndex = 7

	-- Hints sit under the vitals line, where the player is already looking for
	-- ammo when they run dry.
	hintLabel = makeLabel(root, UDim2.new(0, 420, 0, 22), UDim2.new(1, -444, 1, -32), 15, Enum.TextXAlignment.Right)
	hintLabel.TextColor3 = ACCENT
	hintLabel.Visible = false
	hintUntil = os.clock() + HINT_SECONDS

	meleeBack = Instance.new("Frame")
	meleeBack.Size = UDim2.new(0, 320, 0, 3)
	meleeBack.Position = UDim2.new(0, 24, 1, -37)
	meleeBack.BackgroundColor3 = Color3.fromRGB(48, 50, 56)
	meleeBack.BorderSizePixel = 0
	meleeBack.Parent = root

	meleeBar = Instance.new("Frame")
	meleeBar.Size = UDim2.new(1, 0, 1, 0)
	meleeBar.BackgroundColor3 = ACCENT
	meleeBar.BorderSizePixel = 0
	meleeBar.Parent = meleeBack

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
		if typeof(payload) ~= "table" then
			return
		end

		-- Everything except the bark used to fall out of this handler on the
		-- first line, so extraction, run end and pad openings all arrived and
		-- were discarded.
		if payload.kind == "padOpened" then
			bannerLabel.Text = string.format("%s PAD OPEN", string.upper(tostring(payload.zone)))
			bannerLabel.TextColor3 = GOOD
			bannerUntil = os.clock() + BANNER_SECONDS
			return
		elseif payload.kind == "playerExtracted" then
			if payload.playerId == player.UserId then
				HudController.showSummary(true, payload.zone, payload.value or 0)
			else
				bannerLabel.Text = "A SQUADMATE EXTRACTED"
				bannerLabel.TextColor3 = DIM
				bannerUntil = os.clock() + BANNER_SECONDS
			end
			return
		elseif payload.kind == "playerDied" then
			if payload.playerId == player.UserId then
				HudController.showSummary(false, nil, payload.droppedValue or 0)
			end
			return
		elseif payload.kind == "runEnded" then
			return
		end

		if payload.kind ~= "overseerBark" then
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

	Remotes.event("DamageFrom").OnClientEvent:Connect(function(payload: any)
		if typeof(payload) ~= "table" or typeof(payload.from) ~= "Vector3" then
			return
		end
		HudController.showDamageFrom(payload.from)
	end)

	Remotes.event("RunState").OnClientEvent:Connect(function(payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		latest.canRedeploy = payload.canRedeploy == true
		latest.endReason = payload.endReason
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
