-- Recovery is committed before reducing the result returned by the retention waterfall.
local budget_mod = require("spill.budget")
local media = require("spill.media")
local notice_format = require("spill.notice")

local count_lines = budget_mod.count_lines

local FAILURE_CANDIDATES = {
	"[spill: output exceeds inline token budget]",
	"[output exceeds budget]",
	"[budget exceeded]",
	"[over budget]",
	"[truncated]",
	"...",
	"",
}

local function copy_table(src)
	local out = {}
	for key, item in pairs(src) do
		out[key] = item
	end
	return out
end

local function non_empty_string(value)
	return type(value) == "string" and value ~= "" and value or nil
end

local function normalize_suggested_base(raw)
	local base = non_empty_string(raw) or "output"
	base = base:gsub("%.txt$", ""):gsub("%.bin$", "")
	if #base > 40 then
		base = notice_format.utf8_prefix(base, 40)
	end
	return base ~= "" and base or "output"
end

local function build_save_opts(result, budget, call)
	local tool_name = non_empty_string(call and call.name) or non_empty_string(budget and budget.tool_name)
	local call_id = non_empty_string(call and call.id)
		or non_empty_string(budget and budget.tool_call_id)
		or non_empty_string(budget and budget.execution_id)
	local details_tbl = type(result.details) == "table" and result.details or nil
	local label = non_empty_string(result.label) or non_empty_string(details_tbl and details_tbl.label) or tool_name
	local raw_source = type(result.spill_source) == "table" and result.spill_source
		or (details_tbl and type(details_tbl.spill_source) == "table" and details_tbl.spill_source or nil)
	local source = nil
	if raw_source and non_empty_string(raw_source.kind) then
		local kind = raw_source.kind == "session_reference" and "session-reference" or raw_source.kind
		if kind == "session-reference" then
			local sid = non_empty_string(raw_source.session_id) or non_empty_string(budget and budget.session_id)
			local s_label = non_empty_string(raw_source.label) or label or "session-reference"
			if sid then
				source = {
					kind = "session-reference",
					session_id = sid,
					label = s_label,
				}
			end
		elseif kind == "tool" then
			local src_tool = non_empty_string(raw_source.tool_name) or tool_name
			local src_call = non_empty_string(raw_source.tool_call_id) or call_id
			local src_label = non_empty_string(raw_source.label) or label
			if src_tool and src_call then
				source = {
					kind = "tool",
					tool_name = src_tool,
					tool_call_id = src_call,
					label = src_label,
				}
			elseif non_empty_string(budget and budget.session_id) then
				source = {
					kind = "session-reference",
					session_id = budget.session_id,
					label = src_label or src_tool or "tool-output",
				}
			end
		end
	elseif tool_name and call_id then
		source = {
			kind = "tool",
			tool_name = tool_name,
			tool_call_id = call_id,
			label = label,
		}
	elseif non_empty_string(budget and budget.session_id) and (tool_name or label) then
		source = {
			kind = "session-reference",
			session_id = budget.session_id,
			label = label or tool_name,
		}
	end
	local raw_suggested = non_empty_string(result.suggested_name)
		or non_empty_string(details_tbl and details_tbl.suggested_name)
		or tool_name
		or (source and source.kind)
		or "output"
	local suggested_base = normalize_suggested_base(raw_suggested)
	return {
		suggested_name = suggested_base .. ".txt",
		source = source,
	}, suggested_base
end

local function copy_details(result)
	if type(result.details) == "table" then
		return copy_table(result.details)
	end
	return {}
end

return function(result, budget, cfg, storage, llm, call)
	storage = storage or mare.spill
	if result.spill_exempt or (type(result.details) == "table" and result.details.spill_exempt) then
		return result
	end
	local content = result.content
	if type(content) ~= "string" and type(content) ~= "table" then
		return result
	end
	if not budget or not budget.session_id then
		return result
	end

	-- Replayed text/blocks have lost in-memory flags. Recover persisted suffix before budgeting.
	local replay_body, replay_blocks, persisted
	if type(content) == "string" then
		replay_body, persisted = notice_format.split(content)
	elseif type(content) == "table" then
		replay_blocks, persisted = notice_format.split_blocks(content)
	end

	local has_image, text_parts, total_text_bytes, total_text_lines, total_images = budget_mod.inspect_content(content)
	if has_image == nil then
		if persisted then
			local value = copy_table(result)
			value.content = replay_blocks or replay_body
			value.output_notice, value.truncated = persisted, true
			return value
		end
		return result
	end

	local bytes = math.min(cfg.max_bytes, budget.max_bytes or cfg.max_bytes)
	local lines = math.min(cfg.max_lines, budget.max_lines or cfg.max_lines)
	local max_tokens = cfg.max_inline_tokens
	local measured, measure_fn, measure_warn

	if max_tokens ~= nil then
		local route_target = budget.route_snapshot or budget.route
		measure_fn = budget_mod.build_measure_fn(llm, route_target, function(reason)
			measure_warn = measure_warn or ("spill: " .. reason .. "; using fallback token estimate")
		end)
		local merr
		measured, merr = measure_fn(content)
		if not measured then
			error("route measurement failed: " .. tostring(merr))
		end
	end

	local within_budget = total_text_bytes <= bytes
		and total_text_lines <= lines
		and (max_tokens == nil or measured.tokens <= max_tokens)

	local saved_handles = {}
	local function cleanup_saved()
		for _, h in ipairs(saved_handles) do
			pcall(storage.delete, h, { session_id = budget.session_id })
		end
		saved_handles = {}
	end

	local function notice_fits(cand)
		if #cand > bytes or count_lines(cand) > lines then
			return false
		end
		if max_tokens ~= nil then
			local ok_m, m = pcall(measure_fn, cand)
			if not ok_m or not m or m.tokens > max_tokens then
				return false
			end
		end
		return true
	end

	local function explicit_budget_failure(err_msg)
		local err_str = tostring(err_msg)
		local failure_text
		for _, cand in ipairs(FAILURE_CANDIDATES) do
			if notice_fits(cand) then
				failure_text = cand
				break
			end
		end
		if failure_text == nil then
			error("output budget cannot fit any failure notice: " .. err_str)
		end
		local value = copy_table(result)
		value.output_notice = nil
		value.truncated = true
		value.is_error = true
		value.error_code = "output_budget_exceeded"
		local details = copy_details(result)
		details.spill_error = err_str
		value.details = details
		value.content = (type(content) == "table") and { { type = "text", text = failure_text } } or failure_text
		if type(value.content) == "table" then
			value.no_truncate = true
		end
		return value, "spill: budget cannot fit recovery notice; returned explicit failure: " .. err_str
	end

	if persisted then
		local value = copy_table(result)
		value.output_notice, value.truncated = persisted, true
		if replay_body ~= nil then
			if within_budget then
				value.content = replay_body
				return value, measure_warn
			end
			local ok_r, re_body =
				pcall(budget_mod.trim_text_body, replay_body, persisted, max_tokens, bytes, lines, measure_fn)
			if not ok_r then
				return explicit_budget_failure(re_body)
			end
			value.content = re_body
			return value, measure_warn
		end
		-- Keep persisted notice block in multimodal content since downstream pipeline only appends string notices.
		value.no_truncate = true
		if within_budget then
			local copied = {}
			for i, b in ipairs(content) do
				copied[i] = b
			end
			value.content = copied
			return value, measure_warn
		end
		local body_measured = nil
		if max_tokens ~= nil then
			if #replay_blocks == 0 then
				body_measured = { tokens = 0, blocks = {} }
			else
				local bmerr
				body_measured, bmerr = measure_fn(replay_blocks)
				if not body_measured then
					error("route measurement failed: " .. tostring(bmerr))
				end
			end
		end
		local ok_mm, re_mm = pcall(
			budget_mod.retain_multimodal,
			replay_blocks,
			persisted,
			max_tokens,
			bytes,
			lines,
			body_measured,
			measure_fn
		)
		if not ok_mm then
			return explicit_budget_failure(re_mm)
		end
		value.content = re_mm
		return value, measure_warn
	end

	if within_budget then
		return result, measure_warn
	end

	local function in_memory_fallback(err_msg)
		cleanup_saved()
		local err_str = tostring(err_msg)
		local cand1 = notice_format.format_storage_error(total_text_bytes, total_images, err_str)
		local cand2 = "[... output truncated; full output could not be saved ...]"
		local err_notice = notice_fits(cand1) and cand1 or (notice_fits(cand2) and cand2 or nil)
		if not err_notice then
			return explicit_budget_failure(err_str)
		end

		local value = copy_table(result)
		value.output_notice = nil
		value.truncated = true
		local details = copy_details(result)
		details.spill_error = err_str
		value.details = details
		local warn = "spill: storage failed; returned in-memory truncated output: " .. err_str

		if has_image then
			local ok_mm, retained =
				pcall(budget_mod.retain_multimodal, content, err_notice, max_tokens, bytes, lines, measured, measure_fn)
			value.content = ok_mm and retained or { { type = "text", text = err_notice } }
			value.no_truncate = true
			return value, warn
		end

		local raw_text = table.concat(text_parts)
		local ok_body, body =
			pcall(budget_mod.trim_text_body, raw_text, err_notice, max_tokens, bytes, lines, measure_fn)
		if ok_body then
			value.content = body == "" and err_notice or (body .. "\n" .. err_notice)
		else
			value.content = err_notice
		end
		return value, warn
	end

	local save_opts, suggested_base = build_save_opts(result, budget, call)
	local full_text
	local image_refs = {}
	if not has_image then
		full_text = table.concat(text_parts)
	else
		local built, refs_or_err =
			media.build_transcript(content, budget.session_id, storage, save_opts, suggested_base, saved_handles)
		if not built then
			return in_memory_fallback(refs_or_err)
		end
		full_text, image_refs = built, refs_or_err
	end

	local ok_save, saved = pcall(storage.save, budget.session_id, full_text, save_opts)
	if not ok_save then
		return in_memory_fallback(saved)
	end
	saved_handles[#saved_handles + 1] = saved.spill_id
	local notice = notice_format.format(saved)

	local function build_success_result(retained_content, used_notice)
		local value = copy_table(result)
		value.content = retained_content
		value.output_notice = used_notice
		value.truncated = true
		if has_image or type(retained_content) == "table" then
			value.no_truncate = true
		end
		local details = copy_details(result)
		details.spill = {
			handle = saved.spill_id,
			size = saved.size,
			backend = saved.backend,
			path = saved.path,
			retrieval_hint = saved.retrieval_hint,
			suggested_name = save_opts.suggested_name,
			source = saved.source or save_opts.source,
			images = #image_refs > 0 and image_refs or nil,
		}
		value.details = details
		return value
	end

	local function retain_with_notice(active_notice)
		if has_image then
			return pcall(
				budget_mod.retain_multimodal,
				content,
				active_notice,
				max_tokens,
				bytes,
				lines,
				measured,
				measure_fn
			)
		end
		return pcall(budget_mod.trim_text_body, full_text, active_notice, max_tokens, bytes, lines, measure_fn)
	end

	local ok_ret, retained = retain_with_notice(notice)
	if ok_ret then
		return build_success_result(retained, notice), measure_warn
	end

	-- Retry with compact handle-only notice when a long retrieval hint overflows budget.
	local compact_notice = notice_format.format_compact(saved)
	if compact_notice ~= notice and notice_fits(compact_notice) then
		local ok_compact, compact_retained = retain_with_notice(compact_notice)
		if ok_compact then
			return build_success_result(compact_retained, compact_notice), measure_warn
		end
	end

	if max_tokens ~= nil and tostring(retained):find("output budget cannot fit recovery notice", 1, true) then
		cleanup_saved()
		return explicit_budget_failure(retained)
	end
	return in_memory_fallback(retained)
end
