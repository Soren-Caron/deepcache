--!strict
--[[
	Self-test for the test framework.

	This exists because a test runner that silently reports success is worse
	than no runner at all. These assertions verify that the framework can
	actually detect the failures it claims to detect.

	The "does a failing assertion get recorded" case is checked in
	tools/selftest.luau rather than here — asserting it inline would require
	deliberately failing a test inside the suite that counts failures.
]]

local t = require("./framework")
local expect = t.expect

t.describe("framework/expect", function()
	t.it("toEqual passes on identical primitives", function()
		expect(42).toEqual(42)
		expect("hello").toEqual("hello")
		expect(true).toEqual(true)
	end)

	t.it("toEqual deep-compares tables", function()
		expect({ a = 1, b = { 2, 3 } }).toEqual({ a = 1, b = { 2, 3 } })
	end)

	t.it("toEqual rejects tables with extra keys", function()
		expect(function()
			expect({ a = 1 }).toEqual({ a = 1, b = 2 })
		end).toThrow()
	end)

	t.it("toEqual rejects tables with differing values", function()
		expect(function()
			expect({ a = 1 }).toEqual({ a = 2 })
		end).toThrow()
	end)

	t.it("toBe checks identity, not structure", function()
		local shared = { 1 }
		expect(shared).toBe(shared)
		expect(function()
			expect({ 1 }).toBe({ 1 })
		end).toThrow()
	end)

	t.it("approx respects the tolerance boundary", function()
		expect(1.024).approx(1.0, 0.025)
		expect(function()
			expect(1.026).approx(1.0, 0.025)
		end).toThrow()
	end)

	t.it("approx rejects non-numbers", function()
		expect(function()
			expect("nope").approx(1.0, 0.1)
		end).toThrow("needs a number")
	end)

	t.it("toThrow matches an error substring", function()
		expect(function()
			error("unimplemented: Snapshot.encode")
		end).toThrow("unimplemented")
	end)

	t.it("never inverts an assertion", function()
		expect(1).never().toEqual(2)
		expect(function() end).never().toThrow()
	end)

	t.it("toBeNil distinguishes nil from false", function()
		expect(nil).toBeNil()
		expect(function()
			expect(false).toBeNil()
		end).toThrow()
	end)

	t.it("truthiness follows Luau rules, not Lua-1.0 intuition", function()
		expect(0).toBeTruthy()
		expect("").toBeTruthy()
		expect(false).toBeFalsy()
		expect(nil).toBeFalsy()
	end)
end)
