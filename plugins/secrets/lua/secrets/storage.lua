-- Single-name operations reuse the host's public credential store and its existing lock.
return function(ctx, service, secret_name, validate_secret_value, sync)
	local function key(name)
		return "mare-plugin/secrets/" .. secret_name(name)
	end
	local function read(name)
		local record = ctx.llm:auth_get(key(name))
		if record == nil then
			return nil
		end
		assert(
			type(record) == "table"
				and record.version == 1
				and record.kind == "explicit-secret"
				and type(record.value) == "string",
			"Invalid stored secret record"
		)
		return record.value ~= "" and record.value or nil
	end
	local function mask_credential(value)
		assert(utf8.len(value), "Invalid stored secret UTF-8")
		local chars = {}
		for _, cp in utf8.codes(value) do
			chars[#chars + 1] = utf8.char(cp)
		end
		local provider_end = 0
		for i, ch in ipairs(chars) do
			if ch == "-" or ch == "_" then
				if i <= 8 and table.concat(chars, "", 1, i - 1):match("^[A-Za-z0-9]+$") then
					provider_end = i
				elseif #chars <= 17 then
					return string.rep("•", #chars)
				end
				break
			end
		end
		local hidden = #chars - provider_end - 5 - 4
		if hidden < 8 then
			return string.rep("•", #chars)
		end
		return table.concat(chars, "", 1, provider_end + 5)
			.. string.rep("•", hidden)
			.. table.concat(chars, "", #chars - 3, #chars)
	end
	function service.describe(_, _, name)
		name = secret_name(name)
		local value = read(name)
		local configured = value ~= nil
		return mare.projection.project({
			name = name,
			configured = configured,
			source = configured and "auth" or nil,
			scope = "profile",
			writable = true, -- This source supports writes; an actual OS/write failure still rejects.
			masked = configured and mask_credential(value) or nil,
		})
	end
	function service.stored()
		if not require("mare_lib").callable(ctx.llm.auth_keys) then
			error(mare.error("secrets.unavailable", "Stored-name enumeration requires public llm.auth_keys support"), 0)
		end
		local rows = mare.json.array({})
		for _, address in ipairs(ctx.llm:auth_keys()) do
			assert(
				not address:find("[[mare-value:", 1, true),
				"Projected credential addresses cannot be enumerated safely"
			)
			local name = address:match("^mare%-plugin/secrets/([A-Z0-9_]+)$")
			if name then
				local ok, info = pcall(service.describe, service, ctx, name)
				rows[#rows + 1] = ok and info
					or { name = name, configured = false, invalid = true, scope = "profile", writable = true }
			end
		end
		return mare.projection.project(rows)
	end
	function service.save(_, _, name, value)
		name = secret_name(name)
		if validate_secret_value then
			validate_secret_value(name, value)
		else
			assert(type(value) == "string" and value ~= "", "Secret value must be a non-empty string")
			assert(mare.projection.project(name) == name and not name:find(value, 1, true), "Unsafe secret name")
		end
		-- Validate UTF-8 before touching storage. No namespace index or read-modify-write race.
		mare.projection.project(value)
		ctx.llm:auth_set(key(name), { version = 1, kind = "explicit-secret", value = value })
		return service.describe(service, ctx, name)
	end
	function service.load(_, _, name)
		name = secret_name(name)
		if sync then
			sync()
		end
		local init_info = ctx.session:info()
		local init_id, init_gen = init_info.session_id, init_info.session_epoch
		local ok, value = pcall(read, name) -- Re-read on every operation; never cache a value.
		local cur_info = ctx.session:info()
		if cur_info.session_id ~= init_id or cur_info.session_epoch ~= init_gen then
			if sync then
				sync()
			end
			if not ok then
				error(value, 0)
			end
			error("Session changed while loading secret", 0)
		end
		-- Even a missing/invalid replacement revokes the old local lease: fail closed.
		service.remove(service, ctx, name)
		if not ok then
			error(value, 0)
		end
		if value == nil then
			local msg = "Secret is not configured in this profile"
			if mare and type(mare.error) == "function" then
				error(mare.error("secrets.not_configured", msg), 0)
			end
			error(msg, 0)
		end
		-- A new load is explicit replacement, never a hidden change to an approval.
		return service.register(service, ctx, name, value)
	end
	-- Public reference resolution never returns the stored plaintext to its caller.
	function service.resolve(_, caller, name)
		local reference = service.load(service, caller, name)
		return mare.projection.project({ reference = reference, source = "auth", scope = "profile" })
	end
	function service.delete(_, _, name)
		name = secret_name(name)
		if sync then
			sync()
		end
		local init_info = ctx.session:info()
		local init_id, init_gen = init_info.session_id, init_info.session_epoch
		ctx.llm:auth_set(key(name), nil)
		local cur_info = ctx.session:info()
		if cur_info.session_id == init_id and cur_info.session_epoch == init_gen then
			service.remove(service, ctx, name)
		elseif sync then
			sync()
		end
		return service.describe(service, ctx, name)
	end
end
