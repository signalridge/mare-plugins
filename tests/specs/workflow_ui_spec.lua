local support = assert(load(mare.fs.read("tests/specs/support.lua"), "@tests/specs/support.lua"))()

local describe = mare.test.describe
local it = mare.test.it
local before_each = mare.test.before_each
local after_each = mare.test.after_each
local expect = mare.test.expect

support.preload_modules("workflow", {
	"workflow.config",
	"workflow.schema",
	"workflow.events",
	"workflow.records",
	"workflow.panel",
	"workflow.summary",
})

local config = require("workflow.config")
local panel = require("workflow.panel")
local summary = require("workflow.summary")

describe("workflow ui", function()
	local orig_get_renderer, orig_hint

	before_each(function()
		orig_get_renderer = mare.ui.get_renderer
		orig_hint = mare.keymap and mare.keymap.hint
	end)

	after_each(function()
		mare.ui.get_renderer = orig_get_renderer
		if mare.keymap then
			mare.keymap.hint = orig_hint
		end
	end)

	it("renders braille, block, and ASCII fallback bars and respects height compression", function()
		expect.eq(panel.resolve_bar_mode("braille", true), "braille")
		expect.eq(panel.resolve_bar_mode("block", true), "block")
		expect.eq(panel.resolve_bar_mode("braille", false), "ascii")

		local ascii_bar = panel.render_bar(0.5, 8, "ascii")
		expect.eq(ascii_bar, "[====----]")
		local block_bar = panel.render_bar(0.5, 4, "block")
		expect.eq(block_bar, "[██░░]")

		local run = {
			run_id = "wf-1",
			name = "ui-audit",
			description = "UI audit across areas",
			status = "running",
			started_at_ms = 1000,
			started_clock = mare.task.clock(),
			total = 8,
			completed = 5,
			failed = 1,
			cancelled = 0,
			phase_order = { "Review", "Verify" },
			phases = {
				Review = { title = "Review", agents = {} },
				Verify = { title = "Verify", agents = {} },
			},
			agents = {},
		}
		for i = 1, 6 do
			local m = {
				seq = i,
				label = "rev-" .. i,
				phase = "Review",
				status = i <= 5 and "completed" or "failed",
				duration_ms = 12000,
				error = i == 6 and "Rate limited" or nil,
			}
			run.agents[#run.agents + 1] = m
			table.insert(run.phases.Review.agents, m)
		end
		for i = 7, 8 do
			local m = {
				seq = i,
				label = "ver-" .. i,
				phase = "Verify",
				status = "running",
				tool_calls = 3,
				preview = "Checking findings",
				started_clock = mare.task.clock(),
			}
			run.agents[#run.agents + 1] = m
			table.insert(run.phases.Verify.agents, m)
		end

		local hint_called = false
		if mare.keymap then
			mare.keymap.hint = function(action, context)
				if action == "agents" and context == "editor" then
					hint_called = true
					return { "<Left>" }
				end
				return {}
			end
		end

		local cfg = config.normalize({})
		local node = panel.render_run(run, 90, 20, cfg, { term_height = 60, utf8 = true })
		local encoded = mare.json.encode(node)
		expect.match(encoded, "ui%-audit")
		expect.match(encoded, "Review")
		expect.match(encoded, "Verify")
		expect.match(encoded, "for agents")
		expect.truthy(hint_called)
		expect.falsy(assert(mare.fs.read("plugins/workflow/lua/workflow/panel.lua")):find("keys_for", 1, true))

		-- Tight height triggers collapse_done + folding (+N more) and stays within cap
		local tight = panel.render_run(run, 60, 5, cfg, { term_height = 24, utf8 = false })
		local tight_json = mare.json.decode(mare.json.encode(tight))
		expect.truthy(#tight_json.items <= 5)
		local tight_str = mare.json.encode(tight_json)
		expect.match(tight_str, "completed")
		expect.match(tight_str, "%[") -- ASCII fallback bar
	end)

	it("uses single-line list for 1-3 plain agents and invokes workflow/panel renderer hook", function()
		local cfg = config.normalize({})
		local small_run = {
			run_id = "wf-small",
			name = "quick-check",
			description = "Two agents",
			status = "running",
			started_at_ms = 1000,
			started_clock = mare.task.clock(),
			total = 2,
			completed = 0,
			failed = 0,
			cancelled = 0,
			phase_order = {},
			phases = {},
			agents = {
				{
					seq = 1,
					label = "explore",
					status = "running",
					preview = "Reading src/main.rs",
					started_clock = mare.task.clock(),
				},
				{ seq = 2, label = "tests", status = "completed", preview = "All passed", duration_ms = 4000 },
			},
		}
		local list_node =
			panel.render_run(small_run, 100, 12, cfg, { term_height = 40, utf8 = true, agents_hint = false })
		local list_str = mare.json.encode(list_node)
		expect.match(list_str, "explore")
		expect.match(list_str, "Reading src/main.rs")

		mare.ui.get_renderer = function(kind)
			if kind == "workflow/panel" then
				return function(r, w)
					return mare.ui.Line("CUSTOM:" .. r.name .. ":" .. tostring(w))
				end
			end
		end
		local custom = panel.render_run(small_run, 77, 10, cfg, {})
		expect.match(mare.json.encode(custom), "CUSTOM:quick%-check:77")
	end)

	it("renders compact and expanded transcript summaries and rebuilds on /resume", function()
		local run = {
			run_id = "wf-sum",
			name = "ui-audit",
			description = "UI/UX audit",
			status = "completed",
			duration_ms = 252000,
			agents = {
				{
					seq = 1,
					label = "a1",
					phase = "Review",
					status = "completed",
					duration_ms = 60000,
					summary = "Looks good",
					usage = { input = 800, output = 400 },
				},
				{ seq = 2, label = "a2", phase = "Verify", status = "failed", duration_ms = 5000, error = "Timed out" },
				{ seq = 3, label = "a3", phase = "Verify", status = "interrupted", duration_ms = 1000 },
			},
		}
		local compact_line = summary.compact_text(run)
		expect.match(compact_line, "✓ ui%-audit")
		expect.match(compact_line, "3 agents")
		expect.match(compact_line, "4m12s")

		local compact_node = mare.json.encode(summary.render_run(run, false))
		expect.match(compact_node, "ui%-audit")
		expect.falsy(compact_node:find("Timed out", 1, true))

		local expanded_node = mare.json.encode(summary.render_run(run, true))
		expect.match(expanded_node, "Review")
		expect.match(expanded_node, "Verify")
		expect.match(expanded_node, "1.2k tok")
		expect.match(expanded_node, "Timed out")
		expect.match(expanded_node, "interrupted")

		-- /resume rebuild via session records
		local entry_renderers = {}
		local ctx = {
			session = {
				list_records = function(_, kind)
					if kind == "workflow/run-start" then
						return {
							data = {
								{ run_id = "wf-res", name = "resumed", description = "From disk", started_at_ms = 10 },
							},
						}
					elseif kind == "workflow/agent-start" then
						return { data = { { run_id = "wf-res", seq = 1, label = "worker", started_at_ms = 11 } } }
					end
					return { data = {} }
				end,
			},
			ui = {
				register_entry_renderer = function(_, kind, def)
					entry_renderers[kind] = def
				end,
				invalidate = function() end,
			},
			on = function() end,
		}
		local sum_inst = summary.create(ctx, { session = ctx.session })
		sum_inst.rebuild()
		expect.eq(#sum_inst.list(), 1)
		expect.eq(sum_inst.list()[1].status, "interrupted")
		expect.truthy(entry_renderers["workflow/run-start"])
		local entry_compact =
			mare.json.encode(entry_renderers["workflow/run-start"].compact({ data = { run_id = "wf-res" } }))
		expect.match(entry_compact, "resumed")
		expect.match(entry_compact, "interrupted")

		-- Live running run does NOT commit a permanent transcript summary at run-start;
		-- render_tool handles completed runs cleanly and rebuilds lazily if transcript rebuilds out of order.
		local live_run = {
			run_id = "wf-live-1",
			name = "live-audit",
			description = "Live",
			status = "running",
			recorded_in_session = true,
			agents = { { seq = 1, label = "w1", status = "running" } },
		}
		sum_inst.track_run(live_run)
		expect.eq(entry_renderers["workflow/run-start"].compact({ data = { run_id = "wf-live-1" } }), nil)
		expect.eq(entry_renderers["workflow/run-start"].expanded({ data = { run_id = "wf-live-1" } }), nil)
		live_run.status = "completed"
		live_run.completed = 1
		live_run.duration_ms = 1200
		local done_tool_compact = mare.json.encode(
			sum_inst.render_tool({ meta = { name = "live-audit" } }, { details = { run = live_run } }, false)
		)
		expect.match(done_tool_compact, "live%-audit")
		expect.match(done_tool_compact, "1 agent")

		-- Panel preserves unphased members when named phases start, applies collapse_done in list, and counts members for +N more
		local cfg = config.normalize({})
		local mixed_run = {
			run_id = "wf-mixed",
			name = "mixed",
			description = "Unphased plus phased",
			status = "running",
			started_clock = mare.task.clock(),
			total = 6,
			completed = 1,
			failed = 0,
			cancelled = 0,
			phase_order = { "LatePhase" },
			phases = { LatePhase = { title = "LatePhase", agents = {} } },
			agents = {
				{
					seq = 1,
					label = "early-unphased",
					status = "running",
					preview = "working",
					started_clock = mare.task.clock(),
				},
				{ seq = 2, label = "p1", phase = "LatePhase", status = "completed", duration_ms = 1000 },
				{
					seq = 3,
					label = "p2",
					phase = "LatePhase",
					status = "running",
					preview = "p2",
					started_clock = mare.task.clock(),
				},
				{
					seq = 4,
					label = "p3",
					phase = "LatePhase",
					status = "running",
					preview = "p3",
					started_clock = mare.task.clock(),
				},
				{
					seq = 5,
					label = "p4",
					phase = "LatePhase",
					status = "running",
					preview = "p4",
					started_clock = mare.task.clock(),
				},
				{
					seq = 6,
					label = "p5",
					phase = "LatePhase",
					status = "running",
					preview = "p5",
					started_clock = mare.task.clock(),
				},
			},
		}
		for i = 2, 6 do
			table.insert(mixed_run.phases.LatePhase.agents, mixed_run.agents[i])
		end
		local mixed_out = mare.json.encode(panel.render_run(mixed_run, 60, 20, cfg, { term_height = 60, utf8 = true }))
		expect.match(mixed_out, "001")
		expect.match(mixed_out, "working")
		expect.match(mixed_out, "LatePhase")

		-- Tight cap of 4 lines (2 body rows) keeps early-unphased + 1 row, hides >=4 members (not layout rows)
		local folded_out = mare.json.encode(panel.render_run(mixed_run, 40, 4, cfg, { term_height = 40, utf8 = true }))
		expect.match(folded_out, "%+%d+ more")

		-- List layout collapses completed members when tight
		local list_cfg = config.normalize({ panel = { layout = "list", collapse_done = true } })
		local list_tight =
			mare.json.encode(panel.render_run(mixed_run, 80, 6, list_cfg, { term_height = 40, utf8 = true }))
		expect.match(list_tight, "1 completed")

		-- max_height = 1 strictly emits 1 row
		local one_row = panel.render_run(mixed_run, 60, 1, cfg, { term_height = 40, utf8 = true })
		local line_count = type(one_row) == "table" and #(one_row.items or one_row) or 0
		expect.eq(line_count, 1)

		-- engine tracks run BEFORE writer.run_start records so live scrollback finds by_id immediately
		local engine_mod = require("workflow.engine")
		local saw_live_during_record = nil
		local live_sum = summary.create({
			ui = {
				register_entry_renderer = function() end,
				invalidate = function() end,
			},
		}, {})
		local live_eng = engine_mod.new({
			ctx = {
				spawn = function(_, fn)
					return mare.task.spawn(fn)
				end,
			},
			get_cfg = function()
				return cfg
			end,
			svc = {
				session = {
					info = function()
						return { session_id = "s-live", session_epoch = "g1", ephemeral = false, readonly = false }
					end,
					add_record = function(_, kind, data)
						if kind == "workflow/run-start" then
							local found = false
							for _, item in ipairs(live_sum.list()) do
								if item.run_id == data.run_id then
									found = true
								end
							end
							saw_live_during_record = found
						end
						return { durable = true }
					end,
				},
			},
			summary = live_sum,
			runner = function()
				return { ok = true, text = "ok" }
			end,
		})
		live_eng.run({
			meta = { name = "live-idx", description = "Indexed before run-start record" },
			script = [[ return agent("a") ]],
		})
		expect.eq(saw_live_during_record, true)
	end)

	it("renders background workflow/run-end cleanly and rebuilds lazily on /tree order mismatch", function()
		local sum_mod = require("workflow.summary")
		local renderers = {}
		local lazy_records = {}
		local lazy_ctx = {
			ui = {
				register_entry_renderer = function(_, kind, spec)
					renderers[kind] = spec
				end,
			},
			session = {
				list_records = function(_, kind)
					return { data = lazy_records[kind] or {} }
				end,
			},
		}
		local s = sum_mod.create(lazy_ctx, {
			session = {
				list_records = function(_, kind)
					return { data = lazy_records[kind] or {} }
				end,
			},
		})
		expect.truthy(s)
		lazy_records = {
			["workflow/run-start"] = {
				{ run_id = "wf-bg-1", name = "bg", description = "BG", background = true, started_at_ms = 1000 },
			},
			["workflow/agent-start"] = {
				{ run_id = "wf-bg-1", seq = 1, label = "a1", started_at_ms = 1001 },
				{ run_id = "wf-bg-1", seq = 2, label = "a2", started_at_ms = 1002 },
			},
			["workflow/agent-end"] = {
				{ run_id = "wf-bg-1", seq = 1, status = "completed", ok = true, duration_ms = 200 },
				{ run_id = "wf-bg-1", seq = 2, status = "completed", ok = true, duration_ms = 250 },
			},
			["workflow/run-end"] = {
				{
					run_id = "wf-bg-1",
					name = "bg",
					background = true,
					status = "completed",
					total = 2,
					completed = 2,
					duration_ms = 500,
				},
			},
		}
		-- Calling entry renderer directly before explicit s.rebuild() lazily rebuilds from session entries
		expect.eq(renderers["workflow/run-start"].compact({ data = { run_id = "wf-bg-1" } }), nil)
		local end_node = renderers["workflow/run-end"].compact({ data = { run_id = "wf-bg-1" } })
		expect.truthy(end_node)
		expect.match(mare.json.encode(end_node), "bg")
		expect.match(mare.json.encode(end_node), "2 agents")

		local orig_style = mare.ui.style
		mare.ui.style = function(name)
			if name == "workflow.bar_done" then
				return { fg = "green" }
			end
			return nil
		end
		local styled_run = {
			run_id = "wf-styled",
			name = "styled",
			status = "completed",
			started_at_ms = 1000,
			phase_order = {},
			phases = {},
			agents = { { seq = 1, label = "a1", status = "completed", started_at_ms = 1000 } },
			members = { { seq = 1, label = "a1", status = "completed", started_at_ms = 1000 } },
			logs = {},
		}
		local styled_node =
			panel.render_run(styled_run, 80, 12, config.normalize({}), { term_height = 40, utf8 = true })
		mare.ui.style = orig_style
		expect.truthy(styled_node)
		expect.match(mare.json.encode(styled_node), "workflow.bar_done")
	end)
end)
