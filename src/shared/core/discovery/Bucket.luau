--!strict
--[[ M5-2. Skill bucketing and the widening schedule. See docs/06 §Bucketing
	and widening.

	Buckets are 100 rating points wide, indexed by `floor(rating / 100)` --
	a player at 1250 is bucket 12, matching docs/06's own worked example
	exactly. `floor` is a pure function of one input, so "no player in two
	buckets" holds by construction: there is exactly one bucket for any
	given rating, never an ambiguous boundary case.

	The widening schedule is a five-stage function of wait time alone. The
	last stage matters most: a matchmaker that only optimizes match quality
	produces a queue nobody finishes waiting in.

	**Replaces a pre-existing M0 scaffold** (`Bucket.of`, and a single
	`Bucket.window(rating, waitedSeconds): SearchWindow` returning
	`{centre, spread, acceptAny, startUndersized}`) that this file didn't
	check for before designing its own three-function split (`bucketFor` /
	`stageFor` / `inSearchRange`). The split is arguably easier to test in
	isolation; the original's single compound object is arguably a cleaner
	call site. Kept this shape after confirming nothing else in the repo
	referenced the original names yet.
]]

export type WideningStage = "own" | "radius1" | "radius2" | "any" | "undersized"

local Bucket = {}

Bucket.WIDTH = 100

--- Wait-time thresholds, in seconds, from docs/06's table.
local RADIUS1_AT = 15
local RADIUS2_AT = 30
local ANY_AT = 45
local UNDERSIZED_AT = 75

function Bucket.bucketFor(rating: number): number
	return math.floor(rating / Bucket.WIDTH)
end

--- Which stage of the widening schedule applies at `waitSeconds`. Order of
--- the checks matters: undersized must win over any at 75s+, so it is
--- checked first, not last.
function Bucket.stageFor(waitSeconds: number): WideningStage
	if waitSeconds >= UNDERSIZED_AT then
		return "undersized"
	elseif waitSeconds >= ANY_AT then
		return "any"
	elseif waitSeconds >= RADIUS2_AT then
		return "radius2"
	elseif waitSeconds >= RADIUS1_AT then
		return "radius1"
	else
		return "own"
	end
end

--- Whether `candidateBucket` is a legal match for someone in `ownBucket` at
--- the given stage. "undersized" returns true unconditionally -- at that
--- stage the caller is starting the run regardless of who else is queued,
--- so every candidate is trivially "in range" for whatever squad forms.
function Bucket.inSearchRange(ownBucket: number, candidateBucket: number, stage: WideningStage): boolean
	if stage == "own" then
		return candidateBucket == ownBucket
	elseif stage == "radius1" then
		return math.abs(candidateBucket - ownBucket) <= 1
	elseif stage == "radius2" then
		return math.abs(candidateBucket - ownBucket) <= 2
	end
	-- "any" and "undersized" both search everyone; they differ in what the
	-- caller does with that, not in who counts as a candidate.
	return true
end

return Bucket
