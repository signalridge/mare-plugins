local support = assert(load(mare.fs.read("tests/specs/support.lua"), "@tests/specs/support.lua"))()
local H = support.load_lua("tests/specs/presets_support.lua")

local describe = mare.test.describe
local it = mare.test.it
local before_each = mare.test.before_each
local after_each = mare.test.after_each
local expect = mare.test.expect

local async_defs = {
	a = { model = "model-a", system = "PROMPT_A {{model}}", tools = { "read" } },
	b = { model = "model-b", system = "PROMPT_B", tools = { "bash" } },
}

local async_models = {
	["model-a"] = { ref = "model-a", id = "id-a" },
	["model-b"] = { ref = "model-b", id = "id-b" },
}

describe("presets lifecycle", function()
	local orig_connected, orig_select, orig_notify, orig_channel, orig_state_update

	before_each(function()
		orig_connected = mare.ui.connected
		orig_select = mare.ui.select
		orig_notify = mare.ui.notify
		orig_channel = mare.task.channel
		orig_state_update = mare.state.update
		H.clear_persisted_state()
	end)

	after_each(function()
		mare.ui.connected = orig_connected
		mare.ui.select = orig_select
		mare.ui.notify = orig_notify
		mare.task.channel = orig_channel
		mare.state.update = orig_state_update
		H.clear_persisted_state()
	end)

	it("serializes concurrent selections via mare.task.channel without interleaving model and prompt", function()
		local conc = H.fixture(async_defs, nil, { models = async_models })
		local paused_tx, paused_rx = mare.task.channel()
		local gate_tx, gate_rx = mare.task.channel()
		local done_a_tx, done_a_rx = mare.task.channel()
		local done_b_tx, done_b_rx = mare.task.channel()
		local paused_on_a = false

		conc.on_set_model = function(ref)
			if ref == "model-a" then
				paused_on_a = true
				paused_tx:send(true)
				gate_rx:recv()
			end
		end

		mare.task.spawn(function()
			done_a_tx:send(table.pack(conc.service.select(nil, nil, "a")))
		end)
		expect.truthy(paused_rx:recv())
		expect.truthy(paused_on_a)

		mare.task.spawn(function()
			done_b_tx:send(table.pack(conc.service.select(nil, nil, "b")))
		end)
		mare.task.sleep(10)

		-- While task_a is yielded inside set_model("model-a"), task_b MUST NOT have changed model or prompt.
		expect.eq(conc.model.ref, "model-a")
		expect.eq(#conc.calls, 1)
		expect.eq(conc.service.current().id, nil)
		expect.eq(conc:prompt(), "base")

		gate_tx:send(true)
		local res_a = done_a_rx:recv()
		local res_b = done_b_rx:recv()
		expect.eq(res_a[1], true)
		expect.eq(res_b[1], true)
		expect.eq(conc.service.current().id, "b")
		expect.eq(conc.model.ref, "model-b")
		expect.truthy(conc:prompt():find("PROMPT_B", 1, true))
		expect.falsy(conc:prompt():find("PROMPT_A", 1, true))
		expect.eq(#conc.constraint(), 1)
		expect.eq(conc.constraint()[1], "bash")

		local sel_events = {}
		for _, ev in ipairs(conc.events) do
			if ev.event == "presets/selection-changed" then
				sel_events[#sel_events + 1] = ev
			end
		end
		expect.eq(#sel_events, 2)
		expect.eq(sel_events[1].payload.id, "a")
		expect.eq(sel_events[1].model, "model-a")
		expect.truthy(sel_events[1].prompt:find("PROMPT_A", 1, true))
		expect.falsy(sel_events[1].prompt:find("PROMPT_B", 1, true))
		expect.eq(sel_events[1].tools[1], "read")

		expect.eq(sel_events[2].payload.id, "b")
		expect.eq(sel_events[2].model, "model-b")
		expect.truthy(sel_events[2].prompt:find("PROMPT_B", 1, true))
		expect.falsy(sel_events[2].prompt:find("PROMPT_A", 1, true))
		expect.eq(sel_events[2].tools[1], "bash")
	end)

	it("serializes concurrent select + clear and rejects queued selection on generation change", function()
		local conc_clear = H.fixture(async_defs, nil, { models = async_models })
		local paused_tx, paused_rx = mare.task.channel()
		local clear_tx, clear_rx = mare.task.channel()
		local d1_tx, d1_rx = mare.task.channel()
		local d2_tx, d2_rx = mare.task.channel()

		conc_clear.on_set_model = function(ref)
			if ref == "model-a" then
				paused_tx:send(true)
				clear_rx:recv()
			end
		end

		mare.task.spawn(function()
			d1_tx:send(table.pack(conc_clear.service.select(nil, nil, "a")))
		end)
		expect.truthy(paused_rx:recv())
		mare.task.spawn(function()
			d2_tx:send(table.pack(conc_clear.service.select(nil, nil, "clear")))
		end)
		mare.task.sleep(10)
		clear_tx:send(true)
		local r1 = d1_rx:recv()
		local r2 = d2_rx:recv()
		expect.eq(r1[1], true)
		expect.eq(r2[1], true)
		expect.eq(conc_clear.service.current().id, nil)
		expect.eq(conc_clear:prompt(), "base")
		expect.eq(conc_clear.constraint(), nil)

		local conc_gen = H.fixture(async_defs, nil, { models = async_models })
		local gpaused_tx, gpaused_rx = mare.task.channel()
		local gen_tx, gen_rx = mare.task.channel()
		local dg1_tx, dg1_rx = mare.task.channel()
		local dg2_tx, dg2_rx = mare.task.channel()

		conc_gen.on_set_model = function(ref)
			if ref == "model-a" then
				gpaused_tx:send(true)
				gen_rx:recv()
			end
		end

		mare.task.spawn(function()
			dg1_tx:send(table.pack(pcall(conc_gen.service.select, nil, nil, "a")))
		end)
		expect.truthy(gpaused_rx:recv())
		mare.task.spawn(function()
			dg2_tx:send(table.pack(pcall(conc_gen.service.select, nil, nil, "b")))
		end)
		mare.task.sleep(10)

		conc_gen.generation = "next"
		conc_gen.hooks["session/changed"]({ reason = "resume" })
		gen_tx:send(true)
		local rg1 = dg1_rx:recv()
		local rg2 = dg2_rx:recv()
		-- Contract errors are raised instead of returned as nil and an error value.
		expect.eq(rg1[1], false)
		expect.eq(rg2[1], false)
		expect.eq(conc_gen.service.current().id, nil)
		expect.eq(conc_gen:prompt(), "base")
		expect.eq(conc_gen.constraint(), nil)
	end)

	it("falls back to pure-coroutine yield when mare.task.channel is absent", function()
		mare.task.channel = nil
		local fallback_conc = H.fixture(async_defs, nil, { models = async_models })
		fallback_conc.on_set_model = function(ref)
			if ref == "model-a" then
				coroutine.yield("yield-model-a")
			end
		end

		local co_a = coroutine.create(function()
			return fallback_conc.service.select(nil, nil, "a")
		end)
		local co_b = coroutine.create(function()
			return fallback_conc.service.select(nil, nil, "b")
		end)

		local ok_a, y_a = coroutine.resume(co_a)
		expect.truthy(ok_a)
		expect.eq(y_a, "yield-model-a")

		local ok_b = coroutine.resume(co_b)
		expect.truthy(ok_b)
		expect.eq(coroutine.status(co_b), "suspended")
		expect.eq(fallback_conc.model.ref, "model-a")
		expect.eq(fallback_conc.service.current().id, nil)

		local ok_a2, res_a = coroutine.resume(co_a)
		expect.truthy(ok_a2)
		expect.eq(res_a, true)
		expect.eq(coroutine.status(co_a), "dead")
		expect.eq(fallback_conc.service.current().id, "a")
		expect.eq(fallback_conc.model.ref, "model-a")

		local ok_b2, res_b = coroutine.resume(co_b)
		expect.truthy(ok_b2)
		expect.eq(res_b, true)
		expect.eq(coroutine.status(co_b), "dead")
		expect.eq(fallback_conc.service.current().id, "b")
		expect.eq(fallback_conc.model.ref, "model-b")
		expect.truthy(fallback_conc:prompt():find("PROMPT_B", 1, true))
		expect.eq(fallback_conc.constraint()[1], "bash")
	end)

	it("persists default and staged across reload/restart and auto-applies on new sessions only", function()
		local n9_defs = {
			a = { model = "model-a", system = "PROMPT_A", tools = { "read" }, order = 1 },
			b = { model = "model-b", system = "PROMPT_B", tools = { "bash" }, order = 2 },
			c = { system = "PROMPT_C", denylist = { "write" }, order = 3 },
		}
		local n9 = H.fixture(n9_defs, { default = "a" }, { models = async_models })
		expect.eq(n9.service.current().id, nil)
		n9.hooks["session/started"]({ resumed = false })
		expect.eq(n9.service.current().id, "a")
		expect.eq(n9.model.ref, "model-a")
		expect.truthy(n9:prompt():find("PROMPT_A", 1, true))
		expect.eq(#n9.constraint(), 1)
		expect.eq(n9.constraint()[1], "read")

		-- Explicit /preset clear does not re-apply default on the same session and does not roll back model.
		n9.command("clear")
		expect.eq(n9.service.current().id, nil)
		expect.eq(n9.model.ref, "model-a")
		expect.eq(n9:prompt(), "base")
		expect.eq(n9.constraint(), nil)

		-- Resumed session does not auto-apply default.
		n9.generation = "resumed-gen"
		n9.hooks["session/changed"]({ reason = "resume" })
		expect.eq(n9.service.current().id, nil)
		expect.eq(n9:prompt(), "base")
		n9.hooks["session/started"]({ resumed = true })
		expect.eq(n9.service.current().id, nil)
		expect.eq(n9:prompt(), "base")

		-- set_default persists across plugin reload/restart and auto-applies on session/new even while switching == true.
		expect.truthy(n9.service.set_default(nil, nil, "b"))
		n9.dispose()
		local n9_reloaded = H.fixture(n9_defs, { default = "a" }, { models = async_models })
		n9_reloaded.generation = "new-gen-1"
		n9_reloaded.switching = true
		n9_reloaded.hooks["session/changed"]({ reason = "new" })
		n9_reloaded.hooks["session/new"]()
		n9_reloaded.switching = false
		expect.eq(n9_reloaded.service.current().id, "b")
		expect.eq(n9_reloaded.model.ref, "model-b")
		expect.truthy(n9_reloaded:prompt():find("PROMPT_B", 1, true))
		expect.eq(#n9_reloaded.constraint(), 1)
		expect.eq(n9_reloaded.constraint()[1], "bash")

		-- stage persists across reload, is consumed once on next new session, and subsequent new session falls back to default.
		expect.truthy(n9_reloaded.service.stage(nil, nil, "c"))
		expect.eq(n9_reloaded.service.staged().id, "c")
		n9_reloaded.dispose()
		local n9_restarted = H.fixture(n9_defs, { default = "a" }, { models = async_models })
		expect.eq(n9_restarted.service.staged().id, "c")
		n9_restarted.hooks["session/started"]({ resumed = false })
		expect.eq(n9_restarted.service.current().id, "c")
		expect.eq(n9_restarted.service.staged().id, nil)
		expect.truthy(n9_restarted:prompt():find("PROMPT_C", 1, true))
		local n9_tools = n9_restarted.constraint()
		expect.eq(#n9_tools, 3)
		expect.eq(n9_tools[1], "read")
		expect.eq(n9_tools[2], "read_file")
		expect.eq(n9_tools[3], "bash")

		n9_restarted.generation = "new-gen-2"
		n9_restarted.switching = true
		n9_restarted.hooks["session/changed"]({ reason = "new" })
		n9_restarted.hooks["session/new"]()
		n9_restarted.switching = false
		expect.eq(n9_restarted.service.current().id, "b")
		expect.eq(n9_restarted.model.ref, "model-b")
		expect.truthy(n9_restarted:prompt():find("PROMPT_B", 1, true))
		expect.eq(n9_restarted.constraint()[1], "bash")

		-- Clearing set_default(nil) restores configured default.
		expect.truthy(n9_restarted.service.set_default(nil, nil, nil))
		n9_restarted.generation = "new-gen-3"
		n9_restarted.hooks["session/new"]()
		expect.eq(n9_restarted.service.current().id, "a")
		expect.eq(n9_restarted.model.ref, "model-a")
		expect.truthy(n9_restarted:prompt():find("PROMPT_A", 1, true))
		expect.eq(n9_restarted.constraint()[1], "read")
	end)

	it("handles /preset help, inspect, default, stage subcommands, badges, and idempotent selection/clear", function()
		local ui_cmd = H.fixture({
			alpha = { name = "Alpha", system = "ALPHA_PROMPT", tools = { "read" }, order = 1 },
			beta = { name = "Beta", system = "BETA_PROMPT", denylist = { "write" }, order = 2 },
			bad = { name = "Bad", model = false, system = "unused prompt", tools = { "read" }, order = 3 },
		})

		ui_cmd.command("help")
		expect.eq(ui_cmd:last().level, "info")
		expect.truthy(ui_cmd:last().text:find("Usage: /preset", 1, true))
		expect.eq(ui_cmd.command("help missing").status, "rejected")
		expect.eq(ui_cmd.command("help alpha"), nil)
		expect.truthy(ui_cmd:last().text:find("ALPHA_PROMPT", 1, true))

		-- Broken preset inspect and picker preview expose validation reason and raw declared fields.
		expect.eq(ui_cmd.command("inspect bad"), nil)
		local bad_notice = ui_cmd:last()
		expect.eq(bad_notice.level, "warning")
		expect.truthy(bad_notice.text:find("bad [broken]", 1, true))
		expect.truthy(bad_notice.text:find("Broken:", 1, true))
		expect.truthy(bad_notice.text:find("model: false", 1, true))
		expect.truthy(bad_notice.text:find("system: unused prompt", 1, true))

		-- /preset default and /preset stage subcommands + staged field in list()/picker/list output.
		expect.eq(ui_cmd.command("default beta"), nil)
		expect.eq(ui_cmd:last().text, "Default preset: beta")
		expect.eq(ui_cmd.command("default"), nil)
		expect.eq(ui_cmd:last().text, "Default preset: beta")
		expect.eq(ui_cmd.command("default bad").status, "rejected")

		expect.eq(ui_cmd.command("stage alpha"), nil)
		expect.eq(ui_cmd:last().text, "Staged preset for next session: alpha")
		expect.eq(ui_cmd.command("stage"), nil)
		expect.eq(ui_cmd:last().text, "Staged preset: alpha")
		expect.eq(ui_cmd.command("stage bad").status, "rejected")

		expect.eq(ui_cmd.command("list"), nil)
		local roster_text = ui_cmd:last().text
		expect.truthy(roster_text:find("bad [bad] — broken:", 1, true))
		expect.truthy(ui_cmd:last().text:find("Alpha [alpha] (staged)", 1, true))
		expect.truthy(ui_cmd:last().text:find("Beta [beta] (default)", 1, true))
		expect.truthy(roster_text:find("bad [bad]", 1, true) < roster_text:find("Alpha [alpha]", 1, true))
		expect.truthy(roster_text:find("Alpha [alpha]", 1, true) < roster_text:find("Beta [beta]", 1, true))

		ui_cmd.connected, ui_cmd.pick = true, nil
		expect.eq(ui_cmd.command("").status, "cancelled")
		expect.eq(ui_cmd.dialog.items[1].disabled, true)
		expect.match(mare.json.encode(ui_cmd.dialog.items[1].preview), "Broken:")
		expect.eq(ui_cmd.dialog.items[2].label, "Alpha (staged)")
		expect.match(mare.json.encode(ui_cmd.dialog.items[2].preview), "Staged: yes")

		expect.eq(ui_cmd.command("stage clear"), nil)
		expect.eq(ui_cmd.service.staged().id, nil)
		expect.eq(ui_cmd.command("default clear"), nil)
		expect.eq(ui_cmd.command("default"), nil)
		expect.eq(ui_cmd:last().text, "Default preset: none")

		-- Idempotent clear when nothing active and idempotent re-select without model avoid duplicate events.
		local ev_count_before = #ui_cmd.events
		expect.eq(ui_cmd.service.select(nil, nil, "clear"), true)
		expect.eq(#ui_cmd.events, ev_count_before)
		expect.eq(ui_cmd.service.select(nil, nil, "alpha"), true)
		local ev_after_select = #ui_cmd.events
		expect.eq(ev_after_select, ev_count_before + 1)
		expect.eq(ui_cmd.service.select(nil, nil, "alpha"), true)
		expect.eq(#ui_cmd.events, ev_after_select)
		expect.eq(ui_cmd.service.select(nil, nil, "clear"), true)
		expect.eq(#ui_cmd.events, ev_after_select + 1)
	end)

	it("preserves staged on auto-apply failure and propagates mare.state.update failures", function()
		local fi_defs = {
			fallback_def = { model = "model-a", system = "DEFAULT_PROMPT", tools = { "read" }, order = 1 },
			need_model = { model = "later-model", system = "RECOVERED_PROMPT", tools = { "bash" }, order = 2 },
		}
		local fi1 = H.fixture(
			fi_defs,
			{ default = "fallback_def" },
			{ models = { ["model-a"] = { ref = "model-a", id = "model-a" } } }
		)
		expect.truthy(fi1.service.stage(nil, nil, "need_model"))
		expect.eq(fi1.service.staged().id, "need_model")
		fi1.dispose()

		local fi2 = H.fixture(
			fi_defs,
			{ default = "fallback_def" },
			{ models = { ["model-a"] = { ref = "model-a", id = "model-a" } } }
		)
		fi2.connected = true
		fi2.hooks["session/started"]({ resumed = false })
		expect.eq(fi2.service.current().id, nil)
		expect.eq(fi2:prompt(), "base")
		expect.eq(fi2.service.staged().id, "need_model")
		expect.eq(fi2:last().level, "warning")
		expect.truthy(fi2:last().text:find("Preset auto-apply failed", 1, true))

		-- Retrying on same generation once model becomes available recovers cleanly and consumes staged.
		fi2.models["later-model"] = { ref = "later-model", id = "later-model" }
		fi2.hooks["session/new"]()
		expect.eq(fi2.service.current().id, "need_model")
		expect.eq(fi2.model.ref, "later-model")
		expect.truthy(fi2:prompt():find("RECOVERED_PROMPT", 1, true))
		expect.eq(fi2.constraint()[1], "bash")
		expect.eq(fi2.service.staged().id, nil)

		-- Fault injection 2: persistence failures from mare.state.update propagate instead of returning success or mutating state.
		mare.state.update = function()
			error("disk full")
		end
		local ok_def, err_def = pcall(fi2.service.set_default, nil, nil, "need_model")
		expect.eq(ok_def, false)
		expect.truthy(tostring(err_def):find("disk full", 1, true))
		expect.eq(fi2.command("default need_model").status, "rejected")
		fi2.command("list")
		expect.truthy(fi2:last().text:find("fallback_def [fallback_def] (default)", 1, true))
		expect.falsy(fi2:last().text:find("need_model [need_model] (default)", 1, true))

		mare.state.update = function()
			return nil, "readonly state store"
		end
		local ok_stg, err_stg = pcall(fi2.service.stage, nil, nil, "fallback_def")
		expect.eq(ok_stg, false)
		expect.truthy(tostring(err_stg):find("readonly state store", 1, true))
		expect.eq(fi2.service.staged().id, nil)
		expect.eq(fi2.command("stage fallback_def").status, "rejected")
		expect.eq(fi2.service.staged().id, nil)

		mare.state.update = orig_state_update
		expect.eq(fi2.service.set_default(nil, nil, "need_model"), true)
		expect.eq(fi2.service.stage(nil, nil, "fallback_def"), true)
		expect.eq(fi2.service.staged().id, "fallback_def")
	end)
end)
