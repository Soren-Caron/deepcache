--!strict
--[[ Short-lived world effects: tracers, muzzle flashes, impacts.

	Presentation only, and deliberately client-side: none of this is a fact the
	server needs, and a shot that draws instantly regardless of latency is the
	whole point of the prediction layer it hangs off.

	Everything is pooled and every part is `CanQuery = false`. A tracer that
	participates in raycasts would block the next shot's wall check, which is a
	genuinely confusing bug to chase: the weapon appears to stop working only
	while firing quickly.
]]

local Debris = game:GetService("Debris")
local RunService = game:GetService("RunService")

local Effects = {}

local TRACER_SECONDS = 0.055
local FLASH_SECONDS = 0.045
local IMPACT_SECONDS = 0.20

local container: Folder? = nil

local function folder(): Folder
	if container ~= nil and container.Parent ~= nil then
		return container
	end
	local existing = workspace:FindFirstChild("DeepcacheEffects")
	if existing ~= nil and existing:IsA("Folder") then
		container = existing
		return existing
	end
	local created = Instance.new("Folder")
	created.Name = "DeepcacheEffects"
	created.Parent = workspace
	container = created
	return created
end

local function makePart(): Part
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Parent = folder()
	return part
end

--- A tapered streak along the shot, faded out over a few frames rather than
--- destroyed on a timer. A hard cut at 50 ms reads as a flicker; a fade of the
--- same length reads as a tracer.
function Effects.tracer(origin: Vector3, target: Vector3, color: Color3?)
	local delta = target - origin
	local distance = delta.Magnitude
	if distance < 0.5 then
		return
	end

	local beam = makePart()
	beam.Color = color or Color3.fromRGB(255, 226, 158)
	beam.Size = Vector3.new(0.12, 0.12, distance)
	beam.CFrame = CFrame.lookAt(origin, target) * CFrame.new(0, 0, -distance / 2)
	beam.Transparency = 0.15

	local start = os.clock()
	local connection: RBXScriptConnection
	connection = RunService.RenderStepped:Connect(function()
		local t = (os.clock() - start) / TRACER_SECONDS
		if t >= 1 or beam.Parent == nil then
			connection:Disconnect()
			beam:Destroy()
			return
		end
		beam.Transparency = 0.15 + 0.85 * t
		-- Thins as it fades, so the streak reads as travelling rather than
		-- simply dimming in place.
		beam.Size = Vector3.new(0.12 * (1 - t), 0.12 * (1 - t), distance)
	end)
end

--- A brief bloom at the muzzle plus a real light, so firing in the Vault's
--- heavy fog actually illuminates the room for an instant.
function Effects.muzzleFlash(origin: Vector3)
	local flash = makePart()
	flash.Shape = Enum.PartType.Ball
	flash.Size = Vector3.new(0.55, 0.55, 0.55)
	flash.Color = Color3.fromRGB(255, 236, 190)
	flash.Transparency = 0.1
	flash.CFrame = CFrame.new(origin)

	local light = Instance.new("PointLight")
	light.Brightness = 4
	light.Range = 14
	light.Color = Color3.fromRGB(255, 226, 170)
	light.Parent = flash

	Debris:AddItem(flash, FLASH_SECONDS)
end

--- Impact spark where a shot lands. Called on confirmed hits, so it doubles as
--- world-space feedback that the hitmarker is telling the truth.
function Effects.impact(position: Vector3, normal: Vector3?)
	local spark = makePart()
	spark.Shape = Enum.PartType.Ball
	spark.Size = Vector3.new(0.4, 0.4, 0.4)
	spark.Color = Color3.fromRGB(255, 200, 120)
	spark.CFrame = CFrame.new(position + (normal or Vector3.yAxis) * 0.2)

	local start = os.clock()
	local connection: RBXScriptConnection
	connection = RunService.RenderStepped:Connect(function()
		local t = (os.clock() - start) / IMPACT_SECONDS
		if t >= 1 or spark.Parent == nil then
			connection:Disconnect()
			spark:Destroy()
			return
		end
		local size = 0.4 + 0.9 * t
		spark.Size = Vector3.new(size, size, size)
		spark.Transparency = t
	end)
end

return Effects
