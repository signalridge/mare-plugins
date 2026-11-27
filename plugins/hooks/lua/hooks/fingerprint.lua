-- Shared trust identity and plugin package content fingerprinting.
local M = {}

local IGNORED_NAMES = {
	["__pycache__"] = true,
	[".venv"] = true,
}

local function is_ignored_name(name)
	return IGNORED_NAMES[name] == true or name:sub(-4) == ".pyc" or name:sub(-9) == ".egg-info"
end

local function is_unreadable_dir_mode(mode)
	if mare.os == "windows" or type(mode) ~= "number" then
		return false
	end
	local perm = mode % 512
	local has_owner_read = math.floor(perm / 256) % 2 == 1
	local has_group_read = math.floor(perm / 32) % 2 == 1
	local has_other_read = math.floor(perm / 4) % 2 == 1
	return not (has_owner_read or has_group_read or has_other_read)
end

function M.hash_identity(parts)
	local encoded = {}
	for i, part in ipairs(parts) do
		local s = part == nil and "" or tostring(part)
		encoded[i] = tostring(#s) .. ":" .. s
	end
	local text = table.concat(encoded, "|")
	if mare.crypto and type(mare.crypto.sha256) == "function" then
		return mare.crypto.sha256(text)
	end
	return text
end

function M.plugin_content_hash(root)
	if type(root) ~= "string" or root == "" then
		return nil, "plugin root must be a non-empty path"
	end
	if
		not (
			mare.fs
			and type(mare.fs.stat) == "function"
			and type(mare.fs.list) == "function"
			and type(mare.fs.read) == "function"
			and mare.crypto
			and type(mare.crypto.sha256) == "function"
		)
	then
		return nil, "plugin fingerprint APIs unavailable"
	end
	local normalized = root:gsub("/+$", "")
	if normalized == "" then
		normalized = "/"
	end
	local stat_fn = type(mare.fs.lstat) == "function" and mare.fs.lstat or mare.fs.stat
	local ok_root, root_st = pcall(stat_fn, normalized)
	if not ok_root or type(root_st) ~= "table" or root_st.kind ~= "dir" then
		return nil, "plugin root is not a directory: " .. root
	end
	if is_unreadable_dir_mode(root_st.mode) then
		return nil, "unreadable plugin directory: " .. normalized
	end
	local records = {}
	local seen = 0
	local stack = { { rel = "", full = normalized, depth = 0 } }
	while #stack > 0 do
		local item = table.remove(stack)
		if item.depth > 32 then
			return nil, "plugin directory depth limit exceeded: " .. item.full
		end
		local ok_list, entries, list_err = pcall(mare.fs.list, item.full, { strict = true, no_follow = true })
		if not ok_list or type(entries) ~= "table" then
			local detail = (not ok_list and entries) or (type(entries) ~= "table" and (list_err or entries))
			return nil,
				"failed to list plugin directory: "
					.. item.full
					.. (detail ~= nil and (" (" .. tostring(detail) .. ")") or "")
		end
		if entries.error ~= nil or entries.ok == false then
			return nil,
				"failed to list plugin directory: " .. item.full .. (entries.error ~= nil and (" (" .. tostring(
					entries.error
				) .. ")") or "")
		end
		local sorted = {}
		for _, entry in ipairs(entries) do
			if type(entry) ~= "table" or type(entry.name) ~= "string" or entry.name == "" then
				return nil, "invalid directory entry in plugin directory: " .. item.full
			end
			if not is_ignored_name(entry.name) then
				sorted[#sorted + 1] = entry
			end
		end
		table.sort(sorted, function(a, b)
			return a.name < b.name
		end)
		for i = #sorted, 1, -1 do
			local entry = sorted[i]
			local name = entry.name
			seen = seen + 1
			if seen > 4096 then
				return nil, "plugin entry count limit exceeded: " .. normalized
			end
			local child_rel = item.rel == "" and name or (item.rel .. "/" .. name)
			local child_full = (item.full == "/" and "" or item.full) .. "/" .. name
			if entry.kind ~= nil and entry.kind ~= "dir" and entry.kind ~= "file" then
				return nil, "unsupported plugin entry type: " .. child_full
			end
			local ok_st, st = pcall(stat_fn, child_full)
			if not ok_st or type(st) ~= "table" then
				return nil, "failed to stat plugin entry: " .. child_full
			end
			if st.kind == "dir" then
				if is_unreadable_dir_mode(st.mode) then
					return nil, "unreadable plugin directory: " .. child_full
				end
				records[#records + 1] = "D:" .. tostring(#child_rel) .. ":" .. child_rel
				stack[#stack + 1] = { rel = child_rel, full = child_full, depth = item.depth + 1 }
			elseif st.kind == "file" then
				local ok_rd, content, rd_err = pcall(mare.fs.read, child_full, { no_follow = true })
				if not ok_rd or type(content) ~= "string" then
					return nil,
						"failed to read plugin file: " .. child_full .. " (" .. tostring(content or rd_err) .. ")"
				end
				if type(st.size) == "number" and #content ~= st.size then
					return nil, "plugin file changed while fingerprinting: " .. child_full
				end
				records[#records + 1] = "F:"
					.. tostring(#child_rel)
					.. ":"
					.. child_rel
					.. ":"
					.. tostring(#content)
					.. ":"
					.. mare.crypto.sha256(content)
			else
				return nil, "unsupported plugin entry type: " .. child_full
			end
		end
	end
	return "sha256:" .. mare.crypto.sha256("mare-plugin-bundle-v1\n" .. table.concat(records, "\n"))
end

function M.effective_hash(cmd, content_hash)
	if cmd.require_trust and cmd.plugin_root then
		local fp = content_hash
		local err
		if not fp then
			fp, err = M.plugin_content_hash(cmd.plugin_root)
		end
		if not fp then
			return nil, err or "plugin content verification failed"
		end
		return M.hash_identity({ "trusted-plugin", cmd.declaration_hash or cmd.hash, fp }), fp
	end
	return cmd.hash
end

return M
