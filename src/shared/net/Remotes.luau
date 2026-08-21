--!strict
--[[
	Single declaration point for every remote.

	CLAUDE.md: remotes are declared once here and accessed only through this
	module. Never `WaitForChild` a remote inline — that scatters string
	literals across the codebase and turns a rename into a silent runtime
	failure on one code path.

	Channel choice is load-bearing, not stylistic:

	  Unreliable — snapshots only. Losing one is fine; the next arrives in 50ms
	               and interpolation covers the gap. Ordering does not matter
	               because every snapshot carries its own tick.
	  Reliable   — everything whose loss changes game state: fire requests, hit
	               results, despawns, ammo corrections. A dropped despawn leaves
	               a ghost on screen forever.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local FOLDER_NAME = "DeepcacheRemotes"

type RemoteKind = "Reliable" | "Unreliable" | "Function"

local DECLARATIONS: { [string]: RemoteKind } = {
	--- Server -> client, 20Hz. Delta-compressed entity snapshots.
	Snapshot = "Unreliable",

	--- Client -> server. A fire request; validated, never trusted.
	FireRequest = "Reliable",
	--- Server -> client. Authoritative outcome for a specific request seq.
	FireResult = "Reliable",

	--- Server -> client. Entities that left interest or died. Must be reliable:
	--- omission from an unreliable packet is indistinguishable from loss.
	Despawn = "Reliable",

	--- Server -> client. Corrects a mispredicted ammo count.
	AmmoSync = "Reliable",

	--- Server -> client. Position correction from the movement guard.
	PositionCorrection = "Reliable",

	--- Server -> client. Run lifecycle, objectives, OVERSEER barks (M2/M4).
	RunEvent = "Reliable",

	--- Client -> server. Ask to pick up or drop a specific ground item. The
	--- server decides; a client asking twice for the same uid loses the second
	--- time, which is the whole point of the claim in core/sim/Loot.
	LootRequest = "Reliable",
	--- Server -> client. Carried manifest, total weight, speed multiplier.
	--- Reliable because a lost update leaves the HUD lying about the one number
	--- the player is making decisions on.
	CarryUpdate = "Reliable",
	--- Server -> client, ~1Hz. Clock, pad states, squad status for the HUD.
	RunState = "Reliable",

	--- Client -> server. Place, cancel, or refresh a market order. Every field
	--- is validated server-side; the client is asking, not telling. Reliable
	--- because a dropped request leaves escrow the player believes they moved
	--- exactly where it was, and they will assume the game ate it.
	MarketRequest = "Reliable",
	--- Server -> client. Order book for the viewed item, this player's own
	--- open orders, and their spendable balance. Reliable for the same reason
	--- CarryUpdate is: a lost update leaves the UI lying about the numbers a
	--- player is spending real currency against.
	MarketUpdate = "Reliable",
}

local CLASS_BY_KIND: { [RemoteKind]: string } = {
	Reliable = "RemoteEvent",
	Unreliable = "UnreliableRemoteEvent",
	Function = "RemoteFunction",
}

local Remotes = {}

local folder: Folder? = nil
local cache: { [string]: Instance } = {}

local function getFolder(): Folder
	if folder then
		return folder
	end

	if RunService:IsServer() then
		local existing = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
		if existing then
			folder = existing :: Folder
		else
			local created = Instance.new("Folder")
			created.Name = FOLDER_NAME
			created.Parent = ReplicatedStorage
			folder = created
		end
	else
		folder = ReplicatedStorage:WaitForChild(FOLDER_NAME, 30) :: Folder
		if folder == nil then
			error("Remotes: server never created the remote folder", 2)
		end
	end

	return folder :: Folder
end

--- Create every declared remote. Server only, called once at boot before any
--- client can request one.
function Remotes.init()
	assert(RunService:IsServer(), "Remotes.init must run on the server")
	local parent = getFolder()
	for name, kind in DECLARATIONS do
		if parent:FindFirstChild(name) == nil then
			local instance = Instance.new(CLASS_BY_KIND[kind])
			instance.Name = name
			instance.Parent = parent
		end
	end
end

local function fetch(name: string): Instance
	local cached = cache[name]
	if cached then
		return cached
	end

	local kind = DECLARATIONS[name]
	if kind == nil then
		error(`Remotes: "{name}" is not declared. Add it to DECLARATIONS.`, 3)
	end

	local parent = getFolder()
	local instance: Instance?
	if RunService:IsServer() then
		instance = parent:FindFirstChild(name)
		if instance == nil then
			error(`Remotes: "{name}" missing — was Remotes.init() called at boot?`, 3)
		end
	else
		instance = parent:WaitForChild(name, 30)
		if instance == nil then
			error(`Remotes: timed out waiting for "{name}"`, 3)
		end
	end

	cache[name] = instance :: Instance
	return instance :: Instance
end

function Remotes.event(name: string): RemoteEvent
	local instance = fetch(name)
	assert(instance:IsA("RemoteEvent"), `Remotes: "{name}" is not a RemoteEvent`)
	return instance
end

function Remotes.unreliable(name: string): UnreliableRemoteEvent
	local instance = fetch(name)
assert(instance:IsA("UnreliableRemoteEvent"), `Remotes: "{name}" is not an UnreliableRemoteEvent`)
	return instance
end

Remotes.DECLARATIONS = DECLARATIONS

return Remotes
