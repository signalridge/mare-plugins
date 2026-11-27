-- Accepted-input identity belongs to the agent. This adapter neither queues input nor writes
-- an independent journal. Async policy work is cached for the pure selected-history transaction.
return function(ctx, run, register)
	local capability = require("hooks.capability")
	if
		not capability.check_capability(
			ctx.agent,
			"input_admission",
			1,
			"UserPromptSubmit",
			"agent:capabilities().input_admission == 1"
		)
	then
		return
	end
	if not pcall(capability.step, ctx, "UserPromptSubmit") then
		capability.warn("hooks: UserPromptSubmit skipped; core does not provide agent:step_participant / step_state")
		return
	end
	local pending = {}
	local function prune(turn_id)
		for id, item in pairs(pending) do
			if item.turn_id ~= turn_id or item.cancel:is_cancelled() then
				pending[id] = nil
			end
		end
	end
	register("agent/input-ready", function(event)
		assert(
			event.cancel and event.input_id and event.attempt_id and event.session,
			"input-ready operation identity is required"
		)
		prune(event.turn_id)
		local text = {}
		for _, block in ipairs(event.content) do
			if block.type == "text" then
				text[#text + 1] = block.text
			end
		end
		local vote = run(
			"UserPromptSubmit",
			"",
			{ prompt = table.concat(text, "\n"), turn_id = event.turn_id },
			{ cancel = event.cancel }
		)
		if vote.decision ~= "allow" then
			return { decision = "deny", reason = vote.reason or "UserPromptSubmit blocked input", abort = vote.abort }
		end
		if vote.context and vote.context ~= "" then
			if #vote.context > 65536 then
				return { decision = "deny", reason = "hook context exceeds the shared disclosure budget" }
			end
			local item = {
				input_id = event.input_id,
				attempt_id = event.attempt_id,
				revision = event.revision,
				turn_id = event.turn_id,
				session_id = event.session.session_id,
				session_epoch = event.session.session_epoch,
				text = vote.context,
				cancel = event.cancel,
			}
			local used = 0
			for _, cached in pairs(pending) do
				used = used + #cached.text
			end
			local remaining = 65536 - used
			local text = vote.context
			if #text > remaining then
				local capped = remaining >= 512 and select(1, require("hooks.spill").cap_context(text, remaining))
					or nil
				if not capped then
					return { decision = "deny", reason = "pending hook contexts exceed the shared disclosure budget" }
				end
				text = capped
			end
			item.text = text
			pending[event.attempt_id] = item
		end
		return { decision = "allow" }
	end)
	ctx.agent:step_participant("hooks.prompts", function(previous, step)
		local seen, contexts, ids, metadata = {}, {}, {}, {}
		for _, id in ipairs(previous and previous.attempts or {}) do
			seen[id] = true
		end
		local session = ctx.session:info()
		for _, message in ipairs(step.messages) do
			local id = message.input_attempt_id
			local item = id and pending[id]
			if
				item
				and message.input_id == item.input_id
				and item.turn_id == step.turn_id
				and item.session_id == session.session_id
				and item.session_epoch == session.session_epoch
			then
				ids[#ids + 1] = id
				if not seen[id] then
					contexts[#contexts + 1] = item.text
					metadata[#metadata + 1] = { input_id = item.input_id, attempt_id = id, revision = item.revision }
					seen[id] = true
				end
			end
		end
		if #contexts == 0 then
			return
		end
		return {
			state = { attempts = ids },
			disclosures = {
				{
					source = "hooks",
					text = table.concat(contexts, "\n\n"),
					metadata = { event = "UserPromptSubmit", inputs = metadata },
				},
			},
		}
	end, { output = "transaction" })
	ctx:on("agent/step-committed", function()
		local state = ctx.agent:step_state("hooks.prompts")
		for _, id in ipairs(state and state.attempts or {}) do
			pending[id] = nil
		end
	end)
	ctx:on("turn/completed", function(event)
		for id, item in pairs(pending) do
			if item.turn_id == event.turn_id then
				pending[id] = nil
			end
		end
	end)
	ctx:effect(function()
		return function()
			pending = {}
		end
	end)
end
