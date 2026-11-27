local M = {}

local function has_entry(list, expected)
	if type(list) ~= "table" then
		return false
	end
	for _, value in ipairs(list) do
		if value == expected then
			return true
		end
	end
	return false
end

local function join_strings(list, fallback)
	if type(list) ~= "table" or #list == 0 then
		return fallback
	end
	local items = {}
	for _, value in ipairs(list) do
		if type(value) == "string" and value ~= "" then
			items[#items + 1] = value
		end
	end
	return #items > 0 and table.concat(items, ", ") or fallback
end

local function truncate_text(text, max_len)
	if type(text) ~= "string" then
		return nil
	end
	local trimmed = text:match("^%s*(.-)%s*$")
	if trimmed == "" then
		return nil
	end
	local char_len = utf8.len(trimmed)
	if not char_len and mare and mare.text and type(mare.text.sanitize) == "function" then
		trimmed = mare.text.sanitize(trimmed)
		char_len = utf8.len(trimmed)
	end
	if char_len then
		if char_len <= max_len then
			return trimmed
		end
		if max_len <= 3 then
			local end_byte = utf8.offset(trimmed, max_len + 1)
			return end_byte and trimmed:sub(1, end_byte - 1) or ""
		end
		local cut_byte = utf8.offset(trimmed, max_len - 2)
		return (cut_byte and trimmed:sub(1, cut_byte - 1) or "") .. "..."
	end
	if mare and mare.text and type(mare.text.cut) == "function" then
		return mare.text.cut(trimmed, max_len)
	end
	return ""
end

local function format_peer_label(p)
	local state = type(p.status) == "table" and p.status.state or "idle"
	local mode = type(p.mode) == "string" and p.mode ~= "" and (", " .. p.mode) or ""
	local plugins = type(p.plugins) == "table" and p.plugins or {}
	local held = type(plugins.status) == "table"
			and type(plugins.status.held) == "number"
			and plugins.status.held > 0
			and (" [" .. tostring(plugins.status.held) .. " held]")
		or ""
	local session_name = type(plugins.session) == "table"
			and type(plugins.session.session_id) == "string"
			and truncate_text(plugins.session.name, 24)
		or nil
	local status_msg = type(p.status) == "table" and truncate_text(p.status.message, 40) or nil
	local extras = {}
	if session_name then
		extras[#extras + 1] = session_name
	end
	if status_msg then
		extras[#extras + 1] = status_msg
	end
	local extra_text = #extras > 0 and (" · " .. table.concat(extras, " · ")) or ""
	local dir = type(p.cwd) == "string" and p.cwd ~= "" and ("  " .. p.cwd) or ""
	return string.format(
		"%s (%s, pid %d%s)%s%s%s",
		tostring(p.name),
		tostring(state),
		tonumber(p.pid) or 0,
		mode,
		held,
		extra_text,
		dir
	)
end

local function notify(msg, level)
	if mare.ui and type(mare.ui.notify) == "function" then
		mare.ui.notify(msg, level or "info")
	end
end

local function pick_peer(peers, target_arg)
	if target_arg == "" then
		local items = {}
		for _, p in ipairs(peers) do
			items[#items + 1] = format_peer_label(p)
		end
		local idx = mare.ui.select({ title = "Select a peer session", items = items })
		return idx and peers[idx] or nil
	end

	local matches = {}
	local target_pid = tonumber(target_arg)
	for _, p in ipairs(peers) do
		if p.name == target_arg or (target_pid and p.pid == target_pid) then
			matches[#matches + 1] = p
		end
	end
	if #matches == 0 then
		notify(("No live peer matching %q"):format(target_arg), "warning")
		return nil
	end
	if #matches == 1 then
		return matches[1]
	end
	local items = {}
	for _, p in ipairs(matches) do
		items[#items + 1] = format_peer_label(p)
	end
	local idx = mare.ui.select({ title = ("Multiple peers match %q"):format(target_arg), items = items })
	return idx and matches[idx] or nil
end

local function send_flow(client, peer, queue_only)
	if type(mare.ui.input) ~= "function" then
		notify("Peer messaging requires text input UI support", "warning")
		return
	end
	local mode_label = queue_only and "queue_only" or "trigger_turn"
	local text = mare.ui.input({
		title = ("Message to @%s (%s)"):format(tostring(peer.name), mode_label),
		placeholder = "Enter message...",
	})
	if type(text) ~= "string" or text:match("%S") == nil then
		notify("Message cancelled or empty", "info")
		return
	end
	local receipt, send_err = client:send({ text = text, queue_only = queue_only })
	if not receipt then
		local hint = send_err.code == "outcome_unknown" and " (do not resend automatically)" or ""
		notify(("Send failed (%s): %s%s"):format(send_err.code, send_err.message, hint), "error")
		return
	end
	if receipt.status ~= "held" then
		notify(("Message %s: %s"):format(receipt.message_id, receipt.status), "info")
		return
	end
	local terminal, wait_err = client:wait_message(receipt.message_id, { timeout_ms = 30000 })
	if not terminal then
		notify(
			("Message %s still held (%s): %s. Do not resend automatically."):format(
				receipt.message_id,
				wait_err.code,
				wait_err.message
			),
			"warning"
		)
		return
	end
	local detail = ("Message %s: %s"):format(receipt.message_id, terminal.status)
	if type(terminal.reason) == "string" and terminal.reason ~= "" then
		detail = detail .. " (" .. terminal.reason .. ")"
	end
	notify(detail, terminal.status == "delivered" and "info" or "warning")
end

function M.run(ctx, args, helpers)
	if not mare.ui or type(mare.ui.select) ~= "function" then
		notify("Peer UI requires a connected selection UI", "warning")
		return
	end
	local peers = helpers.others()
	if #peers == 0 then
		notify("No other local mare sessions are running", "info")
		return
	end
	local target_arg = type(args) == "string" and args:match("^%s*(.-)%s*$") or ""
	local peer = pick_peer(peers, target_arg)
	if not peer then
		return
	end
	if not helpers.sending_available() then
		notify(
			format_peer_label(peer)
				.. "\nSending is unavailable until the core peer-message source boundary fix (PEERS-3) is merged.",
			"info"
		)
		return
	end

	while true do
		local client, cerr = helpers.connect({ pid = peer.pid, started_at_ms = peer.started_at_ms })
		if not client then
			notify(("Failed to connect to @%s (%s): %s"):format(tostring(peer.name), cerr.code, cerr.message), "error")
			return
		end
		local ok, should_continue = pcall(function()
			local info = client:info() or {}
			local status, serr = client:status()
			local state_line
			if status then
				state_line = tostring(status.state or "unknown")
				if type(status.message) == "string" and status.message ~= "" then
					state_line = state_line .. " - " .. status.message
				end
			else
				state_line = "unavailable ("
					.. tostring(serr and serr.code or "error")
					.. (type(serr and serr.message) == "string" and (": " .. serr.message) or "")
					.. ")"
			end
			local can_message = type(info.allowed) ~= "table" or has_entry(info.allowed, "peer.message")
			local supports_queue_only = has_entry(info.delivery_modes, "queue_only")
			local mode = type(peer.mode) == "string" and peer.mode ~= "" and (", " .. peer.mode) or ""
			local lines = {
				("@%s (pid %d%s)"):format(tostring(peer.name), tonumber(peer.pid) or 0, mode),
			}
			if type(peer.cwd) == "string" and peer.cwd ~= "" then
				lines[#lines + 1] = "cwd: " .. peer.cwd
			end
			local plugins = type(peer.plugins) == "table" and peer.plugins or {}
			if type(plugins.session) == "table" and type(plugins.session.session_id) == "string" then
				local sname = truncate_text(plugins.session.name, 40)
				lines[#lines + 1] = "session: "
					.. (sname and (sname .. " (" .. plugins.session.session_id .. ")") or plugins.session.session_id)
			end
			lines[#lines + 1] = "status: " .. state_line
			lines[#lines + 1] = "delivery modes: " .. join_strings(info.delivery_modes, "trigger_turn")
			lines[#lines + 1] = "allowed (self-reported): " .. join_strings(info.allowed, "unknown")
			local title = table.concat(lines, "\n")

			local actions = {}
			if can_message then
				actions[#actions + 1] = { label = "Send message (trigger turn)", kind = "send_trigger" }
				if supports_queue_only then
					actions[#actions + 1] = { label = "Send message (queue only)", kind = "send_queue" }
				end
			end
			actions[#actions + 1] = { label = "Wait for idle", kind = "wait_idle" }
			actions[#actions + 1] = { label = "Wait for next idle", kind = "wait_next_idle" }
			actions[#actions + 1] = { label = "Refresh status", kind = "refresh" }

			local labels = {}
			for _, action in ipairs(actions) do
				labels[#labels + 1] = action.label
			end
			local choice = mare.ui.select({ title = title, items = labels })
			if not choice or not actions[choice] then
				return false
			end
			local selected = actions[choice].kind
			if selected == "send_trigger" then
				send_flow(client, peer, false)
				return false
			elseif selected == "send_queue" then
				send_flow(client, peer, true)
				return false
			elseif selected == "wait_idle" or selected == "wait_next_idle" then
				local idle, ierr = client:wait_idle({
					current_or_next = selected == "wait_idle",
					timeout_ms = 30000,
				})
				if idle then
					notify(("Peer @%s is %s"):format(tostring(peer.name), tostring(idle.state)), "info")
				else
					notify(("Wait idle failed (%s): %s"):format(tostring(ierr.code), tostring(ierr.message)), "warning")
				end
				return false
			end
			return true
		end)
		helpers.release(client)
		if not ok then
			notify("Peer operation failed: " .. tostring(should_continue), "error")
			return
		end
		if not should_continue then
			return
		end
	end
end

return M
