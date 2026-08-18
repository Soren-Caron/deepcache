--!strict
--[[ M4-10. Deterministic A/B arm assignment. Accept criterion from
	tasks/BACKLOG.md: over 1,000 simulated runs, arm split within 48-52%.
]]

local t = require("./framework")
local expect = t.expect

local AbTest = require("../src/shared/core/director/AbTest")

t.describe("AbTest.assignArm", function()
	t.it("is deterministic: the same runId always gets the same arm", function()
		local runId = "01HX9F3K2M-deadbeef"
		local first = AbTest.assignArm(runId)
		for _ = 1, 20 do
			expect(AbTest.assignArm(runId)).toEqual(first)
		end
	end)

	t.it("returns only 'A' or 'B'", function()
		for i = 1, 50 do
			local arm = AbTest.assignArm(`run-{i}`)
			expect(arm == "A" or arm == "B").toBeTruthy()
		end
	end)

	t.it("different runIds are not all assigned the same arm", function()
		local seen: { [string]: boolean } = {}
		for i = 1, 30 do
			seen[AbTest.assignArm(`varied-run-id-{i}-{i * 7919}`)] = true
		end
		expect(seen.A).toBeTruthy()
		expect(seen.B).toBeTruthy()
	end)

	t.it("over 1,000 simulated runs, the arm split is within 48-52%", function()
		local countA = 0
		local countB = 0
		for i = 1, 1000 do
			-- Mirrors the real runId shape (seed-guid), not just a bare counter,
			-- so this exercises the same string shape production actually hashes.
			local runId = `{i}-{string.format("%08x-%04x-%04x", i * 2654435761 % 0x100000000, i % 0x10000, (i * 31) % 0x10000)}`
			local arm = AbTest.assignArm(runId)
			if arm == "A" then
				countA += 1
			else
				countB += 1
			end
		end

		local fractionA = countA / 1000
		expect(fractionA >= 0.48).toBeTruthy()
		expect(fractionA <= 0.52).toBeTruthy()
		expect(countA + countB).toEqual(1000)
	end)
end)
