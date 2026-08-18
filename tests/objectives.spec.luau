--!strict
--[[ M4-8. Objective cooldown gate. Clamp.luau already covers "is this id in
	the whitelist"; these tests are about the other half of that split --
	"and is it available right now" -- which is the part that needs state.
]]

local t = require("./framework")
local expect = t.expect

local Objectives = require("../src/shared/core/director/Objectives")

local COOLDOWNS = {
	purge_node = 120,
	hold_terminal = 150,
	escort_cart = 240,
	no_loot_window = 180,
	hunt_warden = 300,
}

t.describe("Objectives.new / isAvailable", function()
	t.it("starts with the initial id active and everything else available", function()
		local state = Objectives.new("hold_terminal")
		expect(state.activeId).toEqual("hold_terminal")
		expect(Objectives.isAvailable(state, "purge_node", 0)).toBeTruthy()
		expect(Objectives.isAvailable(state, "hunt_warden", 0)).toBeTruthy()
	end)

	t.it("an id never issued is always available, at any timestamp", function()
		local state = Objectives.new("hold_terminal")
		expect(Objectives.isAvailable(state, "escort_cart", 999999)).toBeTruthy()
	end)
end)

t.describe("Objectives.issue", function()
	t.it("a genuine change starts the PREVIOUS objective's cooldown, not the new one's", function()
		local state = Objectives.new("hold_terminal")
		Objectives.issue(state, "purge_node", 100, COOLDOWNS)

		expect(state.activeId).toEqual("purge_node")
		-- hold_terminal (now inactive) is on cooldown until 100 + 150.
		expect(Objectives.isAvailable(state, "hold_terminal", 100)).toBeFalsy()
		expect(Objectives.isAvailable(state, "hold_terminal", 249)).toBeFalsy()
		expect(Objectives.isAvailable(state, "hold_terminal", 250)).toBeTruthy()
		-- purge_node, now active, has no cooldown of its own yet.
		expect(Objectives.isAvailable(state, "purge_node", 100)).toBeTruthy()
	end)

	t.it("re-issuing the id already active is a no-op -- holding steady must not reset anything", function()
		local state = Objectives.new("hold_terminal")
		Objectives.issue(state, "hold_terminal", 100, COOLDOWNS)
		expect(state.activeId).toEqual("hold_terminal")
		-- Nothing went on cooldown: hold_terminal is still active, not "on cooldown against itself."
		expect(Objectives.isAvailable(state, "hold_terminal", 100)).toBeTruthy()

		Objectives.issue(state, "hold_terminal", 500, COOLDOWNS)
		expect(Objectives.isAvailable(state, "hold_terminal", 500)).toBeTruthy()
	end)

	t.it("cooldown durations differ per objective and are looked up by the PREVIOUS id, not a flat default", function()
		local state = Objectives.new("hunt_warden")
		Objectives.issue(state, "purge_node", 0, COOLDOWNS)
		-- hunt_warden's own cooldown is 300, distinct from purge_node's 120.
		expect(Objectives.isAvailable(state, "hunt_warden", 120)).toBeFalsy()
		expect(Objectives.isAvailable(state, "hunt_warden", 299)).toBeFalsy()
		expect(Objectives.isAvailable(state, "hunt_warden", 300)).toBeTruthy()
	end)

	t.it("an id with no known cooldown duration defaults to immediately available again", function()
		local state = Objectives.new("hold_terminal")
		Objectives.issue(state, "purge_node", 0, {}) -- empty cooldown table
		expect(Objectives.isAvailable(state, "hold_terminal", 0)).toBeTruthy()
	end)
end)

t.describe("Objectives.resolve", function()
	t.it("accepts a candidate that is not on cooldown", function()
		local state = Objectives.new("hold_terminal")
		expect(Objectives.resolve(state, "purge_node", 0)).toEqual("purge_node")
	end)

	t.it("rejects a candidate on cooldown and keeps the currently active objective instead", function()
		local state = Objectives.new("hold_terminal")
		Objectives.issue(state, "purge_node", 0, COOLDOWNS)
		-- hold_terminal just went on cooldown; proposing it again immediately
		-- must not interrupt purge_node, which is legitimately still running.
		expect(Objectives.resolve(state, "hold_terminal", 1)).toEqual("purge_node")
	end)

	t.it("accepts a previously-cooling-down candidate once its cooldown has elapsed", function()
		local state = Objectives.new("hold_terminal")
		Objectives.issue(state, "purge_node", 0, COOLDOWNS)
		expect(Objectives.resolve(state, "hold_terminal", 250)).toEqual("hold_terminal")
	end)

	t.it("a full rotation: each objective cools down after leaving and is rejected until it elapses", function()
		local state = Objectives.new("purge_node")
		local t_ = 0

		local function advanceTo(candidate: string, expectResolved: string, atSeconds: number)
			t_ = atSeconds
			local resolved = Objectives.resolve(state, candidate, t_)
			expect(resolved).toEqual(expectResolved)
			Objectives.issue(state, resolved, t_, COOLDOWNS)
		end

		advanceTo("hold_terminal", "hold_terminal", 20)
		-- purge_node was active at t=0, left at t=20, so it is on cooldown
		-- until 20+120=140. Proposing it again at t=40 must be rejected.
		advanceTo("purge_node", "hold_terminal", 40)
		expect(state.activeId).toEqual("hold_terminal")

		advanceTo("purge_node", "purge_node", 140)
		expect(state.activeId).toEqual("purge_node")
	end)
end)
