return {
	name = "time-context-probe",
	inject = { "llm", "context", "agent", "session", "tools", "commands", "policy" },
	apply = function(ctx)
		-- Deterministic integration sampling still executes the public native formatter.
		-- No private clock or host fields: only the documented sample instant override.
		local encoded = mare.env("TIME_SAMPLE_SERIES")
		if encoded then
			local samples = mare.json.decode(encoded)
			local original, index = mare.time.query, 0
			local replacement
			replacement = function(request)
				if request.action == "sample" and request.instant_ms == nil then
					index = index + 1
					request = table.copy(request)
					request.instant_ms = samples[math.min(index, #samples)]
				end
				return original(request)
			end
			mare.time.query = replacement
			ctx:effect(function()
				return function()
					if mare.time.query == replacement then
						mare.time.query = original
					end
				end
			end)
		end
		local admission = mare.env("TIME_ADMISSION")
		if admission == "deny" or admission == "cancel" then
			ctx.policy:voter("agent/step-ready", function(step)
				if admission == "deny" then
					return { decision = "deny", reason = "TIME_POLICY_REFUSAL" }
				end
				step.cancel:cancel()
				return { decision = "allow" }
			end)
		elseif admission == "write-fail" then
			-- A public store adapter injects a failure at the shared step batch boundary.
			-- Delegation is restricted to the documented StoreFile API, with no private fields.
			local original, failed = mare.store.open, false
			local replacement
			replacement = function(path, opts)
				local file = original(path, opts)
				local wrapper = {}
				for _, method in ipairs({
					"append",
					"append_batch",
					"activate",
					"flush",
					"close",
					"path",
					"matches_path",
					"checkpoint",
					"stats",
				}) do
					wrapper[method] = function(_, ...)
						if method == "append_batch" and not failed then
							local entries = ...
							for _, entry in ipairs(entries) do
								if entry.type == "custom" and entry.kind == "agent/step-state" then
									failed = true
									error("TIME_STEP_BATCH_WRITE_FAILURE")
								end
							end
						end
						return file[method](file, ...)
					end
				end
				return wrapper
			end
			mare.store.open = replacement
			ctx:effect(function()
				return function()
					if mare.store.open == replacement then
						mare.store.open = original
					end
				end
			end)
			ctx.agent:step_participant("time-probe-joint", function(previous)
				return { value = (previous and previous.value or 0) + 1 }
			end)
		end
		ctx.commands:register("time-facts", {
			description = "Forward reported facts through a command",
			run = function(args, input)
				local payload = (input and input.content) or args
				return ctx.agent:prompt(payload, {
					delivery = input and input.delivery or nil,
					source = "peer",
					input_context = input and input.input_context or nil,
				})
			end,
		})
		ctx.commands:register("time-local-only", {
			local_only = true,
			run = function()
				error("local grant escaped")
			end,
		})
		ctx.tools:register("time_replay_grant_probe", {
			description = "Verify replay never carries input authorization",
			side_effect = "read",
			idempotent = true,
			parameters = { type = "object", properties = {}, additionalProperties = false },
			execute = function()
				local ok, err = pcall(ctx.commands.run, ctx.commands, "/time-local-only")
				assert(
					not ok and type(err) == "table" and err.code == "commands.local_only",
					tostring(err and err.code or err)
				)
				for _, message in ipairs(ctx.agent:messages()) do
					if message.context_disclosure then
						assert(message.notification == true, "context disclosure must stay a notification")
						if mare.input and mare.input.replay then
							assert(not pcall(mare.input.replay, message))
						end
					end
				end
				return { content = "REPLAY_GRANT_NOT_INHERITED" }
			end,
		})
		ctx.tools:register("time_probe", {
			description = "Read the committed host time fact",
			side_effect = "read",
			idempotent = true,
			parameters = { type = "object", properties = {}, additionalProperties = false },
			execute = function()
				local state = ctx.agent:step_state("time-context")
				assert(state and state.host.local_date)
				return { content = { { type = "text", text = "time fact observed: " .. state.host.local_date } } }
			end,
		})
		local faux = assert(ctx.llm:provider("faux"))
		local path = assert(mare.env("TIME_CAPTURE"))
		ctx.llm:register_provider({
			provider = "time-faux",
			default_model = "echo",
			models = {
				{ model_id = "echo", context_window = 100000, max_output = 4096, images = true },
				{ model_id = "echo2", context_window = 100000, max_output = 4096, images = true },
			},
			is_configured = function()
				return true
			end,
			stream = function(req, sink)
				local snapshot = {
					system = req.system,
					messages = req.messages,
					model = req.model.ref,
					cached_system = ctx.context:system_prompt(req.model),
					history = ctx.agent:messages(),
				}
				assert(mare.fs.write(path, (mare.fs.read(path) or "") .. mare.json.encode(snapshot) .. "\n"))
				return faux.stream(req, sink)
			end,
		})
		ctx:on("app/shutdown", function()
			assert(mare.fs.write(assert(mare.env("TIME_SESSION")), mare.json.encode(ctx.session:entries())))
		end)
	end,
}
