-- Test fixture verifying public btw service contracts and capturing request/build prompts.
return {
	name = "btw-probe",
	inject = { "btw", "conversations", "agent", "commands", "llm", "session", "bus" },
	apply = function(ctx)
		local capture = mare.env("BTW_CAPTURE")
		local function write_capture(entry)
			if not capture or capture == "" then
				return
			end
			local old = mare.fs.read(capture) or ""
			assert(mare.fs.write(capture, old .. mare.json.encode(entry) .. "\n"))
		end

		if capture and capture ~= "" then
			ctx:on("request/build", function(req, ev)
				local tool_names = {}
				for _, t in ipairs(req.tools or {}) do
					tool_names[#tool_names + 1] = t.name
				end
				write_capture({
					kind = "request_build",
					model = req.model,
					params = req.params,
					system = req.system,
					tools = tool_names,
					messages = req.messages,
				})
				return ev.next(req)
			end)
		end

		if mare.env("BTW_SWITCH_PROVIDER") == "1" then
			ctx.llm:register_provider({
				provider = "probe-side",
				is_configured = function()
					return true
				end,
				models = {
					{ model_id = "m1", context_window = 100000, max_output = 4096 },
					{ model_id = "m2", context_window = 100000, max_output = 4096 },
					{ model_id = "concurrent", context_window = 100000, max_output = 4096 },
					{ model_id = "nostream", context_window = 100000, max_output = 4096 },
				},
				stream = function(req, sink)
					local mid = type(req.model) == "table" and (req.model.model_id or "") or ""
					if mid == "concurrent" then
						local chunk = req.purpose == "side" and "side concurrent working" or "parent partial streaming"
						sink({ type = "text_delta", delta = chunk })
					end
					write_capture({
						kind = "llm_stream",
						purpose = req.purpose,
						model = type(req.model) == "table" and req.model.ref or req.model,
						params = req.params,
						messages = req.messages,
					})
					if mid == "concurrent" then
						req.cancel:wait()
						return { role = "assistant", stop_reason = "aborted", content = {} }
					end
					if mid == "nostream" then
						return {
							role = "assistant",
							stop_reason = "stop",
							content = { { type = "text", text = "final without chunks" } },
						}
					end
					local text = "reply[" .. tostring(type(req.model) == "table" and req.model.ref or req.model) .. "]"
					sink({ type = "text_delta", delta = text })
					return { role = "assistant", stop_reason = "stop", content = { { type = "text", text = text } } }
				end,
			})
		end

		ctx.commands:register("btw-probe-view", {
			description = "Test helper to open btw transcript overlay",
			run = function()
				ctx.btw:view()
			end,
		})

		ctx.commands:register("btw-probe-transcript", {
			description = "Test helper to write btw.transcript() JSON to a path",
			args = "<path>",
			run = function(args)
				local path = (args or ""):match("^%s*(.-)%s*$")
				assert(path ~= "", "path required")
				assert(mare.fs.write(path, mare.json.encode(ctx.btw:transcript() or false)))
			end,
		})

		ctx.commands:register("btw-probe-ops", {
			description = "Test helper to exercise live btw service contracts",
			run = function()
				local ok, err = pcall(function()
					local info, start_err = ctx.conversations:start()
					assert(info, tostring(start_err))
					local s1 = ctx.btw:status()
					assert(
						s1.open == true and s1.selected == true and s1.parked == false and s1.id == info.conversation_id
					)
					local act1 = ctx.agent:activity()
					assert(
						act1.extra
							and act1.extra.btw
							and act1.extra.btw.open == true
							and act1.extra.btw.selected == true
					)
					assert(ctx.btw:view() == true, "view while open must return true")

					ctx.btw:toggle()
					local s2 = ctx.btw:status()
					assert(s2.open == true and s2.selected == false and s2.parked == true, "toggle must park side")
					local act2 = ctx.agent:activity()
					assert(act2.extra and act2.extra.btw and act2.extra.btw.parked == true)

					assert(ctx.btw:close() == true, "close must close side")
					local s3 = ctx.btw:status()
					assert(s3.open == false and ctx.btw:transcript().open == false)
					local act3 = ctx.agent:activity()
					assert(act3.extra == nil or act3.extra.btw == nil, "closed btw must clear activity")
				end)
				local ops_report = mare.env("BTW_OPS_REPORT")
				if ops_report and ops_report ~= "" then
					assert(
						mare.fs.write(
							ops_report,
							mare.json.encode({ ok = ok, detail = ok and "passed" or tostring(err) })
						)
					)
				end
				assert(ok, err)
			end,
		})

		ctx.commands:register("btw-probe-model", {
			description = "Test helper to switch current model",
			args = "<provider/model>",
			run = function(args)
				local target = (args or ""):match("^%s*(.-)%s*$")
				assert(target ~= "", "model required")
				assert(ctx.llm:set_model(target), "failed to set model: " .. target)
			end,
		})

		ctx.commands:register("btw-probe-abort-turn", {
			description = "Test helper to abort a specific turn by turn_id",
			args = "<turn_id>",
			run = function(args)
				local turn_id = (args or ""):match("^%s*(.-)%s*$")
				assert(turn_id ~= "", "turn_id required")
				local ok, err = ctx.agent:cancel({ turn_id = turn_id })
				assert(ok, tostring(err))
			end,
		})

		local secret_lease
		ctx:effect(function()
			return function()
				if secret_lease then
					pcall(secret_lease.close, secret_lease)
					secret_lease = nil
				end
			end
		end)

		ctx:on("app/ready", function()
			local secret = mare.env("BTW_SECRET")
			if secret and secret ~= "" and mare.projection and type(mare.projection.register) == "function" then
				secret_lease = mare.projection.register(secret)
			end

			local report = mare.env("BTW_PROBE_REPORT")
			if not report or report == "" then
				return
			end
			local ok, err = pcall(function()
				local s0 = ctx.btw:status()
				assert(s0.open == false and s0.parked == false and s0.turn_count == 0, "unexpected initial status")
				assert(ctx.btw:transcript().open == false, "initial transcript must be closed")
				local act0 = ctx.agent:activity()
				assert(act0.extra == nil or act0.extra.btw == nil, "closed btw must not publish activity")
				assert(ctx.btw:view() == false, "view while closed must return false")
				local early = ctx.btw:ask("before main")
				assert(
					early
						and type(early.error) == "string"
						and (early.error:find("/side", 1, true) ~= nil or early.error:find("history", 1, true) ~= nil),
					"early ask should fail cleanly: " .. tostring(early and early.error)
				)
			end)
			assert(mare.fs.write(report, mare.json.encode({ ok = ok, detail = ok and "passed" or tostring(err) })))
			assert(ok, err)
		end)
	end,
}
