local records = require("workflow.records")
local panel = require("workflow.panel")

local M = {}

local function clean(s)
	return tostring(s or ""):gsub("[%c]+", " "):gsub("%s+", " "):match("^%s*(.-)%s*$") or ""
end

local function status_mark(status)
	if status == "completed" then
		return "✓", "MareSuccess"
	elseif status == "running" then
		return "◐", "MareAccent"
	elseif status == "cancelled" then
		return "⊘", "MareWarning"
	elseif status == "interrupted" or status == "stop_unconfirmed" then
		return "⚠", "MareWarning"
	end
	return "✗", "MareError"
end

function M.counts_of(run)
	if type(run.counts) == "table" then
		return run.counts
	end
	local completed, failed, cancelled, interrupted = 0, 0, 0, 0
	for _, a in ipairs(run.agents or {}) do
		if a.status == "completed" then
			completed = completed + 1
		elseif a.status == "cancelled" then
			cancelled = cancelled + 1
		elseif a.status == "interrupted" or a.status == "stop_unconfirmed" then
			interrupted = interrupted + 1
		else
			failed = failed + 1
		end
	end
	return {
		total = #(run.agents or {}),
		completed = completed,
		failed = failed,
		cancelled = cancelled,
		interrupted = interrupted,
	}
end

function M.compact_text(run)
	local c = M.counts_of(run)
	local sym = status_mark(run.status)
	local dur = panel.format_duration(run.duration_ms or 0)
	local parts = {
		("%s %s"):format(sym, tostring(run.name or "workflow")),
		clean(run.description or ""),
		("%d agent%s"):format(c.total, c.total == 1 and "" or "s"),
	}
	local tallies = {}
	if c.completed > 0 then
		tallies[#tallies + 1] = c.completed .. " ✓"
	end
	if c.failed > 0 then
		tallies[#tallies + 1] = c.failed .. " ✗"
	end
	if c.cancelled > 0 then
		tallies[#tallies + 1] = c.cancelled .. " ⊘"
	end
	if c.interrupted > 0 then
		tallies[#tallies + 1] = c.interrupted .. " interrupted"
	end
	if #tallies > 0 then
		parts[#parts + 1] = table.concat(tallies, " ")
	end
	parts[#parts + 1] = dur
	local filtered = {}
	for _, p in ipairs(parts) do
		if p ~= "" then
			filtered[#filtered + 1] = p
		end
	end
	return table.concat(filtered, " · ")
end

local function fmt_tokens(usage)
	if type(usage) ~= "table" then
		return nil
	end
	local total = (tonumber(usage.input) or 0) + (tonumber(usage.output) or 0)
	if total <= 0 then
		return nil
	end
	if total >= 1000 then
		return ("%.1fk tok"):format(total / 1000)
	end
	return tostring(total) .. " tok"
end

function M.render_run(run, expanded)
	if type(run) ~= "table" then
		return nil
	end
	local _, hl = status_mark(run.status)
	local head = mare.ui.Line({ mare.ui.Span(M.compact_text(run)):hl(hl) })
	if not expanded then
		return head
	end

	local nodes = { head }
	local groups = {}
	local group_idx = {}
	for _, a in ipairs(run.agents or {}) do
		local pname = a.phase or "(default)"
		if not group_idx[pname] then
			group_idx[pname] = { title = a.phase, items = {} }
			groups[#groups + 1] = group_idx[pname]
		end
		table.insert(group_idx[pname].items, a)
	end

	for _, g in ipairs(groups) do
		if g.title then
			nodes[#nodes + 1] = mare.ui.Line({ mare.ui.Span("  " .. g.title):hl("MareBold") })
		end
		for _, a in ipairs(g.items) do
			local asym, ahl = status_mark(a.status)
			local dur = panel.format_duration(a.duration_ms or 0)
			local tok = fmt_tokens(a.usage)
			local line_preview = a.status == "interrupted" and "interrupted"
				or clean(a.summary or a.error or a.status or "")
			local spans = {
				mare.ui.Span(("    %s %s"):format(asym, tostring(a.label or ("agent-" .. tostring(a.seq))))):hl(ahl),
				mare.ui.Span(("  %s"):format(a.status == "interrupted" and "interrupted" or a.status)):hl(ahl),
				mare.ui.Span(" · " .. dur):hl("MareDim"),
			}
			if tok then
				spans[#spans + 1] = mare.ui.Span(" · " .. tok):hl("MareDim")
			end
			if line_preview ~= "" and line_preview ~= a.status then
				spans[#spans + 1] = mare.ui.Span(" — " .. mare.text.trunc_width(line_preview, 80)):hl("MareMuted")
			end
			nodes[#nodes + 1] = mare.ui.Line(spans)
		end
	end

	if run.error then
		nodes[#nodes + 1] = mare.ui.Line({ mare.ui.Span("  error: " .. clean(run.error)):hl("MareError") })
	end
	return mare.ui.Lines(nodes)
end

function M.create(ctx, svc)
	local S = {}
	local history = {}
	local by_id = {}
	local ui_ref = nil

	local function invalidate_ui()
		if ui_ref and type(ui_ref.invalidate) == "function" then
			pcall(ui_ref.invalidate, ui_ref)
		end
	end

	local function index_run(run)
		if type(run) ~= "table" or type(run.run_id) ~= "string" then
			return
		end
		if not by_id[run.run_id] then
			history[#history + 1] = run
		else
			for i, existing in ipairs(history) do
				if existing.run_id == run.run_id then
					history[i] = run
					break
				end
			end
		end
		by_id[run.run_id] = run
	end

	function S.track_run(run)
		index_run(run)
		invalidate_ui()
	end

	function S.record_run(run)
		index_run(run)
		invalidate_ui()
	end

	function S.rebuild()
		history = {}
		by_id = {}
		if svc.session then
			for _, run in ipairs(records.reconstruct(svc.session)) do
				index_run(run)
			end
		end
		return history
	end

	function S.list()
		return history
	end

	function S.render_tool(args, result, expanded)
		if not result then
			local name = type(args) == "table" and type(args.meta) == "table" and args.meta.name or "workflow"
			return mare.ui.Spinner("workflow " .. tostring(name) .. " · running")
		end
		local details = type(result.details) == "table" and result.details or nil
		local run = details and details.run
		if type(run) == "table" then
			return M.render_run(run, expanded)
		end
		if details and details.background == true then
			local label = tostring(details.name or "workflow")
			local jid = tostring(details.job_id or "")
			return mare.ui.Line({
				mare.ui.Span(("◐ %s · background job %s"):format(label, jid)):hl("MareAccent"),
			})
		end
		return nil
	end

	local function resolve_entry_run(d)
		local run_id = type(d) == "table" and d.run_id or nil
		if not run_id then
			return nil
		end
		local run = by_id[run_id]
		if not run and svc and svc.session then
			-- /tree branch switches fire ui's session/loaded before workflow's listener runs rebuild().
			S.rebuild()
			run = by_id[run_id]
		end
		return run
	end

	local function render_start_entry(entry, expanded)
		local d = type(entry) == "table" and (entry.data or entry) or {}
		local run = resolve_entry_run(d)
		if run then
			-- Live runs must not freeze a premature 0-agent block at run-start; completed foreground
			-- runs render through render_tool(), and background runs render through workflow/run-end.
			if run.status == "running" or run.status ~= "interrupted" then
				return nil
			end
			return M.render_run(run, expanded)
		end
		return mare.ui.Line({
			mare.ui.Span(("workflow %s"):format(tostring(d.name or d.run_id or ""))):hl("MareDim"),
		})
	end

	local function render_end_entry(entry, expanded)
		local d = type(entry) == "table" and (entry.data or entry) or {}
		local run = resolve_entry_run(d)
		if run and (run.background or d.background) then
			return M.render_run(run, expanded)
		end
		return nil
	end

	local function attach_ui(c)
		if c and c.ui then
			ui_ref = c.ui
		end
		if c and c.ui and type(c.ui.register_entry_renderer) == "function" then
			c.ui:register_entry_renderer("workflow/run-start", {
				compact = function(entry)
					return render_start_entry(entry, false)
				end,
				expanded = function(entry)
					return render_start_entry(entry, true)
				end,
			})
			c.ui:register_entry_renderer("workflow/run-end", {
				compact = function(entry)
					return render_end_entry(entry, false)
				end,
				expanded = function(entry)
					return render_end_entry(entry, true)
				end,
			})
		end
	end

	if type(ctx.inject) == "function" then
		ctx:inject({ "ui" }, attach_ui)
	elseif ctx.ui then
		attach_ui(ctx)
	end

	return S
end

return M
