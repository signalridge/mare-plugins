-- PreToolUse handler adapter: policy admission + additionalContext disclosure transaction.
local spill = require("hooks.spill")

return function(ctx, run, register, turn)
	local items = {}
	local has_participant = ctx.agent and require("mare_lib").callable(ctx.agent.step_participant)

	local function trim_old()
		while #items > 16 do
			table.remove(items, 1)
		end
	end

	local function session_owner()
		if not (ctx.session and require("mare_lib").callable(ctx.session.info)) then
			return nil, nil
		end
		local ok, info = pcall(ctx.session.info, ctx.session)
		if not ok or type(info) ~= "table" then
			return nil, nil
		end
		return info.session_id, info.session_epoch
	end

	local function prune_other_sessions(cur_id, cur_gen)
		if not cur_id and not cur_gen then
			return
		end
		local kept = {}
		for _, item in ipairs(items) do
			if
				(item.session_id == nil and item.generation == nil)
				or (item.session_id == cur_id and item.generation == cur_gen)
			then
				kept[#kept + 1] = item
			end
		end
		items = kept
	end

	register("tool/before", function(call, _, operation)
		if call and call.name == "call_tool" then
			return nil
		end
		local owner_id, owner_gen = session_owner()
		prune_other_sessions(owner_id, owner_gen)
		local payload = {
			cwd = call.cwd or mare.cwd,
			tool_name = call.name,
			tool_input = call.arguments,
			tool_use_id = call.id,
		}
		local vote = run("PreToolUse", call.name, payload, operation)
		local cur_id, cur_gen = session_owner()
		if cur_id ~= owner_id or cur_gen ~= owner_gen then
			prune_other_sessions(cur_id, cur_gen)
			return { decision = vote.decision, reason = vote.reason, abort = vote.abort }
		end
		if vote.decision == "allow" and vote.context and vote.context ~= "" then
			if not has_participant then
				return {
					decision = "deny",
					reason = "PreToolUse additionalContext requires step_participant capability",
					abort = vote.abort,
				}
			end
			local capped, err = spill.cap_context(vote.context, 65536)
			if not capped then
				return { decision = "deny", reason = err, abort = vote.abort }
			end
			local id = mare.crypto and type(mare.crypto.random_hex) == "function" and mare.crypto.random_hex(12)
				or string.format("%s:%d", tostring(call.id or "tool"), #items + 1)
			items[#items + 1] = {
				id = id,
				tool_name = call.name,
				tool_call_id = call.id,
				turn_id = turn(),
				session_id = owner_id,
				generation = owner_gen,
				text = capped,
			}
			trim_old()
		end
		return { decision = vote.decision, reason = vote.reason, abort = vote.abort }
	end)

	if not has_participant then
		return
	end

	ctx.agent:step_participant("hooks.pre_tool", function(previous, step)
		local cur_id, cur_gen = session_owner()
		prune_other_sessions(cur_id, cur_gen)
		if #items == 0 then
			return
		end
		local last = previous and previous.last_id
		local first = 1
		for index, item in ipairs(items) do
			if item.id == last then
				first = index + 1
			end
		end
		if first > #items then
			return
		end
		local disclosures, total_bytes, last_id = {}, 0, nil
		local turn_id = step and step.turn_id
		for index = first, #items do
			local item = items[index]
			if not turn_id or not item.turn_id or item.turn_id == "" or item.turn_id == turn_id then
				if total_bytes + #item.text > 65536 and #disclosures > 0 then
					break
				end
				disclosures[#disclosures + 1] = {
					source = "hooks",
					text = item.text,
					metadata = {
						event = "PreToolUse",
						tool_name = item.tool_name,
						tool_call_id = item.tool_call_id,
						id = item.id,
					},
				}
				total_bytes = total_bytes + #item.text
				last_id = item.id
				if #disclosures >= 16 then
					break
				end
			end
		end
		if #disclosures == 0 then
			return
		end
		return { state = { last_id = last_id }, disclosures = disclosures }
	end, { output = "transaction" })

	ctx:on("agent/step-committed", function()
		local state = ctx.agent:step_state("hooks.pre_tool")
		if state and state.last_id then
			for index, item in ipairs(items) do
				if item.id == state.last_id then
					for _ = 1, index do
						table.remove(items, 1)
					end
					break
				end
			end
		end
	end)

	ctx:on("turn/completed", function(event)
		if not event or not event.turn_id then
			return
		end
		local kept = {}
		for _, item in ipairs(items) do
			if item.turn_id ~= event.turn_id then
				kept[#kept + 1] = item
			end
		end
		items = kept
	end)

	ctx:effect(function()
		return function()
			items = {}
		end
	end)
end
