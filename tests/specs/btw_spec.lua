local support = assert(load(mare.fs.read("tests/specs/support.lua"), "@tests/specs/support.lua"))()

local describe = mare.test.describe
local it = mare.test.it
local before_each = mare.test.before_each
local after_each = mare.test.after_each
local expect = mare.test.expect

local plugin = support.load_plugin("btw", { "btw.render", "btw.tracker" })
local tracker_mod = require("btw.tracker")

local SECRET = "sk-proj-1234567890abcdef1234567890abcdef"

local function expected_projected(value)
	if mare.projection and type(mare.projection.project) == "function" then
		return mare.projection.project(value)
	end
	return value
end

local function copy_table(value)
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in pairs(value) do
		out[k] = copy_table(v)
	end
	return out
end

local function merge_config(overrides)
	local cfg = support.default_config(plugin)
	for k, v in pairs(overrides or {}) do
		cfg[k] = v
	end
	return cfg
end

local function make_harness(cfg_overrides)
	local events = {}
	local widgets = {}
	local statuses = {}
	local actions = {}
	local keys = {}
	local invalidations = {}
	local dispose_callbacks = {}
	local commands_registered = 0
	local activity_provider, provided_service
	local conv_info = nil
	local conv_calls = {}
	local agent_calls = {}
	local start_err, toggle_err

	local ctx = {
		on = function(_, name, fn)
			events[name] = events[name] or {}
			events[name][#events[name] + 1] = fn
		end,
		effect = function(_, setup)
			local fn = setup()
			dispose_callbacks[#dispose_callbacks + 1] = fn
		end,
		provide = function(_, name, svc)
			expect.eq(name, "btw")
			provided_service = svc
		end,
		agent = {
			register_activity = function(_, name, fn)
				expect.eq(name, "btw")
				activity_provider = fn
			end,
			prompt = function(_, text, opts)
				agent_calls[#agent_calls + 1] = { method = "prompt", text = text, opts = opts }
				return { status = "started", turn_id = "turn-sent" }
			end,
			wait = function(_, turn_id)
				agent_calls[#agent_calls + 1] = { method = "wait", turn_id = turn_id }
				return { turn_id = turn_id, status = "completed", text = "answer" }
			end,
		},
		commands = {
			register = function()
				commands_registered = commands_registered + 1
			end,
		},
		conversations = {
			info = function()
				return conv_info
			end,
			start = function(_, opts)
				conv_calls[#conv_calls + 1] = { method = "start", opts = opts }
				if start_err then
					return nil, start_err
				end
				conv_info = {
					conversation_id = "side-1",
					ui_context_id = "ctx-1",
					session_id = "sess-main",
					selected = true,
					busy = false,
					model = "faux/echo",
					params = { reasoning_effort = "high" },
					message_count = 0,
				}
				return conv_info
			end,
			toggle = function()
				conv_calls[#conv_calls + 1] = { method = "toggle" }
				if toggle_err then
					return nil, toggle_err
				end
				if not conv_info then
					return nil, "No side conversation is open"
				end
				conv_info.selected = not conv_info.selected
				return { conversation_id = conv_info.conversation_id, selected = conv_info.selected }
			end,
			close = function()
				conv_calls[#conv_calls + 1] = { method = "close" }
				if not conv_info then
					return false
				end
				conv_info = nil
				return true
			end,
		},
		ui = {
			widget = function(_, name, def)
				widgets[name] = def
			end,
			status = function(_, name, def)
				statuses[name] = def
			end,
			invalidate = function(_, name)
				invalidations[#invalidations + 1] = name
			end,
			action = function(_, name, fn, opts)
				actions[name] = { fn = fn, opts = opts }
			end,
			key = function(_, key, action, desc)
				keys[key] = { action = action, desc = desc }
			end,
			-- In the UI's ordered submit chain, btw registers as handler "btw" at order 10.
			handler = function(_, kind, name, opts, fn)
				expect.eq(kind, "submit")
				expect.eq(name, "btw")
				expect.eq(opts.order, 10)
				events["input/submit"] = events["input/submit"] or {}
				events["input/submit"][#events["input/submit"] + 1] = fn
			end,
		},
	}

	local cfg = merge_config(cfg_overrides)
	plugin.apply(ctx, cfg)

	return {
		ctx = ctx,
		events = events,
		widgets = widgets,
		statuses = statuses,
		actions = actions,
		keys = keys,
		invalidations = invalidations,
		commands_registered = commands_registered,
		activity = activity_provider,
		service = provided_service,
		conv_calls = conv_calls,
		agent_calls = agent_calls,
		emit = function(name, payload)
			local last
			for _, fn in ipairs(events[name] or {}) do
				last = fn(payload)
			end
			return last
		end,
		set_info = function(info)
			conv_info = info
		end,
		set_errors = function(s_err, t_err)
			start_err = s_err
			toggle_err = t_err
		end,
		dispose = function()
			for _, fn in ipairs(dispose_callbacks) do
				fn()
			end
		end,
	}
end

describe("btw", function()
	local last_overlay, last_notice
	local orig_overlay, orig_notify

	before_each(function()
		last_overlay, last_notice = nil, nil
		orig_overlay = mare.ui.overlay
		orig_notify = mare.ui.notify
		mare.ui.overlay = function(title, body)
			last_overlay = { title = title, body = body }
		end
		mare.ui.notify = function(msg, level)
			last_notice = { msg = msg, level = level }
		end
	end)

	after_each(function()
		mare.ui.overlay = orig_overlay
		mare.ui.notify = orig_notify
	end)

	it("validates metadata, contracts, and config options", function()
		expect.eq(plugin.name, "btw")
		expect.eq(type(plugin.contracts.btw), "table")
		expect.eq(#plugin.provide, 1)
		expect.eq(plugin.provide[1], "btw")

		expect.eq(plugin.config_schema.show_parked_status.type, "boolean")
		expect.eq(plugin.config_schema.max_turns.min, 1)
		expect.eq(plugin.config_schema.max_turns.max, 1000)
		expect.eq(plugin.config_schema.max_output_bytes.min, 256)
		expect.eq(plugin.config_schema.max_output_bytes.max, 1048576)
		expect.eq(plugin.config_schema.max_transcript_bytes.min, 256)
		expect.eq(plugin.config_schema.max_transcript_bytes.max, 4194304)
	end)

	it("registers defaults, handles closed state, streaming, projection, truncation, and max_turns", function()
		local h = make_harness({ max_turns = 2, max_output_bytes = 256 })
		expect.eq(h.commands_registered, 0)
		expect.truthy(h.actions["btw.toggle"] and h.actions["btw.view"] and h.actions["btw.close"])
		expect.truthy(h.widgets["btw:parked"] and h.statuses["btw"])

		local s0 = h.service.status()
		expect.eq(s0.open, false)
		expect.eq(s0.selected, false)
		expect.eq(s0.parked, false)
		expect.eq(s0.turn_count, 0)
		expect.eq(h.service.transcript().open, false)
		expect.eq(h.activity(), nil)
		expect.eq(#h.widgets["btw:parked"].render(100, 1).items, 0)
		expect.eq(h.statuses["btw"].render(), nil)

		expect.eq(h.service.view(), false)
		expect.truthy(last_notice)
		expect.eq(last_notice.level, "info")

		h.set_info({
			conversation_id = "side-1",
			ui_context_id = "ctx-1",
			session_id = "sess-main",
			selected = true,
			busy = true,
			model = "faux/side",
			params = { reasoning_effort = "low" },
			message_count = 1,
			turn_id = "t1",
			parent_status = { state = "working" },
		})
		h.emit("conversation/opened", { id = "side-1", session_id = "sess-main", model = "faux/side" })
		expect.eq(#h.widgets["btw:parked"].render(100, 1).items, 0)
		expect.eq(h.statuses["btw"].render(), nil)
		expect.eq(h.activity().open, true)
		expect.eq(h.activity().selected, true)
		expect.eq(h.activity().parked, false)

		h.emit("conversation/stream", {
			id = "side-stale",
			turn_id = "t9",
			event = { type = "text_delta", delta = "wrong" },
		})
		expect.eq(h.service.transcript().streaming, nil)

		h.emit("conversation/stream", {
			id = "side-1",
			turn_id = "t1",
			event = { type = "reasoning_delta", delta = "reasoning with " .. SECRET },
		})
		h.emit("conversation/stream", {
			id = "side-1",
			turn_id = "t1",
			event = { type = "text_delta", delta = "answer " .. SECRET },
		})
		h.emit("conversation/stream", {
			id = "side-1",
			turn_id = "t1",
			event = { type = "tool_start", call = { id = "call-1", name = "read" } },
		})
		local long_out = string.rep("a", 300) .. "TAIL_" .. SECRET
		h.emit("conversation/stream", {
			id = "side-1",
			turn_id = "t1",
			event = { type = "tool_output", partial = { output = long_out } },
		})
		h.emit("conversation/stream", {
			id = "side-1",
			turn_id = "t1",
			event = { type = "tool_result", result = { is_error = false } },
		})

		local tr_streaming = h.service.transcript()
		expect.eq(tr_streaming.streaming.text, expected_projected("answer " .. SECRET))
		expect.eq(tr_streaming.streaming.reasoning, expected_projected("reasoning with " .. SECRET))
		expect.eq(tr_streaming.streaming.tools[1].name, "read")
		expect.eq(tr_streaming.streaming.tools[1].done, true)
		expect.truthy(#tr_streaming.streaming.tools[1].output <= 256)
		expect.truthy(tr_streaming.streaming.tools[1].output:find("TAIL_", 1, true))
		expect.eq(
			tr_streaming.streaming.tools[1].output,
			mare.text.cut(expected_projected(long_out), 256, { keep = "tail", unit = "bytes" })
		)

		h.emit("conversation/settled", { id = "side-1", turn_id = "t1" })
		expect.eq(h.service.transcript().streaming, nil)
		expect.eq(#h.service.transcript().turns, 1)

		h.emit("conversation/stream", {
			id = "side-1",
			turn_id = "t2",
			event = { type = "text_delta", delta = "turn two" },
		})
		h.emit("conversation/settled", { id = "side-1", turn_id = "t2" })
		h.emit("conversation/settled", { id = "side-1", turn_id = "t3", error = "err " .. SECRET })

		local tr_bounded = h.service.transcript()
		expect.eq(#tr_bounded.turns, 2)
		expect.eq(tr_bounded.turns[1].turn_id, "t2")
		expect.eq(tr_bounded.turns[1].text, "turn two")
		expect.eq(tr_bounded.turns[2].turn_id, "t3")
		expect.eq(tr_bounded.turns[2].error, expected_projected("err " .. SECRET))

		h.set_info({
			conversation_id = "side-1",
			ui_context_id = "ctx-1",
			session_id = "sess-main",
			selected = false,
			busy = true,
			model = "faux/side",
			parent_status = { state = "streaming", detail = "read" },
		})
		h.emit("conversation/changed", {
			id = "side-1",
			session_id = "sess-main",
			selected = false,
			parent_status = { state = "streaming", detail = "read" },
		})
		local st_parked = h.service.status()
		expect.eq(st_parked.parked, true)
		expect.eq(st_parked.selected, false)
		expect.eq(st_parked.busy, true)
		expect.eq(h.activity().parked, true)
		expect.eq(h.activity().busy, true)

		local lines = h.widgets["btw:parked"].render(120, 1)
		expect.eq(#lines.items, 1)
		local line_json = mare.json.encode(lines)
		expect.truthy(line_json:find("Side parked", 1, true))
		expect.truthy(line_json:find("busy", 1, true))
		expect.truthy(line_json:find("parent streaming (read)", 1, true))
		expect.truthy(line_json:find("/side close to discard", 1, true))
		expect.falsy(line_json:find("/side back to resume", 1, true))
		expect.eq(#h.widgets["btw:parked"].render(120, 0).items, 0)
		expect.truthy(mare.json.encode(h.statuses["btw"].render()):find("side busy", 1, true))

		last_overlay = nil
		expect.eq(h.service.view(), true)
		expect.eq(last_overlay.title, "Side conversation · faux/side")
		local body_json = mare.json.encode(last_overlay.body)
		expect.truthy(body_json:find("Model: `faux/side`", 1, true))
		expect.truthy(body_json:find("Parent: `streaming` (read)", 1, true))
		expect.truthy(body_json:find("turn two", 1, true))
		expect.truthy(body_json:find(expected_projected("err " .. SECRET), 1, true))

		expect.error(function()
			h.service.ask(nil, nil, 123)
		end)
		expect.error(function()
			h.service.ask(nil, nil, "ok", "bad-opts")
		end)
		local res1 = h.service.ask(nil, nil, "follow up", { reasoning_effort = "medium" })
		expect.eq(res1.turn_id, "turn-sent")
		expect.eq(res1.status, "completed")
		expect.eq(h.conv_calls[#h.conv_calls].method, "toggle")
		expect.eq(h.agent_calls[#h.agent_calls - 1].method, "prompt")
		expect.eq(h.agent_calls[#h.agent_calls - 1].text, "follow up")
		expect.eq(h.agent_calls[#h.agent_calls].method, "wait")
		expect.eq(h.agent_calls[#h.agent_calls].turn_id, "turn-sent")

		local res2 = h.service.ask(nil, nil, "fresh", { replace = true })
		expect.eq(res2.turn_id, "turn-sent")
		expect.eq(h.conv_calls[#h.conv_calls - 1].method, "close")
		expect.eq(h.conv_calls[#h.conv_calls].method, "start")
		expect.eq(h.agent_calls[#h.agent_calls - 1].method, "prompt")
		expect.eq(h.agent_calls[#h.agent_calls - 1].text, "fresh")
		expect.eq(h.agent_calls[#h.agent_calls].method, "wait")

		h.actions["btw.close"].fn()
		expect.eq(h.service.status().open, false)
		h.emit("conversation/closed", { id = "side-1" })
		expect.eq(h.activity(), nil)

		last_notice = nil
		h.actions["btw.toggle"].fn()
		expect.truthy(last_notice)
		expect.eq(last_notice.level, "info")

		h.set_errors(nil, "No side conversation is open")
		local ok_tog, err_tog = pcall(h.service.toggle)
		expect.falsy(ok_tog)
		expect.eq(type(err_tog), "table")
		expect.eq(err_tog.code, "btw.btw_unavailable")
		h.set_errors(nil, nil)

		last_notice = nil
		h.actions["btw.close"].fn()
		expect.truthy(last_notice)
		expect.truthy(last_notice.msg:find("No side conversation", 1, true))

		h.set_errors("boom start", nil)
		local err_res = h.service.ask(nil, nil, "x")
		expect.eq(err_res.error, "boom start")
		h.set_errors(nil, nil)
	end)

	it("resets on session change/dispose, respects show_parked_status=false, and isolates side commands", function()
		local h = make_harness()
		h.set_info({ conversation_id = "side-2", selected = false, busy = false, model = "faux/x" })
		h.emit("conversation/opened", { id = "side-2", model = "faux/x" })
		h.emit(
			"conversation/stream",
			{ id = "side-2", turn_id = "t1", event = { type = "text_delta", delta = "keep" } }
		)
		expect.eq(h.service.transcript().streaming.text, "keep")
		h.set_info(nil)
		h.emit("session/changed", {})
		expect.eq(h.service.transcript().open, false)
		expect.eq(h.service.status().open, false)

		h.set_info({ conversation_id = "side-3", selected = false, busy = false, model = "faux/x" })
		h.emit("conversation/opened", { id = "side-3", model = "faux/x" })
		h.dispose()
		h.set_info(nil)
		expect.eq(h.service.transcript().open, false)

		local h_quiet = make_harness({ show_parked_status = false })
		expect.eq(next(h_quiet.keys), nil)
		h_quiet.set_info({ conversation_id = "side-4", selected = false, busy = false, model = "faux/x" })
		h_quiet.emit("conversation/opened", { id = "side-4", model = "faux/x" })
		expect.eq(#h_quiet.widgets["btw:parked"].render(100, 1).items, 0)
		expect.eq(h_quiet.statuses["btw"].render(), nil)

		local h_settled = make_harness({ max_turns = 10, max_transcript_bytes = 4096 })
		h_settled.set_info({ conversation_id = "side-ns", selected = true, busy = false, model = "faux/echo" })
		h_settled.emit("conversation/opened", { id = "side-ns", model = "faux/echo" })
		h_settled.emit("input/submit", { text = "user question " .. SECRET })
		h_settled.emit("conversation/settled", {
			id = "side-ns",
			turn_id = "t-ns-1",
			text = "final answer without chunks " .. SECRET,
		})
		local tr_ns = h_settled.service.transcript()
		expect.eq(#tr_ns.turns, 1)
		expect.eq(tr_ns.turns[1].prompt, expected_projected("user question " .. SECRET))
		expect.eq(tr_ns.turns[1].text, expected_projected("final answer without chunks " .. SECRET))
		last_overlay = nil
		expect.eq(h_settled.service.view(), true)
		local overlay_json = mare.json.encode(last_overlay.body)
		expect.truthy(overlay_json:find(expected_projected("user question " .. SECRET), 1, true))
		expect.truthy(overlay_json:find(expected_projected("final answer without chunks " .. SECRET), 1, true))

		h_settled.emit("input/submit", { text = "second question" })
		h_settled.emit("conversation/settled", {
			id = "side-ns",
			session_id = "sess-main",
			turn_id = "t-ns-2",
			text = "second answer",
		})
		tr_ns = h_settled.service.transcript()
		expect.eq(#tr_ns.turns, 2)
		expect.eq(tr_ns.turns[2].prompt, "second question")
		expect.eq(tr_ns.turns[2].text, "second answer")

		for _, blocked in ipairs({ "/retry", "/undo", "/compact", "/new", "/fork", "/resume", "/model foo", "/clear" }) do
			last_notice = nil
			local ev = { text = blocked }
			expect.eq(h_settled.emit("input/submit", ev), true) -- stops ui's submit chain
			expect.eq(ev.handled, true)
			expect.truthy(ev.command_result)
			expect.eq(ev.command_result.status, "rejected")
			expect.truthy(last_notice)
			expect.eq(last_notice.level, "warning")
		end
		for _, allowed in ipairs({ "/side close", "/btw close", "/help" }) do
			local ev = { text = allowed }
			expect.eq(h_settled.emit("input/submit", ev), false) -- ui keeps routing it
			expect.falsy(ev.handled)
		end

		h_settled.emit(
			"conversation/stream",
			{ id = "side-ns", turn_id = "t-iso-1", event = { type = "text_delta", delta = "one " } }
		)
		h_settled.emit(
			"conversation/stream",
			{ id = "side-ns", turn_id = "t-iso-2", event = { type = "text_delta", delta = "two " } }
		)
		h_settled.emit(
			"conversation/stream",
			{ id = "side-ns", turn_id = "t-iso-1", event = { type = "text_delta", delta = "done" } }
		)
		h_settled.emit("conversation/settled", { id = "side-ns", turn_id = "t-iso-1" })
		h_settled.emit("conversation/settled", { id = "side-ns", turn_id = "t-iso-2" })
		tr_ns = h_settled.service.transcript()
		expect.eq(tr_ns.turns[3].turn_id, "t-iso-1")
		expect.eq(tr_ns.turns[3].text, "one done")
		expect.eq(tr_ns.turns[4].turn_id, "t-iso-2")
		expect.eq(tr_ns.turns[4].text, "two ")
	end)

	it("enforces byte budgets on text, reasoning, errors, and prompt queues with FIFO alignment", function()
		local h_budget = make_harness({ max_turns = 50, max_transcript_bytes = 256 })
		h_budget.set_info({ conversation_id = "side-b", selected = true, busy = true, model = "faux/echo" })
		h_budget.emit("conversation/opened", { id = "side-b", model = "faux/echo" })
		h_budget.emit("conversation/stream", {
			id = "side-b",
			turn_id = "tb-1",
			event = { type = "reasoning_delta", delta = string.rep("T", 200) },
		})
		h_budget.emit("conversation/stream", {
			id = "side-b",
			turn_id = "tb-1",
			event = { type = "text_delta", delta = string.rep("A", 200) },
		})
		h_budget.emit("conversation/settled", { id = "side-b", turn_id = "tb-1" })
		local tr_b = h_budget.service.transcript()
		expect.eq(tr_b.truncated, true)
		local total_b = #(tr_b.turns[1].reasoning or "") + #(tr_b.turns[1].text or "")
		expect.truthy(total_b <= 256)
		last_overlay = nil
		expect.eq(h_budget.service.view(), true)
		expect.truthy(mare.json.encode(last_overlay.body):find("truncated to byte budget", 1, true))

		local h_err_budget = make_harness({ max_turns = 50, max_transcript_bytes = 256 })
		h_err_budget.set_info({ conversation_id = "side-eb", selected = true, busy = true, model = "faux/echo" })
		h_err_budget.emit("conversation/opened", { id = "side-eb", model = "faux/echo" })
		h_err_budget.emit("conversation/settled", {
			id = "side-eb",
			turn_id = "teb-1",
			error = string.rep("E", 4096),
		})
		local tr_eb = h_err_budget.service.transcript()
		expect.eq(tr_eb.truncated, true)
		expect.truthy(#(tr_eb.turns[1].error or "") <= 256)

		local h_tp = make_harness({ max_turns = 50, max_transcript_bytes = 256 })
		h_tp.set_info({ conversation_id = "side-tp", selected = true, busy = true, model = "faux/echo" })
		h_tp.emit("conversation/opened", { id = "side-tp", model = "faux/echo" })
		h_tp.service.ask(nil, nil, string.rep("P", 4096))
		h_tp.emit("conversation/settled", { id = "side-tp", turn_id = "turn-sent", text = string.rep("R", 100) })
		local tr_tp = h_tp.service.transcript()
		expect.eq(tr_tp.truncated, true)
		local tp_bytes = #(tr_tp.turns[1].prompt or "") + #(tr_tp.turns[1].text or "")
		expect.truthy(tp_bytes <= 256)

		local pq_listeners = {}
		local pq_info = { conversation_id = "side-pq", selected = true, busy = true, model = "faux/echo" }
		local pq_ctx = {
			conversations = {
				info = function()
					return pq_info
				end,
			},
			on = function(_, name, fn)
				pq_listeners[name] = fn
			end,
		}
		local pq_tracker = tracker_mod(pq_ctx, { max_turns = 50, max_transcript_bytes = 256 })
		pq_listeners["conversation/opened"]({ id = "side-pq", model = "faux/echo" })
		pq_tracker.queue_prompt(string.rep("Q", 4096))
		pq_listeners["conversation/settled"]({ id = "side-pq", turn_id = "tpq-1", text = string.rep("R", 100) })
		local tr_pq = pq_tracker.transcript()
		expect.eq(tr_pq.truncated, true)
		local pq_bytes = #(tr_pq.turns[1].prompt or "") + #(tr_pq.turns[1].text or "")
		expect.truthy(pq_bytes <= 256)

		local lz100_listeners = {}
		local lz100_info = { conversation_id = "side-lz100", selected = true, busy = true, model = "faux/echo" }
		local lz100_ctx = {
			conversations = {
				info = function()
					return lz100_info
				end,
			},
			on = function(_, name, fn)
				lz100_listeners[name] = fn
			end,
		}
		local lz100_tracker = tracker_mod(lz100_ctx, { max_turns = 50, max_transcript_bytes = 256 })
		lz100_listeners["conversation/opened"]({ id = "side-lz100", model = "faux/echo" })
		local prompt_a = string.rep("A", 256)
		local prompt_b = string.rep("B", 256)
		lz100_tracker.queue_prompt(prompt_a)
		lz100_tracker.queue_prompt(prompt_b)
		lz100_listeners["conversation/stream"]({
			id = "side-lz100",
			turn_id = "tlz-1",
			event = { type = "text_delta", delta = "" },
		})
		lz100_listeners["conversation/settled"]({ id = "side-lz100", turn_id = "tlz-1", text = "" })
		lz100_listeners["conversation/settled"]({ id = "side-lz100", turn_id = "tlz-2", text = "" })
		local tr_lz100 = lz100_tracker.transcript()
		expect.eq(tr_lz100.truncated, true)
		expect.eq(#tr_lz100.turns, 2)
		expect.eq(tr_lz100.turns[1].prompt, nil)
		expect.eq(tr_lz100.turns[2].prompt, prompt_b)
	end)

	it("compacts tombstones and bounds prompt_queue memory under max_turns", function()
		local lz139_listeners = {}
		local lz139_info = { conversation_id = "side-lz139", selected = true, busy = true, model = "faux/echo" }
		local lz139_ctx = {
			conversations = {
				info = function()
					return lz139_info
				end,
			},
			on = function(_, name, fn)
				lz139_listeners[name] = fn
			end,
		}
		local lz139_tracker = tracker_mod(lz139_ctx, { max_turns = 8, max_transcript_bytes = 512 })
		lz139_listeners["conversation/opened"]({ id = "side-lz139", model = "faux/echo" })
		lz139_listeners["conversation/settled"]({
			id = "side-lz139",
			turn_id = "t139-seed",
			text = string.rep("D", 256),
		})
		for i = 1, 100 do
			local keep_p = ("keep-" .. tostring(i) .. "-" .. string.rep("K", 256)):sub(1, 256)
			lz139_tracker.queue_prompt(string.rep("X", 256))
			lz139_tracker.queue_prompt(keep_p)
			lz139_listeners["conversation/settled"]({ id = "side-lz139", turn_id = "t139-a-" .. i, text = "" })
			lz139_listeners["conversation/settled"]({ id = "side-lz139", turn_id = "t139-b-" .. i, text = "" })
			local tr_step = lz139_tracker.transcript()
			local last_two = tr_step.turns
			expect.eq(last_two[#last_two - 1].prompt, nil)
			expect.eq(last_two[#last_two].prompt, keep_p)
		end

		for i = 1, 50 do
			lz139_tracker.queue_prompt(string.rep("Y", 512))
			lz139_listeners["conversation/settled"]({
				id = "side-lz139",
				turn_id = "t139-exp-" .. i,
				prompt = "explicit-" .. i,
				text = "",
			})
		end
		lz139_tracker.queue_prompt("after-cap")
		local found_after_cap = false
		for i = 1, 9 do
			lz139_listeners["conversation/settled"]({ id = "side-lz139", turn_id = "t139-drain-" .. i, text = "" })
			local tr_drain = lz139_tracker.transcript()
			if tr_drain.turns[#tr_drain.turns].prompt == "after-cap" then
				found_after_cap = true
				break
			end
		end
		expect.truthy(found_after_cap)

		local lz157_listeners = {}
		local lz157_info = { conversation_id = "side-lz157", selected = true, busy = true, model = "faux/echo" }
		local lz157_ctx = {
			conversations = {
				info = function()
					return lz157_info
				end,
			},
			on = function(_, name, fn)
				lz157_listeners[name] = fn
			end,
		}
		local lz157_tracker = tracker_mod(lz157_ctx, { max_turns = 2, max_transcript_bytes = 256 })
		lz157_listeners["conversation/opened"]({ id = "side-lz157", model = "faux/echo" })

		local p157_1 = ("1-" .. string.rep("A", 256)):sub(1, 256)
		local p157_2 = ("2-" .. string.rep("B", 256)):sub(1, 256)
		local p157_3 = ("3-" .. string.rep("C", 256)):sub(1, 256)
		lz157_tracker.queue_prompt(p157_1)
		lz157_tracker.queue_prompt(p157_2)
		lz157_tracker.queue_prompt(p157_3)

		lz157_listeners["conversation/settled"]({ id = "side-lz157", turn_id = "t157-1", text = "" })
		local tr157_1 = lz157_tracker.transcript()
		expect.eq(#tr157_1.turns, 1)
		expect.eq(tr157_1.turns[1].prompt, nil)

		lz157_listeners["conversation/settled"]({ id = "side-lz157", turn_id = "t157-2", text = "" })
		local tr157_2 = lz157_tracker.transcript()
		expect.eq(#tr157_2.turns, 2)
		expect.eq(tr157_2.turns[2].prompt, nil)

		lz157_listeners["conversation/settled"]({ id = "side-lz157", turn_id = "t157-3", text = "" })
		local tr157_3 = lz157_tracker.transcript()
		expect.eq(#tr157_3.turns, 2)
		expect.eq(tr157_3.turns[1].turn_id, "t157-2")
		expect.eq(tr157_3.turns[1].prompt, nil)
		expect.eq(tr157_3.turns[2].turn_id, "t157-3")
		expect.eq(tr157_3.turns[2].prompt, p157_3)

		collectgarbage("collect")
		local mem_before = collectgarbage("count")
		for i = 1, 500 do
			lz157_tracker.queue_prompt(string.rep("Y", 512))
			lz157_listeners["conversation/settled"]({
				id = "side-lz157",
				turn_id = "t157-exp-" .. i,
				prompt = "explicit-" .. i,
				text = "",
			})
		end
		collectgarbage("collect")
		local mem_after = collectgarbage("count")
		expect.truthy(mem_after - mem_before < 64)

		lz157_tracker.queue_prompt("after-exp-1")
		lz157_tracker.queue_prompt("after-exp-2")
		lz157_listeners["conversation/settled"]({ id = "side-lz157", turn_id = "t157-after-1", text = "" })
		expect.eq(lz157_tracker.transcript().turns[2].prompt, "after-exp-1")
		lz157_listeners["conversation/settled"]({ id = "side-lz157", turn_id = "t157-after-2", text = "" })
		expect.eq(lz157_tracker.transcript().turns[2].prompt, "after-exp-2")
	end)

	it(
		"tracks incremental byte budget accurately across tool_output overwrites, prompt transfer, and multi-turn eviction",
		function()
			local listeners = {}
			local info = { conversation_id = "side-inc", selected = true, busy = true, model = "faux/echo" }
			local t_ctx = {
				conversations = {
					info = function()
						return info
					end,
				},
				on = function(_, name, fn)
					listeners[name] = fn
				end,
			}
			local tr = tracker_mod(t_ctx, { max_turns = 50, max_transcript_bytes = 120, max_output_bytes = 200 })
			listeners["conversation/opened"]({ id = "side-inc", model = "faux/echo" })

			-- tool_output replace must subtract old output length before adding new length.
			listeners["conversation/stream"]({
				id = "side-inc",
				turn_id = "ti-1",
				event = { type = "tool_start", call = { id = "c1", name = "bash" } },
			})
			listeners["conversation/stream"]({
				id = "side-inc",
				turn_id = "ti-1",
				event = { type = "tool_output", partial = { output = string.rep("O", 100) } },
			})
			-- Replace 100 bytes with 10 bytes: total cached should drop back to 10 (not 110!).
			listeners["conversation/stream"]({
				id = "side-inc",
				turn_id = "ti-1",
				event = { type = "tool_output", partial = { output = string.rep("X", 10) } },
			})
			-- Now add 100 bytes of text: 10 + 100 = 110 <= 120, so NO truncation should occur!
			for i = 1, 10 do
				listeners["conversation/stream"]({
					id = "side-inc",
					turn_id = "ti-1",
					event = { type = "text_delta", delta = string.rep("A", 10) },
				})
			end
			local snap1 = tr.transcript()
			expect.eq(snap1.truncated, false)
			expect.eq(snap1.streaming.text, string.rep("A", 100))
			expect.eq(snap1.streaming.tools[1].output, string.rep("X", 10))
			listeners["conversation/settled"]({ id = "side-inc", turn_id = "ti-1" })

			-- Detached snapshot: mutating snap1 does not affect settled turn.
			snap1.streaming.text = "mutated"
			expect.eq(tr.transcript().turns[1].text, string.rep("A", 100))

			-- Queue prompt preserved across conversation/opened must keep accurate byte count.
			listeners["conversation/closed"]({})
			tr.queue_prompt(string.rep("Q", 80))
			info = { conversation_id = "side-inc-2", selected = true, busy = true, model = "faux/echo" }
			listeners["conversation/opened"]({ id = "side-inc-2", model = "faux/echo" })
			-- Add 50 bytes of text -> 80 + 50 = 130 > 120 -> prompt_queue trimmed/dropped to stay <= 120.
			listeners["conversation/stream"]({
				id = "side-inc-2",
				turn_id = "ti-2",
				event = { type = "text_delta", delta = string.rep("B", 50) },
			})
			listeners["conversation/settled"]({ id = "side-inc-2", turn_id = "ti-2" })
			local snap2 = tr.transcript()
			expect.eq(snap2.truncated, true)
			local sum2 = #(snap2.turns[1].prompt or "") + #(snap2.turns[1].text or "")
			expect.truthy(sum2 <= 120)

			-- Multi-turn eviction via head/tail queue preserves order and byte cap.
			for i = 1, 5 do
				listeners["conversation/stream"]({
					id = "side-inc-2",
					turn_id = "ti-m-" .. i,
					event = { type = "text_delta", delta = string.rep(tostring(i), 50) },
				})
				listeners["conversation/settled"]({ id = "side-inc-2", turn_id = "ti-m-" .. i })
			end
			local snap3 = tr.transcript()
			expect.eq(snap3.truncated, true)
			local sum3 = 0
			for _, t in ipairs(snap3.turns) do
				sum3 = sum3 + #(t.prompt or "") + #(t.text or "") + #(t.reasoning or "") + #(t.error or "")
			end
			expect.truthy(sum3 <= 120)
			expect.eq(snap3.turns[#snap3.turns].turn_id, "ti-m-5")

			-- Interleaved enqueue/settle must never leave stale prompt bytes after sparse queue compaction.
			local sp_listeners = {}
			local sp_info = { conversation_id = "side-sparse", selected = true, busy = true, model = "faux/echo" }
			local sp_ctx = {
				conversations = {
					info = function()
						return sp_info
					end,
				},
				on = function(_, name, fn)
					sp_listeners[name] = fn
				end,
			}
			local sp_tr = tracker_mod(sp_ctx, { max_turns = 50, max_transcript_bytes = 1024, max_output_bytes = 512 })
			sp_listeners["conversation/opened"]({ id = "side-sparse", model = "faux/echo" })
			for i = 1, 10 do
				sp_tr.queue_prompt(string.rep("P", 100))
				sp_listeners["conversation/settled"]({ id = "side-sparse", turn_id = "sp-" .. i, text = "" })
			end
			-- Clear settled turns via conversation/closed? No, keep checking within fresh open or directly:
			-- Enqueue 5 prompts, settle 1, enqueue 4 more, settle rest -> sparse head/tail gaps.
			sp_listeners["conversation/closed"]({})
			sp_info = { conversation_id = "side-sparse-2", selected = true, busy = true, model = "faux/echo" }
			sp_listeners["conversation/opened"]({ id = "side-sparse-2", model = "faux/echo" })
			sp_tr.queue_prompt(string.rep("A", 100))
			sp_tr.queue_prompt(string.rep("B", 100))
			sp_listeners["conversation/settled"]({ id = "side-sparse-2", turn_id = "g-1", text = "" })
			sp_tr.queue_prompt(string.rep("C", 100))
			sp_tr.queue_prompt(string.rep("D", 100))
			sp_tr.queue_prompt(string.rep("E", 100))
			sp_tr.queue_prompt(string.rep("F", 100))
			sp_listeners["conversation/settled"]({ id = "side-sparse-2", turn_id = "g-2", text = "" })
			sp_listeners["conversation/settled"]({ id = "side-sparse-2", turn_id = "g-3", text = "" })
			sp_listeners["conversation/settled"]({ id = "side-sparse-2", turn_id = "g-4", text = "" })
			sp_listeners["conversation/settled"]({ id = "side-sparse-2", turn_id = "g-5", text = "" })
			sp_listeners["conversation/settled"]({ id = "side-sparse-2", turn_id = "g-6", text = "" })
			local pre_snap = sp_tr.transcript()
			expect.eq(#pre_snap.turns, 6)
			expect.eq(pre_snap.turns[6].prompt, string.rep("F", 100))
			-- Now reset via closed + opened with no queued prompts, or evict old turns via 900B stream!
			-- Streaming 900B with 1,024B cap must retain ALL 900B (evicting old turns, no phantom prompt bytes).
			sp_listeners["conversation/stream"]({
				id = "side-sparse-2",
				turn_id = "g-stream",
				event = { type = "text_delta", delta = string.rep("Z", 900) },
			})
			sp_listeners["conversation/settled"]({ id = "side-sparse-2", turn_id = "g-stream" })
			local post_snap = sp_tr.transcript()
			expect.eq(#post_snap.turns[#post_snap.turns].text, 900)
		end
	)

	it("does not enqueue !cmd or failed /btw starts and prefers ev.prompt on settle", function()
		local h = make_harness()
		-- Rejected !cmd while side conversation is selected must NOT shift prompt_queue
		h.set_info({ conversation_id = "side-q", selected = true, busy = false, model = "faux/echo" })
		h.emit("conversation/opened", { id = "side-q", model = "faux/echo" })
		local bang_ev = { text = "!ls" }
		expect.eq(h.emit("input/submit", bang_ev), false)
		h.emit("input/submit", { text = "real prompt" })
		h.emit("conversation/settled", {
			id = "side-q",
			turn_id = "t-q-1",
			text = "reply 1",
		})
		local tr = h.service.transcript()
		expect.eq(#tr.turns, 1)
		expect.eq(tr.turns[1].prompt, "real prompt")

		-- Failed /btw start while no conversation is open must not leak into subsequent opened conversation
		h.emit("conversation/closed", {})
		h.set_info(nil)
		h.emit("input/submit", { text = "/btw failed start" })
		h.set_info({ conversation_id = "side-q2", selected = true, busy = false, model = "faux/echo" })
		h.emit("conversation/opened", { id = "side-q2", model = "faux/echo" })
		h.emit("conversation/settled", {
			id = "side-q2",
			turn_id = "t-q2-1",
			prompt = "authoritative prompt",
			text = "reply 2",
		})
		local tr2 = h.service.transcript()
		expect.eq(#tr2.turns, 1)
		expect.eq(tr2.turns[1].prompt, "authoritative prompt")

		-- Core ev.prompt overrides queued prompt
		h.emit("input/submit", { text = "queued copy" })
		h.emit("conversation/settled", {
			id = "side-q2",
			turn_id = "t-q2-2",
			prompt = "canonical " .. SECRET,
			text = "ok",
		})
		local tr3 = h.service.transcript()
		expect.eq(tr3.turns[2].prompt, expected_projected("canonical " .. SECRET))
	end)

	it("does not subscribe to unpublished ui/context-* events", function()
		local h = make_harness()
		expect.eq(h.events["ui/context-focused"], nil)
		expect.eq(h.events["ui/context-closed"], nil)
		local manifest = assert(mare.fs.read("plugins/btw/mare-plugin.toml"))
		expect.falsy(manifest:find("ui/context-focused", 1, true))
		expect.falsy(manifest:find("ui/context-closed", 1, true))
	end)
end)
