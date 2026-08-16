--!strict
--[[ M2-7. Run lifecycle.

	The rule with the most gameplay riding on it is that extraction is
	individual: one player leaving must not end the run, and must not make it
	easier for whoever stays.
]]

local t = require("./framework")
local expect = t.expect

local Run = require("../src/shared/core/sim/Run")
local Budget = require("../src/shared/core/sim/Budget")
local Branding = require("../src/shared/config/Branding")
local Zones = require("../src/shared/config/Zones")

local SCHEDULE: Run.PadSchedule = {
	Perimeter = Zones.Perimeter.padOpensAt,
	Processing = Zones.Processing.padOpensAt,
	Vault = Zones.Vault.padOpensAt,
}

local function newRun(playerIds: { number }?): Run.RunState
	return Run.new(1234, Branding.runLengthSeconds, playerIds or { 1, 2, 3 })
end

local function advance(state: Run.RunState, seconds: number): { Run.Event }
	local all: { Run.Event } = {}
	for _ = 1, math.floor(seconds) do
		for _, event in Run.step(state, 1, SCHEDULE) do
			table.insert(all, event)
		end
	end
	return all
end

local function kinds(events: { Run.Event }): { string }
	local out: { string } = {}
	for _, event in events do
		table.insert(out, event.kind)
	end
	return out
end

--------------------------------------------------------------------------------

t.describe("Run clock", function()
	t.it("starts at the full run length", function()
		local state = newRun()
		expect(state.elapsedSeconds).toEqual(0)
		expect(Run.secondsRemaining(state)).toEqual(720)
		expect(state.complete).toBeFalsy()
	end)

	t.it("counts down and ends exactly at the cap", function()
		local state = newRun()
		advance(state, 719)
		expect(state.complete).toBeFalsy()
		expect(Run.secondsRemaining(state)).toEqual(1)

		Run.step(state, 1, SCHEDULE)
		expect(state.complete).toBeTruthy()
		expect(state.endReason).toEqual("timeout")
		expect(Run.secondsRemaining(state)).toEqual(0)
	end)

	t.it("ignores a non-finite or negative dt rather than corrupting the clock", function()
		local state = newRun()
		Run.step(state, 0 / 0, SCHEDULE)
		Run.step(state, -50, SCHEDULE)
		Run.step(state, math.huge, SCHEDULE)
		expect(state.elapsedSeconds).toEqual(0)
	end)

	t.it("stops producing events once complete", function()
		local state = newRun()
		advance(state, 720)
		expect(#Run.step(state, 10, SCHEDULE)).toEqual(0)
	end)
end)

t.describe("Run pad schedule", function()
	t.it("opens each pad at its configured time, shallowest first", function()
		local state = newRun()
		expect(Run.isPadOpen(state, "Perimeter")).toBeFalsy()

		advance(state, 179)
		expect(Run.isPadOpen(state, "Perimeter")).toBeFalsy()
		Run.step(state, 1, SCHEDULE)
		expect(Run.isPadOpen(state, "Perimeter")).toBeTruthy()
		expect(Run.isPadOpen(state, "Processing")).toBeFalsy()

		advance(state, 180)
		expect(Run.isPadOpen(state, "Processing")).toBeTruthy()
		expect(Run.isPadOpen(state, "Vault")).toBeFalsy()

		advance(state, 180)
		expect(Run.isPadOpen(state, "Vault")).toBeTruthy()
		expect(Run.openZones(state)).toEqual({ "Perimeter", "Processing", "Vault" })
	end)

	t.it("reports each pad opening exactly once", function()
		local state = newRun()
		local opened: { [string]: number } = {}
		for _ = 1, 700 do
			for _, event in Run.step(state, 1, SCHEDULE) do
				if event.kind == "padOpened" then
					opened[event.zone] = (opened[event.zone] or 0) + 1
				end
			end
		end
		expect(opened.Perimeter).toEqual(1)
		expect(opened.Processing).toEqual(1)
		expect(opened.Vault).toEqual(1)
	end)

	t.it("orders deepest last when one long tick crosses several thresholds", function()
		-- A hitch must not report the Vault pad opening before the Perimeter's.
		local state = newRun()
		local events = Run.step(state, 600, SCHEDULE)
		local zones: { string } = {}
		for _, event in events do
			if event.kind == "padOpened" then
				table.insert(zones, event.zone)
			end
		end
		expect(zones).toEqual({ "Perimeter", "Processing", "Vault" })
	end)
end)

t.describe("Run extraction", function()
	t.it("refuses extraction before the pad opens", function()
		local state = newRun()
		local ok, reason = Run.tryExtract(state, 1, "Perimeter")
		expect(ok).toBeFalsy()
		expect(reason).toEqual("padClosed")
		expect(state.players[1].status).toEqual("active")
	end)

	t.it("banks what the player carried and clears it", function()
		local state = newRun()
		Run.setCarried(state, 1, 44, 2600)
		advance(state, 180)

		local ok = Run.tryExtract(state, 1, "Perimeter")
		expect(ok).toBeTruthy()
		expect(state.players[1].status).toEqual("extracted")
		expect(state.players[1].bankedValue).toEqual(2600)
		expect(state.players[1].carriedValue).toEqual(0)
		expect(state.players[1].carriedWeight).toEqual(0)
	end)

	t.it("does not end the run for everyone else", function()
		-- The design's social pressure point. If this regresses, the whole
		-- risk/reward loop collapses into "first one out ends it".
		local state = newRun({ 1, 2, 3 })
		advance(state, 180)
		Run.tryExtract(state, 1, "Perimeter")

		expect(state.complete).toBeFalsy()
		expect(Run.activeCount(state)).toEqual(2)
		expect(state.players[2].status).toEqual("active")
		expect(state.players[3].status).toEqual("active")
	end)

	t.it("does not make the run easier for whoever stays", function()
		-- Enemy budget is computed from the squad that dropped, not the squad
		-- that is left, so leaving raises the pressure on the rest.
		local state = newRun({ 1, 2, 3 })
		local before = Budget.compute(300, Run.budgetHeadcount(state), 1.5, 1.0)

		advance(state, 180)
		Run.tryExtract(state, 1, "Perimeter")
		Run.kill(state, 2)

		expect(Run.activeCount(state)).toEqual(1)
		expect(Run.budgetHeadcount(state)).toEqual(3)
		expect(Budget.compute(300, Run.budgetHeadcount(state), 1.5, 1.0)).toEqual(before)
	end)

	t.it("refuses a second extraction, an unknown player, and a finished run", function()
		local state = newRun()
		advance(state, 180)
		expect(Run.tryExtract(state, 1, "Perimeter")).toBeTruthy()

		local ok, reason = Run.tryExtract(state, 1, "Perimeter")
		expect(ok).toBeFalsy()
		expect(reason).toEqual("notActive")

		local ok2, reason2 = Run.tryExtract(state, 999, "Perimeter")
		expect(ok2).toBeFalsy()
		expect(reason2).toEqual("notInRun")

		advance(state, 720)
		local ok3, reason3 = Run.tryExtract(state, 2, "Perimeter")
		expect(ok3).toBeFalsy()
		expect(reason3).toEqual("runOver")
	end)

	t.it("ends the run once nobody is left active", function()
		local state = newRun({ 1, 2 })
		advance(state, 180)
		Run.tryExtract(state, 1, "Perimeter")
		expect(state.complete).toBeFalsy()

		Run.kill(state, 2)
		Run.step(state, 1, SCHEDULE)
		expect(state.complete).toBeTruthy()
		expect(state.endReason).toEqual("squadResolved")
	end)
end)

t.describe("Run death", function()
	t.it("drops everything carried and banks nothing", function()
		local state = newRun()
		Run.setCarried(state, 1, 55, 4100)

		local died, dropped = Run.kill(state, 1)
		expect(died).toBeTruthy()
		expect(dropped).toEqual(4100)
		expect(state.players[1].status).toEqual("dead")
		expect(state.players[1].bankedValue).toEqual(0)
		expect(state.players[1].carriedValue).toEqual(0)
	end)

	t.it("cannot kill the same player twice or drop their loot twice", function()
		local state = newRun()
		Run.setCarried(state, 1, 20, 900)
		expect(select(2, Run.kill(state, 1))).toEqual(900)

		local died, dropped = Run.kill(state, 1)
		expect(died).toBeFalsy()
		expect(dropped).toEqual(0)
	end)

	t.it("cannot pick anything up after dying", function()
		local state = newRun()
		Run.kill(state, 1)
		Run.setCarried(state, 1, 80, 9999)
		expect(state.players[1].carriedValue).toEqual(0)
	end)

	t.it("treats running out the clock as dying", function()
		-- Standing on loot when the timer expires must not bank it.
		local state = newRun({ 1 })
		Run.setCarried(state, 1, 70, 5000)
		local events = advance(state, 720)

		expect(state.players[1].status).toEqual("dead")
		expect(state.players[1].bankedValue).toEqual(0)
		local seen = kinds(events)
		expect(seen[#seen]).toEqual("runEnded")
		expect(seen[#seen - 1]).toEqual("died")
	end)
end)

t.describe("Run summary", function()
	t.it("accounts for every player exactly once", function()
		local state = newRun({ 1, 2, 3, 4 })
		advance(state, 180)
		Run.setCarried(state, 1, 10, 1000)
		Run.setCarried(state, 2, 10, 2000)
		Run.tryExtract(state, 1, "Perimeter")
		Run.tryExtract(state, 2, "Perimeter")
		Run.kill(state, 3)

		local summary = Run.summary(state)
		expect(summary.extracted).toEqual(2)
		expect(summary.died).toEqual(1)
		expect(summary.active).toEqual(1)
		expect(summary.extracted + summary.died + summary.active).toEqual(4)
		expect(summary.bankedValue).toEqual(3000)
		expect(summary.startingHeadcount).toEqual(4)
	end)

	t.it("ignores duplicate player ids at the drop", function()
		local state = Run.new(1, 720, { 7, 7, 7 })
		expect(state.startingHeadcount).toEqual(1)
		expect(#state.order).toEqual(1)
	end)
end)
