-- Durable definitions and current-session delivery; temporary /loop adapters remain session-owned.
return {
	name = "schedule",
	tags = {},
	provide = { "schedule" },
	contracts = {
		schedule = {
			doc = "Durable scheduled definitions and session-scoped loop tasks.",
			events = {
				changed = {
					doc = "Durable schedule catalog or delivery state changed.",
					mode = "emit",
					expose = "lua",
					retain = "last",
					data = {
						type = "object",
						properties = {
							revision = { type = "integer" },
						},
						required = { "revision" },
						additionalProperties = true,
					},
				},
			},
			errors = {
				invalid_schedule = { doc = "invalid schedule prompt, interval, action, filter, or query" },
				not_found = { doc = "schedule task or definition was not found" },
				schedule_unavailable = { doc = "schedule state or storage is unavailable in this session" },
			},
			methods = {
				create = {
					doc = "Create a session-scoped loop task.",
					expose = "lua",
					scope = "session",
					params = {
						type = "object",
						properties = {
							prompt = { type = "string" },
							interval_ms = { type = { "integer", "null" } },
						},
						required = { "prompt" },
						additionalProperties = false,
					},
					order = { "prompt", "interval_ms" },
					result = { type = "string" },
					errors = { "invalid_schedule", "schedule_unavailable" },
				},
				list = {
					doc = "List active and paused session loop tasks.",
					expose = "lua",
					scope = "session",
					params = {
						type = "object",
						properties = {},
						additionalProperties = false,
					},
					order = {},
					result = { type = "array", items = { type = "object" } },
				},
				control = {
					doc = "Control a session loop task (pause, resume, stop).",
					expose = "lua",
					scope = "session",
					params = {
						type = "object",
						properties = {
							action = { type = "string", enum = { "pause", "resume", "stop" } },
							target = { type = { "string", "null" } },
						},
						required = { "action" },
						additionalProperties = false,
					},
					order = { "action", "target" },
					result = {
						type = "object",
						properties = {
							ok = { type = "boolean" },
							note = { type = "string" },
						},
						required = { "ok", "note" },
						additionalProperties = false,
					},
					errors = { "invalid_schedule", "not_found", "schedule_unavailable" },
				},
				submit = {
					doc = "Submit adaptive loop interval selection for the active turn.",
					expose = "lua",
					scope = "session",
					params = {
						type = "object",
						properties = {
							args = { type = "object" },
						},
						required = { "args" },
						additionalProperties = false,
					},
					order = { "args" },
					result = { type = "boolean" },
					errors = { "invalid_schedule", "schedule_unavailable" },
				},
				create_durable = {
					doc = "Create a host-scoped durable scheduled definition (supports options.cancel).",
					expose = "lua",
					scope = "host",
					params = {
						type = "object",
						properties = {
							request = { type = "object" },
						},
						required = { "request" },
						additionalProperties = false,
					},
					order = { "request", "options" },
					lua = { options = "table?" },
					result = { type = "object" },
					errors = { "invalid_schedule", "schedule_unavailable" },
				},
				list_durable = {
					doc = "List host-scoped durable scheduled definitions.",
					expose = "lua",
					scope = "host",
					params = {
						type = "object",
						properties = {
							filter = { type = { "object", "null" } },
						},
						additionalProperties = false,
					},
					order = { "filter" },
					result = { type = "object" },
					errors = { "invalid_schedule", "schedule_unavailable" },
				},
				view = {
					doc = "Inspect a durable schedule definition and its state.",
					expose = "lua",
					scope = "host",
					params = {
						type = "object",
						properties = {
							request = { type = "object" },
						},
						required = { "request" },
						additionalProperties = false,
					},
					order = { "request" },
					result = { type = "object" },
					errors = { "invalid_schedule", "not_found", "schedule_unavailable" },
				},
				edit = {
					doc = "Edit a durable schedule definition (supports options.cancel).",
					expose = "lua",
					scope = "host",
					params = {
						type = "object",
						properties = {
							request = { type = "object" },
						},
						required = { "request" },
						additionalProperties = false,
					},
					order = { "request", "options" },
					lua = { options = "table?" },
					result = { type = "object" },
					errors = { "invalid_schedule", "not_found", "schedule_unavailable" },
				},
				history = {
					doc = "Query delivery history for durable schedules.",
					expose = "lua",
					scope = "host",
					params = {
						type = "object",
						properties = {
							request = { type = "object" },
						},
						required = { "request" },
						additionalProperties = false,
					},
					order = { "request" },
					result = { type = "object" },
					errors = { "invalid_schedule", "not_found", "schedule_unavailable" },
				},
				delete_inactive = {
					doc = "Delete inactive durable schedule definitions (supports options.cancel).",
					expose = "lua",
					scope = "host",
					params = {
						type = "object",
						properties = {},
						additionalProperties = false,
					},
					order = { "options" },
					lua = { options = "table?" },
					result = {
						type = "object",
						properties = {
							deleted = { type = "integer" },
						},
						required = { "deleted" },
						additionalProperties = false,
					},
					errors = { "invalid_schedule", "schedule_unavailable" },
				},
				run = {
					doc = "Trigger an immediate run of a durable schedule (supports options.cancel).",
					expose = "lua",
					scope = "host",
					params = {
						type = "object",
						properties = {
							request = { type = "object" },
						},
						required = { "request" },
						additionalProperties = false,
					},
					order = { "request", "options" },
					lua = { options = "table?" },
					result = { type = "object" },
					errors = { "invalid_schedule", "not_found", "schedule_unavailable" },
				},
				delivery_limits = {
					doc = "Return configured delivery history retention limits.",
					expose = "lua",
					scope = "host",
					params = {
						type = "object",
						properties = {},
						additionalProperties = false,
					},
					order = {},
					result = { type = "object" },
				},
			},
		},
	},
	inject = { "agent", "session", "commands", "tools", "bus", "policy", "task" },
	config_schema = {
		delivery_history_days = {
			type = "integer",
			default = 30,
			min = 1,
			max = 3650,
			unit = "days",
			desc = "Number of days to retain scheduled delivery history.",
			apply = "live",
		},
		delivery_history_records = {
			type = "integer",
			default = 200,
			min = 1,
			max = 10000,
			desc = "Maximum number of delivery history records retained per task.",
			apply = "live",
		},
		new_session_interval_seconds = {
			type = "integer",
			default = 60,
			min = 60,
			max = 604800,
			unit = "s",
			desc = "Minimum interval in seconds for recurring new-session scheduled runs.",
			apply = "next_op",
		},
	},
	apply = function(ctx, cfg)
		local plan_mode_of = require("mare_lib").follow(ctx, "plan_mode")
		local scheduler = require("schedule.scheduler")(ctx, plan_mode_of)
		require("schedule.interface")(ctx, scheduler)
		local domain, engine = require("schedule.domain")(ctx, cfg)
		-- plan_mode is optional: follow it while its provider is available.
		local drive, delivery = require("schedule.delivery")(ctx, domain, engine, plan_mode_of)
		require("schedule.management")(ctx, domain, engine)
		local function raise_schedule_error(err, default_code)
			local raw_code = type(err) == "table" and err.code or nil
			local msg = type(err) == "table" and (err.message or tostring(err)) or tostring(err or "schedule error")
			local code = default_code or "schedule_unavailable"
			local lower = msg:lower()
			if raw_code == "cancelled" then
				if mare and type(mare.error) == "function" then
					error(mare.error("cancelled", msg), 0)
				end
				error(msg, 0)
			end
			if
				raw_code == "invalid_selector"
				or raw_code == "invalid_rule"
				or raw_code == "invalid_argument"
				or lower:find("unknown field", 1, true)
				or (type(raw_code) == "string" and (raw_code:find("invalid", 1, true) or raw_code:find(
					"validation",
					1,
					true
				)))
				or lower:find("invalid", 1, true)
				or lower:find("interval", 1, true)
				or lower:find("prompt", 1, true)
				or lower:find("must ", 1, true)
				or lower:find("expected ", 1, true)
				or lower:find("at least", 1, true)
			then
				code = "invalid_schedule"
			elseif
				raw_code == "not_found"
				or raw_code == "schedule_not_found"
				or raw_code == "delivery_cursor_not_found"
				or lower:find("not found", 1, true)
				or lower:find("unknown task", 1, true)
				or lower:find("unknown action", 1, true)
			then
				code = (raw_code == "unknown action" or lower:find("unknown action", 1, true)) and "invalid_schedule"
					or "not_found"
			end
			if mare and type(mare.error) == "function" then
				error(mare.error("schedule." .. code, msg), 0)
			end
			error(msg, 0)
		end
		local function wrap_service(fn, default_code)
			return function(...)
				local res, err = fn(...)
				if res == nil and err ~= nil then
					raise_schedule_error(err, default_code)
				end
				return res
			end
		end
		local function wrap_control(fn)
			return function(...)
				local res, note = fn(...)
				if res == nil and note ~= nil then
					raise_schedule_error(note, "schedule_unavailable")
				end
				return { ok = res == true, note = tostring(note or "") }
			end
		end
		local facade = {
			create = wrap_service(scheduler.create, "invalid_schedule"),
			list = scheduler.list,
			control = wrap_control(scheduler.control),
			submit = wrap_service(scheduler.submit, "invalid_schedule"),
			create_durable = wrap_service(domain.create, "schedule_unavailable"),
			list_durable = wrap_service(domain.list, "schedule_unavailable"),
			view = wrap_service(domain.view, "not_found"),
			edit = wrap_service(domain.edit, "schedule_unavailable"),
			history = wrap_service(domain.history, "schedule_unavailable"),
			delete_inactive = wrap_service(domain.delete_inactive, "schedule_unavailable"),
			run = wrap_service(domain.run, "schedule_unavailable"),
			delivery_limits = domain.delivery_limits,
		}
		require("mare_lib").service(ctx, "schedule", facade)
		local stopped, lifetime = false, mare.task.token()
		local wake = lifetime:child()
		local function nudge()
			if stopped or lifetime:is_cancelled() then
				return
			end
			local prev = wake
			wake = lifetime:child()
			prev:cancel()
		end
		ctx:on("schedule/changed", function(ev)
			if not ev or ev.source ~= "delivery" then
				delivery.clear_cooldown(ev and ev.id or nil)
				nudge()
			end
		end)
		for _, event_name in ipairs({ "agent/settled", "turn/completed", "queue/changed", "plan-mode/changed" }) do
			ctx:on(event_name, nudge)
		end
		local last_session_id = ctx.session:info().session_id
		local function maybe_notify_fork(ev)
			local prev_session_id = last_session_id
			local info = ctx.session:info()
			last_session_id = (type(ev) == "table" and ev.session_id) or info.session_id
			if
				type(ev) ~= "table"
				or ev.reason ~= "fork"
				or not prev_session_id
				or prev_session_id == last_session_id
				or info.readonly
				or info.unstable
				or info.ephemeral
				or not ctx.agent
				or not require("mare_lib").callable(ctx.agent.notify)
			then
				return
			end
			local has_source_tasks, offset = false, 0
			while true do
				local page = domain.list(nil, nil, { limit = 500, offset = offset })
				if not page or type(page.items) ~= "table" or #page.items == 0 then
					break
				end
				for _, task in ipairs(page.items) do
					if task.status ~= "ended" and task.target and task.target.session_id == prev_session_id then
						has_source_tasks = true
						break
					end
				end
				offset = offset + #page.items
				if has_source_tasks or offset >= (page.total or 0) then
					break
				end
			end
			if has_source_tasks then
				pcall(
					ctx.agent.notify,
					ctx.agent,
					"This forked session does not inherit durable scheduled tasks from the source session. Tasks targeting the source session continue to target the source session; create or retarget tasks here if needed.",
					{ wake = false }
				)
			end
		end
		ctx:on("session/changed", function(ev)
			maybe_notify_fork(ev)
			delivery.clear_cooldown()
			nudge()
		end)
		for _, event_name in ipairs({
			"session/loaded",
			"session/started",
			"session/switch-completed",
		}) do
			ctx:on(event_name, function()
				last_session_id = ctx.session:info().session_id
				delivery.clear_cooldown()
				nudge()
			end)
		end
		ctx:on("app/shutdown", function()
			stopped = true
			lifetime:cancel()
		end)
		ctx:effect(function()
			return function()
				stopped = true
				lifetime:cancel()
			end
		end)
		-- A provider-owned host coroutine avoids retaining a model tool's permission context.
		-- Single next-due sleep + wake-on-change token avoids fixed polling.
		ctx:spawn(function()
			while not stopped and not lifetime:is_cancelled() do
				local token = wake
				local res, err, wait_ms = drive()
				if err and err.code ~= "cancelled" then
					mare.log("error", err.message)
					if err.code == "storage_corrupt" then
						break
					end
					if err.code == "storage_unavailable" and wait_ms == nil then
						wait_ms = 5000
					end
				end
				if stopped or lifetime:is_cancelled() then
					break
				end
				if not token:is_cancelled() then
					if res and res.admitted then
						mare.task.yield()
					elseif wait_ms == nil then
						token:wait()
					elseif wait_ms > 0 then
						mare.task.sleep(math.min(wait_ms, 2147483647), token)
					else
						mare.task.yield()
					end
				end
			end
		end)
	end,
}
