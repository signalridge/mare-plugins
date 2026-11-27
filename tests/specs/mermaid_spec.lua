local support = assert(load(mare.fs.read("tests/specs/support.lua"), "@tests/specs/support.lua"))()
local H = support.load_lua("tests/specs/mermaid_support.lua")
local Profile = require("mermaid.profile")

local describe = mare.test.describe
local it = mare.test.it
local before_each = mare.test.before_each
local after_each = mare.test.after_each
local expect = mare.test.expect

describe("mermaid", function()
	local env, gates

	before_each(function()
		gates = {}
	end)

	after_each(function()
		if env then
			env.dispose()
			env.restore()
			env = nil
		end
	end)

	it("validates config defaults, profile estimation, bucketing, and bounds", function()
		env = H.make_env()
		local plugin = H.plugin
		local cfg = H.support.default_config(plugin)

		expect.eq(cfg.streaming_preview, true)
		expect.eq(cfg.expanded_max_rows, 200)
		expect.eq(cfg.max_nodes, 100)
		expect.eq(cfg.max_edges, 200)
		expect.eq(cfg.max_heap_mb, 512)
		expect.eq(cfg.node_spacing, 80)
		expect.eq(cfg.rank_spacing, 80)
		expect.eq(cfg.node_padding_x, 40)
		expect.eq(cfg.node_padding_y, 20)

		local est =
			Profile.estimate_diagram_size("%% comment\ngraph TD\nA[Start] --> B[End]\nB -.-> C{Done}\nD(Extra)\n")
		expect.eq(est.nodes, 4)
		expect.eq(est.edges, 2)

		expect.eq(Profile.bucket_width(77), 80)
		expect.eq(Profile.bucket_width(80), 80)
		expect.eq(Profile.bucket_width(81), 84)

		local g = Profile.inline_aspect_goal(80, 24, { 8, 16 })
		expect.truthy(g and g >= 4 / 3 and g <= 6.0)
		expect.eq((g * 4) % 1, 0)

		local p1 = Profile.new(cfg, { source = "graph TD\nA-->B", width = 77, height = 24 })
		local p2 = Profile.new(cfg, { source = "graph TD\nA-->B", width = 80, height = 24 })
		local p3 = Profile.new(cfg, { source = "graph TD\nA-->B", width = 81, height = 24 })
		expect.eq(Profile.key(cfg, "graph TD\nA-->B", p1), Profile.key(cfg, "graph TD\nA-->B", p2))
		expect.truthy(Profile.key(cfg, "graph TD\nA-->B", p2) ~= Profile.key(cfg, "graph TD\nA-->B", p3))

		local p_zoom = Profile.new(cfg, { source = "graph TD\nA-->B", width = 80, height = 24, zoom_percent = 200 })
		expect.truthy(p_zoom.size_px > p2.size_px and p_zoom.size_px <= cfg.max_pixels)

		local p_light = Profile.new(cfg, {
			source = "graph TD\nA-->B",
			width = 80,
			height = 24,
			theme = { code_background = "#ffffff", appearance = "light" },
		})
		expect.eq(p2.theme, "dark")
		expect.eq(p_light.theme, "default")

		expect.eq(plugin.config_schema.max_nodes.min, 1)
	end)

	it("isolates occurrences, dedups shared source, upgrades open->closed, and handles zoom & viewer", function()
		env = H.make_env({
			proc_gate_factory = function(_, idx)
				local g = mare.task.token()
				gates[idx] = g
				return g
			end,
		})
		H.apply_plugin(env)
		expect.truthy(env.presenters.mermaid)
		local presenter = env.presenters.mermaid
		expect.eq(presenter.preview, true)

		-- Trivial single-line open block skipped
		local trivial_res = "unset"
		local triv_tx, triv_rx = mare.task.channel()
		mare.task.spawn(function()
			trivial_res = presenter.render(H.render_request({
				source = "graph TD",
				phase = "open",
				block_id = "triv",
			}))
			triv_tx:send(true)
		end)
		triv_rx:recv()
		expect.eq(trivial_res, nil)
		expect.eq(#env.proc_runs, 0)

		-- Shared source dedup across two occurrences: cancelling occ1 leaves occ2 intact
		local res1, res2 = "unset", "unset"
		local c1, c2 = mare.task.token(), mare.task.token()
		local ch1_tx, ch1_rx = mare.task.channel()
		local ch2_tx, ch2_rx = mare.task.channel()
		mare.task.spawn(function()
			res1 = presenter.render(H.render_request({
				source = "graph TD\nA[Shared]-->B[Target]",
				block_id = "occ-1",
				cancel = c1,
			}))
			ch1_tx:send(true)
		end)
		mare.task.spawn(function()
			res2 = presenter.render(H.render_request({
				source = "graph TD\nA[Shared]-->B[Target]",
				block_id = "occ-2",
				cancel = c2,
			}))
			ch2_tx:send(true)
		end)
		expect.truthy(H.wait_until(function()
			return #env.proc_runs == 1
		end))
		mare.task.sleep(15)
		expect.eq(#env.proc_runs, 1)

		c1:cancel()
		ch1_rx:recv()
		expect.eq(res1, nil)
		expect.truthy(not gates[1]:is_cancelled() or res2 == "unset")

		gates[1]:cancel()
		ch2_rx:recv()
		expect.eq(type(res2), "table")
		expect.truthy(res2.compact and res2.expanded)
		expect.eq(res2.compact.max_rows, 20)
		expect.eq(res2.expanded.max_rows, 200)

		-- Verify --max-old-space-size and adapter timeout/heap input
		local run1 = env.proc_runs[1]
		expect.eq(run1.args[1], "--max-old-space-size=512")
		expect.match(run1.input, '"timeout_ms":15000')
		expect.match(run1.input, '"max_heap_mb":512')

		-- open -> closed transition on same occurrence upgrades cleanly
		local closed_res = "unset"
		local open_tx, open_rx = mare.task.channel()
		local closed_tx, closed_rx = mare.task.channel()
		mare.task.spawn(function()
			presenter.render(H.render_request({
				source = "graph TD\nStream1[Open]-->Stream2",
				phase = "open",
				block_id = "occ-stream",
			}))
			open_tx:send(true)
		end)
		expect.truthy(H.wait_until(function()
			return #env.proc_runs == 2
		end))

		mare.task.spawn(function()
			closed_res = presenter.render(H.render_request({
				source = "graph TD\nStream1[Open]-->Stream2",
				phase = "closed",
				block_id = "occ-stream",
			}))
			closed_tx:send(true)
		end)
		mare.task.sleep(20)
		expect.eq(#env.proc_runs, 2)
		gates[2]:cancel()
		open_rx:recv()
		closed_rx:recv()
		expect.eq(type(closed_res), "table")
		expect.truthy(closed_res.compact and closed_res.expanded)
		-- Read the saved PNG back by its handle.
		local function find_image(node, seen)
			seen = seen or {}
			if type(node) ~= "table" or seen[node] then
				return nil
			end
			seen[node] = true
			if node.kind == "artifact_image" then
				return node
			end
			for _, v in pairs(node) do
				local hit = find_image(v, seen)
				if hit then
					return hit
				end
			end
		end
		local image = find_image(closed_res.compact)
		expect.truthy(image)
		expect.truthy(image.read_bytes > 0)

		-- Zoom command + viewer + transcript-scoped keymaps
		expect.truthy(env.commands.mermaid)
		env.commands.mermaid.run("zoom 150")
		expect.truthy(#env.emitted >= 1)
		expect.eq(env.emitted[#env.emitted].name, "ui/presentation-invalidate")

		local zoomed_res
		local zoom_tx, zoom_rx = mare.task.channel()
		mare.task.spawn(function()
			zoomed_res = presenter.render(H.render_request({
				source = "graph TD\nZ[Zoom]-->W",
				block_id = "occ-zoom",
			}))
			zoom_tx:send(true)
		end)
		expect.truthy(H.wait_until(function()
			return gates[3] ~= nil
		end))
		gates[3]:cancel()
		zoom_rx:recv()
		expect.truthy(zoomed_res)
		expect.eq(zoomed_res.compact.max_rows, 30)

		env.commands.mermaid.run("")
		expect.truthy(env.get_transcript())
		expect.eq(env.get_transcript().title, "Mermaid Viewer")

		env.set_transcript("Session Transcript")
		expect.eq(env.keymap_actions["mermaid.zoom_in"].fn(), false)
		env.set_transcript("Mermaid Viewer")
		env.keymap_actions["mermaid.zoom_in"].fn()
		expect.truthy(env.notifications[#env.notifications] or #env.emitted >= 2)
	end)

	it("enforces complexity bounds, queue backpressure, and immediate cancelled-waiter eviction", function()
		env = H.make_env({
			proc_gate_factory = function(_, idx)
				local g = mare.task.token()
				gates[idx] = g
				return g
			end,
		})
		H.apply_plugin(env, { max_nodes = 2, max_edges = 2 })
		expect.truthy(env.presenters.mermaid)
		local presenter = env.presenters.mermaid

		-- Complexity limit rejection in tool and presenter
		local tool_rej = env.tools.mermaid.execute({ source = "graph TD\nA[1]-->B[2]\nB-->C[3]\nC-->D[4]" }, {})
		expect.truthy(tool_rej.is_error)
		expect.match(tool_rej.content, "complexity limit")
		expect.eq(#env.proc_runs, 0)

		local pres_rej = "unset"
		local rej_tx, rej_rx = mare.task.channel()
		mare.task.spawn(function()
			pres_rej = presenter.render(H.render_request({
				source = "graph TD\nA[1]-->B[2]\nB-->C[3]\nC-->D[4]",
				block_id = "too-big",
			}))
			rej_tx:send(true)
		end)
		rej_rx:recv()
		expect.eq(pres_rej, nil)
		expect.eq(#env.proc_runs, 0)

		-- Queue capacity (2 active + 16 waiting = 18) + immediate cancelled-waiter eviction
		local results = {}
		local cancels = {}
		local rxs = {}
		for i = 1, 18 do
			cancels[i] = mare.task.token()
			local tx, rx = mare.task.channel()
			rxs[i] = rx
			mare.task.spawn(function()
				results[i] = presenter.render(H.render_request({
					source = "graph TD\nN" .. i .. "-->M" .. i,
					block_id = "q-" .. i,
					cancel = cancels[i],
				}))
				tx:send(true)
			end)
		end
		expect.truthy(H.wait_until(function()
			return #env.proc_runs == 2
		end))
		mare.task.sleep(20)
		expect.eq(#env.proc_runs, 2)

		-- 19th distinct request hits backpressure immediately
		local res19 = "unset"
		local ch19_tx, ch19_rx = mare.task.channel()
		mare.task.spawn(function()
			res19 = presenter.render(H.render_request({
				source = "graph TD\nN19-->M19",
				block_id = "q-19",
			}))
			ch19_tx:send(true)
		end)
		ch19_rx:recv()
		expect.eq(res19, nil)

		-- Cancel queued waiter #3 BEFORE releasing active workers 1 or 2 -> immediate eviction frees slot!
		cancels[3]:cancel()
		rxs[3]:recv()
		expect.eq(results[3], nil)

		local res20 = "unset"
		local ch20_tx, ch20_rx = mare.task.channel()
		mare.task.spawn(function()
			res20 = presenter.render(H.render_request({
				source = "graph TD\nN20-->M20",
				block_id = "q-20",
			}))
			ch20_tx:send(true)
		end)
		mare.task.sleep(20)
		expect.eq(res20, "unset")

		-- Release all active/subsequent gates
		local idx = 1
		while true do
			if not H.wait_until(function()
				return gates[idx] ~= nil
			end, 200) then
				break
			end
			gates[idx]:cancel()
			idx = idx + 1
		end
		ch20_rx:recv()
		for i = 1, 18 do
			if i ~= 3 then
				rxs[i]:recv()
			end
		end
		expect.eq(#env.proc_runs, 18)
		expect.eq(type(res20), "table")
		expect.truthy(res20.compact)
	end)

	it("degrades cleanly when result_pipeline or artifact_image is unavailable", function()
		env = H.make_env()
		env.ctx.tools.capabilities = nil
		H.apply_plugin(env)
		expect.eq(env.presenters.mermaid, nil)
		expect.truthy(#env.notifications >= 1)
		expect.truthy(env.notifications[#env.notifications].msg:find("result pipeline", 1, true))
		env.dispose()
		env.restore()

		env = H.make_env()
		env.ctx.ui.artifact_image = nil
		H.apply_plugin(env)
		expect.eq(env.presenters.mermaid, nil)
		expect.truthy(#env.notifications >= 1)
		expect.truthy(env.notifications[#env.notifications].msg:find("image resources", 1, true))
	end)

	it(
		"counts multi-node/edge diagrams, builds hardened mmdc config, uses ctx.ui:invalidate_presentations, and drops failed records",
		function()
			-- Diagram estimation covers ;, &, bare nodes, and sequence/class/ER/state edges
			local complex = Profile.estimate_diagram_size(table.concat({
				"graph TD",
				"A[One] & B[Two] --> C[Three]; D --> E",
				"sequenceDiagram",
				"Alice->>Bob: hi",
				"erDiagram",
				"CUSTOMER ||--o{ ORDER : places",
			}, "\n"))
			expect.truthy(complex.nodes >= 9)
			expect.truthy(complex.edges >= 5)

			-- Hardened config generation in adapter.lua
			local Adapter = require("mermaid.adapter")
			expect.truthy(type(Adapter) == "string")
			expect.truthy(Adapter:find("securityLevel:'strict'", 1, true))
			expect.truthy(Adapter:find("htmlLabels:false", 1, true))
			expect.truthy(Adapter:find("themeCSS:''", 1, true))
			expect.truthy(Adapter:find("maxEdges:maxEdges", 1, true))

			-- Invalidation via ctx.ui:invalidate_presentations and failed record cleanup
			env = H.make_env()
			local invalidate_calls = 0
			env.ctx.ui.invalidate_presentations = function(_, opts)
				invalidate_calls = invalidate_calls + 1
				expect.eq(opts.reason, "mermaid-zoom")
				expect.eq(opts.zoom_percent, 125)
			end
			local Viewer = require("mermaid.viewer")
			local v = Viewer.new(env.ctx, H.support.default_config(H.plugin), {
				get_automatic = function()
					return true
				end,
				is_disposed = function()
					return false
				end,
			})
			v:set_zoom(125, true)
			expect.eq(invalidate_calls, 1)

			-- Failed session:record must not cache artifact and must delete spill object
			local removed_handles = {}
			local orig_delete = mare.spill.delete
			mare.spill.delete = function(spill_id, opts)
				removed_handles[#removed_handles + 1] = { sid = opts and opts.session_id, spill_id = spill_id }
				return orig_delete(spill_id, opts)
			end
			env.ctx.session.add_record = function()
				error("disk full", 0)
			end
			H.apply_plugin(env)
			local tool_res = env.tools.mermaid.execute({ source = "graph TD\nX-->Y" }, { cancel = mare.task.token() })
			expect.truthy(tool_res.content:find("persistence failed", 1, true))
			expect.eq(#removed_handles, 1)
			expect.truthy(#env.proc_runs >= 1)
			local req_payload = mare.json.decode(env.proc_runs[#env.proc_runs].input)
			expect.eq(req_payload.max_edges, 200)
			-- Second attempt with recording restored must NOT hit stale cache
			local saved_count = 0
			env.ctx.session.add_record = function()
				saved_count = saved_count + 1
				return { durable = true }
			end
			local tool_res2 = env.tools.mermaid.execute({ source = "graph TD\nX-->Y" }, { cancel = mare.task.token() })
			expect.eq(saved_count, 1)
			expect.truthy(tool_res2.details and tool_res2.details.artifact)
			expect.truthy(tool_res2.value and tool_res2.value.artifact)
			expect.eq(tool_res2.for_program, nil)
		end
	)
end)
