local function contains_text(blocks, needle)
	for _, block in ipairs(blocks) do
		if type(block) == "table" and block.type == "text" and type(block.text) == "string" then
			if block.text:find(needle, 1, true) then
				return true
			end
		end
	end
	return false
end

local CONTENT_TRUNCATION_SUFFIX = "\n[script output truncated to this call's budget]"
local ERROR_TRUNCATION_SUFFIX = "\n[error truncated to this call's budget]"

local function cut_bytes(text, limit)
	if limit <= 0 or text == "" then
		return ""
	end
	if mare and mare.text and type(mare.text.cut) == "function" then
		return mare.text.cut(text, limit, { unit = "bytes" })
	end
	if #text <= limit then
		return text
	end
	return text:sub(1, limit)
end

local function bound_error(err, error_cap)
	if error_cap <= 0 then
		return ""
	end
	if #err <= error_cap then
		return err
	end
	if error_cap <= #ERROR_TRUNCATION_SUFFIX then
		if error_cap >= 8 then
			local prefix = cut_bytes(err, error_cap - 3)
			if prefix ~= "" then
				return prefix .. "..."
			end
		end
		return cut_bytes(err, error_cap)
	end
	return cut_bytes(err, error_cap - #ERROR_TRUNCATION_SUFFIX) .. ERROR_TRUNCATION_SUFFIX
end

local function truncate_content(blocks, budget)
	local kept = {}
	local remaining = budget
	local truncated = false
	for _, block in ipairs(blocks) do
		if type(block) == "table" and block.type == "text" and type(block.text) == "string" then
			if not truncated then
				if #block.text <= remaining then
					kept[#kept + 1] = block
					remaining = remaining - #block.text
				elseif remaining > #CONTENT_TRUNCATION_SUFFIX then
					kept[#kept + 1] = {
						type = "text",
						text = cut_bytes(block.text, remaining - #CONTENT_TRUNCATION_SUFFIX)
							.. CONTENT_TRUNCATION_SUFFIX,
					}
					remaining = 0
					truncated = true
				else
					kept[#kept + 1] = {
						type = "text",
						text = remaining > 0 and cut_bytes(block.text, remaining) or "",
					}
					remaining = 0
					truncated = true
				end
			end
		else
			kept[#kept + 1] = block
		end
	end
	return kept
end

return function(cell, max_output_tokens)
	local label = cell.status == "running" and ("Script running with cell ID " .. tostring(cell.cell_id or ""))
		or cell.status == "completed" and "Script completed"
		or cell.status == "cancelled" and "Script terminated"
		or "Script failed"
	local max_bytes = type(max_output_tokens) == "number" and math.max(0, math.floor(max_output_tokens * 4)) or 40000
	local has_error = type(cell.error) == "string" and cell.error ~= ""
	local stop_unconfirmed = cell.stop_unconfirmed == true
	local unconfirmed_msg = stop_unconfirmed and (has_error and cell.error or "Script stop is unconfirmed") or nil

	-- When an error is present under a tiny budget, never let the generic status label starve the error.
	if has_error and max_bytes < #label + math.min(#cell.error, 8) then
		label = ""
	elseif #label > max_bytes then
		label = cut_bytes(label, max_bytes)
	end
	local remaining = math.max(0, max_bytes - #label)

	-- Reserve the error budget first so bounded errors are never dropped or pushed past total budget.
	local bounded_err = nil
	if stop_unconfirmed then
		bounded_err = unconfirmed_msg
		remaining = math.max(0, remaining - #bounded_err)
	elseif has_error then
		local error_cap = math.min(512, math.max(64, math.floor(max_bytes / 2)))
		if error_cap > remaining then
			error_cap = remaining
		end
		bounded_err = bound_error(cell.error, error_cap)
		remaining = math.max(0, remaining - #bounded_err)
	end

	local kept_blocks = truncate_content(cell.content or {}, remaining)
	local content = {}
	if label ~= "" then
		content[#content + 1] = { type = "text", text = label }
	end
	for _, block in ipairs(kept_blocks) do
		content[#content + 1] = block
	end
	if
		bounded_err
		and bounded_err ~= ""
		and not contains_text(kept_blocks, cell.error)
		and not contains_text(kept_blocks, bounded_err)
	then
		content[#content + 1] = { type = "text", text = bounded_err }
	end
	local is_error = cell.is_error
	if is_error == nil then
		is_error = cell.status == "failed" or cell.status == "cancelled" or has_error
	end
	return { content = content, is_error = is_error, details = cell }
end
