-- Run the external hook once at canonical settlement. Apply dialect feedback after later
-- canonical replacements, before display retention. Script output never rewrites canonical.
return function(ctx, run, register)
	if
		not require("hooks.capability").check_capability(
			ctx.tools,
			"result_pipeline",
			1,
			"PostToolUse",
			"tools:capabilities().result_pipeline == 1"
		)
	then
		return
	end
	local pending = {}
	local function append(result, text)
		if not text or text == "" then
			return
		end
		if type(result.content) == "string" then
			result.content = result.content .. "\n\n" .. text
		elseif type(result.content) == "table" then
			result.content[#result.content + 1] = { type = "text", text = text }
		else
			result.content = text
		end
	end
	register("tool/program-result", function(result, call, operation)
		if call and call.name == "call_tool" then
			return result
		end
		if not operation or not operation.execution_id then
			result.is_error = true
			append(result, "PostToolUse unavailable: public execution identity contract is required")
			return result
		end
		for id, item in pairs(pending) do
			if item.cancel and item.cancel:is_cancelled() then
				pending[id] = nil
			end
		end
		local vote = run("PostToolUse", call.name, {
			cwd = call.cwd or mare.cwd,
			tool_name = call.name,
			tool_input = call.arguments,
			tool_use_id = call.id,
			tool_response = result,
		}, operation)
		local feedback = vote.context
		if vote.decision ~= "allow" then
			feedback = (feedback and feedback .. "\n\n" or "") .. (vote.reason or "PostToolUse hook blocked the result")
			result.is_error = true
		end
		pending[operation.execution_id] =
			{ feedback = feedback, blocked = vote.decision ~= "allow", cancel = operation.cancel }
		if vote.abort and operation.run_cancel then
			operation.run_cancel:cancel()
		end
		return result
	end)
	register("tool/after", function(result, _, operation) -- a waterfall: the registrar wraps it
		local item = operation and pending[operation.execution_id]
		if item then
			pending[operation.execution_id] = nil
			append(result, item.feedback)
			result.is_error = result.is_error or item.blocked or nil
		end
		return result
	end)
	ctx:effect(function()
		return function()
			pending = {}
		end
	end)
end
