local M = {}
M.validate = require("ask_user_question.validate").validate
local function empty(status, message)
	return { status = status, answers = mare.json.array({}), message = message }
end
function M.ask(qs, cancel, restored, save)
	cancel = cancel or mare.task.token()
	if mare.mode == "child" then
		return empty("unavailable", "Nobody can answer in this child agent. Report the question to the parent agent.")
	end
	if not mare.ui.can_respond() then
		return empty("unavailable", "Nobody can answer: no interactive responder is available.")
	end
	local drafts = restored and restored.drafts or {}
	for i in ipairs(qs) do
		drafts[i] = drafts[i] or { selected = {} }
	end
	local position = restored and restored.position or 1
	local reviewing = false
	local function changed()
		if save then
			save({ drafts = drafts, position = position })
		end
	end
	while true do
		if cancel:is_cancelled() then
			return empty("cancelled", "The question call was cancelled; no answers were submitted.")
		end
		if not mare.ui.can_respond() then
			return empty("disconnected", "The interactive responder disconnected; no answers were submitted.")
		end
		if position <= #qs then
			local outcome =
				require("ask_user_question.editor").edit(qs[position], drafts[position], position, #qs, cancel, changed)
			if outcome == "next" then
				position = reviewing and #qs + 1 or position + 1
				reviewing = false
			elseif outcome == "back" then
				position = math.max(1, position - 1)
			elseif outcome == "review" then
				position = #qs + 1
			else
				return empty(
					outcome,
					outcome == "dismissed" and "The user dismissed the questions; no answers were submitted."
						or "No answers were submitted: " .. outcome
				)
			end
			changed()
		else
			local rows, missing, skipped = {}, 0, 0
			for i, q in ipairs(qs) do
				local d = drafts[i]
				if not d.status then
					missing = missing + 1
				elseif d.status == "skipped" then
					skipped = skipped + 1
				end
				local labels = {}
				for n, o in ipairs(q.options) do
					if d.selected[n] then
						labels[#labels + 1] = o.label
					end
				end
				if d.custom then
					labels[#labels + 1] = d.custom
				end
				rows[i] = {
					label = q.header .. " — " .. (d.status or "unanswered"),
					detail = table.concat(labels, "; "),
					preview = mare.ui.Code(q.question),
				}
			end
			rows[#qs + 1] = {
				label = "Submit answers",
				disabled = missing > 0,
				detail = missing > 0 and "Answer or explicitly skip every question." or nil,
			}
			rows[#qs + 2] = { label = "Dismiss questions" }
			local index, tab_or_reason = mare.ui.select({
				title = "Review questions",
				body = "Review or edit answers before submitting.",
				items = rows,
				cancel = cancel,
				selected = #qs + 1,
			})
			if cancel:is_cancelled() then
				return empty("cancelled", "The question call was cancelled; no answers were submitted.")
			end
			if not index then
				local reason = tab_or_reason
				if reason == "cancelled" then
					reason = mare.ui.can_respond() and "dismissed" or "disconnected"
				end
				return empty(
					reason or (mare.ui.can_respond() and "dismissed" or "disconnected"),
					"No answers were submitted."
				)
			end
			if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #rows or rows[index].disabled then
				return empty("invalid_ui_answer", "The UI returned an invalid answer.")
			elseif index <= #qs then
				position = index
				reviewing = true
			elseif index == #qs + 2 then
				return empty("dismissed", "The user dismissed the questions; no answers were submitted.")
			elseif index == #qs + 1 and missing == 0 then
				local confirmed = true
				if skipped > 0 then
					local choice, skip_tab_or_reason = mare.ui.select({
						title = "Submit with skipped questions?",
						body = ("%d question(s) were explicitly skipped."):format(skipped),
						items = { "Return to review", "Submit answers" },
						cancel = cancel,
					})
					if cancel:is_cancelled() then
						return empty("cancelled", "The question call was cancelled; no answers were submitted.")
					end
					local reason = (choice == nil) and skip_tab_or_reason or nil
					if reason and reason ~= "cancelled" then
						return empty(reason, "No answers were submitted.")
					end
					if choice == nil and not mare.ui.can_respond() then
						return empty(
							"disconnected",
							"The interactive responder disconnected; no answers were submitted."
						)
					end
					if choice ~= nil and choice ~= 1 and choice ~= 2 then
						return empty("invalid_ui_answer", "The UI returned an invalid confirmation.")
					end
					confirmed = choice == 2
				end
				if confirmed then
					local answers = mare.json.array({})
					for i, q in ipairs(qs) do
						local selected = mare.json.array({})
						for n, o in ipairs(q.options) do
							if drafts[i].selected[n] then
								selected[#selected + 1] = o.label
							end
						end
						answers[#answers + 1] = { id = q.id, selected = selected, custom = drafts[i].custom }
					end
					return { status = "answered", answers = answers }
				end
			else
				return empty("invalid_ui_answer", "The UI returned an invalid answer.")
			end
		end
	end
end
return M
