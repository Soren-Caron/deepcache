--!strict
--[[
	Client startup.

	Presentation only. Nothing here decides anything the server cares about —
	it renders what the server says happened and predicts how it should look
	while the authoritative answer is in flight.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")

local Branding = require(Shared.config.Branding)
local EntityRenderer = require("./controllers/EntityRenderer")
local PredictionController = require("./controllers/PredictionController")
local HudController = require("./controllers/HudController")

local function main()
	EntityRenderer.start()
	HudController.start()

	PredictionController.setHooks({
		onTracer = function(origin: Vector3, target: Vector3)
			-- M1 placeholder. The effects layer lands in M7; drawing a beam
			-- here keeps the prediction path observable in a playtest.
			local distance = (target - origin).Magnitude
			local beam = Instance.new("Part")
			beam.Anchored = true
			beam.CanCollide = false
			beam.CanQuery = false
			beam.CastShadow = false
			beam.Material = Enum.Material.Neon
			beam.Color = Color3.fromRGB(255, 220, 150)
			beam.Size = Vector3.new(0.1, 0.1, distance)
			beam.CFrame = CFrame.lookAt(origin, target) * CFrame.new(0, 0, -distance / 2)
			beam.Parent = workspace
			task.delay(0.05, function()
				beam:Destroy()
			end)
		end,
	})

	PredictionController.start()

	print(`[{Branding.gameName}] client up — entities, prediction, HUD`)
end

main()
