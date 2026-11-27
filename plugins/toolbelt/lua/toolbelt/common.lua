local M = {}

local function norm_sep(p)
	return (p:gsub("\\", "/"))
end

local function trim_trailing_slashes(p)
	if p:match("^/+$") then
		return "/"
	end
	if p:match("^[A-Za-z]:[/\\]+$") then
		return p:sub(1, 3)
	end
	return (p:gsub("[/\\]+$", ""))
end

local function is_absolute(p)
	return p:sub(1, 1) == "/" or p:match("^[A-Za-z]:[/\\]") ~= nil
end

local function parent_dir(p)
	local clean = trim_trailing_slashes(p)
	local dir, sep = clean:match("^(.*)([/\\])[^/\\]+$")
	if dir == "" and sep == "/" then
		return "/"
	end
	if dir and dir:match("^[A-Za-z]:$") then
		return dir .. sep
	end
	return dir
end

function M.trim(s)
	return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.first_lines(s, max_lines)
	local out = {}
	for line in (tostring(s or "") .. "\n"):gmatch("([^\r\n]*)\r?\n") do
		local trimmed = M.trim(line)
		if trimmed ~= "" then
			out[#out + 1] = trimmed
			if #out >= (max_lines or 4) then
				break
			end
		end
	end
	return table.concat(out, "\n")
end

function M.validate_text_arg(value, field, required)
	if value == nil then
		if required then
			return nil, field .. " is required"
		end
		return nil
	end
	if type(value) ~= "string" then
		return nil, field .. " must be a string"
	end
	if value:find("\0", 1, true) then
		return nil, field .. " contains a NUL byte"
	end
	if required and value == "" then
		return nil, field .. " must not be empty"
	end
	return value
end

function M.validate_nonneg_int(value, field)
	if value == nil then
		return nil
	end
	if type(value) ~= "number" or value % 1 ~= 0 or value < 0 then
		return nil, field .. " must be a non-negative integer"
	end
	return value
end

function M.resolve_root(raw_path, base_cwd)
	local candidate
	if raw_path == nil or raw_path == "" or raw_path == "." then
		candidate = base_cwd or mare.cwd
	else
		if type(raw_path) ~= "string" then
			error("toolbelt: path must be a string", 0)
		end
		if raw_path:find("\0", 1, true) then
			error("toolbelt: path contains a NUL byte", 0)
		end
		if not is_absolute(raw_path) and type(base_cwd) == "string" and base_cwd ~= "" and base_cwd ~= mare.cwd then
			candidate = trim_trailing_slashes(base_cwd) .. "/" .. raw_path
		else
			candidate = raw_path
		end
	end
	if type(candidate) ~= "string" or candidate == "" then
		error("toolbelt: search root could not be resolved", 0)
	end
	if type(mare.fs) == "table" and type(mare.fs.resolve) == "function" then
		local ok, resolved = pcall(mare.fs.resolve, candidate)
		if not ok or type(resolved) ~= "string" or resolved == "" then
			error("toolbelt: search root could not be resolved: " .. tostring(resolved), 0)
		end
		return trim_trailing_slashes(resolved)
	end
	if is_absolute(candidate) then
		return trim_trailing_slashes(candidate)
	end
	error("toolbelt: mare.fs.resolve is unavailable for relative path", 0)
end

local function resolve_base_cwd(ctx)
	if ctx and type(ctx.cwd) == "string" and ctx.cwd ~= "" then
		return ctx.cwd
	end
	return mare.cwd
end

function M.access_fn()
	return function(args, ctx)
		local root = M.resolve_root(args and args.path, resolve_base_cwd(ctx))
		return {
			{
				kind = "file",
				op = "read",
				path = root,
				recursive = true,
			},
		}
	end
end

local function path_error_result(err)
	local msg = tostring(err)
	if msg:lower():find("sandbox:", 1, true) then
		return { content = msg, is_error = true, error_code = "sandbox_denied" }
	end
	return { content = "Invalid path: " .. msg, is_error = true }
end

function M.search_target(raw_path, tctx)
	local base_cwd = resolve_base_cwd(tctx)
	local ok, root = pcall(M.resolve_root, raw_path, base_cwd)
	if not ok then
		return nil, path_error_result(root)
	end

	local run_cwd = base_cwd or root
	local base_dir = root
	local st
	if type(mare.fs) == "table" and type(mare.fs.stat) == "function" then
		local ok_stat, stat_res = pcall(mare.fs.stat, root)
		if not ok_stat then
			return nil, path_error_result(stat_res)
		end
		st = stat_res
	end

	if st then
		if st.kind == "dir" then
			run_cwd = root
			base_dir = root
		else
			local parent = parent_dir(root)
			run_cwd = parent or base_cwd or "/"
			base_dir = parent or base_cwd or "/"
		end
	else
		run_cwd = (type(base_cwd) == "string" and base_cwd ~= "") and trim_trailing_slashes(base_cwd) or root
		base_dir = root
	end

	local real_base_dir
	if type(mare.fs) == "table" and type(mare.fs.realpath) == "function" then
		local ok_real, real = pcall(mare.fs.realpath, base_dir)
		if ok_real and type(real) == "string" and real ~= "" then
			real = trim_trailing_slashes(real)
			if real ~= base_dir then
				real_base_dir = real
			end
		end
	end

	return {
		root = root,
		target = root,
		run_cwd = run_cwd,
		base_dir = base_dir,
		real_base_dir = real_base_dir,
	}
end

function M.rel_path(path, target)
	if type(path) ~= "string" then
		return ""
	end
	local clean = path
	local clean_norm = norm_sep(clean)
	if clean_norm:sub(1, 2) == "./" then
		clean = clean:sub(3)
		clean_norm = clean_norm:sub(3)
	end
	local case_insensitive = mare and mare.os == "windows"
	local clean_cmp = case_insensitive and clean_norm:lower() or clean_norm
	for _, base in ipairs({ target.base_dir, target.real_base_dir }) do
		if type(base) == "string" and base ~= "" then
			local base_norm = trim_trailing_slashes(norm_sep(base))
			local base_cmp = case_insensitive and base_norm:lower() or base_norm
			if clean_cmp == base_cmp then
				return "."
			end
			local prefix_norm = (base_norm == "/" or base_norm:match("^[A-Za-z]:/$")) and base_norm
				or (base_norm .. "/")
			local prefix_cmp = case_insensitive and prefix_norm:lower() or prefix_norm
			if clean_cmp:sub(1, #prefix_cmp) == prefix_cmp then
				return clean_norm:sub(#prefix_norm + 1)
			end
		end
	end
	return clean
end

function M.split_nul(raw)
	local out = {}
	if type(raw) ~= "string" or raw == "" then
		return out
	end
	for item in raw:gmatch("([^\0]+)") do
		if item ~= "" then
			out[#out + 1] = item
		end
	end
	return out
end

function M.sort_by_mtime_desc(paths)
	local items = {}
	local has_stat = type(mare.fs) == "table" and type(mare.fs.stat) == "function"
	for _, p in ipairs(paths) do
		local mtime = 0
		if has_stat then
			local ok, st = pcall(mare.fs.stat, p)
			if ok and type(st) == "table" and type(st.mtime) == "number" then
				mtime = st.mtime
			end
		end
		items[#items + 1] = { path = p, mtime = mtime }
	end
	table.sort(items, function(a, b)
		if a.mtime ~= b.mtime then
			return a.mtime > b.mtime
		end
		return a.path < b.path
	end)
	local sorted = {}
	for i, item in ipairs(items) do
		sorted[i] = item.path
	end
	return sorted
end

function M.map_rel_paths(paths, target)
	local rels = {}
	for i, p in ipairs(paths) do
		rels[i] = M.rel_path(p, target)
	end
	return rels
end

function M.effective_limit(arg_limit, cfg_default)
	if arg_limit == nil then
		return cfg_default
	end
	if arg_limit == 0 then
		return nil
	end
	return arg_limit
end

function M.truncate_before_omission(stdout, is_nul)
	if type(stdout) ~= "string" then
		return ""
	end
	local head = stdout
	local m_start = stdout:find("\n%.%.%. %d+ bytes omitted %.%.%.\n")
	if not m_start then
		m_start = stdout:find("^%.%.%. %d+ bytes omitted %.%.%.\n")
	end
	if m_start then
		head = stdout:sub(1, m_start - 1)
	end
	if is_nul then
		local last_nul = head:match(".*()\0")
		return last_nul and head:sub(1, last_nul) or ""
	end
	local last_nl = head:match(".*()\n")
	return last_nl and head:sub(1, last_nl) or ""
end

function M.truncation_line(omitted)
	if omitted and omitted > 0 then
		return ("[... %d more results truncated; narrow the path, glob or pattern]"):format(omitted)
	end
	return "[... more results truncated; narrow the path, glob or pattern]"
end

function M.join_capped(items, total_available, omitted_before, limit, max_bytes, opts)
	opts = opts or {}
	local start_idx = opts.start_idx or 1
	local trailer_lines = opts.trailer_lines
	local force_truncated = opts.force_truncated == true
	local stop_at = limit and math.min(#items, start_idx - 1 + limit) or #items

	local out = {}
	local kept_count = 0
	local used_bytes = 0
	local byte_omitted = 0
	local single_line_cut = false
	local prev_group
	local reserve = 0
	for _, extra in ipairs(trailer_lines or {}) do
		reserve = reserve + #extra + 1
	end
	local notice_reserve = math.max(#M.truncation_line(math.max(1, total_available)), #M.truncation_line(0)) + 1

	for i = start_idx, stop_at do
		local item = items[i]
		local is_grouped = type(item) == "table"
		local line = is_grouped and item.line or item
		local group = is_grouped and item.group or nil
		local need_blank = prev_group ~= nil and group ~= nil and group ~= prev_group
		local add_bytes = #line + (kept_count > 0 and 1 or 0) + (need_blank and 1 or 0)
		local will_truncate = force_truncated or (total_available - omitted_before - (kept_count + 1)) > 0
		local cap = max_bytes - reserve - (will_truncate and notice_reserve or 0)
		if used_bytes + add_bytes > cap and kept_count > 0 then
			byte_omitted = stop_at - i + 1
			break
		end
		if used_bytes + add_bytes > cap and kept_count == 0 then
			local slice_cap = math.max(1, max_bytes - reserve - notice_reserve)
			local cut = mare.text.cut(line, slice_cap)
			out[1] = cut
			kept_count = 1
			single_line_cut = #cut < #line
			byte_omitted = stop_at - i
			break
		end
		if need_blank then
			out[#out + 1] = ""
		end
		out[#out + 1] = line
		prev_group = group
		kept_count = kept_count + 1
		used_bytes = used_bytes + add_bytes
	end

	for _, extra in ipairs(trailer_lines or {}) do
		out[#out + 1] = extra
	end
	local dropped_entries = math.max(0, total_available - omitted_before - kept_count)
	if dropped_entries == 0 and byte_omitted > 0 then
		dropped_entries = byte_omitted
	elseif dropped_entries == 0 and single_line_cut then
		dropped_entries = 1
	end
	local truncated = dropped_entries > 0 or force_truncated or single_line_cut
	if truncated then
		out[#out + 1] = M.truncation_line(dropped_entries)
	end
	return table.concat(out, "\n"), truncated
end

function M.run_proc(bin_path, argv, target, cfg, tctx, is_empty_exit)
	local res = mare.proc.run({
		cmd = bin_path,
		args = argv,
		cwd = target.run_cwd,
		timeout_ms = cfg.timeout_ms,
		max_output = cfg.max_output_bytes,
		cancel = tctx and tctx.cancel or nil,
	})
	if res.cancelled then
		return nil, { content = "cancelled", is_error = true, cancelled = true }
	end
	if res.timed_out then
		return nil,
			{
				content = ("timed out after %d ms"):format(cfg.timeout_ms),
				is_error = true,
				error_code = "tool_timeout",
			}
	end
	if
		res.sandbox_denied
		or res.sandbox_failed
		or (type(res.sandbox_marker) == "string" and res.sandbox_marker ~= "")
	then
		local marker = res.sandbox_marker or "[sandbox: access denied]"
		local detail = M.first_lines(res.stderr, 3)
		local msg = (detail ~= "" and not detail:find(marker, 1, true)) and (marker .. "\n" .. detail) or marker
		return nil,
			{
				content = msg,
				is_error = true,
				error_code = res.sandbox_denied and "sandbox_denied" or "sandbox_failed",
				details = { sandbox_marker = marker, sandbox_denied = res.sandbox_denied },
			}
	end
	if is_empty_exit and is_empty_exit(res) then
		return { empty = true, res = res }
	end
	if res.code ~= 0 then
		local err_text = M.first_lines(res.stderr, 5)
		if err_text == "" then
			err_text = M.first_lines(res.stdout, 5)
		end
		if err_text == "" then
			err_text = ("process exited with code %s%s"):format(
				tostring(res.code),
				res.signal and (" (signal " .. tostring(res.signal) .. ")") or ""
			)
		end
		return nil, { content = err_text, is_error = true }
	end
	return { empty = false, res = res }
end

local function parse_rg_content(stdout, target, show_line_numbers)
	local entries = {}
	for line in (stdout or ""):gmatch("[^\r\n]+") do
		local ok, obj = pcall(mare.json.decode, line)
		if ok and type(obj) == "table" and (obj.type == "match" or obj.type == "context") then
			local data = obj.data or {}
			local path_text = data.path and data.path.text or ""
			local rel = M.rel_path(path_text, target)
			local line_num = data.line_number
			local text = ""
			if type(data.lines) == "table" then
				if type(data.lines.text) == "string" then
					text = data.lines.text:gsub("[\r\n]+$", "")
				elseif type(data.lines.bytes) == "string" then
					text = "[binary or non-UTF-8 line]"
				end
			end
			local sep = obj.type == "context" and "-" or ":"
			local formatted
			if show_line_numbers and type(line_num) == "number" then
				formatted = ("%s%s%d%s %s"):format(rel, sep, line_num, sep, text)
			else
				formatted = ("%s%s %s"):format(rel, sep, text)
			end
			entries[#entries + 1] = { group = rel, line = formatted }
		end
	end
	return entries
end

function M.run_rg_like(bin_path, cfg, args, tctx, opts)
	local pattern, perr = M.validate_text_arg(args.pattern, "pattern", true)
	if not pattern then
		return { content = perr, is_error = true }
	end
	local glob_val, gerr = M.validate_text_arg(args.glob, "glob", false)
	if gerr then
		return { content = gerr, is_error = true }
	end
	local type_val, terr = M.validate_text_arg(args.type, "type", false)
	if terr then
		return { content = terr, is_error = true }
	end
	local offset, oerr = M.validate_nonneg_int(args.offset, "offset")
	if oerr then
		return { content = oerr, is_error = true }
	end
	offset = offset or 0
	local head_limit, herr = M.validate_nonneg_int(args.head_limit, "head_limit")
	if herr then
		return { content = herr, is_error = true }
	end
	local limit = M.effective_limit(head_limit, cfg.head_limit_default)

	local mode = args.output_mode or "content"
	local target, target_err_res = M.search_target(args.path, tctx)
	if not target then
		return target_err_res
	end

	local argv = { "--no-config", "--color=never" }
	if mode == "content" then
		argv[#argv + 1] = "--json"
	elseif mode == "files_with_matches" then
		argv[#argv + 1] = "--files-with-matches"
		argv[#argv + 1] = "-0"
	elseif mode == "count" then
		argv[#argv + 1] = "--count-matches"
		argv[#argv + 1] = "--with-filename"
	else
		return { content = "Unsupported output_mode: " .. tostring(mode), is_error = true }
	end

	if glob_val and glob_val ~= "" then
		argv[#argv + 1] = "--glob=" .. glob_val
	end
	if type_val and type_val ~= "" then
		argv[#argv + 1] = "--type=" .. type_val
	end
	if args["-i"] == true then
		argv[#argv + 1] = "--ignore-case"
	end
	if opts.allow_multiline and args.multiline == true then
		argv[#argv + 1] = "-U"
		argv[#argv + 1] = "--multiline-dotall"
	end
	if opts.allow_literal and args.literal == true then
		argv[#argv + 1] = "-F"
	end
	if mode == "content" and opts.allow_context then
		local c_val, cerr = M.validate_nonneg_int(args["-C"], "-C")
		if cerr then
			return { content = cerr, is_error = true }
		end
		local a_val, aerr = M.validate_nonneg_int(args["-A"], "-A")
		if aerr then
			return { content = aerr, is_error = true }
		end
		local b_val, berr = M.validate_nonneg_int(args["-B"], "-B")
		if berr then
			return { content = berr, is_error = true }
		end
		if c_val ~= nil then
			argv[#argv + 1] = "-C"
			argv[#argv + 1] = tostring(c_val)
		else
			if a_val ~= nil then
				argv[#argv + 1] = "-A"
				argv[#argv + 1] = tostring(a_val)
			end
			if b_val ~= nil then
				argv[#argv + 1] = "-B"
				argv[#argv + 1] = tostring(b_val)
			end
		end
	end

	if opts.regexp_flag then
		argv[#argv + 1] = "--regexp=" .. pattern
		argv[#argv + 1] = "--"
		argv[#argv + 1] = target.target
	else
		argv[#argv + 1] = "--"
		argv[#argv + 1] = pattern
		argv[#argv + 1] = target.target
	end

	local outcome, err_res = M.run_proc(bin_path, argv, target, cfg, tctx, function(res)
		return res.code == 1 and M.trim(res.stderr) == ""
	end)
	if not outcome then
		return err_res
	end
	if outcome.empty then
		return { content = "No matches", details = { matches = 0 } }
	end

	local proc_dropped = (outcome.res.dropped or 0) > 0
	local stdout = outcome.res.stdout or ""
	if proc_dropped then
		stdout = M.truncate_before_omission(stdout, mode == "files_with_matches")
	end

	if mode == "content" then
		local show_nums = args["-n"] ~= false
		local entries = parse_rg_content(stdout, target, show_nums)
		local total = #entries
		if total == 0 or offset >= total then
			if proc_dropped then
				return {
					content = M.truncation_line(),
					details = { mode = mode, matches = 0, truncated = true },
				}
			end
			return { content = "No matches", details = { mode = mode, matches = 0 } }
		end
		local content, truncated = M.join_capped(
			entries,
			total,
			offset,
			limit,
			cfg.max_output_bytes,
			{ start_idx = offset + 1, force_truncated = proc_dropped }
		)
		return {
			content = content,
			details = { mode = mode, matches = total, truncated = truncated },
		}
	elseif mode == "files_with_matches" then
		local all_paths = M.split_nul(stdout)
		local total = #all_paths
		if total == 0 or offset >= total then
			if proc_dropped then
				return {
					content = M.truncation_line(),
					details = { mode = mode, matches = 0, truncated = true },
				}
			end
			return { content = "No matches", details = { mode = mode, matches = 0 } }
		end
		local sorted = M.sort_by_mtime_desc(all_paths)
		local rels = M.map_rel_paths(sorted, target)
		local content, truncated = M.join_capped(
			rels,
			total,
			offset,
			limit,
			cfg.max_output_bytes,
			{ start_idx = offset + 1, force_truncated = proc_dropped }
		)
		return {
			content = content,
			details = { mode = mode, matches = total, truncated = truncated },
		}
	else
		local entries = {}
		local total_matches = 0
		for line in stdout:gmatch("[^\r\n]+") do
			local path_part, count_str = line:match("^(.*):(%d+)$")
			if path_part and count_str then
				local cnt = tonumber(count_str) or 0
				total_matches = total_matches + cnt
				entries[#entries + 1] = M.rel_path(path_part, target) .. ": " .. tostring(cnt)
			end
		end
		local total_files = #entries
		if total_files == 0 or offset >= total_files then
			if proc_dropped then
				return {
					content = M.truncation_line(),
					details = { mode = mode, files = 0, matches = 0, truncated = true },
				}
			end
			return { content = "No matches", details = { mode = mode, matches = 0 } }
		end
		local content, truncated = M.join_capped(entries, total_files, offset, limit, cfg.max_output_bytes, {
			start_idx = offset + 1,
			trailer_lines = { "total: " .. tostring(total_matches) },
			force_truncated = proc_dropped,
		})
		return {
			content = content,
			details = { mode = mode, files = total_files, matches = total_matches, truncated = truncated },
		}
	end
end

function M.render_result(label, res, expanded)
	if res and res.is_error then
		return nil
	end
	if type(ui) ~= "table" or type(ui.Span) ~= "function" then
		return nil
	end
	local text = type(res and res.content) == "string" and res.content or ""
	local count = 0
	for _ in text:gmatch("[^\r\n]+") do
		count = count + 1
	end
	local head = ui.Line({
		ui.Span(label .. ": "):hl("MareToolName"),
		ui.Span(("%d line%s"):format(count, count == 1 and "" or "s")):hl("MareMuted"),
	})
	if expanded and text ~= "" and type(ui.Lines) == "function" and type(ui.Paragraph) == "function" then
		return ui.Lines({ head, ui.Paragraph(ui.Line({ ui.Span(text) })) })
	end
	return head
end

return M
