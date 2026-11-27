local M = {}

local QUOTE_PAIRS = {
	{ '"', '"' },
	{ "'", "'" },
	{ "`", "`" },
	{ "\226\128\156", "\226\128\157" },
	{ "\226\128\152", "\226\128\153" },
}

local function unwrap_quotes(line)
	for _, pair in ipairs(QUOTE_PAIRS) do
		local open, close = pair[1], pair[2]
		if #line >= #open + #close and line:sub(1, #open) == open and line:sub(-#close) == close then
			local inner = line:sub(#open + 1, -#close - 1)
			if not inner:find(open, 1, true) and (open == close or not inner:find(close, 1, true)) then
				return inner
			end
		end
	end
	return line
end

local function unwrap_emphasis(line)
	for _, marker in ipairs({ "***", "**", "*" }) do
		local len = #marker
		if #line > len * 2 and line:sub(1, len) == marker and line:sub(-len) == marker then
			local inner = line:sub(len + 1, -len - 1)
			if inner:match("^%S") and inner:match("%S$") and not inner:find(marker, 1, true) then
				return inner
			end
		end
	end
	return line
end

local function project_text(value)
	if type(value) == "string" and mare and mare.projection and type(mare.projection.project) == "function" then
		return mare.projection.project(value)
	end
	return value
end

local function plain_fallback_text(text)
	text = project_text(text)
	local trimmed = text:match("^%s*(.*)$") or ""
	if #trimmed > 4096 then
		trimmed = mare.text.cut(trimmed, 4096, { unit = "bytes" })
	end
	trimmed = trimmed:gsub("([^\r\n]+)", function(line)
		return (line:gsub("^%s*#+%s+", ""):gsub("^%s*>+%s*", ""))
	end)
	return trimmed
		:gsub("!?%[([^%]\r\n]*)%]%b()", "%1")
		:gsub("`([^`\r\n]+)`", "%1")
		:gsub("%*%*%*([^%*\r\n%s][^%*\r\n]-)%*%*%*", "%1")
		:gsub("%*%*([^%*\r\n%s][^%*\r\n]-)%*%*", "%1")
		:gsub("%*([^%*\r\n%s][^%*\r\n]-)%*", "%1")
end

function M.normalize(text, bytes)
	text = project_text(text)
	text = mare.text.sanitize(text):gsub("[%z\1-\31\127]", " ")
	-- Strip C1 controls and invisible/bidirectional formatting characters from terminal titles.
	text = text:gsub("\194[\128-\159\173]", " ")
		:gsub("\216\156", "")
		:gsub("\225\160\142", "")
		:gsub("\226\128[\139-\143\170-\174]", "")
		:gsub("\226\129[\160-\164\166-\175]", "")
		:gsub("\239\187\191", "")
	return mare.text.cut(text:gsub("%s+", " "):match("^%s*(.-)%s*$"), bytes, { unit = "bytes" }):gsub("%s+$", "")
end

function M.fallback(text, words, bytes)
	local out = {}
	local plain = plain_fallback_text(text)
	for word in M.normalize(plain, #plain):gmatch("%S+") do
		out[#out + 1] = word
		if #out == words then
			break
		end
	end
	return M.normalize(table.concat(out, " "), bytes)
end

function M.response(message, bytes)
	if message.stop_reason ~= "stop" then
		return nil, "title response did not finish normally"
	end
	local parts = {}
	for _, block in ipairs(message.content or {}) do
		if block.type == "tool_use" or block.type == "tool_call" then
			return nil, "title response contained a tool call"
		end
		if block.type == "text" then
			parts[#parts + 1] = block.text
		end
	end
	for raw_line in table.concat(parts, " "):gmatch("[^\r\n]+") do
		local line = raw_line:match("^%s*(.-)%s*$")
		if line ~= "" then
			line = unwrap_quotes(line):match("^%s*(.-)%s*$")
			line = unwrap_emphasis(line):gsub("[%.%?!]+$", "")
			local title = M.normalize(line, bytes)
			if title ~= "" then
				return title
			end
		end
	end
	return nil, "title response contained no text"
end

return M
