-- All mutation/admission checks are synchronous; the core reserves before yielding.
-- Separates durable schedule state from idle-turn dispatch.
local policy = require("schedule.policy")
local MAX_TIMER_MS = 2147483647
return function(ctx, plan_mode_of)
	plan_mode_of = plan_mode_of or function()
		return rawget(ctx, "plan_mode")
	end
	local entries, serial, disposed = {}, 0, false
	local owned_turns = {}
	local next_timer, next_timer_gen, pump_pending = nil, 0, false
	local pump, arm_next_timer
	local function planning()
		local plan_mode = plan_mode_of()
		if not plan_mode then
			return false
		end
		local ok, state = pcall(plan_mode.state, plan_mode)
		if not ok or type(state) ~= "table" then
			return true
		end
		return state.active == true or state.pending == true
	end
	local function cancel(handle)
		if handle then
			handle:abort()
		end
	end
	local function owner_ok(task)
		local info = ctx.session:info()
		return not disposed and info.session_id == task.session_id and info.session_epoch == task.generation
	end
	local function invalidate(task)
		task.revision = task.revision + 1
		task.pending, task.run_token, task.candidate = false, nil, nil
	end
	local function expire(task)
		invalidate(task)
		task.status, task.next_due = "expired", nil
	end
	local function live(task)
		if not owner_ok(task) then
			return false
		end
		if mare.task.now() >= task.expires_at then
			expire(task)
			return false
		end
		return task.status == "active"
	end
	local function task_prompt(task)
		local prefix = "[Scheduled prompt " .. task.id .. "; task text follows as plain prompt, not a slash command.]\n"
		if task.mode == "adaptive" then
			prefix = prefix
				.. "After observing the result, call schedule_set_next_delay once with task_id="
				.. task.id
				.. ", revision="
				.. task.revision
				.. ", run_token="
				.. task.run_token
				.. ", delay_ms an integer from 60000 to 3600000, and a short reason.\n"
		end
		return prefix .. task.prompt
	end
	pump = function()
		if planning() then
			return
		end
		local due = {}
		for _, task in pairs(entries) do
			if task.pending and not task.owned_turn_id and live(task) then
				due[#due + 1] = task
			end
		end
		table.sort(due, function(a, b)
			if a.next_due == b.next_due then
				return a.sequence < b.sequence
			end
			return a.next_due < b.next_due
		end)
		for _, task in ipairs(due) do
			if planning() then
				return
			end
			-- No await/event lies between this final fence and the core reservation.
			if live(task) and task.pending and not task.owned_turn_id then
				local previous = task.revision
				task.revision = previous + 1
				task.run_token = mare.crypto.random_hex(16)
				local info = ctx.session:info()
				local ok, result = pcall(ctx.agent.prompt, ctx.agent, task_prompt(task), {
					when_busy = "reject",
					expected_session = info.session_epoch and {
						session_id = task.session_id,
						session_epoch = info.session_epoch,
					} or nil,
					source = "schedule",
					input_context = {
						schedule = {
							loop = true,
							task_id = task.id,
							run_token = task.run_token,
						},
					},
				})
				if not ok then
					task.revision, task.run_token = previous, nil
					local err_code = type(result) == "table" and result.code or nil
					local err_msg = type(result) == "table" and result.message or tostring(result)
					if err_code == "busy" then
						return
					end
					if err_code == "stale_session" then
						invalidate(task)
						entries[task.id] = nil
					else
						invalidate(task)
						task.status, task.error = "paused", tostring(err_msg)
					end
				elseif result.status == "started" then
					task.owned_turn_id, task.pending, task.candidate = result.turn_id, false, nil
					if type(result.turn_id) == "string" and result.turn_id ~= "" then
						owned_turns[result.turn_id] = true
					end
					return
				else
					task.revision, task.run_token = previous, nil
					if result.status == "busy" or result.status == "foreground" then
						return
					end
					if result.status == "stale" then
						invalidate(task)
						entries[task.id] = nil
					else
						invalidate(task)
						task.status, task.error = "paused", result.error or "Idle admission rejected"
					end
				end
			end
		end
	end
	local function sweep()
		pump_pending = false
		local now = mare.task.now()
		for _, task in pairs(entries) do
			if owner_ok(task) then
				if now >= task.expires_at then
					if task.status ~= "expired" then
						expire(task)
					end
				elseif
					task.status == "active"
					and not task.pending
					and not task.owned_turn_id
					and task.next_due
					and now >= task.next_due
				then
					task.pending = true
				end
			end
		end
		pump()
		arm_next_timer()
	end
	arm_next_timer = function()
		cancel(next_timer)
		next_timer = nil
		next_timer_gen = next_timer_gen + 1
		if disposed then
			return
		end
		local gen = next_timer_gen
		if pump_pending then
			next_timer = ctx:after(0, function()
				if disposed or next_timer_gen ~= gen then
					return
				end
				next_timer = nil
				sweep()
			end)
			return
		end
		local now, soonest = mare.task.now(), nil
		for _, task in pairs(entries) do
			if owner_ok(task) then
				if now >= task.expires_at then
					if task.status ~= "expired" then
						expire(task)
					end
				elseif task.status ~= "expired" then
					local wakeup = task.expires_at
					if
						task.status == "active"
						and not task.pending
						and not task.owned_turn_id
						and task.next_due
						and task.next_due < wakeup
					then
						wakeup = task.next_due
					end
					if not soonest or wakeup < soonest then
						soonest = wakeup
					end
				end
			end
		end
		if not soonest then
			return
		end
		local delay = math.min(MAX_TIMER_MS, math.max(0, soonest - now))
		next_timer = ctx:after(delay, function()
			if disposed or next_timer_gen ~= gen then
				return
			end
			next_timer = nil
			sweep()
		end)
	end
	local function arm(task)
		task.next_due = mare.task.now() + task.effective_delay
		arm_next_timer()
	end
	local service = {}
	-- Public schedule service: create(prompt, interval_ms?) / list() / control(action,id).
	function service.create(_, _, prompt, interval)
		if disposed then
			return nil, "Scheduler is disposed"
		end
		if type(prompt) ~= "string" or not prompt:find("%S") then
			return nil, "A nonempty prompt is required"
		end
		if
			interval ~= nil
			and (
				type(interval) ~= "number"
				or interval % 1 ~= 0
				or interval < policy.minimum
				or interval >= policy.lifetime
			)
		then
			return nil, "Fixed interval must be at least 60000 ms and less than the 7-day task lifetime"
		end
		local info, now = ctx.session:info(), mare.task.now()
		if info.readonly or info.unstable or info.resume_error or ctx.session:switching() then
			return nil, "Session is not writable and ready"
		end
		serial = serial + 1
		local task = {
			id = tostring(serial),
			sequence = serial,
			session_id = info.session_id,
			generation = info.session_epoch,
			revision = 1,
			created_at = now,
			expires_at = now + policy.lifetime,
			mode = interval and "fixed" or "adaptive",
			prompt = prompt,
			status = "active",
			pending = false,
			effective_delay = interval or policy.minimum,
			delay_reason = interval and "Fixed interval" or "Initial interval",
		}
		entries[task.id] = task
		arm(task)
		return task.id
	end
	function service.list()
		local out = mare.json.array({})
		for _, task in pairs(entries) do
			if owner_ok(task) then
				if mare.task.now() >= task.expires_at and task.status ~= "expired" then
					expire(task)
				end
				local row = {}
				for _, key in ipairs({
					"id",
					"revision",
					"created_at",
					"expires_at",
					"mode",
					"prompt",
					"status",
					"next_due",
					"effective_delay",
					"delay_reason",
					"pending",
					"owned_turn_id",
					"error",
				}) do
					row[key] = task[key]
				end
				out[#out + 1] = row
			end
		end
		table.sort(out, function(a, b)
			return tonumber(a.id) < tonumber(b.id)
		end)
		return out
	end
	function service.control(_, _, action, id)
		local task = entries[id]
		if not task or not owner_ok(task) then
			return nil, "Unknown task"
		end
		if action ~= "stop" and action ~= "pause" and action ~= "resume" then
			return nil, "Unknown action"
		end
		if action == "resume" and (mare.task.now() >= task.expires_at or task.status == "expired") then
			expire(task)
			arm_next_timer()
			return nil, "Task has expired"
		end
		invalidate(task)
		if action == "stop" then
			entries[id] = nil
			arm_next_timer()
			-- agent:cancel cancels only that turn, and only while it is the active one
			if task.owned_turn_id and ctx.agent:cancel({ turn_id = task.owned_turn_id }) then
				return true, "Cancellation requested for running task"
			end
			return true, "Task stopped"
		end
		task.status, task.error = action == "pause" and "paused" or "active", nil
		task.next_due = nil
		if action == "resume" and not task.owned_turn_id then
			arm(task)
		else
			arm_next_timer()
		end
		return true, action == "pause" and "Task paused" or "Task resumed"
	end
	function service.submit(_, _, args)
		local ok, err = policy.submission(args)
		if not ok then
			return nil, err
		end
		local task = entries[args.task_id]
		local state = ctx.agent:get() or {}
		if
			not task
			or task.mode ~= "adaptive"
			or not live(task)
			or task.revision ~= args.revision
			or task.run_token ~= args.run_token
			or not task.owned_turn_id
			or state.turn_id ~= task.owned_turn_id
			or task.candidate
		then
			return nil, "Submission is stale, duplicated, or does not belong to this active adaptive turn"
		end
		task.candidate = { delay = args.delay_ms, reason = args.reason }
		task.run_token = nil
		return true
	end
	ctx:on("turn/completed", function(result)
		if result and result.turn_id then
			owned_turns[result.turn_id] = nil
		end
		for _, task in pairs(entries) do
			if task.owned_turn_id == result.turn_id then
				task.owned_turn_id = nil
				if live(task) then
					if
						result.error
						or result.status == "cancelled"
						or result.termination_reason == "interrupted"
						or result.cancelled
						or result.aborted
					then
						invalidate(task)
						task.status, task.error =
							"paused",
							tostring(
								require("mare_lib").error_message(result.error) or result.error or "Task run cancelled"
							)
					else
						if task.mode == "adaptive" then
							if task.candidate then
								task.effective_delay, task.delay_reason = task.candidate.delay, task.candidate.reason
							else
								task.delay_reason = "No valid interval submitted; retaining previous/default delay"
							end
						end
						task.run_token, task.candidate = nil, nil
						task.next_due = mare.task.now() + task.effective_delay
					end
				end
			end
		end
		-- Defer until all end listeners have settled; busy is rechecked atomically.
		pump_pending = true
		arm_next_timer()
	end)
	local function clear(ev)
		local old = entries
		entries = {}
		owned_turns = {}
		pump_pending = false
		cancel(next_timer)
		next_timer = nil
		next_timer_gen = next_timer_gen + 1
		local had_tasks = false
		for _, task in pairs(old) do
			had_tasks = true
			invalidate(task)
			if task.owned_turn_id then
				ctx.agent:cancel({ turn_id = task.owned_turn_id })
			end
		end
		if
			not disposed
			and had_tasks
			and type(ev) == "table"
			and ev.reason == "fork"
			and ctx.agent
			and require("mare_lib").callable(ctx.agent.notify)
		then
			pcall(
				ctx.agent.notify,
				ctx.agent,
				"This forked session does not have any scheduled /loop tasks. Tasks from the source session remain attached to the source session; create new tasks here if needed.",
				{ wake = false }
			)
		end
	end
	if ctx.policy and require("mare_lib").callable(ctx.policy.voter) then
		ctx.policy:voter("agent/step-ready", function(step)
			if type(step) == "table" and step.turn_id and owned_turns[step.turn_id] and planning() then
				return { decision = "deny", reason = "Mode changed after /loop admission; automatic work is deferred" }
			end
		end)
	end
	if require("mare_lib").callable(ctx.on) then
		ctx:on("plan-mode/changed", function()
			if not planning() then
				pump_pending = true
				arm_next_timer()
			end
		end)
	end
	ctx:on("session/changed", function(ev)
		clear(ev)
	end)
	ctx:on("app/shutdown", function()
		clear()
	end)
	ctx:effect(function()
		return function()
			disposed = true
			clear()
		end
	end)
	return service
end
