--!strict
--[[ Field repair: a channelled heal on a finite number of charges.

	Until now there was no healing at all. A player had 100 HP -- Roblox's
	Humanoid default, never set by this project -- its default 1 HP/s
	regeneration, and a twelve-minute run, so forty damage cost forty seconds
	of walking it off and a bad thirty seconds in the Perimeter was
	unrecoverable rather than expensive. The pool is now
	`Combat.PLAYER_MAX_HEALTH`.

	The shape is chosen to keep the run's tension rather than remove it:

	  - **A completed channel heals to full, whatever the deficit.** The charge
	    is the resource, not the health: a fixed 45-point repair meant a charge
	    was worth less the healthier you were, so the optimal play was to sit at
	    low HP before spending one. Healing to full makes the decision about
	    *when* rather than about squeezing value out of the number, and it is
	    what makes the scarcity legible -- two charges is two mistakes.
	  - **Charges are finite and do not refill mid-run.** A regenerating heal
	    turns every fight into a war of attrition the player always wins by
	    waiting. Finite charges make "do I burn one here" a real question, and
	    it is the same question the whole game is about. This is now the *only*
	    thing limiting healing, which is why it has to stay small.
	  - **It is channelled, not instant.** Standing still for a couple of
	    seconds in a room that just tried to kill you is the cost. This is what
	    makes the sweep and the heal work together: you buy space, then you
	    spend it.
	  - **Health arrives on an accelerating curve, not all at the end.** A flat
	    channel that pays out only on completion feels dead for its whole
	    duration -- you hold a key and nothing happens until it either works or
	    does not. Paying continuously against `progress^2` means the bar moves
	    immediately, so the ability feels responsive, while most of the value
	    still lands in the final third: the commitment is preserved and the
	    deadness is not.
	  - **Damage cancels it, and the charge is *not* refunded.** Refunding
	    would make a cancelled channel free, so the correct play would be to
	    spam it whenever hurt. Losing the charge means you commit. An
	    interrupted channel keeps whatever health it had already paid out --
	    that is the accelerating curve's other half, and it is why bailing
	    early is weak rather than worthless.

	Pure, with time injected: the whole channel is testable in microseconds
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
	--- Total health this channel will pay if it completes: the deficit at the
	--- moment it began. Fixed at `begin` rather than recomputed per tick, so a
	--- channel cannot grow to cover damage taken while it runs.
	healTotal: number,
	--- Health already paid out during the current channel. Reset per channel;
	--- what makes the payout continuous rather than all-or-nothing.
	applied: number,
	completed: number,
	interrupted: number,
}

export type Params = {
	charges: number,
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
		healTotal = 0,
		applied = 0,
		completed = 0,
		interrupted = 0,
	}
end

--- Fraction of the total heal delivered by `progress` through the channel.
---
--- Squared, so the rate accelerates: half way through has paid a quarter, and
--- the final third carries over half the value. That is what makes the bar
--- move the instant the key goes down while still rewarding finishing.
function Repair.healedFraction(progress: number): number
	local p = math.clamp(progress, 0, 1)
	return p * p
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
	state.healTotal = maxHp - currentHp
	state.applied = 0
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

--- Health owed since the last call, and whether the channel just finished.
---
--- Called every tick while channelling. Returns a *delta*, so the caller adds
--- it rather than setting an absolute -- health taken during the channel stays
--- taken. **Every delta must be applied, not just the completing one:** the
--- payout is spread across the whole channel, so banking only the last tick's
--- slice pays a few percent of the heal.
function Repair.collect(state: State, now: number, params: Params): (boolean, number)
	if state.startedAt == nil then
		return false, 0
	end

	local progress = Repair.progress(state, now, params)
	local owed = state.healTotal * Repair.healedFraction(progress)
	local delta = math.max(0, owed - state.applied)
	state.applied += delta

	if progress < 1 then
		return false, delta
	end

	state.startedAt = nil
	state.completed += 1
	return true, delta
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
	state.healTotal = 0
	state.applied = 0
	state.completed = 0
	state.interrupted = 0
end

return Repair
