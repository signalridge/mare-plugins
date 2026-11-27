-- Goal summary and interactive controls; editing uses the public input buffer value.
return function(ctx, store, runtime)
	local M = {}
	function M.summary()
		local view = runtime.view()
		local g = view.goal
		if not g then
			return view.fault or "No goal is currently set."
		end
		local lines = {
			g.objective,
			"Status: " .. g.status,
			string.format(
				"Tokens used: %d%s",
				g.tokens_used,
				g.token_budget and (" / " .. g.token_budget .. " (remaining " .. g.remaining_tokens .. ")") or ""
			),
			string.format("Activity: %.1fs · audit turn %d", g.time_used_seconds, g.audit_rounds),
		}
		lines[#lines + 1] = string.format("Goal rounds: %d / %d", g.rounds_started, g.max_goal_rounds)
		if g.usage_complete == false then
			lines[#lines + 1] = "Usage is incomplete; only reported tokens are included."
		end
		if g.last_reason then
			lines[#lines + 1] = "Last run: " .. g.last_reason
		end
		if g.blocker then
			lines[#lines + 1] = "Blocker: " .. g.blocker.message
		end
		if g.continuation_stopped and g.status == "active" then
			lines[#lines + 1] = g.stop_reason == "references-pending"
					and "Reference delivery is not acknowledged; retry the goal command with its attachments."
				or "Automatic continuation is stopped; use /goal resume."
		end
		return table.concat(lines, "\n")
	end
	local function cancel_kind(reason)
		return (reason == nil or reason == "cancelled" or reason == "interrupted") and "cancelled" or "rejected"
	end
	function M.form(existing)
		local objective, objective_reason = mare.ui.input({
			title = existing and "Edit goal objective" or "New goal objective",
			placeholder = "Concrete result to achieve",
			default = existing and existing.objective or "",
		})
		if objective == nil then
			return nil, "Goal editing " .. (objective_reason or "cancelled"), cancel_kind(objective_reason)
		end
		if not objective:find("%S") then
			return nil, "Objective must be non-empty"
		end
		local budget, budget_reason = mare.ui.input({
			title = "Token budget (optional; leave empty to keep current)",
			placeholder = existing and existing.token_budget and tostring(existing.token_budget)
				or "No budget unless explicitly requested",
		})
		if budget == nil then
			return nil, "Goal budget editing " .. (budget_reason or "cancelled"), cancel_kind(budget_reason)
		end
		local value = budget ~= "" and tonumber(budget) or nil
		if budget ~= "" and (not value or value <= 0 or value % 1 ~= 0) then
			return nil, "Token budget must be a positive integer"
		end
		return { objective = objective, token_budget = value }
	end
	local offered_owner
	local function offer_resume()
		local g = store.get()
		local owner = store.owner()
		if not g or g.status ~= "paused" or (offered_owner and store.same(offered_owner, owner)) then
			return
		end
		offered_owner = owner
		local revision = store.revision
		local selected = mare.ui.select({
			title = "Resume paused goal?",
			body = M.summary(),
			items = {
				{ label = "Resume goal", detail = "Continue toward the saved objective" },
				{ label = "Keep paused", detail = "Use /goal resume when ready" },
			},
		})
		if selected ~= 1 then
			return
		end
		-- `session/changed` fires before `finish_switch` releases its switch lease; wait for
		-- the switch to settle so `resume_user()` (`agent:resume_input`) does not see `busy`.
		local wait_ticks = 0
		while
			ctx.session
			and type(ctx.session.switching) == "function"
			and ctx.session:switching()
			and not runtime.disposed
			and store.same(owner, store.owner())
			and wait_ticks < 500
		do
			wait_ticks = wait_ticks + 1
			mare.task.sleep(10)
		end
		if not store.same(owner, store.owner()) or store.revision ~= revision then
			mare.ui.notify("Goal changed while asking to resume; no changes saved.", "warning")
			return
		end
		local value, err, kind = runtime.resume_user()
		if err then
			mare.ui.notify(err, "error")
			return
		end
		if kind == "goal" and value and value.status == "active" then
			runtime.stopped = false
			runtime.ready = true
			runtime.attach()
			runtime.kick()
		end
	end
	ctx:on("app/ready", function()
		ctx:after(0, offer_resume)
	end)
	ctx:on("session/changed", function(ev)
		if ev.reason == "resume" then
			ctx:after(0, offer_resume)
		end
	end)
	function M.create_user(objective, budget, max_rounds, pending_references)
		local fields, err = runtime.validate_definition(objective, budget, max_rounds)
		if not fields then
			return nil, err, "rejected"
		end
		local current = runtime.view().goal
		if current and current.status ~= "complete" then
			local preview = mare.text.cut(fields.objective, 200, { unit = "chars" })
			local selected = mare.ui.select({
				title = "Replace goal?",
				body = "New objective: " .. preview,
				items = {
					{ label = "Replace current goal", detail = "Clear it and start the new objective" },
					{ label = "Cancel", detail = "Keep the current goal" },
				},
			})
			if selected ~= 1 then
				return nil, "Goal replacement cancelled; the current goal is unchanged.", "cancelled"
			end
			local value, failure = runtime.replace(
				current.ref,
				fields.objective,
				fields.token_budget,
				fields.max_goal_rounds,
				pending_references
			)
			return value, failure, failure and "rejected" or "accepted"
		end
		local value, failure =
			runtime.create(fields.objective, fields.token_budget, fields.max_goal_rounds, pending_references)
		return value, failure, failure and "rejected" or "accepted"
	end
	function M.menu()
		if store.fault then
			mare.ui.notify(store.fault, "error")
			return
		end
		local g = store.get()
		mare.ui.notify(M.summary(), "info")
		local actions = {}
		if g then
			actions[#actions + 1] = { id = "edit", label = "Edit objective and budget" }
			if g.status == "active" then
				actions[#actions + 1] = { id = "pause", label = "Pause goal" }
			elseif g.status ~= "complete" and g.status ~= "budget_limited" then
				actions[#actions + 1] = { id = "resume", label = "Resume goal" }
			end
			actions[#actions + 1] = { id = "clear", label = "Clear goal" }
		else
			actions[#actions + 1] = { id = "create", label = "Create a goal" }
		end
		local owner, revision = store.owner(), store.revision
		local selected = mare.ui.select({ title = "Goal", body = M.summary(), items = actions })
		if not selected then
			return
		end
		if not store.same(owner, store.owner()) or revision ~= store.revision then
			mare.ui.notify("Goal changed while the menu was open; reopen /goal.", "warning")
			return
		end
		local action = actions[selected].id
		if action == "create" or action == "edit" then
			local form, err, kind = M.form(g)
			if not form then
				if err then
					mare.ui.notify(err, kind == "cancelled" and "info" or "error")
				end
				return
			end
			if not store.same(owner, store.owner()) or revision ~= store.revision then
				mare.ui.notify("Goal changed while editing; no changes saved.", "warning")
				return
			end
			local value, failure
			if action == "create" then
				value, failure = M.create_user(form.objective, form.token_budget)
			else
				value, failure = runtime.edit(form.objective, form.token_budget)
			end
			if failure then
				mare.ui.notify(failure, "error")
				return
			end
			if value and value.status == "active" then
				runtime.stopped = false
				runtime.ready = true
				runtime.attach()
				runtime.kick()
			end
			mare.ui.notify(M.summary(), "info")
		else
			pcall(ctx.commands.run, ctx.commands, "/goal " .. action)
		end
	end
	local last_id, last_status
	ctx:on("goal/changed", function(event)
		if event.owner and not store.same(event.owner, store.owner()) then
			return
		end
		local g = event.goal
		if g and (g.id ~= last_id or g.status ~= last_status) then
			if g.status == "blocked" or g.status == "budget_limited" or g.status == "usage_limited" then
				mare.ui.notify(M.summary(), "warning")
			end
		end
		last_id, last_status = g and g.id, g and g.status
	end)
	return M
end
