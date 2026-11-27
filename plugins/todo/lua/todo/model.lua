local M = {}
local states = { pending = true, in_progress = true, completed = true }
-- Match JavaScript String.trim whitespace semantics, including Unicode spaces and BOM.
local function trim(text)
	local first, last
	for index, code in utf8.codes(text) do
		local space = code >= 9 and code <= 13
			or code == 32
			or code == 0xA0
			or code == 0x1680
			or code >= 0x2000 and code <= 0x200A
			or code == 0x2028
			or code == 0x2029
			or code == 0x202F
			or code == 0x205F
			or code == 0x3000
			or code == 0xFEFF
		if not space then
			first = first or index
			last = index + #utf8.char(code) - 1
		end
	end
	return first and text:sub(first, last) or ""
end
function M.canonical(raw, parallel)
	if type(raw) ~= "table" or not mare.json.is_array(raw) then
		error("todos must be an array")
	end
	local out, seen, active = mare.json.array({}), {}, 0
	for i, item in ipairs(raw) do
		local index = i - 1
		if type(item) ~= "table" then
			error(("todos[%d] must be an object"):format(index))
		end
		for key in pairs(item) do
			if key ~= "content" and key ~= "status" then
				error(("todos[%d] unknown field: %s"):format(index, tostring(key)))
			end
		end
		if type(item.content) ~= "string" then
			error(("todos[%d].content must be a non-empty string"):format(index))
		end
		local content = trim(item.content)
		if content == "" then
			error(("todos[%d].content must be a non-empty string"):format(index))
		end
		if not states[item.status] then
			error(("todos[%d].status must be pending, in_progress, or completed"):format(index))
		end
		if seen[content] then
			error(("todos[%d].content duplicates %s"):format(index, mare.json.encode(content)))
		end
		seen[content] = true
		active = active + (item.status == "in_progress" and 1 or 0)
		out[#out + 1] = { content = content, status = item.status }
	end
	if not parallel and active > 1 then
		error(("at most one task may be in_progress (got %d)"):format(active))
	end
	return out
end
function M.counts(todos)
	local counts = { pending = 0, in_progress = 0, completed = 0 }
	for _, item in ipairs(todos) do
		counts[item.status] = counts[item.status] + 1
	end
	return counts
end
-- Compare retained positions, rather than original indices: inserting an item
-- doesn't falsely report every following entry as moved.
function M.diff(previous, current)
	local old, kept, present = {}, {}, {}
	for _, item in ipairs(current) do
		present[item.content] = true
	end
	for _, item in ipairs(previous) do
		old[item.content] = item
		if present[item.content] then
			kept[#kept + 1] = item.content
		end
	end
	local changes, counts, retained = mare.json.array({}), { added = 0, updated = 0, removed = 0, unchanged = 0 }, 0
	for _, item in ipairs(current) do
		local before = old[item.content]
		local kind, moved = "added", false
		if before then
			retained = retained + 1
			moved = kept[retained] ~= item.content
			kind = (before.status ~= item.status or moved) and "updated" or "unchanged"
		end
		counts[kind] = counts[kind] + 1
		changes[#changes + 1] = {
			content = item.content,
			status = item.status,
			kind = kind,
			previous_status = before and before.status or nil,
			moved = moved,
		}
		old[item.content] = nil
	end
	for _, item in ipairs(previous) do
		if old[item.content] then
			counts.removed = counts.removed + 1
			changes[#changes + 1] = { content = item.content, status = item.status, kind = "removed" }
		end
	end
	return { counts = counts, items = changes }
end
return M
