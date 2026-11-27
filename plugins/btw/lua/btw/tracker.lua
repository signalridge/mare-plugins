-- Tracks active side-conversation turns and status from public conversation/* events.
return function(ctx, cfg, on_change)
	local function project(value)
		if mare.projection and type(mare.projection.project) == "function" then
			return mare.projection.project(value)
		end
		return value
	end

	local function trim_tail(text, max_bytes)
		if max_bytes <= 0 then
			return ""
		end
		if mare.text and type(mare.text.cut) == "function" then
			return mare.text.cut(text, max_bytes, { keep = "tail", unit = "bytes" })
		end
		if #text <= max_bytes then
			return text
		end
		return text:sub(#text - max_bytes + 1)
	end

	local function extract_prompt(ev)
		for _, key in ipairs({ "prompt", "user_text", "user_message", "input", "question" }) do
			if type(ev[key]) == "string" and ev[key] ~= "" then
				return project(ev[key])
			end
		end
		return nil
	end

	local function extract_final_text(ev)
		for _, key in ipairs({ "text", "final_text", "response" }) do
			if type(ev[key]) == "string" and ev[key] ~= "" then
				return project(ev[key])
			end
		end
		local msg = type(ev.message) == "table" and ev.message or (type(ev.result) == "table" and ev.result or nil)
		if msg then
			if type(msg.text) == "string" and msg.text ~= "" then
				return project(msg.text)
			end
			if type(msg.content) == "string" and msg.content ~= "" then
				return project(msg.content)
			end
			if type(msg.content) == "table" then
				local parts = {}
				for _, block in ipairs(msg.content) do
					if type(block) == "table" and block.type == "text" and type(block.text) == "string" then
						parts[#parts + 1] = block.text
					end
				end
				if #parts > 0 then
					return project(table.concat(parts))
				end
			end
		end
		return nil
	end

	local function new_buf()
		return { items = {}, head = 1, tail = 0, head_offset = 0, bytes = 0 }
	end

	local function buf_append(buf, str)
		if not str or str == "" then
			return 0
		end
		local len = #str
		buf.tail = buf.tail + 1
		buf.items[buf.tail] = str
		buf.bytes = buf.bytes + len
		return len
	end

	local function buf_materialize(buf)
		if buf.bytes == 0 then
			return ""
		end
		if buf.head == buf.tail then
			local s = buf.items[buf.head]
			return buf.head_offset > 0 and s:sub(buf.head_offset + 1) or s
		end
		local parts = { buf.head_offset > 0 and buf.items[buf.head]:sub(buf.head_offset + 1) or buf.items[buf.head] }
		for i = buf.head + 1, buf.tail do
			parts[#parts + 1] = buf.items[i]
		end
		local joined = table.concat(parts)
		buf.items = { joined }
		buf.head = 1
		buf.tail = 1
		buf.head_offset = 0
		return joined
	end

	local function buf_shrink(buf, cut)
		if cut <= 0 or buf.bytes == 0 then
			return 0
		end
		if cut >= buf.bytes then
			local removed = buf.bytes
			buf.items = {}
			buf.head = 1
			buf.tail = 0
			buf.head_offset = 0
			buf.bytes = 0
			return removed
		end
		local removed = 0
		local rem = cut
		while rem > 0 and buf.head <= buf.tail do
			local c = buf.items[buf.head]
			local avail = #c - buf.head_offset
			if rem >= avail then
				buf.items[buf.head] = nil
				buf.head = buf.head + 1
				buf.head_offset = 0
				buf.bytes = buf.bytes - avail
				removed = removed + avail
				rem = rem - avail
			else
				local sub = buf.head_offset > 0 and c:sub(buf.head_offset + 1) or c
				local trimmed = trim_tail(sub, avail - rem)
				local actual_cut = avail - #trimmed
				if trimmed == "" then
					buf.items[buf.head] = nil
					buf.head = buf.head + 1
					buf.head_offset = 0
				else
					buf.items[buf.head] = trimmed
					buf.head_offset = 0
				end
				buf.bytes = buf.bytes - actual_cut
				removed = removed + actual_cut
				rem = 0
			end
		end
		while buf.head <= buf.tail do
			local c = buf.items[buf.head]
			local byte = c:byte(buf.head_offset + 1)
			if byte < 128 or byte >= 192 then
				break
			end
			buf.head_offset = buf.head_offset + 1
			buf.bytes = buf.bytes - 1
			removed = removed + 1
			if buf.head_offset >= #c then
				buf.items[buf.head] = nil
				buf.head = buf.head + 1
				buf.head_offset = 0
			end
		end
		if buf.head > buf.tail then
			buf.items = {}
			buf.head = 1
			buf.tail = 0
			buf.head_offset = 0
		end
		return removed
	end

	local function tools_bytes(tools)
		local total = 0
		for _, tool in ipairs(tools or {}) do
			total = total + #(tool.output or "")
		end
		return total
	end

	local state = {
		active_id = nil,
		session_id = nil,
		model = nil,
		turns = {},
		turns_head = 1,
		turns_tail = 0,
		active_turns = {},
		active_order = {},
		turn_prompts = {},
		prompt_queue = {},
		prompt_head = 1,
		prompt_tail = 0,
		prompt_queue_bytes = 0,
		dropped_prompts = 0,
		pending_open_prompt = nil,
		cached_bytes = 0,
		truncated = false,
	}

	local function turns_count()
		return state.turns_tail - state.turns_head + 1
	end

	local function push_settled_turn(turn)
		state.turns_tail = state.turns_tail + 1
		state.turns[state.turns_tail] = turn
		state.cached_bytes = state.cached_bytes + turn.bytes
	end

	local function pop_oldest_turn()
		if state.turns_head > state.turns_tail then
			return nil
		end
		local oldest = state.turns[state.turns_head]
		state.turns[state.turns_head] = nil
		state.turns_head = state.turns_head + 1
		if state.turns_head > state.turns_tail then
			state.turns = {}
			state.turns_head = 1
			state.turns_tail = 0
		elseif state.turns_head > 32 and (state.turns_head - 1) >= (state.turns_tail - state.turns_head + 1) then
			local compacted = {}
			for i = state.turns_head, state.turns_tail do
				compacted[#compacted + 1] = state.turns[i]
			end
			state.turns = compacted
			state.turns_head = 1
			state.turns_tail = #compacted
		end
		state.cached_bytes = state.cached_bytes - oldest.bytes
		return oldest
	end

	local function reset()
		state.active_id = nil
		state.session_id = nil
		state.model = nil
		state.turns = {}
		state.turns_head = 1
		state.turns_tail = 0
		state.active_turns = {}
		state.active_order = {}
		state.turn_prompts = {}
		state.prompt_queue = {}
		state.prompt_head = 1
		state.prompt_tail = 0
		state.prompt_queue_bytes = 0
		state.dropped_prompts = 0
		state.pending_open_prompt = nil
		state.cached_bytes = 0
		state.truncated = false
	end

	local function compact_prompt_queue()
		local head = state.prompt_head
		local tail = state.prompt_tail
		while head <= tail and state.prompt_queue[head] == nil do
			head = head + 1
		end
		if head > tail then
			state.prompt_queue = {}
			state.prompt_head = 1
			state.prompt_tail = 0
			return
		end
		state.prompt_head = head
		if head > 1 and (head > 16 or (head - 1) >= (tail - head + 1)) then
			local compacted = {}
			for i = head, tail do
				compacted[#compacted + 1] = state.prompt_queue[i]
			end
			state.prompt_queue = compacted
			state.prompt_head = 1
			state.prompt_tail = #compacted
		end
	end

	local function trim_turn_excess(turn, excess, is_active)
		if excess <= 0 then
			return 0
		end
		local function shrink_str(str)
			if excess <= 0 or not str or #str == 0 then
				return str
			end
			local old_len = #str
			local cut = math.min(old_len, excess)
			local trimmed = trim_tail(str, old_len - cut)
			local removed = old_len - #trimmed
			excess = math.max(0, excess - cut)
			turn.bytes = turn.bytes - removed
			state.cached_bytes = state.cached_bytes - removed
			turn.truncated = true
			state.truncated = true
			return trimmed
		end
		local function shrink_active_buf(buf)
			if excess <= 0 or buf.bytes == 0 then
				return
			end
			local cut = math.min(buf.bytes, excess)
			local removed = buf_shrink(buf, cut)
			if removed > 0 then
				excess = math.max(0, excess - cut)
				turn.bytes = turn.bytes - removed
				state.cached_bytes = state.cached_bytes - removed
				turn.truncated = true
				state.truncated = true
			end
		end
		if is_active then
			shrink_active_buf(turn.reasoning_buf)
			shrink_active_buf(turn.text_buf)
		else
			turn.reasoning = shrink_str(turn.reasoning)
			turn.text = shrink_str(turn.text)
		end
		for _, tool in ipairs(turn.tools or {}) do
			tool.output = shrink_str(tool.output)
		end
		turn.prompt = shrink_str(turn.prompt)
		turn.error = shrink_str(turn.error)
		return excess
	end

	local function enforce_budget()
		local cap = cfg.max_transcript_bytes
		if not cap or state.cached_bytes <= cap then
			return
		end
		while turns_count() > 0 and state.cached_bytes > cap do
			if turns_count() == 1 and #state.active_order == 0 then
				break
			end
			pop_oldest_turn()
			state.truncated = true
		end
		local excess = state.cached_bytes - cap
		if excess <= 0 then
			return
		end
		-- Drop or trim oldest queued prompts from head to tail.
		-- Dropped slots are counted in `dropped_prompts` so later prompts
		-- never shift onto earlier turns while keeping memory O(1).
		while state.prompt_head <= state.prompt_tail and excess > 0 do
			local p = state.prompt_queue[state.prompt_head]
			if type(p) == "string" and #p > 0 then
				if #p <= excess then
					state.prompt_queue[state.prompt_head] = nil
					state.prompt_head = state.prompt_head + 1
					state.dropped_prompts = state.dropped_prompts + 1
					state.prompt_queue_bytes = state.prompt_queue_bytes - #p
					state.cached_bytes = state.cached_bytes - #p
					excess = excess - #p
				else
					local trimmed = trim_tail(p, #p - excess)
					local removed = #p - #trimmed
					if trimmed ~= "" then
						state.prompt_queue[state.prompt_head] = trimmed
					else
						state.prompt_queue[state.prompt_head] = nil
						state.prompt_head = state.prompt_head + 1
						state.dropped_prompts = state.dropped_prompts + 1
					end
					state.prompt_queue_bytes = state.prompt_queue_bytes - removed
					state.cached_bytes = state.cached_bytes - removed
					excess = math.max(0, excess - removed)
				end
				state.truncated = true
			else
				state.prompt_queue[state.prompt_head] = nil
				state.prompt_head = state.prompt_head + 1
			end
		end
		compact_prompt_queue()
		if excess > 0 then
			local keys = {}
			for k in pairs(state.turn_prompts) do
				keys[#keys + 1] = k
			end
			table.sort(keys)
			for _, k in ipairs(keys) do
				if excess <= 0 then
					break
				end
				local p = state.turn_prompts[k] or ""
				if #p <= excess then
					state.turn_prompts[k] = nil
					state.cached_bytes = state.cached_bytes - #p
					excess = excess - #p
				else
					local trimmed = trim_tail(p, #p - excess)
					local removed = #p - #trimmed
					state.turn_prompts[k] = trimmed
					state.cached_bytes = state.cached_bytes - removed
					excess = math.max(0, excess - removed)
				end
				state.truncated = true
			end
		end
		for i = #state.active_order, 1, -1 do
			local turn = state.active_turns[state.active_order[i]]
			if turn then
				excess = trim_turn_excess(turn, excess, true)
			end
		end
		if excess > 0 and turns_count() > 0 then
			trim_turn_excess(state.turns[state.turns_tail], excess, false)
		end
	end

	local function pop_prompt(turn_id)
		if turn_id and state.turn_prompts[turn_id] then
			local p = state.turn_prompts[turn_id]
			state.turn_prompts[turn_id] = nil
			state.cached_bytes = state.cached_bytes - #p
			return p
		end
		if state.dropped_prompts > 0 then
			state.dropped_prompts = state.dropped_prompts - 1
			return nil
		end
		if state.prompt_head <= state.prompt_tail then
			local p = state.prompt_queue[state.prompt_head]
			state.prompt_queue[state.prompt_head] = nil
			state.prompt_head = state.prompt_head + 1
			compact_prompt_queue()
			if type(p) == "string" and p ~= "" then
				state.prompt_queue_bytes = state.prompt_queue_bytes - #p
				state.cached_bytes = state.cached_bytes - #p
				return p
			end
		end
		return nil
	end

	local function ensure_turn(turn_id)
		local key = turn_id or "__default__"
		local cur = state.active_turns[key]
		if not cur then
			local p = pop_prompt(turn_id)
			local p_bytes = #(p or "")
			cur = {
				turn_id = turn_id,
				prompt = p,
				text_buf = new_buf(),
				reasoning_buf = new_buf(),
				tools = {},
				bytes = p_bytes,
			}
			state.cached_bytes = state.cached_bytes + p_bytes
			state.active_turns[key] = cur
			state.active_order[#state.active_order + 1] = key
		end
		return cur
	end

	local function remove_active_turn(key)
		state.active_turns[key] = nil
		for i, k in ipairs(state.active_order) do
			if k == key then
				table.remove(state.active_order, i)
				break
			end
		end
	end

	local function copy_tools(tools)
		local out = {}
		for _, tool in ipairs(tools or {}) do
			out[#out + 1] = {
				id = tool.id,
				name = tool.name,
				output = tool.output,
				done = tool.done == true,
				is_error = tool.is_error == true,
			}
		end
		return out
	end

	local function sync_info()
		local info = ctx.conversations:info()
		if not info then
			if state.active_id ~= nil then
				reset()
			end
			return nil
		end
		if state.active_id ~= info.conversation_id then
			local saved_prompts = state.prompt_queue
			local saved_head = state.prompt_head
			local saved_tail = state.prompt_tail
			local saved_dropped = state.dropped_prompts
			local saved_prompt_bytes = state.prompt_queue_bytes
			reset()
			state.active_id = info.conversation_id
			state.session_id = info.session_id
			state.model = info.model
			state.prompt_queue = saved_prompts
			state.prompt_head = saved_head
			state.prompt_tail = saved_tail
			state.dropped_prompts = saved_dropped
			state.prompt_queue_bytes = saved_prompt_bytes
			state.cached_bytes = saved_prompt_bytes
		elseif info.model and not state.model then
			state.model = info.model
		end
		return info
	end

	local function notify(reason)
		if on_change then
			on_change(reason)
		end
	end

	ctx:on("conversation/opened", function(ev)
		if type(ev) ~= "table" then
			return
		end
		local saved_prompts = state.prompt_queue
		local saved_head = state.prompt_head
		local saved_tail = state.prompt_tail
		local saved_dropped = state.dropped_prompts
		local saved_prompt_bytes = state.prompt_queue_bytes
		local pending_open = state.pending_open_prompt
		reset()
		state.active_id = ev.id
		state.session_id = ev.session_id
		state.model = ev.model
		state.prompt_queue = saved_prompts
		state.prompt_head = saved_head
		state.prompt_tail = saved_tail
		state.dropped_prompts = saved_dropped
		state.prompt_queue_bytes = saved_prompt_bytes
		state.cached_bytes = saved_prompt_bytes
		if type(pending_open) == "string" and pending_open ~= "" then
			state.prompt_tail = state.prompt_tail + 1
			state.prompt_queue[state.prompt_tail] = pending_open
			state.prompt_queue_bytes = state.prompt_queue_bytes + #pending_open
			state.cached_bytes = state.cached_bytes + #pending_open
			enforce_budget()
		end
		notify("opened")
	end)

	ctx:on("conversation/changed", function(ev)
		local info = sync_info()
		if type(ev) == "table" and info and ev.id ~= info.conversation_id then
			return
		end
		notify("changed")
	end)

	ctx:on("conversation/stream", function(ev)
		if type(ev) ~= "table" or type(ev.event) ~= "table" then
			return
		end
		local info = sync_info()
		if not info or ev.id ~= info.conversation_id then
			return
		end
		local cur = ensure_turn(ev.turn_id)
		local had_text = cur.text_buf.bytes > 0
		local ep = extract_prompt(ev)
		if ep and ep ~= cur.prompt then
			local delta_p = #ep - #(cur.prompt or "")
			cur.prompt = ep
			cur.bytes = cur.bytes + delta_p
			state.cached_bytes = state.cached_bytes + delta_p
		end
		local item = ev.event
		if item.type == "text_delta" then
			local delta_len = buf_append(cur.text_buf, project(tostring(item.delta or "")))
			cur.bytes = cur.bytes + delta_len
			state.cached_bytes = state.cached_bytes + delta_len
			enforce_budget()
			if not had_text and cur.text_buf.bytes > 0 then
				notify("stream")
			end
		elseif item.type == "reasoning_delta" then
			local delta_len = buf_append(cur.reasoning_buf, project(tostring(item.delta or "")))
			cur.bytes = cur.bytes + delta_len
			state.cached_bytes = state.cached_bytes + delta_len
			enforce_budget()
		elseif item.type == "tool_start" then
			local call = type(item.call) == "table" and item.call or {}
			cur.tools[#cur.tools + 1] = {
				id = call.id,
				name = tostring(call.name or "tool"),
				output = nil,
				done = false,
				is_error = false,
			}
			notify("tool_start")
		elseif item.type == "tool_output" then
			local partial = type(item.partial) == "table" and item.partial or {}
			local raw = partial.output or partial.content
			if type(raw) == "string" then
				local target = cur.tools[#cur.tools]
				if target then
					local old_len = #(target.output or "")
					local new_out = trim_tail(project(raw), cfg.max_output_bytes)
					target.output = new_out
					local delta_bytes = #new_out - old_len
					cur.bytes = cur.bytes + delta_bytes
					state.cached_bytes = state.cached_bytes + delta_bytes
					enforce_budget()
				end
			end
		elseif item.type == "tool_result" then
			local target = cur.tools[#cur.tools]
			if target then
				target.done = true
				target.is_error = type(item.result) == "table" and item.result.is_error == true
			end
			notify("tool_result")
		end
	end)

	ctx:on("conversation/settled", function(ev)
		if type(ev) ~= "table" then
			return
		end
		local info = sync_info()
		if not info or ev.id ~= info.conversation_id then
			return
		end
		local key = ev.turn_id or state.active_order[1] or "__default__"
		local cur = state.active_turns[key]
		if cur then
			remove_active_turn(key)
			state.cached_bytes = state.cached_bytes - cur.bytes
		end
		local final_text = extract_final_text(ev)
		local text = (cur and cur.text_buf.bytes > 0 and buf_materialize(cur.text_buf)) or final_text or ""
		local reasoning = (cur and cur.reasoning_buf.bytes > 0 and buf_materialize(cur.reasoning_buf))
			or (type(ev.reasoning) == "string" and project(ev.reasoning))
			or ""
		local ev_prompt = extract_prompt(ev)
		local popped_prompt = (not cur) and pop_prompt(ev.turn_id) or nil
		local prompt = ev_prompt or (cur and cur.prompt) or popped_prompt or nil
		local tools = copy_tools(cur and cur.tools)
		local err_str = ev.error and project(tostring(require("mare_lib").error_message(ev.error) or ev.error)) or nil
		local settled_bytes = #(prompt or "") + #text + #reasoning + #(err_str or "") + tools_bytes(tools)
		push_settled_turn({
			turn_id = ev.turn_id or (cur and cur.turn_id),
			prompt = prompt,
			text = text,
			reasoning = reasoning,
			tools = tools,
			error = err_str,
			truncated = cur and cur.truncated or nil,
			bytes = settled_bytes,
		})
		while turns_count() > cfg.max_turns do
			pop_oldest_turn()
		end
		enforce_budget()
		notify("settled")
	end)

	local function clear_on_event(reason)
		return function()
			reset()
			notify(reason)
		end
	end

	ctx:on("conversation/closed", clear_on_event("closed"))
	ctx:on("session/changed", clear_on_event("session_changed"))
	ctx:on("session/loaded", clear_on_event("session_loaded"))

	local M = {}

	function M.set_pending_open(text)
		if type(text) == "string" and text ~= "" then
			state.pending_open_prompt = project(text)
		else
			state.pending_open_prompt = nil
		end
	end

	function M.clear_pending_open()
		state.pending_open_prompt = nil
	end

	function M.queue_prompt(text)
		if type(text) == "string" and text ~= "" then
			local p = project(text)
			state.prompt_tail = state.prompt_tail + 1
			state.prompt_queue[state.prompt_tail] = p
			state.prompt_queue_bytes = state.prompt_queue_bytes + #p
			state.cached_bytes = state.cached_bytes + #p
			enforce_budget()
		end
	end

	function M.record_prompt(turn_id, text)
		if type(text) ~= "string" or text == "" then
			return
		end
		local projected = project(text)
		if turn_id then
			local cur = state.active_turns[turn_id]
			if cur then
				if not cur.prompt then
					cur.prompt = projected
					cur.bytes = cur.bytes + #projected
					state.cached_bytes = state.cached_bytes + #projected
				end
			else
				local old = state.turn_prompts[turn_id]
				state.turn_prompts[turn_id] = projected
				state.cached_bytes = state.cached_bytes - #(old or "") + #projected
			end
		else
			state.prompt_tail = state.prompt_tail + 1
			state.prompt_queue[state.prompt_tail] = projected
			state.prompt_queue_bytes = state.prompt_queue_bytes + #projected
			state.cached_bytes = state.cached_bytes + #projected
		end
		enforce_budget()
	end

	function M.status()
		local info = sync_info()
		if not info then
			return {
				open = false,
				selected = false,
				parked = false,
				busy = false,
				turn_count = 0,
			}
		end
		local status = {
			open = true,
			id = info.conversation_id,
			ui_context_id = info.ui_context_id,
			session_id = info.session_id,
			selected = info.selected == true,
			parked = info.selected ~= true,
			busy = info.busy == true,
			model = info.model,
			params = info.params,
			message_count = info.message_count,
			turn_id = info.turn_id,
			parent_status = info.parent_status,
			turn_count = turns_count(),
		}
		return project(status)
	end

	local function json_array(t)
		return (mare and mare.json and mare.json.array) and mare.json.array(t) or t
	end

	function M.transcript()
		local info = sync_info()
		if not info then
			return { open = false, turns = json_array({}) }
		end
		local turns = json_array({})
		for i = state.turns_head, state.turns_tail do
			local t = state.turns[i]
			turns[#turns + 1] = {
				turn_id = t.turn_id,
				prompt = t.prompt,
				text = t.text,
				reasoning = t.reasoning,
				tools = copy_tools(t.tools),
				error = t.error,
				truncated = t.truncated,
			}
		end
		local streaming
		local active_key = state.active_order[#state.active_order]
		local cur = active_key and state.active_turns[active_key] or nil
		if cur then
			streaming = {
				turn_id = cur.turn_id,
				prompt = cur.prompt,
				text = buf_materialize(cur.text_buf),
				reasoning = buf_materialize(cur.reasoning_buf),
				tools = copy_tools(cur.tools),
				truncated = cur.truncated,
			}
		end
		return project({
			open = true,
			id = info.conversation_id,
			session_id = info.session_id,
			model = info.model or state.model,
			turns = turns,
			streaming = streaming,
			truncated = state.truncated,
		})
	end

	function M.activity()
		local info = sync_info()
		if not info then
			return nil
		end
		return {
			open = true,
			id = info.conversation_id,
			selected = info.selected == true,
			parked = info.selected ~= true,
			busy = info.busy == true,
			turn_count = turns_count(),
			parent_status = info.parent_status,
		}
	end

	function M.dispose()
		reset()
	end

	return M
end
