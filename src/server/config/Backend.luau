--!strict
--[[ Server-only backend configuration.

	Lives under `src/server` (ServerScriptService), **not** `src/shared`. Shared
	replicates to every client, and the ingest secret and player salt must never
	leave the server — a salt a client can read makes `pid` reversible by anyone
	who can also see their own user id.

	The values here are local development defaults. A published place should
	override them at boot from somewhere the repository does not contain; they
	are committed only so the loop closes on one machine with no accounts, which
	is the whole reason docs/04 chose a local Postgres backend.
]]

return {
	--- Studio and a local server can both reach 127.0.0.1. A published place
	--- cannot, which is what M6-11 (deploy) exists to fix.
	baseUrl = "http://127.0.0.1:8787",
	ingestPath = "/v1/ingest",
	directorPath = "/v1/director/tick",
	--- Slack above the backend's own internal 1200ms Ollama timeout (M4-3),
	--- not a repeat of that number: this covers network + JSON round trip on
	--- top of a budget the backend has already enforced on its side. Not the
	--- same knob as "should the tick budget itself be longer" -- that product
	--- question is open, see docs/metrics/m4.md.
	directorTimeoutSeconds = 1.6,

	--- Shared with the backend's INGEST_SECRET.
	sharedSecret = "dev-ingest-secret-change-me",
	--- Never leaves the server. Rotating it invalidates every historical pid,
	--- which is the point of having it.
	playerSalt = "dev-player-salt-change-me",

	--- Set false to run the game with no backend at all. Events still buffer
	--- and still count drops, so the telemetry path stays exercised.
	enabled = true,

	--- Consecutive failed flushes before the breaker opens.
	breakerThreshold = 3,
	breakerOpenSeconds = 60,

	--- docs/04: 1s, 2s, 4s, 8s, then give up on this attempt.
	retryBackoffSeconds = { 1, 2, 4, 8 },
}
