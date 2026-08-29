--!strict
--[[ M7-5 + M7-7. The look pipeline's single owner: the post-processing stack,
	and the EditableImage budget.

	**One owner per property, deliberately.** M4-9 originally drove
	`ColorCorrectionEffect` from `HudController` for threat tier, and this
	controller drives the same effect from the zone preset. Two writers on one
	property means the last one to tween wins, and the result is a stack that
	flickers between two answers -- the exact failure `HudController`'s own
	header warns about ("two sources for one number is how a HUD ends up
	confidently lying"). So the threat tier now arrives here via
	`setThreatTier`, is combined with the zone preset by
	`core/look/LightingBlend`, and only this file ever writes Lighting.

	All the arithmetic is pure and tested (`tests/look.spec.luau`); what is
	left here is genuinely engine work: creating the effects, running the 1.5s
	transition, and holding EditableImage instances.

	**The EditableImage budget is the reason `core/look/ImageBudget` exists as
	a separate pure module.** Exceeding 8 live instances fails at creation with
	a memory-budget error rather than gracefully, so the ledger is consulted
	*before* `Instance.new` is ever called. That way the refusal path is
	provable in unit tests without allocating nine real images and hoping the
	ninth fails the way the docs say it does.
]]

local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")

local ImageBudget = require(Shared.core.look.ImageBudget)
local LightingBlend = require(Shared.core.look.LightingBlend)
local Ramp = require(Shared.core.look.Ramp)
local ZonesConfig = require(Shared.config.Zones)

local LookController = {}

type ZoneName = string

local DEFAULT_ZONE: ZoneName = "Perimeter"

local function presetFor(zone: ZoneName): LightingBlend.Preset
	local entry = (ZonesConfig :: { [string]: any })[zone]
	if entry == nil or entry.lighting == nil then
		return (ZonesConfig :: { [string]: any })[DEFAULT_ZONE].lighting
	end
	return entry.lighting
end

local colorCorrection: ColorCorrectionEffect? = nil
local bloom: BloomEffect? = nil
local atmosphere: Atmosphere? = nil

local currentZone: ZoneName = DEFAULT_ZONE
local fromPreset: LightingBlend.Preset = presetFor(DEFAULT_ZONE)
local toPreset: LightingBlend.Preset = presetFor(DEFAULT_ZONE)
local transitionElapsed = LightingBlend.TRANSITION_SECONDS
local threatTier = 1

local budget = ImageBudget.new()
--- purpose -> the live instance, so release actually destroys it. A budget
--- that decrements a counter without destroying the instance is worse than no
--- budget: it reports capacity that does not exist.
local images: { [string]: EditableImage } = {}
local renderConnection: RBXScriptConnection? = nil
local metrics = { transitions = 0, applied = 0, imageFailures = 0 }

--------------------------------------------------------------------------------
-- Post-processing stack
--------------------------------------------------------------------------------

--- Adopt the existing effect of this class if the place already has one,
--- otherwise make it.
---
--- **Adopting by *class*, not by name, is the point.** Post effects of the
--- same class stack multiplicatively under `Lighting`, so creating
--- "DeepcacheBloom" next to a Studio-authored "Bloom" does not replace it --
--- it doubles it, and the resulting intensity matches no preset in the
--- config. Found exactly that way: a first pass looked up effects by the name
--- this controller gives them, booted into a place that already had a `Bloom`
--- and an `Atmosphere`, and produced two BloomEffects. Searching by class
--- means the number of live effects is one regardless of what the place file
--- happens to contain.
local function adopt<T>(className: string, preferredName: string): T
	local existing = Lighting:FindFirstChildOfClass(className :: any)
	if existing then
		return existing :: any
	end
	local created = Instance.new(className :: any)
	created.Name = preferredName
	created.Parent = Lighting
	return created :: any
end

local function ensureEffects()
	if colorCorrection == nil then
		colorCorrection = adopt("ColorCorrectionEffect", "DeepcacheColorCorrection")
	end
	if bloom == nil then
		bloom = adopt("BloomEffect", "DeepcacheBloom")
	end
	if atmosphere == nil then
		atmosphere = adopt("Atmosphere", "DeepcacheAtmosphere")
	end
end

--- Push a resolved preset onto the engine. The only place Lighting is written.
local function apply(preset: LightingBlend.Preset)
	local cc = colorCorrection
	if cc then
		cc.TintColor = Color3.new(preset.tintR, preset.tintG, preset.tintB)
		cc.Saturation = preset.saturation
		cc.Contrast = preset.contrast
	end
	local bl = bloom
	if bl then
		bl.Intensity = preset.bloom
	end
	local atm = atmosphere
	if atm then
		-- Atmosphere density rises as the fog distance closes in. Mapped from
		-- the same fogEnd the presets already carry rather than adding a
		-- second authored number that could disagree with it.
		atm.Density = math.clamp(0.3 + (180 - preset.fogEnd) / 180 * 0.35, 0, 1)
	end
	Lighting.FogEnd = preset.fogEnd
	Lighting.FogStart = preset.fogEnd * 0.25
	metrics.applied += 1
end

local function tick(dt: number)
	if transitionElapsed < LightingBlend.TRANSITION_SECONDS then
		transitionElapsed = math.min(transitionElapsed + dt, LightingBlend.TRANSITION_SECONDS)
	end
	local alpha = if LightingBlend.TRANSITION_SECONDS <= 0
		then 1
		else transitionElapsed / LightingBlend.TRANSITION_SECONDS
	apply(LightingBlend.resolve(fromPreset, toPreset, alpha, threatTier))
end

--- Begin a 1.5s transition into `zone`. Re-entering the zone already being
--- transitioned to is a no-op, so a stream of zone updates for the same zone
--- does not restart the blend and freeze it near its start.
function LookController.setZone(zone: ZoneName)
	if zone == currentZone then
		return
	end
	-- Start from wherever the blend actually is, not from the previous zone's
	-- preset: interrupting a transition halfway and snapping back to the old
	-- endpoint is a visible jump.
	local alpha = if LightingBlend.TRANSITION_SECONDS <= 0
		then 1
		else math.min(transitionElapsed / LightingBlend.TRANSITION_SECONDS, 1)
	fromPreset = LightingBlend.lerpPreset(fromPreset, toPreset, alpha)
	toPreset = presetFor(zone)
	currentZone = zone
	transitionElapsed = 0
	metrics.transitions += 1

	-- docs/08: the zone palette image is regenerated on zone transition.
	LookController.regenerateZonePalette()
end

--- Threat tier from OVERSEER. Applied on top of whatever the zone blend is
--- currently at, so a tier change is felt immediately rather than waiting out
--- a transition.
function LookController.setThreatTier(tier: number)
	if tier ~= tier then
		return -- NaN: leave the stack where it is
	end
	threatTier = math.clamp(tier, 1, 5)
end

--------------------------------------------------------------------------------
-- EditableImage budget (M7-7)
--------------------------------------------------------------------------------

--- Ask for an EditableImage. Returns nil and a reason when the budget refuses,
--- never throws -- see the header for why that distinction is the whole point.
function LookController.acquireImage(
	purpose: string,
	width: number,
	height: number,
	useReserve: boolean?
): (EditableImage?, string?)
	local existing = images[purpose]
	if existing ~= nil then
		return existing, nil
	end

	local handle, reason = ImageBudget.acquire(budget, purpose, useReserve)
	if handle == nil then
		metrics.imageFailures += 1
		return nil, reason
	end

	local ok, created = pcall(function()
		local AssetService = game:GetService("AssetService")
		return (AssetService :: any):CreateEditableImage({ Size = Vector2.new(width, height) })
	end)
	if not ok or created == nil then
		-- The engine refused even though the ledger allowed it. Give the slot
		-- straight back rather than leaking it -- a budget that counts slots
		-- the engine never granted will refuse allocations that would have
		-- worked, which is a subtler failure than the one being prevented.
		ImageBudget.release(budget, purpose)
		metrics.imageFailures += 1
		return nil, `engine refused: {tostring(created)}`
	end

	images[purpose] = created :: EditableImage
	return images[purpose], nil
end

function LookController.releaseImage(purpose: string): boolean
	local image = images[purpose]
	if image ~= nil then
		pcall(function()
			image:Destroy()
		end)
		images[purpose] = nil
	end
	return ImageBudget.release(budget, purpose)
end

--- Write a ramp across an image's first row. Colours come from the pure
--- `Ramp` module, so what gets drawn is testable without an image.
local function writeRamp(image: EditableImage, ramp: Ramp.Ramp, width: number)
	local pixels = Ramp.rasterize(ramp, width)
	local buffer_ = buffer.create(width * 4)
	for index, color in pixels do
		local offset = (index - 1) * 4
		buffer.writeu8(buffer_, offset, math.floor(color.r * 255 + 0.5))
		buffer.writeu8(buffer_, offset + 1, math.floor(color.g * 255 + 0.5))
		buffer.writeu8(buffer_, offset + 2, math.floor(color.b * 255 + 0.5))
		buffer.writeu8(buffer_, offset + 3, 255)
	end
	pcall(function()
		(image :: any):WritePixelsBuffer(Vector2.zero, Vector2.new(width, 1), buffer_)
	end)
end

LookController.RAMP_WIDTH = 64

--- Rebuild the zone palette image for the current zone. Releases the previous
--- one first: re-acquiring without releasing bleeds one slot per zone change,
--- and the 7th transition would then hit the cap.
function LookController.regenerateZonePalette()
	LookController.releaseImage("zone_palette")
	local image = LookController.acquireImage("zone_palette", LookController.RAMP_WIDTH, 1)
	if image == nil then
		return
	end
	local preset = presetFor(currentZone)
	writeRamp(
		image,
		Ramp.new({
			{ position = 0, color = Ramp.color(preset.tintR * 0.2, preset.tintG * 0.2, preset.tintB * 0.25) },
			{ position = 1, color = Ramp.color(preset.tintR, preset.tintG, preset.tintB) },
		}),
		LookController.RAMP_WIDTH
	)
end

function LookController.describe(): { [string]: any }
	local info = ImageBudget.describe(budget)
	info.zone = currentZone
	info.threatTier = threatTier
	info.transitions = metrics.transitions
	info.applied = metrics.applied
	info.imageFailures = metrics.imageFailures
	info.transitionProgress = math.min(transitionElapsed / LightingBlend.TRANSITION_SECONDS, 1)
	info.fogEnd = Lighting.FogEnd
	info.bloom = if bloom then bloom.Intensity else -1
	return info
end

--- Client-side diagnostics bridge, mirroring `ServerStorage.DeepcacheDiagnostics`.
---
--- Needed for the same reason the server one is: `require`-ing this module
--- from the command bar returns a fresh, idle copy whose `setZone` would move
--- nothing, so there is otherwise no way to drive the *running* controller for
--- a Studio smoke test. A BindableFunction registered from the live context is.
local function installDiagnostics()
	local player = game:GetService("Players").LocalPlayer
	local existing = player:FindFirstChild("DeepcacheLookDiagnostics")
	if existing then
		existing:Destroy()
	end
	local bridge = Instance.new("BindableFunction")
	bridge.Name = "DeepcacheLookDiagnostics"
	bridge.OnInvoke = function(action: string, a: any, b: any): any
		if action == "setZone" then
			LookController.setZone(tostring(a))
			return LookController.describe()
		elseif action == "setThreatTier" then
			LookController.setThreatTier(tonumber(a) or 1)
			return LookController.describe()
		elseif action == "acquireImage" then
			local image, reason = LookController.acquireImage(tostring(a), 8, 1, b == true)
			return { acquired = image ~= nil, reason = reason, info = LookController.describe() }
		elseif action == "releaseImage" then
			return { released = LookController.releaseImage(tostring(a)), info = LookController.describe() }
		elseif action == "releaseAll" then
			LookController.releaseAllImages()
			return LookController.describe()
		end
		return LookController.describe()
	end
	bridge.Parent = player
end

--- The lighting that does not change with zone or threat.
---
--- Set once, here, because this file's header claims to be the only writer of
--- `Lighting` and that claim is load-bearing -- the M7-5 note further up
--- documents what happened when two owners fought over one property.
--- `apply` owns everything the presets blend (tint, saturation, contrast,
--- bloom, fog); this owns the stage those sit on and never touches them.
---
--- The values are what a sealed facility needs rather than what a Roblox place
--- ships with. The default is mid-afternoon (`ClockTime` 14.5) with outdoor
--- ambient at 0.27 -- correct for a baseplate, wrong for a level whose rooms
--- now have lids on them: the sun was doing the lighting, and once the
--- ceilings went on, every interior would have been lit by nothing but a
--- generic grey ambient.
local function applyBaseline()
	-- Night, so the skybox stops pouring daylight through every doorway.
	Lighting.ClockTime = 0
	Lighting.GeographicLatitude = 0
	Lighting.Brightness = 1
	-- Low, and cool rather than neutral grey: the ceiling fixtures are meant to
	-- be the reason you can see, so ambient only has to keep the shadows from
	-- being pure black.
	Lighting.Ambient = Color3.fromRGB(28, 30, 38)
	Lighting.OutdoorAmbient = Color3.fromRGB(18, 20, 28)
	Lighting.EnvironmentDiffuseScale = 0.25
	Lighting.EnvironmentSpecularScale = 0.35
	Lighting.GlobalShadows = true
	-- Fog *colour* is baseline; fog distance belongs to the presets and is
	-- written by `apply`. Splitting them this way means a zone transition
	-- changes how far you can see without also changing what the haze is made
	-- of, which would read as the room repainting itself.
	Lighting.FogColor = Color3.fromRGB(16, 18, 26)
end

function LookController.start()
	ensureEffects()
	applyBaseline()
	fromPreset = presetFor(DEFAULT_ZONE)
	toPreset = presetFor(DEFAULT_ZONE)
	transitionElapsed = LightingBlend.TRANSITION_SECONDS
	apply(LightingBlend.resolve(fromPreset, toPreset, 1, threatTier))

	-- Allocations 2 and 3 from docs/08's table. Held for the session rather
	-- than churned: they do not depend on zone, and re-creating them per
	-- transition is allocation pressure for no benefit.
	local damage = LookController.acquireImage("damage_state", LookController.RAMP_WIDTH, 1)
	if damage then
		writeRamp(damage, Ramp.damageState(), LookController.RAMP_WIDTH)
	end
	local threat = LookController.acquireImage("threat_gradient", LookController.RAMP_WIDTH, 1)
	if threat then
		writeRamp(threat, Ramp.threatTier(), LookController.RAMP_WIDTH)
	end
	LookController.regenerateZonePalette()

	if renderConnection == nil then
		renderConnection = RunService.RenderStepped:Connect(tick)
	end
	installDiagnostics()
end

function LookController.stop()
	if renderConnection then
		renderConnection:Disconnect()
		renderConnection = nil
	end
	for purpose in images do
		LookController.releaseImage(purpose)
	end
end

--- Testing/diagnostics: drop every image without tearing down the stack.
function LookController.releaseAllImages()
	local purposes: { string } = {}
	for purpose in images do
		table.insert(purposes, purpose)
	end
	for _, purpose in purposes do
		LookController.releaseImage(purpose)
	end
end

return LookController
