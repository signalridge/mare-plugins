-- Independent implementation of the goal round driver.
-- Mare adaptations: public admission claims; domain revisions separate from
-- durable usage journal sequence; source=goal alone never authorizes a round claim.
return function(ctx, store, serial, policy, cfg)
	local M = {
		stopped = false,
		ready = false,
		run = nil,
		plan = false,
		disposed = false,
		claims = {},
		reference_inputs = {},
		pending_reference_delivery = nil,
	}
	local pending = false
	local function snapshot()
		return store.get(), store.revision, store.owner()
	end
	local function mutate(fn, rebase, on_commit)
		local owner, expected = store.owner(), store.revision
		local value, err, written, event = serial(function()
			if not store.same(owner, store.owner()) or (not rebase and expected ~= store.revision) then
				return nil, "stale goal revision or session"
			end
			local g, r = snapshot()
			local next, failure = fn(g)
			if failure then
				return nil, failure
			end
			local ok, error, published = store.commit(next, r, owner)
			if ok and on_commit then
				on_commit(next)
			end
			return ok and store.get() or nil, error, ok, published
		end, owner)
		-- Publishing after releasing the permit permits public observers to issue a
		-- new exact-ref mutation without deadlocking inside the previous transaction.
		if written then
			store.publish(event)
		end
		return value, err, written
	end
	M.mutate = mutate
	require("goal.control")(ctx, store, serial, cfg, M, mutate)
	function M.resume_foreground(owner, input_id)
		if not (ctx.agent and require("mare_lib").callable(ctx.agent.resume_input)) then
			return { status = "empty" }
		end
		local result = ctx.agent:resume_input(
			{ session_id = owner.id, session_epoch = owner.generation },
			input_id and { input_id = input_id } or nil
		)
		if result.status == "started" then
			local g = store.get()
			local reference = M.reference_inputs[result.input_id]
			local related = reference
				and g
				and reference.goal_id == g.id
				and reference.revision == g.revision
				and store.same(reference.owner, owner)
			M.stopped = not related
			M.foreground_turn = {
				turn_id = result.turn_id,
				input_id = result.input_id,
				owner = owner,
				goal_reference = related == true,
			}
			if not related then
				mare.ui.notify("Resumed retained foreground input; the goal has not resumed.", "info")
			end
		end
		return result
	end
	function M.kick()
		if pending or not M.ready or M.disposed or M.stopped or M.plan then
			return
		end
		pending = true
		do
			pending = false
			if M.disposed or M.stopped or M.plan or not M.ready then
				return
			end
			local g, r, owner = snapshot()
			if not g or g.status ~= "active" or g.stop_reason == "references-pending" or not store.writable() then
				return
			end
			if g.rounds_started >= g.max_goal_rounds then
				mutate(function(v)
					v.status = "blocked"
					v.revision = v.revision + 1
					v.blocker = {
						code = "round-limit",
						message = "The configured goal round allowance is exhausted; increase it before resuming.",
					}
					return v
				end)
				M.stopped = true
				return
			end
			serial(function()
				if M.stopped or M.plan or M.disposed or store.revision ~= r or not store.same(owner, store.owner()) then
					return
				end
				local agent_state = ctx.agent:get() or {}
				if agent_state.busy then
					return
				end
				local has_queued = (agent_state.queued or 0) > 0
				if not has_queued and require("mare_lib").callable(ctx.agent.list_queue) then
					local qok, qres = pcall(ctx.agent.list_queue, ctx.agent)
					if qok and type(qres) == "table" and type(qres.data) == "table" and #qres.data > 0 then
						has_queued = true
					end
				end
				if has_queued then
					local fg = M.resume_foreground(owner)
					if fg.status == "started" or fg.status == "busy" or fg.status == "rejected" then
						return
					end
				end
				local prompt = policy.audit
					.. "\nGoal turn "
					.. tostring(g.audit_rounds + 1)
					.. " (audit epoch "
					.. g.audit_epoch
					.. ")\n<objective>\n"
					.. g.objective
					.. "\n</objective>\n"
					.. mare.json.encode(M.view())
				local info = ctx.session:info()
				local ok, result = pcall(ctx.agent.prompt, ctx.agent, prompt, {
					when_busy = "reject",
					expected_session = info.session_epoch and {
						session_id = owner.id,
						session_epoch = info.session_epoch,
					} or nil,
					source = "goal",
				})
				if not ok then
					local err_code = type(result) == "table" and result.code or nil
					local err_msg = type(result) == "table" and result.message or tostring(result)
					if err_code ~= "busy" and err_code ~= "stale_session" then
						M.stopped = true
						mare.ui.notify("Goal continuation rejected: " .. tostring(err_msg), "error")
					end
					return
				end
				if result.status == "started" then
					M.pending_turn = {
						turn_id = result.turn_id,
						id = g.id,
						revision = g.revision,
						owner = owner,
						source = "goal",
						automatic = true,
					}
					M.claims[result.turn_id] = M.pending_turn
				end
				if result.status == "foreground" then
					M.resume_foreground(owner)
				end
				if result.status == "rejected" then
					M.stopped = true
					mare.ui.notify("Goal continuation rejected: " .. tostring(result.error), "error")
				end
				-- busy work will produce another end event; stale reservations are discarded.
			end, owner)
		end
	end
	function M.start(ev)
		local owner, g = store.owner(), store.get()
		local claim = M.claims[ev.turn_id]
		M.claims[ev.turn_id] = nil
		local automatic = claim
			and not claim.cancelled
			and g
			and g.status == "active"
			and claim.id == g.id
			and claim.revision == g.revision
			and store.same(claim.owner, owner)
		if claim and not automatic then
			M.run = { turn_id = ev.turn_id, stale = true, owner = claim.owner }
			ctx.agent:cancel({ turn_id = ev.turn_id, clear_queue = false, reason = "parent" })
			return
		end
		if automatic then
			M.pending_turn = nil
		end
		local foreground = M.foreground_turn
			and M.foreground_turn.turn_id == ev.turn_id
			and store.same(M.foreground_turn.owner, owner)
		local goal_reference = foreground and M.foreground_turn.goal_reference
		if foreground then
			M.foreground_turn = nil
		end
		if not g or g.status ~= "active" then
			M.run = foreground and { turn_id = ev.turn_id, owner = owner, unrelated = true, foreground = true } or nil
			return
		end
		if not automatic and not foreground and not M.plan and not M.recovery_unknown then
			M.stopped = false
			M.ready = true
		end
		M.run = {
			turn_id = ev.turn_id,
			source = ev.source or ev.trigger,
			automatic = automatic == true,
			foreground = foreground,
			id = g.id,
			revision = g.revision,
			owner = owner,
			clock = mare.task.clock(),
			accounted = 0,
			requests = {},
			unrelated = (foreground and not goal_reference) or (M.plan and not automatic),
		}
	end
	function M.enter_history(event)
		local run = M.run
		if not run or run.stale or run.closed or run.unrelated then
			return
		end
		local item = type(event) == "table" and event.item or nil
		local msg = item and item.message or (type(event) == "table" and event.message or nil)
		if item and item.type == "tool_call" then
			run.activity = true
		end
		if type(msg) == "table" then
			if msg.role == "tool_result" then
				run.activity = true
			elseif msg.role == "assistant" then
				for _, block in ipairs(msg.content or {}) do
					if
						block.type == "tool_call"
						or (block.type == "reasoning" and block.redacted == true)
						or (type(block.text) == "string" and block.text:find("%S"))
					then
						run.activity = true
					end
				end
			end
		end
		if msg and msg.role ~= "user" then
			return
		end
		if run.entered then
			return
		end
		run.entered = true
		local g = store.get()
		if not run.automatic and g and g.audit_rounds == 0 and not g.stop_reason then
			return
		end
		local _, err = mutate(function(v)
			if not v or v.id ~= run.id or v.status ~= "active" then
				return nil, "goal changed"
			end
			if run.automatic then
				v.rounds_started = v.rounds_started + 1
				v.audit_rounds = v.audit_rounds + 1
				v.last_round_id = run.turn_id
			else
				v.audit_epoch = v.audit_epoch + 1
				v.stop_reason = nil
				v.audit_rounds = 0
				v.empty_rounds = 0
			end
			return v
		end, true)
		if err then
			M.stopped = true
			mare.ui.notify("Goal round admission failed: " .. tostring(err), "error")
			ctx.agent:cancel({ turn_id = run.turn_id, clear_queue = false, reason = "parent" })
		end
	end
	function M.enter_request(event)
		local run = M.run
		if not run or run.stale or run.closed or run.unrelated then
			return
		end
		run.awaiting_usage = true
		if event and type(event.request_id) == "string" then
			run.requests[event.request_id] = true
		end
		if not run.entered then
			M.enter_history()
		end
	end
	function M.usage(ev)
		local run = M.run
		if
			not run
			or (run.closed and not run.allow_final_usage)
			or run.unrelated
			or ev.purpose ~= "agent"
			or (ev.session_id and ev.session_id ~= run.owner.id)
		then
			return
		end
		if ev.request_id and next(run.requests) ~= nil and not run.requests[ev.request_id] then
			return
		end
		if not ev.request_id and next(run.requests) ~= nil then
			mutate(function(g)
				if g and g.id == run.id then
					g.usage_complete = false
					return g
				end
				return nil, "stale usage owner"
			end, true)
			return
		end
		run.awaiting_usage = false
		run.allow_final_usage = false
		local usage = ev.usage or {}
		-- Mare normalizes uncached input separately from cache reads/writes.
		local amount = (usage.input or 0) + (usage.output or 0) + (usage.cache_read or 0) + (usage.cache_write or 0)
		if amount == 0 then
			return
		end
		local stale = false
		local value, err = mutate(function(g)
			if not g or g.id ~= run.id or not store.same(run.owner, store.owner()) then
				stale = true
				return nil, "stale usage owner"
			end
			g.tokens_used = g.tokens_used + amount
			if g.token_budget and g.tokens_used >= g.token_budget and g.status ~= "complete" then
				if g.status ~= "budget_limited" then
					g.revision = g.revision + 1
				end
				g.status = "budget_limited"
			end
			return g
		end, true)
		if err and not stale then
			M.stopped = true
		elseif value and value.status == "budget_limited" and (ctx.agent:get() or {}).turn_id == run.turn_id then
			run.limited = true
		end
	end
	function M.finish(ev)
		local run = M.run
		if not run or (ev.turn_id and ev.turn_id ~= run.turn_id) then
			return
		end
		M.run = nil
		if run.stale then
			M.retry_on_settled = run.turn_id
			return
		end
		local reason = ev.termination_reason
			or (ev.status == "cancelled" and "interrupted" or ev.status == "failed" and "error" or ev.status)
		if run.unrelated then
			if reason ~= "completed" then
				M.stopped = true
			end
			return
		end
		local activity = run.activity == true
		for _, message in ipairs(ev.messages or {}) do
			if message.role == "tool_result" then
				activity = true
			end
			if message.role == "assistant" then
				for _, block in ipairs(message.content or {}) do
					if
						block.type == "tool_call"
						or (block.type == "reasoning" and block.redacted == true)
						or (type(block.text) == "string" and block.text:find("%S"))
					then
						activity = true
					end
				end
			end
		end
		local current = store.get()
		if not current or current.id ~= run.id or not store.same(run.owner, store.owner()) then
			M.retry_on_settled = run.turn_id
			return
		end
		if
			reason == "interrupted"
			and run.cancel_ref
			and current
			and current.id == run.id
			and current.status == "active"
			and current.revision > run.cancel_ref
		then
			mutate(function(g)
				if run.automatic and run.entered then
					g.last_finished_round_id = run.turn_id
				end
				if not run.closed then
					g.time_used_seconds = g.time_used_seconds + math.max(0, mare.task.clock() - run.clock) / 1000
				end
				if run.awaiting_usage then
					g.usage_complete = false
				end
				g.last_reason = "replaced"
				if g.stop_reason ~= "references-pending" then
					g.stop_reason = nil
				end
				return g
			end, true)
			M.retry_on_settled = run.turn_id
			return
		end
		local disposed = ev.cancellation_cause == "disposed" or M.host_shutdown or M.disposed
		local _, err = mutate(function(g)
			if not g or g.id ~= run.id or not store.same(run.owner, store.owner()) then
				return nil, "stale run owner"
			end
			if run.automatic and run.entered then
				g.last_finished_round_id = run.turn_id
			end
			if not run.closed then
				g.time_used_seconds = g.time_used_seconds + math.max(0, mare.task.clock() - run.clock) / 1000
			end
			g.last_reason = disposed and "disposed" or (ev.conclude_turn and "concluded" or reason or "unknown")
			if disposed then
				g.stop_reason = nil
			elseif reason ~= "completed" or ev.conclude_turn then
				g.stop_reason = g.last_reason
			end
			if run.awaiting_usage then
				g.usage_complete = false
			end
			if not run.closed and g.status == "active" then
				if reason == "usage_limit" then
					g.revision = g.revision + 1
					g.status = "usage_limited"
				elseif reason == "error" or reason == "turn_limit" then
					g.revision = g.revision + 1
					g.status = "blocked"
					g.blocker = {
						code = reason == "turn_limit" and "turn-limit" or "turn-error",
						message = tostring(
							require("mare_lib").error_message(ev.error)
								or ev.error
								or "The goal run ended with an error; resolve it before resuming."
						):match("^%s*(.-)%s*$"),
					}
				elseif reason == "interrupted" and run.automatic and not disposed then
					g.status = "paused"
					g.revision = g.revision + 1
				elseif reason == "completed" and run.automatic and not ev.conclude_turn then
					g.empty_rounds = activity and 0 or g.empty_rounds + 1
					-- Block after three consecutive empty automatic turns.
					if g.empty_rounds >= 3 then
						g.status = "blocked"
						g.revision = g.revision + 1
						g.blocker = {
							code = "empty-response",
							message = "Three consecutive automatic goal rounds returned no meaningful response.",
						}
					end
				end
			end
			return g
		end, true)
		if err or reason ~= "completed" or ev.conclude_turn then
			M.stopped = true
		end
		M.kick()
	end
	function M.restore()
		M.run = nil
		M.pending_turn = nil
		M.resume_pending = nil
		M.reference_inputs = {}
		M.pending_reference_delivery = nil
		M.foreground_turn = nil
		M.stopped = false
		store.restore()
		local restored = store.get()
		if
			restored
			and restored.status == "active"
			and (
				restored.stop_reason
				or (
					restored.last_reason
					and restored.last_reason ~= "completed"
					and restored.last_reason ~= "disposed"
					and restored.last_reason ~= "replaced"
				)
			)
		then
			M.stopped = true
		end
		-- Missing final usage after an unclean exit cannot safely be guessed or retried.
		M.recovery_unknown = ctx.session:info().crashed == true
			or (restored and restored.last_round_id ~= restored.last_finished_round_id)
			or false
		if M.recovery_unknown then
			M.stopped = true
			mare.ui.notify("Goal recovery requires /goal resume after checking interrupted work and usage", "warning")
		end
		M.kick()
	end
	local function guarded(fn, abort)
		return function(event)
			local owner = store.owner()
			local ok, result = pcall(fn, event)
			if ok then
				return result
			end
			if store.same(owner, store.owner()) then
				M.stopped = true
				store.fault = "Goal driver stopped: " .. tostring(result)
				mare.ui.notify(store.fault, "error")
				local run = M.run
				if abort and run then
					ctx.agent:cancel({ turn_id = run.turn_id, clear_queue = false, reason = "parent" })
				end
			end
		end
	end
	-- Cancellation refs are captured only by the control operation that issued
	-- them; external cancellations are observed from the checked final outcome,
	-- never inferred from a possibly rejected frontend request.
	-- tool/before is a decision point: a voter; deny wins in the vote fold, so the old
	-- priority = 1000 is not needed.
	ctx.policy:voter("tool/before", function(call)
		local run = M.run
		if run and run.limited and not run.wrap_up then
			if
				call.name == "get_goal"
				or (
					call.name == "update_goal"
					and (call.arguments.status == "complete" or call.arguments.status == "paused")
				)
			then
				local g = store.get()
				local args = call.arguments or {}
				local key = mare.json.encode(mare.json.array({
					g and g.id or "",
					g and g.revision or 0,
					call.name,
					args.status or "",
					args.goal_id or "",
					math.floor(args.revision or 0),
				}))
				run.budget_seen = run.budget_seen or {}
				if run.budget_seen[key] then
					ctx.agent:cancel({
						mode = "halt",
						reason = "The goal work budget is exhausted; duplicate budget bookkeeping cannot make progress. The goal remains unfinished; inspect the saved status or explicitly raise its budget before resuming.",
					})
					return { decision = "deny", reason = "duplicate budget bookkeeping without lifecycle progress" }
				end
				run.budget_seen[key] = true
				return
			end
			return {
				decision = "deny",
				reason = "The goal work budget is exhausted; only final status bookkeeping and a final reply are allowed.",
			}
		end
		if run and (run.wrap_up or store.fault) then
			return {
				decision = "deny",
				reason = "The goal round is closing; provide only the final reply, without further tools.",
			}
		end
	end)
	-- request/build is a waterfall: pass the rewritten request on via `ev.next(request)`
	ctx:on("request/build", function(request, ev)
		if M.run and M.run.limited and not M.run.wrap_up then
			local tools = mare.json.array({})
			for _, tool in ipairs(request.tools or {}) do
				if tool.name == "get_goal" or tool.name == "update_goal" then
					tools[#tools + 1] = tool
				end
			end
			request.tools = tools
			request.messages[#request.messages + 1] = {
				role = "user",
				content = { { type = "text", text = policy.budget .. "\n" .. mare.json.encode(M.view()) } },
			}
		end
		if M.run and M.run.wrap_up then
			request.tools = mare.json.array({})
			request.messages[#request.messages + 1] = {
				role = "user",
				content = {
					{
						type = "text",
						text = "The goal round is closed. Give the final status and observed usage; do not call more tools.",
					},
				},
			}
		end
		return ev.next(request)
	end)
	ctx:on("turn/started", guarded(M.start, true))
	ctx:on("item/completed", guarded(M.enter_history, true))
	ctx:on("llm/usage", guarded(M.usage, true))
	-- record the request before other listeners react (was priority = 1000; plan #6)
	ctx:on("step/started", guarded(M.enter_request, true), { prepend = true })
	local function drain_pending()
		if (ctx.agent:get() or {}).busy then
			return
		end
		if ctx.session and require("mare_lib").callable(ctx.session.switching) and ctx.session:switching() then
			return
		end
		local pending_resume = M.resume_pending
		if pending_resume then
			M.resume_pending = nil
			local g = store.get()
			if
				g
				and g.id == pending_resume.goal_id
				and g.revision == pending_resume.revision
				and store.same(pending_resume.owner, store.owner())
			then
				if pending_resume.input_id then
					local result = M.resume_foreground(pending_resume.owner, pending_resume.input_id)
					if result.status == "started" then
						if pending_resume.arm and g.status == "active" then
							M.stopped = false
							M.ready = true
							if pending_resume.attach then
								M.attach()
							end
						end
					elseif result.status == "empty" then
						if pending_resume.arm and g.status == "active" then
							M.stopped = false
							M.ready = true
							if pending_resume.attach then
								M.attach()
							end
							M.kick()
						end
					elseif
						result.status == "busy" or (result.status == "rejected" and (ctx.agent:get() or {}).busy)
					then
						M.resume_pending = pending_resume
						M.stopped = true
					else
						M.stopped = true
						mare.ui.notify(
							"Goal reference resume rejected: " .. tostring(result.error or result.status),
							"error"
						)
					end
				else
					local value, err, kind = M.resume_user()
					if err then
						mare.ui.notify(err, "error")
					elseif kind == "goal" and value then
						M.stopped = false
						M.ready = true
						M.attach()
						M.kick()
					end
				end
			end
		else
			M.kick()
		end
	end
	ctx:on("agent/settled", function(event)
		if M.retry_on_settled == event.turn_id then
			M.retry_on_settled = nil
		end
		if not event.busy then
			drain_pending()
		end
	end)
	ctx:on("session/switch-completed", drain_pending)
	ctx:on("compact/completed", drain_pending)
	ctx:on("turn/completed", guarded(M.finish, false))
	ctx:on("session/changed", M.restore)
	ctx:on("app/ready", function()
		M.ready = true
		M.kick()
	end)
	local function plan_state_gated(s)
		return type(s) == "table" and (s.active == true or s.pending == true)
	end
	ctx:on("plan-mode/changed", function(ev)
		M.plan = plan_state_gated(ev)
		if not M.plan then
			M.kick()
		end
	end)
	ctx:inject({ "plan_mode" }, function(scope)
		local ok, state = pcall(scope.plan_mode.state, scope.plan_mode)
		if ok and type(state) == "table" then
			M.plan = plan_state_gated(state)
		else
			M.plan = scope.plan_mode:active() == true
		end
		if not M.plan then
			M.kick()
		end
		scope:effect(function()
			return function()
				if M.plan then
					M.plan = true
					mare.ui.notify(
						"Goal continuation remains paused because plan_mode was unloaded while active.",
						"warning"
					)
				else
					M.plan = false
				end
			end
		end)
	end)
	ctx:on("app/shutdown", function()
		M.stopped = true
		M.host_shutdown = true
		M.ready = false
	end)
	ctx:effect(function()
		return function()
			M.disposed = true
			M.stopped = true
			local run = M.run or M.pending_turn
			if run and run.automatic and store.same(run.owner, store.owner()) then
				ctx.agent:cancel({ turn_id = run.turn_id, clear_queue = false, reason = "disposed" })
			end
		end
	end)
	return M
end
