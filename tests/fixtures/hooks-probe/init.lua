return {
	name = "hooks-probe",
	inject = { "tools", "session", "policy" },
	apply = function(ctx)
		local mode = mare.env("HOOK_MODE")
		local retried = false
		local win_partial = mare.os == "windows" and { "fs_protect", "network" } or nil
		ctx:on("app/ready", function()
			ctx.session:set_sandbox_mode({
				level = mode == "sandbox" and "read-only" or "workspace-write",
				network = true,
				accept_partial = win_partial,
			})
		end)
		ctx.tools:register("hooks_probe", {
			description = "test hooks validation",
			parameters = { type = "object", properties = { value = { type = "string" } }, required = { "value" } },
			side_effect = "read",
			execute = function(args)
				return { content = "PROBE EXECUTED " .. args.value, is_error = mode == "post-error" or nil }
			end,
		})
		ctx:on("tool/after", function(data, ev)
			local call, operation = data.call, data.operation
			if call.name == "hooks_probe" and mode:match("^post%-") then
				assert(mare.fs.write("after-chain", mare.json.encode_strict({
					execution_id = operation and operation.execution_id,
					value = call.arguments.value,
				}) .. "\n", { append = true }))
			end
			return ev.next(data)
		end)
		ctx.policy:rewriter("tool/rewrite", function(call)
			if call.name == "hooks_probe" and mode:match("^post%-") then
				return { value = "executed" }
			end
		end)
		-- core: waterfall("tool/program-result", { result = program, call = call, operation = operation })
		ctx:on("tool/program-result", function(data, ev)
			local result, call, operation = data.result, data.call, data.operation
			if call.name == "hooks_probe" and mode == "post-generic" then
				result.content = "GENERIC REPLACEMENT"
			end
			local out = ev.next()
			-- recorded once the rest of the chain has returned: the e2e checks the chain went on
			if call.name == "hooks_probe" then
				assert(mare.fs.write("program-result-chain", mare.json.encode_strict({
					execution_id = operation and operation.execution_id,
					value = call.arguments.value,
					returned = type(out) == "table",
				}) .. "\n", { append = true }))
			end
			return out
		end)
		ctx.policy:voter("tool/before", function(call)
			if call.name ~= "hooks_probe" then
				return
			end
			if mode == "retry" and not retried then
				retried = true
				-- Real sandbox generation change makes the already-voted snapshot obsolete.
				mare.proc.sandbox.set_current(
					{ level = "workspace-write", network = false, accept_partial = win_partial },
					mare.cwd
				)
			elseif mode == "other-deny" or mode == "post-refused" then
				return { decision = "deny", reason = "independent policy denied" }
			end
		end)
	end,
}
