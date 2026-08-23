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

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")

local NetcodeConfig = require(Shared.config.Netcode)
local Interpolator = require(Shared.core.net.Interpolator)
local Snapshot = require(Shared.core.net.Snapshot)
local Types = require(Shared.core.Types)
local Remotes = require(Shared.net.Remotes)
local Lod = require(Shared.core.anim.Lod)
local StepPlanner = require(Shared.core.anim.StepPlanner)
local TwoBoneIk = require(Shared.core.anim.TwoBoneIk)
local RigsConfig = require(Shared.config.Rigs)
local EntityRig = require("./EntityRig")

local EntityRenderer = {}

local COLORS: { [string]: Color3 } = {
	Skitter = Color3.fromRGB(200, 90, 70),
	Sentry = Color3.fromRGB(90, 130, 200),
	Hauler = Color3.fromRGB(150, 120, 60),
	Lancer = Color3.fromRGB(120, 190, 130),
	Warden = Color3.fromRGB(190, 120, 210),
	Reclaimer = Color3.fromRGB(230, 60, 60),
}

--- Material carries the fiction: the swarm is soft, the turret is metal, the
--- Warden is armoured.
local KIND_MATERIAL: { [string]: Enum.Material } = {
	Skitter = Enum.Material.SmoothPlastic,
	Sentry = Enum.Material.DiamondPlate,
	Hauler = Enum.Material.Metal,
	Lancer = Enum.Material.Foil,
	Warden = Enum.Material.Slate,
	Reclaimer = Enum.Material.CorrodedMetal,
}

local HIT_FLASH_SECONDS = 0.08
local HIT_FLASH_COLOR = Color3.fromRGB(255, 250, 235)
local WOUNDED_COLOR = Color3.fromRGB(70, 20, 18)
local DEATH_FADE_SECONDS = 0.9

type Visual = { lastHp: number, flashUntil: number, deathAt: number }
local visuals: { [number]: Visual } = {}

local interp = Interpolator.new()
local origin: Types.Vec3 = { x = 0, y = 0, z = 0 }

--- Raw authoritative state as of the last packet, mirroring the server's
--- per-client baseline. Kept separate from the interpolation buffer on purpose:
--- deltas must be applied to what the server actually sent, never to an
--- interpolated or extrapolated sample. An earlier version rebuilt the baseline
--- by sampling the interpolator at `now`, which extrapolates up to 80ms past
--- the newest frame — and because each packet then re-extrapolated from the
--- previous extrapolation, the error compounded until entities raced ahead of
--- their true position and stuck there. Static targets hid it completely
--- (zero velocity makes extrapolation a no-op), so it only appeared against a
--- moving one.
local baseline: { Types.EntityView } = {}

local folder: Folder? = nil
local active: { [number]: EntityRig.Rig } = {}
local connection: RBXScriptConnection? = nil

local stats = {
	snapshotsReceived = 0,
	bytesReceived = 0,
	extrapolatedFrames = 0,
	renderedFrames = 0,
	decodeErrors = 0,
	rejectedFrames = 0,
}

--------------------------------------------------------------------------------
-- M7-3: procedural locomotion, LOD'd, with a hard per-frame raycast budget.
--------------------------------------------------------------------------------

--- Gait profile per kind, read from the rig body plan so the legs the planner
--- steps are exactly the legs the renderer draws. Previously one generic
--- quadruped drove every kind while the geometry was a single box, so the two
--- could not disagree; now they can, and sharing one source is what stops them.
local GAIT: { [string]: { offsets: { Types.Vec3 }, groups: { number } } } = {}
for kind, spec in RigsConfig :: any do
	local offsets: { Types.Vec3 } = {}
	local groups: { number } = {}
	for index, leg in spec.legs do
		offsets[index] = Types.vec3(leg.offset.x, leg.offset.y, leg.offset.z)
		groups[index] = leg.group
	end
	GAIT[kind] = { offsets = offsets, groups = groups }
end

local POLE = Types.vec3(0, 1, 0)

type Locomotion = {
	gait: StepPlanner.GaitState,
	lastPos: Types.Vec3,
	--- Last ground height this entity resolved, reused on frames where the
	--- raycast budget did not reach it. docs/08: invisible at those distances.
	groundY: number,
}

local locomotion: { [number]: Locomotion } = {}
local frameIndex = 0

local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude
raycastParams.IgnoreWater = true

--- Per-frame profiling, surfaced through getStats() and sampled into
--- perf.tick telemetry so the client numbers land beside the server ones.
local profile = {
	raycastsThisFrame = 0,
	raycastsPeak = 0,
	interpolationMs = 0,
	animationMs = 0,
	raycastMs = 0,
	totalMs = 0,
	samples = 0,
	tiers = { full = 0, reduced = 0, clip = 0, culled = 0 },
}

local function groundAtFactory(entityId: number, mayCast: boolean): (Types.Vec3) -> Types.Vec3
	return function(desired: Types.Vec3): Types.Vec3
		local loco = locomotion[entityId]
		if not mayCast or profile.raycastsThisFrame >= Lod.RAYCAST_BUDGET then
			-- Budget exhausted or this entity was not granted one: reuse the
			-- last known plane rather than skipping the step entirely, which
			-- would freeze the gait instead of merely dating it.
			return Types.vec3(desired.x, if loco then loco.groundY else desired.y, desired.z)
		end
		profile.raycastsThisFrame += 1
		local origin = Vector3.new(desired.x, desired.y + 6, desired.z)
		local result = workspace:Raycast(origin, Vector3.new(0, -24, 0), raycastParams)
		local y = if result then result.Position.Y else (if loco then loco.groundY else desired.y)
		if loco then
			loco.groundY = y
		end
		return Types.vec3(desired.x, y, desired.z)
	end
end

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

local function release(id: number)
	local rig = active[id]
	if rig == nil then
		return
	end
	active[id] = nil
	-- Cleared with the rig, not left behind: a stale entry would make a
	-- recycled id inherit the previous occupant's health and flash on spawn.
	visuals[id] = nil
	locomotion[id] = nil
	EntityRig.release(rig)
end

function EntityRenderer.setOrigin(newOrigin: Types.Vec3)
	origin = newOrigin
end

--- M7-10: per-subsystem frame cost, plus the LOD census that produced it.
--- A profile without the population it was measured against is not a number
--- anyone can act on.
function EntityRenderer.getProfile(): { [string]: any }
	return {
		raycastsThisFrame = profile.raycastsThisFrame,
		raycastsPeak = profile.raycastsPeak,
		raycastBudget = Lod.RAYCAST_BUDGET,
		interpolationMs = profile.interpolationMs,
		animationMs = profile.animationMs,
		totalMs = profile.totalMs,
		frames = profile.samples,
		tiers = profile.tiers,
		activeEntities = (function()
			local n = 0
			for _ in active do
				n += 1
			end
			return n
		end)(),
	}
end

function EntityRenderer.resetProfile()
	profile.raycastsPeak = 0
	profile.samples = 0
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
		-- A keyframe replaces the world; a delta merges onto the raw baseline.
		local peek = Snapshot.decode(packet, origin)
		if peek.isKeyframe then
			return peek
		end
		return Snapshot.applyDelta(baseline, packet, origin)
	end)

	if not ok then
		-- A corrupt packet is a dropped packet, not a crashed client.
		stats.decodeErrors += 1
		return
	end

	baseline = (decoded :: Snapshot.Snapshot).entities
	Interpolator.push(interp, now, baseline)

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

local function render(dt: number)
	local frameStart = os.clock()
	frameIndex += 1
	profile.raycastsThisFrame = 0

	local renderTime = workspace:GetServerTimeNow() - interp.renderDelay
	local seen: { [number]: boolean } = {}
	stats.renderedFrames += 1

	local camera = workspace.CurrentCamera
	local eye = if camera then camera.CFrame.Position else Vector3.zero

	debug.profilebegin("deepcache/interpolate")
	local interpStart = os.clock()
	local samples: { [number]: any } = {}
	local candidates: { Lod.Candidate } = {}
	for _, id in Interpolator.knownIds(interp) do
		local sample = Interpolator.sample(interp, id, renderTime)
		if sample == nil then
			continue
		end
		seen[id] = true
		samples[id] = sample
		if sample.extrapolated then
			stats.extrapolatedFrames += 1
		end

		local rig = active[id]
		if rig == nil then
			-- Kind arrives in the snapshot's spare state bits, so a Warden gets
			-- a Warden's body plan rather than a generic box.
			rig = EntityRig.acquire(sample.kind, container())
			rig.model.Name = `Entity_{id}`
			active[id] = rig
			visuals[id] = { lastHp = sample.hpPct, flashUntil = 0, deathAt = 0 }
			local profileFor = GAIT[sample.kind] or GAIT.Skitter
			locomotion[id] = {
				gait = StepPlanner.new(profileFor.offsets, profileFor.groups),
				lastPos = Types.vec3(sample.pos.x, sample.pos.y, sample.pos.z),
				groundY = sample.pos.y,
			}
		end

		local look = visuals[id]
		local now = os.clock()

		-- Took damage since the last frame: flash. Without this there is no
		-- feedback that a shot connected -- the enemy just silently has less
		-- health, which reads as the weapon not working.
		if look ~= nil and sample.hpPct < look.lastHp - 1e-4 then
			look.flashUntil = now + HIT_FLASH_SECONDS
		end
		if look ~= nil then
			look.lastHp = sample.hpPct
		end

		local scale, transparency = 1, 0

		if sample.state == "death" then
			-- Corpses collapse and fade over their lifetime rather than
			-- blinking out, so a kill reads as a kill.
			if look ~= nil and look.deathAt == 0 then
				look.deathAt = now
			end
			local age = if look ~= nil then now - look.deathAt else 0
			local t = math.clamp(age / DEATH_FADE_SECONDS, 0, 1)
			scale = 1 - 0.55 * t
			transparency = 0.15 + 0.75 * t
		elseif sample.state == "spawn" then
			-- Materialise instead of popping in.
			scale = 0.6
			transparency = 0.5
		end

		local colour, material
		if look ~= nil and now < look.flashUntil then
			colour = HIT_FLASH_COLOR
			material = Enum.Material.Neon
		else
			colour = COLORS[sample.kind] or COLORS.Skitter
			material = KIND_MATERIAL[sample.kind] or Enum.Material.SmoothPlastic
			-- Damage tint: darken toward the low-health colour as it bleeds
			-- out, so a nearly-dead enemy is worth pushing rather than
			-- guessing about.
			if sample.state ~= "death" and sample.hpPct < 0.999 then
				colour = colour:Lerp(WOUNDED_COLOR, (1 - sample.hpPct) * 0.6)
			end
		end
		EntityRig.setLook(rig, colour, material, transparency)
		EntityRig.setBody(rig, Vector3.new(sample.pos.x, sample.pos.y, sample.pos.z), sample.yaw, scale)

		table.insert(candidates, {
			id = id,
			distance = (Vector3.new(sample.pos.x, sample.pos.y, sample.pos.z) - eye).Magnitude,
		})
	end
	profile.interpolationMs = (os.clock() - interpStart) * 1000
	debug.profileend()

	-- Allocate the frame's raycasts before any gait runs, so the budget is a
	-- decision made once with the whole population in view rather than a
	-- first-come-first-served race between entities.
	local granted = Lod.allocateRaycasts(candidates)
	profile.tiers = Lod.census(candidates)

	debug.profilebegin("deepcache/animation")
	local animStart = os.clock()
	for _, candidate in candidates do
		local id = candidate.id
		local loco = locomotion[id]
		local sample = samples[id]
		if loco == nil or sample == nil then
			continue
		end
		local tier = Lod.tierFor(candidate.distance)
		if not Lod.shouldStepGait(tier, frameIndex) then
			continue
		end

		local bodyPos = Types.vec3(sample.pos.x, sample.pos.y, sample.pos.z)
		local velocity = Types.scaleVec3(Types.subVec3(bodyPos, loco.lastPos), if dt > 0 then 1 / dt else 0)
		loco.lastPos = bodyPos

		-- Only the `full` tier is eligible for a ray at all, and even then only
		-- if the allocator granted it one this frame.
		local mayCast = tier == "full" and granted[id] == true
		StepPlanner.step(loco.gait, bodyPos, velocity, dt, groundAtFactory(id, mayCast))

		-- IK runs only at the full tier: at 40+ studs the joint position is
		-- sub-pixel and solving it is pure cost. Beyond `reduced` the legs are
		-- hidden outright, so there is nothing for a solution to drive.
		local rig = active[id]
		if rig == nil then
			continue
		end
		local showLegs = tier == "full" or tier == "reduced"
		EntityRig.setLegsVisible(rig, showLegs)

		if showLegs then
			local spec = rig.spec
			-- Hips rotate with the body; the planner works in world space, so
			-- the rest offset has to be rotated to match before it is a hip.
			local yawCf = CFrame.Angles(0, sample.yaw, 0)
			local bodyVec = Vector3.new(bodyPos.x, bodyPos.y, bodyPos.z)
			for index, leg in loco.gait.legs do
				local limb = rig.limbs[index]
				if limb == nil then
					continue
				end
				local footV = StepPlanner.footPosition(leg)
				local foot = Vector3.new(footV.x, footV.y, footV.z)
				local rotated = yawCf:VectorToWorldSpace(
					Vector3.new(leg.restOffset.x, leg.restOffset.y, leg.restOffset.z)
				)
				-- Hip sits at the body, not at the resting foot height: the Y
				-- of a rest offset is where the *foot* rests, and using it for
				-- the hip would sink every joint into the floor.
				local hip = bodyVec + Vector3.new(rotated.X, spec.bodyOffsetY * 0.4, rotated.Z)
				local knee: Vector3
				if tier == "full" then
					local kneeV = TwoBoneIk.solve(
						Types.vec3(hip.X, hip.Y, hip.Z),
						Types.vec3(foot.X, foot.Y, foot.Z),
						spec.upperLength,
						spec.lowerLength,
						POLE
					)
					knee = Vector3.new(kneeV.x, kneeV.y, kneeV.z)
				else
					-- `reduced`: straight-line pose, no law of cosines. At 40+
					-- studs the bend is sub-pixel, but the limbs still have to
					-- be *placed* -- an entity that never reached `full` would
					-- otherwise keep the CFrame it was built with and stretch
					-- its legs to the world origin.
					knee = hip:Lerp(foot, 0.5)
				end
				EntityRig.placeLimb(limb, hip, knee, foot)
			end
		end
	end
	profile.animationMs = (os.clock() - animStart) * 1000
	debug.profileend()

	-- Anything the server stopped mentioning entirely.
	for id in active do
		if not seen[id] then
			release(id)
		end
	end

	if profile.raycastsThisFrame > profile.raycastsPeak then
		profile.raycastsPeak = profile.raycastsThisFrame
	end
	profile.totalMs = (os.clock() - frameStart) * 1000
	profile.samples += 1
end

function EntityRenderer.start()
	assert(connection == nil, "EntityRenderer.start: already running")

	Remotes.unreliable("Snapshot").OnClientEvent:Connect(onSnapshot)
	Remotes.event("Despawn").OnClientEvent:Connect(onDespawn)

	-- RenderStepped, not Heartbeat: interpolation should produce a fresh
	-- position for the frame actually being drawn.
	-- Ground rays must not hit the entities themselves, or every leg resolves
	-- to the top of its own body part and the gait plants feet in mid-air.
	-- Ragdolls are excluded for the same reason: a corpse under a walking
	-- entity would raise its feet onto the body.
	local excluded: { Instance } = { container() }
	local ragdolls = workspace:FindFirstChild("DeepcacheRagdolls")
	if ragdolls then
		table.insert(excluded, ragdolls)
	end
	local character = Players.LocalPlayer.Character
	if character then
		table.insert(excluded, character)
	end
	raycastParams.FilterDescendantsInstances = excluded

	connection = RunService.RenderStepped:Connect(render)

	-- M7-10 needs the RUNNING renderer's profile, and require() from the
	-- command bar returns a fresh idle copy whose counters are all zero. Same
	-- bridge pattern as LookController and RagdollController.
	local existingBridge = Players.LocalPlayer:FindFirstChild("DeepcacheRenderDiagnostics")
	if existingBridge then
		existingBridge:Destroy()
	end
	local bridge = Instance.new("BindableFunction")
	bridge.Name = "DeepcacheRenderDiagnostics"
	bridge.OnInvoke = function(action: string): any
		if action == "resetProfile" then
			EntityRenderer.resetProfile()
		end
		local info = EntityRenderer.getProfile()
		info.stats = EntityRenderer.getStats()

		-- Where entities are lost between the wire and the screen. The three
		-- counts should agree; whichever one drops first names the layer.
		info.baselineCount = #baseline
		local known = Interpolator.knownIds(interp)
		info.knownIdCount = #known
		local sampled, renderTime = 0, workspace:GetServerTimeNow() - interp.renderDelay
		local perId: { string } = {}
		for _, id in known do
			local s = Interpolator.sample(interp, id, renderTime)
			if s ~= nil then
				sampled += 1
			end
			table.insert(perId, string.format("%d:%s", id, if s ~= nil then "ok" else "NIL"))
		end
		info.sampledCount = sampled
		info.perId = perId
		info.renderDelay = interp.renderDelay
		return info
	end
	bridge.Parent = Players.LocalPlayer
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
