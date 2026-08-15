--!strict
--[[
	Result type for validation paths.

	CLAUDE.md: "server-side validation failures return (false, reason), they do
	not throw. Throwing is for programmer error only." This makes that shape
	explicit and composable, so a rejected fire request or a clamped director
	proposal carries its reason instead of vanishing into a boolean.
]]

export type Result<T> = { ok: true, value: T } | { ok: false, reason: string }

local Result = {}

function Result.ok<T>(value: T): Result<T>
	return { ok = true, value = value }
end

function Result.err<T>(reason: string): Result<T>
	return { ok = false, reason = reason }
end

--- Unwrap or fall back. Never throws.
function Result.unwrapOr<T>(result: Result<T>, fallback: T): T
	if result.ok then
		return result.value
	end
	return fallback
end

--- Unwrap or throw. For programmer error only — never on a validation path.
function Result.expect<T>(result: Result<T>, context: string): T
	if result.ok then
		return result.value
	end
	error(`{context}: {result.reason}`, 2)
end

--- Transform the success value, passing errors through untouched.
function Result.map<T, U>(result: Result<T>, fn: (T) -> U): Result<U>
	if result.ok then
		return { ok = true, value = fn(result.value) }
	end
	return { ok = false, reason = result.reason }
end

--- Chain a fallible operation.
function Result.andThen<T, U>(result: Result<T>, fn: (T) -> Result<U>): Result<U>
	if result.ok then
		return fn(result.value)
	end
	return { ok = false, reason = result.reason }
end

return Result
