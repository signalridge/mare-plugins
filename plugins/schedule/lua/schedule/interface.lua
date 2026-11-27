local policy = require("schedule.policy")
return function(ctx, scheduler)
	local function notify(text, level)
		mare.ui.notify(text, level or "info")
	end
	ctx.commands:register("loop", {
		description = "Repeat a prompt: [interval] prompt, list, pause/resume/stop id",
		args = "[interval] <prompt> | list | pause|resume|stop <id>",
		run = function(raw)
			local args = raw:match("^%s*(.-)%s*$")
			if args == "list" then
				local lines = {}
				for _, task in ipairs(scheduler.list()) do
					lines[#lines + 1] = string.format(
						"%s %s %s; delay=%sms (%s); due=%s expires=%s pending=%s%s",
						task.id,
						task.mode,
						task.status,
						task.effective_delay,
						task.delay_reason,
						tostring(task.next_due or "none"),
						task.expires_at,
						tostring(task.pending),
						task.error and "; " .. task.error or ""
					)
				end
				notify(#lines > 0 and table.concat(lines, "\n") or "No scheduled prompts")
				return
			end
			local action, id = args:match("^(%a+)%s+(%d+)$")
			if action == "stop" or action == "pause" or action == "resume" then
				local ok, message = scheduler.control(nil, nil, action, id)
				notify(message, ok and "info" or "error")
				return
			end
			if args == "" or args == "stop" or args == "pause" or args == "resume" then
				notify("Usage: /loop [interval] <prompt> | list | pause|resume|stop <id>", "warning")
				return
			end
			local first, rest = args:match("^(%S+)%s+(.+)$")
			local interval, prompt = nil, args
			if first and (first:match("^%d") or first:match("^[-+]%d")) then
				local err
				interval, err = policy.interval(first)
				if not interval then
					notify(err, "error")
					return
				end
				prompt = rest
			end
			local task_id, err = scheduler.create(nil, nil, prompt, interval)
			if not task_id then
				notify(err, "error")
				return
			end
			notify(
				"Scheduled prompt "
					.. task_id
					.. (interval and " (fixed)" or " (adaptive, initial delay 60000ms)")
					.. "; this session only; expires in seven days"
			)
		end,
	})
	ctx.tools:register("schedule_set_next_delay", {
		description = "Set the next delay for this running adaptive scheduled prompt using its task ID, revision and run token. Delay is 60000–3600000 milliseconds. Does not start or resume tasks.",
		side_effect = "write",
		idempotent = false,
		parameters = {
			type = "object",
			additionalProperties = false,
			required = { "task_id", "revision", "run_token", "delay_ms", "reason" },
			properties = {
				task_id = { type = "string" },
				revision = { type = "integer" },
				run_token = { type = "string" },
				delay_ms = { type = "integer" },
				reason = { type = "string" },
			},
		},
		execute = function(args)
			local ok, err = scheduler.submit(nil, nil, args)
			return {
				content = ok and "Next interval recorded; it takes effect after this run succeeds" or err,
				is_error = not ok,
			}
		end,
	})
end
