local M = {}

local function copy_deep(value, seen)
	if type(value) ~= "table" then
		return value
	end
	seen = seen or {}
	if seen[value] then
		return seen[value]
	end
	local is_arr = mare and mare.json and mare.json.is_array and mare.json.is_array(value)
	local out = is_arr and mare.json.array({}) or {}
	seen[value] = out
	for k, v in pairs(value) do
		if type(k) == "string" or type(k) == "number" then
			local vt = type(v)
			if vt == "table" or vt == "string" or vt == "number" or vt == "boolean" then
				out[k] = copy_deep(v, seen)
			end
		end
	end
	return is_arr and mare.json.array(out) or out
end

M.copy_deep = copy_deep

--- Emit a read-only snapshot event through Mare's `ctx.bus` (or `ctx.emit` only when `bus` is absent in mocks).
--- Isolates listener failures and logs warnings.
function M.emit(ctx, name, payload)
	if not ctx then
		return
	end
	local snapshot = copy_deep(payload or {})
	local bus = ctx.bus
	if type(bus) == "table" and type(bus.emit) == "function" then
		local ok, err = pcall(bus.emit, bus, name, snapshot)
		if not ok and mare and type(mare.log) == "function" then
			pcall(mare.log, "warn", ("workflow event %s listener error: %s"):format(tostring(name), tostring(err)))
		end
		return
	end
	if type(ctx.emit) == "function" then
		local ok, err = pcall(ctx.emit, ctx, name, snapshot)
		if not ok and mare and type(mare.log) == "function" then
			pcall(mare.log, "warn", ("workflow event %s listener error: %s"):format(tostring(name), tostring(err)))
		end
	end
end

return M
