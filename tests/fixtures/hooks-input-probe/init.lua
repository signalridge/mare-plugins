return {
	name = "hooks-input-probe",
	inject = { "agent", "session", "tools", "policy", "commands" },
	apply = function(ctx)
		ctx:on("app/ready", function()
			local spec = { level = "workspace-write", network = true }
			if mare.os == "windows" then
				spec.accept_partial = { "fs_protect" }
			end
			ctx.session:set_sandbox_mode(spec)
		end, { prepend = true })
		-- each prepend goes first: the mutator is registered before the meta capture so the capture still runs first
		ctx.policy:voter("agent/input-ready", function(event)
			if mare.env("HOOK_INPUT_MODE") == "mutate" then
				event.content[1].text = "CORRUPTED VOTER VIEW"
				event.input_id = "corrupted-input"
				event.session.session_epoch = "corrupted-epoch"
			end
		end, { prepend = true })
		ctx.policy:voter("agent/input-ready", function(event)
			assert(mare.fs.write(mare.env("HOOK_INPUT_META"), mare.json.encode_strict({
				input_id = event.input_id,
				attempt_id = event.attempt_id,
				revision = event.revision,
				turn_id = event.turn_id,
				source = event.source,
				content = event.content,
				input_context = event.input_context,
				session = event.session,
			}) .. "\n", { append = true }))
		end, { prepend = true })
		ctx.policy:voter("agent/input-ready", function()
			if mare.env("HOOK_INPUT_MODE") == "other-deny" then
				return { decision = "deny", reason = "OTHER POLICY DENIED" }
			end
		end)
		ctx.commands:register("hooks-input-caps", {
			description = "Return agent capabilities",
			run = function()
				return ctx.agent:capabilities()
			end,
		})
		ctx.commands:register("hooks-input-enqueue", {
			description = "Forward enqueue to agent service",
			run = function(args)
				local req = mare.json.decode(args)
				local info = ctx.session:info()
				local owner = req.owner
					or req.expected
					or { session_id = info.session_id, session_epoch = info.session_epoch }
				if owner.session_epoch == nil then
					owner.session_epoch = owner.generation or info.session_epoch
				end
				owner.generation = nil
				return ctx.agent:enqueue(req.content or req.text, owner, {
					source = req.source,
					input_context = req.inputContext,
					delivery = req.delivery,
				})
			end,
		})
		ctx.commands:register("hooks-input-resume", {
			description = "Forward resume_input to agent service",
			run = function(args)
				local req = mare.json.decode(args)
				local info = ctx.session:info()
				local owner = req.owner
					or req.expected
					or { session_id = info.session_id, session_epoch = info.session_epoch }
				if owner.session_epoch == nil then
					owner.session_epoch = owner.generation or info.session_epoch
				end
				owner.generation = nil
				return ctx.agent:resume_input(owner, req.opts)
			end,
		})
		ctx:on("request/build", function(request, ev)
			assert(mare.fs.write(mare.env("HOOK_INPUT_REQUESTS"), mare.json.encode_strict({
				messages = request.messages,
				history = ctx.agent:messages(),
				system = request.system,
				model = request.model and request.model.ref,
			}) .. "\n", { append = true }))
			return ev.next(request)
		end)
		ctx.tools:register("hooks_input_probe", {
			description = "input test",
			side_effect = "read",
			parameters = { type = "object" },
			execute = function()
				return { content = "INPUT TOOL EXECUTED" }
			end,
		})
	end,
}
