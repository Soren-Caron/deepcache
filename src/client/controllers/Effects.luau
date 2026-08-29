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
--- Flight time for an enemy bolt, whatever the distance.
local BOLT_SECONDS = 0.11
--- How long the melee arc stays on screen.
local SWEEP_SECONDS = 0.30

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

--- A travelling bolt from a ranged enemy.
---
--- Unlike `tracer`, which is instantaneous because a player's hitscan round
--- is, this one visibly crosses the gap: a Sentry at 45 studs or a Lancer at
--- 55 otherwise damages you from off-screen with nothing to see and no
--- direction to trace back to. The damage has already been resolved
--- server-side, so the flight is a tenth of a second -- long enough to read,
--- short enough that it is not pretending to be dodgeable.
function Effects.enemyBolt(from: Vector3, to: Vector3, colour: Color3?)
	local delta = to - from
	local distance = delta.Magnitude
	if distance < 1 then
		return
	end
	local direction = delta.Unit

	local bolt = makePart()
	bolt.Color = colour or Color3.fromRGB(255, 130, 90)
	bolt.Size = Vector3.new(0.22, 0.22, math.min(3.5, distance * 0.25))
	bolt.Transparency = 0.05

	local light = Instance.new("PointLight")
	light.Brightness = 2
	light.Range = 8
	light.Color = bolt.Color
	light.Parent = bolt

	local start = os.clock()
	local connection: RBXScriptConnection
	connection = RunService.RenderStepped:Connect(function()
		local t = (os.clock() - start) / BOLT_SECONDS
		if t >= 1 or bolt.Parent == nil then
			connection:Disconnect()
			bolt:Destroy()
			return
		end
		local at = from + direction * (distance * t)
		bolt.CFrame = CFrame.lookAt(at, at + direction)
		-- Fades only at the very end, so most of the flight is fully visible.
		bolt.Transparency = 0.05 + 0.95 * math.max(0, (t - 0.75) / 0.25)
	end)
end

--- The melee sweep: a bright arc swept through the ground plane in front of
--- the swinger.
---
--- Built from a handful of thin segments along the arc rather than one mesh,
--- because the shape has to match `config/Melee` exactly -- a visual that
--- disagrees with the hitbox is worse than no visual, since the player learns
--- the wrong reach. Both come from the same numbers, passed down on the wire.
function Effects.meleeSweep(from: Vector3, facingYaw: number, radius: number, arcDegrees: number, colour: Color3?)
	local SEGMENTS = 9
	local arc = math.rad(arcDegrees)
	local tint = colour or Color3.fromRGB(190, 225, 255)
	local parts: { Part } = {}

	for index = 0, SEGMENTS - 1 do
		-- Sweep from one edge of the arc to the other.
		local t = index / (SEGMENTS - 1)
		local angle = facingYaw - arc / 2 + arc * t
		local direction = Vector3.new(math.sin(angle), 0, math.cos(angle))
		local mid = from + direction * (radius * 0.55)

		local blade = makePart()
		blade.Color = tint
		blade.Size = Vector3.new(0.35, 0.35, radius * 0.9)
		blade.CFrame = CFrame.lookAt(mid, mid + direction) 
		blade.Transparency = 0.2
		parts[#parts + 1] = blade
	end

	local start = os.clock()
	local connection: RBXScriptConnection
	connection = RunService.RenderStepped:Connect(function()
		local t = (os.clock() - start) / SWEEP_SECONDS
		if t >= 1 then
			connection:Disconnect()
			for _, part in parts do
				part:Destroy()
			end
			return
		end
		-- Segments reveal in order, so the arc reads as swept rather than as a
		-- fan appearing all at once.
		for index, part in parts do
			local lead = (index - 1) / #parts
            local local_t = math.clamp((t - lead * 0.45) / 0.55, 0, 1)
			part.Transparency = if local_t <= 0 then 1 else 0.2 + 0.8 * local_t
		end
	end)
end

return Effects
