local support = assert(load(mare.fs.read("tests/specs/support.lua"), "@tests/specs/support.lua"))()

local describe = mare.test.describe
local it = mare.test.it
local before_each = mare.test.before_each
local after_each = mare.test.after_each
local expect = mare.test.expect

local plugin = support.load_plugin(
	"plan-mode",
	{ "plan_mode.coordinator", "plan_mode.effort", "plan_mode.gate", "plan_mode.review", "plan_mode.state" }
)

local function spawn(_, fn, ...)
	return mare.task.spawn(fn, ...)
end

describe("plan-mode", function()
	local orig_ui
	local orig_sandbox

	before_each(function()
		orig_ui = {
			notify = mare.ui.notify,
			can_respond = mare.ui.can_respond,
			select = mare.ui.select,
			input = mare.ui.input,
		}
		orig_sandbox = mare.proc.sandbox
	end)

	after_each(function()
		mare.ui.notify = orig_ui.notify
		mare.ui.can_respond = orig_ui.can_respond
		mare.ui.select = orig_ui.select
		mare.ui.input = orig_ui.input
		mare.proc.sandbox = orig_sandbox
	end)

	it("satisfies state, review, effort, and clean-context handoff contracts", function()
		local notices = {}
		mare.ui.notify = function(v)
			notices[#notices + 1] = v
		end
		mare.ui.can_respond = function()
			return false
		end
		local events, changes, records, staged, tools = {}, {}, {}, {}, {}
		local command, service, section, participant
		local preview, preview_id
		local busy, readonly, ephemeral, fail, switch_during_write = false, false, false, false, false
		local on_record = nil
		local generation, invalidations, writes = "one", 0, 0
		local ctx = {
			session = {
				info = function()
					return { session_epoch = generation, readonly = readonly, ephemeral = ephemeral }
				end,
				list_records = function()
					return { data = records }
				end,
				add_record = function(_, _, value)
					writes = writes + 1
					if on_record then
						local hook = on_record
						on_record = nil
						hook(value)
					end
					if fail then
						error("disk failure", 0)
					end
					if switch_during_write then
						generation = "other"
					end
					records[#records + 1] = value
					return { durable = true }
				end,
			},
			context = {
				invalidate = function()
					invalidations = invalidations + 1
				end,
				section = function(_, v)
					section = v
				end,
			},
			ui = { invalidate = function() end, widget = function() end },
			commands = {
				register = function(_, _, v)
					command = v
				end,
			},
			tools = {
				register = function(_, name, v)
					tools[name] = v
				end,
			},
			agent = {
				get = function()
					return { busy = busy, queued = 0 }
				end,
				step_preview = function(_, _, id)
					if id and id ~= preview_id then
						return nil, "inactive"
					end
					return preview
				end,
				step_state = function(_, name)
					return staged[name]
				end,
				step_participant = function(_, name, fn, opts)
					assert(opts.failure_policy == "defer")
					participant = fn
				end,
				register_activity = function() end,
				notify = function() end,
				steer = function() end,
				prompt = function() end,
			},
			on = function(_, name, fn)
				if not events[name] then
					events[name] = setmetatable({}, {
						__call = function(list, ...)
							for _, f in ipairs(list) do
								f(...)
							end
						end,
					})
				end
				table.insert(events[name], fn)
			end,
			emit = function(_, name, ev)
				assert(name == "plan-mode/changed")
				changes[#changes + 1] = ev
			end,
			effect = function(_, setup)
				setup()
			end,
			spawn = spawn,
			provide = function(_, name, v)
				assert(name == "plan_mode")
				service = v
			end,
		}
		-- Without session.transition, omit the clean-context option but still emit the approval card.
		local cards = {}
		ctx.ui.card = function(_, spec)
			cards[#cards + 1] = spec
			return true
		end
		plugin.apply(ctx, support.default_config(plugin))
		assert(service.state and not service.active() and not section.text(nil, {}))
		assert(command.availability == nil, "commands must support runtime pending selections")
		command.run("on")
		assert(service.active() and section.text(nil, {}) and writes == 1)
		assert(changes[#changes].active and changes[#changes].reason == "committed")
		command.run("on")
		assert(writes == 1 and notices[#notices]:find("already active", 1, true), "idempotent on must not write")
		readonly = true
		assert(command.run("off").status == "rejected")
		assert(service.active() and writes == 1)
		readonly = false
		-- A failed save leaves the outcome unknown: plan mode stays on and retries at the next step.
		fail = true
		local rejected = command.run("off")
		assert(rejected.reason:find("disk failure", 1, true) and rejected.reason:find("stays on", 1, true))
		assert(service.active() and service.state().unconfirmed and service.state().pending == false)
		fail = false
		busy = true
		events["step/started"]({})
		assert(writes == 3 and records[#records].revision == 3, "retry must use a newer revision")
		assert(not service.active() and service.state().pending == nil and not service.state().unconfirmed)
		local token = {
			is_cancelled = function()
				return false
			end,
		}
		assert(tools.exit_plan_mode.execute({ plan = "# plan" }, { cancel = token }).is_error)
		busy = false
		command.run("on")
		assert(tools.exit_plan_mode.execute({ plan = "bad" }, { cancel = token }).is_error)
		assert(
			tools.exit_plan_mode
				.execute({ plan = "# valid" }, { cancel = token }).content
				:find("No interactive", 1, true)
		)
		assert(tools.exit_plan_mode.admit({}), "entered session retains exit declaration")
		-- Restoring another session ignores bad records, invalidates cached prompt and emits even if active is unchanged.
		records = {
			{ version = 1, active = true },
			{ version = 8, active = false },
			{ version = 1, active = "bad" },
			{ version = 1, active = false, revision = -1 },
			{ version = 1, active = false, plan = 123 },
		}
		staged = {}
		generation = "two"
		events["session/changed"]()
		assert(service.active() and changes[#changes].generation == "two" and changes[#changes].reason == "restore")
		records = {}
		staged = {}
		generation = "three"
		events["session/changed"]()
		assert(not service.active() and not section.text(nil, {}))
		assert(not tools.exit_plan_mode.admit({}))
		assert(invalidations >= 4)
		ephemeral = true
		command.run("")
		assert(service.active() and notices[#notices]:find("This run only", 1, true))
		command.run("off")
		assert(not service.active())
		ephemeral = false
		busy = false
		command.run("on")
		local selected = 0
		mare.ui.can_respond = function()
			return true
		end
		mare.ui.select = function()
			selected = selected + 1
			events["queue/changed"]({ action = "steer", items = { { lane = "steer", text = "steer" } } })
			return 1
		end
		local stale = tools.exit_plan_mode.execute(
			{ plan = "# old" },
			{ cancel = token, tool_call_id = "old-completion" }
		)
		assert(stale.is_error and service.active(), "steer allowed approval of stale plan")
		local duplicate = tools.exit_plan_mode.execute(
			{ plan = "# old" },
			{ cancel = token, tool_call_id = "old-completion" }
		)
		assert(duplicate.is_error and selected == 1, "duplicate completion opened review again")
		mare.ui.select = function()
			selected = selected + 1
			return nil
		end
		local fresh = tools.exit_plan_mode.execute(
			{ plan = "# new" },
			{ cancel = token, tool_call_id = "new-completion" }
		)
		assert(fresh.terminate and selected == 2, "fresh plan after steer was not reviewed")
		busy = true
		mare.ui.select = function()
			command.run("off")
			return 1
		end
		local changed = tools.exit_plan_mode.execute(
			{ plan = "# mode change" },
			{ cancel = token, tool_call_id = "changed-mode" }
		)
		assert(changed.is_error and service.state().pending == false, "pending mode edit was overwritten by approval")
		-- Review checks committed batch state, not pending intent, in both directions.
		-- Direction 1: committed active=true + queued off -> current batch review is still allowed.
		mare.ui.select = function()
			selected = selected + 1
			return 1
		end
		local queued_off_review = tools.exit_plan_mode.execute(
			{ plan = "# queued off batch" },
			{ cancel = token, tool_call_id = "queued-off-batch" }
		)
		assert(not queued_off_review.is_error and queued_off_review.details.approved and selected == 3)
		assert(service.active() and service.state().pending == false)
		-- Direction 2: committed active=false + queued on -> current batch review is rejected.
		events["step/started"]({})
		assert(not service.active() and service.state().pending == nil)
		busy = true
		command.run("on")
		assert(not service.active() and service.state().pending == true)
		local queued_on_review = tools.exit_plan_mode.execute(
			{ plan = "# queued on batch" },
			{ cancel = token, tool_call_id = "queued-on-batch" }
		)
		assert(queued_on_review.is_error and queued_on_review.content:find("only available in plan mode", 1, true))
		assert(selected == 3, "queued on must not open review for inactive batch")
		busy = false
		local ok = pcall(plugin.apply, ctx, { section = "" })
		assert(not ok)

		-- Verify review and durable cards without session.transition.
		events["step/started"]({})
		assert(service.active())
		local seen_items
		mare.ui.select = function(spec)
			seen_items = spec.items
			return 1
		end
		local before_cards = #cards
		local compat_approve = tools.exit_plan_mode.execute(
			{ plan = "# Compat Plan\n\nStep 1" },
			{ cancel = token, tool_call_id = "compat-1" }
		)
		assert(not compat_approve.is_error and compat_approve.details.approved)
		assert(
			#seen_items == 2
				and seen_items[1].label == "Approve and implement"
				and seen_items[2].label == "Keep planning"
		)
		assert(
			#cards == before_cards + 1
				and cards[#cards].kind == "proposed_plan"
				and cards[#cards].persist == true
				and cards[#cards].id == "compat-1"
		)
		assert(not service.active())

		-- Exercise review, effort and durable cards with session.transition and a scoped llm.
		local function make_full_harness(cfg_overrides, persisted)
			persisted = persisted or { global = {}, scoped = {} }
			local l_events, l_changes, l_records, l_staged, l_tools, l_notices, l_cards, l_transitions, l_disposes =
				{}, {}, {}, {}, {}, {}, {}, {}, {}
			local l_notes, l_submits, l_command, l_service, l_participant = {}, {}, nil, nil, nil
			local st = {
				busy = false,
				readonly = false,
				generation = "g1",
				context_tokens = 25000,
				model = { ref = "faux/echo", context_window = 100000, options = { "low", "medium", "high" } },
				transition_result = nil,
				card_hook = nil,
			}
			local global_efforts, scoped_efforts, active_scope = {}, {}, nil
			local function emit_event(name, ev)
				for _, fn in ipairs(l_events[name] or {}) do
					fn(ev)
				end
			end
			local mock_llm = {
				current = function()
					return st.model
				end,
				effort_options = function(_, model)
					return model and model.options or nil
				end,
				clamp_effort = function(_, model, wanted)
					if not model or not model.options then
						return nil
					end
					if wanted == nil then
						if active_scope then
							local s = (scoped_efforts[active_scope] and scoped_efforts[active_scope][model.ref])
								or (persisted.scoped[active_scope] and persisted.scoped[active_scope][model.ref])
							if s then
								return s
							end
						end
						return global_efforts[model.ref] or persisted.global[model.ref] or "medium"
					end
					for _, v in ipairs(model.options) do
						if v == wanted then
							return v
						end
					end
					return wanted == "xhigh" and "high" or "medium"
				end,
				effort = function(self)
					return self:clamp_effort(st.model)
				end,
				set_effort = function(_, level, opts)
					if not st.model.options then
						error("no effort parameter")
					end
					if not ({ low = true, medium = true, high = true, xhigh = true })[level] then
						error("unknown effort: " .. tostring(level))
					end
					local save = not (opts and opts.save == false)
					if opts and opts.scope_name then
						scoped_efforts[opts.scope_name] = scoped_efforts[opts.scope_name] or {}
						scoped_efforts[opts.scope_name][st.model.ref] = level
						if save then
							persisted.scoped[opts.scope_name] = persisted.scoped[opts.scope_name] or {}
							persisted.scoped[opts.scope_name][st.model.ref] = level
						end
					end
					if not (opts and opts.scope_name) or (opts and opts.also_global) then
						global_efforts[st.model.ref] = level
						if save then
							persisted.global[st.model.ref] = level
						end
					end
				end,
				scoped_effort = function(self, scope, model)
					local m = model or st.model
					local raw = (scoped_efforts[scope] and scoped_efforts[scope][m.ref])
						or (persisted.scoped[scope] and persisted.scoped[scope][m.ref])
					return raw and self:clamp_effort(m, raw) or nil
				end,
				clear_scope = function(_, scope, model, opts)
					local m = model or st.model
					if m then
						if scoped_efforts[scope] then
							scoped_efforts[scope][m.ref] = nil
						end
						if not (opts and opts.save == false) and persisted.scoped[scope] then
							persisted.scoped[scope][m.ref] = nil
						end
					end
					if active_scope == scope then
						active_scope = nil
					end
				end,
				set_active_scope = function(_, scope)
					active_scope = scope
				end,
				active_scope = function()
					return active_scope
				end,
			}
			local l_ctx = {
				llm = mock_llm,
				usage = {
					context_tokens = function()
						return st.context_tokens
					end,
				},
				session = {
					info = function()
						return {
							session_id = "sess-1",
							session_epoch = st.generation,
							readonly = st.readonly,
							ephemeral = false,
						}
					end,
					list_records = function()
						return { data = l_records }
					end,
					add_record = function(_, _, value)
						l_records[#l_records + 1] = value
						return { durable = true }
					end,
					transition = function(_, spec, opts)
						l_transitions[#l_transitions + 1] = { spec = spec, opts = opts }
						return st.transition_result
							or {
								status = "deferred",
								transition_id = "tr-" .. tostring(#l_transitions),
								mode = spec.mode,
							}
					end,
				},
				context = { invalidate = function() end, section = function() end },
				ui = {
					invalidate = function() end,
					widget = function() end,
					card = function(_, spec)
						if st.card_hook then
							local ok, err = st.card_hook(spec)
							if not ok then
								return nil, err
							end
						end
						l_cards[#l_cards + 1] = spec
						return true
					end,
				},
				commands = {
					register = function(_, _, v)
						l_command = v
					end,
				},
				tools = {
					register = function(_, name, v)
						l_tools[name] = v
					end,
				},
				agent = {
					get = function()
						return { busy = st.busy, queued = 0, turn_id = 1 }
					end,
					register_activity = function() end,
					notify = function(_, text)
						l_notes[#l_notes + 1] = text
					end,
					steer = function(_, text, opts)
						l_submits[#l_submits + 1] = {
							delivery = "steer",
							text = text,
							content = opts and opts.content or nil,
							opts = opts,
						}
					end,
					prompt = function(_, text, opts)
						l_submits[#l_submits + 1] = {
							delivery = (opts and opts.when_busy == "queue") and "follow_up" or "prompt",
							text = text,
							content = opts and opts.content or nil,
							opts = opts,
						}
						return {}
					end,
				},
				on = function(_, name, fn)
					l_events[name] = l_events[name] or {}
					table.insert(l_events[name], fn)
				end,
				emit = function(_, name, ev)
					assert(name == "plan-mode/changed")
					l_changes[#l_changes + 1] = ev
				end,
				effect = function(_, setup)
					local fn = setup()
					l_disposes[#l_disposes + 1] = fn
				end,
				spawn = spawn,
				provide = function(_, _, v)
					l_service = v
				end,
			}
			ui.notify = function(msg)
				l_notices[#l_notices + 1] = msg
			end
			local cfg = support.default_config(plugin)
			cfg.plan_effort = "high"
			cfg.effort_scope = "plan"
			for k, v in pairs(cfg_overrides or {}) do
				cfg[k] = v
			end
			plugin.apply(l_ctx, cfg)
			return {
				st = st,
				events = l_events,
				emit_event = emit_event,
				records = l_records,
				tools = l_tools,
				notices = l_notices,
				notes = l_notes,
				submits = l_submits,
				cards = l_cards,
				transitions = l_transitions,
				disposes = l_disposes,
				command = l_command,
				service = l_service,
				llm = mock_llm,
			}
		end

		local function exit_plan(harness, p, cid, tok)
			return harness.tools.exit_plan_mode.execute(
				{ plan = p },
				{ cancel = tok or mare.task.token(), tool_call_id = cid }
			)
		end

		-- Bad effort config rejected
		local bad_base = support.default_config(plugin)
		assert(not pcall(plugin.apply, ctx, { section = bad_base.section, plan_effort = "" }))
		assert(
			plugin.config_schema.effort_scope.choices[1] == "plan"
				and plugin.config_schema.effort_scope.choices[2] == "global"
		)

		-- Test plan-scoped effort activation, restoration, commands, models without effort, and disposal.
		local h = make_full_harness()
		assert(h.llm:effort() == "medium" and h.llm:active_scope() == nil)
		h.command.run("on")
		assert(h.service.active() and h.llm:active_scope() == "plan" and h.llm:effort() == "high")
		local n_before = #h.notices
		h.command.run("status")
		assert(h.notices[#h.notices]:find("effort: high", 1, true) and #h.notices == n_before + 1)
		assert(h.command.run("effort bogus").status == "rejected")
		assert(h.command.run("effort low") == nil and h.llm:effort() == "low")
		h.command.run("off")
		assert(not h.service.active() and h.llm:active_scope() == nil and h.llm:effort() == "medium")
		h.command.run("on")
		assert(h.llm:active_scope() == "plan" and h.llm:effort() == "low")
		-- No-effort model safety
		h.st.model = { ref = "faux/echo2", options = nil }
		h.emit_event("model/changed")
		assert(h.llm:effort() == nil and h.command.run("effort high").status == "rejected")
		h.st.model = { ref = "faux/echo", context_window = 100000, options = { "low", "medium", "high" } }
		h.emit_event("model/changed")
		assert(h.llm:effort() == "low")
		-- Dispose restores global scope
		for _, fn in ipairs(h.disposes) do
			fn()
		end
		assert(h.llm:active_scope() == nil and h.llm:effort() == "medium")

		-- Explicit plan and global effort persist across restart and stay isolated per model; --session stays temporary.
		local store = { global = {}, scoped = {} }
		local p8a = make_full_harness({ plan_effort = false }, store)
		p8a.command.run("on")
		assert(p8a.command.run("effort low") == nil and store.scoped.plan["faux/echo"] == "low")
		assert(p8a.command.run("effort high --session") == nil and p8a.llm:effort() == "high")
		assert(store.scoped.plan["faux/echo"] == "low")
		p8a.st.model = { ref = "faux/alt", context_window = 100000, options = { "low", "medium", "high" } }
		p8a.emit_event("model/changed")
		assert(p8a.llm:effort() == "medium" and p8a.command.run("effort high global") == nil)
		assert(store.scoped.plan["faux/alt"] == "high" and store.global["faux/alt"] == "high")
		assert(p8a.command.run("effort low global --session") == nil and p8a.llm:effort() == "low")
		assert(store.global["faux/alt"] == "high")
		-- Simulated restart with same persisted store
		local p8b = make_full_harness({ plan_effort = false }, store)
		p8b.command.run("on")
		assert(p8b.llm:effort() == "low")
		p8b.command.run("off")
		assert(p8b.llm:effort() == "medium")
		p8b.st.model = { ref = "faux/alt", context_window = 100000, options = { "low", "medium", "high" } }
		p8b.emit_event("model/changed")
		assert(p8b.llm:effort() == "high")
		p8b.command.run("on")
		assert(p8b.llm:effort() == "high")
		assert(p8b.command.run("effort clear --session") == nil and store.scoped.plan["faux/alt"] == "high")
		assert(p8b.command.run("effort clear") == nil and store.scoped.plan["faux/alt"] == nil)

		-- Global effort_scope preserves effort after leaving plan mode.
		local hg = make_full_harness({ plan_effort = "high", effort_scope = "global" })
		hg.command.run("on")
		assert(hg.llm:active_scope() == nil and hg.llm:effort() == "high")
		hg.command.run("off")
		assert(hg.llm:active_scope() == nil and hg.llm:effort() == "high")
		hg.command.run("effort clear")
		assert(hg.llm:scoped_effort("plan") == nil)

		-- Clean-context handoff: turn-scoped cancellation, read-only mode, card failure, session switch and recovery.
		local g1 = make_full_harness()
		g1.command.run("on")
		local full_plan = "# Clean Context Plan\n\n1. Inspect architecture\n2. Implement safely\n3. Validate everything"
		local g1_items, ro_items
		g1.st.readonly = true
		mare.ui.select = function(spec)
			ro_items = spec.items
			return 1
		end
		local ro_res = exit_plan(g1, full_plan, "ro-1")
		assert(ro_res.is_error and ro_res.error_code == "readonly_session" and #ro_items == 3)
		assert(ro_items[1].disabled and ro_items[2].disabled and not ro_items[3].disabled and #g1.cards == 0)
		g1.st.readonly = false
		g1.st.transition_result = { status = "stale", error = "session changed" }
		mare.ui.select = function(spec)
			g1_items = spec.items
			return 2
		end
		local tr_fail = exit_plan(g1, full_plan, "c-fail")
		assert(tr_fail.is_error and tr_fail.error_code == "transition_failed" and #g1.cards == 0)
		g1.st.transition_result = nil

		-- Turn-scoped cancellation survives per-call cancel after execute(), but not a turn interrupt before agent/settled.
		local run_tok, call_tok = mare.task.token(), mare.task.token()
		g1.emit_event("turn/started", { turn_id = "t1" })
		g1.emit_event("request/prepare", { cancel = run_tok })
		local tr_ok = exit_plan(g1, full_plan, "clean-ok", call_tok)
		assert(#g1_items == 3 and g1_items[2].label == "Implement plan cleanly (clear context)")
		assert(
			not tr_ok.is_error and tr_ok.terminate and tr_ok.details.clear_context and tr_ok.details.plan == full_plan
		)
		assert(#g1.cards == 1 and g1.cards[1].id == "clean-ok" and g1.cards[1].markdown == full_plan)
		local tr = g1.transitions[2]
		assert(
			tr.spec.mode == "new" and tr.opts.defer == true and tr.opts.session_id == "sess-1" and tr.opts.cancel ~= nil
		)
		assert(
			tr.spec.records[1].kind == "plan-mode/state"
				and tr.spec.records[1].data.active == false
				and tr.spec.records[1].data.plan == full_plan
		)
		assert(tr.spec.initial.kind == "input" and tr.spec.initial.content:find(full_plan, 1, true))
		call_tok:cancel()
		assert(not tr.opts.cancel:is_cancelled(), "per-call cancel must not cancel deferred clean-context handoff")
		g1.emit_event("turn/completed", { status = "completed", termination_reason = "completed" })
		assert(not tr.opts.cancel:is_cancelled())
		g1.emit_event("agent/settled", { busy = false })
		g1.records[1] = tr.spec.records[1].data
		g1.emit_event("session/transition-completed")
		assert(not g1.service.active() and g1.service.state().plan == full_plan and g1.llm:active_scope() == nil)

		-- An abort or interrupted turn/completed before agent/settled cancels the approved handoff token.
		g1.command.run("on")
		g1.emit_event("turn/started", { turn_id = "t2" })
		g1.emit_event("request/prepare", { cancel = mare.task.token() })
		local tr_aborted = exit_plan(g1, full_plan, "c-ab")
		assert(not tr_aborted.is_error and tr_aborted.terminate and not g1.transitions[3].opts.cancel:is_cancelled())
		g1.emit_event(
			"turn/completed",
			{ status = "cancelled", termination_reason = "interrupted", cancellation_cause = "user" }
		)
		assert(
			g1.transitions[3].opts.cancel:is_cancelled(),
			"turn abort before agent/settled must cancel deferred handoff"
		)
		g1.emit_event("agent/settled", { busy = false })

		-- A failed clean-context card cancels the handoff and allows recovery; approval failure or a switch preserves active state.
		g1.st.card_hook = function()
			return nil, "card write failed"
		end
		g1.emit_event("turn/started", { turn_id = "t3" })
		local c_card_fail = exit_plan(g1, full_plan, "c-cf")
		assert(c_card_fail.is_error and c_card_fail.error_code == "persist_failed" and not c_card_fail.terminate)
		assert(g1.transitions[4].opts.cancel:is_cancelled() and g1.service.active())
		mare.ui.select = function()
			return 1
		end
		local a_card_fail = exit_plan(g1, full_plan, "a-cf")
		assert(a_card_fail.is_error and a_card_fail.error_code == "persist_failed" and g1.service.active())
		g1.st.card_hook = function()
			g1.st.generation = "g-switched"
			return nil, "session switched"
		end
		local a_switched = exit_plan(g1, full_plan, "a-sw")
		assert(a_switched.is_error and a_switched.error_code == "plan_review_stale" and g1.service.active())
		g1.st.generation = "g1"
		g1.emit_event("session/changed")
		g1.command.run("on")
		g1.st.card_hook = nil
		local recovered = exit_plan(g1, full_plan, "a-rec")
		assert(not recovered.is_error and recovered.details.approved and not g1.service.active())

		-- Parity coverage: distinct notices, completion, attachments, idle narration, error_codes, usage label, blank feedback
		local ph = make_full_harness({ plan_effort = false })
		local comp = ph.command.complete("o")
		assert(#comp == 2 and comp[1].label == "off" and comp[2].label == "on")
		ph.command.run("off")
		assert(ph.notices[#ph.notices] == "Plan mode is already inactive.")
		for _, bad in ipairs({ "status", "effort", "off" }) do
			assert(ph.command.run(bad, { content = { { type = "image", data = "x" } } }).status == "rejected")
		end
		for _, bad in ipairs({
			"effort status extra",
			"effort scope plan extra",
			"effort clear extra",
			"effort low plan extra",
			"effort low --session --session",
		}) do
			assert(ph.command.run(bad).status == "rejected")
		end
		ph.command.run("on", { content = { { type = "image", data = "abc" } } })
		assert(ph.service.active() and #ph.submits == 1 and ph.submits[1].content[1].type == "image" and #ph.notes == 0)
		ph.emit_event("request/build", {})
		ph.command.run("off")
		assert(#ph.notes == 1 and ph.notes[1]:find("switched plan mode off", 1, true))
		ph.emit_event("request/build", {})
		ph.command.run("on")
		assert(#ph.notes == 2 and ph.notes[2]:find("switched plan mode on", 1, true))
		ph.command.run("on")
		assert(ph.notices[#ph.notices]:find("already active", 1, true))
		ph.st.busy = true
		ph.command.run("off")
		assert(ph.notices[#ph.notices] == "Leaving plan mode (applies from the next step).")
		ph.command.run("on")
		assert(ph.notices[#ph.notices] == "Plan mode exit cancelled.")
		ph.st.busy = false
		ph.command.run("off")
		mare.ui.can_respond = function()
			return true
		end
		assert(exit_plan(ph, "# No").error_code == "plan_not_active")
		ph.command.run("on")
		assert(exit_plan(ph, "no heading").error_code == "invalid_args")
		mare.ui.can_respond = function()
			return false
		end
		assert(exit_plan(ph, "# Valid").error_code == "interaction_unavailable")
		mare.ui.can_respond = function()
			return true
		end
		local seen_clean_detail
		mare.ui.select = function(spec)
			seen_clean_detail = spec.items[2].detail
			return 3
		end
		mare.ui.input = function()
			return "   "
		end
		local blank_fb = exit_plan(ph, "# Valid", "fb-blank")
		assert(seen_clean_detail:find("25% used", 1, true) and blank_fb.error_code == "plan_revision_requested")
		assert(blank_fb.content == "The user chose to keep planning; revise the plan and present it again.")
		mare.ui.input = function()
			return "  Check rollback  "
		end
		local trim_fb = exit_plan(ph, "# Valid", "fb-trim")
		assert(
			trim_fb.error_code == "plan_revision_requested"
				and trim_fb.content == "The user chose to keep planning; their feedback: Check rollback"
		)
		for _, reason in ipairs({ "cancelled", "interrupted" }) do
			mare.ui.select = function()
				return nil, reason
			end
			local dismissed = exit_plan(ph, "# Valid", "sel-" .. reason)
			assert(
				not dismissed.is_error
					and dismissed.details
					and dismissed.details.approved == false
					and dismissed.terminate,
				"plan review select " .. reason .. " should decline without interaction_unavailable"
			)
			mare.ui.select = function()
				return 3
			end
			mare.ui.input = function()
				return nil, reason
			end
			local fb_cancel = exit_plan(ph, "# Valid", "fb-" .. reason)
			assert(
				fb_cancel.error_code == "plan_revision_requested",
				"plan feedback input " .. reason .. " should request revision, got " .. tostring(fb_cancel.error_code)
			)
		end
		mare.ui.select = function()
			return nil, "unavailable"
		end
		local unavail_res = exit_plan(ph, "# Valid", "sel-unavail")
		assert(unavail_res.is_error and unavail_res.error_code == "interaction_unavailable")
		-- unloading the plugin while the review dialog is open interrupts the review: the approve
		-- answer that comes back afterwards must not exit plan mode
		mare.ui.select = function()
			for _, fn in ipairs(ph.disposes) do
				fn()
			end
			return 1
		end
		local unloaded = exit_plan(ph, "# Valid", "unload-during-review")
		assert(
			unloaded.is_error and unloaded.error_code == "plan_review_interrupted",
			"unload during review should interrupt it, got " .. tostring(unloaded.error_code)
		)
	end)

	it("enforces plan-mode tool/before precedence and read-only sandbox narrowing", function()
		-- The hard gate defaults on and follows the tool/before policy voting order.
		assert(plugin.config_schema.enforce.default == true, "plan-mode enforce must default to true")
		local gate_events = {}
		local gate_widget
		local gate_notices = {}
		local gate_sandbox_current = nil
		mare.proc = mare.proc or {}
		mare.proc.sandbox = {
			current = function()
				return gate_sandbox_current
			end,
		}
		mare.ui = mare.ui or {}
		mare.ui.notify = function(msg)
			gate_notices[#gate_notices + 1] = msg
		end
		local gate_ctx = {
			session = {
				info = function()
					return { session_epoch = "g-gate", readonly = false, ephemeral = false }
				end,
				list_records = function()
					return { data = {} }
				end,
				add_record = function()
					return { durable = true }
				end,
			},
			context = { invalidate = function() end, section = function() end },
			ui = {
				invalidate = function() end,
				widget = function(_, _, spec)
					gate_widget = spec
				end,
			},
			commands = {
				register = function(_, _, v)
					gate_events._cmd = v
				end,
			},
			tools = { register = function() end },
			agent = {
				get = function()
					return { busy = false, queued = 0 }
				end,
				step_preview = function()
					return nil
				end,
				step_state = function()
					return nil
				end,
				step_participant = function() end,
				register_activity = function() end,
				notify = function() end,
				steer = function() end,
				prompt = function() end,
			},
			on = function(_, name, fn)
				gate_events[name] = gate_events[name] or {}
				table.insert(gate_events[name], fn)
			end,
			emit = function() end,
			effect = function(_, setup)
				setup()
			end,
			spawn = spawn,
			provide = function() end,
		}
		local function vote_gate(call, info)
			for _, fn in ipairs(gate_events["tool/before"] or {}) do
				local v = fn(call, info)
				if v ~= nil then
					return v
				end
			end
			return nil
		end
		local gate_cfg = {
			section = plugin.config_schema.section.default,
			enforce = true,
			allow_tools = { "custom_allowed" },
		}
		plugin.apply(gate_ctx, gate_cfg)
		assert(#(gate_events["tool/before"] or {}) >= 1, "plan-mode must register tool/before listener")
		-- Inactive: no vote on anything
		assert(vote_gate({ name = "write", arguments = {} }, { side_effect = "write" }) == nil)
		-- Activate plan mode
		gate_events._cmd.run("on")
		assert(
			gate_notices[#gate_notices]:find("local writes blocked", 1, true),
			"enter notice must state local writes blocked"
		)
		local banner_lines = gate_widget.render(80, 1)
		assert(
			mare.json.encode(banner_lines):find("PLAN — local writes blocked", 1, true),
			"widget banner must say PLAN — local writes blocked"
		)
		-- Rule 1: exit_plan_mode & allow_tools (live update)
		assert(vote_gate({ name = "exit_plan_mode", arguments = {} }, { side_effect = "write" }) == nil)
		assert(vote_gate({ name = "custom_allowed", arguments = {} }, { side_effect = "write" }) == nil)
		gate_cfg.allow_tools = {}
		assert(vote_gate({ name = "custom_allowed", arguments = {} }, { side_effect = "write" }).decision == "deny")
		gate_cfg.allow_tools = { "custom_allowed" }
		-- Rule 2: escalation requests denied
		assert(
			vote_gate(
				{ name = "bash", arguments = { command = "ls", sandbox_permissions = "write:/tmp" } },
				{ side_effect = "external" }
			).decision == "deny"
		)
		assert(
			vote_gate(
				{ name = "request_permissions", arguments = { additional_permissions = { write = { "/tmp" } } } },
				{ side_effect = "external", permission_request = true }
			).decision == "deny"
		)
		-- Rule 3: subagent & subagent_steer denied
		assert(vote_gate({ name = "subagent", arguments = {} }, { side_effect = "external" }).decision == "deny")
		assert(vote_gate({ name = "subagent_steer", arguments = {} }, { side_effect = "external" }).decision == "deny")
		-- Rule 4: persistent terminal denied with exact reason
		local term_vote = vote_gate({ name = "terminal_open", arguments = {} }, { side_effect = "external" })
		assert(term_vote.decision == "deny" and term_vote.reason == "terminal is unavailable in plan mode")
		assert(vote_gate({ name = "terminal_send", arguments = {} }, { side_effect = "external" }).decision == "deny")
		-- Rule 5: unconfined asks without amendment (before side_effect check)
		local mcp_vote = vote_gate({ name = "mcp_read", arguments = {} }, { side_effect = "read", unconfined = true })
		assert(mcp_vote.decision == "ask" and mcp_vote.amendment == nil)
		-- Rule 6: local write denied
		assert(vote_gate({ name = "apply_patch", arguments = {} }, { side_effect = "write" }).decision == "deny")
		-- Rule 7: bash/powershell narrows only write dimension, leaves network open for intersection, preserves accept_partial/readable/deny_read
		gate_sandbox_current = nil
		local full_vote = vote_gate({ name = "bash", arguments = { command = "ls" } }, { side_effect = "external" })
		assert(
			full_vote.decision == "allow"
				and full_vote.sandbox.level == "read-only"
				and full_vote.sandbox.network == true
		)
		gate_sandbox_current = {
			level = "workspace-write",
			network = false,
			unix_sockets = { "/tmp/agent.sock" },
			accept_partial = { "fs_read" },
			readable = { "/opt" },
			deny_read = { "/etc/shadow" },
			writable = { "/ws" },
			roots = { "/ws" },
		}
		local ws_vote = vote_gate({ name = "bash", arguments = { command = "ls" } }, { side_effect = "external" })
		assert(
			ws_vote.decision == "allow"
				and ws_vote.sandbox.level == "read-only"
				and ws_vote.sandbox.network == true
				and ws_vote.sandbox.unix_sockets[1] == "/tmp/agent.sock"
				and ws_vote.sandbox.accept_partial[1] == "fs_read"
				and ws_vote.sandbox.readable[1] == "/opt"
				and ws_vote.sandbox.deny_read[1] == "/etc/shadow"
				and ws_vote.sandbox.writable == nil
				and ws_vote.sandbox.roots == nil
		)
		-- Rule 8: local read -> nil
		assert(vote_gate({ name = "read", arguments = {} }, { side_effect = "read" }) == nil)

		-- enforce = false falls back to soft guidance and abstains from voting
		local soft_events = {}
		local soft_widget
		local soft_ctx = {
			session = gate_ctx.session,
			context = gate_ctx.context,
			ui = {
				invalidate = function() end,
				widget = function(_, _, spec)
					soft_widget = spec
				end,
			},
			commands = {
				register = function(_, _, v)
					soft_events._cmd = v
				end,
			},
			tools = gate_ctx.tools,
			agent = gate_ctx.agent,
			on = function(_, name, fn)
				soft_events[name] = soft_events[name] or {}
				table.insert(soft_events[name], fn)
			end,
			emit = function() end,
			effect = function(_, setup)
				setup()
			end,
			spawn = spawn,
			provide = function() end,
		}
		plugin.apply(soft_ctx, { section = plugin.config_schema.section.default, enforce = false })
		soft_events._cmd.run("on")
		local soft_banner = soft_widget.render(80, 1)
		expect.match(mare.json.encode(soft_banner), "PLAN — soft guidance")
		for _, fn in ipairs(soft_events["tool/before"] or {}) do
			expect.eq(fn({ name = "write", arguments = {} }, { side_effect = "write" }), nil)
		end
	end)

	it("skips ctx.session:entries() when committed.active is false on session build", function()
		local state_factory = require("plan_mode.state")
		local gen = "g1"
		local recs = {}
		local entry_calls = 0
		local p_events = {}
		local p_ctx = {
			session = {
				info = function()
					return { session_id = "s1", session_epoch = gen, readonly = false, ephemeral = false }
				end,
				list_records = function()
					return { data = recs }
				end,
				add_record = function()
					return { durable = true }
				end,
				entries = function()
					entry_calls = entry_calls + 1
					return { { id = "e1" } }
				end,
			},
			context = { invalidate = function() end },
			agent = {
				get = function()
					return { busy = false }
				end,
				notify = function() end,
			},
			on = function(_, name, fn)
				p_events[name] = fn
			end,
			effect = function(_, setup)
				setup()
			end,
			spawn = spawn,
		}
		local st = state_factory(p_ctx, function() end)
		-- Inactive restore (empty records -> committed.active == false): 0 entries() calls.
		st.restore()
		expect.eq(entry_calls, 0)
		expect.eq(st.current().active, false)

		-- Switch to new session identity with active = true record -> calls entries() once.
		gen = "g2"
		recs = { { version = 1, active = true, entered = true, revision = 1 } }
		st.restore()
		expect.eq(entry_calls, 1)
		expect.eq(st.current().active, true)
	end)

	it("does not overwrite target session effort when model/changed fires before session/changed", function()
		local sess_gen = "gen-a"
		local switching = false
		local recs = {}
		local effort_val, active_scope = "medium", nil
		local evs = {}
		local l_ctx = {
			llm = {
				current = function()
					return { ref = "m1", options = { "low", "medium", "high" } }
				end,
				effort_options = function()
					return { "low", "medium", "high" }
				end,
				clamp_effort = function(_, _, v)
					return v
				end,
				set_effort = function(_, v, opts)
					if not opts or opts.also_global or opts.scope_name == nil then
						effort_val = v
					end
					if opts and opts.scope_name == "plan" and not opts.also_global then
						effort_val = v
					end
				end,
				scoped_effort = function()
					return nil
				end,
				set_active_scope = function(_, s)
					active_scope = s
				end,
				active_scope = function()
					return active_scope
				end,
				effort = function()
					return effort_val
				end,
				clear_scope = function() end,
			},
			session = {
				info = function()
					return { session_id = "s1", session_epoch = sess_gen, readonly = false, ephemeral = false }
				end,
				switching = function()
					return switching
				end,
				list_records = function()
					return { data = recs }
				end,
				add_record = function(_, _, v)
					recs[#recs + 1] = v
					return { durable = true }
				end,
			},
			context = { invalidate = function() end, section = function() end },
			ui = { invalidate = function() end, widget = function() end },
			commands = { register = function() end },
			tools = { register = function() end },
			agent = {
				get = function()
					return { busy = false }
				end,
				register_activity = function() end,
				notify = function() end,
			},
			on = function(_, name, fn)
				evs[name] = evs[name] or {}
				table.insert(evs[name], fn)
			end,
			emit = function() end,
			effect = function(_, setup)
				setup()
			end,
			spawn = spawn,
			provide = function() end,
		}
		local cfg = support.default_config(plugin)
		cfg.plan_effort = "high"
		cfg.effort_scope = "global"
		local orig_policy = l_ctx.policy
		l_ctx.policy = { voter = function() end }
		plugin.apply(l_ctx, cfg)
		local p_svc
		l_ctx.provide = function(_, _, v)
			p_svc = v
		end
		-- Select plan mode active in Session A via /plan on
		local cmd_run
		l_ctx.commands = {
			register = function(_, _, def)
				cmd_run = def
			end,
		}
		evs = {}
		plugin.apply(l_ctx, cfg)
		cmd_run.run("on")
		expect.eq(p_svc.active(), true)
		expect.eq(effort_val, "high")

		-- Simulate /resume to Session B (inactive plan mode, restored effort = "low"):
		-- core emits model/changed BEFORE session/changed.
		switching = true
		sess_gen = "gen-b"
		recs = {}
		effort_val = "low"
		for _, fn in ipairs(evs["model/changed"] or {}) do
			fn()
		end
		expect.eq(effort_val, "low")
		for _, fn in ipairs(evs["session/changed"] or {}) do
			fn({ reason = "resume" })
		end
		switching = false
		expect.eq(p_svc.active(), false)
		expect.eq(effort_val, "low")
	end)

	it("blocks configured workflow tool_name via options service and formats structured agent errors", function()
		local evs = {}
		local wf_name = "custom_wf"
		local tool_before_voter, plan_cmd
		local g_ctx = {
			session = {
				info = function()
					return { session_id = "s-gate", session_epoch = "g-gate", ephemeral = true, readonly = false }
				end,
				list_records = function()
					return { data = {} }
				end,
				add_record = function()
					return { durable = true }
				end,
			},
			context = { invalidate = function() end, section = function() end },
			ui = { invalidate = function() end, widget = function() end },
			commands = {
				register = function(_, _, def)
					plan_cmd = def
				end,
			},
			tools = { register = function() end },
			agent = {
				get = function()
					return { busy = false }
				end,
				prompt = function()
					return { status = "started", turn_id = "t-err" }
				end,
				wait = function()
					return {
						status = "failed",
						error = { code = "provider_error", message = "rate limited" },
					}
				end,
				register_activity = function() end,
			},
			llm = {
				current = function()
					return nil
				end,
				raw_effort = function()
					return nil
				end,
				effort_options = function()
					return nil
				end,
				select_effort = function() end,
				scoped_effort = function()
					return nil
				end,
				active_scope = function()
					return nil
				end,
			},
			policy = {
				voter = function(_, ev, fn)
					if ev == "tool/before" then
						tool_before_voter = fn
					end
				end,
			},
			bus = { emit = function() end },
			on = function(_, ev, fn)
				evs[ev] = evs[ev] or {}
				evs[ev][#evs[ev] + 1] = fn
			end,
			after = function()
				return { cancel = function() end }
			end,
			effect = function() end,
			provide = function() end,
			spawn = spawn,
			options = {
				get = function(_, req)
					if req and req.keys and req.keys[1] == "plugins.workflow.tool_name" then
						return { ["plugins.workflow.tool_name"] = wf_name }
					end
					return {}
				end,
			},
			get = function(_, name)
				if name == "options" then
					return {
						get = function(_, req)
							if req and req.keys and req.keys[1] == "plugins.workflow.tool_name" then
								return { ["plugins.workflow.tool_name"] = wf_name }
							end
							return {}
						end,
					}
				end
				return nil
			end,
		}
		local cfg =
			assert(load(mare.fs.read("tests/specs/support.lua"), "@tests/specs/support.lua"))().default_config(plugin)
		plugin.apply(g_ctx, cfg)
		plan_cmd.run("on")

		local blocked = tool_before_voter({ name = "custom_wf", arguments = {} }, { side_effect = "external" })
		expect.eq(blocked.decision, "deny")

		wf_name = "renamed_wf"
		for _, fn in ipairs(evs["option/changed"] or {}) do
			fn({ key = "plugins.workflow.tool_name" })
		end
		local blocked_after = tool_before_voter({ name = "renamed_wf", arguments = {} }, { side_effect = "external" })
		expect.eq(blocked_after.decision, "deny")

		local failed = plan_cmd.run("do something")
		expect.eq(failed.status, "rejected")
		expect.eq(failed.reason, "rate limited")
	end)

	it("restores plan-mode state recorded before a compaction boundary on load and refresh", function()
		local evs = {}
		local seen_reqs = {}
		local pre_compaction = {
			{ version = 1, active = true, entered = true, revision = 1, plan = "# Pre-compact plan" },
		}
		local post_compaction_tail = {}
		local epoch = "compact-e1"
		local service, section, tool_before_voter
		local tools = {}

		local c_ctx = {
			session = {
				info = function()
					return { session_id = "s-compact", session_epoch = epoch, ephemeral = false, readonly = false }
				end,
				list_records = function(_, kind, req)
					expect.eq(kind, "plan-mode/state")
					seen_reqs[#seen_reqs + 1] = req
					if req and req.loaded_only then
						return { data = post_compaction_tail }
					end
					if req and req.cursor == "tail-page" then
						return { data = post_compaction_tail }
					end
					return { data = pre_compaction, next_cursor = "tail-page" }
				end,
				add_record = function(_, _, value)
					post_compaction_tail[#post_compaction_tail + 1] = value
					return { durable = true }
				end,
			},
			context = {
				invalidate = function() end,
				section = function(_, def)
					section = def
				end,
			},
			ui = { invalidate = function() end, widget = function() end },
			commands = { register = function() end },
			tools = {
				register = function(_, name, def)
					tools[name] = def
				end,
			},
			agent = {
				get = function()
					return { busy = false }
				end,
				register_activity = function() end,
			},
			llm = {
				current = function()
					return nil
				end,
				raw_effort = function()
					return nil
				end,
				effort_options = function()
					return nil
				end,
				select_effort = function() end,
				scoped_effort = function()
					return nil
				end,
				active_scope = function()
					return nil
				end,
			},
			policy = {
				voter = function(_, ev, fn)
					if ev == "tool/before" then
						tool_before_voter = fn
					end
				end,
			},
			bus = { emit = function() end },
			on = function(_, ev, fn)
				evs[ev] = evs[ev] or {}
				evs[ev][#evs[ev] + 1] = fn
			end,
			after = function()
				return { cancel = function() end }
			end,
			effect = function() end,
			provide = function(_, name, svc)
				if name == "plan_mode" then
					service = svc
				end
			end,
			spawn = spawn,
		}

		-- Negative contrast: tail-only read misses pre-compaction state.
		local tail_only = require("mare_lib").all_records(c_ctx.session, "plan-mode/state", { loaded_only = true })
		expect.eq(#tail_only, 0)

		-- 1. Initial load (`build`) on a compacted session with state only before compaction.
		seen_reqs = {}
		plugin.apply(c_ctx, support.default_config(plugin))
		expect.eq(#seen_reqs, 2)
		expect.eq(seen_reqs[1].branch, "all")
		expect.eq(seen_reqs[1].loaded_only, false)
		expect.eq(seen_reqs[2].loaded_only, false)
		expect.eq(service.active(), true)
		expect.eq(service.state().entered, true)
		expect.eq(service.state().revision, 1)
		expect.truthy(section.text(nil, {}))
		expect.eq(tools.exit_plan_mode.admit({}), true)
		local blocked = tool_before_voter({ name = "write", arguments = {} }, { side_effect = "write" })
		expect.eq(blocked.decision, "deny")

		-- 2. In-place refresh (`M.restore` same session identity) sees pre-compaction `entered = true`
		--    combined with post-compaction `active = false`.
		post_compaction_tail = {
			{ version = 1, active = false, entered = false, revision = 2 },
		}
		seen_reqs = {}
		for _, fn in ipairs(evs["session/changed"] or {}) do
			fn()
		end
		expect.eq(#seen_reqs, 2)
		expect.eq(seen_reqs[1].loaded_only, false)
		expect.eq(seen_reqs[2].loaded_only, false)
		expect.eq(service.active(), false)
		expect.eq(service.state().revision, 2)
		expect.eq(service.state().entered, true)
		expect.eq(tools.exit_plan_mode.admit({}), true)

		-- 3. Switching to another compacted session with only pre-compaction `active = true`.
		post_compaction_tail = {}
		epoch = "compact-e2"
		seen_reqs = {}
		for _, fn in ipairs(evs["session/changed"] or {}) do
			fn()
		end
		expect.eq(#seen_reqs, 2)
		expect.eq(seen_reqs[1].loaded_only, false)
		expect.eq(seen_reqs[2].loaded_only, false)
		expect.eq(service.active(), true)
		expect.eq(service.state().revision, 1)
		expect.eq(service.state().entered, true)
	end)
end)
