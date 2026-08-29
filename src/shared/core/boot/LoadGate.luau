--!strict
--[[ Boot sequencing for the loading screen.

	Roblox's own loading screen goes away once the *engine* has loaded, which
	is several seconds before this game has anything to look at: the level is
	generated on the server and parented to Workspace in one go, so the client
	spends that time looking at an unlit black room with a HUD drawn over it.
	That reads as a broken game rather than a loading one.

	This owns the part of that which is decidable without Roblox: which gates
	have opened, how far along that is, what to call the current one, and when
	it is safe to let go. The adapter owns reading the gates and drawing.

	Three rules the shape here exists to enforce:

	  - **Gates latch.** A gate is a question the adapter asks every frame
	    ("does Workspace.Level exist yet?"), and some of them can flicker --
	    `ContentProvider.RequestQueueSize` drops to zero and then rises again
	    as more geometry streams in. Latching the *answer* rather than clamping
	    the *number* is what makes the bar monotonic, and it means the reason
	    it never rewinds is stated once here instead of being a `math.max` the
	    next reader has to reverse-engineer.
	  - **There is a floor and a ceiling on how long it shows.** A screen that
	    flashes for one frame is worse than no screen, so `minSeconds` holds it.
	    A screen that never leaves is worse than a black room, so
	    `timeoutSeconds` forces it away and says so, rather than trapping the
	    player behind a gate that is never going to open.
	  - **The bar stops short of full until it is actually done.** Sitting at
	    100% while still waiting is the thing that makes a loading screen feel
	    hung.

	Time is injected, so the timeout and the minimum can be tested exactly
	instead of by waiting.
]]

local LoadGate = {}

--- One question the adapter answers each frame. `id` is the contract between
--- this module and the adapter; `weight` is roughly how long it takes, so the
--- bar moves at a believable rate rather than in five equal jumps.
export type Step = {
	id: string,
	label: string,
	weight: number,
}

export type Params = {
	steps: { Step },
	--- Held at least this long even if everything is instantly ready, so a warm
	--- client does not get a one-frame flash of loading screen.
	minSeconds: number,
	--- Let go regardless after this, and report that we did.
	timeoutSeconds: number,
	--- Shown once every gate is open.
	readyLabel: string,
}

export type State = {
	startedAt: number,
	--- Gates seen open at least once. Latched: see the header.
	latched: { [string]: boolean },
}

export type Report = {
	progress: number,
	label: string,
	--- Safe to dismiss the screen.
	complete: boolean,
	--- Dismissed on the timeout with gates still shut. Worth logging: it means
	--- one of the gates is wrong, and the player saw the black room anyway.
	timedOut: boolean,
	elapsed: number,
}

--- Highest the bar goes before everything is genuinely ready. A full bar that
--- is still waiting reads as a hang.
local ALMOST = 0.99

local function isFinite(value: number): boolean
	return value == value and value ~= math.huge and value ~= -math.huge
end

function LoadGate.new(now: number): State
	return {
		startedAt = if isFinite(now) then now else 0,
		latched = {},
	}
end

--- Total weight, so weights can be written at any scale.
local function totalWeight(params: Params): number
	local total = 0
	for _, step in params.steps do
		total += math.max(0, step.weight)
	end
	return total
end

--- Fold this frame's gate readings in, and report where that leaves us.
---
--- `open` is read for the declared step ids only; anything else in it is
--- ignored, so an adapter reporting a gate that was renamed or removed cannot
--- quietly count toward completion.
function LoadGate.update(state: State, open: { [string]: boolean }, now: number, params: Params): Report
	local elapsed = if isFinite(now) then math.max(0, now - state.startedAt) else 0

	for _, step in params.steps do
		if open[step.id] == true then
			state.latched[step.id] = true
		end
	end

	local total = totalWeight(params)
	local done = 0
	local pending: string? = nil
	for _, step in params.steps do
		if state.latched[step.id] then
			done += math.max(0, step.weight)
		elseif pending == nil then
			pending = step.label
		end
	end

	local allOpen = pending == nil
	local timedOut = elapsed >= params.timeoutSeconds
	local complete = timedOut or (allOpen and elapsed >= params.minSeconds)

	local progress = if total > 0 then done / total else 1
	if not complete then
		progress = math.min(progress, ALMOST)
	else
		progress = 1
	end

	return {
		progress = progress,
		label = pending or params.readyLabel,
		complete = complete,
		timedOut = timedOut and not allOpen,
		elapsed = elapsed,
	}
end

--- Frame-rate independent approach toward `target`.
---
--- The bar is animated rather than snapped because the gates open in a few
--- large jumps -- geometry alone is most of the wait -- and a bar that teleports
--- from 10% to 70% reads as a glitch. Exponential rather than linear so it
--- never quite arrives early and never overshoots.
function LoadGate.eased(shown: number, target: number, dt: number, rate: number): number
	if not isFinite(shown) or not isFinite(target) then
		return shown
	end
	if not isFinite(dt) or dt <= 0 or rate <= 0 then
		return shown
	end
	return shown + (target - shown) * (1 - math.exp(-rate * dt))
end

return LoadGate
