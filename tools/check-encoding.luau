--!strict
--[[
	Fails if any .luau source file starts with a UTF-8 BOM.

		lune run tools/check-encoding

	Luau rejects a BOM with "Expected identifier ... got Unicode character
	U+feff", and the error points at line 1 of the file rather than at
	whatever wrote it, which makes it a genuinely annoying half-hour.

	Windows PowerShell 5.1's `Set-Content -Encoding UTF8` and `Out-File
	-Encoding utf8` both emit a BOM (there is no `utf8NoBOM` on 5.1). Any
	script that generates Luau must use
	`[System.IO.File]::WriteAllText(path, text, [System.Text.UTF8Encoding]::new($false))`.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local stdio = require("@lune/stdio")

local SCAN_DIRS = { "src", "tests", "tools" }
local BOM = "\239\187\191"

local offenders: { string } = {}
local scanned = 0

local function scan(dir: string)
	if not fs.isDir(dir) then
		return
	end
	for _, entry in fs.readDir(dir) do
		local full = `{dir}/{entry}`
		if fs.isDir(full) then
			scan(full)
		elseif string.match(entry, "%.luau$") then
			scanned += 1
			local contents = fs.readFile(full)
			if string.sub(contents, 1, 3) == BOM then
				table.insert(offenders, full)
			end
		end
	end
end

for _, dir in SCAN_DIRS do
	scan(dir)
end

if #offenders > 0 then
	stdio.write(
		stdio.color("red") .. `encoding check FAILED ({#offenders} file(s) with a UTF-8 BOM)` .. stdio.color("reset") .. "\n"
	)
	for _, f in offenders do
		stdio.write(`  - {f}\n`)
	end
	stdio.write("\n  Rewrite them as UTF-8 without BOM.\n\n")
	process.exit(1)
end

stdio.write(stdio.color("green") .. `encoding check passed ({scanned} .luau files)` .. stdio.color("reset") .. "\n")
process.exit(0)
