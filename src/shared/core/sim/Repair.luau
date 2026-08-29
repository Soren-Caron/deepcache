--!strict
--[[ Field repair: a channelled heal on a finite number of charges.

	Until now there was no healing at all. A player had 100 HP, Roblox's
	default 1 HP/s regeneration, and a twelve-minute run -- so forty damage
	cost forty seconds of walking it off, and a bad thirty seconds in the
	Perimeter was unrecoverable rather than expensive.

	The shape is chosen to keep the run's tension rather than remove it:

	  - **Charges are finite and do not refill mid-run.** A regenerating heal
	    turns every fight into a war of attrition the player always wins by
	    waiting. Finite charges make "do I burn one here" a real question, and
	    it is the same question the whole game is about.
	  - **It is channelled, not instant.** Standing still for a few seconds in
	    a room that just tried to kill you is the cost. This is what makes the
	    sweep and the heal work together: you buy space, then you spend it.
	  - **Damage cancels it, and the charge is *not* refunded.** Refunding
	    would make a cancelled channel free, so the correct play would be to
	    spam it whenever hurt. Losing the charge means you commit.

	Pure, with time injected: a 2.5-second channel is testable in microseconds
	and the interrupt edges can be hit exactly rather than approached by
	playing.
]]

local Repair = {}

export type State = {
	chargesLeft: number,
	--- When the current channel began, or nil when not channelling.
	startedAt: number?,
	--- HP the player had when the channel began, so a heal cannot be stacked
	--- on top of damage taken during it.
	hpAtStart: number,
	completed: number,
	interrupted: number,
}

export type Params = {
	charges: number,
	healAmount: number,
	channelSeconds: number,
}

local function isFinite(value: number): boolean
	return value == value and value ~= math.huge and value ~= -math.huge
end

function Repair.new(params: Params): State
	return {
		chargesLeft = params.charges,
		startedAt = nil,
		hpAtStart = 0,
		completed = 0,
		interrupted = 0,
	}
end

--- Whether a channel is running.
function Repair.isChannelling(state: State): boolean
	return state.startedAt ~= nil
end

--- Start a repair. Returns `(false, reason)` rather than throwing.
---
--- The charge is spent *here*, not on completion. See the header: a refund on
--- interruption would make cancelling free.
function Repair.begin(state: State, now: number, currentHp: number, maxHp: number, params: Params): (boolean, string?)
	if not isFinite(now) then
		return false, "bad_clock"
	end
	if state.startedAt ~= nil then
		return false, "already_repairing"
	end
	if state.chargesLeft <= 0 then
		return false, "no_charges"
	end
	if currentHp >= maxHp then
		return false, "already_full"
	end
	if currentHp <= 0 then
		return false, "dead"
	end

	state.chargesLeft -= 1
	state.startedAt = now
	state.hpAtStart = currentHp
	return true
end

--- 0..1 through the current channel, or 0 when not channelling.
function Repair.progress(state: State, now: number, params: Params): number
	local started = state.startedAt
	if started == nil or params.channelSeconds <= 0 or not isFinite(now) then
		return 0
	end
	return math.clamp((now - started) / params.channelSeconds, 0, 1)
end

--- Has the channel finished? Returns the heal to apply, which is 0 until it
--- has. Clears the channel on completion.
function Repair.collect(state: State, now: number, params: Params): (boolean, number)
	if state.startedAt == nil then
		return false, 0
	end
	if Repair.progress(state, now, params) < 1 then
		return false, 0
	end
	state.startedAt = nil
	state.completed += 1
	return true, params.healAmount
end

--- Stop a channel without healing. Used when the player takes damage, moves
--- out of the run, or dies.
---
--- Returns whether anything was actually cancelled, so a caller can avoid
--- reporting an interrupt that did not happen -- being told the repair was
--- interrupted when you were not repairing is worse than silence.
function Repair.cancel(state: State): boolean
	if state.startedAt == nil then
		return false
	end
	state.startedAt = nil
	state.interrupted += 1
	return true
end

function Repair.reset(state: State, params: Params)
	state.chargesLeft = params.charges
	state.startedAt = nil
	state.hpAtStart = 0
	state.completed = 0
	state.interrupted = 0
end

return Repair
