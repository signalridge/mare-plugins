local M = {}

local BRAILLE_SPIN = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local ASCII_SPIN = { "|", "/", "-", "\\" }
local BRAILLE_CELLS = { "⠀", "⣀", "⣤", "⣶", "⣿" }

local function is_utf8_terminal()
	if mare and mare.ui then
		if type(mare.ui.icon_set) == "function" then
			local ok, set = pcall(mare.ui.icon_set)
			if ok and set == "ascii" then
				return false
			end
		end
		if type(mare.ui.caps) == "function" then
			local ok, caps = pcall(mare.ui.caps)
			if ok and type(caps) == "table" and caps.emoji_wide == false then
				return false
			end
		end
	end
	if mare and mare.env and mare.env.get then
		local lc = mare.env.get("LC_ALL") or mare.env.get("LC_CTYPE") or mare.env.get("LANG") or ""
		if lc ~= "" and not lc:lower():find("utf%-?8") then
			return false
		end
	end
	return true
end

function M.resolve_bar_mode(bar_cfg, utf8_ok)
	if utf8_ok == false or not is_utf8_terminal() then
		return "ascii"
	end
	if bar_cfg == "block" or bar_cfg == "ascii" then
		return bar_cfg
	end
	return "braille"
end

function M.format_duration(ms)
	local s = math.max(0, math.floor((ms or 0) / 1000))
	if s < 60 then
		return s .. "s"
	elseif s < 3600 then
		return ("%dm%02ds"):format(s // 60, s % 60)
	end
	return ("%dh%02dm"):format(s // 3600, (s % 3600) // 60)
end

--- Estimate 0..1 progress for a member using an asymptotic tool-call estimator.
function M.estimate_progress(member, fill_frac)
	if member.status == "completed" then
		return fill_frac or 1.0
	elseif member.status == "failed" or member.status == "cancelled" or member.status == "stop_unconfirmed" then
		return 1.0
	elseif member.status == "queued" then
		return 0.0
	end
	local calls = tonumber(member.tool_calls) or 0
	return math.min(0.95, 1.0 - math.exp(-calls / 6.0) * 0.85)
end

function M.render_bar(frac, cells, mode)
	cells = math.max(4, cells or 8)
	local f = math.max(0, math.min(1, frac or 0))
	if mode == "ascii" then
		local filled = math.floor(f * cells + 0.5)
		return "[" .. string.rep("=", filled) .. string.rep("-", cells - filled) .. "]"
	elseif mode == "block" then
		local filled = math.floor(f * cells + 0.5)
		return "[" .. string.rep("█", filled) .. string.rep("░", cells - filled) .. "]"
	end
	-- braille: 4 fill levels per cell
	local total_steps = cells * 4
	local filled_steps = math.floor(f * total_steps + 0.5)
	local out = {}
	for i = 1, cells do
		local rem = math.max(0, math.min(4, filled_steps - (i - 1) * 4))
		out[i] = BRAILLE_CELLS[rem + 1]
	end
	return "[" .. table.concat(out) .. "]"
end

local function read_style(name, fallback)
	if mare and mare.ui and type(mare.ui.style) == "function" then
		local style_name = "workflow." .. name
		local ok, spec = pcall(mare.ui.style, style_name)
		if ok and type(spec) == "table" then
			return style_name
		end
	end
	return fallback
end

local function get_panel_renderer()
	if mare and mare.ui and type(mare.ui.get_renderer) == "function" then
		local ok, r = pcall(mare.ui.get_renderer, "workflow/panel")
		if ok and r ~= nil then
			return r
		end
	end
	return nil
end

local function agents_hint_text()
	if not (mare and mare.keymap) then
		return nil
	end
	local fn = mare.keymap.hint
	if type(fn) ~= "function" then
		return nil
	end
	local ok, keys = pcall(fn, "agents", "editor")
	if not ok or type(keys) ~= "table" or #keys == 0 then
		return nil
	end
	local k = tostring(keys[1])
	if k == "<Left>" or k == "left" then
		k = is_utf8_terminal() and "←" or "Left"
	end
	return k .. " for agents"
end

local function clean_text(s)
	return tostring(s or ""):gsub("[%c]+", " "):gsub("%s+", " "):match("^%s*(.-)%s*$") or ""
end

local function status_symbol(status, frame_idx, bar_mode)
	local utf8_ok = bar_mode ~= "ascii"
	if status == "completed" then
		return utf8_ok and "✓" or "+", read_style("bar_done", "MareSuccess")
	elseif status == "failed" or status == "stop_unconfirmed" then
		return utf8_ok and "✗" or "x", read_style("failed", "MareError")
	elseif status == "cancelled" or status == "interrupted" then
		return utf8_ok and "⊘" or "-", "MareWarning"
	elseif status == "queued" then
		return utf8_ok and "·" or ".", "MareDim"
	end
	local frames = utf8_ok and BRAILLE_SPIN or ASCII_SPIN
	return frames[(frame_idx % #frames) + 1], "MareAccent"
end

local function format_cell(member, cell_w, compact_bar_only, frame_idx, bar_mode, fill_frac)
	local num = ("%03d"):format(member.seq or 0)
	local sym, hl = status_symbol(member.status, frame_idx, bar_mode)
	if compact_bar_only then
		local bar = M.render_bar(M.estimate_progress(member, fill_frac), 6, bar_mode)
		local label = clean_text(member.label or num)
		local text = ("%s %s %s"):format(num, sym, bar)
		if #text + 2 < cell_w then
			text = text .. " " .. mare.text.trunc_width(label, cell_w - #text - 1)
		end
		return mare.ui.Line({
			mare.ui.Span("  " .. num .. " "):hl("MareDim"),
			mare.ui.Span(sym .. " "):hl(hl),
			mare.ui
				.Span(bar)
				:hl(member.status == "completed" and read_style("bar_done", "MareSuccess") or "MareAccent"),
			#text > #(num .. " " .. sym .. " " .. bar) and mare.ui
				.Span(" " .. mare.text.trunc_width(label, math.max(1, cell_w - #bar - 8)))
				:hl("MareMuted") or "",
		})
	end
	if member.status == "completed" then
		local dur = M.format_duration(member.duration_ms or 0)
		local label = clean_text(member.label or "")
		local body = ("%s %s"):format(dur, label)
		return mare.ui.Line({
			mare.ui.Span("  " .. num .. " "):hl("MareDim"),
			mare.ui.Span(sym .. " "):hl(hl),
			mare.ui.Span(mare.text.trunc_width(body, math.max(4, cell_w - 8))):hl("MareMuted"),
		})
	elseif member.status == "failed" or member.status == "cancelled" or member.status == "stop_unconfirmed" then
		local err = clean_text(member.error or member.status)
		return mare.ui.Line({
			mare.ui.Span("  " .. num .. " "):hl("MareDim"),
			mare.ui.Span(sym .. " "):hl(hl),
			mare.ui.Span(mare.text.trunc_width(err, math.max(4, cell_w - 8))):hl(hl),
		})
	end
	local bar = M.render_bar(M.estimate_progress(member, fill_frac), 8, bar_mode)
	local preview = clean_text(member.preview or member.label or "working…")
	local avail = math.max(4, cell_w - 18)
	return mare.ui.Line({
		mare.ui.Span("  " .. num .. " "):hl("MareDim"),
		mare.ui.Span(bar .. " "):hl("MareAccent"),
		mare.ui.Span(mare.text.trunc_width(preview, avail)):hl("MareMuted"),
	})
end

--- Pure panel renderer for both live widget and unit tests.
function M.render_run(run, width, max_height, cfg, opts)
	opts = opts or {}
	if not run then
		return nil
	end
	width = math.max(20, tonumber(width) or 80)
	local term_h = opts.term_height or (mare and mare.ui and mare.ui.height and mare.ui.height()) or 24
	local frac_cap = math.max(3, math.floor(term_h * ((cfg.panel and cfg.panel.max_height) or 0.33)))
	local cap = math.min(math.max(1, tonumber(max_height) or frac_cap), frac_cap)

	local custom = get_panel_renderer()
	if custom then
		local fn = type(custom) == "function" and custom
			or (type(custom) == "table" and (custom.render or custom.compact))
		if type(fn) == "function" then
			local ok, node = pcall(fn, run, width, cap)
			if ok and node ~= nil then
				return node
			end
		end
	end

	local panel_cfg = cfg.panel or {}
	local bar_mode = M.resolve_bar_mode(panel_cfg.bar, opts.utf8)
	local frame_idx = opts.frame_idx or 0
	local fill_frac = opts.fill_frac
	local elapsed_ms = run.ended_at_ms and (run.ended_at_ms - run.started_at_ms)
		or (mare.task.clock() - (run.started_clock or mare.task.clock()))

	-- Header line
	local rule_char = bar_mode == "ascii" and "-" or "─"
	local title_text = ("%s %s %s "):format(rule_char, tostring(run.name or "workflow"), rule_char)
	local desc_text = clean_text(run.description or "")
	local model_suffix = run.model and (" · " .. tostring(run.model)) or ""
	local header_left = title_text .. desc_text .. model_suffix
	local header_fill = math.max(0, width - mare.text.width(header_left) - 1)
	local title_w = mare.text.width(title_text)
	local header_line = mare.ui.Line({
		mare.ui.Span(mare.text.trunc_width(title_text, width)):hl(read_style("title", "MareAccent")),
		mare.ui.Span(mare.text.trunc_width(desc_text .. model_suffix, math.max(0, width - title_w))):hl("MareMuted"),
		header_fill > 0 and mare.ui.Span(" " .. string.rep(rule_char, header_fill)):hl("MareDim") or "",
	})

	-- Footer line
	local status_label = run.status == "completed" and "Completed."
		or run.status == "failed" and "Failed."
		or run.status == "cancelled" and "Aborted."
		or (run.total == 0 and "Orchestrating…" or "Working…")
	local spin, spin_hl = status_symbol(run.status == "running" and "running" or run.status, frame_idx, bar_mode)
	local done_count = (run.completed or 0) + (run.failed or 0) + (run.cancelled or 0)
	local total_count = math.max(run.total or 0, done_count)
	local overall_frac = fill_frac or (total_count > 0 and (done_count / total_count) or 0)
	local hint = opts.agents_hint ~= nil and opts.agents_hint or agents_hint_text()
	local counts_str = (" %d/%d · %s"):format(done_count, total_count, M.format_duration(elapsed_ms))
		.. (hint and ("  " .. hint) or "")
	local gauge_w = math.max(6, width - mare.text.width(spin .. " " .. status_label .. counts_str) - 4)
	local overall_bar = M.render_bar(overall_frac, math.min(40, gauge_w), bar_mode)
	local footer_line = mare.ui.Line({
		mare.ui.Span(" " .. spin .. " "):hl(spin_hl),
		mare.ui.Span(status_label .. "  "):hl("MareText"),
		mare.ui
			.Span(overall_bar)
			:hl(run.status == "completed" and read_style("bar_done", "MareSuccess") or "MareAccent"),
		mare.ui.Span(counts_str):hl("MareDim"),
	})

	local body_budget = math.max(0, cap - 2)
	local small_list = (panel_cfg.layout == "list") or (total_count > 0 and total_count <= 3 and #run.phase_order == 0)

	local function build_body_lines(collapse_done, bar_only)
		local lines = {}
		local row_members = {}

		local function append_collapsed_done(count)
			if count <= 0 then
				return
			end
			local sym = bar_mode == "ascii" and "+" or "✓"
			lines[#lines + 1] = mare.ui.Line({
				mare.ui.Span(("  %s %d completed"):format(sym, count)):hl(read_style("bar_done", "MareSuccess")),
			})
			row_members[#row_members + 1] = count
		end

		if small_list then
			local visible = {}
			local done_collapsed = 0
			for _, m in ipairs(run.agents or {}) do
				if collapse_done and m.status == "completed" then
					done_collapsed = done_collapsed + 1
				else
					visible[#visible + 1] = m
				end
			end
			append_collapsed_done(done_collapsed)
			for _, m in ipairs(visible) do
				local sym, hl = status_symbol(m.status, frame_idx, bar_mode)
				local dur =
					M.format_duration(m.duration_ms or (mare.task.clock() - (m.started_clock or mare.task.clock())))
				local what = clean_text(m.preview or m.summary or m.status)
				lines[#lines + 1] = mare.ui.Line({
					mare.ui.Span(" " .. sym .. " "):hl(hl),
					mare.ui
						.Span(mare.text.trunc_width(m.label or ("agent-" .. tostring(m.seq)), 18) .. "  ")
						:hl("MareText"),
					mare.ui.Span(mare.text.trunc_width(what, math.max(8, width - 30))):hl("MareMuted"),
					mare.ui.Span("  " .. dur):hl("MareDim"),
				})
				row_members[#row_members + 1] = 1
			end
			return lines, row_members
		end

		local cell_w = panel_cfg.cell_width or 30
		local cols = math.max(1, math.floor(width / cell_w))
		local actual_cell_w = math.floor(width / cols)

		local sections = {}
		local unphased = {}
		for _, m in ipairs(run.agents or {}) do
			if not m.phase or m.phase == "" then
				unphased[#unphased + 1] = m
			end
		end
		if #unphased > 0 then
			sections[#sections + 1] = { title = nil, agents = unphased }
		end
		if #run.phase_order > 0 then
			for _, title in ipairs(run.phase_order) do
				local p = run.phases and run.phases[title]
				if p and #(p.agents or {}) > 0 then
					sections[#sections + 1] = { title = title, agents = p.agents }
				end
			end
		end

		for _, sec in ipairs(sections) do
			if sec.title then
				lines[#lines + 1] = mare.ui.Line({ mare.ui.Span(" " .. sec.title):hl("MareBold") })
				row_members[#row_members + 1] = 0
			end
			local visible = {}
			local done_collapsed = 0
			for _, m in ipairs(sec.agents) do
				if collapse_done and m.status == "completed" then
					done_collapsed = done_collapsed + 1
				else
					visible[#visible + 1] = m
				end
			end
			append_collapsed_done(done_collapsed)
			for idx = 1, #visible, cols do
				local row_items = {}
				for c = 0, cols - 1 do
					local m = visible[idx + c]
					if m then
						row_items[#row_items + 1] =
							format_cell(m, actual_cell_w, bar_only, frame_idx, bar_mode, fill_frac)
					end
				end
				if #row_items == 1 then
					lines[#lines + 1] = row_items[1]
					row_members[#row_members + 1] = 1
				elseif #row_items > 1 then
					lines[#lines + 1] = mare.ui.Row(row_items)
					row_members[#row_members + 1] = #row_items
				end
			end
		end
		return lines, row_members
	end

	local body, row_members = build_body_lines(false, false)
	if #body > body_budget and panel_cfg.collapse_done ~= false then
		body, row_members = build_body_lines(true, false)
	end
	if #body > body_budget then
		body, row_members = build_body_lines(panel_cfg.collapse_done ~= false, true)
	end
	if #body > body_budget then
		local folded = {}
		local keep = math.max(0, body_budget - 1)
		local hidden_members = 0
		for i = 1, keep do
			folded[i] = body[i]
		end
		for i = keep + 1, #body do
			hidden_members = hidden_members + (row_members[i] or 0)
		end
		if hidden_members == 0 then
			hidden_members = #body - keep
		end
		if body_budget >= 1 then
			folded[#folded + 1] = mare.ui.Line({
				mare.ui.Span(("  +%d more"):format(hidden_members)):hl("MareDim"),
			})
		end
		body = folded
	end

	local out = { header_line }
	for _, l in ipairs(body) do
		out[#out + 1] = l
	end
	out[#out + 1] = footer_line
	if cap >= 1 and #out > cap then
		if cap == 1 then
			out = { footer_line }
		else
			local trimmed = { header_line }
			for i = 2, cap - 1 do
				if out[i] then
					trimmed[#trimmed + 1] = out[i]
				end
			end
			trimmed[#trimmed + 1] = footer_line
			out = trimmed
		end
	end
	return mare.ui.Lines(out)
end

function M.create(ctx, get_cfg)
	local P = {}
	local active_run = nil
	local fill_frac = nil
	local frame_idx = 0
	local timer_running = false
	local ui_svc = nil

	local function invalidate()
		if ui_svc and type(ui_svc.invalidate) == "function" then
			pcall(ui_svc.invalidate, ui_svc, "workflow")
		end
	end

	ctx:inject({ "ui" }, function(c)
		ui_svc = c.ui
		c.ui:widget("workflow", {
			slot = "above-editor",
			order = -10,
			render = function(width, max_height)
				if not active_run then
					return nil
				end
				return M.render_run(active_run, width, max_height, get_cfg(), {
					frame_idx = frame_idx,
					fill_frac = fill_frac,
				})
			end,
		})
	end)

	function P.invalidate()
		invalidate()
	end

	function P.attach(run)
		active_run = run
		fill_frac = nil
		frame_idx = 0
		invalidate()
		if not timer_running and ctx.spawn then
			timer_running = true
			ctx:spawn(function()
				while active_run and active_run.status == "running" do
					mare.task.sleep(80)
					frame_idx = frame_idx + 1
					invalidate()
				end
				timer_running = false
			end)
		end
	end

	function P.finish(run)
		if active_run ~= run then
			return
		end
		-- 360ms completion fill-up animation before collapsing the live panel
		if ctx.spawn and mare and mare.ui and mare.ui.connected and mare.ui.connected() then
			for step = 1, 4 do
				fill_frac = step / 4
				invalidate()
				mare.task.sleep(90)
			end
		end
		if active_run == run then
			active_run = nil
			fill_frac = nil
			invalidate()
		end
	end

	return P
end

return M
