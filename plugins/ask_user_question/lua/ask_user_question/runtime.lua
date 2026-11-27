local M = {}
local function same(a, b)
	if type(a) ~= type(b) then
		return false
	end
	if type(a) ~= "table" then
		return a == b
	end
	for k, v in pairs(a) do
		if not same(v, b[k]) then
			return false
		end
	end
	for k in pairs(b) do
		if a[k] == nil then
			return false
		end
	end
	return true
end
local function packed(draft)
	local out = { position = draft.position, drafts = {} }
	for i, d in ipairs(draft.drafts) do
		local selected = mare.json.array({})
		for n, value in pairs(d.selected) do
			if value then
				selected[#selected + 1] = n
			end
		end
		table.sort(selected)
		out.drafts[i] = { selected = selected, status = d.status, custom = d.custom }
	end
	return out
end
local function unpacked(draft, questions)
	if
		type(draft) ~= "table"
		or type(draft.drafts) ~= "table"
		or type(draft.position) ~= "number"
		or draft.position % 1 ~= 0
		or draft.position < 1
		or draft.position > #questions + 1
		or #draft.drafts ~= #questions
	then
		return nil
	end
	local out = { position = draft.position, drafts = {} }
	for i, d in ipairs(draft.drafts) do
		if
			type(d) ~= "table"
			or type(d.selected) ~= "table"
			or (d.status ~= nil and d.status ~= "answered" and d.status ~= "skipped")
			or (
				d.custom ~= nil
				and (
					type(d.custom) ~= "string"
					or not d.custom:match("%S")
					or not utf8.len(d.custom)
					or utf8.len(d.custom) > 10000
				)
			)
		then
			return nil
		end
		local selected = {}
		for _, n in ipairs(d.selected) do
			if type(n) ~= "number" or n % 1 ~= 0 or not questions[i].options[n] or selected[n] then
				return nil
			end
			selected[n] = true
		end
		if not questions[i].multi_select and #d.selected > 1 then
			return nil
		end
		if d.status == "answered" and not next(selected) and not d.custom then
			return nil
		end
		if d.status == "skipped" and (next(selected) or d.custom) then
			return nil
		end
		out.drafts[i] = { selected = selected, status = d.status, custom = d.custom }
	end
	return out
end
function M.new(ctx)
	local current, queue, disposed = nil, {}, false
	local function advance(item)
		if current ~= item then
			return
		end
		current = nil
		while #queue > 0 do
			local next_item = table.remove(queue, 1)
			if not next_item.token:is_cancelled() then
				if not next_item.tx or next_item.tx:send(true) ~= false then
					current = next_item
					break
				end
			end
		end
	end
	local function cancel_all()
		if current then
			current.token:cancel()
		end
		for _, item in ipairs(queue) do
			item.token:cancel()
		end
	end
	ctx:on("session/changed", cancel_all)
	ctx:effect(function()
		return function()
			disposed = true
			cancel_all()
		end
	end)
	local runtime = {}
	function runtime:enter(parent)
		local token = parent and parent:child() or mare.task.token()
		if disposed then
			token:cancel()
		end
		local tx, rx = mare.task.channel()
		local owner = ctx.session:info()
		local item = { token = token, tx = tx, session_epoch = owner.session_epoch, session_id = owner.session_id }
		local function close()
			token:cancel()
			for i, q in ipairs(queue) do
				if q == item then
					table.remove(queue, i)
					break
				end
			end
			advance(item)
		end
		local lease = setmetatable({ token = token }, { __close = close })
		local handed_off = false
		local cleanup <close> = setmetatable({}, {
			__close = function()
				if not handed_off then
					close()
				end
			end,
		})
		if not current then
			current = item
		else
			queue[#queue + 1] = item
			local which = mare.task.select(function()
				return rx:recv()
			end, function()
				token:wait()
			end)
			if which ~= 1 or token:is_cancelled() then
				return nil
			end
		end
		if token:is_cancelled() or ctx.session:info().session_epoch ~= item.session_epoch then
			return nil
		end
		lease.session_epoch = item.session_epoch
		lease.session_id = item.session_id
		handed_off = true
		return lease
	end
	function runtime:restore(lease, execution_id, questions)
		if type(execution_id) ~= "string" or execution_id == "" then
			return nil
		end
		local ok_r, records = pcall(
			require("mare_lib").all_records,
			ctx.session,
			"ask-user/draft",
			{ session_id = lease.session_id, session_epoch = lease.session_epoch }
		)
		if not ok_r or not records then
			lease.token:cancel()
			return nil
		end
		for i = #records, 1, -1 do
			local record = records[i]
			if type(record) == "table" and record.version == 2 and record.execution_id == execution_id then
				return not record.closed and same(record.questions, questions) and unpacked(record.draft, questions)
					or nil
			end
		end
		return nil
	end
	function runtime:save(lease, execution_id, questions, draft, closed)
		if
			type(execution_id) ~= "string"
			or execution_id == ""
			or lease.token:is_cancelled()
			or ctx.session:info().ephemeral
			or ctx.session:info().readonly
		then
			return
		end
		if ctx.session:info().session_epoch ~= lease.session_epoch then
			lease.token:cancel()
			return
		end
		local ok, saved, err = pcall(ctx.session.add_record, ctx.session, "ask-user/draft", {
			version = 2,
			execution_id = execution_id,
			questions = questions,
			draft = draft and packed(draft) or nil,
			closed = closed or false,
		}, { persist = true, session_id = lease.session_id, session_epoch = lease.session_epoch })
		if
			(not ok or not saved)
			and (lease.token:is_cancelled() or ctx.session:info().session_epoch ~= lease.session_epoch)
		then
			lease.token:cancel()
			return
		end
		if not ok or not saved then
			local detail = not ok and (require("mare_lib").error_message(saved) or saved)
				or (require("mare_lib").error_message(err) or err)
			error("Could not save question progress: " .. tostring(detail))
		end
		if ctx.session:info().session_epoch ~= lease.session_epoch then
			lease.token:cancel()
		end
	end
	return runtime
end
return M
