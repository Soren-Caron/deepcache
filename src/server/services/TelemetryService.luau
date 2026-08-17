--!strict
--[[ M3-1 (adapter) / M3-2. Buffers events and ships them to the backend.

	The buffer, the flush rules and the drop accounting are pure
	(`core/telemetry/Buffer`). This owns the parts that can fail: `HttpService`,
	the clock, retries, and the shutdown grace period.

	The governing rule from docs/04 is that telemetry must never block
	gameplay. Everything here is consequently best-effort:

	  - `emit` only appends to a ring. It never yields and never errors.
	  - Flushing happens on its own coroutine, not on the tick loop.
	  - Every HTTP call is wrapped; a dead backend produces counted drops, not
	    an error at a call site that was only trying to record a pickup.

	`HttpService` is capped at 500 requests/minute per server, so a permanently
	unreachable backend must not be allowed to retry in a loop — hence the
	breaker.
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")

local Buffer = require(Shared.core.telemetry.Buffer)
local Hmac = require(Shared.core.telemetry.Hmac)

local BackendConfig = require("../config/Backend")

local TelemetryService = {}

local buffer = Buffer.new()
local context = {
	runId = "unassigned",
	serverId = "studio",
	placeId = 0,
	pid = nil :: string?,
}

local flushing = false
local running = false
local consecutiveFailures = 0
local breakerOpenUntil = 0
local metrics = {
	posted = 0,
	failed = 0,
	batchesDropped = 0,
	lastError = "" :: string,
	lastStatus = 0,
	--- Events drained from the ring but not yet acknowledged. Reported
	--- separately because the retry ladder takes 15 seconds, and during it the
	--- ring reads empty — a dashboard showing `queued = 0` while 200 events sit
	--- in limbo is worse than no number at all.
	inFlight = 0,
}

local function now(): number
	return os.clock()
end

--- Pseudonymous id for a player. Computed here so the raw user id never
--- reaches a payload.
function TelemetryService.pidFor(userId: number): string
	return Hmac.pid(userId, BackendConfig.playerSalt)
end

--- Append an event. Cheap, non-yielding, and safe to call from anywhere
--- including a tick phase.
function TelemetryService.emit(eventType: string, payload: { [string]: any }?, userId: number?)
	local eventContext = {
		runId = context.runId,
		serverId = context.serverId,
		placeId = context.placeId,
		pid = if userId then TelemetryService.pidFor(userId) else nil,
	}
	Buffer.push(buffer, eventType, payload or {}, eventContext, os.time())
end

function TelemetryService.setRun(runId: string)
	context.runId = runId
end

--- NDJSON: one envelope per line. The backend validates and commits per line,
--- so one malformed event cannot cost the whole batch.
local function serialise(batch: { Buffer.Envelope }, dropped: number): string
	local lines: { string } = {}
	for _, envelope in batch do
		local ok, encoded = pcall(HttpService.JSONEncode, HttpService, envelope)
		if ok then
			table.insert(lines, encoded)
		end
	end
	if dropped > 0 then
		-- Loss rides the next successful batch, so a hole in the data is
		-- always visible as a number rather than only as a gap in `seq`.
		local ok, encoded = pcall(HttpService.JSONEncode, HttpService, {
			v = Buffer.ENVELOPE_VERSION,
			ts = os.time(),
			runId = context.runId,
			serverId = context.serverId,
			placeId = context.placeId,
			type = "telemetry.dropped",
			seq = buffer.seq,
			p = { count = dropped },
		})
		if ok then
			table.insert(lines, encoded)
		end
	end
	return table.concat(lines, "\n")
end

local function post(body: string): (boolean, string)
	local timestamp = os.time()
	local nonce = HttpService:GenerateGUID(false)
	local signature = Hmac.signRequest(BackendConfig.sharedSecret, timestamp, nonce, body)

	local ok, result = pcall(function()
		return HttpService:RequestAsync({
			Url = BackendConfig.baseUrl .. BackendConfig.ingestPath,
			Method = "POST",
			Headers = {
				["Content-Type"] = "application/x-ndjson",
				["X-Deepcache-Timestamp"] = tostring(timestamp),
				["X-Deepcache-Nonce"] = nonce,
				["X-Deepcache-Signature"] = signature,
			},
			Body = body,
		})
	end)

	if not ok then
		return false, tostring(result)
	end
	local response = result :: any
	metrics.lastStatus = response.StatusCode
	if not response.Success then
		return false, `HTTP {response.StatusCode}: {tostring(response.Body):sub(1, 200)}`
	end
	return true, ""
end

--- Send one batch, with the documented backoff. Returns whether it landed.
local function flushOnce(force: boolean?): boolean
	if flushing then
		return false
	end
	if not BackendConfig.enabled then
		return false
	end
	if not force and now() < breakerOpenUntil then
		return false
	end
	if Buffer.count(buffer) == 0 then
		return false
	end

	flushing = true
	local batch, dropped = Buffer.drain(buffer, now())
	metrics.inFlight = #batch
	local body = serialise(batch, dropped)

	local landed = false
	local lastError = ""
	for attempt = 1, #BackendConfig.retryBackoffSeconds do
		local ok, err = post(body)
		if ok then
			landed = true
			break
		end
		lastError = err
		if attempt < #BackendConfig.retryBackoffSeconds and not force then
			task.wait(BackendConfig.retryBackoffSeconds[attempt])
		else
			break
		end
	end

	if landed then
		Buffer.commit(buffer)
		metrics.posted += #batch
		consecutiveFailures = 0
		-- A successful flush ends an outage. Leaving the previous failure's
		-- message in place would have `describe()` report a live error
		-- alongside a buffer that is demonstrably healthy again — caught
		-- during the M3-8 failure drill, where a flush that had just landed
		-- still showed `lastError = HttpError: ConnectFail` from the attempt
		-- before it.
		metrics.lastError = ""
	else
		metrics.failed += 1
		metrics.lastError = lastError
		consecutiveFailures += 1
		-- Keep the events rather than discarding them: `requeue` is bounded
		-- and drops the oldest if the ring fills, so holding them costs
		-- nothing that the ring was not already going to cost.
		Buffer.requeue(buffer, batch)
		metrics.batchesDropped += 1

		if consecutiveFailures >= BackendConfig.breakerThreshold then
			-- HttpService allows 500 requests/minute per server. A backend
			-- that is down must not be allowed to spend that budget finding
			-- out repeatedly.
			breakerOpenUntil = now() + BackendConfig.breakerOpenSeconds
			consecutiveFailures = 0
		end
	end

	metrics.inFlight = 0
	flushing = false
	return landed
end

TelemetryService.flushOnce = flushOnce

function TelemetryService.start()
	if running then
		return
	end
	running = true

	context.serverId = if RunService:IsStudio() and game.JobId == "" then "studio-local" else game.JobId
	context.placeId = game.PlaceId

	task.spawn(function()
		while running do
			task.wait(1)
			if Buffer.shouldFlush(buffer, now()) then
				flushOnce()
			end
		end
	end)

	-- docs/04: a forced flush with a grace period, so the last events of a run
	-- are not lost to the shutdown that ends it.
	game:BindToClose(function()
		TelemetryService.emit("server.shutdown", { queued = Buffer.count(buffer) })
		local deadline = now() + 3
		while Buffer.count(buffer) > 0 and now() < deadline do
			if not flushOnce(true) then
				break
			end
		end
	end)
end

function TelemetryService.stop()
	running = false
end

function TelemetryService.describe(): { [string]: any }
	local stats = Buffer.stats(buffer)
	stats.posted = metrics.posted
	stats.failedFlushes = metrics.failed
	stats.lastStatus = metrics.lastStatus
	stats.inFlight = metrics.inFlight
	return {
		buffer = stats,
		lastError = metrics.lastError,
		breakerOpenFor = math.max(0, breakerOpenUntil - now()),
		enabled = BackendConfig.enabled,
		runId = context.runId,
		serverId = context.serverId,
	}
end

return TelemetryService
