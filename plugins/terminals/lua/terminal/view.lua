-- Tool cards consume only public safe-text/structured results; raw PTY bytes never reach UI.
local COMPACT_PREVIEW_LINES = 8
local COMPACT_ERROR_LINES = 4

local function trim_trailing_newlines(text)
	return (text:gsub("[\r\n]+$", ""))
end

local function append_exit_meta(parts, d)
	if d.alternate_screen then
		parts[#parts + 1] = "alt-screen"
	end
	if d.exit_signal then
		parts[#parts + 1] = "signal " .. tostring(d.exit_signal)
	elseif d.exit_code ~= nil then
		parts[#parts + 1] = "exit " .. tostring(d.exit_code)
	elseif d.command_exit_code ~= nil then
		parts[#parts + 1] = "cmd " .. tostring(d.command_exit_code)
	end
	if d.stop_unconfirmed then
		parts[#parts + 1] = "stop_unconfirmed"
	end
end

return function(name, args, result, expanded)
	args = args or {}
	if not result then
		return mare.ui.Spinner(name .. " · " .. (args.session_id or args.name or args.type or "opening"))
	end
	if result.is_error or result.cancelled then
		local msg = trim_trailing_newlines(tostring(result.content or "cancelled"))
		local node = mare.ui.Paragraph(mare.ui.Line({ mare.ui.Span(name .. " failed: ", "error"), msg }))
		return expanded and node or mare.ui.Clip(node, COMPACT_ERROR_LINES, false)
	end
	local d = result.details
	if type(d) ~= "table" then
		return mare.ui.Paragraph(tostring(result.content or ""))
	end
	local parts = { name, d.name or d.session_id or "owned terminals" }
	local state = d.wait_reason or d.status or (d.delivered and "signal delivered") or (d.stopped and "closed")
	if state then
		parts[#parts + 1] = state
	end
	if d.job_id then
		parts[#parts + 1] = d.job_id
	end
	append_exit_meta(parts, d)
	local nodes = { mare.ui.Paragraph(table.concat(parts, " · ")) }
	local raw_text = expanded and (d.text or d.screen or d.output) or (d.output or d.text or d.screen)
	local text = type(raw_text) == "string" and trim_trailing_newlines(raw_text) or nil
	if text and text ~= "" then
		local code = mare.ui.Code(text, "text")
		nodes[#nodes + 1] = expanded and code or mare.ui.Clip(code, COMPACT_PREVIEW_LINES, true)
	end
	if expanded and d.alternate_screen and type(d.screen) == "string" then
		local screen = trim_trailing_newlines(d.screen)
		if screen ~= "" and screen ~= text then
			nodes[#nodes + 1] = mare.ui.Paragraph(mare.ui.Span("Alternate screen viewport", "muted"))
			nodes[#nodes + 1] = mare.ui.Code(screen, "text")
		end
	end
	if d.truncated or (type(d.dropped_lines) == "number" and d.dropped_lines > 0) then
		local notice = type(d.dropped_lines) == "number"
				and d.dropped_lines > 0
				and ("Older output was truncated (" .. tostring(d.dropped_lines) .. " lines dropped)")
			or "Older output was truncated"
		nodes[#nodes + 1] = mare.ui.Paragraph(mare.ui.Span(notice, "muted"))
	end
	if d.sessions then
		if #d.sessions == 0 then
			nodes[#nodes + 1] = mare.ui.Paragraph(mare.ui.Span("No active terminal sessions", "muted"))
		else
			local session_nodes = {}
			for _, session in ipairs(d.sessions) do
				local s_parts = { session.name or session.session_id, session.status }
				if session.type then
					s_parts[#s_parts + 1] = session.type
				end
				append_exit_meta(s_parts, session)
				session_nodes[#session_nodes + 1] = mare.ui.Paragraph(table.concat(s_parts, " · "))
			end
			local list_node = mare.ui.Lines(session_nodes)
			nodes[#nodes + 1] = (expanded or #session_nodes <= COMPACT_PREVIEW_LINES) and list_node
				or mare.ui.Clip(list_node, COMPACT_PREVIEW_LINES, false)
		end
	end
	return mare.ui.Lines(nodes)
end
