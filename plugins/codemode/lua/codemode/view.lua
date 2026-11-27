local COMPACT_PREVIEW_LINES = 8
local SUMMARY_MAX_CHARS = 48

local M = {}

local function first_code_line(input)
	if type(input) ~= "string" then
		return "(script)"
	end
	for line in input:gmatch("[^\r\n]+") do
		local trimmed = line:match("^%s*(.-)%s*$")
		if trimmed ~= "" and not trimmed:match("^%-%-%s*@exec:") then
			local len = utf8.len(trimmed)
			if (len or #trimmed) > SUMMARY_MAX_CHARS then
				local cut = mare
					and mare.text
					and mare.text.cut
					and mare.text.cut(trimmed, SUMMARY_MAX_CHARS - 3, { unit = "chars" })
				if type(cut) == "string" then
					return cut .. "..."
				end
				return trimmed:sub(1, SUMMARY_MAX_CHARS - 3) .. "..."
			end
			return trimmed
		end
	end
	return "(script)"
end

local function collect_text(blocks)
	if type(blocks) ~= "table" then
		return ""
	end
	local parts = {}
	for _, block in ipairs(blocks) do
		if type(block) == "table" and block.type == "text" and type(block.text) == "string" and block.text ~= "" then
			parts[#parts + 1] = block.text
		end
	end
	return table.concat(parts, "\n"):gsub("[\r\n]+$", "")
end

function M.summary(name, args)
	args = args or {}
	if name == "codemode_wait" then
		local id = tostring(args.cell_id or "")
		if args.terminate then
			return ("codemode_wait(%s, terminate)"):format(id)
		end
		return ("codemode_wait(%s)"):format(id)
	end
	return ("codemode(%s)"):format(first_code_line(args.input))
end

function M.render(name, args, result, expanded)
	args = args or {}
	if not result then
		local action = name == "codemode_wait" and (args.terminate and "terminating" or "waiting") or "running"
		return mare.ui.Spinner(name .. " · " .. action)
	end
	if result.is_error or result.cancelled then
		return nil
	end
	local d = type(result.details) == "table" and result.details or {}
	local status = d.status or "completed"
	local header = name .. " · " .. status
	if d.cell_id and status == "running" then
		header = header .. " · " .. tostring(d.cell_id)
	end
	local nodes = { mare.ui.Paragraph(header) }
	if expanded and name == "codemode" and type(args.input) == "string" and args.input ~= "" then
		nodes[#nodes + 1] = mare.ui.Code(args.input, "lua")
	end
	local text = collect_text(d.content)
	if text ~= "" then
		local code = mare.ui.Code(text, "text")
		nodes[#nodes + 1] = expanded and code or mare.ui.Clip(code, COMPACT_PREVIEW_LINES, true)
	end
	return mare.ui.Lines(nodes)
end

return M
