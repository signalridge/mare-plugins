local Buffer = require("terminal.buffer")
return function(ctx, cfg, backends)
	local records, count, generation = {}, 0, 0
	local pending, reserved = 0, {}
	local R = {}
	local closed, closed_order = {}, {}
	function R:closed(id)
		return closed[id]
	end
	local function owner()
		return mare.agent_id or "main"
	end
	function R:get(id)
		local r = records[id]
		if not r or r.owner ~= owner() or r.generation ~= generation or r.retired then
			error("Unknown or expired terminal", 0)
		end
		return r
	end
	function R:get_for_close(id)
		local r = records[id]
		if not r or r.owner ~= owner() or (r.generation ~= generation and not r.retired) then
			error("Unknown or expired terminal", 0)
		end
		return r
	end
	function R:list()
		local list = {}
		for _, r in pairs(records) do
			if r.owner == owner() and (r.generation == generation or (r.retired and r.stop_unconfirmed)) then
				list[#list + 1] = R:snapshot(r)
			end
		end
		table.sort(list, function(a, b)
			return a.session_id < b.session_id
		end)
		return mare.json.array(list)
	end
	function R:snapshot(r)
		local outcome = r.pty:exit_status()
		local code = outcome and outcome.code
		local view = r.pty:view({ max_bytes = cfg.read_max_bytes })
		return {
			session_id = r.id,
			name = r.name,
			type = r.backend.name,
			pid = r.pty.pid and r.pty:pid() or nil,
			job_id = r.job and r.job.job_id,
			status = r.closing and "closing" or (outcome ~= nil and "exited" or "running"),
			exit_code = code,
			exit_signal = outcome and outcome.signal,
			command_exit_code = view.command_exit_code,
			prompt_seq = view.prompt_generation,
			screen = view.screen,
			view_truncated = view.view_truncated,
			alternate_screen = view.alternate_screen,
			stop_unconfirmed = r.stop_unconfirmed or false,
			retired = r.retired or nil,
			cleanup_error = r.cleanup_error,
		}
	end
	function R:close(r, grace_ms)
		r.closing = true
		if r.operation and not r.operation.done then
			r.operation:kill()
		end
		local stopped = r.pty:stop({ grace_ms = grace_ms or cfg.stop_grace_ms })
		r.stop_unconfirmed = stopped.stop_unconfirmed
		if stopped.stopped then
			r.eof = true
			r.reader:abort()
			closed[r.id] = true
			closed_order[#closed_order + 1] = r.id
			if #closed_order > 64 then
				closed[table.remove(closed_order, 1)] = nil
			end
			if records[r.id] == r then
				records[r.id] = nil
				if not r.retired then
					count = math.max(0, count - 1)
				end
			end
		else
			r.cleanup_error = r.cleanup_error or "Terminal stop unconfirmed"
		end
		return stopped
	end
	function R:cleanup()
		local failures = {}
		local snapshot = {}
		for _, r in pairs(records) do
			snapshot[#snapshot + 1] = r
		end
		for _, r in ipairs(snapshot) do
			local ok, result = pcall(R.close, R, r)
			if not ok or not result.stopped then
				-- Bounded retry on transient stop failure before retiring to cleanup-only status.
				local retry_grace = math.min(cfg.stop_grace_ms, 250)
				for _ = 1, 2 do
					ok, result = pcall(R.close, R, r, retry_grace)
					if ok and result.stopped then
						break
					end
				end
			end
			if not ok or not result.stopped then
				if not r.retired then
					r.retired = true
					count = math.max(0, count - 1)
				end
				r.stop_unconfirmed = true
				r.cleanup_error = ok and "Terminal stop unconfirmed; close via terminal_close" or tostring(result)
				failures[#failures + 1] = r.id
			end
		end
		generation = generation + 1
		if #failures > 0 then
			error("Terminal stop unconfirmed: " .. table.concat(failures, ", "), 0)
		end
	end
	function R:open(name, cwd, tool, backend_type)
		require("terminal.config").validate(cfg)
		if count + pending >= cfg.max_sessions then
			error("Terminal session limit reached; close one first", 0)
		end
		local reservation = name and (owner() .. "\0" .. name)
		assert(not reservation or not reserved[reservation], "Terminal name already reserved")
		for _, r in pairs(records) do
			if name and not r.retired and r.owner == owner() and r.name == name then
				error("Terminal name already exists", 0)
			end
		end
		if tool.cancel:is_cancelled() then
			error("Terminal creation cancelled", 0)
		end
		local backend = backends.get(backend_type)
		pending = pending + 1
		if reservation then
			reserved[reservation] = true
		end
		local options = {
			emulate = true,
			cwd = cwd,
			cols = cfg.cols,
			rows = cfg.rows,
			buffer_bytes = cfg.buffer_bytes,
			scrollback_lines = cfg.scrollback_lines,
			env = {
				TERM = "dumb",
				PS1 = "mare> ",
				PS2 = "",
				PROMPT_COMMAND = 'printf "\\033]133;D;%s\\007" "$?"; PS1=\'mare> \'',
				BASH_ENV = "",
				ENV = "",
				NO_COLOR = "1",
				PAGER = "cat",
				HISTFILE = "",
				HISTSIZE = "0",
				HISTFILESIZE = "0",
			},
		}
		local opened, pty = pcall(function()
			local _, transport = mare.task.select(function()
				return backend.open(options, tool.cancel)
			end, function()
				backend.removed:wait()
				error("Terminal backend removed during creation", 0)
			end, function()
				tool.cancel:wait()
				error("Terminal creation cancelled", 0)
			end)
			return transport
		end)
		pending = pending - 1
		if reservation then
			reserved[reservation] = nil
		end
		if not opened then
			error(pty, 0)
		end
		local r = {
			id = mare.crypto.random_hex(16),
			name = name,
			cwd = cwd,
			backend = backend,
			owner = owner(),
			generation = generation,
			pty = pty,
			buffer = Buffer.new(cfg.buffer_bytes, cfg.scrollback_lines),
			busy = false,
			last_output = mare.task.clock(),
		}
		records[r.id], count = r, count + 1
		r.reader = ctx:spawn(function()
			local ok, err = pcall(function()
				while true do
					local text = pty:read_text()
					if not text then
						break
					end
					r.buffer:append(text)
					if r.operation and not r.operation.done then
						r.operation.buffer:append(text)
					end
					r.last_output = mare.task.clock()
				end
			end)
			if pty:try_wait() ~= nil then
				local stopped_ok, stopped = pcall(pty.stop, pty, { grace_ms = 0 })
				r.stop_unconfirmed = not stopped_ok or stopped.stop_unconfirmed
			end
			r.eof, r.read_error = true, not ok and tostring(err) or nil
		end)
		if not backend.active then
			R:close(r, 0)
			error("Terminal backend was removed during creation", 0)
		end
		if backend.bootstrap then
			local ok, err = pcall(pty.write, pty, backend.bootstrap)
			if not ok then
				R:close(r)
				error(err, 0)
			end
		end
		if tool.cancel:is_cancelled() then
			R:close(r)
			error("Terminal creation cancelled", 0)
		end
		return r
	end
	backends.on_remove(function(backend)
		for _, r in pairs(records) do
			if r.backend == backend then
				r.closing = true
				r.stop_unconfirmed = true
				pcall(r.pty.kill, r.pty)
				r.reader:abort()
				local scheduled, spawn_error = pcall(ctx.spawn, ctx, function()
					local ok, stopped = pcall(R.close, R, r, 0)
					if not ok or not stopped.stopped then
						r.cleanup_error = ok and "Backend removal: stop_unconfirmed" or tostring(stopped)
						mare.log("warn", r.cleanup_error)
					end
				end)
				if not scheduled then
					r.cleanup_error = "Backend removal cleanup could not be scheduled: " .. tostring(spawn_error)
					mare.log("warn", r.cleanup_error)
				end
			end
		end
	end)
	if ctx.inject then
		ctx:inject({ "session" }, function(sub)
			if sub.session and sub.session.on_drain then
				sub.session:on_drain(function()
					R:cleanup()
				end)
			end
		end)
	end
	for _, event in ipairs({ "app/shutdown", "session/changed", "workspace/changed" }) do
		ctx:on(event, function()
			R:cleanup()
		end)
	end
	-- Dispose callbacks cannot yield; immediate tree kill is the synchronous fallback.
	ctx:effect(function()
		return function()
			for _, r in pairs(records) do
				r.closing = true
				r.eof = true
				if r.operation and not r.operation.done then
					r.operation:kill()
				end
				pcall(r.pty.kill, r.pty)
				r.reader:abort()
			end
		end
	end)
	return R
end
