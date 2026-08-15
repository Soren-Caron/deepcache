--!strict
--[[
	Verifies the test framework detects the failures it claims to detect.

		lune run tools/selftest

	Why this is separate from tests/framework.spec.luau: proving "a failing
	assertion is recorded as a failure" requires deliberately failing an
	assertion, which would make the main suite permanently red. A suite that
	is never green is a suite whose colour carries no information.

	Run this whenever tests/framework.luau changes. It is wired into CI.
]]

local process = require("@lune/process")
local stdio = require("@lune/stdio")

local framework = require("../tests/framework")

local problems: { string } = {}

local function check(label: string, condition: boolean, detail: string?)
	if condition then
		stdio.write(stdio.color("green") .. "  ok   " .. stdio.color("reset") .. label .. "\n")
	else
		table.insert(problems, label .. (detail and ` — {detail}` or ""))
		stdio.write(stdio.color("red") .. "  FAIL " .. stdio.color("reset") .. label .. "\n")
		if detail then
			stdio.write(`         {detail}\n`)
		end
	end
end

-- A passing test increments `passed` and nothing else ------------------------

framework.reset()
framework.it("passes", function()
	framework.expect(1).toEqual(1)
end)
local s = framework.getStats()
check("passing test increments passed", s.passed == 1, `passed = {s.passed}`)
check("passing test records no failure", s.failed == 0 and #s.failures == 0, `failed = {s.failed}`)

-- A failing assertion is recorded, and does not propagate --------------------

framework.reset()
framework.it("fails", function()
	framework.expect(1).toEqual(2)
end)
s = framework.getStats()
check("failing assertion increments failed", s.failed == 1, `failed = {s.failed}`)
check("failing assertion is captured with a message", #s.failures == 1 and #s.failures[1].message > 0)
check("failing assertion does not increment passed", s.passed == 0, `passed = {s.passed}`)

-- A raw error (not an assertion) is also caught ------------------------------

framework.reset()
framework.it("throws", function()
	error("boom")
end)
s = framework.getStats()
check("raw error is caught as a failure", s.failed == 1)
check("raw error message is preserved", string.find(s.failures[1].message, "boom", 1, true) ~= nil, s.failures[1].message)

-- A throwing suite body is caught, not fatal ---------------------------------

framework.reset()
framework.describe("bad suite", function()
	error("suite exploded")
end)
s = framework.getStats()
check("throwing suite body is recorded, not fatal", s.failed == 1)

-- todo() is pending, never a failure -----------------------------------------

framework.reset()
framework.todo("something unimplemented")
s = framework.getStats()
check("todo increments todo", s.todo == 1, `todo = {s.todo}`)
check("todo does not increment failed", s.failed == 0, `failed = {s.failed}`)
check("todo is listed separately from failures", #s.todos == 1 and #s.failures == 0)

-- reset() actually resets ----------------------------------------------------

framework.reset()
s = framework.getStats()
check(
	"reset clears all counters",
	s.passed == 0 and s.failed == 0 and s.todo == 0 and #s.failures == 0 and #s.todos == 0
)

-- Report ---------------------------------------------------------------------

stdio.write("\n")
if #problems > 0 then
	stdio.write(stdio.color("red") .. `framework selftest FAILED ({#problems} problem(s))` .. stdio.color("reset") .. "\n\n")
	process.exit(1)
end
stdio.write(stdio.color("green") .. "framework selftest passed" .. stdio.color("reset") .. "\n\n")
process.exit(0)
