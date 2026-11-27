return {
	name = "spill-probe",
	inject = { "tools", "llm", "agent", "session" },
	apply = function(ctx)
		local full = string.rep("αβ recovery line\n", 7000)
		ctx.tools:register("spill_fixture", {
			description = "Generate a large text result for offline tests.",
			parameters = {
				type = "object",
				properties = { replay = { type = "string" } },
				additionalProperties = false,
			},
			side_effect = "read",
			idempotent = true,
			execute = function(args)
				return { content = args.replay or full, details = { marker = "preserved" } }
			end,
		})
		local faux = assert(ctx.llm:provider("faux"))
		ctx.llm:register_provider({
			provider = "spill-faux",
			default_model = "small",
			is_configured = function()
				return true
			end,
			models = {
				{
					model_id = "small",
					context_window = 100000,
					max_output = 4096,
					truncation = { mode = "bytes", limit = 4096 },
				},
			},
			stream = function(req, sink)
				assert(mare.fs.write(assert(mare.env("SPILL_CAPTURE")), mare.json.encode(req.messages)))
				return faux.stream(req, sink)
			end,
		})
		ctx:on("app/ready", function()
			-- Direct public storage exercises bounded cursor reads and denied paths separately.
			local sid = ctx.session:info().session_id
			local saved = mare.spill.save(sid, full)
			local a = mare.spill.read(saved.spill_id, { session_id = sid, offset = 2, limit = 1 })
			assert(a.content == "αβ recovery line\n" and a.more)
			mare.spill.delete(saved.spill_id, { session_id = sid })
			assert(not pcall(mare.spill.read, saved.spill_id, { session_id = sid }))
			assert(not pcall(mare.spill.read, mare.cwd .. "/outside", { session_id = sid }))
			assert(not pcall(mare.text.retain, full, { max_bytes = 2, suffix = "too long" }))
			if mare.env("SPILL_DENY") == "1" then
				mare.proc.sandbox.set_current({
					level = "read-only",
					network = true,
					deny_read = { mare.paths.state .. "/spill-results" },
					accept_partial = { "fs_deny_read" },
				})
			end
		end)
	end,
}
