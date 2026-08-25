--!strict
--[[
	Client-side weapon prediction and reconciliation.

	The client draws the shot immediately — muzzle flash, tracer, recoil,
	ammo decrement, hitmarker — and sends a request. When the authoritative
	result arrives it corrects *state*, never presentation.

	That distinction is the whole design: un-drawing a tracer the player already
	saw looks worse than the inconsistency it fixes. So a rejected shot removes
	the hitmarker and restores ammo, and leaves the tracer alone.

	Also the measurement point for two headline metrics: hit-registration RTT
	and mispredict rate.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")

local WeaponsConfig = require(Shared.config.Weapons)
local Remotes = require(Shared.net.Remotes)
local Wire = require(Shared.net.Wire)
local Types = require(Shared.core.Types)
local Raycast = require(Shared.core.sim.Raycast)
local EntityRenderer = require("./EntityRenderer")

local PredictionController = {}

type Pending = {
	seq: number,
	sentAt: number,
	predictedHit: boolean,
	weaponId: string,
}

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

--- Where a shot is aimed, and where it starts.
---
--- Both used to come from the camera, which is wrong in third person for two
--- separate reasons. The camera sits about ten studs behind the character, so
--- the drawn tracer began in mid-air behind the player; and the server rejects
--- an origin further than `ORIGIN_TOLERANCE` (8 studs) from the character and
--- substitutes its own, so the server was already firing from the character
--- while the client drew from the camera. They disagreed on every shot.
---
--- Now: the aim point is where the *mouse* points, found by casting the
--- camera's ray through the cursor, and the shot leaves the character's
--- shoulder toward it. Client and server then agree, and the crosshair
--- (which follows the cursor) tells the truth about where rounds go.
local aimParams = RaycastParams.new()
aimParams.FilterType = Enum.RaycastFilterType.Exclude
aimParams.IgnoreWater = true

local AIM_RANGE = 2000

local function shoulderOrigin(root: BasePart): Vector3
	return root.Position + Vector3.new(0, 1.2, 0)
end

--- World point the cursor is over. Falls back to a far point along the ray
--- when the cursor is over open sky, so aiming at nothing still fires forward
--- rather than refusing.
--- Entity states a shot passes through, matching what the server refuses to
--- register a hit against. Aiming at a corpse would otherwise pull the shot off
--- the live enemy standing behind it.
local AIM_SKIP_STATES: { [Types.EntityStateName]: boolean } = { death = true, spawn = true }

local function aimPoint(): Vector3
	local mouse = UserInputService:GetMouseLocation()
	-- GetMouseLocation is in viewport space including the inset; ScreenPointToRay
	-- expects the same, so no adjustment is needed.
	local ray = camera:ViewportPointToRay(mouse.X, mouse.Y)
	local exclude: { Instance } = {}
	if player.Character then
		table.insert(exclude, player.Character)
	end
	local effects = workspace:FindFirstChild("DeepcacheEffects")
	if effects then
		table.insert(exclude, effects)
	end
	aimParams.FilterDescendantsInstances = exclude

	local hit = workspace:Raycast(ray.Origin, ray.Direction * AIM_RANGE, aimParams)
	local geometryDistance = if hit then hit.Distance else AIM_RANGE

	-- Enemies are invisible to the engine's raycaster: their rig parts are
	-- `CanQuery = false`, so the cast above sails through them onto the floor
	-- behind. Firing from the shoulder at that far point misses, because the
	-- camera is roughly ten studs behind the shoulder and the parallax between
	-- the two grows with distance to the aim point. So test the entity spheres
	-- explicitly, with the same pure math the server will use to judge the
	-- shot -- one implementation, so client and server cannot disagree about
	-- what the cursor was over.
	local views, radii = EntityRenderer.aimTargets()
	local entityHit = Raycast.nearestEntity(
		Wire.toVec3(ray.Origin),
		Wire.toVec3(ray.Direction.Unit),
		views,
		radii,
		geometryDistance,
		AIM_SKIP_STATES
	)
	if entityHit ~= nil then
		return Vector3.new(entityHit.point.x, entityHit.point.y, entityHit.point.z)
	end

	return if hit then hit.Position else ray.Origin + ray.Direction * AIM_RANGE
end

local pending: { [number]: Pending } = {}
local nextSeq = 1
local currentWeapon = "Sidearm"
local ammo: { [string]: number } = {}
local lastFireAt = 0

local rttSamples: { number } = {}
local stats = {
	fired = 0,
	confirmed = 0,
	mispredicted = 0,
	rejected = 0,
}

--- Presentation hooks. Bootstrap wires these to the effects layer; keeping
--- them injectable means this controller has no opinion about visuals and can
--- be driven headlessly in a smoke test.
local hooks = {
	onTracer = function(_origin: Vector3, _hitPos: Vector3) end,
	onHitmarker = function(_confirmed: boolean) end,
	onRemoveHitmarker = function() end,
	onAmmoChanged = function(_weaponId: string, _ammo: number) end,
	onWeaponChanged = function(_weaponId: string, _ammo: number) end,
	onReloadStateChanged = function(_weaponId: string, _reloading: boolean, _seconds: number) end,
}

--- Set while the server has a reload in flight for the held weapon. Firing is
--- refused server-side during it anyway; tracking it here stops the client
--- sending requests it knows will be rejected, and stops the auto-reload below
--- firing a second request every frame.
local reloading: { [string]: boolean } = {}

--- Number-key bindings, in the order docs/01 lists the weapon table.
local SLOT_KEYS: { [Enum.KeyCode]: string } = {
	[Enum.KeyCode.One] = "Sidearm",
	[Enum.KeyCode.Two] = "Carbine",
	[Enum.KeyCode.Three] = "Slug",
	[Enum.KeyCode.Four] = "Arc",
}

function PredictionController.setHooks(newHooks: { [string]: any })
	for key, fn in newHooks do
		if hooks[key] ~= nil then
			hooks[key] = fn
		end
	end
end

function PredictionController.setWeapon(weaponId: string)
	if (WeaponsConfig :: any)[weaponId] == nil then
		return
	end
	currentWeapon = weaponId
end

--- Ask the server to reload the held weapon. The server owns the timer and the
--- magazine; this only sends the request and lets `ReloadState` come back.
function PredictionController.requestReload()
	local weapon = (WeaponsConfig :: any)[currentWeapon]
	if weapon == nil or weapon.magazine == nil then
		return
	end
	if reloading[currentWeapon] then
		return
	end
	if (ammo[currentWeapon] or 0) >= weapon.magazine then
		return
	end
	Remotes.event("ReloadRequest"):FireServer(currentWeapon)
end

local function percentile(values: { number }, fraction: number): number
	if #values == 0 then
		return 0
	end
	local sorted = table.clone(values)
	table.sort(sorted)
	return sorted[math.clamp(math.ceil(#sorted * fraction), 1, #sorted)]
end

function PredictionController.getStats()
	local mispredictRate = if stats.fired > 0 then stats.mispredicted / stats.fired else 0
	return {
		fired = stats.fired,
		confirmed = stats.confirmed,
		mispredicted = stats.mispredicted,
		rejected = stats.rejected,
		mispredictRate = mispredictRate,
		rttP50 = percentile(rttSamples, 0.50),
		rttP95 = percentile(rttSamples, 0.95),
		rttP99 = percentile(rttSamples, 0.99),
	}
end

--------------------------------------------------------------------------------

local function fire()
	local weapon = (WeaponsConfig :: any)[currentWeapon]
	if weapon == nil then
		return
	end

	local now = workspace:GetServerTimeNow()
	local minInterval = if weapon.rps then 1 / weapon.rps else 0.05
	if now - lastFireAt < minInterval then
		return
	end

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root == nil or not root:IsA("BasePart") then
		return
	end

	if reloading[currentWeapon] then
		return
	end

	local remaining = ammo[currentWeapon]
	if remaining == nil then
		remaining = weapon.magazine
	end
	if remaining <= 0 then
		-- Auto-reload on empty. Without it the weapon simply stops working and
		-- nothing on screen explains why -- which is exactly how it behaved
		-- before reloading existed at all.
		PredictionController.requestReload()
		return
	end

	lastFireAt = now

	local origin = shoulderOrigin(root)
	local target = aimPoint()
	local toTarget = target - origin
	if toTarget.Magnitude < 1e-3 then
		return
	end
	local direction = toTarget.Unit

	-- Predict presentation immediately. This is what makes the shot feel
	-- instant regardless of latency.
	ammo[currentWeapon] = remaining - 1
	hooks.onAmmoChanged(currentWeapon, remaining - 1)
	hooks.onTracer(origin, origin + direction * weapon.range)

	local seq = nextSeq
	nextSeq += 1
	stats.fired += 1

	pending[seq] = {
		seq = seq,
		sentAt = now,
		-- M1 predicts "miss" locally and lets the server confirm hits. A local
		-- hit prediction needs the client-side entity positions the renderer
		-- already holds; wiring that in is an M2 refinement, and predicting
		-- conservatively means a mispredict never shows a hitmarker that did
		-- not happen.
		predictedHit = false,
		weaponId = currentWeapon,
	}

	Remotes.event("FireRequest"):FireServer({
		seq = seq,
		clientTime = now,
		origin = origin,
		direction = direction,
		weaponId = currentWeapon,
	})
end

local function onFireResult(result: Wire.FireResult)
	if typeof(result) ~= "table" or typeof(result.seq) ~= "number" then
		return
	end

	local entry = pending[result.seq]
	if entry == nil then
		return
	end
	pending[result.seq] = nil

	local rtt = (workspace:GetServerTimeNow() - entry.sentAt) * 1000
	table.insert(rttSamples, rtt)
	if #rttSamples > 300 then
		table.remove(rttSamples, 1)
	end

	if result.rejected then
		stats.rejected += 1
		-- Reconcile state: give the round back. The tracer stays drawn.
		local weapon = (WeaponsConfig :: any)[entry.weaponId]
		if result.rejected == "ammo" then
			ammo[entry.weaponId] = 0
		elseif weapon then
			ammo[entry.weaponId] = math.min((ammo[entry.weaponId] or 0) + 1, weapon.magazine)
		end
		hooks.onAmmoChanged(entry.weaponId, ammo[entry.weaponId] or 0)
		if entry.predictedHit then
			hooks.onRemoveHitmarker()
		end
		return
	end

	if result.hit ~= entry.predictedHit then
		stats.mispredicted += 1
	end

	if result.hit then
		stats.confirmed += 1
		hooks.onHitmarker(true)
	elseif entry.predictedHit then
		hooks.onRemoveHitmarker()
	end
end

local function onAmmoSync(payload: Wire.AmmoSync)
	if typeof(payload) ~= "table" or typeof(payload.weaponId) ~= "string" then
		return
	end
	ammo[payload.weaponId] = payload.ammo
	hooks.onAmmoChanged(payload.weaponId, payload.ammo)
end

--------------------------------------------------------------------------------

function PredictionController.start()
	for name, weapon in WeaponsConfig :: any do
		ammo[name] = weapon.magazine
	end
	-- Push the starting weapon once. Seeding `ammo` locally is not enough: the
	-- HUD only ever learns a count from a hook, so without this it reads
	-- "Sidearm 0" from boot until the player fires their first shot.
	hooks.onWeaponChanged(currentWeapon, ammo[currentWeapon] or 0)

	Remotes.event("FireResult").OnClientEvent:Connect(onFireResult)
	Remotes.event("AmmoSync").OnClientEvent:Connect(onAmmoSync)
	Remotes.event("ReloadState").OnClientEvent:Connect(function(payload)
		if typeof(payload) ~= "table" or typeof(payload.weaponId) ~= "string" then
			return
		end
		reloading[payload.weaponId] = payload.reloading == true
		hooks.onReloadStateChanged(
			payload.weaponId,
			payload.reloading == true,
			tonumber(payload.seconds) or 0
		)
	end)

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			fire()
			return
		end

		-- Weapon switching. All four weapons have worked server-side since M2-5
		-- and `setWeapon` has existed since M1, but nothing was ever bound to
		-- it, so a real session could only ever fire the Sidearm. With 88 dps
		-- that made a Warden (700 HP, 15.7 dps) and a Reclaimer (550 HP, 26
		-- dps) unwinnable solo -- they out-damage the time needed to kill them.
		if input.KeyCode == Enum.KeyCode.R then
			PredictionController.requestReload()
			return
		end

		local slot = SLOT_KEYS[input.KeyCode]
		if slot ~= nil then
			PredictionController.setWeapon(slot)
			hooks.onWeaponChanged(slot, ammo[slot] or 0)
		end
	end)
end

--- Exposed for the smoke harness, which drives a shot without real input.
function PredictionController.fireOnce()
	fire()
end

return PredictionController
