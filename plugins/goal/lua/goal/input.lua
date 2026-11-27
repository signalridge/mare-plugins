-- Goal command references and input queuing.
-- The domain stores no attachment bytes. Mare's shared enqueue owns canonical
-- ordering/IDs/receipts; a durable activation fence covers separate receipt failure.
return function(ctx, store, runtime)
	local M = {}
	local function normalize_content(content)
		if mare.input and require("mare_lib").callable(mare.input.content) then
			return mare.input.content(content or mare.json.array({}))
		end
		local out = mare.json.array({})
		for _, block in ipairs(content or {}) do
			out[#out + 1] = block
		end
		return out
	end
	function M.prepare(args, input)
		local blocks = normalize_content(input and input.content)
		local refs = mare.json.array({})
		for i = 2, #blocks do
			refs[#refs + 1] = blocks[i]
		end
		local action = args:match("^(%S+)")
		if
			#refs > 0
			and (
				not action
				or action == "status"
				or action == "pause"
				or action == "resume"
				or action == "clear"
				or action == "budget"
				or action == "rounds"
			)
		then
			return nil,
				"Goal references require a create or edit objective; control commands do not consume attachments."
		end
		return { content = refs, owner = store.owner(), input_context = input and input.input_context }
	end
	function M.deliver(value, prepared)
		if #prepared.content == 0 then
			return true, nil
		end
		local refs = normalize_content(prepared.content)
		refs[#refs + 1] = {
			type = "text",
			text = "Reference attachments for the goal objective. Goal ID: "
				.. value.id
				.. "; revision: "
				.. value.revision
				.. ".",
		}
		local pending = runtime.pending_reference_delivery
		local same_pending = pending
			and pending.goal_id == value.id
			and pending.revision == value.revision
			and store.same(pending.owner, prepared.owner)
		local request_id = same_pending and pending.request_id
			or ("goal-ref:" .. tostring(value.id) .. ":" .. tostring(value.revision))
		local ok, receipt = pcall(
			ctx.agent.enqueue,
			ctx.agent,
			refs,
			{ session_id = prepared.owner.id, session_epoch = prepared.owner.generation },
			{
				delivery = "follow_up",
				source = "goal-reference",
				request_id = request_id,
				input_context = prepared.input_context,
			}
		)
		if not ok or type(receipt) ~= "table" then
			runtime.stopped = true
			if same_pending then
				runtime.pending_reference_delivery = nil
			end
			local err_msg = not ok and tostring(receipt) or "invalid enqueue receipt"
			return nil, "Goal saved, but reference delivery failed: " .. err_msg
		end
		if receipt.status ~= "queued" or not receipt.durable then
			runtime.stopped = true
			if receipt.status == "indeterminate" or (receipt.status == "queued" and not receipt.durable) then
				runtime.pending_reference_delivery = {
					goal_id = value.id,
					revision = value.revision,
					request_id = request_id,
					owner = prepared.owner,
					refs = refs,
					input_context = prepared.input_context,
				}
			elseif same_pending then
				runtime.pending_reference_delivery = nil
			end
			if receipt.status == "indeterminate" then
				return nil,
					"Goal saved, but reference delivery outcome is indeterminate; inspect session state before retrying. "
						.. tostring(receipt.error or receipt.status)
			end
			return nil,
				"Goal saved but reference delivery was not durably acknowledged; retry this command with its attachments. "
					.. tostring(receipt.error or receipt.status)
		end
		runtime.pending_reference_delivery = nil
		runtime.reference_inputs[receipt.input_id] =
			{ goal_id = value.id, revision = value.revision, owner = prepared.owner }
		local ready, err = runtime.references_ready({ goal_id = value.id, revision = value.revision }, prepared.owner)
		if not ready then
			runtime.stopped = true
			return nil,
				"Reference input was queued, but the goal changed or its delivery checkpoint could not be saved: "
					.. tostring(err)
		end
		return true, receipt.input_id
	end
	return M
end
