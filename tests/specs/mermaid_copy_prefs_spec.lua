local support = assert(load(mare.fs.read("tests/specs/support.lua"), "@tests/specs/support.lua"))()
local H = support.load_lua("tests/specs/mermaid_support.lua")

local describe = mare.test.describe
local it = mare.test.it
local before_each = mare.test.before_each
local after_each = mare.test.after_each
local expect = mare.test.expect

describe("mermaid copy & prefs", function()
	local env, gates

	before_each(function()
		gates = {}
		env = H.make_env({
			proc_gate_factory = function(_, idx)
				local g = mare.task.token()
				gates[idx] = g
				return g
			end,
		})
		H.apply_plugin(env)
	end)

	after_each(function()
		if env then
			env.dispose()
			env.restore()
			env = nil
		end
	end)

	local function viewer_text()
		local t = env.get_transcript()
		return t and t.node and mare.json.encode(t.node) or ""
	end

	it("handles copy source states, timers, OSC 52, failures, and /mermaid on|off|toggle|prefs", function()
		local select_requests = {}

		expect.truthy(env.presenters.mermaid and env.presenters.mmd)

		-- Render two distinct active diagrams
		local src1 = "graph TD\nCopyA[First]-->CopyB[Second]"
		local src2 = "sequenceDiagram\nAlice->>Bob: Hello"
		local r1, r2
		local ch1_tx, ch1_rx = mare.task.channel()
		local ch2_tx, ch2_rx = mare.task.channel()
		mare.task.spawn(function()
			r1 = env.presenters.mermaid.render(H.render_request({ source = src1, block_id = "copy-1" }))
			ch1_tx:send(true)
		end)
		mare.task.spawn(function()
			r2 = env.presenters.mmd.render(H.render_request({ source = src2, block_id = "copy-2" }))
			ch2_tx:send(true)
		end)
		expect.truthy(H.wait_until(function()
			return gates[1] ~= nil and gates[2] ~= nil
		end))
		gates[1]:cancel()
		gates[2]:cancel()
		ch1_rx:recv()
		ch2_rx:recv()
		expect.truthy(r1 and r2)

		-- Open viewer and verify header shows [Copy Source] and auto on
		env.commands.mermaid.run("view")
		local tr = env.get_transcript()
		expect.truthy(tr and tr.title == "Mermaid Viewer")
		expect.truthy(viewer_text():find("[Copy Source]", 1, true))
		expect.truthy(viewer_text():find("auto on", 1, true))

		-- Copy key declines outside Mermaid Viewer
		env.set_transcript("Other View")
		expect.eq(env.keymap_actions["mermaid.copy_source"].fn(), false)

		-- Copy via viewer 'c' action -> native clipboard -> [Copied] -> revert after timer
		env.commands.mermaid.run("view")
		env.keymap_actions["mermaid.copy_source"].fn()
		expect.truthy(H.wait_until(function()
			return viewer_text():find("[Copied]", 1, true) ~= nil
		end))
		expect.eq(#env.clipboard_calls, 1)
		expect.eq(env.clipboard_calls[1], src2)
		expect.truthy(env.notifications[#env.notifications].msg:find("Copied Mermaid source", 1, true))

		-- Repeated copy before timer fires keeps [Copied] until latest timer fires
		mare.task.sleep(800)
		expect.truthy(viewer_text():find("[Copied]", 1, true))
		env.keymap_actions["mermaid.copy_source"].fn()
		expect.truthy(H.wait_until(function()
			return #env.clipboard_calls == 2
		end))
		mare.task.sleep(800)
		expect.truthy(viewer_text():find("[Copied]", 1, true))
		expect.truthy(H.wait_until(function()
			return viewer_text():find("[Copy Source]", 1, true) ~= nil
		end, 2000))

		-- OSC 52 copy never claims "Copied"
		env.set_clipboard_handler(function(text)
			return { ok = true, method = "osc52", verified = false, bytes = #text }
		end)
		env.commands.mermaid.run("copy 1")
		expect.truthy(H.wait_until(function()
			return viewer_text():find("[Sent via OSC 52]", 1, true) ~= nil
		end))
		expect.eq(env.clipboard_calls[3], src1)
		local osc_msg = env.notifications[#env.notifications].msg
		expect.truthy(osc_msg:find("OSC 52", 1, true) and not osc_msg:find("Copied", 1, true))
		expect.truthy(H.wait_until(function()
			return viewer_text():find("[Copy Source]", 1, true) ~= nil
		end, 2500))

		-- Clipboard failure sets [Copy failed]
		env.set_clipboard_handler(function()
			return { ok = false, bytes = 0, error = "no clipboard" }
		end)
		env.keymap_actions["mermaid.copy_source"].fn()
		expect.truthy(H.wait_until(function()
			return viewer_text():find("[Copy failed]", 1, true) ~= nil
		end))
		expect.eq(env.notifications[#env.notifications].level, "error")

		-- Switching diagram resets copy status
		env.keymap_actions["mermaid.prev"].fn()
		expect.truthy(viewer_text():find("[Copy Source]", 1, true))

		-- /mermaid off unregisters presenters and cancels inflight fence work
		local cancelled_render = "unset"
		expect.truthy(env.presenters.mermaid)
		local pending_presenter = env.presenters.mermaid
		local pend_tx, pend_rx = mare.task.channel()
		mare.task.spawn(function()
			cancelled_render = pending_presenter.render(
				H.render_request({ source = "graph TD\nPending-->Off", block_id = "pending-off" })
			)
			pend_tx:send(true)
		end)
		expect.truthy(H.wait_until(function()
			return gates[3] ~= nil
		end))
		env.commands.mermaid.run("off")
		pend_rx:recv()
		expect.eq(env.presenters.mermaid, nil)
		expect.eq(env.presenters.mmd, nil)
		expect.eq(cancelled_render, nil)
		expect.truthy(viewer_text():find("auto off", 1, true))

		-- Direct render call while disabled returns nil
		expect.eq(
			pending_presenter.render(
				H.render_request({ source = "graph TD\nDisabled-->Skip", block_id = "disabled-skip" })
			),
			nil
		)

		-- /mermaid on / toggle / prefs selector
		env.commands.mermaid.run("on")
		expect.truthy(env.presenters.mermaid and env.presenters.mmd)
		env.commands.mermaid.run("toggle")
		expect.eq(env.presenters.mermaid, nil)
		expect.eq(env.presenters.mmd, nil)

		env.set_select_handler(function(sopts)
			select_requests[#select_requests + 1] = sopts
			return 1
		end)
		env.commands.mermaid.run("prefs")
		expect.eq(#select_requests, 1)
		expect.eq(select_requests[1].selected, 2)
		expect.truthy(env.presenters.mermaid and env.presenters.mmd)

		env.set_select_handler(function(sopts)
			select_requests[#select_requests + 1] = sopts
			return nil
		end)
		env.commands.mermaid.run("prefs")
		expect.eq(#select_requests, 2)
		expect.eq(select_requests[2].selected, 1)
		expect.truthy(env.presenters.mermaid and env.presenters.mmd)
	end)
end)
