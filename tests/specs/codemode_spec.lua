local support = assert(load(mare.fs.read("tests/specs/support.lua"), "@tests/specs/support.lua"))()

local describe = mare.test.describe
local it = mare.test.it
local before_each = mare.test.before_each
local after_each = mare.test.after_each
local expect = mare.test.expect

local plugin = support.load_plugin("codemode", { "codemode.source", "codemode.present", "codemode.view" })
local source = require("codemode.source")
local present = require("codemode.present")
local view = require("codemode.view")

describe("codemode", function()
	local notifications
	local orig_notify

	before_each(function()
		notifications = {}
		orig_notify = mare.ui.notify
		mare.ui.notify = function(msg, level)
			notifications[#notifications + 1] = { msg = msg, level = level }
		end
	end)

	after_each(function()
		mare.ui.notify = orig_notify
	end)

	it("parses and validates source pragmas and exec options", function()
		local code, opts =
			source('-- @exec:{"yield_time_ms":100,"max_output_tokens":500}\nreturn 1', { yield_time_ms = 250 })
		expect.eq(code, "\nreturn 1")
		expect.eq(opts.yield_time_ms, 250)
		expect.eq(opts.max_output_tokens, 500)

		local _, opts2 = source("return 42", { timeout_ms = false })
		expect.eq(opts2.timeout_ms, false)

		local _, opts3 = source("return 42", { timeout_ms = 5000 })
		expect.eq(opts3.timeout_ms, 5000)

		expect.error(function()
			source("   ", {})
		end, "1%.%.65536 bytes")
		expect.error(function()
			source(string.rep("a", 65537), {})
		end, "1%.%.65536 bytes")
		expect.error(function()
			source('-- @exec:{"bad":1}\nreturn 1', {})
		end, "unknown exec option")
		expect.error(function()
			source('return 1\n-- @exec:{"yield_time_ms":100}', {})
		end, "first line")
		expect.error(function()
			source("return 1", { yield_time_ms = -1 })
		end, "invalid exec option: yield_time_ms")
		expect.error(function()
			source("return 1", { max_output_tokens = 1000001 })
		end, "invalid exec option: max_output_tokens")
		expect.error(function()
			source("return 1", { timeout_ms = 0 })
		end, "invalid exec option: timeout_ms")

		local crlf_code, crlf_opts = source('-- @exec:{"yield_time_ms":100,"max_output_tokens":500}\r\nreturn 1', {})
		expect.eq(crlf_code, "\nreturn 1")
		expect.eq(crlf_opts.yield_time_ms, 100)
		expect.eq(crlf_opts.max_output_tokens, 500)

		expect.error(function()
			source("-- @exec:   \nreturn 1", {})
		end, "exec options must be an object")
		expect.error(function()
			source("-- @exec: []\nreturn 1", {})
		end, "exec options must be an object")
		expect.error(function()
			source("-- @exec: 123\nreturn 1", {})
		end, "exec options must be an object")
		expect.error(function()
			source("-- @exec: bad json\nreturn 1", {})
		end)
	end)

	it("presents cell states and enforces output token budgets", function()
		local running = present({
			cell_id = "cell-1",
			status = "running",
			content = { { type = "text", text = "step 1" } },
			is_error = false,
		})
		expect.eq(running.content[1].text, "Script running with cell ID cell-1")
		expect.eq(running.content[2].text, "step 1")
		expect.eq(running.is_error, false)

		local completed =
			present({ status = "completed", content = { { type = "text", text = "ok" } }, is_error = false })
		expect.eq(completed.content[1].text, "Script completed")

		local cancelled = present({ status = "cancelled", content = {}, is_error = true })
		expect.eq(cancelled.content[1].text, "Script terminated")

		local failed = present({ status = "failed", content = {}, error = "cell gone", is_error = true })
		expect.eq(failed.content[1].text, "Script failed")
		expect.eq(failed.content[2].text, "cell gone")

		local partial_err = present({
			status = "failed",
			content = { { type = "text", text = "partial before failure\n" } },
			error = "boom",
			is_error = true,
		})
		expect.eq(partial_err.content[1].text, "Script failed")
		expect.eq(partial_err.content[2].text, "partial before failure\n")
		expect.eq(partial_err.content[3].text, "boom")

		local dedup_err = present({
			status = "failed",
			content = { { type = "text", text = "partial\n" }, { type = "text", text = "boom" } },
			error = "boom",
			is_error = true,
		})
		expect.eq(#dedup_err.content, 3)

		local truncated_short_err = present({
			status = "failed",
			content = { { type = "text", text = "HEAD...\n[script output truncated to this call's budget]" } },
			error = "permission denied",
			is_error = true,
		}, 64)
		expect.eq(#truncated_short_err.content, 3)
		expect.eq(truncated_short_err.content[3].text, "permission denied")

		local function total_text_bytes(blocks)
			local n = 0
			for _, block in ipairs(blocks) do
				if type(block.text) == "string" then
					n = n + #block.text
				end
			end
			return n
		end

		local truncated_long_err = present({
			status = "failed",
			content = {
				{ type = "text", text = "Script failed: bo...\n[script output truncated to this call's budget]" },
			},
			error = string.rep("E", 400) .. "_TAIL_SENTINEL",
			is_error = true,
		}, 16)
		expect.eq(#truncated_long_err.content, 3)
		expect.truthy(total_text_bytes(truncated_long_err.content) <= 16 * 4)
		expect.truthy(truncated_long_err.content[3].text:find("[error truncated to this call's budget]", 1, true))
		for _, block in ipairs(truncated_long_err.content) do
			expect.falsy(block.text:find("_TAIL_SENTINEL", 1, true))
		end

		local truncated_long_err_8_tokens = present({
			status = "failed",
			content = {
				{ type = "text", text = "Script failed: bo...\n[script output truncated to this call's budget]" },
			},
			error = string.rep("E", 400) .. "_TAIL_SENTINEL",
			is_error = true,
		}, 8)
		expect.eq(#truncated_long_err_8_tokens.content, 3)
		expect.truthy(total_text_bytes(truncated_long_err_8_tokens.content) <= 8 * 4)
		expect.truthy(truncated_long_err_8_tokens.content[3].text:find("E", 1, true))
		expect.truthy(truncated_long_err_8_tokens.content[3].text:find("...", 1, true))
		for _, block in ipairs(truncated_long_err_8_tokens.content) do
			expect.falsy(block.text:find("_TAIL_SENTINEL", 1, true))
		end

		local huge_stdout_short_err = present({
			status = "failed",
			content = { { type = "text", text = string.rep("S", 4000) .. "_STDOUT_TAIL" } },
			error = "fatal: out of memory",
			is_error = true,
		}, 128)
		expect.truthy(total_text_bytes(huge_stdout_short_err.content) <= 128 * 4)
		expect.eq(huge_stdout_short_err.content[#huge_stdout_short_err.content].text, "fatal: out of memory")
		expect.falsy(huge_stdout_short_err.content[2].text:find("_STDOUT_TAIL", 1, true))

		local huge_stdout_huge_err = present({
			status = "failed",
			content = { { type = "text", text = string.rep("S", 4000) } },
			error = string.rep("E", 1000) .. "_ERR_TAIL",
			is_error = true,
		}, 128)
		expect.truthy(total_text_bytes(huge_stdout_huge_err.content) <= 128 * 4)
		local last_err_block = huge_stdout_huge_err.content[#huge_stdout_huge_err.content].text
		expect.truthy(last_err_block:find("[error truncated to this call's budget]", 1, true))
		expect.falsy(last_err_block:find("_ERR_TAIL", 1, true))

		local tiny_budget = present({
			status = "failed",
			content = { { type = "text", text = string.rep("A", 200) } },
			error = string.rep("E", 200),
			is_error = true,
		}, 1)
		expect.truthy(total_text_bytes(tiny_budget.content) <= 4)
		expect.truthy(tiny_budget.content[#tiny_budget.content].text:find("E", 1, true))

		local eight_byte_budget = present({
			status = "failed",
			content = { { type = "text", text = string.rep("A", 200) } },
			error = "permission denied: " .. string.rep("X", 100),
			is_error = true,
		}, 2)
		expect.truthy(total_text_bytes(eight_byte_budget.content) <= 8)
		expect.truthy(eight_byte_budget.content[#eight_byte_budget.content].text:find("permi", 1, true))

		local utf8_budget = present({
			status = "failed",
			content = { { type = "text", text = string.rep("😀", 100) } },
			error = string.rep("é", 200),
			is_error = true,
		}, 24)
		expect.truthy(total_text_bytes(utf8_budget.content) <= 24 * 4)
		for _, block in ipairs(utf8_budget.content) do
			if type(block.text) == "string" then
				expect.truthy(utf8.len(block.text) ~= nil)
			end
		end
	end)

	it("renders summaries, spinners, compact clips, and expanded code blocks", function()
		expect.eq(
			view.summary("codemode", { input = '-- @exec:{"yield_time_ms":0}\n\n  return 42  ' }),
			"codemode(return 42)"
		)
		expect.eq(
			view.summary("codemode", { input = string.rep("x", 60) }),
			"codemode(" .. string.rep("x", 45) .. "...)"
		)
		expect.eq(view.summary("codemode_wait", { cell_id = "c-1" }), "codemode_wait(c-1)")
		expect.eq(view.summary("codemode_wait", { cell_id = "c-1", terminate = true }), "codemode_wait(c-1, terminate)")

		local spin_json = mare.json.encode(view.render("codemode", {}, nil, false))
		expect.match(spin_json, "codemode · running")

		expect.eq(view.render("codemode", {}, { is_error = true }, false), nil)

		local compact = mare.json.decode(mare.json.encode(view.render("codemode", { input = "return 1" }, {
			is_error = false,
			details = { status = "completed", content = { { type = "text", text = "hello\n" } } },
		}, false)))
		expect.eq(compact.type, "lines")
		expect.eq(compact.items[1].type, "paragraph")
		expect.eq(compact.items[1].spans[1], "codemode · completed")
		expect.eq(compact.items[2].type, "clip")
		expect.eq(compact.items[2].max, 8)
		expect.eq(compact.items[2].tail, true)
		expect.eq(compact.items[2].child.code, "hello")

		local expanded = mare.json.decode(mare.json.encode(view.render("codemode", { input = "return 1" }, {
			is_error = false,
			details = { status = "completed", content = { { type = "text", text = "hello" } } },
		}, true)))
		expect.eq(expanded.type, "lines")
		expect.eq(expanded.items[2].type, "code")
		expect.eq(expanded.items[2].lang, "lua")
		expect.eq(expanded.items[3].type, "code")
		expect.eq(expanded.items[3].code, "hello")
	end)

	it("wires plugin tools, service, context section, and /codemode commands", function()
		local provided, sections, commands, tools = {}, {}, {}, {}
		local cells_calls = {}
		local cancel_token = mare.task.token()
		local retains_state = true
		local ctx = {
			context = {
				section = function(_, s)
					sections[s.name] = s
				end,
			},
			commands = {
				register = function(_, name, def)
					commands[name] = def
				end,
			},
			tools = {
				register = function(_, name, def)
					tools[name] = def
				end,
			},
			cells = {
				list_tools = function(_, opts)
					if opts and opts.cursor == "p2" then
						return { data = { { name = "probe" } } }
					end
					return { data = { { name = "read" } }, next_cursor = "p2" }
				end,
				start = function(_, code, opts)
					cells_calls.start = { code = code, opts = opts }
					return { status = "completed", content = { { type = "text", text = "done" } }, is_error = false }
				end,
				wait = function(_, id, opts)
					cells_calls.wait = { id = id, opts = opts }
					if id == "missing-cell" then
						error("cells.unknown_cell: unknown cell: " .. tostring(id))
					elseif id == "done-cell" then
						return { status = "completed", cell_id = id, content = {}, is_error = false }
					end
					return { status = "cancelled", cell_id = id, content = {}, is_error = true }
				end,
				reset = function()
					cells_calls.reset = true
					return {}
				end,
				get = function()
					return { running = 1, stored_keys = 2, retains_state = retains_state }
				end,
				list = function()
					return { data = { { cell_id = "cell-1", status = "running" } } }
				end,
			},
			provide = function(_, name, svc)
				provided[name] = svc
			end,
		}

		plugin.apply(ctx, { timeout_ms = 60000 })
		expect.eq(provided.codemode.available(), true)
		expect.truthy(sections["codemode:guidance"])
		expect.eq(tools.codemode.summary({ input = "return 1" }), "codemode(return 1)")
		expect.eq(tools.codemode_wait.summary({ cell_id = "c1" }), "codemode_wait(c1)")
		expect.eq(type(tools.codemode.description), "function")
		expect.truthy(tools.codemode.description():find("retained capability VM", 1, true))
		retains_state = false
		expect.truthy(tools.codemode.description():find("fresh capability VM", 1, true))
		retains_state = true
		expect.truthy(tools.codemode_wait.description:find("max_output_tokens", 1, true))
		expect.truthy(
			tools.codemode_wait.parameters.properties.max_output_tokens.description:find("terminate", 1, true)
		)
		expect.truthy(
			tools.codemode_wait.parameters.properties.terminate.description:find("stops the running cell", 1, true)
		)

		local res = tools.codemode.execute({ input = "return 1" }, { cancel = cancel_token })
		expect.falsy(res.is_error)
		expect.eq(cells_calls.start.opts.timeout_ms, 60000)
		expect.eq(cells_calls.start.opts.wait_cancel(), cancel_token)
		expect.eq(#cells_calls.start.opts.capabilities, 2)

		tools.codemode_wait.execute({ cell_id = "c1", yield_time_ms = 100 }, { cancel = cancel_token })
		expect.eq(cells_calls.wait.id, "c1")
		expect.eq(cells_calls.wait.opts.cancel(), cancel_token)

		notifications = {}
		commands.codemode.run("status")
		expect.truthy(notifications[#notifications].msg:find("active cells: 1", 1, true))
		expect.truthy(notifications[#notifications].msg:find("mode: retained", 1, true))

		commands.codemode.run("stop cell-1")
		expect.eq(notifications[#notifications].msg, "Cell cell-1 terminated.")

		commands.codemode.run("stop missing-cell")
		expect.eq(notifications[#notifications].level, "warning")

		commands.codemode.run("stop done-cell")
		expect.eq(notifications[#notifications].level, "info")
		expect.truthy(notifications[#notifications].msg:find("already finished (completed)", 1, true))

		commands.codemode.run("bogus")
		expect.eq(notifications[#notifications].level, "warning")
		expect.truthy(notifications[#notifications].msg:find("Usage: /codemode", 1, true))

		commands.codemode.run("reset")
		expect.eq(cells_calls.reset, true)
		expect.eq(notifications[#notifications].level, "info")
	end)

	it("validates codemode_wait args before calling cells:wait and preserves stop_unconfirmed output", function()
		local wait_calls = 0
		local tools = {}
		local ctx = {
			context = { section = function() end },
			commands = { register = function() end },
			tools = {
				register = function(_, name, def)
					tools[name] = def
				end,
			},
			cells = {
				list_tools = function()
					return { data = {} }
				end,
				wait = function(_, id, opts)
					wait_calls = wait_calls + 1
					if id == "stuck-cell" then
						return {
							status = "running",
							stop_unconfirmed = true,
							cell_id = id,
							error = "Cell stop timed out; Lua chunk is still unwinding",
							content = { { type = "text", text = "Cell stop timed out; Lua chunk is still unwinding" } },
							is_error = true,
						}
					end
					return { status = "completed", cell_id = id, content = {}, is_error = false }
				end,
				get = function()
					return { running = 0, stored_keys = 0, retains_state = true }
				end,
			},
			provide = function() end,
		}
		plugin.apply(ctx, { timeout_ms = 60000 })

		-- Invalid arguments must fail before touching ctx.cells:wait (which cancels running cell).
		for _, bad in ipairs({
			{ cell_id = "" },
			{ cell_id = "live-1", yield_time_ms = -5 },
			{ cell_id = "live-1", yield_time_ms = 12.5 },
			{ cell_id = "live-1", max_output_tokens = -1 },
			{ cell_id = "live-1", terminate = "yes" },
		}) do
			expect.error(function()
				tools.codemode_wait.execute(bad, { cancel = mare.task.token() })
			end)
			expect.eq(wait_calls, 0)
		end

		-- stop_unconfirmed preserves error message even when max_output_tokens is 0 / tiny.
		local stuck = tools.codemode_wait.execute(
			{ cell_id = "stuck-cell", terminate = true, max_output_tokens = 1 },
			{ cancel = mare.task.token() }
		)
		expect.eq(stuck.is_error, true)
		local saw_unconfirmed = false
		for _, blk in ipairs(stuck.content) do
			if type(blk.text) == "string" and blk.text:find("stop timed out", 1, true) then
				saw_unconfirmed = true
			end
		end
		expect.truthy(saw_unconfirmed)
		expect.eq(stuck.details.stop_unconfirmed, true)

		local view = require("codemode.view")
		local utf8_summary = view.summary("codemode", { input = string.rep("中", 60) })
		expect.truthy(utf8.len(utf8_summary) ~= nil)
		expect.truthy(utf8_summary:find("...)", 1, true) ~= nil)
	end)
end)
