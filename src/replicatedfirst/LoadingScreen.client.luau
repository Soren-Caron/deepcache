--!strict
--[[ The loading screen. Adapter half of `core/boot/LoadGate`.

	Lives in ReplicatedFirst because that is the only place that runs before
	the DataModel has filled in. Roblox's own loading screen leaves once the
	*engine* is ready, which here is several seconds before there is anything
	to look at: the level is generated server-side and parented to Workspace in
	one go, so until it lands the client renders an unlit black room with the
	HUD floating over it. That reads as a broken game, not a loading one.

	This file owns exactly two things core cannot: reading the gates off the
	DataModel, and drawing. Everything about *when* to let go lives in
	`core/boot/LoadGate` and `config/Boot`.

	Two ordering details that matter:

	  - The backdrop is created **before** `RemoveDefaultLoadingScreen`, so
	    there is never a frame with neither screen up. That frame is the black
	    room, which is the entire thing being fixed.
	  - The `assets` gate is only asked once `world` has opened.
	    `ContentProvider.RequestQueueSize` is legitimately 0 before the level
	    exists, so asking early would latch it instantly and the bar would
	    claim the geometry was ready before the server had even sent it.
]]

local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local BACKDROP = Color3.fromRGB(8, 9, 12)
local ACCENT = Color3.fromRGB(235, 200, 120)
local DIM = Color3.fromRGB(160, 165, 175)
local TRACK = Color3.fromRGB(38, 40, 46)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Drawn first, asked about second. See the header.
local gui = Instance.new("ScreenGui")
gui.Name = "DeepcacheLoading"
gui.IgnoreGuiInset = true
gui.ResetOnSpawn = false
gui.DisplayOrder = 1000
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = playerGui

local backdrop = Instance.new("Frame")
backdrop.Size = UDim2.fromScale(1, 1)
backdrop.BackgroundColor3 = BACKDROP
backdrop.BorderSizePixel = 0
backdrop.Parent = gui

local panel = Instance.new("Frame")
panel.AnchorPoint = Vector2.new(0.5, 0.5)
panel.Position = UDim2.fromScale(0.5, 0.5)
panel.Size = UDim2.new(0, 460, 0, 150)
panel.BackgroundTransparency = 1
panel.Parent = backdrop

local function label(name: string, size: number, colour: Color3, y: number, height: number): TextLabel
	local text = Instance.new("TextLabel")
	text.Name = name
	text.BackgroundTransparency = 1
	text.Font = Enum.Font.Code
	text.TextSize = size
	text.TextColor3 = colour
	text.TextXAlignment = Enum.TextXAlignment.Left
	text.Position = UDim2.new(0, 0, 0, y)
	text.Size = UDim2.new(1, 0, 0, height)
	text.Text = ""
	text.Parent = panel
	return text
end

local title = label("Title", 40, ACCENT, 0, 46)
local tagline = label("Tagline", 15, DIM, 50, 20)

local barTrack = Instance.new("Frame")
barTrack.Name = "Track"
barTrack.Position = UDim2.new(0, 0, 0, 100)
barTrack.Size = UDim2.new(1, 0, 0, 3)
barTrack.BackgroundColor3 = TRACK
barTrack.BorderSizePixel = 0
barTrack.Parent = panel

local barFill = Instance.new("Frame")
barFill.Name = "Fill"
barFill.Size = UDim2.fromScale(0, 1)
barFill.BackgroundColor3 = ACCENT
barFill.BorderSizePixel = 0
barFill.Parent = barTrack

local status = label("Status", 14, DIM, 112, 20)
status.Text = "INITIALISING"

local percent = label("Percent", 14, DIM, 112, 20)
percent.TextXAlignment = Enum.TextXAlignment.Right

ReplicatedFirst:RemoveDefaultLoadingScreen()

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Branding = require(Shared.config.Branding)
local BootConfig = require(Shared.config.Boot)
local LoadGate = require(Shared.core.boot.LoadGate)

title.Text = Branding.gameName
tagline.Text = Branding.tagline

local PARAMS: LoadGate.Params = {
	steps = BootConfig.steps,
	minSeconds = BootConfig.minSeconds,
	timeoutSeconds = BootConfig.timeoutSeconds,
	readyLabel = BootConfig.readyLabel,
}

--- Has the server handed us a level? `seed` is set before the folder is
--- parented, so its presence means the whole build landed rather than a bare
--- folder that is still filling.
local function worldReady(): boolean
	local level = Workspace:FindFirstChild("Level")
	return level ~= nil and level:GetAttribute("seed") ~= nil
end

local function avatarReady(): boolean
	local character = player.Character
	if character == nil then
		return false
	end
	return character:FindFirstChild("HumanoidRootPart") ~= nil
		and character:FindFirstChildOfClass("Humanoid") ~= nil
end

local state = LoadGate.new(os.clock())
local shown = 0
local worldSeen = false
local connection: RBXScriptConnection? = nil

local function fadeOut()
	local info = TweenInfo.new(BootConfig.fadeSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(backdrop, info, { BackgroundTransparency = 1 }):Play()
	TweenService:Create(barTrack, info, { BackgroundTransparency = 1 }):Play()
	TweenService:Create(barFill, info, { BackgroundTransparency = 1 }):Play()
	for _, text in { title, tagline, status, percent } do
		TweenService:Create(text, info, { TextTransparency = 1 }):Play()
	end
	task.delay(BootConfig.fadeSeconds + 0.1, function()
		gui:Destroy()
	end)
end

connection = RunService.RenderStepped:Connect(function(dt: number)
	worldSeen = worldSeen or worldReady()

	local report = LoadGate.update(state, {
		engine = game:IsLoaded(),
		world = worldSeen,
		-- Only meaningful once there is geometry to stream. See the header.
		assets = worldSeen and ContentProvider.RequestQueueSize == 0,
		avatar = avatarReady(),
		systems = player:GetAttribute("dcClientReady") == true,
	}, os.clock(), PARAMS)

	shown = LoadGate.eased(shown, report.progress, dt, BootConfig.barRate)
	barFill.Size = UDim2.fromScale(math.clamp(shown, 0, 1), 1)
	status.Text = report.label
	percent.Text = string.format("%3d%%", math.floor(shown * 100))

	if not report.complete then
		return
	end

	if connection then
		connection:Disconnect()
		connection = nil
	end
	if report.timedOut then
		-- Not cosmetic: it means a gate is wrong and the player saw the black
		-- room anyway, which is the failure this screen exists to prevent.
		warn(
			`[{Branding.gameName}] loading screen timed out after {BootConfig.timeoutSeconds}s `
				.. `on "{report.label}" — releasing anyway`
		)
	end
	fadeOut()
end)
