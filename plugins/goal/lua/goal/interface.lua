return function(ctx, store, runtime, policy)
	local display = require("goal.display")(ctx, store, runtime)
	local references = require("goal.input")(ctx, store, runtime)
	local function reply(value, err, completion_report)
		if err then
			return { content = err, is_error = true }
		end
		local view = runtime.view()
		if view.goal == nil then
			view.goal = mare.json.null
		end
		if completion_report then
			view.completion_budget_report = completion_report
		end
		return { content = mare.json.encode(view), details = view }
	end
	local function register(name, description, properties, required, fn, read)
		ctx.tools:register(name, {
			description = description,
			side_effect = read and "read" or "write",
			idempotent = read == true,
			parameters = {
				type = "object",
				properties = properties,
				required = mare.json.array(required),
				additionalProperties = false,
			},
			execute = function(args)
				-- Model mutations require the live model driver.
				-- Native controllers use the separate public goals service.
				if not read and (not (ctx.agent:get() or {}).busy or not mare.exec.current()) then
					return {
						content = "Goal model mutations require the active tool pipeline; native controllers use the goals service.",
						is_error = true,
					}
				end
				return reply(fn(args))
			end,
		})
	end
	register(
		"get_goal",
		"Read the current goal, status, budgets, token usage, elapsed activity time and remaining tokens.",
		{},
		{},
		function()
			return true
		end,
		true
	)
	register(
		"create_goal",
		policy.create,
		{ objective = { type = "string" }, token_budget = { type = "integer" }, max_goal_rounds = { type = "integer" } },
		{ "objective" },
		function(a)
			local g, err = runtime.create(a.objective, a.token_budget, a.max_goal_rounds)
			if g then
				runtime.stopped = false
				runtime.ready = true
				runtime.attach()
				runtime.kick()
			end
			return g, err
		end
	)
	register("update_goal", policy.update, {
		status = { type = "string", enum = { "complete", "blocked", "paused" } },
		goal_id = { type = "string" },
		revision = { type = "integer" },
		blocked_reason = { type = "string" },
	}, { "status", "goal_id", "revision" }, function(a)
		local g, err = runtime.status(a.status, false, { goal_id = a.goal_id, revision = a.revision }, a.blocked_reason)
		local report
		if g and a.status == "complete" and (g.token_budget ~= nil or (g.time_used_seconds or 0) > 0) then
			report = string.format(
				"Report the final token and time budget usage in your closing message using the authoritative numbers in this payload: tokens_used=%d, token_budget=%s, time_used_seconds=%.1f.",
				g.tokens_used,
				g.token_budget ~= nil and tostring(g.token_budget) or "none",
				g.time_used_seconds or 0
			)
		end
		return g, err, report
	end)
	local function notify(ok, err)
		mare.ui.notify(err or display.summary(), err and "error" or "info")
		return ok
	end
	ctx.commands:register("goal", {
		description = "Long-running objective: status, pause, resume, edit, budget, rounds or clear",
		args = "[objective|status|pause|resume|edit <objective>|budget <tokens>|rounds <count>|clear]",
		availability = "always",
		run = function(args, input)
			local prepared, error = references.prepare(args, input)
			if not prepared then
				mare.ui.notify(error, "error")
				return { status = "rejected", reason = error }
			end
			local has_references = #prepared.content > 0
			local function deliver(value)
				if not store.same(prepared.owner, store.owner()) then
					return nil, "goal command owner changed"
				end
				return references.deliver(value, prepared)
			end
			local function start_goal_turn(attach, ref_input_id, g)
				if has_references then
					local res = runtime.resume_foreground(prepared.owner, ref_input_id)
					if res.status == "started" then
						runtime.stopped = false
						runtime.ready = true
						if attach then
							runtime.attach()
						end
						return true
					end
					if res.status == "empty" then
						runtime.stopped = false
						runtime.ready = true
						if attach then
							runtime.attach()
						end
						runtime.kick()
						return true
					end
					runtime.stopped = true
					if res.status == "busy" or (res.status == "rejected" and (ctx.agent:get() or {}).busy) then
						runtime.resume_pending = {
							goal_id = g.id,
							revision = g.revision,
							owner = prepared.owner,
							input_id = ref_input_id,
							attach = attach == true,
							arm = true,
						}
						mare.ui.notify("Waiting for the current run to settle before resuming goal references.", "info")
						return true
					end
					return false, res.error or ("Goal reference resume " .. tostring(res.status))
				end
				runtime.stopped = false
				runtime.ready = true
				if attach then
					runtime.attach()
				end
				runtime.kick()
				return true
			end
			local action, rest = args:match("^(%S+)%s*(.-)%s*$")
			if not action then
				display.menu()
				return
			end
			if action == "status" then
				notify(true)
				return
			end
			if action == "pause" then
				runtime.stopped = true
				local g, err = runtime.status("paused", true)
				if g then
					runtime.cancel()
				end
				notify(g, err)
			elseif action == "resume" then
				local g, err, kind = runtime.resume_user()
				if kind == "goal" and g and g.status == "active" then
					runtime.stopped = false
					runtime.ready = true
					runtime.attach()
					runtime.kick()
				end
				if kind == "pending" then
					mare.ui.notify(
						"Waiting for the current run to settle before resuming foreground input or the goal.",
						"info"
					)
				end
				notify(g, err)
			elseif action == "clear" then
				if not store.get() then
					local reason = store.fault or "no current goal"
					notify(nil, reason)
					return { status = "rejected", reason = reason }
				end
				runtime.cancel()
				local _, err, ok = runtime.mutate(function()
					return nil
				end)
				notify(ok, err)
			elseif action == "edit" then
				local before = runtime.view().goal
				if not before then
					local reason = store.fault or "no current goal"
					notify(nil, reason)
					return { status = "rejected", reason = reason }
				end
				local budget
				if rest == "" then
					local form, err, kind = display.form(store.get())
					if not form then
						if err then
							mare.ui.notify(err, kind == "cancelled" and "info" or "error")
						end
						return { status = kind or "cancelled", reason = err or "Goal edit cancelled" }
					end
					rest, budget = form.objective, form.token_budget
				end
				local current = runtime.view().goal
				if
					not before
					or not current
					or before.id ~= current.id
					or before.revision ~= current.revision
					or not store.same(prepared.owner, store.owner())
				then
					return { status = "rejected", reason = "Goal changed while editing" }
				end
				local g, err = runtime.edit(rest, budget, nil, has_references)
				if not g then
					notify(nil, err)
					return { status = "rejected", reason = err }
				end
				local sent, ref_or_err = deliver(g)
				if not sent then
					notify(nil, ref_or_err)
					return { status = "rejected", reason = ref_or_err }
				end
				if g.status == "active" then
					local started, rerr = start_goal_turn(false, ref_or_err, g)
					if not started then
						notify(nil, rerr)
						return { status = "rejected", reason = rerr }
					end
				elseif has_references then
					local res = runtime.resume_foreground(prepared.owner, ref_or_err)
					if res.status == "busy" or (res.status == "rejected" and (ctx.agent:get() or {}).busy) then
						runtime.stopped = true
						runtime.resume_pending = {
							goal_id = g.id,
							revision = g.revision,
							owner = prepared.owner,
							input_id = ref_or_err,
							attach = false,
							arm = false,
						}
					elseif res.status ~= "started" and res.status ~= "empty" then
						runtime.stopped = true
						local rerr = res.error or ("Goal reference resume " .. tostring(res.status))
						notify(nil, rerr)
						return { status = "rejected", reason = rerr }
					end
				end
				notify(g)
			elseif action == "budget" or action == "rounds" then
				local g = store.get()
				if not g then
					local reason = store.fault or "no current goal"
					notify(nil, reason)
					return { status = "rejected", reason = reason }
				end
				local n = tonumber(rest)
				if not require("goal.journal").integer(n, 1) then
					notify(nil, "limit requires a positive safe integer")
					return
				end
				local value, err =
					runtime.edit(g.objective, action == "budget" and n or nil, action == "rounds" and n or nil)
				notify(value, err)
			else
				local g, err, outcome = display.create_user(args, nil, nil, has_references)
				if g then
					local sent, ref_or_err = deliver(g)
					if not sent then
						notify(nil, ref_or_err)
						return { status = "rejected", reason = ref_or_err }
					end
					local started, rerr = start_goal_turn(true, ref_or_err, g)
					if not started then
						notify(nil, rerr)
						return { status = "rejected", reason = rerr }
					end
				end
				if outcome == "cancelled" then
					mare.ui.notify(err, "info")
					return { status = "cancelled", reason = err }
				end
				notify(g, err)
				if err then
					return { status = "rejected", reason = err }
				end
			end
		end,
	})
	ctx.context:section({
		name = "goal:state",
		order = 1510,
		interpolate = false,
		text = function()
			local g = store.get()
			return g
					and (policy.update .. "\nCurrent goal data (use get_goal for authoritative state):\n" .. mare.json.encode(
						runtime.view()
					))
				or nil
		end,
	})
end
