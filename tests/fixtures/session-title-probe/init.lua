return {
	name = "session-title-probe",
	contracts = {
		["title-test"] = {
			owner = "session-title-probe",
			doc = "Session title probe test events.",
			events = {
				["child-ready"] = {
					doc = "Emitted by child session-title probe on turn start.",
					mode = "emit",
					expose = "lua",
					data = { type = "object", additionalProperties = true },
				},
			},
		},
	},
	inject = { "session", "llm", "session_title", "commands", "agent", "task", "bus" },
	apply = function(ctx)
		-- Check the same session:get/update contract that session-title relies on.
		local callable = require("mare_lib").callable
		local caps_path = mare.env("TITLE_CAPS")
		if caps_path and caps_path ~= "" then
			assert(mare.fs.write(
				caps_path,
				mare.json.encode({
					has_title_api = callable(ctx.session.get) and callable(ctx.session.update),
				})
			))
		end
		ctx:on("turn/started", function()
			if mare.mode == "child" then
				ctx.bus:emit("title-test/child-ready", { has_title = callable(ctx.session_title.get) })
			end
		end)
		local mode = mare.env("TITLE_CUSTOM")
		if mode and mode ~= "none" then
			local remove = ctx.session_title:register({
				id = "test",
				automatic = "all-prompts",
				generate = function(request)
					assert(ctx.session:add_record("title-test/provider-start", { mode = mode }))
					if mode == "sources" then
						assert(ctx.session:add_record("title-test/inputs", { messages = request.messages }))
						return { title = "Sources title" }
					end
					if mode == "error" then
						error("intentional title provider failure")
					end
					if mode == "controls" then
						return { title = "\27]2;evil\7 中文\226\128\174name\n" .. string.rep("标题", 100) }
					end
					if mode == "dispose" then
						request.cancel:wait()
						mare.task.sleep(100)
					else
						mare.task.sleep(300)
					end
					return { title = "Late provider result" }
				end,
			})
			ctx.commands:register("title-provider-remove", {
				run = function()
					remove()
				end,
			})
		end

		ctx.commands:register("title-test-queue", {
			run = function()
				local idle = not ctx.agent:get().busy
				for _, source in ipairs({ "peer", "user" }) do
					ctx.agent:prompt(source .. " queued text", {
						source = source,
						queue_only = idle,
						content = mare.json.array({
							{ type = "text", text = source .. " queued text" },
							{ type = "file", path = "attachment.txt", text = "FILE BODY MUST NOT TITLE" },
							{ type = "image", data = "AA==", mime = "image/png" },
						}),
					})
				end
				ctx.agent:notify("NOTIFICATION MUST NOT TITLE", { wake = false })
			end,
		})
		ctx.commands:register("title-test-info", {
			run = function()
				assert(
					mare.fs.write(
						mare.env("TITLE_INFO"),
						mare.json.encode({ info = ctx.session:info(), queue = ctx.agent:list_queue() })
					)
				)
			end,
		})
		ctx.commands:register("title-test-child", {
			run = function()
				local child =
					mare.subagent.start({ prompt = "child must not generate title", tools = mare.json.array() })
				local events = {}
				local done_tx, done_rx = mare.task.channel()
				local collector = ctx:spawn(function()
					while true do
						local event = child:next_event()
						if not event then
							done_tx:send(true)
							break
						end
						events[#events + 1] = {
							name = event.name,
							purpose = event.payload and event.payload.purpose,
							has_title = event.payload and event.payload.has_title,
						}
					end
				end)
				local result = child:wait()
				done_rx:recv()
				collector:abort()
				assert(not result.error, result.error)
				assert(ctx.session:add_record("title-test/child", { events = events, text = result.text }))
			end,
		})
		ctx:on("llm/usage", function(req)
			if req.purpose == "title" then
				local path = mare.env("TITLE_CAPTURE")
				assert(
					mare.fs.write(
						path,
						(mare.fs.read(path) or "") .. mare.json.encode({ purpose = req.purpose }) .. "\n"
					)
				)
			end
			return req
		end)
		ctx:on("session-title/changed", function(ev)
			local path = mare.env("TITLE_RESULT")
			if path and path ~= "" then
				assert(mare.fs.write(path, mare.json.encode(ev.state)))
			end
		end)
		ctx:on("app/shutdown", function()
			local path = mare.env("TITLE_RESULT")
			if path and path ~= "" then
				assert(mare.fs.write(path, mare.json.encode(ctx.session_title:get())))
			end
		end)
	end,
}
