--!strict
--[[
	Cross-context diagnostics bridge.

	Roblox gives the command bar (and therefore the Studio MCP bridge) its own
	module registry. `require(ServerScriptService.Server.services.TickService)`
	from there returns a *fresh* TickService with `connection = nil`, not the
	one the boot script started — so it reports zero ticks while the server is
	visibly running. `_G` does not cross the boundary either.

	A BindableFunction does. The server binds handlers at boot; the command bar
	invokes them and gets answers from the real, running instances.

	This is the verification hook for every Studio-side measurement in the
	project — tick budget now, hit-registration latency and bandwidth later.
]]

local ServerStorage = game:GetService("ServerStorage")

local Diagnostics = {}

local BRIDGE_NAME = "DeepcacheDiagnostics"

local handlers: { [string]: (...any) -> any } = {}
local bridge: BindableFunction? = nil

--- Register a named command. Handlers may yield.
function Diagnostics.register(name: string, handler: (...any) -> any)
	handlers[name] = handler
end

function Diagnostics.init()
	local existing = ServerStorage:FindFirstChild(BRIDGE_NAME)
	if existing then
		existing:Destroy()
	end

	local created = Instance.new("BindableFunction")
	created.Name = BRIDGE_NAME
	created.Parent = ServerStorage

	created.OnInvoke = function(command: string, ...)
		local handler = handlers[command]
		if handler == nil then
			local available: { string } = {}
			for name in handlers do
				table.insert(available, name)
			end
			table.sort(available)
			return { error = `unknown command "{tostring(command)}"`, available = available }
		end

		-- Never let a diagnostics call take down the server it is inspecting.
		local ok, result = pcall(handler, ...)
		if not ok then
			return { error = tostring(result) }
		end
		return result
	end

	bridge = created
end

function Diagnostics.commands(): { string }
	local out: { string } = {}
	for name in handlers do
		table.insert(out, name)
	end
	table.sort(out)
	return out
end

return Diagnostics
