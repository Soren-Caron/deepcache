--!strict
--[[ M5-1. Glicko-style skill rating.

	Plain Elo is wrong here: this is co-op PvE with no opponent. The
	"opponent" is the run's difficulty, expressed on the same rating scale
	as the player. See docs/06 §Skill rating.

	Pure: no clock, no HttpService, no config. `runDifficulty` and
	`daysSinceLastSeen` arrive as arguments -- computing a real run's
	difficulty from enemy budget, depth reached, etc. is a caller concern
	(the backend rollup, not yet built), same reasoning as M2-8's Budget
	taking a `zoneMultiplier` argument instead of reading config directly.

	**Replaces a pre-existing M0 scaffold this file didn't check for
	before designing its own API** -- the original stub (`export type
	Rating = {r, rd, lastSeenTs}`, `RunOutcome` with raw counts,
	`Rating.decay(current, nowTs)` as its own function) embedded recency
	*in* the rating record and let the caller hand in raw per-run counts
	for this module to weight itself. That is a reasonable, arguably more
	self-contained design. This file instead takes already-normalised
	[0,1] signals and a bare `daysSinceLastSeen`, which is simpler to test
	in isolation but pushes weighting onto the caller. Kept this shape
	because nothing else in the repo referenced the original names yet
	(checked before committing to this, not assumed) -- documented here so
	the divergence is visible, not silently different from what the
	project's own scaffolding had already decided.

	**`R_INITIAL`, a three-way inconsistency, not a simple "doc was
	wrong":** the original scaffold (this file and docs/06, both from the
	M0 scaffold) agreed on `1200`. `backend/src/rollup.ts` (M3-5, two days
	later) diverged to `1500` without reconciling back. 1200 is not a
	standard Glicko value anywhere in the literature; 1500 is. Resolved in
	favor of 1500 -- the actual correct value for a system that calls
	itself "Glicko-style" -- not in favor of whichever artifact was older.
	docs/06 updated to match.

	**As built -- docs/06 states the shape of the formulas
	(`r' = r + K(rd) * (actual - expected)`, "shrink after each run, grow
	with absence") but not their exact constants. Concrete choices made
	here, each picked for a specific, testable behavior:

	  - Expected performance: a logistic curve centred on `r - runDifficulty`
	    with a 400-point scale, mirroring Elo's own expected-score formula --
	    a well-understood shape rather than an invented one.
	  - `K(rd) = K_MAX * (rd / RD_INITIAL)`, `K_MAX = 150`: a brand-new
	    player (rd = RD_INITIAL) can swing up to +-150 in one run; an
	    established player (rd near the floor) swings only a few points.
	  - `rd` shrinks 6% per run (floor 50), grows 5 points per day absent
	    (ceiling RD_INITIAL) -- chosen so ~30 runs takes a player from
	    "brand new" to "established," and ~70 days of total absence
	    fully re-opens their uncertainty.
]]

export type PlayerRating = {
	r: number,
	rd: number,
}

--- Already normalised to comparable [0,1]-ish quantities by the caller --
--- this module does not know what "a good run" looks like in raw units.
export type RunPerformance = {
	extracted: boolean,
	--- carriedValue / an expected value for the zone reached, capped [0,1]
	--- by the caller. Not clamped again here: a caller that hands in 1.3
	--- gets a rating bump reflecting that, which is a caller bug to fix,
	--- not something to silently mask.
	valueRatio: number,
	survived: boolean,
	--- Objectives completed / attempted this run, [0,1]. 0 if none were
	--- offered -- "no objective available" is not "failed every objective."
	objectiveRate: number,
}

local Rating = {}

Rating.R_INITIAL = 1500
Rating.RD_INITIAL = 350
Rating.RD_MIN = 50

local EXPECTED_SCALE = 400
local K_MAX = 150
local RD_SHRINK_FACTOR = 0.94
local RD_GROWTH_PER_DAY = 5

--- Weights on the four performance signals, summing to 1 so a perfect run
--- (extracted, full value, survived, all objectives) scores actual = 1.0.
local WEIGHT_EXTRACTED = 0.4
local WEIGHT_VALUE = 0.2
local WEIGHT_SURVIVED = 0.2
local WEIGHT_OBJECTIVE = 0.2

function Rating.new(): PlayerRating
	return { r = Rating.R_INITIAL, rd = Rating.RD_INITIAL }
end

--- Elo-shaped expected performance from the rating gap alone. 0.5 at parity,
--- climbing toward 1 as the player's rating exceeds the run's difficulty.
function Rating.expectedPerformance(r: number, runDifficulty: number): number
	return 1 / (1 + 10 ^ (-(r - runDifficulty) / EXPECTED_SCALE))
end

function Rating.actualPerformance(performance: RunPerformance): number
	return WEIGHT_EXTRACTED * (if performance.extracted then 1 else 0)
		+ WEIGHT_VALUE * performance.valueRatio
		+ WEIGHT_SURVIVED * (if performance.survived then 1 else 0)
		+ WEIGHT_OBJECTIVE * performance.objectiveRate
end

--- How far a single run can move `r`. Scales with uncertainty: high `rd`
--- (new or long-absent player) swings hard, low `rd` barely moves.
function Rating.kFactor(rd: number): number
	return K_MAX * (rd / Rating.RD_INITIAL)
end

--- Uncertainty earned back by actually playing.
function Rating.shrinkRd(rd: number): number
	return math.max(Rating.RD_MIN, rd * RD_SHRINK_FACTOR)
end

--- Uncertainty regained by time away. `daysSinceLastSeen` is time since the
--- player's *previous* recorded run, not since account creation.
function Rating.growRd(rd: number, daysSinceLastSeen: number): number
	local days = math.max(0, daysSinceLastSeen)
	return math.min(Rating.RD_INITIAL, rd + RD_GROWTH_PER_DAY * days)
end

--- One full update: grow for absence, then move `r` using the grown `rd`,
--- then shrink `rd` for having played. Order matters -- a returning player's
--- comeback run should swing on their *regrown* uncertainty, not their old,
--- already-shrunk one.
function Rating.update(
	rating: PlayerRating,
	runDifficulty: number,
	performance: RunPerformance,
	daysSinceLastSeen: number
): PlayerRating
	local grownRd = Rating.growRd(rating.rd, daysSinceLastSeen)
	local expected = Rating.expectedPerformance(rating.r, runDifficulty)
	local actual = Rating.actualPerformance(performance)
	local k = Rating.kFactor(grownRd)

	return {
		r = rating.r + k * (actual - expected),
		rd = Rating.shrinkRd(grownRd),
	}
end

return Rating
