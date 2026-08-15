--!strict
--[[
	Decides what each client is told, and sends it.

	Per client: pick the most interesting <=32 entities, send a full keyframe
	once a second and deltas in between, and remember what they were sent so the
	next delta is computed against the right baseline.

	Accepted tradeoff: the server assumes every delta arrived. If one is lost,
	the client's baseline diverges for entities that then stop changing, until
	the next keyframe resyncs them — at most one second. Entities that keep
	moving keep being re-sent, so the visible impact is confined to things that
	went still at the exact moment a packet dropped. The alternative is
	per-client acknowledgement, which costs an uplink message per tick per
	client to fix a one-second cosmetic staleness. Not worth it.
]]

local Players = game:GetService("Players")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")

local NetcodeConfig = require(Shared.config.Netcode)
local Interest = require(Shared.core.net.Interest)
local Snapshot = require(Shared.core.net.Snapshot)
local Types = require(Shared.core.Types)
local Remotes = require(Shared.net.Remotes)
local EntityService = require("./EntityService")

local ReplicationService = {}

--- Level origin. Positions are encoded relative to this so an int16 grid
--- covers the map; M2 sets it from the assembled layout.
local origin: Types.Vec3 = { x = 0, y = 0, z = 0 }

type ClientState = {
	baseline: { Types.EntityView },
	lastSentTick: { [number]: number },
	bytesSent: number,
	packetsSent: number,
	windowStart: number,
}

local clients: { [Player]: ClientState } = {}

function ReplicationService.setOrigin(newOrigin: Types.Vec3)
	origin = newOrigin
end

local function stateFor(player: Player): ClientState
	local existing = clients[player]
	if existing then
		return existing
	end
	local created: ClientState = {
		baseline = {},
		lastSentTick = {},
		bytesSent = 0,
		packetsSent = 0,
		windowStart = os.clock(),
	}
	clients[player] = created
	return created
end

function ReplicationService.init()
	Players.PlayerRemoving:Connect(function(player)
		clients[player] = nil
	end)
end

local function viewerPosition(player: Player): Types.Vec3?
	local character = player.Character
	if character == nil then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root == nil or not root:IsA("BasePart") then
		return nil
	end
	local p = root.Position
	return { x = p.X, y = p.Y, z = p.Z }
end

--- Registered as a TickService phase, after simulation and history recording.
function ReplicationService.step(tick: number, _dt: number)
	local despawns = EntityService.drainDespawns()
	if #despawns > 0 then
		-- Reliable: a lost despawn leaves a ghost on screen forever.
		Remotes.event("Despawn"):FireAllClients({ ids = despawns })
	end

	local views = EntityService.views()
	local isKeyframe = Snapshot.isKeyframeTick(tick)

	for _, player in Players:GetPlayers() do
		local viewer = viewerPosition(player)
		if viewer == nil then
			continue
		end

		local state = stateFor(player)

		local selected = Interest.select(views, viewer, {
			radius = NetcodeConfig.INTEREST_RADIUS,
			maxCount = NetcodeConfig.INTEREST_MAX,
			currentTick = tick,
			lastSentTick = state.lastSentTick,
		})

		local packet: buffer
		if isKeyframe then
			packet = Snapshot.encode(tick, selected, origin)
			state.baseline = selected
		else
			packet = Snapshot.encodeDelta(tick, selected, state.baseline, origin)
			-- Mirror what the client will hold after applying this delta.
			state.baseline = Snapshot.applyDelta(state.baseline, packet, origin).entities
		end

		for _, view in selected do
			state.lastSentTick[view.id] = tick
		end

		state.bytesSent += buffer.len(packet)
		state.packetsSent += 1

		Remotes.unreliable("Snapshot"):FireClient(player, packet)
	end
end

--- Bytes/second per client since the last call, for the bandwidth metric.
function ReplicationService.sampleBandwidth(): { [string]: number }
	local out: { [string]: number } = {}
	local now = os.clock()
	for player, state in clients do
		local elapsed = math.max(now - state.windowStart, 1e-6)
		out[player.Name] = state.bytesSent / elapsed
		state.bytesSent = 0
		state.packetsSent = 0
		state.windowStart = now
	end
	return out
end

function ReplicationService.reset()
	clients = {}
end

return ReplicationService
