--!strict
--[[
	Applies server position corrections from the movement guard.

	**Why this exists as a real handler and not a no-op.** Roblox network-owns
	the local character, so the server writing `root.CFrame` is a *request*
	that the client's own physics simulation can immediately overwrite. The
	client has to cooperate for a correction to stick. Until this controller
	existed nothing was connected to `PositionCorrection` at all, which
	produced two distinct failures at once:

	  - Every correction hit an unconsumed remote, so Roblox logged
	    "Remote event invocation queue exhausted ... did you forget to
	    implement OnClientEvent?" and dropped the payload -- 1, 2, 4, 8, 16 ...
	    doubling as the queue backed up.
	  - The correction itself never reliably landed, so the server kept seeing
	    the same implausible position, kept scoring it, and eventually kicked.

	A remote that is fired but never consumed is worse than an unused one: it
	backs up a queue and the log line names the symptom, not the cause.

	The correction is deliberately a hard snap rather than a smoothed lerp.
	This fires when the server has already decided the position was not
	plausible; easing toward the authoritative answer would leave the player
	somewhere the server still disagrees with, and re-trip the guard on the
	next tick.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.net.Remotes)

local CorrectionController = {}

local corrections = 0

local function rootPart(): BasePart?
	local character = Players.LocalPlayer.Character
	if character == nil then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function onPositionCorrection(target: Vector3)
	if typeof(target) ~= "Vector3" then
		return
	end
	local root = rootPart()
	if root == nil then
		-- Mid-respawn. The server forgives a missing character on its side
		-- too (MovementGuardService.forgive), so dropping this is correct
		-- rather than something to retry.
		return
	end

	corrections += 1
	-- Preserve orientation: the guard corrects position only, and rotating the
	-- player would be a second, unrequested change to how the game feels.
	root.CFrame = CFrame.new(target) * (root.CFrame - root.CFrame.Position)
	-- Zero the velocity that produced the rejected displacement. Leaving it
	-- means physics immediately carries the player back out of bounds and the
	-- next tick scores another violation for the same original mistake.
	root.AssemblyLinearVelocity = Vector3.zero
end

function CorrectionController.start()
	Remotes.event("PositionCorrection").OnClientEvent:Connect(onPositionCorrection)
end

--- Diagnostic: how many corrections this client has applied.
function CorrectionController.count(): number
	return corrections
end

return CorrectionController
