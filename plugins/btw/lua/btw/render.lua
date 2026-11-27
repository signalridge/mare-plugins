-- Parked-side indicator and on-demand scrollable transcript viewer.
return function(ctx, cfg, tracker)
	local function parked_label(status)
		local parts = { "Side parked" }
		if status.busy then
			parts[#parts + 1] = "busy"
		end
		local p = status.parent_status
		if type(p) == "table" and p.state and p.state ~= "finished" and p.state ~= "working" then
			parts[#parts + 1] = "parent " .. p.state .. (p.detail and (" (" .. p.detail .. ")") or "")
		end
		parts[#parts + 1] = "/side close to discard"
		return table.concat(parts, " · ")
	end

	ctx.ui:widget("btw:parked", {
		slot = "above-editor",
		order = 90,
		render = function(_, height)
			if not cfg.show_parked_status or (height and height <= 0) then
				return mare.ui.Lines({})
			end
			local status = tracker.status()
			if not status.open or not status.parked then
				return mare.ui.Lines({})
			end
			return mare.ui.Lines({ mare.ui.Line(parked_label(status)) })
		end,
	})

	ctx.ui:status("btw", {
		align = "right",
		order = 120,
		render = function()
			if not cfg.show_parked_status then
				return nil
			end
			local status = tracker.status()
			if not status.open or not status.parked then
				return nil
			end
			return mare.ui.Span(status.busy and "side busy" or "side parked")
		end,
	})

	local M = {}

	function M.invalidate()
		ctx.ui:invalidate("btw:parked")
		ctx.ui:invalidate("btw")
	end

	function M.format_markdown(status, transcript)
		local lines = {}
		local header = {}
		if status.model then
			header[#header + 1] = "Model: `" .. status.model .. "`"
		end
		if type(status.parent_status) == "table" and status.parent_status.state then
			local detail = status.parent_status.detail
			header[#header + 1] = "Parent: `"
				.. status.parent_status.state
				.. "`"
				.. (detail and (" (" .. detail .. ")") or "")
		end
		if #header > 0 then
			lines[#lines + 1] = table.concat(header, " · ")
		end

		local function append_turn(label, turn)
			lines[#lines + 1] = "### " .. label
			if turn.prompt and turn.prompt ~= "" then
				lines[#lines + 1] = "**User:** " .. turn.prompt
			end
			for _, tool in ipairs(turn.tools or {}) do
				local tag = tool.is_error and "error" or (tool.done and "done" or "running")
				lines[#lines + 1] = "- Tool `" .. tool.name .. "` (" .. tag .. ")"
			end
			if turn.text and turn.text ~= "" then
				lines[#lines + 1] = turn.text
			end
			if turn.error then
				lines[#lines + 1] = "Error: " .. turn.error
			end
		end

		local turns = transcript and transcript.turns or {}
		for i, turn in ipairs(turns) do
			append_turn("Turn " .. tostring(i), turn)
		end
		if transcript and transcript.streaming then
			append_turn("Streaming", transcript.streaming)
		end
		if transcript and transcript.truncated then
			lines[#lines + 1] = "_Transcript truncated to byte budget._"
		end
		if #turns == 0 and not (transcript and transcript.streaming) then
			lines[#lines + 1] = "Ready for a side question."
		end
		return table.concat(lines, "\n\n")
	end

	function M.view()
		local status = tracker.status()
		if not status.open then
			mare.ui.notify("No side conversation is open; use /side [question]", "info")
			return false
		end
		local transcript = tracker.transcript()
		local title = "Side conversation · " .. (status.model or "side")
		mare.ui.overlay(title, mare.ui.Markdown(M.format_markdown(status, transcript)))
		return true
	end

	return M
end
