--!strict
--[[ M5-1. Glicko-style skill rating.

	Plain Elo is wrong for co-op PvE: there is no opponent. The "opponent" is
	the run's difficulty, and `rd` carries how confident we are.
]]

local Rating = {}

export type Rating = {
	r: number,
	rd: number,
	lastSeenTs: number,
}

export type RunOutcome = {
	extracted: boolean,
	valueExtracted: number,
	deaths: number,
	objectivesCompleted: number,
	objectivesIssued: number,
	runDifficulty: number,
	squadMeanRating: number,
	ts: number,
}

Rating.START_R = 1200
Rating.START_RD = 350
Rating.MIN_RD = 50
Rating.MAX_RD = 350

function Rating.new(ts: number): Rating
	error("unimplemented: Rating.new (M5-1)")
end

function Rating.update(current: Rating, outcome: RunOutcome): Rating
	error("unimplemented: Rating.update (M5-1)")
end

--- rd grows with time since last seen, so returning players re-calibrate.
function Rating.decay(current: Rating, nowTs: number): Rating
	error("unimplemented: Rating.decay (M5-1)")
end

return Rating
