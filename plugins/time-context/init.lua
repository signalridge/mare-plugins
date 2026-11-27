-- Independent implementation of dynamic time-context and environment delta injection.
return {
	name = "time-context",
	tags = {},
	inject = { "agent" },
	config_schema = {
		refresh_interval_ms = {
			type = "integer",
			default = 600000,
			min = 0,
			max = 9007199254740991,
			unit = "ms",
			apply = "live",
			desc = "Minimum interval in milliseconds between time-context disclosures.",
		},
		timezone = {
			type = "string",
			default = nil,
			nullable = true,
			apply = "reload",
			desc = "Optional IANA or Intl timezone override for host time disclosures.",
		},
		nonfatal_clock_read_errors = {
			type = "boolean",
			default = false,
			apply = "reload",
			desc = "Warn instead of failing activation when host clock sampling fails.",
		},
	},
	apply = function(ctx, config)
		local policy = require("time_context.policy")
		local opts = policy.options(config)
		local function query(request)
			local value, err = mare.time.query(request)
			assert(value, err)
			return value
		end
		local function format(ms, zone, pattern)
			return query({ action = "format", instant_ms = ms, timezone = zone, format = pattern }).text
		end
		local function canonical(zone, strict)
			assert(type(zone) == "string", "client timezone must be a string")
			if strict then
				assert(
					zone ~= ""
						and not zone:find("%s")
						and (zone == "UTC" or zone:match("^[A-Z][A-Za-z0-9_%+%-]*/[A-Z][A-Za-z0-9_%+%-%/]*$")),
					"client timezone must be canonical: " .. zone
				)
			end
			local formatted = query({ action = "format", instant_ms = 0, timezone = zone, format = "%Y-%m-%d" })
			local normalized = (
				type(formatted) == "table"
				and type(formatted.timezone) == "string"
				and formatted.timezone ~= ""
			)
					and formatted.timezone
				or zone
			if strict then
				assert(normalized == zone, "client timezone must be canonical: " .. zone)
			end
			return normalized
		end
		if opts.timezone then
			opts.timezone = canonical(opts.timezone, false)
		end
		local function warn(message)
			mare.log("warn", message)
		end
		local sampled, sample_err = mare.time.query({ action = "sample" }) -- resolve the host zone during activation; never seed a disclosure
		if not sampled then
			if opts.nonfatal_clock_read_errors then
				warn("time-context activation host sample unavailable: " .. tostring(sample_err))
			else
				error(sample_err)
			end
		end
		ctx.agent:step_participant("time-context", function(previous, step)
			local client = policy.zones(step.messages, function(zone)
				canonical(zone, true)
			end, step.turn_id, step.step)
			local zone = client.kind == "resolved" and client.zones[1] or opts.timezone
			local zone_key = client.kind .. ":" .. table.concat(client.zones, ",") .. ":" .. (opts.timezone or "")
			local cwd = mare.fs.cwd
			local function unavailable(err_msg)
				warn("time-context host sample unavailable: " .. tostring(err_msg))
				if
					previous
					and previous.status == "unavailable"
					and previous.turn_id == step.turn_id
					and previous.cwd == cwd
					and previous.zone_key == zone_key
				then
					return nil
				end
				local state = {
					status = "unavailable",
					cwd = cwd,
					client = client,
					zone_key = zone_key,
					configured_zone = opts.timezone,
					turn_id = step.turn_id,
					step = step.step,
					reason = "clock-unavailable",
				}
				return {
					state = state,
					disclosures = { { source = "agent.time-context", text = policy.render(state) } },
				}
			end
			local host, host_err = mare.time.query({ action = "sample" })
			if not host then
				if opts.nonfatal_clock_read_errors then
					return unavailable(host_err)
				end
				error(host_err)
			end
			if type(host.timezone) ~= "string" then
				host.timezone = nil
			end
			local request_date, request_timestamp = host.local_date, host.timestamp
			if zone then
				local ok_date, formatted_date = pcall(format, host.instant_ms, zone, "%Y-%m-%d")
				if not ok_date then
					if opts.nonfatal_clock_read_errors then
						return unavailable(formatted_date)
					end
					error(formatted_date)
				end
				local ok_ts, formatted_ts = pcall(format, host.instant_ms, zone, "%Y-%m-%dT%H:%M:%S%:z")
				if not ok_ts then
					if opts.nonfatal_clock_read_errors then
						return unavailable(formatted_ts)
					end
					error(formatted_ts)
				end
				request_date = formatted_date
				request_timestamp = formatted_ts
			end
			local current = {
				host = host,
				client = client,
				cwd = cwd,
				zone_key = zone_key,
				request_date = request_date,
				configured_zone = opts.timezone,
				request_timestamp = request_timestamp,
				turn_id = step.turn_id,
				step = step.step,
			}
			local refresh_interval_ms = config.refresh_interval_ms
			if refresh_interval_ms == nil then
				refresh_interval_ms = 600000
			end
			local refresh, reason = policy.refresh(previous, current, refresh_interval_ms)
			if not refresh then
				return nil
			end
			current.reason = reason
			if previous and previous.host and previous.cwd == current.cwd then
				current.elapsed_ms = math.max(0, host.instant_ms - previous.host.instant_ms)
			end
			local preceding
			current.elapsed_baseline = "model-visible message"
			if step.step > 1 and previous and previous.host and previous.turn_id == step.turn_id then
				preceding = previous.host.instant_ms
				current.elapsed_baseline = "step context"
			else
				local boundary = policy.trailing_user_boundary(step.messages, step.turn_id)
				for index = #step.messages, 1, -1 do
					local msg = step.messages[index]
					local is_new_turn_user = index > boundary and msg.role == "user" and not msg.notification
					if not is_new_turn_user then
						local timestamp = msg.timestamp
						if
							type(timestamp) == "number"
							and timestamp == timestamp
							and math.abs(timestamp) <= 9007199254740991
						then
							if host.instant_ms >= 1e11 and timestamp >= 1e8 and timestamp < 1e11 then
								timestamp = timestamp * 1000
							end
							preceding = timestamp
							break
						end
					end
				end
			end
			if preceding then
				current.preceding_elapsed_ms = math.max(0, host.instant_ms - preceding)
			end
			return {
				state = current,
				disclosures = { { source = "agent.time-context", text = policy.render(current) } },
			}
		end, { failure_policy = "required", output = "transaction" })
	end,
}
