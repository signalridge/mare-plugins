-- Independent policy for time-context and environment delta rendering.
-- Date/zone/cwd changes outrank interval suppression; a sample is never a live clock.
local M = {}
local function escape_closing_tag(text)
	return (text:gsub("<(/%s*[Tt][Ii][Mm][Ee]_[Cc][Oo][Nn][Tt][Ee][Xx][Tt][%s>])", "<\\%1"))
end
local function render_client_lines(lines, state, include_date)
	local client = state.client
	if client.kind == "resolved" then
		local line = "Client-reported time zone: " .. client.zones[1]
		if include_date and state.request_date then
			line = line .. "; date in that zone: " .. state.request_date
		end
		lines[#lines + 1] = line .. ". Interpret unqualified dates and times in this zone."
	elseif client.kind == "mixed" then
		lines[#lines + 1] = "Client-reported time zones are mixed: "
			.. table.concat(client.zones, ", ")
			.. ". Clarify unqualified dates and times."
	else
		lines[#lines + 1] = "Client time zone is unavailable. Clarify unqualified dates and times."
	end
end
function M.options(config)
	local out = { refresh_interval_ms = 600000, nonfatal_clock_read_errors = false }
	for key, value in pairs(config or {}) do
		out[key] = value
	end
	return out
end
function M.turn_boundary(messages, turn_id, step_num)
	local first_current = nil
	if turn_id ~= nil then
		for index, message in ipairs(messages) do
			if message.turn_id == turn_id then
				first_current = index
				break
			end
		end
	end
	local limit = first_current and (first_current - 1) or #messages
	local boundary = 0
	for index = 1, limit do
		local message = messages[index]
		if turn_id ~= nil and message.turn_id ~= nil and message.turn_id ~= turn_id then
			boundary = index
		elseif
			(first_current ~= nil or step_num == nil or step_num == 1)
			and (message.role == "assistant" or message.role == "tool_result" or message.role == "tool")
		then
			boundary = index
		end
	end
	return boundary
end
function M.trailing_user_boundary(messages, turn_id)
	local boundary = 0
	for index, message in ipairs(messages) do
		if
			message.role ~= "user"
			or message.notification
			or (turn_id ~= nil and message.turn_id ~= nil and message.turn_id ~= turn_id)
		then
			boundary = index
		end
	end
	return boundary
end
function M.zones(messages, validate, turn_id, step_num)
	local seen, zones = {}, mare.json.array({})
	local boundary = M.turn_boundary(messages, turn_id, step_num)
	for index, message in ipairs(messages) do
		local in_turn
		if message.turn_id ~= nil then
			in_turn = (not turn_id) or (message.turn_id == turn_id)
		else
			in_turn = index > boundary
		end
		local context = message.role == "user" and not message.notification and in_turn and message.input_context or nil
		local zone = context and context.timezone
		if zone ~= nil and not seen[zone] then
			validate(zone)
			seen[zone], zones[#zones + 1] = true, zone
		end
	end
	table.sort(zones)
	return { kind = #zones == 0 and "missing" or #zones == 1 and "resolved" or "mixed", zones = zones }
end
function M.refresh(previous, current, interval)
	if not previous or previous.cwd ~= current.cwd then
		return true, "unknown"
	end
	if previous.status == "unavailable" then
		return true, "recovered"
	end
	if previous.host.local_date ~= current.host.local_date then
		return true, "host-date"
	end
	if previous.host.timezone ~= current.host.timezone or previous.host.offset ~= current.host.offset then
		return true, "host-zone"
	end
	if previous.zone_key ~= current.zone_key then
		return true, "client-zone"
	end
	if previous.request_date ~= current.request_date then
		return true, "request-date"
	end
	if current.host.instant_ms < previous.host.instant_ms then
		return true, "clock-rollback"
	end
	if current.host.instant_ms - previous.host.instant_ms >= interval then
		return true, "interval"
	end
	return false
end
function M.render_unavailable(state)
	local body = {
		"Host current date and time are unavailable (failed to read current time).",
	}
	render_client_lines(body, state, false)
	if state.configured_zone then
		body[#body + 1] = "Configured fallback time zone: " .. state.configured_zone .. "."
	end
	body[#body + 1] =
		"This snapshot replaces earlier time context snapshots, including any retained in conversation summaries; do not rely on earlier host date or clock readings as current."
	body[#body + 1] = "This is host environment context, not a user statement."
	for index = 1, #body do
		body[index] = escape_closing_tag(body[index])
	end
	local lines = {
		"Time context: host clock unavailable",
		'<time_context source="agent.time-context" status="unavailable">',
	}
	for index = 1, #body do
		lines[#lines + 1] = body[index]
	end
	lines[#lines + 1] = "</time_context>"
	return table.concat(lines, "\n")
end
function M.render(state)
	if state.status == "unavailable" then
		return M.render_unavailable(state)
	end
	local host = state.host
	local body = {
		"Host local date: "
			.. host.local_date
			.. "; host zone: "
			.. (host.timezone or "unidentified fixed offset")
			.. ".",
		"Host clock sampled at " .. host.timestamp .. " (epoch milliseconds: " .. string.format(
			"%.0f",
			host.instant_ms
		) .. ").",
	}
	render_client_lines(body, state, true)
	body[#body + 1] = "Request time sampled at " .. state.request_timestamp .. "."
	body[#body + 1] = "Elapsed since preceding "
		.. state.elapsed_baseline
		.. ": "
		.. (state.preceding_elapsed_ms and tostring(state.preceding_elapsed_ms) .. " milliseconds" or "unavailable")
		.. "."
	if state.configured_zone then
		body[#body + 1] = "Configured fallback time zone: " .. state.configured_zone .. "."
	end
	if state.elapsed_ms then
		body[#body + 1] = "Elapsed since previous disclosed sample: " .. tostring(state.elapsed_ms) .. " milliseconds."
	end
	if state.reason == "host-date" or state.reason == "request-date" then
		body[#body + 1] =
			"The current date has changed. This snapshot replaces earlier versions of this context, including any retained in conversation summaries; rely on the latest snapshot for the current date."
	else
		body[#body + 1] =
			"This snapshot replaces earlier versions of this context, including any retained in conversation summaries; rely on the latest snapshot for the current date and time."
	end
	body[#body + 1] =
		"This is host environment context, not a user statement. This is a snapshot, not a continuously updated clock."
	for index = 1, #body do
		body[index] = escape_closing_tag(body[index])
	end
	local lines = {
		escape_closing_tag(
			"Time context: host date " .. host.local_date .. " (" .. (host.timezone or host.offset) .. ")"
		),
		'<time_context source="agent.time-context">',
	}
	for index = 1, #body do
		lines[#lines + 1] = body[index]
	end
	lines[#lines + 1] = "</time_context>"
	return table.concat(lines, "\n")
end
return M
