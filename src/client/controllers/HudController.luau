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
