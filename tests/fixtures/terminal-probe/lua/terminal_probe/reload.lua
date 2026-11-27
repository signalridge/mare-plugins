local DEFAULT_MAX_RETRIES = 8
local DEFAULT_BASE_DELAY_MS = 25
local DEFAULT_MAX_DELAY_MS = 400

local function is_busy_error(err)
	local msg = tostring(err)
	return msg:find("reload or model request already in progress", 1, true) ~= nil
		or msg:find("retry afterwards", 1, true) ~= nil
end

return function(kernel, name, opts)
	opts = opts or {}
	local max_retries = opts.max_retries or DEFAULT_MAX_RETRIES
	local delay_ms = opts.base_delay_ms or DEFAULT_BASE_DELAY_MS
	local max_delay_ms = opts.max_delay_ms or DEFAULT_MAX_DELAY_MS
	local sleep = opts.sleep or mare.task.sleep

	for attempt = 1, max_retries + 1 do
		local ok, result = pcall(kernel.reload, kernel, name)
		if ok then
			return result
		end
		if not is_busy_error(result) or attempt > max_retries then
			error(result, 0)
		end
		sleep(delay_ms)
		delay_ms = math.min(delay_ms * 2, max_delay_ms)
	end
end
