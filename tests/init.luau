--!strict
--[[
	Test entry point. Discovers and runs every `*.spec.luau` under tests/.

		lune run tests

	Exit code 0 when all assertions pass (todos do not fail the suite),
	1 when any assertion fails.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local stdio = require("@lune/stdio")

-- `@self` rather than `./`: inside an init.luau, a relative require resolves
-- against the *parent* of this directory, so `./framework` would look for
-- ../framework. `@self` is the alias that means "next to this init.luau".
local framework = require("@self/framework")

local function color(name: stdio.Color, text: string): string
	return stdio.color(name) .. text .. stdio.color("reset")
end

-- Discovery ------------------------------------------------------------------

local specs: { string } = {}

local function collect(dir: string, prefix: string)
	for _, entry in fs.readDir(dir) do
		local full = `{dir}/{entry}`
		if fs.isDir(full) then
			collect(full, `{prefix}{entry}/`)
		elseif string.match(entry, "%.spec%.luau$") then
			table.insert(specs, prefix .. string.gsub(entry, "%.luau$", ""))
		end
	end
end

collect("tests", "")
table.sort(specs)

if #specs == 0 then
	stdio.write(color("yellow", "no *.spec.luau files found under tests/\n"))
	process.exit(1)
end

-- Execution ------------------------------------------------------------------

local start = os.clock()

for _, spec in specs do
	local ok, err = pcall(function()
		require(`@self/{spec}`)
	end)
	if not ok then
		stdio.write(color("red", `x failed to load {spec}: {tostring(err)}\n`))
		local stats = framework.getStats()
		stats.failed += 1
		table.insert(stats.failures, {
			suite = spec,
			name = "(module load)",
			message = tostring(err),
		})
	end
end

local elapsed = (os.clock() - start) * 1000

-- Reporting ------------------------------------------------------------------

local stats = framework.getStats()

if #stats.failures > 0 then
	stdio.write("\n")
	for _, f in stats.failures do
		stdio.write(color("red", `  x {f.suite} > {f.name}`) .. "\n")
		for line in string.gmatch(f.message, "[^\n]+") do
			stdio.write(`      {line}\n`)
		end
	end
end

if stats.todo > 0 then
	stdio.write("\n")
	stdio.write(color("yellow", `  {stats.todo} todo:`) .. "\n")
	for _, t in stats.todos do
		stdio.write(color("yellow", `      - {t.suite} > {t.name}`) .. "\n")
	end
end

stdio.write("\n")
stdio.write(`  {#specs} spec file(s) in {string.format("%.1f", elapsed)}ms\n`)
stdio.write("  " .. color("green", `{stats.passed} passed`))
if stats.failed > 0 then
	stdio.write("  " .. color("red", `{stats.failed} failed`))
end
if stats.todo > 0 then
	stdio.write("  " .. color("yellow", `{stats.todo} todo`))
end
stdio.write("\n\n")

process.exit(if stats.failed > 0 then 1 else 0)
