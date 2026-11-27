return {
	name = "hooks-events-probe",
	inject = { "agent", "session" },
	apply = function(ctx)
		ctx:on("app/ready", function()
			local spec = { level = "workspace-write", network = true }
			if mare.os == "windows" then
				spec.accept_partial = { "fs_protect" }
			end
			ctx.session:set_sandbox_mode(spec)
		end, { prepend = true })
		ctx:on("request/build", function(request, ev)
			assert(mare.fs.write(mare.env("HOOK_REQUESTS"), mare.json.encode_strict({
				messages = request.messages,
				history = ctx.agent:messages(),
				system = request.system,
			}) .. "\n", { append = true }))
			assert(mare.fs.write(mare.env("HOOK_SESSION"), mare.json.encode_strict(ctx.session:info())))
			return ev.next(request)
		end)
	end,
}
