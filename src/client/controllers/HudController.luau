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
	sees or could show unfiltered text). `threatTier` [1,5] drives a
	`ColorCorrectionEffect` under `Lighting`: contrast and saturation climb
	and the tint shifts warmer as tier rises, tweened rather than snapped so
	a tier change reads as escalation, not a flicker.
]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")

local Remotes = require(Shared.net.Remotes)
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

--- docs/05: threatTier [1,5] drives lighting. Calm and cool at 1, saturated
--- and warm at 5 -- tuned to be visibly, not subtly, different at the
--- extremes, since "threat tier 5 visibly shifts the post stack" is the
--- literal M4-9 acceptance criterion.
local TIER_TINT: { [number]: Color3 } = {
	[1] = Color3.fromRGB(205, 220, 235),
	[2] = Color3.fromRGB(220, 220, 215),
	[3] = Color3.fromRGB(235, 210, 190),
	[4] = Color3.fromRGB(240, 175, 150),
	[5] = Color3.fromRGB(255, 120, 100),
}
local TIER_CONTRAST: { [number]: number } = { [1] = -0.1, [2] = -0.02, [3] = 0.06, [4] = 0.18, [5] = 0.32 }
local TIER_SATURATION: { [number]: number } = { [1] = -0.2, [2] = -0.05, [3] = 0.05, [4] = 0.18, [5] = 0.35 }
local TIER_TWEEN_INFO = TweenInfo.new(2.5, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
local COMMS_DISPLAY_SECONDS = 10

local gui: ScreenGui? = nil
local clockLabel: TextLabel
local weightLabel: TextLabel
local weightBar: Frame
local padLabel: TextLabel
local statusLabel: TextLabel
local vitalsLabel: TextLabel
local commsLabel: TextLabel
local colorCorrection: ColorCorrectionEffect
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
local function applyThreatTier(tier: number)
	local clamped = math.clamp(math.floor(tier + 0.5), 1, 5)
	TweenService:Create(colorCorrection, TIER_TWEEN_INFO, {
		TintColor = TIER_TINT[clamped],
		Contrast = TIER_CONTRAST[clamped],
		Saturation = TIER_SATURATION[clamped],
	}):Play()
end

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
	vitalsLabel.Text = string.format("HP %3d", hp)
	vitalsLabel.TextColor3 = if hp <= 25 then ALERT else DIM
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

	weightLabel = makeLabel(weightPanel, UDim2.new(1, 0, 0, 26), UDim2.new(0, 0, 0, 0), 20, Enum.TextXAlignment.Left)
	statusLabel = makeLabel(root, UDim2.new(0, 520, 0, 22), UDim2.new(0, 24, 1, -30), 16, Enum.TextXAlignment.Left)
	vitalsLabel = makeLabel(root, UDim2.new(0, 200, 0, 30), UDim2.new(1, -224, 1, -60), 24, Enum.TextXAlignment.Right)

	-- M4-9 comms panel: OVERSEER's filtered barks, top-of-screen, below the
	-- clock so it never overlaps the number the player is reading fastest.
	commsLabel = makeLabel(root, UDim2.new(0, 600, 0, 28), UDim2.new(0.5, -300, 0, 96), 17, Enum.TextXAlignment.Center)
	commsLabel.TextColor3 = COMMS_COLOR
	commsLabel.Font = Enum.Font.Code
	commsLabel.RichText = false -- server text is filtered, not markup-safe; never interpret it as rich text
	commsLabel.Visible = false

	-- M4-9 threat-tier lighting hook. Reuses an existing effect if the level
	-- (or Studio authoring) already has one rather than creating a duplicate
	-- that would fight it for the same visual slot.
	local existingEffect = Lighting:FindFirstChildOfClass("ColorCorrectionEffect")
	if existingEffect then
		colorCorrection = existingEffect
	else
		local created = Instance.new("ColorCorrectionEffect")
		created.Name = "OverseerThreatTier"
		created.Parent = Lighting
		colorCorrection = created
	end
	applyThreatTier(2) -- BUILD's baseline tier, so the level doesn't start mid-tween from defaults

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
			applyThreatTier(payload.threatTier)
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
