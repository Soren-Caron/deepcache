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

local PredictionController = {}

type Pending = {
	seq: number,
	sentAt: number,
	predictedHit: boolean,
	weaponId: string,
}

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

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

	local remaining = ammo[currentWeapon]
	if remaining == nil then
		remaining = weapon.magazine
	end
	if remaining <= 0 then
		return
	end

	lastFireAt = now

	local origin = camera.CFrame.Position
	local direction = camera.CFrame.LookVector

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

	Remotes.event("FireResult").OnClientEvent:Connect(onFireResult)
	Remotes.event("AmmoSync").OnClientEvent:Connect(onAmmoSync)

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			fire()
		end
	end)
end

--- Exposed for the smoke harness, which drives a shot without real input.
function PredictionController.fireOnce()
	fire()
end

return PredictionController
