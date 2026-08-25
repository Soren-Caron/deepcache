--!strict
--[[ Reload timing.

	`CombatService.reload` has existed since M2-5 and refills a magazine
	instantly. Nothing ever called it outside diagnostics, and `reloadSeconds`
	— defined for all four weapons — was read by nothing anywhere in `src/`.
	So in a real session a Sidearm held 14 rounds and then was dry for the rest
	of the run.

	This is the part that was missing: *when* a reload finishes, and what a
	player may do while it runs. Kept pure because the interesting cases are
	all timing edges, and none of them need an engine to reproduce.

	Reserves are infinite by design. The economy already charges for ammo as a
	run-end sink (`EconomyService.onRunEnd`), so a finite reserve would be
	double-counting the same cost in two systems; docs/07 treats ammo as a
	credit sink, not as an inventory item.

	Time is an injected parameter, never read from a clock — the pure-core
	rule, and the reason a 2.8 s Slug reload can be tested in microseconds.
]]

local Reload = {}

export type State = {
	--- weaponId -> the time its in-flight reload completes. Absent means idle.
	completesAt: { [string]: number },
}

export type Weapon = {
	magazine: number,
	reloadSeconds: number,
}

local function isFinite(value: number): boolean
	return value == value and value ~= math.huge and value ~= -math.huge
end

function Reload.new(): State
	return { completesAt = {} }
end

function Reload.isReloading(state: State, weaponId: string, now: number): boolean
	local due = state.completesAt[weaponId]
	if due == nil then
		return false
	end
	if not isFinite(now) then
		-- A poisoned clock must not silently end every reload in flight.
		return true
	end
	return now < due
end

--- Begin a reload. Returns `(false, reason)` rather than throwing, per the
--- server-validation convention: every caller here is ultimately a remote.
function Reload.begin(
	state: State,
	weaponId: string,
	weapon: Weapon,
	currentAmmo: number,
	now: number
): (boolean, string?)
	if not isFinite(now) then
		return false, "bad_clock"
	end
	if Reload.isReloading(state, weaponId, now) then
		return false, "already_reloading"
	end
	-- Reloading a full magazine is not an error the player should be punished
	-- for -- it is a keypress with nothing to do -- but it must not restart the
	-- timer either, or holding R would lock a weapon out of firing forever.
	if currentAmmo >= weapon.magazine then
		return false, "magazine_full"
	end

	local duration = weapon.reloadSeconds
	if not isFinite(duration) or duration < 0 then
		duration = 0
	end
	state.completesAt[weaponId] = now + duration
	return true
end

--- Weapons whose reload has finished as of `now`, cleared as they are
--- reported. Returns them rather than refilling anything: the magazine lives
--- on the server and this module may not know what one is.
function Reload.collect(state: State, now: number): { string }
	local done: { string } = {}
	if not isFinite(now) then
		return done
	end
	for weaponId, due in state.completesAt do
		if now >= due then
			table.insert(done, weaponId)
		end
	end
	-- Sorted so a tick that completes two reloads reports them in a stable
	-- order, which keeps a replayed session identical.
	table.sort(done)
	for _, weaponId in done do
		state.completesAt[weaponId] = nil
	end
	return done
end

--- Abandon an in-flight reload. Switching away from a weapon cancels it: a
--- reload you walked away from should not finish in your pocket, and letting
--- it would make swapping the fastest way to reload everything at once.
function Reload.cancel(state: State, weaponId: string)
	state.completesAt[weaponId] = nil
end

function Reload.cancelAll(state: State)
	state.completesAt = {}
end

--- Fraction elapsed, 0..1, for a progress readout. Returns 1 when idle.
function Reload.progress(state: State, weaponId: string, weapon: Weapon, now: number): number
	local due = state.completesAt[weaponId]
	if due == nil or not isFinite(now) then
		return 1
	end
	local duration = weapon.reloadSeconds
	if not isFinite(duration) or duration <= 0 then
		return 1
	end
	local remaining = due - now
	if remaining <= 0 then
		return 1
	end
	return math.clamp(1 - remaining / duration, 0, 1)
end

function Reload.pendingCount(state: State): number
	local n = 0
	for _ in state.completesAt do
		n += 1
	end
	return n
end

return Reload
