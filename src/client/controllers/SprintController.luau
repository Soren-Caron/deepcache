--!strict
--[[ Sprint input and stamina, client side.

	The stamina rules are pure (`core/sim/Stamina`); this reads the key, ticks
	them, and writes `Humanoid.WalkSpeed`.

	**The server must be told.** `MovementGuardService` budgets horizontal
	displacement against a speed provider, and a sprint it does not know about
	is indistinguishable from a speed hack — the same class of bug as the jump
	that got a player kicked, where the guard was measuring against a limit the
	player could legitimately exceed. So sprint state goes up on a remote and
	the guard's provider accounts for it.

	Walk speed is *multiplied*, not replaced, so the weight system keeps
	mattering: sprinting while loaded is still slower than sprinting empty.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")

local MovementConfig = require(Shared.config.Movement)
local Stamina = require(Shared.core.sim.Stamina)
local Remotes = require(Shared.net.Remotes)

local SprintController = {}

local PARAMS: Stamina.Params = {
	max = MovementConfig.STAMINA_MAX,
	drainPerSecond = MovementConfig.STAMINA_DRAIN_PER_SECOND,
	regenPerSecond = MovementConfig.STAMINA_REGEN_PER_SECOND,
	regenDelay = MovementConfig.STAMINA_REGEN_DELAY,
	recoverFraction = MovementConfig.STAMINA_RECOVER_FRACTION,
	minToStart = MovementConfig.STAMINA_MIN_TO_START,
}

local player = Players.LocalPlayer
local state = Stamina.new(PARAMS)
local held = false
local lastSent: boolean? = nil
local connection: RBXScriptConnection? = nil

--- Base walk speed as the server set it, before any sprint multiplier. Read
--- fresh each frame rather than cached: `LootService` rewrites WalkSpeed as
--- carried weight changes, and caching it would freeze the carry penalty the
--- first time a player sprinted.
local baseSpeed = 16

local hooks = {
	onStaminaChanged = function(_fraction: number, _exhausted: boolean) end,
}

function SprintController.setHooks(newHooks: { [string]: any })
	for key, fn in newHooks do
		if hooks[key] ~= nil then
			hooks[key] = fn
		end
	end
end

local function humanoid(): Humanoid?
	local character = player.Character
	return character and character:FindFirstChildOfClass("Humanoid")
end

--- Is the player actually moving? Sprinting on the spot should not drain.
local function moving(): boolean
	local h = humanoid()
	if h == nil then
		return false
	end
	return h.MoveDirection.Magnitude > 0.1
end

local function step(dt: number)
	local h = humanoid()
	if h == nil or h.Health <= 0 then
		return
	end

	if not state.sprinting then
		-- Capture the server's current walk speed while not sprinting, so the
		-- multiplier always applies to an up-to-date carry penalty.
		baseSpeed = h.WalkSpeed
	end

	local sprinting = Stamina.step(state, dt, held and moving(), PARAMS)
	h.WalkSpeed = if sprinting then baseSpeed * MovementConfig.SPRINT_MULTIPLIER else baseSpeed

	if sprinting ~= lastSent then
		lastSent = sprinting
		-- Only on change. A per-frame remote for a boolean would be 60
		-- messages a second describing something that changes twice a minute.
		Remotes.event("SprintState"):FireServer(sprinting)
	end

	hooks.onStaminaChanged(Stamina.fraction(state, PARAMS), state.exhausted)
end

function SprintController.getState()
	return {
		fraction = Stamina.fraction(state, PARAMS),
		sprinting = state.sprinting,
		exhausted = state.exhausted,
		current = state.current,
	}
end

function SprintController.start()
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if input.KeyCode == Enum.KeyCode.LeftShift or input.KeyCode == Enum.KeyCode.RightShift then
			held = true
		end
	end)

	UserInputService.InputEnded:Connect(function(input)
		if input.KeyCode == Enum.KeyCode.LeftShift or input.KeyCode == Enum.KeyCode.RightShift then
			held = false
		end
	end)

	-- A fresh character arrives at default speed with no sprint state, and the
	-- server has no idea the old one was sprinting.
	player.CharacterAdded:Connect(function()
		Stamina.reset(state, PARAMS)
		held = false
		lastSent = nil
	end)

	if connection == nil then
		connection = RunService.Heartbeat:Connect(step)
	end
end

function SprintController.stop()
	if connection then
		connection:Disconnect()
		connection = nil
	end
end

return SprintController
