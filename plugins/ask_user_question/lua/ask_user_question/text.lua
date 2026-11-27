local M = {}
-- Existing text is explicit and editable without requiring a private editor API.
function M.edit(title, previous, cancel)
	if previous then
		local i, tab_or_reason = mare.ui.select({
			title = title,
			body = "Current text is shown in the preview.",
			cancel = cancel,
			items = {
				{ label = "Replace text", preview = mare.ui.Code(previous) },
				{ label = "Clear text" },
				{ label = "Keep text" },
			},
		})
		if cancel and cancel:is_cancelled() then
			return nil, "cancelled"
		end
		local reason = (i == nil) and tab_or_reason or nil
		if reason and reason ~= "cancelled" then
			return nil, reason
		end
		if i == nil and not mare.ui.can_respond() then
			return nil, "disconnected"
		end
		if i ~= nil and i ~= 1 and i ~= 2 and i ~= 3 then
			return nil, "invalid_ui_answer"
		end
		if not i or i == 3 then
			return previous
		end
		if i == 2 then
			return nil
		end
	end
	local value, reason = mare.ui.input({ title = title, placeholder = "Your answer or notes", cancel = cancel })
	if cancel and cancel:is_cancelled() then
		return nil, "cancelled"
	end
	if reason and reason ~= "cancelled" then
		return nil, reason
	end
	if value == nil then
		if reason == nil and not mare.ui.can_respond() then
			return nil, "disconnected"
		end
		return previous
	end
	if type(value) ~= "string" then
		return nil, "invalid_ui_answer"
	end
	if not value:match("%S") then
		return nil
	end
	if not utf8.len(value) or utf8.len(value) > 10000 then
		mare.ui.notify("Text must be valid UTF-8 and at most 10000 characters", "warning")
		return previous
	end
	return value
end
return M
