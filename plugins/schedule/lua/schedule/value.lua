-- Strict detached values and UTC serialization; all calendar/zone arithmetic stays in time.query.
local M = {}
function M.copy(value)
	local decoded, err = mare.json.decode_lossless(mare.json.encode_strict(value))
	if decoded == nil then
		error(err)
	end
	return decoded
end
function M.options(options)
	if options == nil then
		return true
	end
	if type(options) ~= "table" or getmetatable(options) ~= nil then
		return M.fail("invalid_selector", "Options must be a plain table")
	end
	for key in pairs(options) do
		if key ~= "cancel" then
			return M.fail("invalid_selector", "Only cancel is a supported option")
		end
	end
	if options.cancel ~= nil and not mare.task.is_token(options.cancel) then
		return M.fail("invalid_selector", "cancel must be a native token")
	end
	return true
end
-- Combine provider lifetime and request cancellation without racing away from a definitive
-- native result. Losing an ACK after publication is unknown, never fabricated rollback.
function M.cancellable(owner, caller, fn)
	local token = owner:child()
	if caller and caller:is_cancelled() then
		token:cancel()
	end
	local watcher <close> = setmetatable(
		{ task = caller and mare.task.spawn(function()
			caller:wait()
			token:cancel()
		end) or nil },
		{
			__close = function(value)
				if value.task then
					value.task:abort()
				end
			end,
		}
	)
	return fn(token)
end
function M.fail(code, message)
	return nil, { code = code, message = message }
end
function M.object(value, allowed, required)
	if type(value) ~= "table" or mare.json.is_array(value) then
		return M.fail("invalid_selector", "Expected a JSON object")
	end
	for key in pairs(value) do
		if not allowed[key] then
			return M.fail("invalid_selector", "Unknown field: " .. tostring(key))
		end
	end
	for _, key in ipairs(required or {}) do
		if value[key] == nil then
			return M.fail("invalid_selector", "Missing field: " .. key)
		end
	end
	return true
end
function M.integer(value, minimum, maximum)
	return type(value) == "number" and value % 1 == 0 and value >= minimum and value <= (maximum or 9007199254740991)
end
function M.text(value, name, maximum)
	if type(value) ~= "string" then
		return M.fail("invalid_rule", name .. " must be text")
	end
	value = value:match("^%s*(.-)%s*$")
	local length = utf8.len(value)
	if not length or length == 0 or maximum and length > maximum then
		return M.fail("invalid_rule", name .. " is empty or too long")
	end
	return value
end
function M.query(query)
	local result, err = mare.time.query(query)
	if not result then
		return M.fail("invalid_rule", tostring(err))
	end
	return result
end
function M.iso(ms)
	local result, err = M.query({ action = "format", instant_ms = ms, timezone = "UTC", format = "%Y-%m-%dT%H:%M:%S" })
	if not result then
		return nil, err
	end
	return result.text .. string.format(".%03dZ", ms % 1000)
end
function M.ms(text)
	local result, err = M.query({ action = "instant", value = text })
	return result and result.instant_ms, err
end
function M.next(pattern, after)
	local result, err = M.query({ action = "next", pattern = pattern, after_ms = after })
	if not result then
		return nil, err
	end
	return result.next_ms ~= mare.json.null and result.next_ms or nil
end
return M
