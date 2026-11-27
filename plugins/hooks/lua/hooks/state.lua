-- Persistent/session handler enable/disable and SHA-256 trust confirmation.
local fingerprint = require("hooks.fingerprint")
local M = {}

local function read_persisted()
	if mare.state and type(mare.state.read) == "function" then
		local st = mare.state.read()
		if type(st) == "table" then
			return st.hooks or {}
		end
	end
	return {}
end

local function update_persisted(fn)
	if mare.state and type(mare.state.update) == "function" then
		mare.state.update(function(st)
			st.hooks = type(st.hooks) == "table" and st.hooks or {}
			st.hooks.disabled = type(st.hooks.disabled) == "table" and st.hooks.disabled or {}
			st.hooks.trusted = type(st.hooks.trusted) == "table" and st.hooks.trusted or {}
			fn(st.hooks)
			return st
		end)
	end
end

function M.new()
	local session_disabled = {}
	local session_trusted = {}
	local trust_locked, trust_waiters = false, {}
	local self = {}

	local function release_trust_lock()
		while #trust_waiters > 0 do
			local waiter = table.remove(trust_waiters, 1)
			if not waiter.cancelled then
				waiter.granted = true
				if not waiter.tx or waiter.tx:send(true) ~= false then
					return
				end
				waiter.granted = false
			end
		end
		trust_locked = false
	end

	local function with_trust_lock(fn)
		local mine = { granted = false, cancelled = false }
		local guard <close> = setmetatable({}, {
			__close = function()
				if mine.granted then
					mine.granted = false
					release_trust_lock()
				else
					mine.cancelled = true
				end
			end,
		})
		if trust_locked then
			if mare.task and type(mare.task.channel) == "function" then
				local rx
				mine.tx, rx = mare.task.channel()
				trust_waiters[#trust_waiters + 1] = mine
				rx:recv()
			elseif coroutine.isyieldable() then
				trust_waiters[#trust_waiters + 1] = mine
				while not mine.granted do
					coroutine.yield()
				end
			else
				return false, "trust confirmation already in progress"
			end
		else
			trust_locked = true
			mine.granted = true
		end
		return fn()
	end

	function self.is_enabled(cmd)
		if cmd.enabled == false then
			if session_disabled[cmd.id] == false then
				return true
			end
			local persisted = read_persisted()
			if type(persisted.disabled) == "table" and persisted.disabled[cmd.id] == false then
				return true
			end
			return false
		end
		if session_disabled[cmd.id] ~= nil then
			return not session_disabled[cmd.id]
		end
		local persisted = read_persisted()
		if type(persisted.disabled) == "table" and persisted.disabled[cmd.id] == true then
			return false
		end
		return true
	end

	function self.set_enabled(cmd, enabled)
		local disabled = not enabled
		session_disabled[cmd.id] = disabled
		update_persisted(function(hooks)
			if cmd.enabled == false then
				if enabled then
					hooks.disabled[cmd.id] = false
				else
					hooks.disabled[cmd.id] = nil
				end
			else
				if disabled then
					hooks.disabled[cmd.id] = true
				else
					hooks.disabled[cmd.id] = nil
				end
			end
		end)
		return enabled
	end

	function self.toggle(cmd)
		return self.set_enabled(cmd, not self.is_enabled(cmd))
	end

	local function is_trusted_for_hash(cmd, effective_hash)
		if session_trusted[cmd.id] == effective_hash then
			return true
		end
		local persisted = read_persisted()
		return type(persisted.trusted) == "table" and persisted.trusted[cmd.id] == effective_hash
	end

	local function save_trust_hash(cmd, persist, effective_hash)
		session_trusted[cmd.id] = effective_hash
		if persist then
			update_persisted(function(hooks)
				hooks.trusted[cmd.id] = effective_hash
			end)
		end
	end

	function self.current_hash(cmd)
		return fingerprint.effective_hash(cmd)
	end

	function self.is_trusted(cmd)
		if not cmd.require_trust then
			return true, nil, cmd.hash
		end
		local effective_hash, fp_err = self.current_hash(cmd)
		if not effective_hash then
			return false, "plugin content verification failed: " .. tostring(fp_err or "unreadable plugin")
		end
		if is_trusted_for_hash(cmd, effective_hash) then
			return true, nil, effective_hash
		end
		return false, "untrusted or modified hook handler (sha256: " .. effective_hash:sub(1, 12) .. ")", effective_hash
	end

	function self.trust(cmd, persist)
		local effective_hash, fp_err = self.current_hash(cmd)
		if not effective_hash then
			return false, fp_err or "plugin content verification failed"
		end
		save_trust_hash(cmd, persist, effective_hash)
		return true, effective_hash
	end

	function self.ensure_trusted(cmd)
		if not cmd.require_trust then
			return true, nil, cmd.hash
		end
		return with_trust_lock(function()
			local effective_hash, fp_err = self.current_hash(cmd)
			if not effective_hash then
				return false, "plugin content verification failed: " .. tostring(fp_err or "unreadable plugin")
			end
			if is_trusted_for_hash(cmd, effective_hash) then
				return true, nil, effective_hash
			end
			if mare.ui and type(mare.ui.select) == "function" then
				local index = mare.ui.select({
					title = "Trust hook handler?",
					body = {
						"Event: " .. cmd.event,
						"Matcher: " .. (cmd.matcher or "*"),
						"Handler: " .. cmd.label,
						"Command: " .. cmd.command,
						"SHA-256: " .. effective_hash,
					},
					items = {
						"Trust and run (remember)",
						"Trust for this session only",
						"Deny",
					},
				})
				if index == 1 or index == 2 then
					local post_hash, post_err = self.current_hash(cmd)
					if not post_hash then
						return false,
							"plugin content verification failed: " .. tostring(post_err or "unreadable plugin")
					end
					if post_hash ~= effective_hash then
						return false, "plugin contents changed during trust confirmation"
					end
					save_trust_hash(cmd, index == 1, post_hash)
					return true, nil, post_hash
				end
			end
			return false,
				"untrusted or modified hook handler (sha256: " .. effective_hash:sub(1, 12) .. ")",
				effective_hash
		end)
	end

	return self
end

return M
