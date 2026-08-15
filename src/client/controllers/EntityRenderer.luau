--!strict
--[[
	Renders server entities from interpolated snapshots.

	The client draws entities ~100ms in the past. That deliberate lag is what
	makes a dropped packet invisible — there is always a future frame to
	interpolate toward. Every Instance here exists only on this client; the
	server has none.

	Models are pooled. Creating and destroying 40 Instances a second produces
	exactly the kind of GC sawtooth that shows up as stutter, and pooling costs
	one table.
]]

local RunService = game:GetService("RunService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")

local NetcodeConfig = require(Shared.config.Netcode)
local Interpolator = require(Shared.core.net.Interpolator)
local Snapshot = require(Shared.core.net.Snapshot)
local Types = require(Shared.core.Types)
local Remotes = require(Shared.net.Remotes)

local EntityRenderer = {}

local COLORS: { [string]: Color3 } = {
	Skitter = Color3.fromRGB(200, 90, 70),
	Sentry = Color3.fromRGB(90, 130, 200),
	Hauler = Color3.fromRGB(150, 120, 60),
	Lancer = Color3.fromRGB(120, 190, 130),
	Warden = Color3.fromRGB(190, 120, 210),
	Reclaimer = Color3.fromRGB(230, 60, 60),
}

local interp = Interpolator.new()
local origin: Types.Vec3 = { x = 0, y = 0, z = 0 }

local folder: Folder? = nil
local active: { [number]: BasePart } = {}
local pool: { BasePart } = {}
local connection: RBXScriptConnection? = nil

local stats = {
	snapshotsReceived = 0,
	bytesReceived = 0,
	extrapolatedFrames = 0,
	renderedFrames = 0,
}

local function container(): Folder
	if folder then
		return folder
	end
	local created = Instance.new("Folder")
	created.Name = "DeepcacheEntities"
	created.Parent = workspace
	folder = created
	return created
end

local function acquire(): BasePart
	local recycled = table.remove(pool)
	if recycled then
		recycled.Parent = container()
		return recycled
	end

	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Size = Vector3.new(2, 3, 2)
	part.Parent = container()
	return part
end

local function release(id: number)
	local part = active[id]
	if part == nil then
		return
	end
	active[id] = nil
	part.Parent = nil
	table.insert(pool, part)
end

function EntityRenderer.setOrigin(newOrigin: Types.Vec3)
	origin = newOrigin
end

function EntityRenderer.getStats()
	return table.clone(stats)
end

--------------------------------------------------------------------------------

local function onSnapshot(packet: buffer)
	if typeof(packet) ~= "buffer" then
		return
	end

	local now = workspace:GetServerTimeNow()
	stats.snapshotsReceived += 1
	stats.bytesReceived += buffer.len(packet)

	Interpolator.observeArrival(interp, now)

	local ok, decoded = pcall(function()
		-- A keyframe replaces the world; a delta merges onto what we hold.
		local peek = Snapshot.decode(packet, origin)
		if peek.isKeyframe then
			return peek
		end
		local baseline: { Types.EntityView } = {}
		for _, id in Interpolator.knownIds(interp) do
			local sample = Interpolator.sample(interp, id, now)
			if sample then
				baseline[#baseline + 1] = {
					id = id,
					pos = sample.pos,
					yaw = sample.yaw,
					state = sample.state,
					hpPct = 1,
				}
			end
		end
		return Snapshot.applyDelta(baseline, packet, origin)
	end)

	if not ok then
		-- A corrupt packet is a dropped packet, not a crashed client.
		return
	end

	Interpolator.push(interp, now, (decoded :: Snapshot.Snapshot).entities)

	-- Retune render delay from observed jitter roughly once a second.
	if stats.snapshotsReceived % 20 == 0 then
		Interpolator.updateDelay(interp, Interpolator.jitterP95(interp, NetcodeConfig.TICK_SECONDS))
	end
end

local function onDespawn(payload: { ids: { number } })
	if typeof(payload) ~= "table" or typeof(payload.ids) ~= "table" then
		return
	end
	for _, id in payload.ids do
		release(id)
	end
end

--------------------------------------------------------------------------------

local function render()
	local renderTime = workspace:GetServerTimeNow() - interp.renderDelay
	local seen: { [number]: boolean } = {}
	stats.renderedFrames += 1

	for _, id in Interpolator.knownIds(interp) do
		local sample = Interpolator.sample(interp, id, renderTime)
		if sample == nil then
			continue
		end
		seen[id] = true

		if sample.extrapolated then
			stats.extrapolatedFrames += 1
		end

		local part = active[id]
		if part == nil then
			part = acquire()
			part.Name = `Entity_{id}`
			part.Color = COLORS.Skitter
			active[id] = part
		end

		part.CFrame = CFrame.new(sample.pos.x, sample.pos.y, sample.pos.z)
			* CFrame.Angles(0, sample.yaw, 0)
		part.Transparency = if sample.state == "death" then 0.6 else 0
	end

	-- Anything the server stopped mentioning entirely.
	for id in active do
		if not seen[id] then
			release(id)
		end
	end
end

function EntityRenderer.start()
	assert(connection == nil, "EntityRenderer.start: already running")

	Remotes.unreliable("Snapshot").OnClientEvent:Connect(onSnapshot)
	Remotes.event("Despawn").OnClientEvent:Connect(onDespawn)

	-- RenderStepped, not Heartbeat: interpolation should produce a fresh
	-- position for the frame actually being drawn.
	connection = RunService.RenderStepped:Connect(render)
end

function EntityRenderer.stop()
	if connection then
		connection:Disconnect()
		connection = nil
	end
	for id in active do
		release(id)
	end
end

return EntityRenderer
