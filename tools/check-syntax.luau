--!strict
--[[
	Compiles every .luau file under src/ without running it.

		lune run tools/check-syntax

	Why this exists: adapter code (anything touching `game`, `workspace`,
	`Instance`) cannot be required by the test suite, and `rojo build` packages
	source as strings without parsing it. So without this, a syntax error in a
	service sits undetected until someone opens Studio.

	This is a compile check, not a type check — it catches malformed syntax, not
	a misspelled field. Full type checking needs luau-lsp, which is a separate
	tool and a later addition.

	It also lints cross-service relative requires, which compile fine and fail
	only at runtime. See lintCrossServiceRequires below.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local stdio = require("@lune/stdio")

local SCAN_DIRS = { "src", "tests", "tools" }

local failures: { { path: string, message: string } } = {}
local checked = 0

--[[
	Cross-service require lint.

	`src/shared` maps to ReplicatedStorage.Shared, `src/server` to
	ServerScriptService.Server, `src/client` to StarterPlayerScripts.Client.
	Relative string requires traverse the DataModel, so they work *within* a
	mapped subtree but cannot cross between services: `require("../shared/x")`
	from a server module resolves to ServerScriptService.shared, which does not
	exist.

	This cost a real debugging cycle — every adapter compiled, synced, and then
	failed at runtime. Instance requires through
	`game:GetService("ReplicatedStorage").Shared` are the fix, and this catches
	a regression at build time instead of on boot.
]]
local function lintCrossServiceRequires(path: string, source: string)
	local isServer = string.match(path, "^src/server/") ~= nil
	local isClient = string.match(path, "^src/client/") ~= nil
	if not (isServer or isClient) then
		return
	end

	for pattern in string.gmatch(source, 'require%(%s*"([^"]+)"') do
		if string.match(pattern, "shared/") and string.match(pattern, "^%.%.") then
			table.insert(failures, {
				path = path,
				message = `cross-service relative require: require("{pattern}")\n`
					.. `    src/shared maps to ReplicatedStorage.Shared but this file lives under `
					.. `{if isServer then "ServerScriptService" else "StarterPlayerScripts"}.\n`
					.. `    Use: local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")`,
			})
		end
	end
end

local function scan(dir: string)
	if not fs.isDir(dir) then
		return
	end
	for _, entry in fs.readDir(dir) do
		local full = `{dir}/{entry}`
		if fs.isDir(full) then
			scan(full)
		elseif string.match(entry, "%.luau$") then
			checked += 1
			local source = fs.readFile(full)
			local ok, err = pcall(function()
				luau.load(source, { debugName = full })
			end)
			if not ok then
				table.insert(failures, { path = full, message = tostring(err) })
			else
				lintCrossServiceRequires(full, source)
			end
		end
	end
end

for _, dir in SCAN_DIRS do
	scan(dir)
end

if #failures > 0 then
	stdio.write(
		stdio.color("red") .. `syntax check FAILED ({#failures} of {checked} files)` .. stdio.color("reset") .. "\n"
	)
	for _, failure in failures do
		stdio.write(`\n  {failure.path}\n`)
		for line in string.gmatch(failure.message, "[^\n]+") do
			stdio.write(`    {line}\n`)
		end
	end
	stdio.write("\n")
	process.exit(1)
end

stdio.write(stdio.color("green") .. `syntax check passed ({checked} files)` .. stdio.color("reset") .. "\n")
process.exit(0)
