--!strict
--[[ Sound cue scheduling.

	Pure, because the two rules that make game audio survive contact with a
	swarm are both arithmetic and both easy to get wrong in a way you only
	notice with forty enemies on screen:

	  - **Throttling.** Twenty Skitters landing hits in the same tick must not
	    start twenty copies of one sound. Beyond a handful, additional voices
	    add loudness and nothing else, and Roblox will happily start all of
	    them. Each cue gets a minimum interval.
	  - **Pitch variation.** The same sample at the same pitch, fired eight
	    times a second, stops reading as eight shots and starts reading as a
	    machine fault. A few percent of jitter fixes it.

	Time is injected, so a burst that takes a second in play takes microseconds
	to test.
]]

local Cues = {}

export type State = {
	--- Last time each cue was allowed, by name.
	lastPlayed: { [string]: number },
	--- Cues suppressed by the throttle, for the diagnostic. A cue that is
	--- silently dropped and never counted is indistinguishable from one that
	--- was never wired up.
	suppressed: number,
	played: number,
}

function Cues.new(): State
	return { lastPlayed = {}, suppressed = 0, played = 0 }
end

--- May `cue` start right now?
---
--- Records the decision, so callers must not ask twice for one sound.
function Cues.shouldPlay(state: State, cue: string, now: number, minIntervalSeconds: number): boolean
	if now ~= now or now == math.huge or now == -math.huge then
		return false
	end

	local last = state.lastPlayed[cue]
	-- A cue never played before is always allowed, whatever the interval.
	if last ~= nil and now - last < minIntervalSeconds then
		state.suppressed += 1
		return false
	end

	state.lastPlayed[cue] = now
	state.played += 1
	return true
end

--- Playback rate for one instance of a cue.
---
--- `roll` is a 0..1 sample from the caller's RNG; passing it in rather than
--- drawing one keeps this deterministic and testable. `jitter` is a fraction:
--- 0.06 means +/-6%.
function Cues.pitch(roll: number, jitter: number): number
	if roll ~= roll or jitter ~= jitter or jitter <= 0 then
		return 1
	end
	local clamped = math.clamp(roll, 0, 1)
	-- Map 0..1 onto -jitter..+jitter around unity.
	return 1 + (clamped * 2 - 1) * jitter
end

--- Volume for a sound heard `distance` studs away, given a rolloff maximum.
---
--- Roblox's own rolloff handles positional audio, so this exists only for the
--- cues played flat on the client -- a hit confirmation, a reload -- where
--- there is no emitter to attach to but distance still ought to matter.
function Cues.attenuate(distance: number, maxDistance: number): number
	if distance ~= distance or maxDistance <= 0 then
		return 0
	end
	if distance <= 0 then
		return 1
	end
	if distance >= maxDistance then
		return 0
	end
	local fraction = 1 - distance / maxDistance
	-- Squared, so the falloff is gentle near the player and steep at the edge,
	-- which is how loudness actually behaves.
	return fraction * fraction
end

function Cues.reset(state: State)
	state.lastPlayed = {}
	state.suppressed = 0
	state.played = 0
end

return Cues
