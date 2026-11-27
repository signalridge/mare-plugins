return {
	name = "plan-mode-probe",
	inject = { "plan_mode", "commands", "context", "session", "tools" },
	apply = function(ctx)
		local capture = mare.env("PLAN_CAPTURE")
		local function contracts()
			local ok, err = pcall(function()
				assert(ctx.tools:get("exit_plan_mode"), "exit_plan_mode must be registered")
				local events = 0
				ctx:on("plan-mode/changed", function(ev)
					assert(type(ev.active) == "boolean")
					if ev.reason == "committed" then
						events = events + 1
					end
				end)
				ctx.commands:run("/plan on")
				assert(ctx.plan_mode:active())
				assert(ctx.context:system_prompt():find("Plan mode (soft guidance) is active", 1, true))
				ctx.commands:run("/plan on")
				assert(ctx.plan_mode:active(), "on must be idempotent")
				assert(events == 1, "idempotent on must not emit extra event")
				ctx.commands:run("/plan off")
				assert(not ctx.plan_mode:active())
				assert(not ctx.context:system_prompt():find("Plan mode (soft guidance) is active", 1, true))
				assert(events == 2)
			end)
			assert(
				mare.fs.write(
					assert(mare.env("PLAN_REPORT")),
					mare.json.encode({ ok = ok, detail = ok and "passed" or tostring(err) })
				)
			)
			assert(ok, err)
		end
		ctx:on("app/ready", function()
			if mare.env("PLAN_CONTRACTS") == "1" then
				contracts()
			end
			local action = mare.env("PLAN_ACTION")
			if action and action ~= "" then
				ctx.commands:run("/plan " .. action)
			end
		end)
		if mare.env("PLAN_FREEZE_RACE") == "1" then
			local started, switched = false, false
			ctx:on("turn/started", function()
				if not started then
					started = true
					ctx.commands:run("/plan on")
				end
			end)
			-- core: waterfall("context/transform", { messages = history, model = model }) (agent/loop_request.lua:86)
			ctx:on("context/transform", function(data, ev)
				local history, model = data and data.messages, data and data.model
				if not switched then
					switched = true
					ctx.commands:run("/plan off")
					mare.task.sleep(2)
				end
				local out = ev.next()
				-- recorded once the rest of the chain has returned: the e2e checks the chain went on
				local chain = mare.env("PLAN_TRANSFORM_CHAIN")
				if chain then
					local old = mare.fs.read(chain) or ""
					assert(mare.fs.write(chain, old .. mare.json.encode({
						history = type(history) == "table",
						model = type(model) == "table",
						returned = type(out) == "table",
					}) .. "\n"))
				end
				return out
			end)
		end
		ctx:on("request/build", function(req, ev)
			if mare.env("PLAN_BUSY_ATTEMPT") == "off" then
				ctx.commands:run("/plan off")
				assert(
					ctx.plan_mode:active() and ctx.plan_mode:state().pending == false,
					"busy command must queue the selection"
				)
			end
			local old = mare.fs.read(capture) or ""
			assert(mare.fs.write(capture, old .. mare.json.encode({
				system = req.system,
				active = ctx.plan_mode:active(),
				pending = ctx.plan_mode:state().pending,
				tools = req.tools,
				messages = req.messages,
			}) .. "\n"))
			return ev.next(req)
		end)
	end,
}
