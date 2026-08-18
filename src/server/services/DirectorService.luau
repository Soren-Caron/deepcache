--!strict
--[[ M4-6/M4-7/M4-8. Drives the pacing FSM on the documented 20s director
	cadence, layers OVERSEER's async proposal on top of it via Clamp, filters
	the resulting bark, and gates the resolved objective against cooldown
	state (`core/director/Objectives`) before it is applied.

	The FSM (`core/director/Fsm`) always runs and always produces a valid
	decision — that is M2's exit criterion and it does not change here.
	OVERSEER is additive: every 20s this fires an async HTTP call to the
	backend, and if a usable proposal comes back before the *next* tick
	boundary, `Clamp.apply(proposal, fsmDecision, bounds)` is what actually
	gets applied. A proposal that never arrives, times out, or fails
	validation simply means the FSM decision is what applies -- there is no
	special-cased "LLM failed" path, because Clamp.apply(nil, ...) already
	returns the baseline.

	HttpService:RequestAsync yields and cannot be cancelled once started.
	`requestWithTimeout` below does not stop the request -- nothing can --
	it stops *waiting* on it and moves on, discarding whatever eventually
	comes back. That is what "timeout" means for a blocking call with no
	cancellation primitive, and it is a real, different thing from the
	backend's own internal timeout (M4-3), which does abort its call to
	Ollama.

	Known, documented gaps in the run-state payload sent to the backend --
	not fabricated data, placeholders explicitly marked as such: per-player
	kills/deaths are not tracked live anywhere in the codebase yet (only a
	run-level total exists, computed once at run end), a player's current
	zone is not derivable from position yet (no zone-lookup helper exists),
	and `pressure.budgetSpent`/`recentPlayerDamage`/`recentEnemyDeaths` have
	no source (`core/sim/Budget` is not wired into `EntityService` yet --
	that gap predates this file, see M2's still-open adapter todos).
	`aliveEnemies` and `secondsSinceLastFight` ARE real, derived from
	`EntityService.count()` and a hit-count watch on `CombatService`,
	respectively.
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local TextService = game:GetService("TextService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")

local Clamp = require(Shared.core.director.Clamp)
local Fsm = require(Shared.core.director.Fsm)
local ObjectivesCore = require(Shared.core.director.Objectives)
local Schema = require(Shared.core.director.Schema)
local CannedBarks = require(Shared.config.CannedBarks)
local ObjectivesConfig = require(Shared.config.Objectives)

local BackendConfig = require("../config/Backend")
local CombatService = require("./CombatService")
local EntityService = require("./EntityService")
local LootService = require("./LootService")
local RunLifecycleService = require("./RunLifecycleService")
local TelemetryService = require("./TelemetryService")

local DirectorService = {}

--- Adapter owns the config -> core mapping; core cannot read config/ (see
--- the M1-4/M2-8 precedent).
local COOLDOWN_SECONDS_BY_ID: { [string]: number } = {}
for id, spec in ObjectivesConfig :: { [string]: { cooldownSeconds: number } } do
	COOLDOWN_SECONDS_BY_ID[id] = spec.cooldownSeconds
end

--- docs/05 §Cadence and latency.
local TICK_INTERVAL_SECONDS = 20
local HISTORY_SIZE = 5

local context = Fsm.new()
local currentDecision: Schema.DirectorDecision = context.lastDecision
local objectiveState = ObjectivesCore.new(context.lastDecision.objective.id)
local running = false
local sinceFight = 0
local lastHitCount = 0

local inFlight = false
local pendingProposal: unknown = nil
local consecutiveFailures = 0
local breakerOpenUntil = 0

local history: { string } = {}
--- The filtered, display-ready bark. Never the raw `currentDecision.bark`
--- directly -- that has been sanitised of control characters by Clamp, but
--- never content-filtered, and docs/05 §Content filtering is explicit that
--- no unfiltered model text may reach a player under any circumstance.
local filteredBark = ""

local metrics = {
	calls = 0,
	fallbacks = 0,
	skipped = 0,
	lastLatencyMs = 0,
	lastError = "",
	lastModel = "",
	lastPromptVersion = "",
}

local function now(): number
	return os.clock()
end

local function squadHpFraction(): number
	local total = 0
	local count = 0
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			total += humanoid.Health / math.max(humanoid.MaxHealth, 1)
			count += 1
		end
	end
	if count == 0 then
		return 1
	end
	return total / count
end

local function pickCannedBark(intent: string): string
	local pool = CannedBarks[intent] or CannedBarks.hold_steady
	if pool == nil or #pool == 0 then
		return "..."
	end
	return pool[math.random(1, #pool)]
end

--- The requesting user for FilterStringAsync -- docs/05: "use the run's
--- host player." Nothing elsewhere in this codebase tracks a designated
--- host, so the first connected player stands in for it. Returns 0 (an
--- id no real player can have) if nobody is connected, which correctly
--- forces FilterStringAsync to fail rather than silently skip filtering.
local function hostUserId(): number
	local first = Players:GetPlayers()[1]
	return if first then first.UserId else 0
end

--- Never returns unfiltered text. Both TextService calls are pcall-wrapped
--- per docs/05 §Content filtering; either one failing falls back to a
--- canned line for the same intent, not to the raw bark.
local function filterBark(rawBark: string, intent: string, requestingUserId: number): string
	local filterOk, filterResult = pcall(function()
		return TextService:FilterStringAsync(rawBark, requestingUserId, Enum.TextFilterContext.PublicChat)
	end)
	if not filterOk then
		return pickCannedBark(intent)
	end

	local broadcastOk, display = pcall(function()
		return (filterResult :: TextFilterResult):GetNonChatStringForBroadcastAsync()
	end)
	if not broadcastOk then
		return pickCannedBark(intent)
	end

	return display :: string
end

--- Runs `fn` on its own thread and waits up to `timeoutSeconds` for it.
--- Cannot cancel `fn` -- nothing in Roblox can cancel a yielded
--- HttpService call -- it stops waiting and lets the caller move on.
local function requestWithTimeout(timeoutSeconds: number, fn: () -> any): (boolean, any)
	local done = false
	local callOk = false
	local callResult: any = nil

	task.spawn(function()
		callOk, callResult = pcall(fn)
		done = true
	end)

	local deadline = now() + timeoutSeconds
	while not done and now() < deadline do
		task.wait(0.02)
	end

	if not done then
		return false, "timeout"
	end
	if not callOk then
		return false, tostring(callResult)
	end
	return true, callResult
end

local function callDirectorTick(payload: { [string]: any }): (boolean, { [string]: any }?, string?)
	local body = HttpService:JSONEncode(payload)
	local ok, result = requestWithTimeout(BackendConfig.directorTimeoutSeconds, function()
		return HttpService:RequestAsync({
			Url = BackendConfig.baseUrl .. BackendConfig.directorPath,
			Method = "POST",
			Headers = { ["Content-Type"] = "application/json" },
			Body = body,
		})
	end)

	if not ok then
		return false, nil, tostring(result)
	end

	local response = result :: any
	if not response.Success then
		return false, nil, `HTTP {response.StatusCode}`
	end

	local decodeOk, decoded = pcall(HttpService.JSONDecode, HttpService, response.Body)
	if not decodeOk or typeof(decoded) ~= "table" then
		return false, nil, "invalid_response_json"
	end

	return true, decoded :: { [string]: any }, nil
end

local function buildRunState(elapsed: number): { [string]: any }
	local squad = {}
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		table.insert(squad, {
			pid = TelemetryService.pidFor(player.UserId),
			hp = if humanoid then math.floor(humanoid.Health) else 0,
			weight = math.floor(LootService.carriedWeight(player.UserId)),
			-- Not tracked live per-player yet -- see this file's header comment.
			kills = 0,
			deaths = 0,
			zone = "unknown",
		})
	end

	return {
		runId = TelemetryService.describe().runId,
		t = math.floor(elapsed),
		squad = squad,
		pressure = {
			aliveEnemies = EntityService.count(),
			-- No source yet -- Budget.luau is not wired into EntityService.
			budgetSpent = 0,
			recentPlayerDamage = 0,
			recentEnemyDeaths = 0,
		},
		pacing = {
			secondsSinceLastFight = math.floor(sinceFight),
			secondsSinceLastLull = math.floor(context.secondsSinceLastLull),
			fsmState = context.state,
		},
		objective = { active = context.lastDecision.objective.id, progress = 0 },
		history = history,
	}
end

local function recordHistory(decision: Schema.DirectorDecision, elapsed: number)
	table.insert(history, `{decision.intent} at {math.floor(elapsed)}s`)
	if #history > HISTORY_SIZE then
		table.remove(history, 1)
	end
end

--- One director tick: apply whatever proposal arrived since the last
--- boundary, step the FSM, then fire the next async request. Exposed
--- directly (not just via the 20s loop) so Studio diagnostics can force one
--- on demand instead of waiting out the real cadence.
function DirectorService.tick()
	local run = RunLifecycleService.getState()
	local elapsed = if run then run.elapsedSeconds else 0

	local proposal = pendingProposal
	pendingProposal = nil

	local hits = CombatService.getMetrics().hits
	if hits > lastHitCount then
		sinceFight = 0
	end
	lastHitCount = hits

	local input: Fsm.FsmInput = {
		elapsedSeconds = elapsed,
		pressure = { aliveEnemies = EntityService.count(), budgetSpent = 0, recentPlayerDamage = 0, recentEnemyDeaths = 0 },
		squadHpFraction = squadHpFraction(),
		secondsSinceLastFight = sinceFight,
	}
	local fsmDecision = Fsm.step(context, input, TICK_INTERVAL_SECONDS)

	local decision = Clamp.apply(proposal, fsmDecision, Schema.DEFAULT_BOUNDS)

	-- Clamp already guarantees decision.objective.id is a real whitelist id
	-- (M4-5's half of the split). This is the other half: is it available
	-- *right now*, or still cooling down from having just been active.
	local previousObjective = currentDecision.objective
	local wasActive = objectiveState.activeId
	local resolvedObjectiveId = ObjectivesCore.resolve(objectiveState, decision.objective.id, elapsed)
	if resolvedObjectiveId ~= decision.objective.id then
		-- Rejected: keep whatever was already active, params included -- an
		-- objective in progress does not restart just because a competing
		-- id was proposed and blocked by its own cooldown.
		decision.objective = { id = resolvedObjectiveId, params = previousObjective.params }
	end
	ObjectivesCore.issue(objectiveState, resolvedObjectiveId, elapsed, COOLDOWN_SECONDS_BY_ID)
	if resolvedObjectiveId ~= wasActive then
		TelemetryService.emit("objective.issued", { id = resolvedObjectiveId, previousId = wasActive, tSeconds = elapsed })
	end

	currentDecision = decision
	if proposal == nil then
		metrics.fallbacks += 1
	end
	recordHistory(decision, elapsed)

	-- Filtering yields (a real network-backed Roblox service call) and must
	-- never happen on the tick path itself -- docs/05 §Content filtering.
	local bark = decision.bark
	local intent = decision.intent
	local requestingUserId = hostUserId()
	task.spawn(function()
		filteredBark = filterBark(bark, intent, requestingUserId)
	end)

	TelemetryService.emit("director.decision", {
		intent = decision.intent,
		spawnMultiplier = decision.spawnMultiplier,
		spawnPattern = decision.spawnPattern,
		objectiveId = decision.objective.id,
		threatTier = decision.threatTier,
		fallbackUsed = proposal == nil,
		latencyMs = metrics.lastLatencyMs,
		model = metrics.lastModel,
		promptVersion = metrics.lastPromptVersion,
	})

	if inFlight then
		metrics.skipped += 1
		return
	end
	if now() < breakerOpenUntil then
		return
	end

	inFlight = true
	local payload = buildRunState(elapsed)
	task.spawn(function()
		local start = now()
		local ok, result, err = callDirectorTick(payload)
		metrics.lastLatencyMs = (now() - start) * 1000
		metrics.calls += 1

		local proposalOut: unknown = nil
		if ok and result then
			metrics.lastModel = tostring(result.model or "")
			metrics.lastPromptVersion = tostring(result.promptVersion or "")
			if result.proposal ~= nil then
				proposalOut = result.proposal
			else
				err = tostring(result.error or "unknown")
			end
		end

		if proposalOut ~= nil then
			pendingProposal = proposalOut
			consecutiveFailures = 0
			metrics.lastError = ""
		else
			consecutiveFailures += 1
			metrics.lastError = err or "unknown"
			if consecutiveFailures >= BackendConfig.breakerThreshold then
				breakerOpenUntil = now() + BackendConfig.breakerOpenSeconds
				consecutiveFailures = 0
			end
		end

		inFlight = false
	end)
end

function DirectorService.start()
	if running then
		return
	end
	running = true
	task.spawn(function()
		while running do
			local ok, err = pcall(DirectorService.tick)
			if not ok then
				warn(`[DirectorService] tick errored: {err}`)
			end
			task.wait(TICK_INTERVAL_SECONDS)
		end
	end)
end

function DirectorService.stop()
	running = false
end

function DirectorService.getDecision(): Schema.DirectorDecision
	return currentDecision
end

--- The filtered, display-ready bark -- what M4-9's HUD panel should read,
--- never `getDecision().bark` directly.
function DirectorService.getFilteredBark(): string
	return filteredBark
end

--- M4-7 Studio smoke test hook: filters a bark synchronously (this yields,
--- which a BindableFunction handler may do) and returns the result, so a
--- diagnostics call can force a real failure (an invalid `requestingUserId`
--- like 0 genuinely fails `FilterStringAsync`, no test-only mock needed)
--- and assert a canned line came back instead of raw text.
function DirectorService.forceFilterBark(rawBark: string, intent: string, requestingUserId: number): string
	return filterBark(rawBark, intent, requestingUserId)
end

function DirectorService.describe(): { [string]: any }
	return {
		fsmState = context.state,
		decision = currentDecision,
		filteredBark = filteredBark,
		calls = metrics.calls,
		fallbacks = metrics.fallbacks,
		skipped = metrics.skipped,
		lastLatencyMs = metrics.lastLatencyMs,
		lastError = metrics.lastError,
		lastModel = metrics.lastModel,
		lastPromptVersion = metrics.lastPromptVersion,
		breakerOpenFor = math.max(0, breakerOpenUntil - now()),
		inFlight = inFlight,
	}
end

return DirectorService
