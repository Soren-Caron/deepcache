--!strict
--[[ Field repair, client side.

	**[G] is a press, not a hold.** It was a hold, and that was a trap: a tap
	began the channel and the key release cancelled it a few milliseconds
	later, so the player spent a charge, received a third of a hit point, and
	had nothing on screen explaining why. Nothing labelled it as a hold either
	-- the HUD said "[G] repair". Pressing again abandons a channel in progress,
	so a mistaken start does not pin you in place.

	Moving still cancels: the channel is meant to hold you still, and letting a
	player heal while walking would remove the only cost it has. But pressing
	[G] *while already moving* is refused outright rather than started and
	immediately cancelled -- a refusal costs nothing, and a cancel costs the
	charge. That is the same trap in a different shape, and it is why the check
	happens before the request rather than after it.

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
--- A cancel is in flight. `repairing` stays true until the server answers, so
--- without this the movement check would fire a cancel every frame of the
--- round trip -- and a notice with it.
local cancelSent = false
local connection: RBXScriptConnection? = nil

local hooks = {
	onChanged = function(_charges: number, _progress: number, _repairing: boolean) end,
	--- Short player-facing line explaining a refusal or an interruption. The
	--- controller knows *why* it refused; the server only ever sees the result.
	onNotice = function(_text: string) end,
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

local function cancel(notice: string?)
	if not repairing or cancelSent then
		return
	end
	cancelSent = true
	if notice then
		hooks.onNotice(notice)
	end
	Remotes.event("RepairRequest"):FireServer("cancel")
end

function RepairController.start()
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or input.KeyCode ~= Enum.KeyCode.G then
			return
		end
		if repairing then
			cancel("REPAIR ABANDONED")
			return
		end
		if moving() then
			-- Refused, not started-and-cancelled. See the header: starting here
			-- would spend the charge and throw it away in the same frame.
			hooks.onNotice("HOLD STILL TO REPAIR")
			return
		end
		Remotes.event("RepairRequest"):FireServer("begin")
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
			cancelSent = false
		end
		repairing = nowRepairing
	end)

	player.CharacterAdded:Connect(function()
		repairing = false
		cancelSent = false
	end)

	if connection == nil then
		connection = RunService.Heartbeat:Connect(function()
			-- Moving cancels. Checked here rather than on the server because the
			-- client is the only place that knows the input the instant it
			-- happens, and the server re-checks the thing that matters anyway:
			-- it is the one applying the health.
			if repairing and moving() then
				cancel("REPAIR INTERRUPTED")
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
