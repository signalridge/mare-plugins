-- Byte, line, and token budget fitting for text and multimodal tool outputs.
local notice_format = require("spill.notice")

local M = {}

local utf8_prefix = notice_format.utf8_prefix
local utf8_suffix = notice_format.utf8_suffix

function M.count_lines(text)
	if text == "" then
		return 0
	end
	local _, count = text:gsub("\n", "")
	return count + 1
end

local count_lines = M.count_lines

local function find_token_prefix(s, max_tokens, max_bytes, measure_fn)
	if max_tokens <= 0 or max_bytes <= 0 or s == "" then
		return ""
	end
	local full = utf8_prefix(s, max_bytes)
	if full ~= "" then
		local fm = measure_fn(full)
		if fm and fm.tokens <= max_tokens then
			return full
		end
	end
	local best = ""
	local lo, hi = 0, math.min(#s, max_bytes)
	while lo < hi do
		local mid = math.floor((lo + hi + 1) / 2)
		local cand = utf8_prefix(s, mid)
		if cand == "" then
			lo = mid
		else
			local m = measure_fn(cand)
			if m and m.tokens <= max_tokens then
				best = cand
				lo = mid
			else
				hi = #cand - 1
			end
		end
	end
	return best
end

local function find_token_suffix(s, max_tokens, max_bytes, measure_fn)
	if max_tokens <= 0 or max_bytes <= 0 or s == "" then
		return ""
	end
	local full = utf8_suffix(s, max_bytes)
	if full ~= "" then
		local fm = measure_fn(full)
		if fm and fm.tokens <= max_tokens then
			return full
		end
	end
	local best = ""
	local lo, hi = 0, math.min(#s, max_bytes)
	while lo < hi do
		local mid = math.floor((lo + hi + 1) / 2)
		local cand = utf8_suffix(s, mid)
		if cand == "" then
			lo = mid
		else
			local m = measure_fn(cand)
			if m and m.tokens <= max_tokens then
				best = cand
				lo = mid
			else
				hi = #cand - 1
			end
		end
	end
	return best
end

function M.retain_text_tokens(text, notice, max_tokens, max_bytes, max_lines, measure_fn)
	local notice_m = assert(measure_fn(notice))
	if notice_m.tokens > max_tokens then
		error("output budget cannot fit recovery notice")
	end
	local avail_tokens = max_tokens - notice_m.tokens
	local avail_bytes = max_bytes - (#notice + 1)
	if avail_bytes < 0 or count_lines(notice) > max_lines then
		error("output budget cannot fit recovery notice")
	end
	local om_worst = notice_format.format_omission(#text, 0)
	local om_m = assert(measure_fn(om_worst))
	local content_tokens = math.max(0, avail_tokens - om_m.tokens)
	local content_bytes = math.max(0, avail_bytes - #om_worst - 2)
	local head_tokens = math.floor(content_tokens / 2)
	local tail_tokens = content_tokens - head_tokens
	local head_bytes = math.floor(content_bytes / 2)
	local tail_bytes = content_bytes - head_bytes
	local head = find_token_prefix(text, head_tokens, head_bytes, measure_fn)
	local remainder = text:sub(#head + 1)
	local tail = find_token_suffix(remainder, tail_tokens, tail_bytes, measure_fn)
	local function build(h, t)
		local ob = #text - #h - #t
		if ob == 0 then
			return text
		end
		local parts = {}
		if h ~= "" then
			parts[#parts + 1] = h
		end
		parts[#parts + 1] = notice_format.format_omission(ob, 0)
		if t ~= "" then
			parts[#parts + 1] = t
		end
		return table.concat(parts, "\n")
	end
	local body = build(head, tail)
	-- Trim if framing tokens pushed the combined body + notice over budget.
	while true do
		local combined = body == "" and notice or (body .. "\n" .. notice)
		local cm = measure_fn(combined)
		if cm and cm.tokens <= max_tokens and #combined <= max_bytes and count_lines(combined) <= max_lines then
			break
		end
		if #head == 0 and #tail == 0 then
			if body ~= "" then
				body = ""
			else
				error("output budget cannot fit recovery notice")
			end
		elseif #tail >= #head and #tail > 0 then
			tail = utf8_suffix(tail, math.floor(#tail / 2))
			body = build(head, tail)
		else
			head = utf8_prefix(head, math.floor(#head / 2))
			body = build(head, tail)
		end
	end
	return body
end

function M.retain_text_bytes_lines(text, notice, max_bytes, max_lines)
	if #notice > max_bytes or count_lines(notice) > max_lines then
		error("output budget cannot fit recovery notice")
	end
	local avail_bytes = max_bytes - (#notice + 1)
	local avail_lines = max_lines - count_lines(notice)
	if avail_bytes <= 0 or avail_lines <= 0 then
		return notice
	end
	local om_worst = notice_format.format_omission(#text, 0)
	local content_bytes = avail_bytes - #om_worst - 2
	if content_bytes <= 0 or avail_lines <= 1 then
		if #om_worst + 1 + #notice <= max_bytes and count_lines(om_worst) + count_lines(notice) <= max_lines then
			return om_worst .. "\n" .. notice
		end
		return notice
	end
	local head_bytes = math.ceil(content_bytes * 0.6)
	local tail_bytes = content_bytes - head_bytes
	local head = utf8_prefix(text, head_bytes)
	local tail = utf8_suffix(text:sub(#head + 1), tail_bytes)
	local function build(h, t)
		local ob = #text - #h - #t
		local parts = {}
		if h ~= "" then
			parts[#parts + 1] = h
		end
		if ob > 0 then
			parts[#parts + 1] = notice_format.format_omission(ob, 0)
		end
		if t ~= "" then
			parts[#parts + 1] = t
		end
		parts[#parts + 1] = notice
		return table.concat(parts, "\n")
	end
	local out = build(head, tail)
	while #out > max_bytes or count_lines(out) > max_lines do
		if #head == 0 and #tail == 0 then
			if #om_worst + 1 + #notice <= max_bytes and count_lines(om_worst) + count_lines(notice) <= max_lines then
				return om_worst .. "\n" .. notice
			end
			return notice
		end
		if #tail >= #head and #tail > 0 then
			local nl = tail:find("\n", 1, true)
			if count_lines(out) > max_lines and nl then
				tail = tail:sub(nl + 1)
			else
				tail = utf8_suffix(tail, math.floor(#tail / 2))
			end
		else
			local last_nl = head:match(".*()\n")
			if count_lines(out) > max_lines and last_nl and last_nl > 1 then
				head = head:sub(1, last_nl - 1)
			else
				head = utf8_prefix(head, math.floor(#head / 2))
			end
		end
		out = build(head, tail)
	end
	return out
end

function M.trim_text_body(text, notice, max_tokens, bytes, lines, measure_fn)
	if max_tokens ~= nil then
		return M.retain_text_tokens(text, notice, max_tokens, bytes, lines, measure_fn)
	end
	if _G.mare and _G.mare.text and _G.mare.text.retain then
		local preview = _G.mare.text.retain(text, { max_bytes = bytes, max_lines = lines, suffix = notice })
		-- The core owns the final notice reservation, so return the preview body without a duplicate notice.
		return preview:sub(1, -#notice - 1):gsub("\n$", "")
	end
	local plain = M.retain_text_bytes_lines(text, notice, bytes, lines)
	return plain:sub(1, -#notice - 1):gsub("\n$", "")
end

local function collect_head_blocks(blocks, head_tokens, head_bytes, measured, measure_fn)
	local head = {}
	local head_stop_idx = #blocks + 1
	local head_split_tail_text = nil
	local kept_bytes, kept_images = 0, 0
	local h_tok_left = head_tokens
	local h_byte_left = head_bytes
	for i = 1, #blocks do
		local b = blocks[i]
		local btok = measured and measured.blocks[i] and measured.blocks[i].tokens or 0
		if b.type == "image" then
			if not h_tok_left or btok <= h_tok_left then
				head[#head + 1] = b
				kept_images = kept_images + 1
				if h_tok_left then
					h_tok_left = h_tok_left - btok
				end
			else
				head_stop_idx = i
				break
			end
		elseif b.type == "text" then
			if (not h_tok_left or btok <= h_tok_left) and #b.text <= h_byte_left then
				head[#head + 1] = b
				kept_bytes = kept_bytes + #b.text
				if h_tok_left then
					h_tok_left = h_tok_left - btok
				end
				h_byte_left = h_byte_left - #b.text
			else
				local prefix
				if h_tok_left and measure_fn then
					prefix = find_token_prefix(b.text, h_tok_left, h_byte_left, measure_fn)
				else
					prefix = utf8_prefix(b.text, h_byte_left)
				end
				if prefix ~= "" then
					head[#head + 1] = { type = "text", text = prefix }
					kept_bytes = kept_bytes + #prefix
				end
				head_split_tail_text = b.text:sub(#prefix + 1)
				head_stop_idx = i
				break
			end
		end
	end
	return head, head_stop_idx, head_split_tail_text, kept_bytes, kept_images
end

local function collect_tail_blocks(
	blocks,
	head_stop_idx,
	head_split_tail_text,
	tail_tokens,
	tail_bytes,
	measured,
	measure_fn
)
	local t_tok_left = tail_tokens
	local t_byte_left = tail_bytes
	local tail_rev = {}
	local kept_bytes, kept_images = 0, 0
	for i = #blocks, head_stop_idx, -1 do
		local b = blocks[i]
		local text_override = (i == head_stop_idx and head_split_tail_text) or nil
		if b.type == "image" then
			local btok = measured and measured.blocks[i] and measured.blocks[i].tokens or 0
			if not t_tok_left or btok <= t_tok_left then
				tail_rev[#tail_rev + 1] = b
				kept_images = kept_images + 1
				if t_tok_left then
					t_tok_left = t_tok_left - btok
				end
			else
				break
			end
		elseif b.type == "text" then
			local txt = text_override or b.text
			local btok
			if t_tok_left and measure_fn then
				btok = text_override and assert(measure_fn(txt)).tokens
					or (measured and measured.blocks[i] and measured.blocks[i].tokens or 0)
			end
			if (not t_tok_left or btok <= t_tok_left) and #txt <= t_byte_left then
				if txt ~= "" then
					tail_rev[#tail_rev + 1] = { type = "text", text = txt }
					kept_bytes = kept_bytes + #txt
					if t_tok_left then
						t_tok_left = t_tok_left - btok
					end
					t_byte_left = t_byte_left - #txt
				end
			else
				local suffix
				if t_tok_left and measure_fn then
					suffix = find_token_suffix(txt, t_tok_left, t_byte_left, measure_fn)
				else
					suffix = utf8_suffix(txt, t_byte_left)
				end
				if suffix ~= "" then
					tail_rev[#tail_rev + 1] = { type = "text", text = suffix }
					kept_bytes = kept_bytes + #suffix
				end
				break
			end
		end
	end
	local tail = {}
	for i = #tail_rev, 1, -1 do
		tail[#tail + 1] = tail_rev[i]
	end
	return tail, kept_bytes, kept_images
end

local function assemble_multimodal_range(
	head,
	h_end,
	tail,
	t_start,
	total_bytes,
	total_images,
	kept_bytes,
	kept_images,
	notice
)
	local out = {}
	local text_run = {}
	local function flush_text()
		if #text_run > 0 then
			out[#out + 1] = { type = "text", text = #text_run == 1 and text_run[1] or table.concat(text_run, "\n") }
			text_run = {}
		end
	end
	local function push_block(b)
		if b.type == "text" then
			text_run[#text_run + 1] = b.text
		else
			flush_text()
			out[#out + 1] = b
		end
	end
	for i = 1, h_end do
		push_block(head[i])
	end
	local ob = math.max(0, total_bytes - kept_bytes)
	local oi = math.max(0, total_images - kept_images)
	if ob > 0 or oi > 0 then
		push_block({ type = "text", text = notice_format.format_omission(ob, oi) })
	end
	for i = t_start, #tail do
		push_block(tail[i])
	end
	flush_text()
	out[#out + 1] = { type = "text", text = notice }
	return out
end

local function blocks_fit_budget(blks, max_bytes, max_lines, max_tokens, measure_fn)
	local txt_bytes, txt_lines = 0, 0
	for _, b in ipairs(blks) do
		if b.type == "text" then
			txt_bytes = txt_bytes + #b.text
			txt_lines = txt_lines + count_lines(b.text)
		end
	end
	if txt_bytes > max_bytes or txt_lines > max_lines then
		return false
	end
	if max_tokens and measure_fn then
		local m, merr = measure_fn(blks)
		if not m then
			error("route measurement failed: " .. tostring(merr))
		end
		return m.tokens <= max_tokens
	end
	return true
end

local function text_stats(txt)
	local _, nl = txt:gsub("\n", "")
	return #txt, nl, txt:sub(-1) == "\n", txt == ""
end

local function build_head_metrics(head)
	local n = #head
	local fixed_bytes = { [0] = 0 }
	local fixed_lines = { [0] = 0 }
	local trail_count = { [0] = 0 }
	local trail_bytes = { [0] = 0 }
	local trail_nl = { [0] = 0 }
	local trail_ends_nl = { [0] = false }
	local trail_last_empty = { [0] = false }

	local fb, fl = 0, 0
	local tc, tb, tnl, tenl, tle = 0, 0, 0, false, false
	for i = 1, n do
		local b = head[i]
		if b.type == "text" then
			local len, nl, ends_nl, is_empty = text_stats(b.text)
			tc = tc + 1
			tb = tb + len
			tnl = tnl + nl
			tenl = ends_nl
			tle = is_empty
		else
			if tc > 0 then
				fb = fb + tb + (tc - 1)
				if not (tc == 1 and tle) then
					fl = fl + tnl + (tc - 1) + 1
				end
				tc, tb, tnl, tenl, tle = 0, 0, 0, false, false
			end
		end
		fixed_bytes[i] = fb
		fixed_lines[i] = fl
		trail_count[i] = tc
		trail_bytes[i] = tb
		trail_nl[i] = tnl
		trail_ends_nl[i] = tenl
		trail_last_empty[i] = tle
	end
	return {
		fixed_bytes = fixed_bytes,
		fixed_lines = fixed_lines,
		trail_count = trail_count,
		trail_bytes = trail_bytes,
		trail_nl = trail_nl,
		trail_ends_nl = trail_ends_nl,
		trail_last_empty = trail_last_empty,
	}
end

local function build_tail_metrics(tail)
	local n = #tail
	local fixed_bytes = { [n + 1] = 0 }
	local fixed_lines = { [n + 1] = 0 }
	local lead_count = { [n + 1] = 0 }
	local lead_bytes = { [n + 1] = 0 }
	local lead_nl = { [n + 1] = 0 }
	local lead_ends_nl = { [n + 1] = false }
	local lead_last_empty = { [n + 1] = false }

	local fb, fl = 0, 0
	local lc, lb, lnl, lenl, lle = 0, 0, 0, false, false
	for i = n, 1, -1 do
		local b = tail[i]
		if b.type == "text" then
			local len, nl, ends_nl, is_empty = text_stats(b.text)
			if lc == 0 then
				lenl = ends_nl
				lle = is_empty
			end
			lc = lc + 1
			lb = lb + len
			lnl = lnl + nl
		else
			if lc > 0 then
				fb = fb + lb + (lc - 1)
				if not (lc == 1 and lle) then
					fl = fl + lnl + (lc - 1) + 1
				end
				lc, lb, lnl, lenl, lle = 0, 0, 0, false, false
			end
		end
		fixed_bytes[i] = fb
		fixed_lines[i] = fl
		lead_count[i] = lc
		lead_bytes[i] = lb
		lead_nl[i] = lnl
		lead_ends_nl[i] = lenl
		lead_last_empty[i] = lle
	end
	return {
		fixed_bytes = fixed_bytes,
		fixed_lines = fixed_lines,
		lead_count = lead_count,
		lead_bytes = lead_bytes,
		lead_nl = lead_nl,
		lead_ends_nl = lead_ends_nl,
		lead_last_empty = lead_last_empty,
	}
end

local function range_fits_bytes_lines(
	hm,
	h_end,
	tm,
	t_start,
	total_bytes,
	total_images,
	kept_bytes,
	kept_images,
	notice_bytes,
	notice_lines,
	max_bytes,
	max_lines
)
	local ob = math.max(0, total_bytes - kept_bytes)
	local oi = math.max(0, total_images - kept_images)
	local om_bytes, om_nl = 0, 0
	local has_om = ob > 0 or oi > 0
	if has_om then
		local om_str = notice_format.format_omission(ob, oi)
		om_bytes = #om_str
		om_nl = select(2, om_str:gsub("\n", ""))
	end

	local h_tc = hm.trail_count[h_end]
	local t_lc = tm.lead_count[t_start]
	local mid_pieces = h_tc + (has_om and 1 or 0) + t_lc
	local mid_bytes, mid_lines = 0, 0
	if mid_pieces > 0 then
		mid_bytes = hm.trail_bytes[h_end] + om_bytes + tm.lead_bytes[t_start] + (mid_pieces - 1)
		local last_ends_nl, last_empty
		if t_lc > 0 then
			last_ends_nl = tm.lead_ends_nl[t_start]
			last_empty = tm.lead_last_empty[t_start]
		elseif has_om then
			last_ends_nl = false
			last_empty = false
		else
			last_ends_nl = hm.trail_ends_nl[h_end]
			last_empty = hm.trail_last_empty[h_end]
		end
		if not (mid_pieces == 1 and last_empty) then
			local mid_nl = hm.trail_nl[h_end] + om_nl + tm.lead_nl[t_start] + (mid_pieces - 1)
			mid_lines = mid_nl + 1
		end
	end

	local total_txt_bytes = hm.fixed_bytes[h_end] + tm.fixed_bytes[t_start] + mid_bytes + notice_bytes
	local total_txt_lines = hm.fixed_lines[h_end] + tm.fixed_lines[t_start] + mid_lines + notice_lines
	return total_txt_bytes <= max_bytes and total_txt_lines <= max_lines
end

function M.retain_multimodal(blocks, notice, max_tokens, max_bytes, max_lines, measured, measure_fn)
	local notice_m = max_tokens and assert(measure_fn(notice)) or nil
	if notice_m and notice_m.tokens > max_tokens then
		error("output budget cannot fit recovery notice")
	end
	local notice_bytes = #notice
	local notice_lines = count_lines(notice)
	if notice_bytes > max_bytes or notice_lines > max_lines then
		error("output budget cannot fit recovery notice")
	end
	local total_bytes, total_images = 0, 0
	for _, b in ipairs(blocks) do
		if b.type == "text" then
			total_bytes = total_bytes + #b.text
		elseif b.type == "image" then
			total_images = total_images + 1
		end
	end
	local om_worst = notice_format.format_omission(total_bytes, total_images)
	local om_tokens = max_tokens and assert(measure_fn(om_worst)).tokens or 0
	local avail_tokens = max_tokens and math.max(0, max_tokens - notice_m.tokens - om_tokens) or nil
	local avail_bytes = math.max(0, max_bytes - (notice_bytes + 1) - #om_worst - 2)
	local head_tokens = avail_tokens and math.floor(avail_tokens / 2) or nil
	local tail_tokens = avail_tokens and (avail_tokens - head_tokens) or nil
	local head_bytes = math.floor(avail_bytes / 2)
	local tail_bytes = avail_bytes - head_bytes

	local head, head_stop_idx, head_split_tail_text, head_kb, head_ki =
		collect_head_blocks(blocks, head_tokens, head_bytes, measured, measure_fn)
	local tail, tail_kb, tail_ki =
		collect_tail_blocks(blocks, head_stop_idx, head_split_tail_text, tail_tokens, tail_bytes, measured, measure_fn)
	local kept_bytes = head_kb + tail_kb
	local kept_images = head_ki + tail_ki

	local only_notice = { { type = "text", text = notice } }
	if not blocks_fit_budget(only_notice, max_bytes, max_lines, max_tokens, measure_fn) then
		error("output budget cannot fit recovery notice")
	end

	local hm = build_head_metrics(head)
	local tm = build_tail_metrics(tail)
	local h_end, t_start, tail_len = #head, 1, #tail

	while true do
		if
			range_fits_bytes_lines(
				hm,
				h_end,
				tm,
				t_start,
				total_bytes,
				total_images,
				kept_bytes,
				kept_images,
				notice_bytes,
				notice_lines,
				max_bytes,
				max_lines
			)
		then
			local out_blocks = assemble_multimodal_range(
				head,
				h_end,
				tail,
				t_start,
				total_bytes,
				total_images,
				kept_bytes,
				kept_images,
				notice
			)
			if not max_tokens or not measure_fn then
				return out_blocks
			end
			local m, merr = measure_fn(out_blocks)
			if not m then
				error("route measurement failed: " .. tostring(merr))
			end
			if m.tokens <= max_tokens then
				return out_blocks
			end
		end
		local h_len = h_end
		local t_len = tail_len - t_start + 1
		if h_len == 0 and t_len == 0 then
			return only_notice
		end
		local drop_tail = t_len >= h_len and t_len > 0
		local removed
		if drop_tail then
			removed = tail[t_start]
			t_start = t_start + 1
		else
			removed = head[h_end]
			h_end = h_end - 1
		end
		if removed.type == "text" then
			kept_bytes = kept_bytes - #removed.text
		elseif removed.type == "image" then
			kept_images = kept_images - 1
		end
	end
end

function M.inspect_content(content)
	if type(content) == "string" then
		return false, { content }, #content, count_lines(content), 0
	end
	local has_image = false
	local text_parts = {}
	local total_text_bytes, total_text_lines, total_images = 0, 0, 0
	for _, block in ipairs(content) do
		if type(block) ~= "table" then
			return nil
		end
		if block.type == "text" and type(block.text) == "string" then
			text_parts[#text_parts + 1] = block.text
			total_text_bytes = total_text_bytes + #block.text
			total_text_lines = total_text_lines + count_lines(block.text)
		elseif block.type == "image" then
			has_image = true
			total_images = total_images + 1
		else
			return nil
		end
	end
	return has_image, text_parts, total_text_bytes, total_text_lines, total_images
end

local function estimate_text_tokens(text)
	if mare and mare.text and type(mare.text.tokens) == "function" then
		return mare.text.tokens(text)
	end
	return math.ceil(#text / 4)
end

local function estimate_image_tokens()
	if mare and mare.text and type(mare.text.image_tokens) == "number" then
		return mare.text.image_tokens
	end
	return 1200
end

local function fallback_measure(c)
	if type(c) ~= "table" then
		local s = type(c) == "string" and c or tostring(c or "")
		local t = estimate_text_tokens(s)
		return {
			tokens = t,
			estimated = true,
			method = "fallback-tokens",
			blocks = { { index = 1, kind = "text", tokens = t } },
		}
	end
	local total = 0
	local blocks_m = {}
	for i, b in ipairs(c) do
		local kind = type(b) == "table" and b.type or "text"
		local t
		if kind == "image" then
			t = estimate_image_tokens()
		else
			local s = type(b) == "table" and type(b.text) == "string" and b.text or ""
			t = estimate_text_tokens(s)
		end
		total = total + t
		blocks_m[i] = { index = i, kind = kind, tokens = t }
	end
	return {
		tokens = total,
		estimated = true,
		method = "fallback-tokens",
		blocks = blocks_m,
	}
end

function M.build_measure_fn(llm, route_target, on_fallback)
	local has_measure = llm and require("mare_lib").callable(llm.measure)
	local use_fallback = not route_target or not has_measure
	if use_fallback and on_fallback then
		if not has_measure then
			on_fallback("llm.measure unavailable")
		elseif not route_target then
			on_fallback("route measurement unavailable: missing route")
		end
	end

	local function call_llm_measure(arg)
		local ok, m, err = pcall(llm.measure, llm, route_target, arg)
		if not ok then
			return nil, m
		end
		if type(m) ~= "table" or type(m.tokens) ~= "number" then
			return nil, err or "invalid measurement result"
		end
		return m
	end

	local function switch_to_fallback(c, err)
		use_fallback = true
		if on_fallback then
			on_fallback("route measurement failed: " .. tostring(err))
		end
		return fallback_measure(c)
	end

	return function(c)
		if use_fallback then
			return fallback_measure(c)
		end
		if type(c) ~= "table" then
			local m, err = call_llm_measure(c)
			if not m then
				return switch_to_fallback(c, err)
			end
			return m
		end
		for _, b in ipairs(c) do
			if type(b) == "table" and b.type == "image" then
				local m, err = call_llm_measure(c)
				if not m then
					return switch_to_fallback(c, err)
				end
				return m
			end
		end
		if #c == 1 and type(c[1]) == "table" and c[1].type == "text" then
			local m, err = call_llm_measure(c[1].text)
			if not m then
				return switch_to_fallback(c, err)
			end
			return m
		end
		local total, blocks_m = 0, {}
		for i, b in ipairs(c) do
			local bm, err = call_llm_measure(type(b) == "table" and b.text or "")
			if not bm then
				return switch_to_fallback(c, err)
			end
			total = total + bm.tokens
			blocks_m[i] = bm.blocks and bm.blocks[1] or { index = i, kind = "text", tokens = bm.tokens }
		end
		return { tokens = total, blocks = blocks_m }
	end
end

return M
