--!strict
--[[ M5-2. Queue bucketing and the widening schedule.

	A matchmaker that optimises purely for match quality produces a queue
	nobody finishes waiting in. The 75s undersized-start rule is the release
	valve. See docs/06-MATCHMAKING-DISCOVERY.md.
]]

local Bucket = {}

export type SearchWindow = {
	centre: number,
	spread: number,
	acceptAny: boolean,
	startUndersized: boolean,
}

Bucket.WIDTH = 100
Bucket.WIDEN_AT = { { 15, 1 }, { 30, 2 } }
Bucket.ANY_AT = 45
Bucket.UNDERSIZED_AT = 75

function Bucket.of(rating: number): number
	error("unimplemented: Bucket.of (M5-2)")
end

function Bucket.window(rating: number, waitedSeconds: number): SearchWindow
	error("unimplemented: Bucket.window (M5-2)")
end

return Bucket
