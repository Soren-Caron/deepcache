--!strict
--[[ Field repair, client side.

	Holds [G]. Releasing cancels, and so does moving -- the channel is meant to
	pin you in place, and letting a player heal while walking would remove the
	only cost it has.

	Everything authoritative lives on the server: charges, whether the channel
	completed, and the health it applies. This asks, and draws a bar.

	The bar is driven from the *server's* start signal rather than from the
	keypress, unlike the sweep's cooldown mirror. The difference is what a
	wrong guess costs: an optimistic sweep cooldown shows the ability as busy
	for one extra round trip, which is harmless, while an optimistic repair bar
	would show progress toward a heal the server refused -- and the player would
	stand still for it.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")

local RepairConfig = require(Shared.config.Repair)
local Remotes = require(Shared.net.Remotes)

local RepairController = {}

local player = Players.LocalPlayer

local charges = RepairConfig.charges
local repairing = false
local startedAt = 0
local held = false
local connection: RBXScriptConnection? = nil

local hooks = {
	onChanged = function(_charges: number, _progress: number, _repairing: boolean) end,
}

function RepairController.setHooks(newHooks: { [string]: any })
	for key, fn in newHooks do
		if hooks[key] ~= nil then
			hooks[key] = fn
		end
	end
end

local function moving(): boolean
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		return false
	end
	return humanoid.MoveDirection.Magnitude > 0.1
end

function RepairController.progress(): number
	if not repairing or RepairConfig.channelSeconds <= 0 then
		return 0
	end
	return math.clamp((os.clock() - startedAt) / RepairConfig.channelSeconds, 0, 1)
end

function RepairController.getState()
	return { charges = charges, repairing = repairing, progress = RepairController.progress() }
end

local function cancel()
	if not repairing then
		return
	end
	Remotes.event("RepairRequest"):FireServer("cancel")
end

function RepairController.start()
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or input.KeyCode ~= Enum.KeyCode.G then
			return
		end
		held = true
		Remotes.event("RepairRequest"):FireServer("begin")
	end)

	UserInputService.InputEnded:Connect(function(input)
		if input.KeyCode ~= Enum.KeyCode.G then
			return
		end
		held = false
		cancel()
	end)

	Remotes.event("RepairState").OnClientEvent:Connect(function(payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		if typeof(payload.charges) == "number" then
			charges = payload.charges
		end
		local nowRepairing = payload.repairing == true
		if nowRepairing and not repairing then
			startedAt = os.clock()
		end
		repairing = nowRepairing
	end)

	player.CharacterAdded:Connect(function()
		repairing = false
		held = false
	end)

	if connection == nil then
		connection = RunService.Heartbeat:Connect(function()
			-- Moving cancels. Checked here rather than on the server because the
			-- client is the only place that knows the input the instant it
			-- happens, and the server re-checks the thing that matters anyway:
			-- it is the one applying the health.
			if repairing and (moving() or not held) then
				cancel()
			end
			hooks.onChanged(charges, RepairController.progress(), repairing)
		end)
	end
end

function RepairController.stop()
	if connection then
		connection:Disconnect()
		connection = nil
	end
end

return RepairController
