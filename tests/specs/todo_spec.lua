local support = assert(load(mare.fs.read("tests/specs/support.lua"), "@tests/specs/support.lua"))()

local describe = mare.test.describe
local it = mare.test.it
local before_each = mare.test.before_each
local after_each = mare.test.after_each
local expect = mare.test.expect

local plugin = support.load_plugin("todo", { "todo.model", "todo.view" })
local model = require("todo.model")
local view = require("todo.view")

describe("todo", function()
	local events, tool, section, widget, cmd
	local info, records, writes, invalidations
	local fail, switch_during_write
	local activity_provider, provided
	local last_select, last_notice
	local orig_select, orig_notify, orig_mode
	local ctx

	local function put(content)
		return tool.execute({ todos = mare.json.array({ { content = content, status = "pending" } }) })
	end

	before_each(function()
		events, tool, section, widget, cmd = {}, nil, nil, nil, nil
		info = { session_epoch = "one", readonly = false }
		records, writes, invalidations = {}, 0, 0
		fail, switch_during_write = false, false
		activity_provider, provided = nil, nil
		last_select, last_notice = nil, nil

		orig_select = mare.ui.select
		orig_notify = mare.ui.notify
		orig_mode = mare.mode
		mare.ui.select = function(opts)
			last_select = opts
		end
		mare.ui.notify = function(msg, level)
			last_notice = { msg = msg, level = level }
		end

		ctx = {
			agent = {
				register_activity = function(_, name, callback)
					expect.eq(name, "todo")
					activity_provider = callback
				end,
			},
			tools = {
				register = function(_, _, def)
					tool = def
				end,
			},
			context = {
				invalidate = function()
					invalidations = invalidations + 1
				end,
				section = function(_, def)
					section = def
				end,
			},
			ui = {
				invalidate = function() end,
				widget = function(_, _, def)
					widget = def
				end,
			},
			commands = {
				register = function(_, _, def)
					cmd = def
				end,
			},
			session = {
				info = function()
					return { session_epoch = info.session_epoch, readonly = info.readonly }
				end,
				list_records = function()
					return { data = records }
				end,
				add_record = function(_, _, data)
					writes = writes + 1
					if fail then
						error("disk failure", 0)
					end
					if switch_during_write then
						info.session_epoch = "other"
					end
					records[#records + 1] = data
					return { durable = true }
				end,
			},
			provide = function(_, name, service)
				expect.eq(name, "todo")
				provided = service
			end,
			on = function(_, name, fn)
				events[name] = fn
			end,
		}
		plugin.apply(ctx, { allow_parallel_in_progress = false })
	end)

	after_each(function()
		mare.ui.select = orig_select
		mare.ui.notify = orig_notify
		mare.mode = orig_mode
	end)

	it("handles persistence failure, readonly, clear retry, session switch, and cancellation", function()
		expect.eq(provided.snapshot().todos, mare.json.null)
		expect.eq(activity_provider(), mare.json.null)

		expect.falsy(put("kept").is_error)
		local before = invalidations
		fail = true
		local fail_res = put("lost")
		expect.truthy(fail_res.is_error)
		expect.eq(fail_res.error_code, "persist_failed")
		expect.eq(invalidations, before)
		expect.match(section.text(), "kept")

		info.readonly = true
		local prior_writes = writes
		local ro_res = put("readonly")
		expect.truthy(ro_res.is_error)
		expect.eq(ro_res.error_code, "readonly_session")
		expect.eq(writes, prior_writes)
		expect.match(section.text(), "kept")

		-- Read-only sessions allow prompts without bricking request/ready.
		events["turn/started"]({ text = "new work" })
		expect.eq(events["request/ready"](), nil)
		expect.eq(writes, prior_writes)
		expect.eq(provided.snapshot().todos, mare.json.null)

		info.readonly = false
		fail = false
		expect.falsy(put("kept").is_error)
		fail = true
		events["turn/started"]({ text = "new work" })
		expect.eq(events["request/ready"]().decision, "deny")
		expect.match(section.text(), "kept")

		fail = false
		expect.eq(events["request/ready"](), nil)
		expect.falsy(section.text():find("kept", 1, true))
		expect.truthy(invalidations > before)
		expect.eq(provided.snapshot().todos, mare.json.null)
		expect.falsy(put("restored").is_error)

		records = { { version = 1, todos = mare.json.array({ { content = "other session", status = "completed" } }) } }
		info.session_epoch = "two"
		events["session/changed"]()
		expect.match(section.text(), "other session")
		expect.falsy(section.text():find("restored", 1, true))
		expect.eq(#widget.render(5, 0), 0)
		expect.truthy(#widget.render(5, 1) <= 1)

		local cancel_writes = writes
		local tok = mare.task.token()
		tok:cancel()
		local cancelled = tool.execute(
			{ todos = mare.json.array({ { content = "cancelled", status = "completed" } }) },
			{ cancel = tok }
		)
		expect.truthy(cancelled.is_error)
		expect.truthy(cancelled.cancelled)
		expect.eq(cancelled.error_code, "cancelled")
		expect.eq(writes, cancel_writes)
		expect.falsy(section.text():find("cancelled", 1, true))
	end)

	it("validates canonical items and computes diffs", function()
		expect.error(function()
			model.canonical(mare.json.array({ { content = "\u{00a0}\u{3000}", status = "pending" } }), false)
		end, "todos%[0%]%.content must be a non%-empty string")

		expect.error(function()
			model.canonical(
				mare.json.array({ { content = "x", status = "pending" }, { content = " x ", status = "completed" } }),
				false
			)
		end, 'todos%[1%]%.content duplicates "x"')

		expect.error(function()
			model.canonical(mare.json.array({ { content = "x", status = "pending", extra = 1 } }), false)
		end, "todos%[0%] unknown field: extra")

		expect.error(function()
			model.canonical(mare.json.array({ { content = "x", status = "bad" } }), false)
		end, "todos%[0%]%.status must be pending, in_progress, or completed")

		expect.error(function()
			model.canonical(
				mare.json.array({ { content = "a", status = "in_progress" }, { content = "b", status = "in_progress" } }),
				false
			)
		end, "at most one task may be in_progress %(got 2%)")

		local trimmed =
			model.canonical(mare.json.array({ { content = "\u{feff}Unicode\u{202f}", status = "pending" } }), false)
		expect.eq(trimmed[1].content, "Unicode")

		local diff = model.diff(
			mare.json.array({
				{ content = "one", status = "pending" },
				{ content = "two", status = "pending" },
				{ content = "removed", status = "completed" },
			}),
			mare.json.array({
				{ content = "two", status = "completed" },
				{ content = "added", status = "pending" },
				{ content = "one", status = "pending" },
			})
		)
		expect.eq(diff.counts.added, 1)
		expect.eq(diff.counts.removed, 1)
		expect.eq(diff.counts.updated, 2)
		expect.eq(diff.items[1].previous_status, "pending")
		expect.truthy(diff.items[1].moved)

		local inserted = model.diff(
			mare.json.array({ { content = "one", status = "pending" } }),
			mare.json.array({
				{ content = "added", status = "pending" },
				{ content = "one", status = "pending" },
			})
		)
		expect.eq(inserted.counts.unchanged, 1)
		expect.eq(inserted.counts.updated, 0)
	end)

	it("rejects stale sessions, invalid config, and child mode", function()
		switch_during_write = true
		local stale_res = put("stale")
		expect.truthy(stale_res.is_error)
		expect.eq(stale_res.error_code, "stale_session")
		expect.falsy(section.text():find("stale", 1, true))
		switch_during_write = false

		expect.eq(plugin.config_schema.allow_parallel_in_progress.type, "boolean")
		expect.eq(plugin.config_schema.allow_parallel_in_progress.default, false)
		expect.truthy(tool.parameters.properties.todos.description)
		expect.truthy(tool.parameters.properties.todos.items.properties.content.description)
		expect.truthy(tool.parameters.properties.todos.items.properties.status.description)
		expect.error(function()
			tool.execute({ todos = mare.json.array({ { content = "x", status = "pending" } }), explanation = 123 })
		end)

		records = {}
		events["session/changed"]()
		local child_writes = writes
		mare.mode = "child"
		local child_res = put("child-item")
		expect.truthy(child_res.is_error)
		expect.eq(child_res.error_code, "tool_context_unavailable")
		expect.match(child_res.content, "child session storage is unavailable")
		expect.eq(writes, child_writes)
		expect.eq(provided.snapshot().todos, mare.json.null)
		expect.falsy(section.text():find("child-item", 1, true))
	end)

	it("renders view cards, bounded widget overflow, and /todos modal states", function()
		expect.match(mare.json.encode(view.render({}, nil, false)), "Updating todo list…")
		local cancelled_card = mare.json.encode(view.render({}, { cancelled = true, content = "aborted" }, false))
		expect.match(cancelled_card, "Todo update cancelled: ")
		expect.match(cancelled_card, "aborted")

		local error_card = mare.json.encode(
			view.render({}, { is_error = true, content = { { type = "text", text = "boom" } } }, false)
		)
		expect.match(error_card, "Todo update failed: ")
		expect.match(error_card, "boom")

		local legacy_ok = mare.json.encode(
			view.render(
				{ todos = mare.json.array({ { content = "a", status = "pending" } }) },
				{ content = "raw" },
				true
			)
		)
		expect.match(legacy_ok, "Baseline unavailable")
		expect.match(legacy_ok, "raw")

		local legacy_bad = mare.json.encode(view.render({}, { content = "raw" }, true))
		expect.match(legacy_bad, "baseline unavailable")

		local empty_expanded = mare.json.encode(view.render({}, {
			details = {
				todos = mare.json.array({}),
				diff = {
					baseline = "previous",
					counts = { added = 0, updated = 0, removed = 1, unchanged = 0 },
					items = { { content = "gone", status = "completed", kind = "removed" } },
				},
			},
		}, true))
		expect.match(empty_expanded, "No todos")
		expect.match(empty_expanded, "removed · %[x%] gone")

		local three = {
			{ content = "one", status = "in_progress" },
			{ content = "two", status = "pending" },
			{ content = "three", status = "completed" },
		}
		local overflow = view.widget({ todos = three, collapsed = false }, 40, 3)
		local overflow_json = mare.json.encode(overflow)
		expect.match(overflow_json, "2 more · /todos")
		local exact = view.widget({ todos = three, collapsed = false }, 40, 4)
		expect.falsy(mare.json.encode(exact):find("more · /todos", 1, true))

		local narrow_parallel = view.widget({
			todos = {
				{ content = "very long first concurrent task name", status = "in_progress" },
				{ content = "second concurrent task", status = "in_progress" },
			},
			collapsed = true,
		}, 42, 1)
		local narrow_json = mare.json.encode(narrow_parallel)
		expect.match(narrow_json, "%+1")

		view.show({ todos = nil })
		expect.eq(last_select.body, "No checklist has been written for this work")
		view.show({ todos = {} })
		expect.eq(last_select.body, "No todos (explicitly cleared)")
		view.show({ todos = three })
		expect.eq(last_select.body, nil)
		expect.eq(#last_select.items, 3)

		expect.falsy(put("cmd item").is_error)
		expect.eq(#widget.render(40, 5).items, 1)
		cmd.run("expand")
		local expanded = widget.render(40, 5)
		expect.eq(#expanded.items, 2)
		expect.match(mare.json.encode(expanded), "cmd item")
		cmd.run("toggle")
		expect.eq(#widget.render(40, 5).items, 1)
		cmd.run("collapse")
		expect.eq(#widget.render(40, 5).items, 1)
		last_notice = nil
		cmd.run("bogus")
		expect.truthy(last_notice)
		expect.eq(last_notice.level, "warning")
		expect.match(last_notice.msg, "Usage: /todos")
	end)

	it("isolates corrupted restore() records and clears stale checklists on session/changed", function()
		expect.falsy(put("session-a-task").is_error)
		expect.match(section.text(), "session%-a%-task")

		local logs = {}
		local orig_log = mare.log
		mare.log = function(level, msg)
			logs[#logs + 1] = { level = level, msg = msg }
		end
		records = { { version = 99, todos = mare.json.array({}) } }
		info.session_epoch = "corrupted-gen"
		events["session/changed"]()
		mare.log = orig_log

		expect.eq(provided.snapshot().todos, mare.json.null)
		expect.falsy(section.text():find("session-a-task", 1, true))
		expect.truthy(#logs >= 1)
	end)
end)
