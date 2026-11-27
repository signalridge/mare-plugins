local M = {}
function M.edit(q, draft, position, total, cancel, changed)
	local cursor = 1
	for i, o in ipairs(q.options) do
		if o.recommended then
			cursor = i
		end
	end
	while true do
		if cancel:is_cancelled() then
			return "cancelled"
		end
		if not mare.ui.can_respond() then
			return "disconnected"
		end
		local rows, actions = {}, {}
		local function row(item, action)
			rows[#rows + 1] = item
			actions[#rows] = action
		end
		for i, o in ipairs(q.options) do
			row({
				label = (draft.selected[i] and "[x] " or "[ ] ")
					.. o.label
					.. (o.recommended and " ★ Recommended" or ""),
				detail = o.description,
				preview = o.preview and mare.ui.Code(o.preview) or nil,
			}, { kind = "option", index = i })
		end
		row({ label = "Other — write an answer", detail = draft.custom }, { kind = "other" })
		row({
			label = draft.custom and "Edit notes" or "Add notes",
			detail = "Include details alongside a selected option.",
		}, { kind = "notes" })
		row({ label = "Done", disabled = not next(draft.selected) and not draft.custom }, { kind = "done" })
		row({ label = "Skip this question" }, { kind = "skip" })
		if position > 1 then
			row({ label = "Previous question" }, { kind = "back" })
		end
		row({ label = "Review questions" }, { kind = "review" })
		row({ label = "Dismiss questions" }, { kind = "dismissed" })
		local index, tab_or_reason = mare.ui.select({
			title = ("%d/%d %s"):format(position, total, q.header),
			body = q.question,
			items = rows,
			selected = cursor,
			cancel = cancel,
		})
		if cancel:is_cancelled() then
			return "cancelled"
		end
		if not index then
			local reason = tab_or_reason
			if reason == "cancelled" then
				reason = mare.ui.can_respond() and "dismissed" or "disconnected"
			end
			return reason or (mare.ui.can_respond() and "dismissed" or "disconnected")
		end
		local action = actions[index]
		-- a disabled row (Done with nothing chosen) is not a valid answer from any UI
		if not action or rows[index].disabled then
			return "invalid_ui_answer"
		end
		cursor = index
		if action.kind == "option" then
			if q.multi_select then
				draft.selected[action.index] = not draft.selected[action.index] or nil
			else
				draft.selected = { [action.index] = true }
			end
			draft.status = (next(draft.selected) or draft.custom) and "answered" or nil
			changed()
			if not q.multi_select then
				return "next"
			end
		elseif action.kind == "other" or action.kind == "notes" then
			local value, err = require("ask_user_question.text").edit(
				q.header .. " — " .. (action.kind == "other" and "Other" or "Notes"),
				draft.custom,
				cancel
			)
			if cancel:is_cancelled() then
				return "cancelled"
			end
			if err then
				return err
			end
			if value and action.kind == "other" and not q.multi_select then
				draft.selected = {}
			end
			draft.custom = value
			draft.status = (next(draft.selected) or value) and "answered" or nil
			changed()
			if action.kind == "other" and value and not q.multi_select then
				return "next"
			end
		elseif action.kind == "done" then
			if next(draft.selected) or draft.custom then
				draft.status = "answered"
				changed()
				return "next"
			end
		elseif action.kind == "skip" then
			draft.selected = {}
			draft.custom = nil
			draft.status = "skipped"
			changed()
			return "next"
		else
			return action.kind
		end
	end
end
return M
