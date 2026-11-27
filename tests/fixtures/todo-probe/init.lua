return {
	name = "todo-probe",
	inject = { "tools", "context", "session", "agent", "policy" },
	apply = function(ctx)
		local capture = mare.env("TODO_CAPTURE")
		if mare.env("TODO_CANCEL_APPROVAL") then
			ctx.policy:voter("tool/before", function(call)
				if call.name == "todo_write" then
					return { decision = "ask", reason = "Cancel this checklist update before saving" }
				end
			end)
		end

		ctx:on("request/build", function(req, ev)
			local old = mare.fs.read(capture) or ""
			assert(
				mare.fs.write(
					capture,
					old .. mare.json.encode({ system = req.system, tools = req.tools, messages = req.messages }) .. "\n"
				)
			)
			return ev.next(req)
		end)
		ctx:on("app/ready", function()
			if mare.env("TODO_LEGACY_SEED") then
				ctx.agent:append({
					role = "assistant",
					content = {
						{
							type = "tool_call",
							id = "legacy-todo",
							name = "todo_write",
							arguments = { todos = mare.json.array({ { content = "legacy task", status = "pending" } }) },
						},
					},
				})
				ctx.agent:append({
					role = "tool_result",
					tool_call_id = "legacy-todo",
					tool_name = "todo_write",
					content = { { type = "text", text = "legacy result without details" } },
				})
			end

			local report = mare.env("TODO_PROBE_REPORT")
			if not report then
				return
			end
			local ok, err = pcall(function()
				local tool = assert(ctx.tools:get("todo_write"), "todo_write not installed")
				local function put(items)
					return tool.execute({ todos = mare.json.array(items) })
				end
				local result = put({ { content = "  probe {{literal}}  ", status = "in_progress" } })
				assert(not result.is_error and result.details.todos[1].content == "probe {{literal}}")
				assert(mare.json.decode(result.content).counts.in_progress == 1)
				assert(ctx.context:system_prompt():find("probe {{literal}}", 1, true))
				for _, items in ipairs({
					{ { content = " ", status = "pending" } },
					{ { content = "x", status = "in_progress" }, { content = "y", status = "in_progress" } },
				}) do
					assert(not pcall(put, items), "invalid list was accepted")
				end
				ctx:emit("turn/started", { trigger = "continue" })
				assert(ctx.context:system_prompt():find("probe {{literal}}", 1, true))
				ctx:emit("turn/started", { trigger = "notification" })
				assert(ctx.context:system_prompt():find("probe {{literal}}", 1, true))
				ctx:emit("step/started", { turn = 2 })
				assert(ctx.context:system_prompt():find("probe {{literal}}", 1, true))
				ctx:emit("turn/started", { trigger = "prompt", text = "new work" })
				assert(not ctx.context:system_prompt():find("probe {{literal}}", 1, true))
				assert(not put({}).is_error)
			end)
			assert(mare.fs.write(report, mare.json.encode({ ok = ok, detail = ok and "passed" or tostring(err) })))
			assert(ok, err)
		end)
	end,
}
