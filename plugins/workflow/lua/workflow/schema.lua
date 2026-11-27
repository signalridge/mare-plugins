local M = {}

local ALLOWED_KEYWORDS = {
	type = true,
	properties = true,
	required = true,
	additionalProperties = true,
	items = true,
	enum = true,
	const = true,
	oneOf = true,
}

local VALID_TYPES = {
	object = true,
	array = true,
	string = true,
	number = true,
	integer = true,
	boolean = true,
	null = true,
}

local function json_null()
	return mare and mare.json and mare.json.null or nil
end

local function is_null(v)
	local jn = json_null()
	return v == nil or (jn ~= nil and v == jn)
end

local ARRAY_MT = mare and mare.json and type(mare.json.array) == "function" and getmetatable(mare.json.array({})) or nil

local function has_array_marker(t)
	if type(t) ~= "table" then
		return false
	end
	if mare and mare.json and type(mare.json.is_array) == "function" then
		return mare.json.is_array(t) == true
	end
	if ARRAY_MT ~= nil and getmetatable(t) == ARRAY_MT then
		return true
	end
	return false
end

local function is_plain_table(t)
	if type(t) ~= "table" then
		return false
	end
	if has_array_marker(t) then
		return false
	end
	return true
end

local function is_array_table(t)
	if type(t) ~= "table" then
		return false
	end
	if has_array_marker(t) then
		return true
	end
	-- An unmarked empty table `{}` is a JSON object, never an empty JSON array `[]`.
	if next(t) == nil then
		return false
	end
	local count = 0
	for k in pairs(t) do
		if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then
			return false
		end
		count = count + 1
	end
	return count == #t
end

local function check_type_decl(t, path)
	if type(t) == "string" then
		if not VALID_TYPES[t] then
			error(("%s.type: unsupported type %q"):format(path, t), 0)
		end
		return
	end
	if type(t) == "table" and is_array_table(t) and #t > 0 then
		for i, item in ipairs(t) do
			if type(item) ~= "string" or not VALID_TYPES[item] then
				error(("%s.type[%d]: unsupported type %s"):format(path, i, tostring(item)), 0)
			end
		end
		return
	end
	error(("%s.type: must be a valid JSON Schema type string or non-empty array"):format(path), 0)
end

local function validate_node(node, path, depth)
	if depth > 32 then
		error(("%s: schema exceeds maximum nesting depth"):format(path), 0)
	end
	if type(node) ~= "table" or (mare and mare.json and mare.json.is_array and mare.json.is_array(node)) then
		error(("%s: schema must be an object"):format(path), 0)
	end
	for k in pairs(node) do
		if not ALLOWED_KEYWORDS[k] then
			error(("%s: unsupported JSON Schema keyword %q"):format(path, tostring(k)), 0)
		end
	end
	if node.type ~= nil then
		check_type_decl(node.type, path)
	end
	if node.properties ~= nil then
		if not is_plain_table(node.properties) then
			error(("%s.properties: must be an object"):format(path), 0)
		end
		for prop, sub in pairs(node.properties) do
			if type(prop) ~= "string" then
				error(("%s.properties: property keys must be strings"):format(path), 0)
			end
			validate_node(sub, path .. ".properties." .. prop, depth + 1)
		end
	end
	if node.required ~= nil then
		if not is_array_table(node.required) then
			error(("%s.required: must be an array of strings"):format(path), 0)
		end
		for i, name in ipairs(node.required) do
			if type(name) ~= "string" then
				error(("%s.required[%d]: must be a string"):format(path, i), 0)
			end
		end
	end
	if node.additionalProperties ~= nil then
		if type(node.additionalProperties) ~= "boolean" then
			validate_node(node.additionalProperties, path .. ".additionalProperties", depth + 1)
		end
	end
	if node.items ~= nil then
		validate_node(node.items, path .. ".items", depth + 1)
	end
	if node.enum ~= nil then
		if not is_array_table(node.enum) or #node.enum == 0 then
			error(("%s.enum: must be a non-empty array"):format(path), 0)
		end
	end
	if node.oneOf ~= nil then
		if not is_array_table(node.oneOf) or #node.oneOf == 0 then
			error(("%s.oneOf: must be a non-empty array"):format(path), 0)
		end
		for i, sub in ipairs(node.oneOf) do
			validate_node(sub, ("%s.oneOf[%d]"):format(path, i), depth + 1)
		end
	end
end

function M.validate_schema(schema)
	if type(schema) ~= "table" or (mare and mare.json and mare.json.is_array and mare.json.is_array(schema)) then
		error("schema must be a JSON Schema object", 0)
	end
	if schema.type ~= "object" then
		error("schema root must have type = 'object'", 0)
	end
	validate_node(schema, "schema", 0)
	return true
end

local function json_equal(a, b)
	local jn = json_null()
	if (a == nil or (jn ~= nil and a == jn)) and (b == nil or (jn ~= nil and b == jn)) then
		return true
	end
	if type(a) ~= type(b) then
		return false
	end
	if type(a) ~= "table" then
		return a == b
	end
	local arr_a = is_array_table(a)
	local arr_b = is_array_table(b)
	if arr_a ~= arr_b then
		return false
	end
	for k, v in pairs(a) do
		if not json_equal(v, b[k]) then
			return false
		end
	end
	for k in pairs(b) do
		if a[k] == nil then
			return false
		end
	end
	return true
end

local function matches_single_type(expected, value)
	if expected == "null" then
		return is_null(value)
	elseif expected == "boolean" then
		return type(value) == "boolean"
	elseif expected == "string" then
		return type(value) == "string"
	elseif expected == "integer" then
		return type(value) == "number"
			and value == value
			and value > -math.huge
			and value < math.huge
			and value % 1 == 0
	elseif expected == "number" then
		return type(value) == "number" and value == value and value > -math.huge and value < math.huge
	elseif expected == "array" then
		return is_array_table(value)
	elseif expected == "object" then
		return type(value) == "table" and not is_array_table(value)
	end
	return false
end

local function validate_val(schema, value, path)
	if schema.const ~= nil then
		if not json_equal(value, schema.const) then
			return false, ("%s: expected const value"):format(path)
		end
	end
	if schema.enum ~= nil then
		local matched = false
		for _, candidate in ipairs(schema.enum) do
			if json_equal(value, candidate) then
				matched = true
				break
			end
		end
		if not matched then
			return false, ("%s: value not in enum"):format(path)
		end
	end
	if schema.oneOf ~= nil then
		local matches = 0
		for _, sub in ipairs(schema.oneOf) do
			if validate_val(sub, value, path) then
				matches = matches + 1
			end
		end
		if matches ~= 1 then
			return false, ("%s: expected exactly 1 oneOf match, got %d"):format(path, matches)
		end
	end
	if schema.type ~= nil then
		if type(schema.type) == "string" then
			if not matches_single_type(schema.type, value) then
				return false, ("%s: expected %s"):format(path, schema.type)
			end
		else
			local ok_type = false
			for _, t in ipairs(schema.type) do
				if matches_single_type(t, value) then
					ok_type = true
					break
				end
			end
			if not ok_type then
				return false, ("%s: type mismatch"):format(path)
			end
		end
	end
	if matches_single_type("array", value) and schema.items ~= nil then
		for i, item in ipairs(value) do
			local ok, err = validate_val(schema.items, item, ("%s[%d]"):format(path, i - 1))
			if not ok then
				return false, err
			end
		end
	end
	if matches_single_type("object", value) then
		local props = type(schema.properties) == "table" and schema.properties or {}
		if type(schema.required) == "table" then
			for _, req in ipairs(schema.required) do
				if value[req] == nil then
					return false, ("%s.%s: missing required property"):format(path, req)
				end
			end
		end
		for k, v in pairs(value) do
			if type(k) ~= "string" then
				return false, ("%s: object keys must be strings"):format(path)
			end
			local prop_schema = props[k]
			if prop_schema ~= nil then
				local ok, err = validate_val(prop_schema, v, path .. "." .. k)
				if not ok then
					return false, err
				end
			elseif schema.additionalProperties == false then
				return false, ("%s.%s: additional property is not allowed"):format(path, k)
			elseif type(schema.additionalProperties) == "table" then
				local ok, err = validate_val(schema.additionalProperties, v, path .. "." .. k)
				if not ok then
					return false, err
				end
			end
		end
	end
	return true
end

function M.validate_value(schema, value)
	M.validate_schema(schema)
	return validate_val(schema, value, "$")
end

local function is_kebab(s)
	return type(s) == "string"
		and s ~= ""
		and #s <= 64
		and s:match("^[a-z][a-z0-9-]*$") ~= nil
		and not s:find("--", 1, true)
		and s:sub(-1) ~= "-"
end

function M.validate_meta(meta)
	if not is_plain_table(meta) then
		return false, "meta must be an object"
	end
	for k in pairs(meta) do
		if k ~= "name" and k ~= "description" and k ~= "when_to_use" and k ~= "phases" then
			return false, "unknown meta field: " .. tostring(k)
		end
	end
	if not is_kebab(meta.name) then
		return false, "meta.name must be a short kebab-case identifier (^[a-z][a-z0-9-]*$)"
	end
	if type(meta.description) ~= "string" or not meta.description:find("%S") then
		return false, "meta.description must be a non-empty string"
	end
	if meta.when_to_use ~= nil and type(meta.when_to_use) ~= "string" then
		return false, "meta.when_to_use must be a string"
	end
	if meta.phases ~= nil then
		if not is_array_table(meta.phases) then
			return false, "meta.phases must be an array"
		end
		for i, p in ipairs(meta.phases) do
			if not is_plain_table(p) then
				return false, ("meta.phases[%d] must be an object"):format(i - 1)
			end
			for pk in pairs(p) do
				if pk ~= "title" and pk ~= "detail" and pk ~= "provider" and pk ~= "model" then
					return false, ("meta.phases[%d] unknown field: %s"):format(i - 1, tostring(pk))
				end
			end
			if type(p.title) ~= "string" or not p.title:find("%S") then
				return false, ("meta.phases[%d].title must be a non-empty string"):format(i - 1)
			end
			for _, opt_k in ipairs({ "detail", "provider", "model" }) do
				if p[opt_k] ~= nil and type(p[opt_k]) ~= "string" then
					return false, ("meta.phases[%d].%s must be a string"):format(i - 1, opt_k)
				end
			end
		end
	end
	return true
end

return M
