-- /hooks management slash command: list, status, toggle, and trust confirmation.
local function find_command(commands, target)
	if not target or target == "" then
		return nil
	end
	local idx = tonumber(target)
	if idx and idx >= 1 and idx <= #commands and idx % 1 == 0 then
		return commands[idx], idx
	end
	for i, cmd in ipairs(commands) do
		if cmd.id == target or cmd.label == target then
			return cmd, i
		end
	end
	return nil
end

local function describe_command(cmd, state)
	local matcher = cmd.matcher or "*"
	if cmd.unsupported_type then
		local behaviour = cmd.decision_event and "fail-closed" or "skipped"
		return {
			tag = "INACTIVE",
			matcher = matcher,
			status_meta = string.format("unsupported %q hook, %s", cmd.unsupported_type, behaviour),
			detail = string.format("unsupported %q hook (%s) | %s", cmd.unsupported_type, behaviour, cmd.source_name),
			target = cmd.source_name,
		}
	end
	local enabled = state.is_enabled(cmd) and "ON" or "OFF"
	local trust = cmd.require_trust and (state.is_trusted(cmd) and "trusted" or "untrusted") or "auto"
	local mode = cmd.runs_async and ", async" or ""
	local cur_hash = type(state.current_hash) == "function" and state.current_hash(cmd) or cmd.hash
	local hash = (cur_hash or "unverified"):sub(1, 12)
	return {
		tag = enabled,
		matcher = matcher,
		status_meta = string.format("%s%s, sha256:%s", trust, mode, hash),
		detail = string.format("%s | %s | sha256:%s", cmd.command, trust, hash),
		target = cmd.command,
	}
end

local function format_status(commands, state)
	if #commands == 0 then
		return "No hooks configured."
	end
	local lines = {}
	for i, cmd in ipairs(commands) do
		local info = describe_command(cmd, state)
		lines[#lines + 1] = string.format(
			"%d. [%s] %s (%s, %s) -> %s",
			i,
			info.tag,
			cmd.label,
			info.matcher,
			info.status_meta,
			info.target
		)
	end
	return table.concat(lines, "\n")
end

local function notify(text, level)
	if mare.ui and type(mare.ui.notify) == "function" then
		mare.ui.notify(text, level or "info")
	end
end

local function inactive_rejection(cmd)
	return {
		status = "rejected",
		reason = string.format("hook %s is inactive (unsupported type %q)", cmd.label, cmd.unsupported_type),
	}
end

return function(ctx, commands, state)
	if not ctx.commands or not require("mare_lib").callable(ctx.commands.register) then
		return
	end
	ctx.commands:register("hooks", {
		description = "List, inspect, and toggle configured hooks",
		args = "[status|list|toggle <n>|enable <n>|disable <n>|trust <n>]",
		run = function(args)
			local trimmed = (args or ""):match("^%s*(.-)%s*$")
			if trimmed == "status" or trimmed == "list" then
				local summary = format_status(commands, state)
				notify(summary, "info")
				return { status = "completed", summary = summary }
			end
			local action, target = trimmed:match("^(%S+)%s+(.+)$")
			if action == "toggle" or action == "enable" or action == "disable" or action == "trust" then
				local cmd = find_command(commands, target)
				if not cmd then
					return { status = "rejected", reason = "unknown hook handler: " .. tostring(target) }
				end
				if cmd.unsupported_type then
					return inactive_rejection(cmd)
				end
				if action == "toggle" then
					local enabled = state.toggle(cmd)
					notify("Hook " .. cmd.label .. (enabled and " enabled" or " disabled"), "info")
				elseif action == "enable" then
					state.set_enabled(cmd, true)
					notify("Hook " .. cmd.label .. " enabled", "info")
				elseif action == "disable" then
					state.set_enabled(cmd, false)
					notify("Hook " .. cmd.label .. " disabled", "info")
				elseif action == "trust" then
					local ok, hash_or_err = state.trust(cmd, true)
					if not ok then
						return { status = "rejected", reason = tostring(hash_or_err) }
					end
					notify(
						"Hook " .. cmd.label .. " trusted (sha256:" .. tostring(hash_or_err):sub(1, 12) .. ")",
						"info"
					)
				end
				return { status = "completed" }
			end
			if trimmed ~= "" then
				return {
					status = "rejected",
					reason = "usage: /hooks [status|list|toggle <n>|enable <n>|disable <n>|trust <n>]",
				}
			end
			if #commands == 0 then
				notify("No hooks configured.", "info")
				return { status = "completed" }
			end
			if not mare.ui or type(mare.ui.select) ~= "function" then
				return { status = "rejected", reason = "hooks menu requires interactive UI" }
			end
			local items = {}
			for i, cmd in ipairs(commands) do
				local info = describe_command(cmd, state)
				items[i] = {
					id = cmd.id,
					label = string.format("[%s] %s (%s)", info.tag, cmd.label, info.matcher),
					detail = info.detail,
				}
			end
			local index, tab_or_reason = mare.ui.select({
				title = "Hooks (select to toggle)",
				items = items,
			})
			if not index then
				local reason = tab_or_reason
				if reason == "unavailable" or reason == "disconnected" or reason == "invalid_ui_answer" then
					return { status = "rejected", reason = "hooks menu unavailable (" .. tostring(reason) .. ")" }
				end
				return { status = "cancelled" }
			end
			local chosen = commands[index]
			if not chosen then
				return { status = "rejected", reason = "invalid hook selection" }
			end
			if chosen.unsupported_type then
				local rej = inactive_rejection(chosen)
				notify(rej.reason, "warning")
				return rej
			end
			local enabled = state.toggle(chosen)
			notify("Hook " .. chosen.label .. (enabled and " enabled" or " disabled"), "info")
			return { status = "completed" }
		end,
	})
end
