--!strict
--[[
	Minimal test framework for DEEPCACHE pure-core modules.

	Deliberately dependency-free and ~200 lines: a full framework is more
	surface area than value at this project's size, and this one runs
	identically under Lune with no Roblox dependency.

	Usage from a spec file:

		local t = require("./framework")

		t.describe("Quantize", function()
			t.it("roundtrips a position", function()
				t.expect(decode(encode(3.7))).approx(3.7, 0.025)
			end)

			t.todo("handles the full coordinate range")
		end)

	`todo` marks unimplemented work: reported as pending, never a failure, so
	a green suite stays a meaningful signal while the worklist is still visible.
]]

local stdio = require("@lune/stdio")

export type Stats = {
	passed: number,
	failed: number,
	todo: number,
	failures: { { suite: string, name: string, message: string } },
	todos: { { suite: string, name: string } },
}

local stats: Stats = { passed = 0, failed = 0, todo = 0, failures = {}, todos = {} }
local currentSuite = "(root)"

--------------------------------------------------------------------------------
-- Comparison helpers
--------------------------------------------------------------------------------

local function typeName(v: any): string
	return typeof(v)
end

local function serialize(v: any, depth: number?): string
	local d = depth or 0
	if d > 4 then
		return "<deep>"
	end
	local ty = typeName(v)
	if ty == "string" then
		return string.format("%q", v :: string)
	elseif ty == "table" then
		local parts: { string } = {}
		local tbl = v :: { [any]: any }
		-- Array part first, for readable diffs on sequences.
		local n = 0
		for _ in ipairs(tbl) do
			n += 1
		end
		if n > 0 then
			for i = 1, n do
				table.insert(parts, serialize(tbl[i], d + 1))
			end
		else
			local keys: { any } = {}
			for k in pairs(tbl) do
				table.insert(keys, k)
			end
			table.sort(keys, function(a, b)
				return tostring(a) < tostring(b)
			end)
			for _, k in ipairs(keys) do
				table.insert(parts, string.format("%s = %s", tostring(k), serialize(tbl[k], d + 1)))
			end
		end
		return "{ " .. table.concat(parts, ", ") .. " }"
	end
	return tostring(v)
end

local function deepEqual(a: any, b: any): (boolean, string?)
	if a == b then
		return true, nil
	end
	if typeName(a) ~= typeName(b) then
		return false, `type mismatch: {typeName(a)} vs {typeName(b)}`
	end
	if typeName(a) ~= "table" then
		return false, `{serialize(a)} ~= {serialize(b)}`
	end

	local ta, tb = a :: { [any]: any }, b :: { [any]: any }
	for k, v in pairs(ta) do
		local ok, why = deepEqual(v, tb[k])
		if not ok then
			return false, `at key {tostring(k)}: {why}`
		end
	end
	for k in pairs(tb) do
		if ta[k] == nil then
			return false, `extra key {tostring(k)} in actual`
		end
	end
	return true, nil
end

--------------------------------------------------------------------------------
-- Assertions
--------------------------------------------------------------------------------

export type Expectation = {
	toEqual: (expected: any) -> (),
	toBe: (expected: any) -> (),
	toBeTruthy: () -> (),
	toBeFalsy: () -> (),
	toBeNil: () -> (),
	approx: (expected: number, tolerance: number) -> (),
	toThrow: (substring: string?) -> (),
	never: () -> Expectation,
}

local function fail(message: string): ()
	error(message, 3)
end

local function makeExpectation(actual: any, negated: boolean): Expectation
	local function check(ok: boolean, positiveMsg: string, negativeMsg: string)
		if negated then
			if ok then
				fail(negativeMsg)
			end
		else
			if not ok then
				fail(positiveMsg)
			end
		end
	end

	local self = {} :: Expectation

	self.toEqual = function(expected: any)
		local ok, why = deepEqual(actual, expected)
		check(
			ok,
			`expected {serialize(expected)}, got {serialize(actual)}` .. (why and ` ({why})` or ""),
			`expected value to differ from {serialize(expected)}`
		)
	end

	self.toBe = function(expected: any)
		check(
			rawequal(actual, expected),
			`expected identity {serialize(expected)}, got {serialize(actual)}`,
			`expected not to be identical to {serialize(expected)}`
		)
	end

	self.toBeTruthy = function()
		check(not not actual, `expected truthy, got {serialize(actual)}`, `expected falsy, got {serialize(actual)}`)
	end

	self.toBeFalsy = function()
		check(not actual, `expected falsy, got {serialize(actual)}`, `expected truthy, got {serialize(actual)}`)
	end

	self.toBeNil = function()
		check(actual == nil, `expected nil, got {serialize(actual)}`, `expected non-nil`)
	end

	self.approx = function(expected: number, tolerance: number)
		if typeName(actual) ~= "number" then
			fail(`approx() needs a number, got {typeName(actual)}`)
		end
		local delta = math.abs((actual :: number) - expected)
		check(
			delta <= tolerance,
			`expected {expected} +/- {tolerance}, got {actual} (delta {delta})`,
			`expected {actual} to differ from {expected} by more than {tolerance}`
		)
	end

	self.toThrow = function(substring: string?)
		if typeName(actual) ~= "function" then
			fail(`toThrow() needs a function, got {typeName(actual)}`)
		end
		local ok, err = pcall(actual :: () -> ())
		local threw = not ok
		if not negated and not threw then
			fail("expected function to throw, it returned normally")
		end
		if negated and threw then
			fail(`expected function not to throw, got: {tostring(err)}`)
		end
		if threw and substring and not negated then
			local text = tostring(err)
			if not string.find(text, substring, 1, true) then
				fail(`expected error containing {string.format("%q", substring)}, got: {text}`)
			end
		end
	end

	self.never = function(): Expectation
		return makeExpectation(actual, not negated)
	end

	return self
end

--------------------------------------------------------------------------------
-- Public surface
--------------------------------------------------------------------------------

local M = {}

function M.expect(actual: any): Expectation
	return makeExpectation(actual, false)
end

function M.describe(name: string, body: () -> ())
	local previous = currentSuite
	currentSuite = name
	local ok, err = pcall(body)
	if not ok then
		stats.failed += 1
		table.insert(stats.failures, {
			suite = name,
			name = "(suite body)",
			message = tostring(err),
		})
		stdio.write(stdio.color("red") .. "  x suite body threw: " .. tostring(err) .. stdio.color("reset") .. "\n")
	end
	currentSuite = previous
end

function M.it(name: string, body: () -> ())
	local ok, err = pcall(body)
	if ok then
		stats.passed += 1
	else
		stats.failed += 1
		table.insert(stats.failures, { suite = currentSuite, name = name, message = tostring(err) })
	end
end

function M.todo(name: string)
	stats.todo += 1
	table.insert(stats.todos, { suite = currentSuite, name = name })
end

function M.getStats(): Stats
	return stats
end

function M.reset()
	stats = { passed = 0, failed = 0, todo = 0, failures = {}, todos = {} }
	currentSuite = "(root)"
end

return M
