-- A send owns its slot through interrupt delivery; jobs refer to this send, never the shell.
local Buffer = require("terminal.buffer")
local function poll_operation(cfg, caps, r, op, token, op_cancel)
	while true do
		local now = mare.task.clock()
		if (token:is_cancelled() or op.cancelled) and not op.interrupted then
			op.cancelled, op.interrupted = true, true
			-- Synchronous verified delivery completes before the send slot can be released.
			if caps.foreground_signals then
				r.pty:signal("SIGINT")
			else
				r.pty:write("\3")
			end
		end
		if r.eof or r.closing then
			op.reason = "session_exit"
			break
		end
		if r.read_error then
			error(r.read_error, 0)
		end
		local view, foreground = r.pty:view({ screen = false }), r.pty:foreground()
		local last_activity = math.max(r.last_output, op.started)
		local idle_for = now - last_activity
		local quiet = idle_for >= cfg.poll_interval_ms
		if
			view.prompt_generation > op.generation
			and quiet
			and view.tail:sub(-6) == "mare> "
			and (not caps.foreground or (foreground and foreground.pgid == r.shell_pgid))
		then
			op.reason = "prompt"
			break
		end
		if
			not op.cancelled
			and now - op.started >= cfg.poll_interval_ms * 2
			and quiet
			and foreground
			and foreground.input_waiting == true
			-- an empty poll sent nothing: a process already waiting for input is no reason to stop
			-- before new output (collects until the deadline)
			and r.buffer.finish > op.initial_cursor
		then
			op.reason = "stdin_read"
			break
		end
		local tail_pending = view.prompt_generation > op.generation
			and view.tail:sub(-6) ~= "mare> "
			and (#view.tail == 0 or ("mare> "):sub(1, #view.tail) == view.tail)
		local idle_limit = cfg.idle_silence_ms
			+ (view.prompt_generation > op.generation and cfg.handoff_grace_ms or 0)
			+ (tail_pending and cfg.prompt_tail_grace_ms or 0)
		if not op.cancelled and (op.empty or r.buffer.finish > op.initial_cursor) and idle_for >= idle_limit then
			op.reason = "inferred_idle"
			break
		end
		local active_deadline = op.started + ((op.cancelled or op.background) and cfg.timeout_ms or op.timeout_ms)
		if now >= active_deadline then
			op.reason = (op.cancelled or op.background or op.timeout_ms >= cfg.timeout_ms) and "timeout"
				or "wait_elapsed"
			op.stop_unconfirmed = op.cancelled or nil
			break
		end
		local step_ms = math.min(cfg.poll_interval_ms, math.max(1, active_deadline - now))
		mare.task.sleep(step_ms, not op.interrupted and op_cancel or nil)
	end
end

return function(ctx, cfg, registry, caps)
	local M = {}
	function M:start(r, text, timeout_ms, token, opts)
		require("terminal.config").validate(cfg)
		assert(not r.busy and not r.closing and not r.eof, "Terminal busy, closing or exited")
		assert(not token:is_cancelled(), "Terminal send cancelled before write")
		opts = opts or {}
		local done_token = mare.task.token()
		local op_cancel = token:child()
		local op = {
			started = mare.task.clock(),
			cursor = 0,
			buffer = Buffer.new(cfg.read_max_bytes, cfg.scrollback_lines),
			initial_cursor = r.buffer.finish,
			generation = r.pty:view({ screen = false }).prompt_generation,
			timeout_ms = timeout_ms,
			background = opts.background == true,
			empty = #text == 0,
			op_cancel = op_cancel,
		}
		r.busy, r.operation = true, op
		function op:status()
			return {
				state = self.done and "exited" or "running",
				code = self.done and (self.error and 1 or 0) or nil,
				elapsed_ms = mare.task.clock() - self.started,
				unread = self.buffer.finish - self.cursor,
				bytes = self.buffer.finish,
				cancelled = self.cancelled or false,
				stop_unconfirmed = self.stop_unconfirmed or false,
			}
		end
		function op:read(read_opts)
			local delta, cursor, dropped = self.buffer:delta(
				self.cursor,
				math.min((read_opts or {}).max_bytes or cfg.read_max_bytes, cfg.read_max_bytes)
			)
			self.cursor = cursor
			return { text = delta, dropped = dropped and 1 or 0, done = self.done or false }
		end
		function op:read_at(offset, read_opts)
			local max_bytes = math.min((read_opts or {}).max_bytes or cfg.read_max_bytes, cfg.read_max_bytes)
			local text, next_pos, dropped = self.buffer:read_at(offset or 0, max_bytes)
			return { text = text, next = next_pos, dropped = dropped }
		end
		function op:tail(n)
			return self.buffer:delta(self.buffer.start, n)
		end
		function op:kill()
			self.cancelled = true
			self.op_cancel:cancel()
		end
		function op:wait(wait_opts)
			wait_opts = wait_opts or {}
			if not wait_opts.timeout_ms and not wait_opts.cancel and not wait_opts.update then
				if not self.done then
					done_token:wait()
				end
				return self:status()
			end
			local deadline = wait_opts.timeout_ms and mare.task.clock() + wait_opts.timeout_ms
			local updated = self.initial_cursor
			while not self.done do
				if wait_opts.update and r.buffer.finish ~= updated then
					wait_opts.update()
					updated = r.buffer.finish
				end
				if wait_opts.cancel and wait_opts.cancel:is_cancelled() then
					local interrupt_deadline = mare.task.clock() + math.max(cfg.poll_interval_ms * 2, 100)
					while not self.interrupted and not self.done and mare.task.clock() < interrupt_deadline do
						mare.task.sleep(10, done_token)
					end
					if self.interrupted and not self.done then
						local drain_ms = math.min(
							120,
							wait_opts.timeout_ms and wait_opts.timeout_ms > 0 and wait_opts.timeout_ms or 120
						)
						mare.task.sleep(drain_ms, done_token)
					end
					local state = self:status()
					state.cancelled = true
					return state
				end
				if
					deadline
					and mare.task.clock() >= deadline
					and (self.background or self.cancelled or wait_opts.timeout_ms < self.timeout_ms)
				then
					break
				end
				mare.task.sleep(cfg.poll_interval_ms, done_token)
			end
			if self.done and wait_opts.timeout_ms then
				-- Let any wait({}) watcher (e.g. jobs registry) observe completion first.
				mare.task.sleep(0)
			end
			return self:status()
		end
		function op:stop(stop_opts)
			self:kill()
			self:wait({ timeout_ms = (stop_opts or {}).grace_ms or cfg.stop_grace_ms })
			return { stopped = self.done or false, stop_unconfirmed = not self.done }
		end
		if type(opts.before_write) == "function" then
			local bok, berr = pcall(opts.before_write, op)
			if not bok then
				op.done = true
				done_token:cancel()
				r.busy, r.operation, r.job = false, nil, nil
				error(berr, 0)
			end
		end
		local ok, err = pcall(r.pty.write, r.pty, text)
		if not ok then
			op.done = true
			done_token:cancel()
			r.busy, r.operation, r.job = false, nil, nil
			error(err, 0)
		end
		op.worker = ctx:spawn(function()
			local wok, werr = pcall(poll_operation, cfg, caps, r, op, token, op_cancel)
			op.error = not wok and tostring(werr) or nil
			if r.operation == op then
				r.busy, r.operation, r.job = false, nil, nil
			end
			op.done = true
			done_token:cancel()
		end)
		return op
	end
	return M
end
