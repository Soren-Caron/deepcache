--!strict
--[[ Sound playback.

	The adapter half of `core/audio/Cues`. Every decision about *whether* a
	sound may start lives in core and is unit tested; this owns the Roblox
	half -- creating and reaping `Sound` instances, attaching positional ones
	to an emitter, and reading the asset table.

	**Cues with no `assetId` are skipped and counted.** Every id in
	`config/Audio` is currently empty, for the reason documented there, so
	today this controller plays nothing at all -- but `describe()` reports
	exactly how many cues were requested and how many were silent for want of
	an asset. That distinction matters: this project has repeatedly shipped
	features that were fully built and silently never connected, and "silent
	because nobody chose a sound" and "silent because the wiring is broken"
	look identical from the outside unless something counts.

	Pooling is by destruction rather than reuse. A `Sound` is cheap to create
	and the alternative -- a pool keyed by asset -- would have to handle a
	sound being restarted while still playing, which is exactly the case the
	throttle in core exists to prevent.
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local SoundService = game:GetService("SoundService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")

local AudioConfig = require(Shared.config.Audio)
local Cues = require(Shared.core.audio.Cues)

local AudioController = {}

local player = Players.LocalPlayer
local state = Cues.new()
local random = Random.new()

--- How long a one-shot is allowed to live before being reaped, regardless of
--- its real length. A cue whose asset is longer than this is misconfigured;
--- see the note in config/Audio about keeping one-shots short.
local MAX_LIFETIME = 6

local live = 0
--- Forward declaration: `play` reports through this, but it is defined below
--- next to the other diagnostics.
local publish: () -> ()
local metrics = {
	requested = 0,
	playedNoAsset = 0,
	playedForReal = 0,
	suppressedByThrottle = 0,
	suppressedByBudget = 0,
}

local container: Folder? = nil

local function folder(): Folder
	if container ~= nil and container.Parent ~= nil then
		return container
	end
	local created = Instance.new("Folder")
	created.Name = "DeepcacheAudio"
	created.Parent = SoundService
	container = created
	return created
end

--- Play one cue. `at` is required for positional cues and ignored otherwise.
---
--- Returns whether a sound actually started, so a caller can tell "throttled"
--- from "played" -- though almost nothing needs to.
function AudioController.play(cueName: string, at: Vector3?): boolean
	local cue = AudioConfig.CUES[cueName]
	if cue == nil then
		-- A typo'd cue name is a programmer error, but not one worth throwing
		-- over during a firefight. Count it and move on -- and publish, so a
		-- `requested` count that outruns every other counter names the bug.
		metrics.requested += 1
		publish()
		return false
	end

	metrics.requested += 1

	if not Cues.shouldPlay(state, cueName, os.clock(), cue.minInterval) then
		metrics.suppressedByThrottle += 1
		publish()
		return false
	end

	if cue.assetId == "" then
		-- Wired, reachable, and deliberately silent. Counting this is what
		-- makes "no asset chosen yet" distinguishable from "never called".
		metrics.playedNoAsset += 1
		publish()
		return false
	end

	if live >= AudioConfig.MAX_CONCURRENT then
		metrics.suppressedByBudget += 1
		publish()
		return false
	end

	local sound = Instance.new("Sound")
	sound.SoundId = if cue.assetId:match("^rbxassetid://") then cue.assetId else `rbxassetid://{cue.assetId}`
	sound.Volume = cue.volume * AudioConfig.MASTER_VOLUME
	sound.PlaybackSpeed = Cues.pitch(random:NextNumber(), cue.jitter)
	sound.RollOffMaxDistance = cue.rollOffMaxDistance
	sound.RollOffMode = Enum.RollOffMode.InverseTapered

	if cue.positional and at ~= nil then
		-- Positional cues need a part to emit from. An anchored, invisible,
		-- non-queryable attachment point, reaped with the sound.
		local emitter = Instance.new("Part")
		emitter.Anchored = true
		emitter.CanCollide = false
		emitter.CanQuery = false
		emitter.CanTouch = false
		emitter.Transparency = 1
		emitter.Size = Vector3.new(0.1, 0.1, 0.1)
		emitter.CFrame = CFrame.new(at)
		emitter.Parent = folder()
		sound.Parent = emitter
		Debris:AddItem(emitter, MAX_LIFETIME)
	else
		sound.Parent = folder()
		Debris:AddItem(sound, MAX_LIFETIME)
	end

	live += 1
	sound.Ended:Connect(function()
		live -= 1
	end)
	-- Destroying without Ended firing (Debris reap) would leak the count.
	sound.Destroying:Connect(function()
		if sound.IsPlaying then
			live -= 1
		end
	end)

	sound:Play()
	metrics.playedForReal += 1
	publish()
	return true
end

--- Which cues still have no asset chosen. Surfaced so the remaining work is a
--- list rather than a vague "audio is missing".
function AudioController.missingAssets(): { string }
	local missing: { string } = {}
	for name, cue in AudioConfig.CUES do
		if cue.assetId == "" then
			table.insert(missing, name)
		end
	end
	table.sort(missing)
	return missing
end

function AudioController.describe(): { [string]: any }
	local missing = AudioController.missingAssets()
	local total = 0
	for _ in AudioConfig.CUES do
		total += 1
	end
	return {
		cuesDeclared = total,
		cuesWithoutAsset = #missing,
		missing = missing,
		requested = metrics.requested,
		playedForReal = metrics.playedForReal,
		playedNoAsset = metrics.playedNoAsset,
		suppressedByThrottle = metrics.suppressedByThrottle,
		suppressedByBudget = metrics.suppressedByBudget,
		liveSounds = live,
	}
end

--- Publish the counters onto the container folder as attributes.
---
--- Client controllers have no equivalent of the server's diagnostics
--- BindableFunction, and a `require` from the command bar returns a fresh idle
--- copy whose counters are all zero -- the trap that has already produced
--- invalid results twice on this branch. Attributes live on a real Instance in
--- the live DataModel, so reading them cannot pick up a different copy.
---
--- This matters more than usual here: with no assets chosen, a working audio
--- layer and a completely unwired one are both silent.
function publish()
	local f = folder()
	f:SetAttribute("requested", metrics.requested)
	f:SetAttribute("playedForReal", metrics.playedForReal)
	f:SetAttribute("playedNoAsset", metrics.playedNoAsset)
	f:SetAttribute("suppressedByThrottle", metrics.suppressedByThrottle)
	f:SetAttribute("suppressedByBudget", metrics.suppressedByBudget)
	f:SetAttribute("liveSounds", live)
end

--- Create the container up front so the counters are readable before the first
--- cue, and so "no folder" means "controller never started" rather than
--- "nothing has played yet".
function AudioController.start()
	publish()
end

function AudioController.reset()
	Cues.reset(state)
	metrics.requested = 0
	metrics.playedForReal = 0
	metrics.playedNoAsset = 0
	metrics.suppressedByThrottle = 0
	metrics.suppressedByBudget = 0
end

--- Where the local player is, for attenuating flat cues. Positional ones let
--- Roblox do this.
function AudioController.listenerPosition(): Vector3
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root ~= nil and root:IsA("BasePart") then
		return root.Position
	end
	return Vector3.zero
end

return AudioController
