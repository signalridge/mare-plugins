-- The persisted convention identifies a recovery notice, not authenticated origin.
local M = {}

function M.utf8_prefix(s, max_bytes)
	if type(s) ~= "string" or max_bytes <= 0 or s == "" then
		return ""
	end
	return mare.text.cut(s, max_bytes)
end

function M.utf8_suffix(s, max_bytes)
	if type(s) ~= "string" or max_bytes <= 0 or s == "" then
		return ""
	end
	return mare.text.cut(s, max_bytes, { keep = "tail" })
end

local function sanitize_line(text)
	return (tostring(text):gsub("[\r\n\t]+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.format_compact(saved)
	return ("[Complete tool output (%d bytes): %s. Use read_spill with offset/limit.]"):format(
		saved.size,
		saved.spill_id
	)
end

function M.format(saved)
	local hint = type(saved.retrieval_hint) == "string" and sanitize_line(saved.retrieval_hint) or ""
	if hint == "" then
		if type(saved.path) == "string" and saved.path ~= "" then
			hint = ("Use read_spill with offset/limit, or read (offset/limit) / grep at %s."):format(
				sanitize_line(saved.path)
			)
		else
			hint = "Use read_spill with offset/limit."
		end
	end
	return ("[Complete tool output (%d bytes): %s. %s]"):format(saved.size, saved.spill_id, hint)
end

function M.format_storage_error(omitted_bytes, omitted_images, err)
	local clean_err = sanitize_line(err or "storage error")
	if #clean_err > 120 then
		clean_err = M.utf8_prefix(clean_err, 117) .. "..."
	end
	local omitted = {}
	if (omitted_bytes or 0) > 0 then
		omitted[#omitted + 1] = ("%d bytes"):format(omitted_bytes)
	end
	if (omitted_images or 0) > 0 then
		omitted[#omitted + 1] = ("%d images"):format(omitted_images)
	end
	local what = #omitted > 0 and ("omitted " .. table.concat(omitted, ", ")) or "output truncated"
	return ("[... %s; full output could not be saved (%s) ...]"):format(what, clean_err)
end

function M.format_omission(omitted_bytes, omitted_images)
	if (omitted_images or 0) > 0 and (omitted_bytes or 0) > 0 then
		return ("[... omitted %d bytes, %d images ...]"):format(omitted_bytes, omitted_images)
	elseif (omitted_images or 0) > 0 then
		return ("[... omitted %d images ...]"):format(omitted_images)
	end
	return ("[... omitted %d bytes ...]"):format(omitted_bytes or 0)
end

function M.split(text)
	if type(text) ~= "string" or text:sub(-1) ~= "]" then
		return nil
	end
	local prefix = "[Complete tool output ("
	local start
	local pos = 1
	while true do
		local found = text:find(prefix, pos, true)
		if not found then
			break
		end
		if found == 1 or text:sub(found - 1, found - 1) == "\n" then
			start = found
		end
		pos = found + 1
	end
	if not start then
		return nil
	end
	local candidate = text:sub(start)
	if candidate:find("\n", 1, true) then
		return nil
	end
	local size, locator, hint = candidate:match("^%[Complete tool output %((%d+) bytes%): (%S+)%. (.+)%]$")
	if not size or not locator or not hint or hint == "" or #locator > 65536 then
		return nil
	end
	local count = tonumber(size)
	if not count or count > 9007199254740991 or tostring(count):find("e") then
		return nil
	end
	return text:sub(1, start - 1):gsub("\n$", ""), candidate
end

function M.split_blocks(blocks)
	if type(blocks) ~= "table" or #blocks == 0 then
		return nil
	end
	local last = blocks[#blocks]
	if type(last) ~= "table" or last.type ~= "text" or type(last.text) ~= "string" then
		return nil
	end
	local body, persisted = M.split(last.text)
	if not persisted then
		return nil
	end
	local copy = {}
	for i = 1, #blocks - 1 do
		copy[i] = blocks[i]
	end
	if body ~= "" then
		copy[#copy + 1] = { type = "text", text = body }
	end
	return copy, persisted
end

return M
