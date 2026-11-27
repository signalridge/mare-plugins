-- Schedule timing selectors and update semantics.
local V = require("schedule.value")
local M = {}
local selectors = {
	after = "after_seconds",
	at = "at",
	every = "every_seconds",
	daily = "daily",
	weekly = "weekly",
	cron = "cron",
	rrule = "rrule",
}
function M.normalize(timing, now)
	if type(timing) ~= "table" or not selectors[timing.kind] then
		return V.fail("invalid_rule", "Unknown timing kind")
	end
	local key = selectors[timing.kind]
	local ok, err = V.object(timing, { kind = true, [key] = true }, { key })
	if not ok then
		return nil, err
	end
	local value, pattern = timing[key]
	if timing.kind == "after" or timing.kind == "every" then
		if not V.integer(value, timing.kind == "every" and 60 or 1, 9007199254740) then
			return V.fail("invalid_rule", "Seconds must be safe positive integers; every requires at least 60")
		end
		pattern = timing.kind == "after" and { kind = "instant", at_ms = now + value * 1000 }
			or { kind = "interval", anchor_ms = now, every_ms = value * 1000 }
	elseif timing.kind == "at" then
		local result
		if type(value) == "string" then
			result, err = V.query({ action = "instant", value = value })
		else
			ok, err = V.object(value, { date = true, time = true, time_zone = true }, { "date", "time", "time_zone" })
			if not ok then
				return nil, err
			end
			result, err =
				V.query({ action = "instant", date = value.date, time = value.time, timezone = value.time_zone })
		end
		if not result then
			return nil, err
		end
		pattern = { kind = "instant", at_ms = result.instant_ms }
	elseif timing.kind == "daily" or timing.kind == "weekly" then
		ok, err = V.object(
			value,
			{ time = true, time_zone = true, weekdays = timing.kind == "weekly" },
			timing.kind == "weekly" and { "time", "time_zone", "weekdays" } or { "time", "time_zone" }
		)
		if not ok then
			return nil, err
		end
		pattern = { kind = "calendar", time = value.time, timezone = value.time_zone, weekdays = value.weekdays }
	elseif timing.kind == "cron" then
		ok, err = V.object(value, { expression = true, time_zone = true }, { "expression", "time_zone" })
		if not ok then
			return nil, err
		end
		pattern = { kind = "cron", expression = value.expression, timezone = value.time_zone }
	else
		pattern = { kind = "rrule", rrule = value }
	end
	local result
	result, err = V.query({ action = "normalize", pattern = pattern, after_ms = now })
	if not result then
		return nil, err
	end
	pattern = result.pattern
	local normalized = { kind = timing.kind }
	if timing.kind == "after" or timing.kind == "every" then
		normalized[key] = value
	elseif timing.kind == "at" then
		normalized.at = assert(V.iso(pattern.at_ms))
	elseif timing.kind == "rrule" then
		normalized.rrule = pattern.rrule
	elseif timing.kind == "cron" then
		normalized.cron = { expression = pattern.expression, time_zone = pattern.timezone }
	else
		normalized[key] = { time = pattern.time, time_zone = pattern.timezone, weekdays = pattern.weekdays }
	end
	return {
		timing = normalized,
		pattern = pattern,
		next_ms = result.next_ms ~= mare.json.null and result.next_ms or nil,
	}
end
function M.coalesced_count(pattern, scheduled_ms, occurrence_ms)
	if not occurrence_ms or occurrence_ms <= scheduled_ms then
		return 0, false
	end
	if pattern.kind == "interval" then
		local count = math.floor((occurrence_ms - scheduled_ms) / pattern.every_ms)
		return math.max(0, count), false
	end
	local count, cursor = 1, scheduled_ms
	while count < 100 do
		local next_ms = V.next(pattern, cursor)
		if not next_ms or next_ms >= occurrence_ms then
			break
		end
		count = count + 1
		cursor = next_ms
	end
	return count, count >= 100
end
function M.resolve(task, now)
	local scheduled_ms = assert(V.ms(task.record.scheduled_at))
	local resolved, err = V.query({
		action = "resolve",
		pattern = task.pattern,
		scheduled_ms = scheduled_ms,
		accepted_ms = now,
	})
	if not resolved then
		return nil, err
	end
	if resolved.next_ms == mare.json.null then
		resolved.next_ms = nil
	end
	local count, capped = M.coalesced_count(task.pattern, scheduled_ms, resolved.occurrence_ms)
	resolved.coalesced_count = count
	resolved.coalesced_capped = capped
	return resolved
end
function M.validate(task)
	local timing, pattern = task.timing, task.pattern
	assert(type(timing) == "table" and selectors[timing.kind] and type(pattern) == "table", "Invalid timing")
	assert(
		V.object(timing, { kind = true, [selectors[timing.kind]] = true }, { selectors[timing.kind] }),
		"Invalid stored timing selector"
	)
	local kind, value = timing.kind, timing[selectors[timing.kind]]
	if kind == "after" then
		assert(
			V.integer(value, 1, 9007199254740)
				and pattern.kind == "instant"
				and pattern.at_ms == V.ms(task.record.scheduled_at),
			"Invalid after timing"
		)
	elseif kind == "at" then
		assert(
			pattern.kind == "instant" and pattern.at_ms == V.ms(value) and value == task.record.scheduled_at,
			"Invalid absolute timing"
		)
	elseif kind == "every" then
		assert(
			V.integer(value, 60, 9007199254740) and pattern.kind == "interval" and pattern.every_ms == value * 1000,
			"Invalid interval timing"
		)
	elseif kind == "rrule" then
		assert(pattern.kind == "rrule" and pattern.rrule == value, "Invalid RRULE timing")
	elseif kind == "cron" then
		assert(
			pattern.kind == "cron"
				and type(value) == "table"
				and pattern.expression == value.expression
				and pattern.timezone == value.time_zone,
			"Invalid Cron timing"
		)
	else
		assert(
			pattern.kind == "calendar"
				and type(value) == "table"
				and pattern.time == value.time
				and pattern.timezone == value.time_zone,
			"Invalid calendar timing"
		)
		assert(
			pattern.weekdays == nil and value.weekdays == nil
				or pattern.weekdays ~= nil
					and value.weekdays ~= nil
					and mare.json.encode_strict(pattern.weekdays) == mare.json.encode_strict(value.weekdays),
			"Calendar weekdays disagree"
		)
	end
	return true
end
return M
