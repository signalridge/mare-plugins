local M = {}

local function now_ms()
	return mare and mare.task and mare.task.now and math.floor(mare.task.now()) or 0
end

local function dur(ms)
	local s = math.max(0, math.floor((ms or 0) / 1000))
	if s < 60 then
		return s .. "s"
	elseif s < 3600 then
		return ("%dm%02ds"):format(s // 60, s % 60)
	end
	return ("%dh%02dm"):format(s // 3600, (s % 3600) // 60)
end

local function status_mark(task)
	if task.status == "completed" then
		return "✓", "MareSuccess", "completed"
	elseif task.status == "cancelled" then
		return "⊘", "MareDim", "cancelled"
	elseif task.status == "in_progress" then
		if task.lease_stale then
			return "!", "MareWarning", "stale lease"
		end
		return "●", "MareAccent", "in_progress"
	elseif task.blocked then
		return "⏸", "MareWarning", "blocked"
	end
	return "○", "MareMuted", "ready"
end

function M.preview_node(task, now)
	now = now or now_ms()
	local sym, hl, word = status_mark(task)
	local function row(k, v)
		return mare.ui.Line({
			mare.ui.Span(("%-11s"):format(k)):hl("MareDim"),
			mare.ui.Span(tostring(v)),
		})
	end
	local out = {
		mare.ui.Line({
			mare.ui.Span(sym .. " " .. task.id .. " · " .. task.title):hl("MareTitle"),
			mare.ui.Span("  " .. word):hl(hl),
		}),
		row("priority", task.priority),
		row("revision", task.revision),
	}
	if task.owner then
		local lease_text = ""
		if task.lease_expires_at_ms then
			local rem = task.lease_expires_at_ms - now
			lease_text = rem > 0 and (" (" .. dur(rem) .. " left)") or " (expired)"
		end
		out[#out + 1] = row("owner", task.owner .. lease_text)
	end
	if #(task.blocked_by or {}) > 0 then
		out[#out + 1] = row("blocked_by", table.concat(task.blocked_by, ", "))
	end
	if #(task.unresolved_blockers or {}) > 0 then
		out[#out + 1] = row("waiting_on", table.concat(task.unresolved_blockers, ", "))
	end
	if #(task.blocks or {}) > 0 then
		out[#out + 1] = row("blocks", table.concat(task.blocks, ", "))
	end
	if task.description and task.description ~= "" then
		out[#out + 1] = mare.ui.Gap(1)
		out[#out + 1] = mare.ui.Paragraph(task.description)
	end
	if task.result and task.result ~= "" then
		out[#out + 1] = mare.ui.Gap(1)
		out[#out + 1] = mare.ui.Line({ mare.ui.Span("Result:"):hl("MareSuccess") })
		out[#out + 1] = mare.ui.Paragraph(task.result)
	end
	if #(task.notes or {}) > 0 then
		out[#out + 1] = mare.ui.Gap(1)
		out[#out + 1] = mare.ui.Line({ mare.ui.Span("Notes:"):hl("MareDim") })
		for _, n in ipairs(task.notes) do
			out[#out + 1] = mare.ui.Line({
				mare.ui.Span(("  [%s] "):format(tostring(n.author or "?"))):hl("MareDim"),
				mare.ui.Span(tostring(n.text or "")),
			})
		end
	end
	return mare.ui.Lines(out)
end

local function make_items(tasks, filter_fn, now)
	local items = {}
	local mapped = {}
	for _, t in ipairs(tasks) do
		if filter_fn(t) then
			local sym, hl, word = status_mark(t)
			local owner_str = t.owner and (" · @" .. t.owner) or ""
			local blk_str = #(t.unresolved_blockers or {}) > 0
					and (" · waiting: " .. table.concat(t.unresolved_blockers, ","))
				or ""
			items[#items + 1] = {
				id = t.id,
				label = ("%s %s  %s"):format(sym, t.id, t.title),
				detail = ("%s · %s%s%s"):format(word, t.priority, owner_str, blk_str),
				lines = {
					mare.ui.Line({
						mare.ui.Span(sym .. " "):hl(hl),
						mare.ui.Span(t.id .. " "):hl("MareDim"),
						mare.ui.Span(mare.text.trunc_width(t.title, 48)),
						mare.ui.Span("  " .. word .. owner_str .. blk_str):hl(hl),
					}),
				},
			}
			mapped[#items] = t
		end
	end
	return items, mapped
end

function M.build_inspector(store)
	local snap = store.list()
	local now = now_ms()
	local tabs_def = {
		{
			name = "All",
			fn = function()
				return true
			end,
		},
		{
			name = "Ready",
			fn = function(t)
				return t.ready
			end,
		},
		{
			name = "Active",
			fn = function(t)
				return t.status == "in_progress"
			end,
		},
		{
			name = "Blocked",
			fn = function(t)
				return t.blocked
			end,
		},
		{
			name = "Done",
			fn = function(t)
				return t.status == "completed" or t.status == "cancelled"
			end,
		},
	}
	local tabs, maps = {}, {}
	for i, td in ipairs(tabs_def) do
		local items, mapped = make_items(snap.tasks, td.fn, now)
		tabs[i] = { name = td.name, items = items, selected = 1 }
		maps[i] = mapped
	end
	local c = snap.counts
	local right = ("%d active · %d ready · %d blocked · %d done"):format(
		c.in_progress,
		c.ready,
		c.blocked,
		c.completed
	)
	return {
		title = "Team Board",
		title_right = right,
		tabs = tabs,
		on_highlight = function(i, tab)
			local item = tabs[tab or 1] and tabs[tab or 1].items and tabs[tab or 1].items[i]
			if not item then
				return nil
			end
			local cur_now = now_ms()
			local live_snap = store.list()
			for _, lt in ipairs(live_snap.tasks) do
				if lt.id == item.id then
					return M.preview_node(lt, cur_now)
				end
			end
			return mare.ui.Line({
				mare.ui.Span(("Task %s is no longer on the board."):format(tostring(item.id))):hl("MareDim"),
			})
		end,
	},
		snap
end

function M.open_inspector(store)
	local spec = M.build_inspector(store)
	if not (mare and mare.ui and type(mare.ui.select) == "function") then
		return
	end
	-- Read-only inspector: displays tasks and previews, ignores selection.
	mare.ui.select(spec)
end

function M.widget_node(store, width, show_widget)
	if not show_widget then
		return nil
	end
	local snap = store.cached_snapshot and store.cached_snapshot() or store.list()
	local c = snap.counts
	if c.total == 0 then
		return nil
	end
	local summary = ("Team: %d active · %d ready · %d blocked · %d/%d done"):format(
		c.in_progress,
		c.ready,
		c.blocked,
		c.completed,
		c.total
	)
	return mare.ui.Line({
		mare.ui.Span("  " .. mare.text.trunc_width(summary, math.max(10, (width or 80) - 10))):hl("MareAccent"),
		mare.ui.Span("  /team"):hl("MareDim"),
	})
end

function M.context_text(store)
	local snap = store.cached_snapshot and store.cached_snapshot({ include_completed = false })
		or store.list({ include_completed = false })
	if #snap.tasks == 0 then
		return nil
	end
	local compact = {}
	for _, t in ipairs(snap.tasks) do
		compact[#compact + 1] = {
			id = t.id,
			title = t.title,
			status = t.status,
			ready = t.ready,
			owner = t.owner,
			unresolved_blockers = t.unresolved_blockers,
			revision = t.revision,
		}
	end
	return "Shared team task board (active/pending tasks):\n" .. mare.json.encode(compact)
end

return M
