--!strict
--[[ M2-7. Run lifecycle: the clock, the pad schedule, extraction and death.

	The rules that make the loop a loop, kept pure so they can be tested without
	a play session:

	  - Twelve minutes, hard cap.
	  - Pads open on a schedule, deepest last. A pad that opens later is further
	    in and pays better.
	  - **Extraction is individual.** One player leaving does not end the run for
	    the others. It makes it *harder*, because the enemy budget is computed
	    from the headcount the run started with and never scales back down. That
	    is the social pressure point and it is deliberate (docs/01).
	  - Death drops everything carried this run. The stash is untouched.

	Time is injected. Nothing here reads a clock.
]]

local Run = {}

export type PlayerStatus = "active" | "extracted" | "dead"

export type PlayerState = {
	id: number,
	status: PlayerStatus,
	carriedWeight: number,
	carriedValue: number,
	endedAtSeconds: number?,
	bankedValue: number,
}

export type RunState = {
	seed: number,
	elapsedSeconds: number,
	lengthSeconds: number,
	--- Headcount at the drop. Enemy budget uses this for the whole run.
	startingHeadcount: number,
	players: { [number]: PlayerState },
	order: { number },
	openPads: { [string]: boolean },
	complete: boolean,
	endReason: string?,
}

export type Event =
	{ kind: "padOpened", zone: string }
	| { kind: "extracted", playerId: number, value: number }
	| { kind: "died", playerId: number, droppedValue: number }
	| { kind: "runEnded", reason: string }

--- `{ [zone] = secondsUntilOpen }`, from `Zones[zone].padOpensAt`.
export type PadSchedule = { [string]: number }

function Run.new(seed: number, lengthSeconds: number, playerIds: { number }): RunState
	local players: { [number]: PlayerState } = {}
	local order: { number } = {}
	for _, id in playerIds do
		if players[id] == nil then
			players[id] = {
				id = id,
				status = "active",
				carriedWeight = 0,
				carriedValue = 0,
				endedAtSeconds = nil,
				bankedValue = 0,
			}
			table.insert(order, id)
		end
	end

	return {
		seed = seed,
		elapsedSeconds = 0,
		lengthSeconds = math.max(1, lengthSeconds),
		startingHeadcount = #order,
		players = players,
		order = order,
		openPads = {},
		complete = false,
		endReason = nil,
	}
end

function Run.secondsRemaining(state: RunState): number
	return math.max(0, state.lengthSeconds - state.elapsedSeconds)
end

function Run.isPadOpen(state: RunState, zone: string): boolean
	return state.openPads[zone] == true
end

--- Players still in the level. Distinct from `startingHeadcount`, which is what
--- the enemy budget uses.
function Run.activeCount(state: RunState): number
	local n = 0
	for _, player in state.players do
		if player.status == "active" then
			n += 1
		end
	end
	return n
end

--- The headcount enemy scaling uses: the squad that dropped, not the squad
--- that is left. Extracting early makes the run harder for whoever stays.
function Run.budgetHeadcount(state: RunState): number
	return state.startingHeadcount
end

local function finish(state: RunState, reason: string, events: { Event })
	if state.complete then
		return
	end
	state.complete = true
	state.endReason = reason
	table.insert(events, { kind = "runEnded", reason = reason })
end

--- Advance the clock. Returns everything that changed, in the order it
--- happened, so the adapter can fire remotes and telemetry without diffing
--- state itself.
function Run.step(state: RunState, dt: number, schedule: PadSchedule): { Event }
	local events: { Event } = {}
	if state.complete then
		return events
	end

	local step = if dt == dt and dt ~= math.huge then math.max(0, dt) else 0
	state.elapsedSeconds += step

	-- Pads open in schedule order, so a single long tick that crosses two
	-- thresholds still reports them deepest-last rather than in table order.
	local pending: { { zone: string, at: number } } = {}
	for zone, openAt in schedule do
		if not state.openPads[zone] and state.elapsedSeconds >= openAt then
			table.insert(pending, { zone = zone, at = openAt })
		end
	end
	table.sort(pending, function(a, b)
		if a.at ~= b.at then
			return a.at < b.at
		end
		return a.zone < b.zone
	end)
	for _, entry in pending do
		state.openPads[entry.zone] = true
		table.insert(events, { kind = "padOpened", zone = entry.zone })
	end

	if state.elapsedSeconds >= state.lengthSeconds then
		-- Anyone still in the level when the clock runs out loses what they
		-- carried, same as dying. The timer is the whole tension.
		for _, id in state.order do
			local player = state.players[id]
			if player.status == "active" then
				player.status = "dead"
				player.endedAtSeconds = state.elapsedSeconds
				table.insert(events, { kind = "died", playerId = id, droppedValue = player.carriedValue })
				player.carriedValue = 0
				player.carriedWeight = 0
			end
		end
		finish(state, "timeout", events)
		return events
	end

	if Run.activeCount(state) == 0 then
		finish(state, "squadResolved", events)
	end

	return events
end

--- Attempt to extract. Refusals are ordinary gameplay, so this returns a reason
--- rather than throwing.
function Run.tryExtract(state: RunState, playerId: number, zone: string): (boolean, string?)
	if state.complete then
		return false, "runOver"
	end
	local player = state.players[playerId]
	if player == nil then
		return false, "notInRun"
	end
	if player.status ~= "active" then
		return false, "notActive"
	end
	if not Run.isPadOpen(state, zone) then
		return false, "padClosed"
	end

	player.status = "extracted"
	player.endedAtSeconds = state.elapsedSeconds
	player.bankedValue = player.carriedValue
	player.carriedValue = 0
	player.carriedWeight = 0
	return true, nil
end

--- Kill a player. Returns what they dropped, which the caller scatters on the
--- ground — teammates can pick it up, which is the point.
function Run.kill(state: RunState, playerId: number): (boolean, number)
	local player = state.players[playerId]
	if player == nil or player.status ~= "active" then
		return false, 0
	end
	local dropped = player.carriedValue
	player.status = "dead"
	player.endedAtSeconds = state.elapsedSeconds
	player.carriedValue = 0
	player.carriedWeight = 0
	return true, dropped
end

--- Track what a player is carrying. The authoritative weight lives here so the
--- movement penalty and the payout agree on one number.
function Run.setCarried(state: RunState, playerId: number, weight: number, value: number)
	local player = state.players[playerId]
	if player == nil or player.status ~= "active" then
		return
	end
	player.carriedWeight = math.max(0, if weight == weight then weight else 0)
	player.carriedValue = math.max(0, if value == value then value else 0)
end

--- Which zones a player may extract from right now.
function Run.openZones(state: RunState): { string }
	local out: { string } = {}
	for zone, open in state.openPads do
		if open then
			table.insert(out, zone)
		end
	end
	table.sort(out)
	return out
end

function Run.summary(state: RunState): { [string]: any }
	local extracted, died, active, banked = 0, 0, 0, 0
	for _, player in state.players do
		if player.status == "extracted" then
			extracted += 1
			banked += player.bankedValue
		elseif player.status == "dead" then
			died += 1
		else
			active += 1
		end
	end
	return {
		seed = state.seed,
		elapsedSeconds = state.elapsedSeconds,
		remaining = Run.secondsRemaining(state),
		complete = state.complete,
		endReason = state.endReason,
		startingHeadcount = state.startingHeadcount,
		extracted = extracted,
		died = died,
		active = active,
		bankedValue = banked,
		openPads = Run.openZones(state),
	}
end

return Run
