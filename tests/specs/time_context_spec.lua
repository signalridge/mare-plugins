local support = assert(load(mare.fs.read("tests/specs/support.lua"), "@tests/specs/support.lua"))()

local describe = mare.test.describe
local it = mare.test.it
local before_each = mare.test.before_each
local after_each = mare.test.after_each
local expect = mare.test.expect

local plugin = support.load_plugin("time-context", { "time_context.policy" })
local policy = require("time_context.policy")

local function copy_table(value)
	local out = {}
	for k, v in pairs(value) do
		out[k] = v
	end
	return out
end

describe("time-context", function()
	local real_log = mare.log
	mare.test.after_each(function()
		mare.log = real_log
	end)
	local now, date, zone, offset, sample_err
	local logs, state, prepare, messages
	local agent, ctx
	local orig_cwd, orig_time, orig_query

	local function commit()
		local transaction = prepare(state, { messages = messages, step = 1, turn_id = "test" })
		local candidate = transaction and transaction.state
		if candidate then
			state = candidate
		end
		return candidate
	end

	before_each(function()
		now, date, zone, offset, sample_err = 1000, "2026-11-14", "Asia/Tokyo", "+09:00", nil
		logs, state, prepare, messages = {}, nil, nil, {}

		orig_cwd = mare.fs.cwd
		orig_time = mare.time
		orig_query = orig_time and orig_time.query or nil

		mare.fs.cwd = "/one"
		if not mare.time then
			mare.time = {}
		end
		mare.time.query = function(q)
			if q.action == "sample" then
				if sample_err then
					return nil, sample_err
				end
				return {
					instant_ms = now,
					local_date = date,
					timezone = zone,
					offset = offset,
					timestamp = date .. "T00:00:00" .. offset,
				}
			end
			expect.eq(q.action, "format")
			if q.timezone == "bad" then
				return nil, "invalid zone"
			end
			return {
				timezone = q.timezone == "US/Eastern" and "America/New_York" or q.timezone,
				text = q.timezone == "America/Los_Angeles"
						and (q.instant_ms >= 700000 and "2026-11-14" or "2026-11-13")
					or date,
			}
		end

		agent = {
			messages = function()
				return messages
			end,
			step_state = function(_, name)
				expect.eq(name, "time-context")
				return state
			end,
			step_participant = function(_, name, fn, opts)
				expect.eq(name, "time-context")
				expect.eq(opts.failure_policy, "required")
				expect.eq(opts.output, "transaction")
				prepare = fn
			end,
		}
		ctx = { agent = agent }
		plugin.apply(ctx, {})
	end)

	after_each(function()
		mare.fs.cwd = orig_cwd
		if orig_time then
			orig_time.query = orig_query
		end
		mare.time = orig_time
	end)

	it("validates options", function()
		expect.eq(plugin.config_schema.refresh_interval_ms.type, "integer")
		expect.eq(plugin.config_schema.refresh_interval_ms.min, 0)
		expect.eq(plugin.config_schema.refresh_interval_ms.default, 600000)
		expect.eq(plugin.config_schema.timezone.type, "string")
		expect.eq(plugin.config_schema.timezone.nullable, true)
		expect.eq(policy.options({ refresh_interval_ms = 600000 }).refresh_interval_ms, 600000)

		expect.eq(plugin.config_schema.nonfatal_clock_read_errors.type, "boolean")
		expect.eq(plugin.config_schema.nonfatal_clock_read_errors.default, false)
		expect.eq(policy.options({ nonfatal_clock_read_errors = true }).nonfatal_clock_read_errors, true)
	end)

	it("handles interval, midnight, zone, rollback, cwd, fallback, and client-source contracts", function()
		expect.eq(commit().reason, "unknown")
		now = now + 1
		expect.falsy(commit())
		now = 601000
		expect.eq(commit().reason, "interval")
		now = now + 1
		date = "2026-11-15"
		expect.eq(commit().reason, "host-date") -- midnight outranks interval
		zone = "Europe/London"
		offset = "+00:00"
		expect.eq(commit().reason, "host-zone")
		now = now - 10
		expect.eq(commit().reason, "clock-rollback")
		expect.eq(state.elapsed_ms, 0)

		messages = { { role = "user", turn_id = "test", input_context = { timezone = "America/Los_Angeles" } } }
		expect.eq(commit().reason, "client-zone")
		expect.truthy(state.host.local_date ~= state.request_date)

		local disclosed = policy.render(state)
		now = now + 1
		date = "2026-11-16"
		expect.eq(policy.render(state), disclosed) -- committed snapshot stays stable across fallback

		messages[#messages + 1] = { role = "user", turn_id = "test", input_context = { timezone = "Europe/London" } }
		commit()
		expect.eq(state.client.kind, "mixed")
		expect.truthy(policy.render(state):find("mixed", 1, true))

		messages = { { role = "assistant", content = {} } }
		commit()
		expect.eq(state.client.kind, "missing")

		messages = { { role = "user", turn_id = "test", input_context = { timezone = "bad" } } }
		expect.error(function()
			prepare(state, { messages = messages, step = 1, turn_id = "test" })
		end) -- required prepare refuses invalid caller fact

		messages = {}
		mare.fs.cwd = "/two"
		expect.eq(commit().reason, "unknown")

		local reported = policy.zones({
			{ role = "user", turn_id = "old", input_context = { timezone = "Europe/London" } },
			{ role = "user", turn_id = "current", input_context = { timezone = "America/Los_Angeles" } },
		}, function() end, "current")
		expect.eq(reported.kind, "resolved")
		expect.eq(reported.zones[1], "America/Los_Angeles")

		messages = { { role = "user", turn_id = "test", input_context = { timezone = "US/Eastern" } } }
		expect.error(function()
			prepare(state, { messages = messages, step = 1, turn_id = "test" })
		end)

		-- A configured fallback must not relabel the date selected by a unique client zone.
		local displayed = copy_table(state)
		displayed.configured_zone = "Europe/London"
		displayed.client = { kind = "resolved", zones = { "America/Los_Angeles" } }
		displayed.request_date = "2026-11-13"
		local text = policy.render(displayed)
		expect.truthy(text:find("Configured fallback time zone: Europe/London.", 1, true))
		expect.truthy(text:find("date in that zone: 2026-11-13", 1, true))

		-- request-date change outranks interval suppression when client zone crosses midnight.
		messages = { { role = "user", turn_id = "test", input_context = { timezone = "America/Los_Angeles" } } }
		expect.eq(commit().reason, "client-zone")
		now = 700000
		expect.eq(prepare(state, { messages = messages, step = 1, turn_id = "test" }).state.reason, "request-date")
	end)

	it("tracks step elapsed baseline, fixed offset rendering, and configured alias normalization", function()
		expect.eq(commit().reason, "unknown")
		now = 700000
		messages = { { role = "user", turn_id = "test", input_context = { timezone = "America/Los_Angeles" } } }
		expect.eq(commit().reason, "client-zone")

		-- step > 1 within the same turn uses step context baseline; step == 1 filters message timestamps.
		local msg_with_ts = {
			{ role = "user", turn_id = "t1", timestamp = 699000 },
			{ role = "assistant", timestamp = 0 / 0 },
			{ role = "assistant", timestamp = math.huge },
			{ role = "assistant", timestamp = "bad" },
		}
		local step1 = prepare(state, { messages = msg_with_ts, step = 1, turn_id = "t1" }).state
		expect.eq(step1.elapsed_baseline, "model-visible message")
		expect.eq(step1.preceding_elapsed_ms, 1000)

		now = 700500
		local step2 = prepare(step1, { messages = msg_with_ts, step = 2, turn_id = "t1" })
		expect.eq(step2, nil) -- suppressed within interval
		local step2_forced = policy.refresh(step1, {
			host = { instant_ms = now, local_date = date, timezone = zone, offset = offset },
			cwd = mare.fs.cwd,
			zone_key = step1.zone_key,
			request_date = step1.request_date,
		}, 0)
		expect.truthy(step2_forced)

		-- Configured alias normalization and unidentified fixed offset rendering.
		zone = false
		local tx = prepare(nil, { messages = {}, step = 1, turn_id = "fixed" })
		expect.eq(tx.state.host.timezone, nil)
		local fixed_text = tx.disclosures[1].text
		expect.match(fixed_text, "%(%+09:00%)")
		expect.truthy(fixed_text:find("unidentified fixed offset", 1, true))
		expect.truthy(fixed_text:find("Elapsed since preceding model-visible message: unavailable.", 1, true))

		local live_cfg = { timezone = "US/Eastern", refresh_interval_ms = 0 }
		plugin.apply({ agent = agent }, live_cfg)
		local tx_cfg = prepare(nil, {
			messages = {
				{ role = "user", turn_id = "mix", input_context = { timezone = "Europe/London" } },
				{ role = "user", turn_id = "mix", input_context = { timezone = "America/Los_Angeles" } },
			},
			step = 1,
			turn_id = "mix",
		})
		expect.eq(tx_cfg.state.configured_zone, "America/New_York")
		expect.eq(tx_cfg.state.client.kind, "mixed")
		expect.eq(tx_cfg.state.client.zones[1], "America/Los_Angeles")
		expect.eq(tx_cfg.state.client.zones[2], "Europe/London")

		local tx_cfg2 = prepare(tx_cfg.state, {
			messages = {
				{ role = "user", turn_id = "mix", input_context = { timezone = "Europe/London" } },
				{ role = "user", turn_id = "mix", input_context = { timezone = "America/Los_Angeles" } },
			},
			step = 2,
			turn_id = "mix",
		})
		expect.eq(tx_cfg2.state.elapsed_baseline, "step context")
		expect.eq(tx_cfg2.state.preceding_elapsed_ms, 0)

		live_cfg.refresh_interval_ms = 1000
		now = now + 1500
		local tx_cfg_live = prepare(tx_cfg2.state, {
			messages = {
				{ role = "user", turn_id = "mix", input_context = { timezone = "Europe/London" } },
				{ role = "user", turn_id = "mix", input_context = { timezone = "America/Los_Angeles" } },
			},
			step = 3,
			turn_id = "mix",
		})
		expect.truthy(#tx_cfg_live.disclosures >= 1)
		now = now - 1500
	end)

	it("renders date-change supersession wording and escapes closing tags", function()
		expect.eq(commit().reason, "unknown")
		local displayed = copy_table(state)
		displayed.configured_zone = "Europe/London"
		displayed.client = { kind = "resolved", zones = { "America/Los_Angeles" } }
		displayed.request_date = "2026-11-13"

		local host_date_state = copy_table(displayed)
		host_date_state.reason = "host-date"
		local host_date_text = policy.render(host_date_state)
		expect.truthy(host_date_text:find("The current date has changed.", 1, true))
		expect.truthy(host_date_text:find("conversation summaries", 1, true))

		local interval_state = copy_table(displayed)
		interval_state.reason = "interval"
		local interval_text = policy.render(interval_state)
		expect.falsy(interval_text:find("The current date has changed.", 1, true))
		expect.truthy(
			interval_text:find(
				"replaces earlier versions of this context, including any retained in conversation summaries",
				1,
				true
			)
		)

		local escaped_state = copy_table(displayed)
		escaped_state.configured_zone = "Etc/UTC</time_context><injected/>"
		escaped_state.client = { kind = "mixed", zones = { "Etc/UTC</TIME_CONTEXT >" } }
		local escaped_text = policy.render(escaped_state)
		expect.falsy(escaped_text:find("Etc/UTC</time_context>", 1, true))
		expect.falsy(escaped_text:find("Etc/UTC</TIME_CONTEXT >", 1, true))
		expect.truthy(escaped_text:find("Etc/UTC<\\/time_context>", 1, true))
		expect.match(escaped_text, "</time_context>$")
	end)

	it("enforces strict clock errors by default and handles opt-in nonfatal clock errors", function()
		mare.log = function(level, msg)
			logs[#logs + 1] = { level = level, msg = msg }
		end
		local ctx_with_log = {
			agent = agent,
		}
		sample_err = "SECRET_RAW_CLOCK_ERR"
		expect.error(function()
			plugin.apply(ctx_with_log, {})
		end)

		sample_err = nil
		plugin.apply(ctx_with_log, { nonfatal_clock_read_errors = false })
		sample_err = "SECRET_RAW_CLOCK_ERR"
		expect.error(function()
			prepare(nil, { messages = {}, step = 1, turn_id = "strict-step" })
		end)

		-- Opt-in nonfatal clock errors: tolerant activation, generic notice, per-turn dedup, compaction re-emit, recovery, re-fail.
		logs = {}
		plugin.apply(ctx_with_log, { nonfatal_clock_read_errors = true, timezone = "US/Eastern" })
		expect.eq(#logs, 1)
		expect.eq(logs[1].level, "warn")

		local unavail_1 = prepare(nil, {
			messages = { { role = "user", turn_id = "nf-1", input_context = { timezone = "Asia/Tokyo" } } },
			step = 1,
			turn_id = "nf-1",
		})
		expect.truthy(unavail_1)
		expect.eq(unavail_1.state.status, "unavailable")

		local unavail_text = unavail_1.disclosures[1].text
		expect.truthy(unavail_text:find('status="unavailable"', 1, true))
		expect.truthy(unavail_text:find("failed to read current time", 1, true))
		expect.falsy(unavail_text:find("SECRET_RAW_CLOCK_ERR", 1, true))
		expect.truthy(unavail_text:find("Client-reported time zone: Asia/Tokyo.", 1, true))
		expect.truthy(unavail_text:find("Configured fallback time zone: America/New_York.", 1, true))

		expect.eq(
			prepare(unavail_1.state, {
				messages = { { role = "user", turn_id = "nf-1", input_context = { timezone = "Asia/Tokyo" } } },
				step = 2,
				turn_id = "nf-1",
			}),
			nil
		)

		local unavail_new_turn = prepare(unavail_1.state, {
			messages = { { role = "user", turn_id = "nf-2", input_context = { timezone = "Asia/Tokyo" } } },
			step = 1,
			turn_id = "nf-2",
		})
		expect.truthy(unavail_new_turn)
		expect.eq(unavail_new_turn.state.status, "unavailable")

		local unavail_compacted = prepare(nil, {
			messages = { { role = "user", turn_id = "nf-1", input_context = { timezone = "Asia/Tokyo" } } },
			step = 2,
			turn_id = "nf-1",
		})
		expect.truthy(unavail_compacted)
		expect.eq(unavail_compacted.state.status, "unavailable")

		expect.error(function()
			prepare(unavail_1.state, {
				messages = { { role = "user", turn_id = "nf-bad", input_context = { timezone = "bad" } } },
				step = 1,
				turn_id = "nf-bad",
			})
		end)

		sample_err = nil
		local recovered = prepare(unavail_new_turn.state, {
			messages = { { role = "user", turn_id = "nf-2", input_context = { timezone = "Asia/Tokyo" } } },
			step = 2,
			turn_id = "nf-2",
		})
		expect.truthy(recovered)
		expect.eq(recovered.state.status, nil)
		expect.eq(recovered.state.reason, "recovered")
		expect.eq(recovered.state.elapsed_ms, nil)
		expect.eq(recovered.state.elapsed_baseline, "model-visible message")

		sample_err = "SECRET_RAW_CLOCK_ERR_2"
		local re_unavail = prepare(recovered.state, {
			messages = { { role = "user", turn_id = "nf-2", input_context = { timezone = "Asia/Tokyo" } } },
			step = 3,
			turn_id = "nf-2",
		})
		expect.truthy(re_unavail)
		expect.eq(re_unavail.state.status, "unavailable")
		expect.falsy(re_unavail.disclosures[1].text:find("SECRET_RAW_CLOCK_ERR_2", 1, true))
	end)

	it("deduplicates timezone validation per step while preserving invalid-zone failure", function()
		local tz_queries = 0
		local orig_q = mare.time.query
		mare.time.query = function(q)
			if q.action == "format" and q.instant_ms == 0 then
				tz_queries = tz_queries + 1
			end
			return orig_q(q)
		end

		messages = {}
		for i = 1, 50 do
			messages[i] = {
				role = "user",
				turn_id = "dedupe-turn",
				input_context = { timezone = (i % 2 == 0) and "America/Los_Angeles" or "Europe/London" },
			}
		end
		tz_queries = 0
		local res = prepare(nil, { messages = messages, step = 1, turn_id = "dedupe-turn" })
		expect.truthy(res)
		expect.eq(res.state.client.kind, "mixed")
		expect.eq(res.state.client.zones[1], "America/Los_Angeles")
		expect.eq(res.state.client.zones[2], "Europe/London")
		expect.eq(tz_queries, 2)

		-- Invalid zone still throws even after repeated valid zones.
		messages[#messages + 1] = {
			role = "user",
			turn_id = "dedupe-turn",
			input_context = { timezone = "bad" },
		}
		expect.error(function()
			prepare(res.state, { messages = messages, step = 2, turn_id = "dedupe-turn" })
		end)
	end)

	it("tracks core turn_id-less user input_context across steps and converts legacy enqueue seconds", function()
		now = 1700001000000
		local prev_turn = {
			{ role = "user", timestamp = 1700000000, input_context = { timezone = "Europe/London" } },
			{ role = "assistant", timestamp = 1700000500000 },
			{ role = "user", notification = true, turn_id = "turn-0", timestamp = 1700000500000 },
			{ role = "user", timestamp = 1700000999, input_context = { timezone = "Asia/Tokyo" } },
		}
		local step1 = prepare(nil, { messages = prev_turn, step = 1, turn_id = "turn-1" })
		expect.truthy(step1)
		expect.eq(step1.state.client.kind, "resolved")
		expect.eq(step1.state.client.zones[1], "Asia/Tokyo")
		-- Trailing current-turn user input at 1700000999 is skipped; picks assistant at 1700000500000.
		expect.eq(step1.state.preceding_elapsed_ms, 500000)

		-- Legacy epoch seconds on an earlier user/assistant message converts cleanly to ms (not ~56 years).
		local sec_msgs = {
			{ role = "user", timestamp = 1700000000 },
			{ role = "user", timestamp = 1700000999 },
		}
		local sec_step = prepare(nil, { messages = sec_msgs, step = 1, turn_id = "turn-sec" })
		expect.eq(sec_step.state.preceding_elapsed_ms, nil)

		local sec_after_assistant = {
			{ role = "user", timestamp = 1700000000 },
			{ role = "assistant", timestamp = 1700000900 },
			{ role = "user", timestamp = 1700000999 },
		}
		local sec_step2 = prepare(nil, { messages = sec_after_assistant, step = 1, turn_id = "turn-sec-2" })
		expect.eq(sec_step2.state.preceding_elapsed_ms, 100000)

		-- Step 2 with committed context_disclosure keeps step 1's turn_id-less user timezone and sees steer timezone.
		local step2_msgs = {
			{ role = "user", timestamp = 1700000000, input_context = { timezone = "Europe/London" } },
			{ role = "assistant", timestamp = 1700000500000 },
			{ role = "user", timestamp = 1700000999, input_context = { timezone = "Asia/Tokyo" } },
			{
				role = "user",
				notification = true,
				turn_id = "turn-1",
				context_disclosure = { source = "agent.time-context" },
			},
			{ role = "assistant", timestamp = 1700001001000 },
			{ role = "user", timestamp = 1700001002, input_context = { timezone = "America/Los_Angeles" } },
		}
		local zones_step2 = policy.zones(step2_msgs, function() end, "turn-1", 2)
		expect.eq(zones_step2.kind, "mixed")
		expect.eq(zones_step2.zones[1], "America/Los_Angeles")
		expect.eq(zones_step2.zones[2], "Asia/Tokyo")
	end)
end)
