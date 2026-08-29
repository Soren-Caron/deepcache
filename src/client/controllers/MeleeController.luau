--!strict
--[[ The melee sweep, client side.

	Reads the key, asks the server, and draws the arc. It decides nothing: the
	request carries no position, no direction and no targets, because the
	server takes all three from the character. See `MeleeService`'s header.

	The cooldown is mirrored here purely so the HUD can show it. That mirror is
	optimistic — it starts the moment the key is pressed rather than when the
	server confirms — which is the right way round for a readout: showing the
	ability as ready when the server would refuse is worse than showing it as
	busy for one extra round trip.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")

local MeleeConfig = require(Shared.config.Melee)
local Sweep = require(Shared.core.sim.Sweep)
local Remotes = require(Shared.net.Remotes)

local MeleeController = {}

local player = Players.LocalPlayer
local lastSwingAt: number? = nil
local connection: RBXScriptConnection? = nil

local hooks = {
	onCooldownChanged = function(_fraction: number, _ready: boolean) end,
	onHit = function(_count: number) end,
}

function MeleeController.setHooks(newHooks: { [string]: any })
	for key, fn in newHooks do
		if hooks[key] ~= nil then
			hooks[key] = fn
		end
	end
end

--- 0..1, where 1 is ready. For the HUD.
function MeleeController.readiness(): number
	local remaining = Sweep.remaining(lastSwingAt, os.clock(), MeleeConfig.cooldownSeconds)
	if MeleeConfig.cooldownSeconds <= 0 then
		return 1
	end
	return 1 - remaining / MeleeConfig.cooldownSeconds
end

local function trySwing()
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil or humanoid.Health <= 0 then
		return
	end
	if not Sweep.ready(lastSwingAt, os.clock(), MeleeConfig.cooldownSeconds) then
		return
	end
	lastSwingAt = os.clock()
	Remotes.event("MeleeRequest"):FireServer()
end

function MeleeController.start()
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		-- F, and left on F deliberately: every letter that reads as "attack" is
		-- taken (R reloads, 1-4 switch, shift sprints), and F is the near-universal
		-- convention for a contextual melee in a shooter.
		if input.KeyCode == Enum.KeyCode.F then
			trySwing()
		end
	end)

	-- A fresh character has no cooldown owed to it, and the server's per-player
	-- timer is keyed on the Player rather than the character, so the two would
	-- disagree for one cooldown after every respawn if this were not cleared.
	player.CharacterAdded:Connect(function()
		lastSwingAt = nil
	end)

	Remotes.event("MeleeSwing").OnClientEvent:Connect(function(payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		MeleeController.onSwing(payload)
	end)

	if connection == nil then
		connection = RunService.Heartbeat:Connect(function()
			hooks.onCooldownChanged(MeleeController.readiness(), MeleeController.readiness() >= 1)
		end)
	end
end

--- Drawn for every player's swing, not just the local one: a teammate clearing
--- a swarm next to you should be visible.
local onSwingHook: ((payload: any) -> ())? = nil

function MeleeController.setSwingRenderer(fn: (payload: any) -> ())
	onSwingHook = fn
end

function MeleeController.onSwing(payload: any)
	if onSwingHook ~= nil then
		onSwingHook(payload)
	end
	if payload.by == player.UserId and typeof(payload.hits) == "number" and payload.hits > 0 then
		hooks.onHit(payload.hits)
	end
end

function MeleeController.stop()
	if connection then
		connection:Disconnect()
		connection = nil
	end
end

return MeleeController
