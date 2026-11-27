-- Hard plan-mode tool/before gate restricting mutating tools while planning.
local SUBAGENT_TOOLS = {
	subagent = true,
	subagent_steer = true,
}

local TERMINAL_TOOLS = {
	terminal_open = true,
	terminal_send = true,
	terminal_read = true,
	terminal_list = true,
	terminal_signal = true,
	terminal_close = true,
}

local JOB_TOOLS = {
	job_write = true,
	job_kill = true,
}

local function build_allowed_set(allow_tools)
	local allowed = {}
	if type(allow_tools) == "table" then
		for _, name in ipairs(allow_tools) do
			if type(name) == "string" then
				allowed[name] = true
			end
		end
	end
	return allowed
end

local function copy_array(list)
	if type(list) ~= "table" then
		return nil
	end
	local out = {}
	for i, v in ipairs(list) do
		out[i] = v
	end
	return out
end

local function append_unique(out, seen, list)
	if type(list) ~= "table" then
		return
	end
	for _, v in ipairs(list) do
		if not seen[v] then
			seen[v] = true
			out[#out + 1] = v
		end
	end
end

local function preserved_readable(current)
	if not current.restrict_read then
		return copy_array(current.readable)
	end
	local out, seen = {}, {}
	append_unique(out, seen, current.readable)
	if not current.reads_pinned then
		append_unique(out, seen, current.writable)
		append_unique(out, seen, current.roots)
	end
	return out
end

--- Build a read-only sandbox constraint that narrows only the local write dimension,
--- leaving network open to intersection so session/grant network rules remain intact.
local function read_only_sandbox()
	local sandbox_api = mare and mare.proc and mare.proc.sandbox
	local current = sandbox_api and type(sandbox_api.current) == "function" and sandbox_api.current() or nil
	if not current then
		return { level = "read-only", network = true }
	end
	return {
		level = "read-only",
		network = true,
		unix_sockets = copy_array(current.unix_sockets),
		accept_partial = copy_array(current.accept_partial),
		readable = preserved_readable(current),
		deny_read = copy_array(current.deny_read),
		restrict_read = current.restrict_read,
		reads_pinned = current.restrict_read and true or nil,
	}
end

local function is_allowed_tool(list, name)
	if type(list) ~= "table" or not name then
		return false
	end
	for _, entry in ipairs(list) do
		if entry == name then
			return true
		end
	end
	return false
end

return function(cfg, state, options_of, ctx)
	local cached_workflow_tool

	if ctx and type(ctx.on) == "function" then
		ctx:on("option/changed", function(ev)
			if not ev or ev.key == "plugins.workflow.tool_name" or ev.key == "plugins.workflow" then
				cached_workflow_tool = nil
			end
		end)
	end

	local function workflow_tool_name()
		if cached_workflow_tool then
			return cached_workflow_tool
		end
		local resolved = "workflow"
		local opts = type(options_of) == "function" and options_of() or nil
		if opts and type(opts.get) == "function" then
			local ok, values = pcall(opts.get, opts, { keys = { "plugins.workflow.tool_name" } })
			local name = ok and type(values) == "table" and values["plugins.workflow.tool_name"]
			if type(name) == "string" and name ~= "" then
				resolved = name
			end
		end
		cached_workflow_tool = resolved
		return resolved
	end

	--- Policy vote for `tool/before` following the plan-mode precedence order.
	local function vote(call, info)
		if cfg.enforce == false or not state.current().active then
			return nil
		end
		local name = call and call.name
		if name == "exit_plan_mode" or is_allowed_tool(cfg.allow_tools, name) then
			return nil
		end
		local args = call and call.arguments
		if
			(type(args) == "table" and (args.sandbox_permissions ~= nil or args.additional_permissions ~= nil))
			or (info and info.permission_request)
		then
			return {
				decision = "deny",
				reason = "Escalated permissions are unavailable in plan mode",
			}
		end
		if SUBAGENT_TOOLS[name] or name == workflow_tool_name() then
			return {
				decision = "deny",
				reason = "Subagents cannot be spawned or steered in plan mode",
			}
		end
		if TERMINAL_TOOLS[name] then
			return {
				decision = "deny",
				reason = "terminal is unavailable in plan mode",
			}
		end
		if JOB_TOOLS[name] then
			return {
				decision = "deny",
				reason = "Background job control is unavailable in plan mode",
			}
		end
		if name == "peer_send" then
			return {
				decision = "ask",
				reason = "Peer messaging runs outside plan mode's local write confinement",
			}
		end
		if info and info.unconfined == true then
			return {
				decision = "ask",
				reason = "This tool runs outside the local sandbox and may have side effects that plan mode cannot block",
			}
		end
		if name == "todo_write" then
			return {
				decision = "deny",
				reason = "todo_write is a checklist tool and cannot run in plan mode",
			}
		end
		if info and info.side_effect == "write" then
			return {
				decision = "deny",
				reason = "Local writes are blocked in plan mode",
			}
		end
		if name == "bash" or name == "powershell" or (info and info.side_effect == "external") then
			return {
				decision = "allow",
				sandbox = read_only_sandbox(),
			}
		end
		return nil
	end

	return {
		vote = vote,
	}
end
