local support = assert(load(mare.fs.read("tests/specs/support.lua"), "@tests/specs/support.lua"))()

local describe = mare.test.describe
local it = mare.test.it
local before_each = mare.test.before_each
local after_each = mare.test.after_each
local expect = mare.test.expect

local wf_plugin = support.load_plugin("workflow", {
	"workflow.config",
	"workflow.schema",
	"workflow.events",
	"workflow.records",
	"workflow.vm",
	"workflow.panel",
	"workflow.summary",
	"workflow.engine",
})

local config = require("workflow.config")
local schema = require("workflow.schema")
local records = require("workflow.records")
local engine_mod = require("workflow.engine")

describe("workflow", function()
	local orig_state_read, orig_state_set, orig_notify, orig_mode, orig_env_get
	local saved_state, notices

	before_each(function()
		orig_state_read = mare.state.read
		orig_state_set = mare.state.set
		orig_notify = mare.ui.notify
		orig_mode = mare.mode
		orig_env_get = mare.env.get

		saved_state = {}
		notices = {}
		mare.state.read = function()
			return saved_state
		end
		mare.state.set = function(k, v)
			saved_state[k] = v
		end
		mare.ui.notify = function(msg, level)
			notices[#notices + 1] = { msg = msg, level = level }
		end
	end)

	after_each(function()
		mare.state.read = orig_state_read
		mare.state.set = orig_state_set
		mare.ui.notify = orig_notify
		mare.mode = orig_mode
		mare.env.get = orig_env_get
	end)

	it("toggles /workflow on|off via state.json, updates prompt guidance and events", function()
		local tools, commands, sections, emitted = {}, {}, {}, {}
		local invalidations = 0
		local ctx = {
			tools = {
				register = function(_, name, def)
					tools[name] = def
				end,
				touch = function() end,
			},
			commands = {
				register = function(_, name, def)
					commands[name] = def
				end,
			},
			context = {
				section = function(_, def)
					sections[def.name] = def
				end,
				invalidate = function()
					invalidations = invalidations + 1
				end,
			},
			ui = {
				widget = function() end,
				invalidate = function() end,
				register_entry_renderer = function() end,
			},
			session = {
				info = function()
					return { session_id = "s-1", session_epoch = "g-1", ephemeral = false, readonly = false }
				end,
				list_records = function()
					return { data = {} }
				end,
			},
			emit = function(_, name, payload)
				emitted[#emitted + 1] = { name = name, payload = payload }
			end,
			on = function() end,
			spawn = function(_, fn)
				return mare.task.spawn(fn)
			end,
		}

		wf_plugin.apply(ctx, support.default_config(wf_plugin))

		expect.truthy(tools.workflow)
		expect.eq(tools.workflow.enabled(), false)
		expect.eq(sections["workflow:guidance"].text(), nil)
		expect.eq(emitted[#emitted].name, "workflow/changed")
		expect.eq(emitted[#emitted].payload.enabled, false)

		commands.workflow.run("on")
		expect.eq(saved_state.workflow_enabled, true)
		expect.eq(tools.workflow.enabled(), true)
		expect.match(sections["workflow:guidance"].text(), "workflow")
		expect.eq(emitted[#emitted].payload.enabled, true)
		expect.truthy(invalidations >= 1)

		commands.workflow.run("off")
		expect.eq(saved_state.workflow_enabled, false)
		expect.eq(tools.workflow.enabled(), false)
		expect.eq(sections["workflow:guidance"].text(), nil)
		expect.eq(emitted[#emitted].payload.enabled, false)

		-- Reloading plugin restores saved state from state.json
		saved_state.workflow_enabled = true
		expect.eq(config.load_enabled(config.DEFAULTS), true)
	end)

	it("resolves auto concurrency and validates restricted JSON schemas and meta", function()
		mare.env.get = function(name)
			if name == "MARE_WORKFLOW_CPUS" then
				return "10"
			end
			return orig_env_get(name)
		end
		expect.eq(config.resolve_concurrency({ max_concurrent_agents = 0 }), 8)
		mare.env.get = function(name)
			if name == "MARE_WORKFLOW_CPUS" then
				return "32"
			end
			return orig_env_get(name)
		end
		expect.eq(config.resolve_concurrency({ max_concurrent_agents = 0 }), 16)
		expect.eq(config.resolve_concurrency({ max_concurrent_agents = 5 }), 5)

		local valid_schema = {
			type = "object",
			additionalProperties = false,
			required = { "verdict", "tags" },
			properties = {
				verdict = { enum = { "pass", "fail" } },
				tags = { type = "array", items = { type = "string" } },
				detail = { oneOf = { { type = "string" }, { const = false } } },
			},
		}
		expect.truthy(schema.validate_schema(valid_schema))
		expect.truthy(schema.validate_value(valid_schema, {
			verdict = "pass",
			tags = mare.json.array({ "a", "b" }),
			detail = false,
		}))
		local ok_bad, err_bad = schema.validate_value(valid_schema, {
			verdict = "maybe",
			tags = mare.json.array({ "a" }),
		})
		expect.falsy(ok_bad)
		expect.match(err_bad, "enum")

		expect.error(function()
			schema.validate_schema({ type = "string" })
		end, "type = 'object'")

		expect.error(function()
			schema.validate_schema({
				type = "object",
				properties = { x = { type = "string", pattern = "^a" } },
			})
		end, "unsupported JSON Schema keyword")

		local ok_m = schema.validate_meta({
			name = "ui-audit",
			description = "Audit UI files",
			phases = mare.json.array({ { title = "Review", model = "gpt-5" } }),
		})
		expect.truthy(ok_m)

		local ok_m_bad, err_m = schema.validate_meta({ name = "BadName", description = "x" })
		expect.falsy(ok_m_bad)
		expect.match(err_m, "kebab%-case")
	end)

	it("enforces monotonic prefix invariant in session records and reconstructs interrupted runs", function()
		local stored = {}
		local fail_next = false
		local session_mock = {
			info = function()
				return { session_id = "sess-1", session_epoch = "gen-1", ephemeral = false, readonly = false }
			end,
			add_record = function(_, kind, data)
				if fail_next then
					error("disk full", 0)
				end
				stored[#stored + 1] = { kind = kind, data = data }
				return { durable = true }
			end,
			list_records = function(_, kind)
				local out = {}
				for _, r in ipairs(stored) do
					if r.kind == kind then
						out[#out + 1] = r.data
					end
				end
				return { data = out }
			end,
		}

		local w = records.new_writer(function()
			return session_mock
		end)
		expect.truthy(w.run_start({ run_id = "r1", name = "audit", description = "desc", started_at_ms = 10 }))
		expect.falsy(w.run_start({ run_id = "r1" })) -- at most one run-start
		expect.truthy(w.agent_start(1, { run_id = "r1", seq = 1, label = "a1", started_at_ms = 11 }))
		expect.falsy(w.agent_start(1, { run_id = "r1", seq = 1, label = "dup" })) -- unique seq
		expect.falsy(w.run_end({ run_id = "r1" })) -- cannot write run-end while seq 1 open
		expect.truthy(w.agent_end(1, { run_id = "r1", seq = 1, status = "completed", ok = true, duration_ms = 5 }))
		expect.truthy(w.run_end({ run_id = "r1", status = "completed", total = 1, duration_ms = 10 }))
		expect.eq(#stored, 4)

		-- Stop writing on first failure
		local w2 = records.new_writer(function()
			return session_mock
		end)
		expect.truthy(w2.run_start({ run_id = "r2", name = "broken", description = "desc", started_at_ms = 20 }))
		expect.truthy(w2.agent_start(1, { run_id = "r2", seq = 1, label = "b1", started_at_ms = 21 }))
		fail_next = true
		expect.falsy(w2.agent_end(1, { run_id = "r2", seq = 1, status = "completed", ok = true }))
		fail_next = false
		expect.falsy(w2.run_end({ run_id = "r2", status = "completed" })) -- stopped after failure

		local reconstructed = records.reconstruct(session_mock)
		expect.eq(#reconstructed, 2)
		expect.eq(reconstructed[1].status, "completed")
		expect.eq(reconstructed[2].status, "interrupted")
		expect.eq(reconstructed[2].agents[1].status, "interrupted")
	end)

	it(
		"runs parallel, pipeline, schema validation, error/limit discipline, and concurrency cap in real sandbox VM",
		function()
			local emitted, session_recs = {}, {}
			local active_count, peak_active = 0, 0
			local cfg = config.normalize({
				max_concurrent_agents = 2,
				max_total_agents = 10,
				max_items_per_call = 5,
				child_result_chars = 40,
				max_result_chars = 5000,
				sync_timeout_ms = 5000,
			})
			local ctx = {
				emit = function(_, name, payload)
					emitted[#emitted + 1] = { name = name, payload = payload }
				end,
				spawn = function(_, fn)
					return mare.task.spawn(fn)
				end,
			}
			local sess = {
				info = function()
					return {
						session_id = "s-vm",
						session_epoch = "epoch-vm",
						ephemeral = false,
						readonly = false,
					}
				end,
				add_record = function(_, kind, data)
					session_recs[#session_recs + 1] = { kind = kind, data = data }
					return { durable = true }
				end,
			}
			local eng = engine_mod.new({
				ctx = ctx,
				get_cfg = function()
					return cfg
				end,
				svc = { session = sess },
				runner = function(spec)
					active_count = active_count + 1
					if active_count > peak_active then
						peak_active = active_count
					end
					mare.task.sleep(25)
					active_count = active_count - 1
					if spec.prompt:find("FAIL_ME", 1, true) then
						return { ok = false, status = "failed", error = "boom" }
					end
					if spec.output_schema then
						if spec.prompt:find("BAD_JSON", 1, true) then
							return { ok = true, status = "completed", text = "not json" }
						end
						return { ok = true, status = "completed", structured = { refuted = false, note = spec.label } }
					end
					return {
						ok = true,
						status = "completed",
						text = "reply:" .. spec.prompt .. ":" .. string.rep("x", 50),
					}
				end,
			})

			local res = eng.run({
				meta = { name = "demo-run", description = "Run parallel and pipeline" },
				args = { items = mare.json.array({ "one", "two", "FAIL_ME", "four" }) },
				script = [[
				local S = {
					type = "object",
					additionalProperties = false,
					required = { "refuted", "note" },
					properties = {
						refuted = { type = "boolean" },
						note = { type = "string" },
					},
				}
				phase("Gather")
				local p = parallel({
					function() return agent("p1", { label = "a1" }) end,
					function() return agent("FAIL_ME", { label = "a2" }) end,
					function() error("stage crash") end,
					function() return agent("p4", { label = "a4" }) end,
				})
				assert(p.n == 4)
				assert(p[1] and p[2] == nil and p[3] == nil and p[4])
				assert(p.errors[2].kind == "agent")
				assert(p.errors[3].kind == "stage")
				phase("Verify")
				local pipe = pipeline(args.items,
					function(item)
						if item == "FAIL_ME" then
							return agent("FAIL_ME", { label = "v-" .. item, schema = S })
						end
						return agent("verify " .. item, { label = "v-" .. item, schema = S })
					end,
					function(verdict, item)
						if verdict and not verdict.refuted then
							return { item = item, note = verdict.note }
						end
						return nil
					end
				)
				log("done")
				return { p = p, pipe = pipe, p_err_2 = p.errors[2].kind, p_err_3 = p.errors[3].kind }
			]],
			})

			expect.falsy(res.is_error, res.content)
			expect.truthy(peak_active <= 2)
			expect.match(res.content, 'workflow "demo%-run" completed %(7 agents%)')
			expect.eq(#res.details.result.p, 4)
			expect.eq(res.details.result.p[2], mare.json.null)
			expect.eq(res.details.result.p[3], mare.json.null)
			expect.eq(#res.details.result.p[1], 40) -- capped by child_result_chars = 40
			expect.eq(res.details.result.pipe[3], mare.json.null)
			expect.eq(res.details.result.pipe[4].item, "four")

			-- Verify listener snapshot isolation & single canonical event names
			local saw = {}
			local started_payload = nil
			for _, e in ipairs(emitted) do
				saw[e.name] = (saw[e.name] or 0) + 1
				if e.name == "workflow/started" then
					started_payload = e.payload
				end
			end
			expect.truthy(
				saw["workflow/started"]
					and saw["workflow/phase"]
					and saw["workflow/log"]
					and saw["workflow/agent-started"]
					and saw["workflow/agent-completed"]
					and saw["workflow/completed"]
			)
			expect.eq(started_payload.parent_session_id, "s-vm")
			expect.eq(started_payload.parent_session_epoch, "epoch-vm")
			expect.eq(started_payload.parent_session, nil)
			expect.eq(saw["workflow/start"], nil)
			expect.eq(saw["workflow/agent-start"], nil)
			expect.eq(saw["workflow/agent-end"], nil)
			expect.eq(saw["workflow/end"], nil)

			-- Bad argument / unsupported schema / limit errors abort the entire run
			local bad_schema_res = eng.run({
				meta = { name = "bad-schema", description = "Should abort" },
				script = [[
				local r = parallel({
					function() return agent("ok", { schema = { type = "string" } }) end,
				})
				return r
			]],
			})
			expect.truthy(bad_schema_res.is_error)
			expect.match(bad_schema_res.content, "Error: workflow run failed:")

			local items_limit_res = eng.run({
				meta = { name = "too-many", description = "Should abort" },
				script = [[
				return pipeline({ 1, 2, 3, 4, 5, 6 }, function(x) return x end)
			]],
			})
			expect.truthy(items_limit_res.is_error)
			expect.match(items_limit_res.content, "max_items_per_call")

			-- Depth-1 guard in child mode
			mare.mode = "child"
			local child_res = eng.run({
				meta = { name = "nested", description = "Must refuse" },
				script = [[ return 1 ]],
			})
			expect.truthy(child_res.is_error)
			expect.match(child_res.content, "depth limit 1")
			mare.mode = orig_mode
		end
	)

	it("handles cooperative cancellation, sync_timeout_ms watchdog, and run_in_background jobs", function()
		local tracked_jobs = {}
		local cfg = config.normalize({
			stop_grace_ms = 80,
			sync_timeout_ms = 120,
			max_result_chars = 60,
		})
		local ctx = {
			emit = function() end,
			spawn = function(_, fn)
				return mare.task.spawn(fn)
			end,
		}
		local jobs_svc = {
			track = function(_, spec)
				local j = {
					job_id = "workflow-" .. tostring(#tracked_jobs + 1),
					kind = spec.kind,
					label = spec.label,
					description = spec.description,
					handle = spec.handle,
					background = spec.background,
				}
				tracked_jobs[#tracked_jobs + 1] = j
				return j
			end,
		}
		local eng = engine_mod.new({
			ctx = ctx,
			get_cfg = function()
				return cfg
			end,
			svc = { jobs = jobs_svc },
			runner = function(spec, opts)
				if spec.prompt == "hang" then
					opts.cancel:wait()
					return { ok = false, status = "cancelled", error = "cancelled" }
				end
				return { ok = true, status = "completed", text = string.rep("A", 120) }
			end,
		})

		-- Sync timeout watchdog
		local sync_res = eng.run({
			meta = { name = "spin", description = "Infinite loop" },
			script = [[
				while true do end
				return 1
			]],
		})
		expect.truthy(sync_res.is_error)
		expect.match(sync_res.content, "sync_timeout_ms")

		-- Cancellation
		local tok = mare.task.token()
		local cancel_task = mare.task.spawn(function()
			mare.task.sleep(40)
			tok:cancel()
		end)
		local cancel_res = eng.run({
			meta = { name = "cancel-me", description = "Cancelled" },
			script = [[ return agent("hang") ]],
		}, { cancel = tok })
		cancel_task:wait()
		expect.truthy(cancel_res.is_error)
		expect.eq(cancel_res.content, "Error: workflow run was cancelled")
		expect.truthy(cancel_res.cancelled)

		-- Truncation notice on max_result_chars
		local trunc_res = eng.run({
			meta = { name = "trunc", description = "Truncated output" },
			script = [[ return agent("ok") ]],
		})
		expect.falsy(trunc_res.is_error)
		expect.match(trunc_res.content, "%[truncated: omitted %d+ characters%]")

		-- Background job integration
		local bg_res = eng.run({
			meta = { name = "bg-run", description = "Background workflow" },
			run_in_background = true,
			script = [[
				phase("BgPhase")
				log("working in background")
				return { value = agent("ok") }
			]],
		})
		expect.falsy(bg_res.is_error)
		expect.match(bg_res.content, "started in the background as job workflow%-1")
		expect.eq(#tracked_jobs, 1)
		local st = tracked_jobs[1].handle:wait({ timeout_ms = 5000 })
		expect.eq(st.state, "exited")
		expect.eq(st.code, 0)
		local out = tracked_jobs[1].handle:read({})
		expect.match(out.text, "%[phase%] BgPhase")
		expect.match(out.text, "%[log%] working in background")
		expect.match(out.text, 'workflow "bg%-run" completed')
		expect.eq(out.done, true)

		-- Capped read must report done = false until cursor reaches end
		local bg2 = eng.run({
			meta = { name = "bg-cap", description = "Capped read test" },
			run_in_background = true,
			script = [[ log("hello world from background"); return { ok = true } ]],
		})
		expect.falsy(bg2.is_error)
		tracked_jobs[2].handle:wait({ timeout_ms = 5000 })
		local slice1 = tracked_jobs[2].handle:read({ max_bytes = 8 })
		expect.eq(#slice1.text, 8)
		expect.eq(slice1.done, false)
		local slice_rest = tracked_jobs[2].handle:read({})
		expect.eq(slice_rest.done, true)
	end)

	it(
		"enforces workflow invariants: nested [[[1]]] array, {} vs [] vs null schema, serialized writer, pipeline short-circuit, per-slice watchdog, stop_unconfirmed, session switch, and child restrictions",
		function()
			-- 1. Serialized records.new_writer: concurrent agent_start where 1st fails blocks 2nd on dequeue
			local append_calls = 0
			local conc_sess = {
				info = function()
					return { session_id = "s-ser", session_epoch = "g1", ephemeral = false, readonly = false }
				end,
				add_record = function(_, kind)
					if kind == "workflow/agent-start" then
						append_calls = append_calls + 1
						mare.task.sleep(30)
						error("append boom", 0)
					end
					return { durable = true }
				end,
			}
			local sw = records.new_writer(function()
				return conc_sess
			end)
			expect.truthy(sw.run_start({ run_id = "r-ser", name = "ser", description = "d", started_at_ms = 1 }))
			local a1_ok, a2_ok
			local f1 = mare.task.spawn(function()
				a1_ok = sw.agent_start(1, { run_id = "r-ser", seq = 1, label = "a1" })
			end)
			local f2 = mare.task.spawn(function()
				a2_ok = sw.agent_start(2, { run_id = "r-ser", seq = 2, label = "a2" })
			end)
			f1:wait()
			f2:wait()
			expect.falsy(a1_ok)
			expect.falsy(a2_ok)
			expect.eq(append_calls, 1)
			expect.truthy(sw.status().failed)

			-- 2. Empty {} vs [] vs null in schema validator
			local shape_schema = {
				type = "object",
				additionalProperties = false,
				required = { "obj", "arr", "nilv" },
				properties = {
					obj = { oneOf = { { type = "object" }, { type = "array" } } },
					arr = { type = "array" },
					nilv = { type = "null" },
				},
			}
			expect.truthy(schema.validate_value(shape_schema, {
				obj = mare.json.decode_lossless("{}"),
				arr = mare.json.decode_lossless("[]"),
				nilv = mare.json.null,
			}))
			local bad_arr_ok = schema.validate_value({
				type = "object",
				properties = { arr = { type = "array" } },
			}, { arr = mare.json.decode_lossless("{}") })
			expect.falsy(bad_arr_ok)

			-- 3. VM + Engine P1/P2s
			local seen_specs = {}
			local cur_sess = { session_id = "sess-a", session_epoch = "gen-1", ephemeral = false, readonly = false }
			local recorded_runs = {}
			local cfg = config.normalize({
				max_concurrent_agents = 2,
				child_result_chars = 40,
				sync_timeout_ms = 2000,
				stop_grace_ms = 80,
			})
			local ctx = {
				emit = function() end,
				spawn = function(_, fn)
					return mare.task.spawn(fn)
				end,
			}
			local eng = engine_mod.new({
				ctx = ctx,
				get_cfg = function()
					return cfg
				end,
				svc = {
					session = {
						info = function()
							return cur_sess
						end,
						add_record = function(_, kind, data)
							recorded_runs[#recorded_runs + 1] = { kind = kind, data = data }
							return { durable = true }
						end,
					},
				},
				runner = function(spec, opts)
					seen_specs[#seen_specs + 1] = spec
					if spec.prompt == "fail-stage" then
						return { ok = false, status = "failed", error = "agent failed" }
					end
					if spec.prompt == "big-json" then
						return { ok = true, status = "completed", structured = { msg = string.rep("Z", 100) } }
					end
					if spec.prompt == "slow-ok" then
						mare.task.sleep(250, opts.cancel)
						return { ok = true, status = "completed", text = "slow" }
					end
					if spec.prompt == "stubborn" then
						mare.task.sleep(400) -- ignores opts.cancel past stop_grace_ms = 80
						return { ok = true, status = "completed", text = "too late" }
					end
					return { ok = true, status = "completed", text = "ok:" .. spec.prompt }
				end,
			})

			-- Nested [[[1]]] returns fast without recursion, hidden timers, pipeline stops on failed agent(), parallel populates stage, and child specs enforce depth-1
			local nested_args = mare.json.decode_lossless('{"values":[[[1]]]}')
			local p1_res = eng.run({
				meta = { name = "vm-fixes", description = "Test nested arrays, pipeline stop, child config" },
				args = nested_args,
				script = [[
				assert(setTimeout == nil and sleep == nil, "timers must be hidden")
				local pipe = pipeline({ "fail-stage", "good" },
					function(item) return agent(item, { tools = { "read", "subagent", "workflow" } }) end,
					function(val) return "STAGE2:" .. tostring(val) end
				)
				assert(pipe[1] == nil and pipe.errors[1].kind == "agent" and pipe.errors[1].stage == 1)
				assert(pipe[2] == "STAGE2:ok:good")
				local par = parallel({ function() return agent("fail-stage") end })
				assert(par.errors[1].stage == 1)
				return { values = args.values, pipe = pipe }
			]],
			})
			expect.falsy(p1_res.is_error, p1_res.content)
			expect.eq(p1_res.details.result.values[1][1][1], 1)
			expect.eq(p1_res.details.result.pipe[1], mare.json.null)
			expect.eq(p1_res.details.result.pipe[2], "STAGE2:ok:good")

			-- Verify child spawn_spec disables subagent & workflow plugins and strips them from tools
			local saw_stripped = false
			for _, sp in ipairs(seen_specs) do
				if sp.tools then
					saw_stripped = true
					expect.eq(#sp.tools, 1)
					expect.eq(sp.tools[1], "read")
				end
				expect.eq(sp.config.plugins.subagent.enabled, false)
				expect.eq(sp.config.plugins.workflow.enabled, false)
			end
			expect.truthy(saw_stripped)

			-- opts = false is fatal abort
			local bad_opts = eng.run({
				meta = { name = "bad-opts", description = "opts=false" },
				script = [[ return agent("ok", false) ]],
			})
			expect.truthy(bad_opts.is_error)
			expect.match(bad_opts.content, "agent%(%) opts must be an object")

			-- child_result_chars enforced on structured output
			local big_struct = eng.run({
				meta = { name = "big-struct", description = "Oversized structured" },
				script = [[
				local S = { type = "object", properties = { msg = { type = "string" } }, required = { "msg" } }
				local v = parallel({ function() return agent("big-json", { schema = S }) end })
				return { val = v[1], err = v.errors[1] and v.errors[1].message }
			]],
			})
			expect.falsy(big_struct.is_error)
			expect.eq(big_struct.details.result.val, nil)
			expect.match(big_struct.details.result.err, "child_result_chars")

			-- Per-slice watchdog catches infinite sync loop in worker 2 even while worker 1 awaits agent()
			local saved_sync_timeout = cfg.sync_timeout_ms
			cfg.sync_timeout_ms = 150
			local spin_with_sibling = eng.run({
				meta = { name = "sibling-spin", description = "Watchdog with active sibling" },
				script = [[
				return parallel({
					function() return agent("slow-ok") end,
					function() while true do end end,
				})
			]],
			})
			cfg.sync_timeout_ms = saved_sync_timeout
			expect.truthy(spin_with_sibling.is_error)
			expect.match(spin_with_sibling.content, "sync_timeout_ms")

			-- Stop unconfirmed propagates when child handle ignores cancel beyond stop_grace_ms
			local tok2 = mare.task.token()
			local started_tx, started_rx = mare.task.channel()
			local t_can = mare.task.spawn(function()
				started_rx:recv()
				tok2:cancel()
			end)
			local unconf_eng = engine_mod.new({
				ctx = ctx,
				get_cfg = function()
					return cfg
				end,
				svc = {
					session = {
						info = function()
							return cur_sess
						end,
						add_record = function(_, kind, data)
							recorded_runs[#recorded_runs + 1] = { kind = kind, data = data }
							return { durable = true }
						end,
					},
				},
				runner = nil, -- use default_spawn_runner with mocked mare.subagent.start
			})
			local orig_subagent = mare.subagent
			mare.subagent = {
				start = function()
					started_tx:send(true)
					return {
						wait = function()
							mare.task.sleep(300)
							return { text = "late" }
						end,
						cancel = function() end,
					}
				end,
			}
			local unconf_res = unconf_eng.run({
				meta = { name = "unconf", description = "Stubborn child" },
				script = [[ return agent("stubborn") ]],
			}, { cancel = tok2 })
			t_can:wait()
			mare.subagent = orig_subagent
			expect.truthy(unconf_res.is_error)
			expect.truthy(unconf_res.cancelled)
			expect.truthy(unconf_res.stop_unconfirmed)
			local last_rec = recorded_runs[#recorded_runs]
			expect.eq(last_rec.kind, "workflow/run-end")
			expect.eq(last_rec.data.stop_unconfirmed, true)

			-- Session switch mid-run cancels workflow
			local sw_task = mare.task.spawn(function()
				mare.task.sleep(30)
				cur_sess = { session_id = "sess-b", session_epoch = "gen-2", ephemeral = false, readonly = false }
				eng.on_session_changed()
			end)
			local sw_res = eng.run({
				meta = { name = "sess-switch", description = "Switch mid-run" },
				script = [[ return agent("slow-ok") ]],
			})
			sw_task:wait()
			expect.truthy(sw_res.is_error)
			expect.truthy(sw_res.cancelled)

			-- FIFO write queue keeps strict 1 -> 2 -> 3 order when writer 2 fails
			local order_log = {}
			local seq_seen = {}
			local q_w = records.new_writer(function()
				return {
					info = function()
						return { session_id = "fifo-s", session_epoch = "g1", ephemeral = false, readonly = false }
					end,
					add_record = function(_, kind, data)
						order_log[#order_log + 1] = kind
						if kind == "workflow/run-start" then
							return { durable = true }
						end
						seq_seen[#seq_seen + 1] = data.seq
						mare.task.sleep(25)
						if #order_log == 3 then
							error("second failed", 0)
						end
						return { durable = true }
					end,
				}
			end)
			expect.truthy(q_w.run_start({ run_id = "fifo-1" }))
			local f1 = mare.task.spawn(function()
				q_w.agent_start(1, { run_id = "fifo-1", seq = 1 })
			end)
			mare.task.sleep(3)
			local f2 = mare.task.spawn(function()
				q_w.agent_start(2, { run_id = "fifo-1", seq = 2 })
			end)
			mare.task.sleep(3)
			local f3 = mare.task.spawn(function()
				q_w.agent_start(3, { run_id = "fifo-1", seq = 3 })
			end)
			f1:wait()
			f2:wait()
			f3:wait()
			-- Caller 1 succeeded (#2), caller 2 failed (#3), caller 3 saw failed=true and did not append
			expect.eq(#order_log, 3)
			expect.eq(seq_seen[1], 1)
			expect.eq(seq_seen[2], 2)

			-- stop_unconfirmed holds semaphore slot (concurrency=1 does not admit second child over unconfirmed stop)
			local sem_cap_seen = 0
			local conc_cfg = config.normalize({ max_concurrent_agents = 1, sync_timeout_ms = 2000, stop_grace_ms = 50 })
			local tok_sem = mare.task.token()
			local t_sem_cancel = mare.task.spawn(function()
				mare.task.sleep(60)
				tok_sem:cancel()
			end)
			local unconf_sem_eng = engine_mod.new({
				ctx = ctx,
				get_cfg = function()
					return conc_cfg
				end,
				svc = {
					session = {
						info = function()
							return { session_id = "s-sem", session_epoch = "g1", ephemeral = false, readonly = false }
						end,
					},
				},
				runner = function()
					sem_cap_seen = sem_cap_seen + 1
					return { ok = false, status = "stop_unconfirmed", stop_unconfirmed = true, error = "hung" }
				end,
			})
			local cap_res = unconf_sem_eng.run({
				meta = { name = "unconf-cap", description = "Capacity retained" },
				script = [[
					return parallel({
						function() return agent("first") end,
						function() return agent("second") end,
					})
				]],
			}, { cancel = tok_sem })
			t_sem_cancel:wait()
			-- Because first child returned stop_unconfirmed, semaphore slot stays held and second child never runs
			expect.eq(sem_cap_seen, 1)
			expect.truthy(cap_res.stop_unconfirmed)
			local tracked_job = nil
			local bg_eng = engine_mod.new({
				ctx = ctx,
				get_cfg = function()
					return conc_cfg
				end,
				svc = {
					session = {
						info = function()
							return { session_id = "s-bg", session_epoch = "g1", ephemeral = false, readonly = false }
						end,
					},
					jobs = {
						track = function(_, j)
							tracked_job = j
							return { job_id = "job-bg-1" }
						end,
					},
				},
				runner = function()
					return { ok = false, status = "stop_unconfirmed", stop_unconfirmed = true, error = "stuck" }
				end,
			})
			bg_eng.run({
				meta = { name = "bg-unconf", description = "Propagates stop_unconfirmed" },
				script = [[ return agent("hung") ]],
				run_in_background = true,
			})
			local bg_waited = tracked_job.handle:wait({ timeout_ms = 1000 })
			expect.eq(bg_waited.state, "exited")
			expect.eq(bg_waited.code, 1)
			expect.eq(bg_waited.stop_unconfirmed, true)
			expect.eq(tracked_job.handle:stop().stop_unconfirmed, true)

			-- ctx:spawn failure finalizes tracked job handle & pre-worker session switch writes 0 records to session B
			local spawn_fail_job = nil
			local bad_spawn_ctx = {
				spawn = function()
					error("spawn queue full")
				end,
			}
			local bad_bg_eng = engine_mod.new({
				ctx = bad_spawn_ctx,
				get_cfg = function()
					return cfg
				end,
				svc = {
					session = {
						info = function()
							return { session_id = "s-sp", session_epoch = "g1", ephemeral = false, readonly = false }
						end,
					},
					jobs = {
						track = function(_, j)
							spawn_fail_job = j
							return { job_id = "job-fail-1" }
						end,
					},
				},
			})
			local sp_fail_res = bad_bg_eng.run({
				meta = { name = "bg-spawn-fail", description = "Spawn throws" },
				script = [[ return 1 ]],
				run_in_background = true,
			})
			expect.truthy(sp_fail_res.is_error)
			expect.eq(spawn_fail_job.handle:status().state, "exited")
			expect.eq(spawn_fail_job.handle:status().code, 1)

			-- Pre-worker session switch writes zero records to B
			local pre_recs = {}
			local pre_sess = { session_id = "sess-A", session_epoch = "g1", ephemeral = false, readonly = false }
			local tracked_sw = nil
			local delayed_ctx = {
				spawn = function(_, fn)
					return mare.task.spawn(function()
						mare.task.sleep(25)
						fn()
					end)
				end,
			}
			local pre_eng = engine_mod.new({
				ctx = delayed_ctx,
				get_cfg = function()
					return cfg
				end,
				svc = {
					session = {
						info = function()
							return pre_sess
						end,
						add_record = function(_, k, d)
							pre_recs[#pre_recs + 1] = { k = k, d = d }
							return { durable = true }
						end,
					},
					jobs = {
						track = function(_, j)
							tracked_sw = j
							return { job_id = "job-sw-1" }
						end,
					},
				},
				runner = runner,
			})
			pre_eng.run({
				meta = { name = "pre-sw", description = "Switch before spawn runs" },
				script = [[ return agent("a") ]],
				run_in_background = true,
			})
			pre_sess = { session_id = "sess-B", session_epoch = "g2", ephemeral = false, readonly = false }
			local pre_wait = tracked_sw.handle:wait({ timeout_ms = 1000 })
			expect.eq(pre_wait.state, "exited")
			expect.eq(pre_wait.code, 1)
			expect.eq(#pre_recs, 0)

			-- Recheck P2s: mixed table in log() inside parallel is fatal; implicit phase provider rejected; structured null preserved via lossless decode
			local mixed_log = eng.run({
				meta = { name = "mixed-log", description = "Mixed table fatal" },
				script = [[
					return parallel({
						function()
							log({ "a", foo = "bar" })
							return "ok"
						end,
					})
				]],
			})
			expect.truthy(mixed_log.is_error)
			expect.match(mixed_log.content, "mix array and object")

			local default_prov_eng = engine_mod.new({
				ctx = ctx,
				get_cfg = function()
					return cfg
				end,
				svc = {
					session = {
						info = function()
							return cur_sess
						end,
					},
				},
			})
			local imp_prov = default_prov_eng.run({
				meta = {
					name = "imp-prov",
					description = "Implicit phase provider",
					phases = { { title = "Bad", provider = "claude" } },
				},
				script = [[
					phase("Bad")
					return agent("x")
				]],
			})
			expect.truthy(imp_prov.is_error)
			expect.match(imp_prov.content, "unsupported workflow provider")

			local null_eng = engine_mod.new({
				ctx = ctx,
				get_cfg = function()
					return cfg
				end,
				svc = {
					session = {
						info = function()
							return cur_sess
						end,
					},
				},
				runner = function()
					-- Simulate structured decoding dropping a null key while lossless JSON text preserves it
					return { ok = true, text = '{"val": null}', structured = {} }
				end,
			})
			local null_res = null_eng.run({
				meta = { name = "null-field", description = "Nullable required field" },
				script = [[
					local S = {
						type = "object",
						properties = { val = { type = { "string", "null" } } },
						required = { "val" },
					}
					local r = agent("n", { schema = S })
					return { is_null = r.val == json.null }
				]],
			})
			expect.falsy(null_res.is_error)
			expect.eq(null_res.details.result.is_null, true)
		end
	)

	it(
		"enforces bus isolation, stop_unconfirmed waiter wake, over_limit, tool ceiling, vm breakout, live config, and log guards",
		function()
			support.preload_modules("workflow", {
				"workflow.config",
				"workflow.schema",
				"workflow.events",
				"workflow.records",
				"workflow.vm",
				"workflow.engine",
			})
			local events_mod = require("workflow.events")
			local vm_mod = require("workflow.vm")
			local engine_mod = require("workflow.engine")
			local config_mod = require("workflow.config")
			local wf_plugin = dofile("plugins/workflow/init.lua")

			-- ctx.bus emits canonical workflow/* once, never falls back to workflow-orch/* or bare ctx:emit
			local bus_calls = {}
			local bare_emit_calls = 0
			events_mod.emit({
				emit = function()
					bare_emit_calls = bare_emit_calls + 1
				end,
				bus = {
					emit = function(_, name, payload)
						bus_calls[#bus_calls + 1] = name
						if name:sub(1, 9) == "workflow/" then
							error("event `" .. name .. "` rejected", 0)
						end
						return true
					end,
				},
			}, "workflow/started", { run_id = "r1" })
			expect.eq(bare_emit_calls, 0)
			expect.eq(#bus_calls, 1)
			expect.eq(bus_calls[1], "workflow/started")

			-- Clamp stop_grace_ms <= 600000
			expect.eq(config_mod.normalize({ stop_grace_ms = 999999 }).stop_grace_ms, 600000)

			-- Syntactic breakout & upvalue capture attempt on __wf_finish rejected cleanly
			local breakout = vm_mod.run({
				script = [[ end; __wf_finish = function() return "pwned" end; local function f() ]],
				cfg = config_mod.normalize({}),
				concurrency = 1,
				callbacks = {
					phase = function()
						return true
					end,
					log = function()
						return true
					end,
					check_items = function()
						return { ok = true }
					end,
					agent = function()
						return { ok = true }
					end,
				},
			})
			expect.falsy(breakout.ok)

			-- Setting global __wf_finish or calling error cannot replace __wf_finish
			local tamper = vm_mod.run({
				script = [[ __wf_finish = function() return "hijacked" end; return { ok = 42 } ]],
				cfg = config_mod.normalize({}),
				concurrency = 1,
				callbacks = {
					phase = function()
						return true
					end,
					log = function()
						return true
					end,
					check_items = function()
						return { ok = true }
					end,
					agent = function()
						return { ok = true }
					end,
				},
			})
			expect.truthy(tamper.ok)
			expect.eq(tamper.result.ok, 42)

			-- log(nil) is guarded & tight log() loop cannot starve sync_timeout_ms
			local starved = vm_mod.run({
				script = [[
				while true do
					log(nil)
				end
			]],
				cfg = config_mod.normalize({ sync_timeout_ms = 60, stop_grace_ms = 100 }),
				concurrency = 1,
				callbacks = {
					phase = function()
						return true
					end,
					log = function()
						mare.task.sleep(10)
						return true
					end,
					check_items = function()
						return { ok = true }
					end,
					agent = function()
						return { ok = true }
					end,
				},
			})
			expect.falsy(starved.ok)
			expect.match(starved.error, "sync_timeout_ms")

			-- stop_unconfirmed with concurrency = 1 wakes queued waiter instead of hanging forever; tool ceiling and bounded logs
			local spawned_specs = {}
			local base_cfg =
				config_mod.normalize({ max_concurrent_agents = 1, stop_grace_ms = 50, sync_timeout_ms = 2000 })
			local eng = engine_mod.new({
				ctx = {
					bus = {
						emit = function()
							return true
						end,
					},
					spawn = function(_, fn)
						return mare.task.spawn(fn)
					end,
				},
				get_cfg = function()
					return base_cfg
				end,
				svc = {
					session = {
						info = function()
							return { session_id = "s1", session_epoch = "g1" }
						end,
					},
					subagent = {
						list_types = function()
							return { data = { { name = "restricted", tools = { "read" } } } }
						end,
					},
					jobs = {
						track = function(_, spec)
							return { job_id = "job-over", over_limit = 2 }
						end,
						kill = function() end,
					},
				},
				runner = function(spec)
					spawned_specs[#spawned_specs + 1] = spec
					if #spawned_specs == 1 then
						return { ok = false, status = "timeout", error = "timed out", stop_unconfirmed = true }
					end
					return { ok = true, text = "ok" }
				end,
			})

			local unconf_res = eng.run({
				meta = { name = "unconf-hang", description = "Wakes queued waiter on stop_unconfirmed" },
				script = [[
				local r = parallel({
					function() return agent("first") end,
					function() return agent("second") end,
				})
				return r
			]],
			}, { declared_tools = { "read", "grep", "workflow", "subagent" } })
			expect.truthy(unconf_res.stop_unconfirmed)
			-- Only worker 1 started; worker 2 rejected cleanly without hanging!
			expect.eq(#spawned_specs, 1)
			-- Child tools exclude disallowed tools, workflow tool, and obey parent declared_tools
			expect.eq(table.concat(spawned_specs[1].tools, ","), "read,grep")

			-- over_limit check rejects background workflow before spawning
			local over_res = eng.run({
				meta = { name = "over-bg", description = "Over limit" },
				script = [[ return agent("a") ]],
				run_in_background = true,
			})
			expect.truthy(over_res.is_error)
			expect.match(over_res.content, "too many background jobs")

			-- log(nil) and bounded run.logs (cap enforced)
			local log_cfg =
				config_mod.normalize({ max_concurrent_agents = 1, stop_grace_ms = 50, sync_timeout_ms = 30000 })
			local log_eng = engine_mod.new({
				ctx = { bus = {
					emit = function()
						return true
					end,
				} },
				max_run_logs = 10,
				get_cfg = function()
					return log_cfg
				end,
				svc = {
					session = {
						info = function()
							return { session_id = "s1", session_epoch = "g1" }
						end,
					},
				},
				runner = function()
					return { ok = true, text = "done" }
				end,
			})
			local log_res = log_eng.run({
				meta = { name = "logs-bound", description = "Bounded logs" },
				script = [[
				log(nil)
				for i = 1, 15 do
					log("line-" .. i)
				end
				return "ok"
			]],
			})
			expect.eq(log_res.is_error and log_res.content or false, false)
			expect.eq(#log_res.details.run.logs, 10)
			expect.eq(log_res.details.run.logs[10].message, "line-15")

			-- stop_grace_ms schema max = 600000
			expect.eq(wf_plugin.config_schema.stop_grace_ms.max, 600000)

			-- make_job_buffer keeps UTF-8 boundaries across overflow trim, read_at max_bytes, and tail
			local buf = engine_mod.make_job_buffer(14)
			buf.append("中文字")
			buf.append("测试行")
			local r1 = buf.read_at(0, { max_bytes = 5 })
			expect.truthy(utf8.len(r1.text) ~= nil)
			local t = buf.tail(5)
			expect.truthy(utf8.len(t) ~= nil)

			-- max_bytes < 4 is rejected cleanly without stalling or advancing the cursor
			local cbuf = engine_mod.make_job_buffer(64)
			cbuf.append("中文字")
			expect.error(function()
				cbuf.read_at(0, { max_bytes = 2 })
			end, "max_bytes must be at least 4")
			expect.error(function()
				cbuf.read_consuming({ max_bytes = 3 })
			end, "max_bytes must be at least 4")
			local c1 = cbuf.read_consuming({ max_bytes = 4 })
			expect.eq(c1.text, "中")
			local total1, unread1 = cbuf.stats()
			expect.eq(total1, 10)
			expect.eq(unread1, 7)
			local c2 = cbuf.read_consuming({ max_bytes = 16 })
			expect.eq(c2.text, "文字\n")
			local _, unread2 = cbuf.stats()
			expect.eq(unread2, 0)
		end
	)
end)
