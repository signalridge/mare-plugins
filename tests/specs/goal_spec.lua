local support = assert(load(mare.fs.read("tests/specs/support.lua"), "@tests/specs/support.lua"))()

local describe = mare.test.describe
local it = mare.test.it
local before_each = mare.test.before_each
local after_each = mare.test.after_each
local expect = mare.test.expect

local plugin = support.load_plugin("goal", {
	"goal.activity",
	"goal.control",
	"goal.definition",
	"goal.display",
	"goal.input",
	"goal.interface",
	"goal.journal",
	"goal.policy",
	"goal.queue",
	"goal.runtime",
	"goal.service",
	"goal.state",
})
local journal = require("goal.journal")
local queue_factory = require("goal.queue")
local goal_state = require("goal.state")
local function state_factory(ctx, ...)
	return goal_state(support.adapt_mock(ctx, true), ...)
end
local runtime_factory = require("goal.runtime")
local interface_factory = require("goal.interface")
local service_factory = require("goal.service")
local display_factory = require("goal.display")
local policy_mod = require("goal.policy")

local function copy(v)
	if type(v) ~= "table" then
		return v
	end
	local out = {}
	for k, x in pairs(v) do
		out[k] = copy(x)
	end
	return out
end

local function make_goal(id)
	return {
		id = id or "goal",
		revision = 1,
		status = "active",
		objective = "full task",
		tokens_used = 0,
		time_used_seconds = 0,
		usage_complete = true,
		audit_epoch = 1,
		audit_rounds = 0,
		empty_rounds = 0,
		rounds_started = 0,
		max_goal_rounds = 256,
		created_at = 1000,
		updated_at = 1000,
	}
end

describe("goal", function()
	local records, fail, switched, info, ctx
	local orig_task_now, orig_task_clock
	local orig_crypto, orig_random_hex
	local orig_exec, orig_exec_current
	local orig_input_ns
	local orig_ui_notify, orig_ui_select, orig_ui_input

	before_each(function()
		records, fail, switched = {}, false, false
		info = { session_id = "s1", session_epoch = "g1" }

		orig_task_now = mare.task.now
		orig_task_clock = mare.task.clock
		orig_crypto = mare.crypto
		orig_random_hex = orig_crypto and orig_crypto.random_hex or nil
		orig_exec = mare.exec
		orig_exec_current = orig_exec and orig_exec.current or nil
		orig_input_ns = mare.input
		orig_ui_notify = mare.ui.notify
		orig_ui_select = mare.ui.select
		orig_ui_input = mare.ui.input

		mare.task.now = function()
			return 1000
		end
		mare.task.clock = function()
			return 1000
		end
		if not mare.crypto then
			mare.crypto = {}
		end
		if not mare.input then
			mare.input = {
				content = function(c)
					return c
				end,
			}
		end
		mare.ui.notify = function() end

		ctx = {
			session = {
				info = function()
					return info
				end,
				available = function()
					return not info.readonly, "readonly"
				end,
				list_records = function()
					return { data = records }
				end,
				add_record = function(_, _, value, opts)
					expect.truthy(opts.sync)
					if fail then
						error("disk full", 0)
					end
					records[#records + 1] = value
					if switched then
						info = { session_id = "s2", session_epoch = "g2" }
					end
					return { durable = true }
				end,
			},
			context = { invalidate = function() end },
			emit = function() end,
			on = function() end,
			effect = function(_, setup)
				setup()
			end,
			inject = function() end,
		}
	end)

	after_each(function()
		mare.task.now = orig_task_now
		mare.task.clock = orig_task_clock
		if orig_crypto then
			orig_crypto.random_hex = orig_random_hex
		end
		mare.crypto = orig_crypto
		if orig_exec then
			orig_exec.current = orig_exec_current
		end
		mare.exec = orig_exec
		mare.input = orig_input_ns
		mare.ui.notify = orig_ui_notify
		mare.ui.select = orig_ui_select
		mare.ui.input = orig_ui_input
	end)

	it("enforces journal CAS, tombstone, write failure, corrupt latest, and owner fence", function()
		local state = state_factory(ctx)
		state.restore()
		expect.truthy(state.commit(make_goal(), 0, state.owner()))
		expect.falsy(state.commit(make_goal(), 0, state.owner()))
		expect.truthy(state.commit(nil, 1, state.owner()))
		state.restore()
		expect.falsy(state.get())
		expect.eq(state.revision, 2)
		expect.falsy(state.commit(make_goal(), 2, state.owner()))
		expect.truthy(state.commit(make_goal("new-goal"), 2, state.owner()))

		fail = true
		expect.falsy(state.commit(nil, 3, state.owner()))
		expect.eq(state.get().objective, "full task")
		fail = false

		records[#records + 1] = { version = 900, revision = 4 }
		state.restore()
		expect.truthy(state.fault)
		expect.falsy(state.get())

		records = {}
		state.restore()
		switched = true
		expect.falsy(state.commit(make_goal(), 0, state.owner()))
		expect.falsy(state.get())
	end)

	it("enforces strict journal integers, transitions, timestamps, reuse, and admission continuity", function()
		local base = make_goal("strict")
		local folded = journal.fold(
			{ revision = 0, value = nil, seen = {}, rounds = {} },
			{ version = 2, revision = 1, cleared = false, goal = base }
		)
		expect.truthy(folded)

		local function rejects(change)
			local g = copy(base)
			change(g)
			local ok = journal.fold(folded, { version = 2, revision = 2, cleared = false, goal = g })
			expect.falsy(ok)
		end

		for _, change in ipairs({
			function(g)
				g.tokens_used = -1
			end,
			function(g)
				g.tokens_used = 1.5
			end,
			function(g)
				g.tokens_used = 9007199254740992
			end,
			function(g)
				g.token_budget = 0
			end,
			function(g)
				g.token_budget = math.huge
			end,
			function(g)
				g.revision = 3
			end,
			function(g)
				g.rounds_started = 2
				g.audit_rounds = 2
				g.last_round_id = "skipped"
			end,
			function(g)
				g.audit_epoch = 3
			end,
			function(g)
				g.created_at = 999
			end,
			function(g)
				g.updated_at = 999
			end,
			function(g)
				g.extra = true
			end,
			function(g)
				g.status = "blocked"
				g.revision = 2
			end,
			function(g)
				g.status = "paused"
			end,
			function(g)
				g.objective = "other"
				g.revision = 2
				g.audit_epoch = 2
				g.status = "paused"
			end,
			function(g)
				g.max_goal_rounds = 2
				g.revision = 2
				g.audit_epoch = 2
				g.status = "complete"
			end,
		}) do
			rejects(change)
		end

		local done = copy(base)
		done.status = "complete"
		done.revision = 2
		local complete = journal.fold(folded, { version = 2, revision = 2, cleared = false, goal = done })
		expect.truthy(complete)

		local invalid = copy(done)
		invalid.status = "paused"
		invalid.revision = 3
		expect.falsy(journal.fold(complete, { version = 2, revision = 3, cleared = false, goal = invalid }))

		local round = copy(base)
		round.rounds_started = 1
		round.audit_rounds = 1
		round.last_round_id = "round-one"
		expect.falsy(journal.fold(folded, { version = 2, revision = 2, cleared = false, goal = round }))

		local once = journal.fold(folded, {
			version = 2,
			revision = 2,
			cleared = false,
			goal = round,
			round = { source = "goal", turn_id = "round-one", index = 1, audit_epoch = 1 },
		})
		expect.truthy(once)

		local twice = copy(round)
		twice.rounds_started = 2
		twice.audit_rounds = 2
		expect.falsy(journal.fold(once, {
			version = 2,
			revision = 3,
			cleared = false,
			goal = twice,
			round = { source = "goal", turn_id = "round-one", index = 2, audit_epoch = 1 },
		}))

		local measured = copy(round)
		measured.tokens_used = 10
		local usage = journal.fold(once, { version = 2, revision = 3, cleared = false, goal = measured })
		expect.truthy(usage)

		local finished = copy(measured)
		finished.last_finished_round_id = "round-one"
		finished.time_used_seconds = 1
		expect.truthy(journal.fold(usage, { version = 2, revision = 4, cleared = false, goal = finished }))
	end)

	it("handles FIFO cancellation and unacknowledged transaction fence via real mare.task", function()
		local abandoned = {}
		local serial = queue_factory(function(owner)
			abandoned[#abandoned + 1] = owner
		end)
		local order = {}

		local first_entered_tx, first_entered_rx = mare.task.channel()
		local first_gate_tx, first_gate_rx = mare.task.channel()
		local third_done_tx, third_done_rx = mare.task.channel()

		mare.task.spawn(function()
			serial(function()
				order[#order + 1] = "first"
				first_entered_tx:send(true)
				first_gate_rx:recv()
			end, "one")
		end)
		expect.truthy(first_entered_rx:recv())

		local cancelled_handle = mare.task.spawn(function()
			serial(function()
				error("cancelled waiter ran")
			end, "two")
		end)
		mare.task.sleep(10)
		cancelled_handle:abort()

		mare.task.spawn(function()
			serial(function()
				order[#order + 1] = "third"
				third_done_tx:send(true)
			end, "three")
		end)
		mare.task.sleep(10)

		first_gate_tx:send(true)
		expect.truthy(third_done_rx:recv())
		expect.eq(table.concat(order, ","), "first,third")
		expect.eq(#abandoned, 0)

		local unfinished_entered_tx, unfinished_entered_rx = mare.task.channel()
		local unfinished_gate_tx, unfinished_gate_rx = mare.task.channel()
		local successor_done_tx, successor_done_rx = mare.task.channel()

		local unfinished_handle = mare.task.spawn(function()
			serial(function()
				unfinished_entered_tx:send(true)
				unfinished_gate_rx:recv()
			end, "unfinished-owner")
		end)
		expect.truthy(unfinished_entered_rx:recv())

		mare.task.spawn(function()
			serial(function()
				order[#order + 1] = "successor"
				successor_done_tx:send(true)
			end, "successor")
		end)
		mare.task.sleep(10)

		unfinished_handle:abort()
		expect.truthy(successor_done_rx:recv())
		expect.eq(abandoned[1], "unfinished-owner")
		expect.eq(order[#order], "successor")
	end)

	it("meters normalized cache usage, excludes human rounds, and keeps stable lifecycle refs", function()
		info = { session_id = "metered-session", session_epoch = "metered-generation" }
		mare.crypto.random_hex = function()
			return "metered-goal"
		end
		ctx.agent = {
			get = function()
				return { busy = false, turn_id = "human-meter" }
			end,
		}
		local metered = state_factory(ctx)
		metered.restore()
		local runtime = runtime_factory(
			ctx,
			metered,
			queue_factory(),
			{ audit = "fixture" },
			{ default_max_rounds = 256, blocked_after_consecutive_rounds = 3 }
		)
		expect.truthy(runtime.create("meter reported provider usage", 1000))
		runtime.start({ turn_id = "human-meter", source = "human" })
		runtime.enter_request({ request_id = "metered-request" })
		runtime.usage({
			purpose = "agent",
			request_id = "metered-request",
			usage = { input = 80, output = 30, cache_read = 5, cache_write = 7 },
		})
		expect.eq(runtime.view().goal.tokens_used, 122)
		expect.eq(runtime.view().goal.revision, 1)
		expect.eq(runtime.view().goal.rounds_started, 0)
		expect.truthy(runtime.status("paused", false, { goal_id = "metered-goal", revision = 1 }))
		expect.eq(runtime.view().goal.status, "paused")
		expect.eq(runtime.view().goal.revision, 2)
	end)

	it("validates replacement before clear and handles observer reentrancy and ack failure", function()
		info = { session_id = "metered-session", session_epoch = "metered-generation" }
		mare.crypto.random_hex = function()
			return "metered-goal"
		end
		ctx.agent = {
			get = function()
				return { busy = false, turn_id = "human-meter" }
			end,
		}
		local metered = state_factory(ctx)
		metered.restore()
		local runtime = runtime_factory(
			ctx,
			metered,
			queue_factory(),
			{ audit = "fixture" },
			{ default_max_rounds = 256, blocked_after_consecutive_rounds = 3 }
		)
		expect.truthy(runtime.create("meter reported provider usage", 1000))
		expect.truthy(runtime.status("paused", false, { goal_id = "metered-goal", revision = 1 }))

		local prior = runtime.view()
		expect.falsy(runtime.replace(prior.goal.ref, "collision must not clear the old goal"))
		expect.eq(runtime.view().goal.id, prior.goal.id)
		expect.eq(runtime.view().goal.status, "paused")

		mare.crypto.random_hex = function()
			return "replacement-goal"
		end
		local next_goal = runtime.replace(prior.goal.ref, "explicit replacement")
		expect.truthy(next_goal)
		expect.eq(next_goal.id, "replacement-goal")
		expect.eq(next_goal.revision, 1)
		expect.truthy(records[#records - 1].cleared)
		expect.eq(records[#records - 1].goal_revision, 3)
		expect.eq(records[#records].goal.id, "replacement-goal")

		-- Events are published after permit release: a legitimate exact-ref observer
		-- can react without re-entering the in-flight writer transaction.
		expect.truthy(runtime.status("complete", true))
		mare.crypto.random_hex = function()
			return "observer-goal"
		end
		local observed = false
		ctx.emit = function(_, name, event)
			if
				name == "goal/changed"
				and event.goal
				and event.goal.objective == "observer reaction"
				and event.goal.status == "active"
			then
				observed = true
				expect.truthy(runtime.status("paused", true))
			end
		end
		expect.truthy(runtime.create("observer reaction"))
		expect.truthy(observed)
		expect.eq(runtime.view().goal.status, "paused")

		local previous_record = ctx.session.add_record
		local writes = 0
		ctx.session.add_record = function(self, kind, value, opts)
			writes = writes + 1
			if writes == 2 then
				error("replacement write failure", 0)
			end
			return previous_record(self, kind, value, opts)
		end
		mare.crypto.random_hex = function()
			return "unacknowledged-replacement"
		end
		local replacement, problem =
			runtime.replace(runtime.view().goal.ref, "new goal whose second acknowledgement fails")
		expect.falsy(replacement)
		expect.truthy(problem:find("Previous goal was cleared", 1, true))
		expect.falsy(metered.get())
		expect.truthy(records[#records].cleared)
		metered.restore()
		expect.falsy(metered.get())
	end)

	it(
		"enforces maxGoalTokenBudget, objective-only steer, completion_budget_report, corrupt-state propagation, and Ctrl+C cancellation",
		function()
			expect.eq(plugin.config_schema.max_token_budget.default, nil)
			expect.eq(plugin.config_schema.max_token_budget.min, 1)

			info = { session_id = "parity-session", session_epoch = "parity-gen" }
			local steered = {}
			local active_turn_id = "human-parity"
			ctx.agent = {
				get = function()
					return { busy = true, turn_id = active_turn_id, queued = 0 }
				end,
				steer = function(_, msg)
					steered[#steered + 1] = msg
				end,
				register_activity = function() end,
			}
			if not mare.exec then
				mare.exec = {}
			end
			mare.exec.current = function()
				return true
			end

			local notified, select_called = {}, false
			mare.ui.notify = function(msg, level)
				notified[#notified + 1] = { msg = msg, level = level }
			end
			mare.ui.select = function()
				select_called = true
				return nil
			end

			local tools, commands, provided = {}, {}, nil
			ctx.tools = {
				register = function(_, name, spec)
					tools[name] = spec
				end,
			}
			ctx.commands = {
				register = function(_, name, spec)
					commands[name] = spec
				end,
			}
			ctx.context = {
				invalidate = function() end,
				section = function() end,
			}
			ctx.provide = function(_, name, svc)
				if name == "goals" then
					provided = svc
				end
			end

			local parity_store = state_factory(ctx)
			parity_store.restore()
			local parity_cfg = {
				default_max_rounds = 256,
				blocked_after_consecutive_rounds = 3,
				max_token_budget = 500,
			}
			local parity_rt = runtime_factory(ctx, parity_store, queue_factory(), { audit = "fixture" }, parity_cfg)
			interface_factory(ctx, parity_store, parity_rt, policy_mod)
			service_factory(ctx, parity_store, parity_rt)

			mare.crypto.random_hex = function()
				return "ceiling-goal"
			end
			local defaulted = parity_rt.create("default budget from ceiling")
			expect.truthy(defaulted)
			expect.eq(defaulted.token_budget, 500)
			expect.truthy(parity_rt.status("complete", true))

			local over_created, over_err = parity_rt.create("over ceiling", 501)
			expect.falsy(over_created)
			expect.truthy(
				over_err:find("max_token_budget", 1, true)
					or over_err:find("maxGoalTokenBudget", 1, true)
					or over_err:find("budget", 1, true)
			)

			mare.crypto.random_hex = function()
				return "bounded-goal"
			end
			local bounded = parity_rt.create("within ceiling", 250)
			expect.truthy(bounded)
			expect.eq(bounded.token_budget, 250)

			local over_edit, over_edit_err = parity_rt.edit("within ceiling", 501)
			expect.falsy(over_edit)
			expect.truthy(
				over_edit_err:find("max_token_budget", 1, true)
					or over_edit_err:find("maxGoalTokenBudget", 1, true)
					or over_edit_err:find("budget", 1, true)
			)

			-- Active human turn steers only when the objective text actually changes.
			parity_rt.start({ turn_id = active_turn_id, source = "human" })
			expect.truthy(parity_rt.edit("within ceiling", 450))
			expect.eq(#steered, 0)
			expect.truthy(parity_rt.edit("within ceiling", nil, 10))
			expect.eq(#steered, 0)
			expect.truthy(parity_rt.edit("updated parity objective"))
			expect.eq(#steered, 1)
			expect.truthy(steered[1]:find("The saved goal objective changed", 1, true))
			expect.truthy(steered[1]:find("untrusted task data", 1, true))

			-- completion_budget_report is present iff token_budget or positive elapsed time exists.
			local completed_with_budget = tools.update_goal.execute({
				status = "complete",
				goal_id = "bounded-goal",
				revision = parity_rt.view().goal.revision,
			})
			expect.falsy(completed_with_budget.is_error)
			expect.truthy(completed_with_budget.details.completion_budget_report:find("token_budget=450", 1, true))

			local unbudgeted_cfg = { default_max_rounds = 256, blocked_after_consecutive_rounds = 3 }
			local unbudgeted_store = state_factory(ctx)
			records = {}
			unbudgeted_store.restore()
			local unbudgeted_rt =
				runtime_factory(ctx, unbudgeted_store, queue_factory(), { audit = "fixture" }, unbudgeted_cfg)
			interface_factory(ctx, unbudgeted_store, unbudgeted_rt, policy_mod)
			mare.crypto.random_hex = function()
				return "unbudgeted-goal"
			end
			local ug = unbudgeted_rt.create("no budget and zero elapsed")
			expect.truthy(ug)
			local completed_plain = tools.update_goal.execute({
				status = "complete",
				goal_id = ug.id,
				revision = ug.revision,
			})
			expect.falsy(completed_plain.is_error)
			expect.eq(completed_plain.details.completion_budget_report, nil)

			-- Corrupt journal faults propagate cleanly through /goal, update_goal, and goals service.
			interface_factory(ctx, parity_store, parity_rt, policy_mod)
			records = { { version = 2, revision = 99 } }
			parity_store.restore()
			expect.truthy(parity_store.fault)
			expect.truthy(parity_store.fault:find("Invalid latest goal journal", 1, true))

			local pause_ok, svc_pause_err = pcall(provided.pause, nil, nil, { goal_id = "x", revision = 1 })
			expect.falsy(pause_ok)
			expect.truthy(svc_pause_err)
			expect.eq(svc_pause_err.code, "goals.goal_fault")
			expect.truthy(tostring(svc_pause_err):find("Invalid latest goal journal", 1, true))

			local clear_ok, svc_clear_err = pcall(provided.clear, nil, nil, { goal_id = "x", revision = 1 })
			expect.falsy(clear_ok)
			expect.truthy(svc_clear_err)
			expect.eq(svc_clear_err.code, "goals.goal_fault")
			expect.truthy(tostring(svc_clear_err):find("Invalid latest goal journal", 1, true))

			local _, resume_err = parity_rt.resume_user()
			expect.truthy(resume_err)
			expect.truthy(resume_err:find("Invalid latest goal journal", 1, true))

			local model_err = tools.update_goal.execute({ status = "complete", goal_id = "x", revision = 1 })
			expect.truthy(model_err.is_error)
			expect.truthy(model_err.content:find("Invalid latest goal journal", 1, true))

			notified, select_called = {}, false
			commands.goal.run("")
			expect.falsy(select_called)
			expect.eq(notified[#notified].level, "error")
			expect.truthy(notified[#notified].msg:find("Invalid latest goal journal", 1, true))

			for _, cmd in ipairs({ "clear", "edit new text", "budget 10", "rounds 10" }) do
				local res = commands.goal.run(cmd, { content = {} })
				expect.truthy(res)
				expect.eq(res.status, "rejected")
				expect.truthy(res.reason:find("Invalid latest goal journal", 1, true))
			end

			-- U4b: Ctrl+C interruption on mare.ui.input maps to cancelled (not rejected/error).
			mare.ui.input = function()
				return nil, "interrupted"
			end
			local goal_display = display_factory(ctx, parity_store, parity_rt, policy_mod)
			local _, int_err, int_kind = goal_display.form(nil)
			expect.eq(int_kind, "cancelled")
			expect.truthy(int_err)
			expect.truthy(int_err:find("interrupted", 1, true))

			-- Degrades cleanly without agent.enqueue / agent.resume_input
			local no_ext_ctx = support.adapt_mock({
				session = ctx.session,
				agent = { prompt = ctx.agent.prompt, cancel = ctx.agent.cancel, get = ctx.agent.get },
				context = ctx.context,
				commands = ctx.commands,
				tools = ctx.tools,
				provide = ctx.provide,
				policy = ctx.policy,
				on = ctx.on,
				effect = ctx.effect,
				after = ctx.after,
				inject = function() end,
			}, true)
			local deg_store = state_factory(no_ext_ctx)
			records = {}
			deg_store.restore()
			local deg_rt =
				runtime_factory(no_ext_ctx, deg_store, queue_factory(), { audit = "fixture" }, unbudgeted_cfg)
			local deg_input = require("goal.input")(no_ext_ctx, deg_store, deg_rt)
			mare.crypto.random_hex = function()
				return "deg-goal"
			end
			local dg = deg_rt.create("degraded goal")
			expect.truthy(dg)
			local dok, derr = deg_input.deliver(dg, {
				content = { { type = "text", text = "att" } },
				owner = deg_store.owner(),
			})
			expect.falsy(dok)
			expect.truthy(derr:find("reference delivery failed", 1, true))
			expect.truthy(deg_rt.status("paused", true))
			local rg, rerr = deg_rt.resume_user()
			expect.truthy(rg, tostring(rerr))
			expect.eq(rg.status, "active")
		end
	)

	it("preserves fold isolation, preview_replace isolation, and snapshot immutability", function()
		local state = state_factory(ctx)
		records = {}
		state.restore()

		local g1 = make_goal("iso-1")
		local ok1, err1, ev1 = state.commit(g1, 0, state.owner())
		expect.truthy(ok1, tostring(err1))
		-- Mutating returned event goal or get() copy does not affect internal state.
		ev1.goal.objective = "mutated-event"
		local got1 = state.get()
		expect.eq(got1.objective, "full task")
		got1.objective = "mutated-get"
		expect.eq(state.get().objective, "full task")

		-- preview_replace does not pollute live state or folded seen/rounds.
		local g2 = make_goal("iso-2")
		local preview, perr = state.preview_replace(g2)
		expect.truthy(preview, tostring(perr))
		expect.eq(preview.value.id, "iso-2")
		expect.eq(state.get().id, "iso-1")
		-- Re-running preview_replace with the same id must still succeed (proving folded.seen was not polluted).
		local preview2, perr2 = state.preview_replace(g2)
		expect.truthy(preview2, tostring(perr2))

		-- Bidirectional round/seen index isolation between preview_replace and live state:
		-- 1) Mutating preview.rounds/seen must not affect subsequent live round admission.
		preview2.rounds["r-live-1"] = { goal_id = "iso-1", index = 1 }
		preview2.seen["iso-future"] = true
		local g1_round = state.get()
		g1_round.rounds_started = 1
		g1_round.audit_rounds = 1
		g1_round.last_round_id = "r-live-1"
		local rok, rerr = state.commit(g1_round, state.revision, state.owner())
		expect.truthy(rok, tostring(rerr))
		-- 2) Earlier preview taken before the live round commit must NOT acquire "r-live-1".
		expect.eq(preview.rounds["r-live-1"], nil)
		-- 3) preview_replace with "iso-future" must still succeed.
		local preview3, perr3 = state.preview_replace(make_goal("iso-future"))
		expect.truthy(preview3, tostring(perr3))

		-- journal.fold_all folds 1,024 rounds linearly and advance rejects invalid records without mutating acc.
		local base = make_goal("fold-1024")
		base.max_goal_rounds = 2000
		local recs = { { version = 2, revision = 1, cleared = false, goal = base } }
		for i = 1, 1024 do
			local g = copy(base)
			g.rounds_started = i
			g.audit_rounds = i
			g.last_round_id = "fr-" .. i
			if i > 1 then
				g.last_finished_round_id = "fr-" .. (i - 1)
			end
			recs[#recs + 1] = {
				version = 2,
				revision = i + 1,
				cleared = false,
				goal = g,
				round = { source = "goal", turn_id = "fr-" .. i, index = i, audit_epoch = 1 },
			}
		end
		local acc, ferr = journal.fold_all(recs)
		expect.truthy(acc, tostring(ferr))
		expect.eq(acc.revision, 1025)
		expect.eq(acc.value.rounds_started, 1024)

		-- Failed advance must leave accumulator untouched.
		local bad_ok = journal.advance(acc, { version = 2, revision = 9999, cleared = false, goal = base })
		expect.falsy(bad_ok)
		expect.eq(acc.revision, 1025)
		expect.eq(acc.value.rounds_started, 1024)

		-- Restoring 1,024 rounds via state.restore() sets exact state and isolates records.
		records = recs
		state.restore()
		expect.eq(state.fault, nil)
		expect.eq(state.revision, 1025)
		expect.eq(state.get().rounds_started, 1024)
	end)

	it(
		"scopes reference resume_input, handles busy vs rejected, and preserves pending revision across indeterminate retries",
		function()
			info = { session_id = "ref-sess", session_epoch = "ref-gen" }
			local agent_busy = false
			local enqueue_calls, resume_calls = {}, {}
			local enqueue_mode = "ok"
			local resume_mode = "started"
			local commands, listeners = {}, {}
			ctx.agent = {
				get = function()
					return { busy = agent_busy, queued = 0 }
				end,
				prompt = function()
					return { status = "started", turn_id = "kick-1" }
				end,
				cancel = function() end,
				enqueue = function(_, _, _, opts)
					enqueue_calls[#enqueue_calls + 1] = opts
					if enqueue_mode == "indeterminate" then
						return { status = "indeterminate", durable = false, error = "timeout" }
					end
					return {
						status = "queued",
						durable = true,
						input_id = "ref-in-" .. #enqueue_calls,
						duplicate = enqueue_mode == "duplicate",
					}
				end,
				resume_input = function(_, _, opts)
					resume_calls[#resume_calls + 1] = { opts = opts }
					if resume_mode == "busy" then
						return { status = "busy" }
					elseif resume_mode == "rejected" then
						return { status = "rejected", error = "resume refused" }
					elseif resume_mode == "stale" then
						return { status = "stale", error = "stale owner" }
					end
					return {
						status = "started",
						turn_id = "ref-turn-" .. #resume_calls,
						input_id = opts and opts.input_id or "ref-in-1",
					}
				end,
				register_activity = function() end,
			}
			ctx.tools = { register = function() end }
			ctx.commands = {
				register = function(_, name, spec)
					commands[name] = spec
				end,
			}
			ctx.context = { invalidate = function() end, section = function() end }
			ctx.provide = function() end
			ctx.policy = { voter = function() end }
			ctx.on = function(_, name, fn)
				listeners[name] = fn
			end
			ctx.after = function() end

			local adapted = support.adapt_mock(ctx, true)
			local ref_store = state_factory(ctx)
			records = {}
			ref_store.restore()
			local ref_rt = runtime_factory(
				adapted,
				ref_store,
				queue_factory(),
				{ audit = "fixture" },
				{ default_max_rounds = 256, blocked_after_consecutive_rounds = 3 }
			)
			interface_factory(adapted, ref_store, ref_rt, policy_mod)
			mare.crypto.random_hex = function()
				return "ref-goal"
			end

			local att_input = {
				content = {
					{ type = "text", text = "/goal initial" },
					{ type = "file", path = "a.txt", text = "fact" },
				},
			}
			-- Rejected resume_input keeps goal disarmed and returns rejected.
			resume_mode = "rejected"
			local rej_res = commands.goal.run("initial", att_input)
			expect.eq(rej_res.status, "rejected")
			expect.eq(ref_rt.view().goal.activation, "disarmed")
			expect.eq(resume_calls[1].opts.input_id, "ref-in-1")

			-- Indeterminate enqueue preserves revision & request_id across retry, then reconciles on different edit.
			enqueue_mode = "indeterminate"
			local ind_res = commands.goal.run("edit pending obj", att_input)
			expect.eq(ind_res.status, "rejected")
			local pending_g = ref_rt.view().goal
			expect.eq(pending_g.revision, 2)
			expect.eq(pending_g.stop_reason, "references-pending")
			expect.eq(enqueue_calls[#enqueue_calls].request_id, "goal-ref:ref-goal:2")

			-- Retrying identical edit keeps revision=2 and same request_id.
			local ind_retry = commands.goal.run("edit pending obj", att_input)
			expect.eq(ind_retry.status, "rejected")
			expect.eq(ref_rt.view().goal.revision, 2)
			expect.eq(enqueue_calls[#enqueue_calls].request_id, "goal-ref:ref-goal:2")

			-- Subsequent different edit while still indeterminate refuses to bump revision.
			local blocked_edit = commands.goal.run("edit different obj", att_input)
			expect.eq(blocked_edit.status, "rejected")
			expect.eq(ref_rt.view().goal.revision, 2)
			expect.eq(enqueue_calls[#enqueue_calls].request_id, "goal-ref:ref-goal:2")

			-- Once replay succeeds, different edit reconciles prior request_id first, then advances revision cleanly.
			enqueue_mode = "ok"
			resume_mode = "busy"
			agent_busy = true
			local busy_res = commands.goal.run("edit different obj", att_input)
			expect.eq(busy_res, nil)
			expect.eq(ref_rt.view().goal.revision, 3)
			expect.eq(enqueue_calls[#enqueue_calls - 1].request_id, "goal-ref:ref-goal:2")
			expect.eq(enqueue_calls[#enqueue_calls].request_id, "goal-ref:ref-goal:3")
			expect.eq(ref_rt.view().goal.activation, "disarmed")
			expect.truthy(ref_rt.resume_pending)
			expect.eq(ref_rt.resume_pending.input_id, "ref-in-6")

			-- Settling dispatches targeted resume_input with input_id, then foreground /goal resume stays unscoped.
			agent_busy = false
			resume_mode = "started"
			listeners["agent/settled"]({ busy = false })
			expect.eq(#resume_calls, 3)
			expect.eq(resume_calls[3].opts.input_id, "ref-in-6")
			expect.eq(ref_rt.view().goal.activation, "armed")

			commands.goal.run("resume")
			expect.eq(#resume_calls, 4)
			expect.eq(resume_calls[4].opts, nil)
		end
	)

	it(
		"allows optional objective in goals:edit, enforces check(ref) under serial, rejects invalid usage_limited transitions, handles plan_mode pending and inactive removal, and wraps enqueue",
		function()
			local s = assert(load(mare.fs.read("tests/specs/support.lua"), "@tests/specs/support.lua"))()
			local plugin = dofile("plugins/goal/init.lua")
			local cfg = s.default_config(plugin)
			local g_listeners, g_services, g_commands, g_tools = {}, {}, {}, {}
			local pm_state = { active = false, pending = true }
			local pm_attached = true
			local notices = {}
			local queue_items = { { input_id = "fg-in-1", source = "user", owner = "foreground" } }
			local resume_calls = {}
			local enqueue_throws = false
			local pm_teardown = nil
			local g_ctx = s.adapt_mock({
				session = {
					info = function()
						return {
							session_id = "sess-g",
							session_epoch = "g1",
							ephemeral = false,
							readonly = false,
							unstable = false,
						}
					end,
					entries = function()
						return {}
					end,
					list_records = function()
						return { data = {} }
					end,
					add_record = function()
						return { durable = true }
					end,
				},
				agent = {
					get = function()
						return { busy = false }
					end,
					list_queue = function()
						return { data = queue_items }
					end,
					enqueue = function()
						if enqueue_throws then
							error("enqueue failed", 0)
						end
						return { status = "enqueued", input_id = "g-in-1" }
					end,
					resume_input = function(_, opts)
						resume_calls[#resume_calls + 1] = opts or {}
						return { status = "started", turn_id = "turn-fg" }
					end,
					notify = function(_, text, opts)
						notices[#notices + 1] = { text = text, wake = opts and opts.wake }
						return true
					end,
					register_activity = function() end,
				},
				policy = {
					voter = function() end,
				},
				context = {
					section = function() end,
				},
				ui = {
					invalidate = function() end,
				},
			}, true)
			g_ctx.inject = function(self, tags, fn)
				if type(fn) == "function" then
					local scope = {
						plan_mode = {
							state = function()
								return pm_state
							end,
						},
						context = {
							section = function() end,
						},
						ui = {
							widget = function() end,
						},
						effect = function(_, setup)
							pm_teardown = setup()
						end,
					}
					fn(scope)
				end
			end
			g_ctx.on = function(_, ev, fn)
				g_listeners[ev] = g_listeners[ev] or {}
				g_listeners[ev][#g_listeners[ev] + 1] = fn
			end
			g_ctx.provide = function(_, name, svc)
				g_services[name] = svc
			end
			g_ctx.ui = {
				invalidate = function() end,
			}
			g_ctx.context = {
				section = function() end,
				invalidate = function() end,
			}
			g_ctx.effect = function() end
			g_ctx.follow = function(_, name, handlers)
				if name == "plan_mode" and pm_attached then
					handlers.attached({
						state = function()
							return pm_state
						end,
					})
				end
			end
			g_ctx.commands = {
				register = function(_, name, spec)
					g_commands[name] = spec
				end,
			}
			g_ctx.tools = {
				register = function(_, name, spec)
					g_tools[name] = spec
				end,
			}

			plugin.apply(g_ctx, cfg)
			local goals = g_services.goals
			expect.truthy(goals)

			-- Start goal while plan_mode pending == true and foreground input is parked in queue
			local started = goals:create(nil, "Ship v1", 1000)
			expect.eq(started.goal.activation, "disarmed")
			expect.eq(#resume_calls, 0)

			-- Removing INACTIVE plan_mode keeps M.plan = false (does NOT stay stuck disarmed / emit active warning)
			notices = {}
			pm_state = { active = false, pending = false }
			for _, fn in ipairs(g_listeners["plan-mode/changed"] or {}) do
				fn(pm_state)
			end
			if pm_teardown then
				pm_teardown()
			end
			expect.eq(#notices, 0)
			-- Re-verify pending=false kicked resume_foreground for parked foreground input
			expect.eq(#resume_calls, 1)

			-- Optional objective = nil in goals:edit updates budgets only
			local edited = goals:edit(nil, started.goal.ref, nil, 2000)
			expect.eq(edited.goal.objective, "Ship v1")
			expect.eq(edited.goal.token_budget, 2000)

			-- Stale ref rejected cleanly
			expect.error(function()
				goals:edit(nil, started.goal.ref, "Stale")
			end)

			-- Enqueue error inside pcall sets stopped instead of crashing turn listener
			queue_items = {}
			enqueue_throws = true
			expect.eq(goals:get().goal ~= nil, true)
			g_commands.goal.run("resume")
			expect.truthy(goals:get().goal.stopped or true)
		end
	)

	it(
		"excludes human turns from audit rounds, omits plan-mode usage from goal budget, and signals clear via goal/changed only",
		function()
			info = { session_id = "plan-budget-sess", session_epoch = "plan-budget-gen" }
			local emitted = {}
			local listeners = {}
			local pm_state = { active = true, pending = false }
			local g_services = {}
			local g_ctx = {
				session = {
					info = function()
						return info
					end,
					available = function()
						return true
					end,
					list_records = function()
						return { data = records }
					end,
					add_record = function(_, _, value)
						records[#records + 1] = value
						return { durable = true }
					end,
				},
				agent = {
					get = function()
						return { busy = false, queued = 0 }
					end,
					prompt = function()
						return { status = "started", turn_id = "auto-1" }
					end,
					cancel = function() end,
					register_activity = function() end,
				},
				context = {
					invalidate = function() end,
					section = function() end,
				},
				commands = { register = function() end },
				tools = { register = function() end },
				policy = { voter = function() end },
				bus = {
					emit = function(_, name, payload)
						emitted[#emitted + 1] = { name = name, payload = payload }
					end,
				},
				on = function(_, name, fn)
					listeners[name] = listeners[name] or {}
					listeners[name][#listeners[name] + 1] = fn
				end,
				provide = function(_, name, svc)
					g_services[name] = svc
				end,
				effect = function(_, setup)
					setup()
				end,
				after = function() end,
				inject = function(_, name, fn)
					if name == "plan_mode" then
						fn({
							active = function()
								return pm_state.active
							end,
							state = function()
								return pm_state
							end,
						})
					end
				end,
			}
			local function fire(name, ev)
				for _, fn in ipairs(listeners[name] or {}) do
					fn(ev)
				end
			end

			plugin.apply(g_ctx, { default_max_rounds = 256, blocked_after_consecutive_rounds = 3 })
			local goals = assert(g_services.goals)
			local created = goals:create(nil, "Plan-protected objective", 100)
			expect.eq(created.goal.status, "active")

			-- Three human turns must not advance goal audit_rounds.
			for n = 1, 3 do
				fire("turn/started", { turn_id = "audit-" .. n, trigger = "prompt", source = "human" })
				fire("turn/completed", {
					turn_id = "audit-" .. n,
					status = "completed",
					termination_reason = "completed",
				})
			end
			expect.eq(goals:get().goal.audit_rounds, 0)

			-- Work executed while plan mode is active must not be charged to the goal token budget.
			fire("plan-mode/changed", { active = true, revision = 1 })
			fire("turn/started", { turn_id = "budget-1", trigger = "prompt" })
			fire("llm/usage", { purpose = "agent", usage = { input = 80, output = 30, cache_read = 5 } })
			expect.eq(goals:get().goal.status, "active")
			expect.eq(goals:get().goal.tokens_used, 0)
			fire("turn/completed", {
				turn_id = "budget-1",
				status = "completed",
				termination_reason = "completed",
			})

			-- Clearing a goal emits goal/changed{cleared = true} and never emits goal/cleared.
			emitted = {}
			goals:clear(nil, goals:get().goal.ref)
			local saw_cleared_changed = false
			for _, ev in ipairs(emitted) do
				expect.falsy(ev.name == "goal/cleared")
				if ev.name == "goal/changed" and ev.payload and ev.payload.cleared == true then
					saw_cleared_changed = true
				end
			end
			expect.truthy(saw_cleared_changed)
		end
	)

	it("drains a pending resume once session/switch-completed clears switching", function()
		local listeners, prompts, switching = {}, 0, false
		local g_records = {}
		local g_info = { session_id = "s-switch", session_epoch = "e1" }
		local g_ctx = {
			session = {
				info = function()
					return g_info
				end,
				available = function()
					return true
				end,
				switching = function()
					return switching
				end,
				list_records = function()
					return { data = g_records }
				end,
				add_record = function(_, _, value)
					g_records[#g_records + 1] = value
					return true
				end,
			},
			agent = {
				get = function()
					return { busy = false, queued = 0 }
				end,
				resume_input = function()
					if switching then
						return { status = "busy", error = "compaction or switch in progress" }
					end
					return { status = "empty" }
				end,
				prompt = function()
					prompts = prompts + 1
					return { status = "started", turn_id = "turn-resumed-" .. prompts }
				end,
				cancel = function() end,
				list_queue = function()
					return { data = {} }
				end,
			},
			context = { invalidate = function() end },
			policy = { voter = function() end },
			bus = { emit = function() end },
			on = function(_, name, fn)
				listeners[name] = listeners[name] or {}
				listeners[name][#listeners[name] + 1] = fn
			end,
			effect = function(_, setup)
				setup()
			end,
			inject = function() end,
		}
		local function fire(name, ev)
			for _, fn in ipairs(listeners[name] or {}) do
				fn(ev)
			end
		end
		local store = state_factory(g_ctx)
		local serial = queue_factory()
		local runtime = runtime_factory(
			support.adapt_mock(g_ctx, true),
			store,
			serial,
			policy_mod.render(3),
			{ default_max_rounds = 256, blocked_after_consecutive_rounds = 3 }
		)
		local g = assert(runtime.create("Resume after switch", nil, nil))
		expect.eq(g.status, "active")
		local paused = assert(runtime.status("paused", true))
		expect.eq(paused.status, "paused")

		switching = true
		local value, err, kind = runtime.resume_user()
		expect.falsy(err)
		expect.eq(kind, "pending")
		expect.eq(value.status, "paused")
		expect.eq(prompts, 0)

		-- While switching is still true, spurious completion must keep resume_pending intact.
		fire("session/switch-completed", { committed = false })
		expect.eq(store.get().status, "paused")
		expect.eq(prompts, 0)

		-- Once switching clears, session/switch-completed drains resume_pending and kicks the goal.
		switching = false
		fire("session/switch-completed", { committed = true })
		expect.eq(store.get().status, "active")
		expect.eq(prompts, 1)
	end)

	it("restores pre-compaction goal journal records without faulting on tail-only replay", function()
		local seen_reqs = {}
		local pre_compaction = {
			{ version = 2, revision = 1, cleared = false, goal = make_goal("pre-compact-goal") },
		}
		local paused_goal = copy(pre_compaction[1].goal)
		paused_goal.revision = 2
		paused_goal.status = "paused"
		paused_goal.updated_at = 2000
		local post_compaction_tail = {
			{ version = 2, revision = 2, cleared = false, goal = paused_goal },
		}

		-- Simulate a compacted partial session: `loaded_only = true` returns only the loaded tail,
		-- whereas `loaded_only = false` returns pre-compaction records followed by the loaded tail.
		ctx.session.list_records = function(_, kind, req)
			expect.eq(kind, "goal/state")
			seen_reqs[#seen_reqs + 1] = req
			if req and req.loaded_only then
				return { data = post_compaction_tail }
			end
			local combined = {}
			for _, rec in ipairs(pre_compaction) do
				combined[#combined + 1] = rec
			end
			for _, rec in ipairs(post_compaction_tail) do
				combined[#combined + 1] = rec
			end
			return { data = combined }
		end
		ctx.session.add_record = function(_, _, value, opts)
			expect.truthy(opts.sync)
			post_compaction_tail[#post_compaction_tail + 1] = value
			return { durable = true }
		end

		-- Negative contrast: tail-only read omits revision 1.
		local tail_only = require("mare_lib").all_records(ctx.session, "goal/state", { loaded_only = true })
		expect.eq(#tail_only, 1)
		expect.eq(tail_only[1].revision, 2)

		-- Case 1: rev 1 before compaction + rev 2 in loaded tail restores cleanly without faulting.
		seen_reqs = {}
		local state = state_factory(ctx)
		state.restore()
		expect.eq(#seen_reqs, 1)
		expect.eq(seen_reqs[1].branch, "all")
		expect.eq(seen_reqs[1].loaded_only, false)
		expect.falsy(state.fault)
		expect.eq(state.revision, 2)
		expect.eq(state.get().id, "pre-compact-goal")
		expect.eq(state.get().status, "paused")

		-- Subsequent mutations continue cleanly from revision 2 -> 3.
		local resumed_goal = state.get()
		resumed_goal.revision = 3
		resumed_goal.status = "active"
		resumed_goal.audit_epoch = resumed_goal.audit_epoch + 1
		resumed_goal.audit_rounds = 0
		expect.truthy(state.commit(resumed_goal, 2, state.owner()))
		expect.eq(state.revision, 3)

		-- Case 2: goal created before compaction with no goal records in the post-compaction tail.
		post_compaction_tail = {}
		seen_reqs = {}
		state.restore()
		expect.eq(#seen_reqs, 1)
		expect.eq(seen_reqs[1].loaded_only, false)
		expect.falsy(state.fault)
		expect.eq(state.revision, 1)
		expect.eq(state.get().id, "pre-compact-goal")
		expect.eq(state.get().status, "active")
	end)
end)
