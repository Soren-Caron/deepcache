--!strict
--[[
	Watches player movement for implausibility.

	Roblox network-owns the player's character, so this is plausibility checking
	rather than authority. It catches trivial cheats and produces the telemetry
	needed to spot the rest. A cheater who stays inside the speed budget gets
	through, and the honest framing matters more than an overclaim.

	All the judgement lives in core/sim/MovementGuard, which is unit tested.
	This file only supplies positions and applies the verdict.
]]

local Players = game:GetService("Players")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")

local NetcodeConfig = require(Shared.config.Netcode)
local MovementGuard = require(Shared.core.sim.MovementGuard)
local Types = require(Shared.core.Types)
local Remotes = require(Shared.net.Remotes)
local TickService = require("./TickService")

local MovementGuardService = {}

type Tracked = {
	state: MovementGuard.State,
	lastPos: Types.Vec3?,
	lastTime: number,
	corrections: number,
	kicked: boolean?,
}

local tracked: { [Player]: Tracked } = {}
local params = table.clone(MovementGuard.DEFAULT_PARAMS)

params.speedMargin = NetcodeConfig.SPEED_MARGIN
params.teleportThreshold = NetcodeConfig.TELEPORT_THRESHOLD
params.decayPerSecond = NetcodeConfig.VIOLATION_DECAY_PER_SEC
params.correctAt = NetcodeConfig.VIOLATION_CORRECT_AT
params.kickAt = NetcodeConfig.VIOLATION_KICK_AT
params.maxFallSpeed = NetcodeConfig.MAX_FALL_SPEED

--- The upward budget is derived from the engine's *live* jump settings rather
--- than hardcoded, because the two are the same physical quantity: a
--- character leaves the ground at `sqrt(2 * gravity * jumpHeight)` (or
--- straight at `JumpPower` when the place still uses that). Hardcoding it
--- would silently start kicking players the moment someone tuned jump height
--- or gravity, which is exactly the class of bug this guard just caused.
local function measuredRiseSpeed(): number
	local StarterPlayer = game:GetService("StarterPlayer")
	local gravity = workspace.Gravity
	local ok, impulse = pcall(function(): number
		if StarterPlayer.CharacterUseJumpPower then
			return StarterPlayer.CharacterJumpPower
		end
		return math.sqrt(2 * gravity * StarterPlayer.CharacterJumpHeight)
	end)
	if not ok or impulse ~= impulse or impulse <= 0 then
		return MovementGuard.DEFAULT_PARAMS.maxRiseSpeed
	end
	-- Headroom over the raw impulse for ramps, knockback, and conveyor-style
	-- boosts, on top of the separate speedMargin the check already applies.
	return impulse * NetcodeConfig.RISE_SPEED_HEADROOM
end

params.maxRiseSpeed = measuredRiseSpeed()

--- Player max speed. M2 replaces this with the weight-derived value; the guard
--- must use the same number the movement code does, or a heavily loaded player
--- gets flagged for moving normally.
local speedProvider: (player: Player) -> number = function()
	return 16
end

function MovementGuardService.setSpeedProvider(provider: (player: Player) -> number)
	speedProvider = provider
end

--- Forget a player's last known position, so the next sample starts a fresh
--- baseline instead of being scored as a jump.
---
--- Call this whenever the *server* moves a character on purpose: a respawn at
--- the drop point, an extraction, a scripted reposition. The guard cannot tell
--- a server teleport from a client one by looking at positions, and without
--- this every legitimate server-side move reads as the exact signature the
--- guard exists to catch. Found when a diagnostics probe repositioned a player
--- onto loot and got them kicked.
function MovementGuardService.forgive(player: Player)
	local entry = tracked[player]
	if entry then
		entry.lastPos = nil
		entry.lastTime = TickService.now()
	end
end

function MovementGuardService.setWorldBounds(min: Types.Vec3, max: Types.Vec3)
	params.worldMin = min
	params.worldMax = max
end

--- Players the client has told us are sprinting. Trusted only as far as it
--- costs: a client claiming to sprint gets a wider speed budget, never a
--- different position. The worst a liar achieves is the sprint multiplier they
--- could have had by pressing the key, which is why this is a remote rather
--- than something the guard tries to infer.
local sprinting: { [Player]: boolean } = {}

function MovementGuardService.isSprinting(player: Player): boolean
	return sprinting[player] == true
end

function MovementGuardService.init()
	Remotes.event("SprintState").OnServerEvent:Connect(function(player, value)
		sprinting[player] = value == true
	end)

	Players.PlayerRemoving:Connect(function(player)
		sprinting[player] = nil
	end)

	Players.PlayerRemoving:Connect(function(player)
		tracked[player] = nil
	end)

	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(function()
			-- A respawn is a legitimate teleport; forget the old position so
			-- it is not measured as one impossible step.
			local entry = tracked[player]
			if entry then
				entry.lastPos = nil
			end
		end)
	end)
end

local function rootOf(player: Player): BasePart?
	local character = player.Character
	if character == nil then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

--- Registered as a TickService phase.
function MovementGuardService.step(_tick: number, dt: number)
	local now = TickService.now()

	for _, player in Players:GetPlayers() do
		local root = rootOf(player)
		if root == nil then
			continue
		end

		local entry = tracked[player]
		if entry == nil then
			entry = { state = MovementGuard.new(), lastPos = nil, lastTime = now, corrections = 0 }
			tracked[player] = entry
		end

		local position = { x = root.Position.X, y = root.Position.Y, z = root.Position.Z }
		local previous = entry.lastPos

		MovementGuard.decay(entry.state, dt, params)

		if previous ~= nil then
			local elapsed = math.max(now - entry.lastTime, 1e-6)
			local verdict = MovementGuard.check(
				entry.state,
				previous,
				position,
				elapsed,
				speedProvider(player),
				params
			)

			if verdict.action == "correct" and verdict.correctedPos then
				entry.corrections += 1
				local target = verdict.correctedPos
				root.CFrame = CFrame.new(target.x, target.y, target.z)
				Remotes.event("PositionCorrection"):FireClient(player, Vector3.new(target.x, target.y, target.z))
				position = target
			elseif verdict.action == "kick" and not entry.kicked then
				-- Once. The score decays slowly, so without this latch the
				-- same player is kicked again every tick until they finish
				-- disconnecting — a wall of identical warnings, and at M3 a
				-- wall of identical telemetry events for one incident.
				entry.kicked = true
				warn(`[MovementGuard] kicking {player.Name}: {table.concat(verdict.reasons, ",")} score={verdict.score}`)
				player:Kick("Movement validation failed.")
			end
		end

		entry.lastPos = position
		entry.lastTime = now
	end
end

function MovementGuardService.getMetrics(): { players: number, totalViolations: number, corrections: number }
	local totalViolations, corrections, count = 0, 0, 0
	for _, entry in tracked do
		totalViolations += entry.state.totalViolations
		corrections += entry.corrections
		count += 1
	end
	return { players = count, totalViolations = totalViolations, corrections = corrections }
end

function MovementGuardService.reset()
	tracked = {}
end

return MovementGuardService
