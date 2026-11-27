-- Explicit review; only a selected approval can transition to implementation.
-- usage_of(): the optional usage service or nil (a follower-backed getter natively; a raw ctx
-- field otherwise). Without usage the context-usage label is omitted.
return function(ctx, state, usage_of)
	usage_of = usage_of or function()
		return rawget(ctx, "usage")
	end
	local disposed, steer_revision = false, 0
	local reviewed, reviewed_generation, reviewed_turn = {}, nil, nil
	local turn_cancel, run_cancel = nil, nil
	local function cancel_turn_handoff()
		if turn_cancel and type(turn_cancel.cancel) == "function" then
			turn_cancel:cancel()
		end
		turn_cancel = nil
		run_cancel = nil
	end
	ctx:on("queue/changed", function(ev)
		if type(ev) ~= "table" then
			return
		end
		if ev.action == "steer" then
			steer_revision = steer_revision + 1
			return
		end
		for _, item in ipairs(type(ev.items) == "table" and ev.items or {}) do
			if type(item) == "table" and item.lane == "steer" then
				steer_revision = steer_revision + 1
				return
			end
		end
	end)
	ctx:on("turn/started", function()
		turn_cancel = nil
		run_cancel = nil
	end)
	ctx:on("request/prepare", function(ev)
		run_cancel = type(ev) == "table" and ev.cancel or nil
		if run_cancel and type(run_cancel.child) == "function" then
			turn_cancel = run_cancel:child()
		end
	end)
	ctx:on("turn/completed", function(res)
		if
			turn_cancel
			and type(turn_cancel.cancel) == "function"
			and type(res) == "table"
			and (
				res.status == "cancelled"
				or res.termination_reason == "interrupted"
				or res.error ~= nil
				or res.cancellation_cause ~= nil
			)
		then
			turn_cancel:cancel()
		end
	end)
	ctx:on("agent/settled", function(ev)
		if not (ev and ev.busy) then
			turn_cancel = nil
			run_cancel = nil
		end
	end)
	ctx:on("session/changed", cancel_turn_handoff)
	ctx:effect(function()
		return function()
			disposed = true
			cancel_turn_handoff()
		end
	end)
	local function emit_plan_card(plan, call_id)
		if ctx.ui and require("mare_lib").callable(ctx.ui.card) then
			local ok, err = ctx.ui:card({
				title = "Proposed Plan",
				markdown = plan,
				kind = "proposed_plan",
				persist = true,
				id = call_id,
			})
			if not ok then
				return nil, err or "Failed to persist proposed plan card"
			end
		end
		return true
	end
	local function clear_context_usage_label()
		local usage = usage_of()
		if not usage or not require("mare_lib").callable(usage.context_tokens) then
			return nil
		end
		local ok, tokens = pcall(usage.context_tokens, usage)
		if not ok or type(tokens) ~= "number" or tokens <= 0 then
			return nil
		end
		local llm = ctx.llm
		local model = llm and require("mare_lib").callable(llm.current) and llm:current() or nil
		if model and type(model.context_window) == "number" and model.context_window > 0 then
			local pct = math.floor((tokens / model.context_window) * 100 + 0.5)
			return string.format("%d%% used", pct)
		end
		if tokens >= 1000 then
			return string.format("%.1fK tokens", tokens / 1000)
		end
		return string.format("%d tokens", tokens)
	end
	return function(plan, cancel, call_id)
		if not state.current().active then
			return {
				content = "exit_plan_mode is only available in plan mode",
				is_error = true,
				error_code = "plan_not_active",
			}
		end
		if type(plan) ~= "string" or not plan:match("^%s*#%s+%S") then
			return {
				content = "A complete Markdown plan starting with a # heading is required",
				is_error = true,
				error_code = "invalid_args",
			}
		end
		if not mare.ui.can_respond() then
			return {
				content = "No interactive user channel is available to review the plan. Plan mode remains active; ask the user to switch modes.",
				is_error = true,
				error_code = "interaction_unavailable",
			}
		end
		local info = ctx.session:info()
		local generation, revision = info.session_epoch, state.selection_revision()
		local agent_state = ctx.agent:get() or {}
		local turn = agent_state.turn_id
		if reviewed_generation ~= generation or reviewed_turn ~= turn then
			reviewed, reviewed_generation, reviewed_turn = {}, generation, turn
		end
		local steering = steer_revision
		if (agent_state.queued or 0) > 0 then
			return {
				content = "User input is queued; read it and present a fresh plan before review",
				is_error = true,
				error_code = "plan_review_stale",
			}
		end
		if call_id and reviewed[call_id] then
			return {
				content = "This plan completion was already reviewed; present a new plan",
				is_error = true,
				error_code = "plan_review_stale",
			}
		end
		if call_id then
			reviewed[call_id] = true
		end
		local is_readonly = info.readonly == true
		local is_child = mare and mare.mode == "child"
		local has_transition = require("mare_lib").callable(ctx.session.transition)
		local items = {
			{
				label = "Approve and implement",
				detail = is_readonly and "Unavailable in a read-only session" or "Leave plan mode from the next step",
				disabled = is_readonly or nil,
				preview = mare.ui.Markdown(plan),
			},
		}
		local actions = { "approve" }
		if has_transition then
			local usage_label = not is_readonly and not is_child and clear_context_usage_label() or nil
			local clean_detail = is_readonly and "Unavailable in a read-only session"
				or (is_child and "Unavailable in a child agent")
				or (
					usage_label
						and ("Start a fresh session with this plan (current context: " .. usage_label .. ")")
					or "Start a fresh session with this plan and leave plan mode"
				)
			items[#items + 1] = {
				label = "Implement plan cleanly (clear context)",
				detail = clean_detail,
				disabled = (is_readonly or is_child) or nil,
				preview = mare.ui.Markdown(plan),
			}
			actions[#actions + 1] = "clean"
		end
		items[#items + 1] = {
			label = "Keep planning",
			detail = "Send feedback and revise this plan",
			preview = mare.ui.Markdown(plan),
		}
		actions[#actions + 1] = "feedback"
		local index, tab_or_reason = mare.ui.select({
			title = "Plan review",
			body = plan,
			cancel = cancel,
			items = items,
		})
		local reason = (index == nil) and tab_or_reason or nil
		if cancel:is_cancelled() then
			return { content = "Plan review cancelled", cancelled = true, is_error = true }
		end
		if disposed then
			return {
				content = "Plan review was interrupted by service reload; present the plan again",
				is_error = true,
				error_code = "plan_review_interrupted",
			}
		end
		if
			steering ~= steer_revision
			or ((ctx.agent:get() or {}).queued or 0) > 0
			or ctx.session:info().session_epoch ~= generation
			or state.selection_revision() ~= revision
		then
			return {
				content = "The session or plan mode changed during review; present a fresh plan",
				is_error = true,
				error_code = "plan_review_stale",
			}
		end
		local user_abort = reason == "cancelled" or reason == "interrupted"
		if reason and not user_abort then
			return {
				content = "Plan review is unavailable; plan mode remains active",
				is_error = true,
				error_code = "interaction_unavailable",
			}
		end
		if index == nil then
			return { content = '{"approved":false}', details = { approved = false }, terminate = true }
		end
		local action = actions[index]
		if action == "clean" then
			local latest = ctx.session:info()
			if latest.readonly then
				return {
					content = "Cannot start a clean session in read-only mode",
					is_error = true,
					error_code = "readonly_session",
				}
			end
			if latest.session_epoch ~= generation then
				return {
					content = "The session changed during review; present a fresh plan",
					is_error = true,
					error_code = "plan_review_stale",
				}
			end
			if mare and mare.mode == "child" then
				return {
					content = "Cannot start a clean session in a child agent",
					is_error = true,
					error_code = "transition_failed",
				}
			end
			if not turn_cancel and mare and mare.task and type(mare.task.token) == "function" then
				turn_cancel = (run_cancel and type(run_cancel.child) == "function") and run_cancel:child()
					or mare.task.token()
			end
			local handoff_cancel = (turn_cancel and type(turn_cancel.child) == "function") and turn_cancel:child()
				or turn_cancel
			if handoff_cancel and handoff_cancel:is_cancelled() then
				return { content = "Plan review cancelled", cancelled = true, is_error = true }
			end
			local res, terr = ctx.session:transition({
				mode = "new",
				records = {
					{
						kind = "plan-mode/state",
						data = {
							version = 1,
							active = false,
							entered = false,
							revision = revision + 1,
							plan = plan,
							narrate = false,
						},
						scope = "session",
					},
				},
				initial = {
					kind = "input",
					content = "Implement the following approved plan, including its validation:\n\n" .. plan,
					source = "plan-mode",
				},
			}, {
				session_id = latest.session_id,
				session_epoch = latest.session_epoch,
				-- Turn-scoped token covers the whole turn until agent/settled (never per-call tctx.cancel).
				cancel = handoff_cancel,
				defer = true,
			})
			if not res then
				return {
					content = terr or "Failed to schedule clean-context transition",
					is_error = true,
					error_code = "transition_failed",
				}
			end
			if res.status == "stale" or res.status == "rejected" or res.status == "indeterminate" then
				return {
					content = res.error or ("Clean-context transition " .. tostring(res.status)),
					is_error = true,
					error_code = "transition_failed",
				}
			end
			local card_ok, card_err = emit_plan_card(plan, call_id)
			if not card_ok then
				if handoff_cancel and type(handoff_cancel.cancel) == "function" then
					handoff_cancel:cancel()
				end
				return {
					content = card_err or "Failed to persist proposed plan card",
					is_error = true,
					error_code = ctx.session:info().session_epoch ~= generation and "plan_review_stale"
						or "persist_failed",
				}
			end
			return {
				content = '{"approved":true,"clear_context":true}',
				details = {
					approved = true,
					clear_context = true,
					plan = plan,
					transition_id = res.transition_id,
				},
				terminate = true,
			}
		end
		if action ~= "approve" then
			local feedback, input_reason =
				mare.ui.input({ title = "Plan feedback", placeholder = "What should change?", cancel = cancel })
			if cancel:is_cancelled() then
				return { content = "Plan review cancelled", cancelled = true, is_error = true }
			end
			if disposed then
				return {
					content = "Plan review was interrupted by service reload; present the plan again",
					is_error = true,
					error_code = "plan_review_interrupted",
				}
			end
			local input_abort = input_reason == "cancelled" or input_reason == "interrupted"
			if
				(input_reason and not input_abort)
				or steering ~= steer_revision
				or ((ctx.agent:get() or {}).queued or 0) > 0
				or state.selection_revision() ~= revision
				or ctx.session:info().session_epoch ~= generation
			then
				return {
					content = "Plan feedback is unavailable or stale; keep planning",
					is_error = true,
					error_code = "interaction_unavailable",
				}
			end
			local trimmed = type(feedback) == "string" and feedback:match("^%s*(.-)%s*$") or ""
			return {
				content = trimmed == "" and "The user chose to keep planning; revise the plan and present it again."
					or ("The user chose to keep planning; their feedback: " .. trimmed),
				is_error = true,
				error_code = "plan_revision_requested",
			}
		end
		local latest = ctx.session:info()
		if latest.readonly then
			return {
				content = "Plan mode cannot change in a read-only session",
				is_error = true,
				error_code = "readonly_session",
			}
		end
		if latest.session_epoch ~= generation then
			return {
				content = "The session changed during review; present a fresh plan",
				is_error = true,
				error_code = "plan_review_stale",
			}
		end
		local card_ok, card_err = emit_plan_card(plan, call_id)
		if not card_ok then
			return {
				content = card_err or "Failed to persist proposed plan card",
				is_error = true,
				error_code = ctx.session:info().session_epoch ~= generation and "plan_review_stale" or "persist_failed",
			}
		end
		if ctx.session:info().session_epoch ~= generation then
			return {
				content = "The session changed during review; present a fresh plan",
				is_error = true,
				error_code = "plan_review_stale",
			}
		end
		local ok, err = state.select(false, false, plan)
		if not ok then
			return {
				content = err,
				is_error = true,
				error_code = ctx.session:info().readonly and "readonly_session" or "persist_failed",
			}
		end
		ctx.agent:notify(
			"The user approved the plan. Implement it from the next step, including its validation.",
			{ wake = false }
		)
		return { content = '{"approved":true}', details = { approved = true, plan = plan } }
	end
end
