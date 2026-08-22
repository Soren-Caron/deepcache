--!strict
--[[ M7-4. Client-side ragdolls, pooled.

	docs/08: ragdoll physics is client-only and never replicated. The server
	sends one `Ragdoll` event per death; each client runs its own simulation
	and the results differ between players, which is correct -- nothing in the
	game reads corpse position, so it costs zero bandwidth to let physics
	disagree.

	The scheduling (which of the 12 slots, when to recycle, what to do when
	they are all busy) lives in `core/anim/RagdollPool` and is unit-tested. All
	that is here is the rig, the impulse, and the collision group.

	**Rigs are created once and reused, never destroyed.** A pool that
	destroyed and re-created parts on each death would defeat its own purpose:
	the reason to pool is that instantiating physics parts mid-firefight is
	exactly when the frame budget is tightest. Recycling means hiding, zeroing
	velocity and re-anchoring -- and un-anchoring on reuse, because a part left
	anchored is a corpse that hangs in the air.

	**The collision group matters as much as the pooling.** docs/08 wants
	ragdolls colliding with world geometry but not with players or each other:
	cheaper, and it stops corpse piles blocking corridors, which in a game
	about extraction routes is a gameplay problem and not a cosmetic one.
]]

local Players = game:GetService("Players")
local PhysicsService = game:GetService("PhysicsService")
local RunService = game:GetService("RunService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")

local RagdollPool = require(Shared.core.anim.RagdollPool)
local Remotes = require(Shared.net.Remotes)

local RagdollController = {}

local COLLISION_GROUP = "DeepcacheRagdoll"
local PART_SIZE = Vector3.new(2, 2, 3)
--- Scales the ledger's damage number into a physics impulse. Tuned so an
--- ordinary killing blow tips a body over rather than launching it.
local IMPULSE_SCALE = 6

local pool = RagdollPool.new()
local rigs: { [number]: BasePart } = {}
local folder: Folder? = nil
local heartbeat: RBXScriptConnection? = nil
local metrics = { received = 0, spawned = 0, recycled = 0 }

local function ensureCollisionGroup()
	-- Registering twice throws, and the client may re-enter start() across a
	-- respawn, so the failure is expected rather than exceptional.
	pcall(function()
		PhysicsService:RegisterCollisionGroup(COLLISION_GROUP)
	end)
	pcall(function()
		-- Not with each other: corpse piles block corridors.
		PhysicsService:CollisionGroupSetCollidable(COLLISION_GROUP, COLLISION_GROUP, false)
		-- Not with players either, for the same reason.
		PhysicsService:CollisionGroupSetCollidable(COLLISION_GROUP, "Default", true)
	end)
end

local function container(): Folder
	if folder and folder.Parent then
		return folder
	end
	local created = Instance.new("Folder")
	created.Name = "DeepcacheRagdolls"
	created.Parent = workspace
	folder = created
	return created
end

--- Build (or fetch) the rig for a pool slot. Created lazily so a session that
--- never sees a death never pays for 12 parts.
local function rigFor(slotIndex: number): BasePart
	local existing = rigs[slotIndex]
	if existing and existing.Parent then
		return existing
	end
	local part = Instance.new("Part")
	part.Name = `Ragdoll_{slotIndex}`
	part.Size = PART_SIZE
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = false
	part.Transparency = 1
	part.Color = Color3.fromRGB(90, 80, 76)
	part.Material = Enum.Material.Slate
	pcall(function()
		part.CollisionGroup = COLLISION_GROUP
	end)
	part.Parent = container()
	rigs[slotIndex] = part
	return part
end

local function hide(slotIndex: number)
	local part = rigs[slotIndex]
	if part == nil then
		return
	end
	part.Transparency = 1
	part.Anchored = true
	part.CanCollide = false
	part.AssemblyLinearVelocity = Vector3.zero
	part.AssemblyAngularVelocity = Vector3.zero
end

local function onRagdoll(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	local entityId = payload.entityId
	local deathPos = payload.deathPos
	if typeof(entityId) ~= "number" or typeof(deathPos) ~= "Vector3" then
		return
	end
	metrics.received += 1

	local now = os.clock()
	local slot, evicted = RagdollPool.acquire(pool, entityId, now)
	if evicted then
		hide(slot.index)
	end

	local part = rigFor(slot.index)
	part.CFrame = CFrame.new(deathPos) * CFrame.Angles(math.random() * 0.4, math.random() * 6.28, math.random() * 0.4)
	part.Transparency = 0
	part.CanCollide = true
	-- Unanchor *after* placing it: unanchoring first lets a frame of gravity
	-- run at the old position, which reads as the corpse teleporting.
	part.Anchored = false
	part.AssemblyLinearVelocity = Vector3.zero
	part.AssemblyAngularVelocity = Vector3.zero

	local direction = if typeof(payload.deathDir) == "Vector3" and payload.deathDir.Magnitude > 0
		then payload.deathDir.Unit
		else Vector3.new(0, 1, 0)
	local magnitude = if typeof(payload.impulseMag) == "number" then payload.impulseMag else 20
	-- Upward component so a body tips and tumbles rather than sliding flat.
	local impulse = (direction + Vector3.new(0, 0.6, 0)) * math.clamp(magnitude, 0, 200) * IMPULSE_SCALE
	part:ApplyImpulse(impulse)
	part:ApplyAngularImpulse(Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5) * magnitude)

	metrics.spawned += 1
end

local function step()
	local freed = RagdollPool.expire(pool, os.clock())
	for _, slotIndex in freed do
		hide(slotIndex)
		metrics.recycled += 1
	end
end

--- Diagnostics bridge, for the same reason LookController has one: `require`
--- from the command bar yields a fresh idle copy, so the running pool can
--- only be inspected through something registered by the live context.
local function installDiagnostics()
	local player = Players.LocalPlayer
	local existing = player:FindFirstChild("DeepcacheRagdollDiagnostics")
	if existing then
		existing:Destroy()
	end
	local bridge = Instance.new("BindableFunction")
	bridge.Name = "DeepcacheRagdollDiagnostics"
	bridge.OnInvoke = function(action: string, a: any): any
		if action == "simulateDeaths" then
			-- Drives the real handler, so what is exercised is the same code
			-- path a server death takes.
			local count = tonumber(a) or 20
            for i = 1, count do
				onRagdoll({
					entityId = 90000 + i,
					kind = "Skitter",
					deathPos = Vector3.new(math.random(-20, 20), 6, math.random(-20, 20)),
					deathDir = Vector3.new(math.random() - 0.5, 0, math.random() - 0.5),
					impulseMag = 30,
					killerWeapon = "Carbine",
				})
				task.wait(2 / math.max(count, 1))
			end
		end
		return RagdollController.describe()
	end
	bridge.Parent = player
end

function RagdollController.describe(): { [string]: any }
	local info = RagdollPool.describe(pool)
	info.received = metrics.received
	info.spawnedRigs = metrics.spawned
	info.recycledRigs = metrics.recycled
	local live = 0
	for _, part in rigs do
		if part.Parent and part.Transparency < 1 then
			live += 1
		end
	end
	info.visibleRigs = live
	return info
end

function RagdollController.start()
	ensureCollisionGroup()
	Remotes.event("Ragdoll").OnClientEvent:Connect(onRagdoll)
	if heartbeat == nil then
		heartbeat = RunService.Heartbeat:Connect(step)
	end
	installDiagnostics()
end

function RagdollController.stop()
	if heartbeat then
		heartbeat:Disconnect()
		heartbeat = nil
	end
end

return RagdollController
