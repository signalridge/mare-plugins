local M = {}
local model = require("todo.model")
local marks = { pending = "[ ]", in_progress = "[~]", completed = "[x]" }
local styles = {
	pending = { fg = "muted" },
	in_progress = { fg = "accent", bold = true },
	completed = { dim = true, strike = true },
}
local function clean(text)
	return tostring(text):gsub("[%c]", " ")
end
local function item_node(item)
	return mare.ui.Paragraph(
		mare.ui.Line({
			mare.ui.Span(marks[item.status] .. " ", styles[item.status]),
			mare.ui.Span(item.content, styles[item.status]),
		}),
		"    "
	)
end
local function summary_parts(todos)
	local c = model.counts(todos)
	local active
	for _, item in ipairs(todos) do
		if item.status == "in_progress" then
			active = active or clean(item.content)
		end
	end
	local head = ("%d/%d completed · %d active · %d pending"):format(c.completed, #todos, c.in_progress, c.pending)
	local extra = c.in_progress > 1 and (" +" .. (c.in_progress - 1)) or ""
	return head .. (active and (" · " .. active) or ""), active and extra or ""
end
function M.summary(todos)
	local text, extra = summary_parts(todos)
	return text .. extra
end
local function result_text(result)
	if type(result.content) == "string" then
		return result.content
	end
	local text = {}
	for _, block in ipairs(type(result.content) == "table" and result.content or {}) do
		if type(block) == "table" and type(block.text) == "string" then
			text[#text + 1] = block.text
		end
	end
	return table.concat(text, "\n")
end
function M.render(args, result, expanded)
	if not result then
		return mare.ui.Line("Updating todo list…")
	end
	if result.is_error or result.cancelled then
		return mare.ui.Paragraph(mare.ui.Line({
			mare.ui.Span(result.cancelled and "Todo update cancelled: " or "Todo update failed: ", "error"),
			result_text(result),
		}))
	end
	local d = result.details
	local legacy = false
	if type(d) ~= "table" or type(d.todos) ~= "table" then
		local ok, value = pcall(model.canonical, type(args) == "table" and args.todos or nil, true)
		if not ok then
			return mare.ui.Paragraph("Todo update · baseline unavailable\n" .. result_text(result))
		end
		d = { todos = value, explanation = type(args.explanation) == "string" and args.explanation or nil }
		legacy = true
	end
	local nodes = { mare.ui.Paragraph("Updated todos · " .. M.summary(d.todos)) }
	if d.explanation and d.explanation:match("%S") then
		nodes[#nodes + 1] = mare.ui.Paragraph(d.explanation)
	end
	if d.diff then
		nodes[#nodes + 1] =
			mare.ui.Line(d.diff.baseline == "initial" and "Initial checklist" or "Compared with previous checklist")
		local c = d.diff.counts
		nodes[#nodes + 1] = mare.ui.Line(
			("%d added · %d updated · %d removed · %d unchanged"):format(c.added, c.updated, c.removed, c.unchanged)
		)
	else
		nodes[#nodes + 1] = mare.ui.Line("Baseline unavailable")
	end
	if legacy then
		nodes[#nodes + 1] = mare.ui.Paragraph(result_text(result))
	end
	if expanded then
		if #d.todos == 0 then
			nodes[#nodes + 1] = mare.ui.Line("No todos")
		end
		if d.diff then
			for _, item in ipairs(d.diff.items) do
				local label = item.kind
				if item.previous_status and item.previous_status ~= item.status then
					label = label .. ": " .. item.previous_status .. " → " .. item.status
				end
				if item.moved then
					label = label .. "; moved"
				end
				nodes[#nodes + 1] =
					mare.ui.Paragraph(label .. " · " .. marks[item.status] .. " " .. clean(item.content))
			end
		else
			for _, item in ipairs(d.todos) do
				nodes[#nodes + 1] = item_node(item)
			end
		end
	end
	return mare.ui.Lines(nodes)
end
function M.widget(state, width, height)
	local nodes = {}
	if state.todos == nil or #state.todos == 0 or height <= 0 then
		return mare.ui.Lines(nodes)
	end
	local function row(text)
		return mare.ui.Line(mare.text.trunc_width(clean(text), math.max(0, width)))
	end
	local text, extra = summary_parts(state.todos)
	local prefix = (state.collapsed and "▸ " or "▾ ") .. "Todos · "
	local max_w = math.max(0, width)
	if extra ~= "" and max_w > #extra then
		nodes[1] = mare.ui.Line(mare.text.trunc_width(clean(prefix .. text), max_w - #extra) .. extra)
	else
		nodes[1] = row(prefix .. text .. extra)
	end
	if state.collapsed then
		return mare.ui.Lines(nodes)
	end
	local limit = #state.todos <= height - 1 and #state.todos or math.max(0, height - 2)
	for i = 1, limit do
		local item = state.todos[i]
		nodes[#nodes + 1] = mare.ui.Line({
			mare.ui.Span(
				mare.text.trunc_width(marks[item.status] .. " " .. clean(item.content), math.max(0, width)),
				styles[item.status]
			),
		})
	end
	if limit < #state.todos and #nodes < height then
		nodes[#nodes + 1] = row(("%d more · /todos"):format(#state.todos - limit))
	end
	return mare.ui.Lines(nodes)
end
function M.show(state)
	local items = {}
	for _, item in ipairs(state.todos or {}) do
		items[#items + 1] = {
			label = marks[item.status] .. " " .. clean(item.content),
			detail = item.status,
			preview = item_node(item),
		}
	end
	mare.ui.select({
		title = "Todos",
		title_right = M.summary(state.todos or {}),
		items = items,
		body = state.todos == nil and "No checklist has been written for this work"
			or #items == 0 and "No todos (explicitly cleared)"
			or nil,
	})
end
return M
