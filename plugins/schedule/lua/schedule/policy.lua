-- No product clock overrides or sub-minute test settings.
local M = { minimum = 60000, maximum = 3600000, lifetime = 7 * 24 * 60 * 60000 }
function M.delay(value)
	return type(value) == "number" and value == value and value % 1 == 0 and value >= M.minimum and value <= M.maximum
end
function M.interval(text)
	local amount, unit = text:match("^(%d+)([smhd])$")
	if not amount then
		return nil, "Interval must be an integer followed by s, m, h or d"
	end
	local value = tonumber(amount) * ({ s = 1000, m = 60000, h = 3600000, d = 86400000 })[unit]
	if value < M.minimum or value > 9007199254740991 or value % 1 ~= 0 then
		return nil, "Interval must be at least one minute and fit in a safe integer"
	end
	return value
end
function M.submission(args)
	if
		type(args) ~= "table"
		or type(args.task_id) ~= "string"
		or type(args.revision) ~= "number"
		or args.revision % 1 ~= 0
		or type(args.run_token) ~= "string"
		or not M.delay(args.delay_ms)
		or type(args.reason) ~= "string"
		or not args.reason:find("%S")
		or #args.reason > 256
	then
		return nil,
			"Require task_id, revision, run_token, delay_ms (60000–3600000 integer), and reason (1–256 bytes)"
	end
	return true
end
return M
