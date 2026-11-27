return {
	name = "presets-probe",
	inject = { "agent", "commands", "context", "llm", "session", "tools" },
	apply = function(ctx)
		-- PRESETS_CAPS=<file>: record whether core has the three context APIs the presets plugin
		-- needs: preview, a per-section disposer from section(), and suppress_runtime.
		local caps_file = mare.env("PRESETS_CAPS")
		if caps_file and caps_file ~= "" then
			local has_lib, lib = pcall(require, "mare_lib")
			local function callable(v)
				return type(v) == "function" or (has_lib and lib.callable and lib.callable(v)) or false
			end
			local disposer = ctx.context:section({ name = "presets-probe:caps", text = "" })
			local has_disposer = callable(disposer)
			if has_disposer then
				disposer()
			end
			assert(mare.fs.write(
				caps_file,
				mare.json.encode({
					preview = callable(ctx.context.preview),
					section_disposer = has_disposer,
					suppress_runtime = callable(ctx.context.suppress_runtime),
				})
			))
		end
		if mare.env("PRESETS_BAD_CONSTRAINT") == "yes" then
			ctx.llm:constrain_tools(function()
				error("fixture tool constraint failed")
			end)
		end
		local faux = assert(ctx.llm:provider("faux"))
		ctx.llm:register_provider({
			provider = "presets-faux",
			default_model = "echo",
			models = {
				{ model_id = "echo", context_window = 100000, max_output = 4096 },
				{ model_id = "fallback", context_window = 100000, max_output = 4096 },
				{
					model_id = "selected",
					context_window = 100000,
					max_output = 4096,
					reasoning = true,
					efforts = { "low", "medium", "high" },
				},
			},
			is_configured = function()
				return true
			end,
			stream = function(req, sink)
				local names = {}
				for _, tool in ipairs(req.tools or {}) do
					names[#names + 1] = tool.name
				end
				local snapshot = {
					system = req.system,
					model = req.model.ref,
					tools = names,
					tool_count = #names,
					messages = req.messages,
					history = ctx.agent:messages(),
					effort = ctx.llm:effort(),
					current_model = ctx.llm:current().ref,
				}
				local path = assert(mare.env("PRESETS_CAPTURE"))
				assert(mare.fs.write(path, (mare.fs.read(path) or "") .. mare.json.encode(snapshot) .. "\n"))
				return faux.stream(req, sink)
			end,
		})
		ctx:on("app/ready", function()
			if mare.env("PRESETS_COMPLETE") == "yes" then
				ctx.context:section({ name = "probe:complete", complete = true, text = "Complete replacement" })
			end
			local action = mare.env("PRESETS_ACTION")
			if action then
				ctx.commands:run("/preset " .. action)
			end
			if mare.env("PRESETS_CLEAR") == "yes" then
				ctx.commands:run("/preset clear")
			end
		end)
		ctx:on("request/build", function(req, ev)
			if mare.env("PRESETS_READD") == "yes" then
				for _, tool in ipairs(ctx.tools:definitions(req.model)) do
					if tool.name == "write" then
						req.tools[#req.tools + 1] = tool
					end
				end
			end
			if mare.env("PRESETS_BUSY") == "yes" then
				local ok, err = pcall(ctx.commands.run, ctx.commands, "/preset clear")
				assert(
					not ok and type(err) == "table" and err.code == "commands.command_unavailable",
					tostring(err and err.code or err)
				)
			end
			return ev.next(req)
		end)
		ctx:on("app/shutdown", function()
			assert(mare.fs.write(assert(mare.env("PRESETS_ENTRIES")), mare.json.encode(ctx.session:entries())))
		end)
	end,
}
