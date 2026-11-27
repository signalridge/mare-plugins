local M = {}

local FIELD_TYPES = {}
for k, t in
	("description=string,system=string,prefix=string,suffix=string,name=string,model=string,order=number,complete=boolean,includeRuntimeContext=boolean,default=boolean,tools=table,denylist=table"):gmatch(
		"(%a+)=(%a+)"
	)
do
	FIELD_TYPES[k] = t
end

local RESERVED_IDS = { clear = true, list = true, inspect = true, default = true, stage = true, help = true }

local function validate_tool_list(value, field)
	local set, list, count = {}, {}, 0
	for index, name in pairs(value) do
		assert(
			type(index) == "number" and index % 1 == 0 and index > 0 and type(name) == "string" and name ~= "",
			"preset " .. field .. " must be a string list"
		)
		count = count + 1
		if not set[name] then
			set[name] = true
			list[#list + 1] = name
		end
	end
	assert(count == #value, "preset " .. field .. " must be a dense list")
	return set, list
end

function M.build_broken_lines(reason, def)
	local lines = { "Broken: " .. reason }
	if type(def) ~= "table" then
		if def ~= nil then
			lines[2] = "Raw: " .. tostring(def)
		end
		return lines
	end
	local fields = {}
	for k, v in pairs(def) do
		local rendered = type(v) ~= "table" and tostring(v) or "{...}"
		if type(v) == "table" and #v > 0 then
			local items = {}
			for i = 1, #v do
				items[i] = tostring(v[i])
			end
			rendered = table.concat(items, ", ")
		end
		fields[#fields + 1] = tostring(k) .. ": " .. rendered
	end
	table.sort(fields)
	for _, f in ipairs(fields) do
		lines[#lines + 1] = f
	end
	return lines
end

function M.validate(id, def)
	assert(type(id) == "string" and id:match("^[%w][%w_-]*$") and not RESERVED_IDS[id], "invalid or reserved preset id")
	assert(type(def) == "table", "preset definition must be a table")
	for key, val in pairs(def) do
		local expected = FIELD_TYPES[key]
		assert(expected, "unsupported preset field: " .. tostring(key))
		assert(type(val) == expected, "preset " .. key .. " must be " .. expected)
	end
	assert(def.model == nil or def.model ~= "", "preset model must be a nonempty ref")
	assert(
		def.order == nil or (def.order == def.order and math.abs(def.order) < math.huge),
		"preset order must be finite"
	)
	if def.complete == true then
		assert(
			(def.prefix and def.prefix ~= "") or (def.system and def.system ~= ""),
			"preset complete requires prefix or system"
		)
	end
	local out = {
		revision = 0,
		description = def.description,
		name = def.name or id,
		order = def.order or 0,
		system = def.system or "",
		prefix = def.prefix,
		suffix = def.suffix,
		complete = def.complete == true,
		includeRuntimeContext = def.includeRuntimeContext ~= false,
		default = def.default == true,
		model = def.model,
	}
	if def.tools ~= nil then
		out.tools, out.tools_list = validate_tool_list(def.tools, "tools")
	end
	if def.denylist ~= nil then
		out.denylist, out.denylist_list = validate_tool_list(def.denylist, "denylist")
	end
	return out
end

function M.copy(value)
	if type(value) ~= "table" then
		return value
	end
	local result = {}
	for key, item in pairs(value) do
		result[key] = M.copy(item)
	end
	return result
end

local function match_glob(name, pattern)
	if not pattern:find("[*?]") then
		return name == pattern
	end
	local lua_pat = "^"
		.. pattern:gsub("([%^%$%(%)%%%.%[%]%+%-%?%*])", function(ch)
			return ({ ["*"] = ".*", ["?"] = "." })[ch] or ("%" .. ch)
		end)
		.. "$"
	return name:match(lua_pat) ~= nil
end

function M.matches_any(name, list)
	for _, pattern in ipairs(list) do
		if match_glob(name, pattern) then
			return true
		end
	end
	return false
end

function M.build_sections(def)
	local sections = {}
	if def.prefix ~= nil then
		sections[#sections + 1] = {
			name = "persona",
			tag = "preamble",
			order = 0,
			raw = true,
			scope = "agent",
			complete = def.complete or nil,
			interpolate = true,
			text = def.prefix,
		}
	end
	if def.suffix ~= nil then
		sections[#sections + 1] = {
			name = "persona_suffix",
			tag = "addendum",
			order = 800,
			scope = "agent",
			interpolate = true,
			text = def.suffix,
		}
	end
	if def.system ~= "" then
		sections[#sections + 1] = {
			name = "presets:guidance",
			order = 1600,
			interpolate = false,
			complete = (def.complete and def.prefix == nil) or nil,
			text = def.system,
		}
	end
	return sections
end

function M.format_definition_lines(def, default_flag, staged_flag)
	local lines = {
		"Model: " .. (def.model or "current"),
		"Tools: " .. (def.tools_list and table.concat(def.tools_list, ", ") or "unchanged"),
	}
	local opt = {
		def.denylist_list and ("Denylist: " .. table.concat(def.denylist_list, ", ")) or false,
		default_flag and "Default: yes" or false,
		staged_flag and "Staged: yes" or false,
		def.prefix ~= nil and ("Prefix: " .. def.prefix) or false,
		def.suffix ~= nil and ("Suffix: " .. def.suffix) or false,
		def.complete and "Complete: yes" or false,
		not def.includeRuntimeContext and "Runtime context: suppressed" or false,
		def.system ~= "" and def.system or false,
	}
	for i = 1, #opt do
		if opt[i] then
			lines[#lines + 1] = opt[i]
		end
	end
	return lines
end

function M.format_badges(row)
	return (row.current and " (current)" or "")
		.. (row.default and " (default)" or "")
		.. (row.staged and " (staged)" or "")
end

return M
