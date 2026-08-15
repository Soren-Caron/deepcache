--!strict
--[[ Pure data. No functions, no requires. See docs/03-NETCODE.md. ]]

return {
	TICK_RATE = 20,
	TICK_SECONDS = 1 / 20,

	SNAPSHOT_MAX_BYTES = 900, -- UnreliableRemoteEvent drops above ~1000. Do not raise.
	SNAPSHOT_HEADER_BYTES = 5,
	SNAPSHOT_ENTITY_BYTES = 11,
	KEYFRAME_INTERVAL = 20,

	INTEREST_RADIUS = 150,
	INTEREST_MAX = 32,

	RENDER_DELAY_MIN = 0.10,
	RENDER_DELAY_MAX = 0.20,
	EXTRAPOLATE_MAX = 0.08,

	HISTORY_TICKS = 20,
	LAGCOMP_WINDOW = 0.25,

	ORIGIN_TOLERANCE = 8,
	SPEED_MARGIN = 1.35,
	TELEPORT_THRESHOLD = 40,
	VIOLATION_DECAY_PER_SEC = 1.0,
	VIOLATION_CORRECT_AT = 5,
	VIOLATION_KICK_AT = 20,

	TICK_BUDGET_MS = 12,

	-- Raised from 6 after measurement. 32 visible entities all changing every
	-- tick costs (5 + 32*11) * 20 = 7140 B/s = 6.97 KB/s, so a 6 KB/s budget
	-- and a 32-entity interest cap were mutually unsatisfiable — only 27
	-- entities fit 6 KB/s. Seeing the crowd matters more in a shooter than
	-- 1 KB/s, and 6 KB/s was an invented target rather than a platform limit
	-- (the real constraint is the ~1000-byte packet cap, which we are well
	-- under at 357 B). validate-config now cross-checks these two so the
	-- inconsistency cannot reappear.
	BANDWIDTH_BUDGET_KBPS = 8,
}
