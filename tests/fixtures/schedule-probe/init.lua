-- Integration-only observer. No clock replacement and no access to scheduler internals.
return {
	name = "schedule-probe",
	inject = { "schedule", "commands", "agent", "session", "tools", "llm", "policy" },
	apply = function(ctx)
		local path = assert(mare.env("SCHEDULE_REPORT"))
		local report = {
			requests = mare.json.array({}),
			ends = mare.json.array({}),
			calls = mare.json.array({}),
			tool_errors = 0,
			accepted_intervals = 0,
		}
		local function save()
			assert(mare.fs.write(path, mare.json.encode(report)))
		end
		local function scheduled_text(messages)
			local text = ""
			for i = #messages, 1, -1 do
				if messages[i].role == "user" then
					text = ""
					for _, block in ipairs(messages[i].content) do
						if block.type == "text" then
							text = text .. block.text
						end
					end
					if text:find("[Scheduled prompt", 1, true) then
						return text, i
					end
				end
			end
			return text, 0
		end
		-- A deterministic faux model consumes the actual request and emits complete tool
		-- arguments. Nothing rewrites the call after the model response is produced.
		local call_sequence, failed_once = 0, false
		ctx.llm:register_provider({
			provider = "faux-schedule",
			default_model = "echo",
			is_configured = function()
				return true
			end,
			models = {
				{
					model_id = "echo",
					name = "Schedule test faux",
					context_window = 100000,
					max_output = 4096,
					reasoning = true,
					efforts = { "low", "medium", "high" },
					cost = { input = 0, output = 0 },
				},
			},
			stream = function(req, sink)
				local text, user_at = scheduled_text(req.messages)
				if text:find("FAIL_ONCE", 1, true) and not failed_once then
					failed_once = true
					error({ message = "schedule fixture failure", retryable = false })
				end
				local id, revision, token = text:match("task_id=(%d+), revision=(%d+), run_token=([%da-f]+)")
				local phase = 0
				for i = user_at + 1, #req.messages do
					if req.messages[i].role == "tool_result" then
						phase = phase + 1
					end
				end
				if id and phase < 3 then
					call_sequence = call_sequence + 1
					local call_id = "schedule_faux_" .. call_sequence
					local args = {
						task_id = id,
						revision = tonumber(revision),
						run_token = token,
						delay_ms = phase == 0 and 59999 or 60000,
						reason = "Observed unchanged; retry in one minute",
					}
					sink({ type = "tool_call_start", tool_call_id = call_id, name = "schedule_set_next_delay" })
					return {
						role = "assistant",
						content = {
							{
								type = "tool_call",
								id = call_id,
								name = "schedule_set_next_delay",
								arguments = args,
							},
						},
						stop_reason = "tool_use",
						usage = { input = 10, output = 10 },
					}
				end
				sink({ type = "text_delta", delta = "scheduled check complete" })
				return {
					role = "assistant",
					content = { { type = "text", text = "scheduled check complete" } },
					stop_reason = "stop",
					usage = { input = 10, output = 10 },
				}
			end,
		})
		ctx:on("request/build", function(req, ev)
			local text = scheduled_text(req.messages)
			report.requests[#report.requests + 1] =
				{ text = text, at = mare.task.now(), turn = (ctx.agent:get() or {}).turn_id }
			save()
			return ev.next(req)
		end)
		ctx.policy:voter("tool/before", function(call)
			if call.name == "schedule_set_next_delay" then
				report.calls[#report.calls + 1] = call.arguments
				if
					not report.proxy_submit_ok
					and report.accepted_intervals >= 1
					and call.arguments.delay_ms == 60000
				then
					-- Fixed and adaptive tasks both exist: check the submitted task by its id.
					local function find(id)
						for _, task in ipairs(ctx.schedule:list()) do
							if task.id == id then
								return task
							end
						end
					end
					local ok_sub = ctx.schedule:submit(call.arguments)
					assert(ok_sub == true, "ctx.schedule:submit valid token must return true")
					local before_dup = assert(find(call.arguments.task_id), "submitted task missing")
					assert(before_dup.mode == "adaptive", "submit target must be the adaptive task")
					local dup_ok, dup_err = pcall(ctx.schedule.submit, ctx.schedule, call.arguments)
					assert(not dup_ok and dup_err and dup_err.code == "schedule.invalid_schedule")
					local after_dup = assert(find(call.arguments.task_id), "submitted task missing after duplicate")
					assert(
						after_dup.status == "active"
							and after_dup.effective_delay == before_dup.effective_delay
							and after_dup.delay_reason == before_dup.delay_reason,
						"duplicate submit changed the task: " .. mare.json.encode(after_dup)
					)
					report.proxy_submit_ok = true
					report.proxy_submit_task = call.arguments.task_id
					report.proxy_submit_reason = call.arguments.reason
				end
				save()
			end
		end)
		ctx:on("turn/completed", function(result)
			report.ends[#report.ends + 1] = { turn_id = result.turn_id, error = result.error, at = mare.task.now() }
			report.tasks = ctx.schedule:list()
			save()
		end)
		ctx:on("item/completed", function(event)
			local item = event and event.item
			if item and item.type == "tool_call" and item.name == "schedule_set_next_delay" then
				if item.result and item.result.is_error then
					report.tool_errors = report.tool_errors + 1
				else
					report.accepted_intervals = report.accepted_intervals + 1
				end
				save()
			end
		end)
		ctx.commands:register("schedule-probe", {
			description = "Integration fixture actions",
			run = function(action)
				if action == "contracts" then
					local ok_create, create_err =
						pcall(ctx.schedule.create, ctx.schedule, "reject short interval", 59999)
					assert(not ok_create and create_err and create_err.code == "schedule.invalid_schedule")
					assert(#ctx.schedule:list() == 0)
					ctx.commands:run("/loop 59s must be rejected")
					assert(#ctx.schedule:list() == 0)
					ctx.commands:run("/loop 1m created through the command")
					local command_task = assert(ctx.schedule:list()[1]).id
					ctx.commands:run("/loop pause " .. command_task)
					assert(ctx.schedule:list()[1].status == "paused")
					ctx.commands:run("/loop resume " .. command_task)
					assert(ctx.schedule:list()[1].status == "active")
					ctx.commands:run("/loop stop " .. command_task)
					assert(#ctx.schedule:list() == 0)
					local task = assert(ctx.schedule:create("paused before due", 60000))
					assert(ctx.schedule:control("pause", task).ok == true)
					assert(ctx.schedule:list()[1].status == "paused")
					assert(ctx.schedule:control("resume", task).ok == true)
					assert(ctx.schedule:list()[1].status == "active")
					assert(ctx.schedule:control("stop", task).ok == true)
					assert(#ctx.schedule:list() == 0)
					local ok_sub, sub_err = pcall(ctx.schedule.submit, ctx.schedule, {
						task_id = task,
						revision = 1,
						run_token = "old",
						delay_ms = 60000,
						reason = "stale",
					})
					assert(not ok_sub and sub_err and sub_err.code == "schedule.invalid_schedule")
					report.contracts = true
				elseif action == "start" then
					assert(ctx.schedule:create("/lua error('scheduled slash must remain prompt')", 60000))
					assert(ctx.schedule:create("Watch and choose the next delay"))
				elseif action == "stop" then
					for _, task in ipairs(ctx.schedule:list()) do
						assert(ctx.schedule:control("stop", task.id).ok == true)
					end
				elseif action == "list" then
					report.tasks = ctx.schedule:list()
				else
					error("Unknown probe action")
				end
				save()
			end,
		})
		save()
	end,
}
