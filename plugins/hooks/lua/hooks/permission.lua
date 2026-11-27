-- PermissionRequest votes on tool/approval; any deny wins, and allow cannot bypass other policies.
return function(ctx, run, register)
	register("tool/approval", function(call, _, _, cancel)
		if call and call.name == "call_tool" then
			return nil
		end
		local vote = run("PermissionRequest", call.name, {
			cwd = call.cwd or mare.cwd,
			tool_name = call.name,
			tool_input = call.arguments,
		}, cancel and { cancel = cancel } or nil)
		if vote.decision == "deny" then
			return { decision = "deny", reason = vote.reason, abort = vote.abort }
		end
		if vote.decided and vote.decision == "allow" then
			return { decision = "allow", source = "hook" }
		end
		return nil
	end)
end
