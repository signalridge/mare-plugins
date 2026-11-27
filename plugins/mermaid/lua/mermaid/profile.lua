local M = {}

local INLINE_ASPECT_CHROME_ROWS = 4
local INLINE_ASPECT_MIN = 4 / 3
local INLINE_ASPECT_MAX = 6.0
local INLINE_ASPECT_QUANT_STEP = 0.25
local INLINE_FIT_MIN_ROWS = 3
local INLINE_DIAGRAM_MAX_ROWS = 200
local RENDER_WIDTH_BUCKET_CELLS = 4

local function integer(value, low, high, name)
	assert(type(value) == "number" and value % 1 == 0 and value >= low and value <= high, "invalid " .. name)
	return value
end

local function number_in(value, low, high, name)
	assert(type(value) == "number" and value == value and value >= low and value <= high, "invalid " .. name)
	return value
end

local function split_statements(line)
	local out = {}
	local cur = {}
	local depth_sq, depth_pa, depth_br = 0, 0, 0
	local quote = nil
	local i, n = 1, #line
	while i <= n do
		local ch = line:sub(i, i)
		if quote then
			cur[#cur + 1] = ch
			if ch == "\\" and i < n then
				i = i + 1
				cur[#cur + 1] = line:sub(i, i)
			elseif ch == quote then
				quote = nil
			end
		else
			if ch == '"' or ch == "'" then
				quote = ch
				cur[#cur + 1] = ch
			elseif ch == "[" then
				depth_sq = depth_sq + 1
				cur[#cur + 1] = ch
			elseif ch == "]" and depth_sq > 0 then
				depth_sq = depth_sq - 1
				cur[#cur + 1] = ch
			elseif ch == "(" then
				depth_pa = depth_pa + 1
				cur[#cur + 1] = ch
			elseif ch == ")" and depth_pa > 0 then
				depth_pa = depth_pa - 1
				cur[#cur + 1] = ch
			elseif ch == "{" then
				depth_br = depth_br + 1
				cur[#cur + 1] = ch
			elseif ch == "}" and depth_br > 0 then
				depth_br = depth_br - 1
				cur[#cur + 1] = ch
			elseif ch == ";" and depth_sq == 0 and depth_pa == 0 and depth_br == 0 then
				local s = table.concat(cur):match("^%s*(.-)%s*$")
				if s ~= "" then
					out[#out + 1] = s
				end
				cur = {}
			else
				cur[#cur + 1] = ch
			end
		end
		i = i + 1
	end
	local tail = table.concat(cur):match("^%s*(.-)%s*$")
	if tail ~= "" then
		out[#out + 1] = tail
	end
	return out
end

local DIRECTIVE_PREFIXES = {
	"graph%s",
	"flowchart%s",
	"sequenceDiagram$",
	"classDiagram$",
	"stateDiagram",
	"erDiagram$",
	"gantt$",
	"pie$",
	"gitGraph$",
	"journey$",
	"mindmap$",
	"timeline$",
	"quadrantChart$",
	"requirementDiagram$",
	"C4Context$",
	"subgraph%s",
	"end$",
	"direction%s",
	"style%s",
	"classDef%s",
	"class%s",
	"linkStyle%s",
	"click%s",
	"accTitle",
	"accDescr",
	"title%s",
	"note%s",
	"Note%s",
	"loop%s",
	"alt%s",
	"else%s",
	"else$",
	"opt%s",
	"par%s",
	"and%s",
	"critical%s",
	"option%s",
	"break%s",
	"rect%s",
	"activate%s",
	"deactivate%s",
	"autonumber$",
}

local function is_directive_line(trimmed)
	for _, pat in ipairs(DIRECTIVE_PREFIXES) do
		if trimmed:match("^" .. pat) then
			return true
		end
	end
	return false
end

local ARROW_PATTERNS = {
	"^<<%-%->>[+-]?",
	"^<<%-%->[+-]?",
	"^%-%->>[+-]?",
	"^%-%->[+-]?",
	"^%->>[+-]?",
	"^%->[+-]?",
	"^<%-%->",
	"^<==>",
	"^%-%.-%>",
	"^%-%.%-",
	"^x%-%-x",
	"^o%-%-o",
	"^%-%-x",
	"^%-%-o",
	"^%-x",
	"^%-%)",
	"^%-%.%.",
	"^<|%-%-",
	"^%-%-|>",
	"^%.%.|>",
	"^<|%.%.",
	"^%.%.>",
	"^<%.%.",
	"^%*%-%-",
	"^%-%-%*",
	"^o%-%-",
	"^%-%-",
	"^==>",
	"^===",
	"^~~~",
	"^%-%->",
	"^%-%-%-",
	"^%.%.",
}

local function match_edge_operator(stmt, i)
	local sub = stmt:sub(i)
	-- ER cardinality relationships: e.g. ||--o{, }o..||, |o--|{
	local er = sub:match("^[|}o][|o][%-%.][%-%.][|{o][|o]")
	if er then
		return i + #er - 1
	end
	-- Labeled inline flowchart edges: -- text -->, -. text .->, == text ==>
	local lbl = sub:match("^%-%-[^%-\r\n]+%-%->")
		or sub:match("^%-%-[^%-\r\n]+%-%-%-")
		or sub:match("^%-%.[^%.\r\n]+%.%->")
		or sub:match("^==[^=\r\n]+==>")
	if lbl then
		return i + #lbl - 1
	end
	for _, pat in ipairs(ARROW_PATTERNS) do
		local m = sub:match(pat)
		if m then
			-- Skip optional |label| right after an arrow
			local after = sub:sub(#m + 1)
			local pipe_lbl = after:match("^|[^|\r\n]*|")
			return i + #m + (pipe_lbl and #pipe_lbl or 0) - 1
		end
	end
	return nil
end

local function extract_nodes_from_segment(seg, seen)
	local s = seg:match("^%s*(.-)%s*$")
	if s == "" then
		return 0
	end
	-- Strip trailing `: message` on sequence/class/ER/state lines outside brackets/quotes.
	local colon_cut
	local sq, pa, br, qt = 0, 0, 0, nil
	local i, n = 1, #s
	while i <= n do
		local ch = s:sub(i, i)
		if qt then
			if ch == "\\" and i < n then
				i = i + 2
			else
				if ch == qt then
					qt = nil
				end
				i = i + 1
			end
		else
			if ch == '"' or ch == "'" then
				qt = ch
			elseif ch == "[" then
				sq = sq + 1
			elseif ch == "]" and sq > 0 then
				sq = sq - 1
			elseif ch == "(" then
				pa = pa + 1
			elseif ch == ")" and pa > 0 then
				pa = pa - 1
			elseif ch == "{" then
				br = br + 1
			elseif ch == "}" and br > 0 then
				br = br - 1
			elseif ch == ":" and sq == 0 and pa == 0 and br == 0 then
				colon_cut = i
				break
			end
			i = i + 1
		end
	end
	if colon_cut then
		s = s:sub(1, colon_cut - 1):match("^%s*(.-)%s*$")
	end
	if s == "" then
		return 0
	end
	local count = 0
	for part in (s .. "&"):gmatch("([^&]*)&") do
		local p = part:match("^%s*(.-)%s*$")
		if p ~= "" then
			count = count + 1
			local id = p
			if p ~= "[*]" then
				id = p:match("^([%w_%.%-]+)") or p
			end
			if id ~= "" then
				seen[id] = true
			end
		end
	end
	return count
end

function M.estimate_diagram_size(source)
	local seen_nodes = {}
	local edges = 0
	for line in (source .. "\n"):gmatch("([^\r\n]*)\r?\n") do
		local trimmed = line:match("^%s*(.-)%s*$")
		if trimmed ~= "" and not trimmed:match("^%%%%") then
			for _, stmt in ipairs(split_statements(trimmed)) do
				if not is_directive_line(stmt) then
					local part_decl = stmt:match("^participant%s+([%w_%.%-]+)") or stmt:match("^actor%s+([%w_%.%-]+)")
					if part_decl then
						seen_nodes[part_decl] = true
					else
						local segments = {}
						local seg_start = 1
						local sq, pa, br, qt = 0, 0, 0, nil
						local i, n = 1, #stmt
						while i <= n do
							local ch = stmt:sub(i, i)
							if qt then
								if ch == "\\" and i < n then
									i = i + 2
								else
									if ch == qt then
										qt = nil
									end
									i = i + 1
								end
							elseif ch == '"' or ch == "'" then
								qt = ch
								i = i + 1
							elseif ch == "[" then
								-- Treat [*] as an atomic state node, not bracket wrapper
								if stmt:sub(i, i + 2) == "[*]" then
									i = i + 3
								else
									sq = sq + 1
									i = i + 1
								end
							elseif ch == "]" and sq > 0 then
								sq = sq - 1
								i = i + 1
							elseif ch == "(" then
								pa = pa + 1
								i = i + 1
							elseif ch == ")" and pa > 0 then
								pa = pa - 1
								i = i + 1
							elseif ch == "{" then
								br = br + 1
								i = i + 1
							elseif ch == "}" and br > 0 then
								br = br - 1
								i = i + 1
							elseif sq == 0 and pa == 0 and br == 0 then
								local op_end = match_edge_operator(stmt, i)
								if op_end then
									segments[#segments + 1] = stmt:sub(seg_start, i - 1)
									seg_start = op_end + 1
									i = op_end + 1
								else
									i = i + 1
								end
							else
								i = i + 1
							end
						end
						segments[#segments + 1] = stmt:sub(seg_start)
						local counts = {}
						for idx, seg in ipairs(segments) do
							counts[idx] = extract_nodes_from_segment(seg, seen_nodes)
						end
						for idx = 1, #segments - 1 do
							local l = math.max(1, counts[idx] or 0)
							local r = math.max(1, counts[idx + 1] or 0)
							edges = edges + (l * r)
						end
					end
				end
			end
		end
	end
	local nodes = 0
	for _ in pairs(seen_nodes) do
		nodes = nodes + 1
	end
	return {
		nodes = nodes,
		edges = edges,
		complexity = math.max(nodes, 2) + math.max(edges, 1),
	}
end

function M.normalize_aspect_ratio(ratio)
	if type(ratio) ~= "number" or ratio ~= ratio or ratio <= 0 or ratio == math.huge then
		return nil
	end
	local clamped = math.max(0.1, math.min(10.0, ratio))
	return math.floor(clamped * 1000 + 0.5)
end

function M.inline_aspect_goal(width, height, cell)
	if type(width) ~= "number" or type(height) ~= "number" or width <= 0 or height <= 0 or type(cell) ~= "table" then
		return nil
	end
	local cell_w = math.max(1, cell[1] or 0)
	local cell_h = math.max(1, cell[2] or 0)
	local avail_cells = math.max(1, width - 2)
	local width_px = avail_cells * cell_w
	local goal_rows =
		math.max(INLINE_FIT_MIN_ROWS, math.min(INLINE_DIAGRAM_MAX_ROWS, height - INLINE_ASPECT_CHROME_ROWS))
	local height_px = goal_rows * cell_h
	local raw = math.max(INLINE_ASPECT_MIN, math.min(INLINE_ASPECT_MAX, width_px / height_px))
	local quantized = math.floor(raw / INLINE_ASPECT_QUANT_STEP + 0.5) * INLINE_ASPECT_QUANT_STEP
	return math.max(INLINE_ASPECT_MIN, math.min(INLINE_ASPECT_MAX, quantized))
end

function M.bucket_width(width)
	local w = math.max(4, math.floor(width))
	return math.floor((w + RENDER_WIDTH_BUCKET_CELLS - 1) / RENDER_WIDTH_BUCKET_CELLS) * RENDER_WIDTH_BUCKET_CELLS
end

function M.layout_config(cfg, source)
	local est = source and M.estimate_diagram_size(source) or { complexity = 0 }
	local spacing_factor = est.complexity > 30 and 1.2 or 1.0
	return {
		node_spacing = math.floor((cfg.node_spacing or 80) * spacing_factor + 0.5),
		rank_spacing = math.floor((cfg.rank_spacing or 80) * spacing_factor + 0.5),
		node_padding_x = cfg.node_padding_x or 40,
		node_padding_y = cfg.node_padding_y or 20,
	}
end

local PROFILE_KEYS = {
	size_px = true,
	scale = true,
	theme = true,
	background = true,
	aspect_per_mille = true,
	node_spacing = true,
	rank_spacing = true,
	node_padding_x = true,
	node_padding_y = true,
}

function M.validate(profile)
	assert(type(profile) == "table", "invalid Mermaid profile")
	for key in pairs(profile) do
		assert(PROFILE_KEYS[key], "unknown Mermaid profile field")
	end
	integer(profile.size_px, 64, 2048, "size_px")
	assert(profile.scale == 1 or profile.scale == 2, "scale must be 1 or 2")
	assert(profile.theme == "dark" or profile.theme == "default", "invalid Mermaid theme")
	assert(
		type(profile.background) == "string"
			and (profile.background == "transparent" or profile.background:match("^#%x%x%x%x%x%x$")),
		"invalid background"
	)
	if profile.aspect_per_mille ~= nil then
		integer(profile.aspect_per_mille, 100, 10000, "aspect_per_mille")
	end
	if profile.node_spacing ~= nil then
		number_in(profile.node_spacing, 10, 480, "node_spacing")
	end
	if profile.rank_spacing ~= nil then
		number_in(profile.rank_spacing, 10, 480, "rank_spacing")
	end
	if profile.node_padding_x ~= nil then
		number_in(profile.node_padding_x, 4, 200, "node_padding_x")
	end
	if profile.node_padding_y ~= nil then
		number_in(profile.node_padding_y, 4, 200, "node_padding_y")
	end
	return profile
end

function M.new(cfg, request)
	request = request or {}
	local caps = request.capabilities or mare.ui.caps()
	local theme = request.theme or {}
	local background = theme.code_background or mare.ui.style("MareCodeBlock").bg
	if type(background) ~= "string" or not background:match("^#%x%x%x%x%x%x$") then
		background = "transparent"
	end
	local dark = theme.appearance ~= "light"
	if background ~= "transparent" then
		local function linear(n)
			n = n / 255
			return n <= 0.04045 and n / 12.92 or ((n + 0.055) / 1.055) ^ 2.4
		end
		local r, g, b =
			tonumber(background:sub(2, 3), 16), tonumber(background:sub(4, 5), 16), tonumber(background:sub(6, 7), 16)
		dark = 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b) < 0.1791
	end
	local width = request.width or mare.ui.width()
	local height = request.height or (mare.ui.height and mare.ui.height()) or cfg.max_rows
	local bucketed = M.bucket_width(math.min(width, cfg.max_cols))
	local cell = caps.cell_px or { 8, 16 }
	local preferred_aspect = (cfg.preferred_aspect_ratio and cfg.preferred_aspect_ratio > 0)
			and cfg.preferred_aspect_ratio
		or M.inline_aspect_goal(width, height, cell)
	local aspect_per_mille = M.normalize_aspect_ratio(preferred_aspect)
	local avail_w_px = bucketed * cell[1]
	local target_h_px = aspect_per_mille and math.floor(avail_w_px / (aspect_per_mille / 1000))
		or (cfg.max_rows * cell[2])
	local zoom_factor = (request.zoom_percent and request.zoom_percent > 100) and (request.zoom_percent / 100) or 1
	local pixels = math.max(avail_w_px, target_h_px, cfg.max_rows * cell[2]) * zoom_factor
	local layout = M.layout_config(cfg, request.source)
	return M.validate({
		size_px = math.floor(math.max(64, math.min(cfg.max_pixels, pixels))),
		scale = cfg.scale,
		theme = dark and "dark" or "default",
		background = background,
		aspect_per_mille = aspect_per_mille,
		node_spacing = layout.node_spacing,
		rank_spacing = layout.rank_spacing,
		node_padding_x = layout.node_padding_x,
		node_padding_y = layout.node_padding_y,
	})
end

function M.key(cfg, source, profile)
	return mare.crypto.sha256(
		mare.json.encode({ "mermaid-adapter-v1", cfg.command, cfg.node, cfg.renderer_script, source, profile })
	)
end

--- Insert or refresh an entry in a bounded insertion-ordered map (LRU eviction).
function M.lru_set(order, map, key, value, limit)
	map[key] = value
	for index = #order, 1, -1 do
		if order[index] == key then
			table.remove(order, index)
		end
	end
	order[#order + 1] = key
	while #order > limit do
		map[table.remove(order, 1)] = nil
	end
end

return M
