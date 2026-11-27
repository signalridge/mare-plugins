local M = {}

local function session_writable(session)
	if
		not session
		or not require("mare_lib").callable(session.info)
		or not require("mare_lib").callable(session.add_record)
	then
		return false
	end
	if mare and mare.mode == "child" then
		return false
	end
	local ok, info = pcall(session.info, session)
	if not ok or type(info) ~= "table" then
		return false
	end
	if info.ephemeral or info.readonly or info.unstable then
		return false
	end
	return true, info
end

--- Create a serialized monotonic prefix writer for one workflow run.
--- Rules:
---   - At most one `workflow/run-start` per run
---   - Every member `seq` is unique and pairs `workflow/agent-start` -> `workflow/agent-end`
---   - `workflow/run-end` cannot be written while any member is still open
---   - All appends are serialized via a FIFO queue; `failed` is rechecked on dequeue;
---     monotonic state advances only after confirmed `session:record` acknowledgement.
function M.new_writer(get_session, owner)
	local writable, info = session_writable(get_session())
	local state = {
		disabled = not writable,
		failed = false,
		started = false,
		ended = false,
		open_seqs = {},
		seen_seqs = {},
		owner = owner or (info and { id = info.session_id, generation = info.session_epoch }) or nil,
		last_error = nil,
	}

	local writing = false
	local waiters = {}

	local function with_write_lock(fn)
		if writing then
			local tx, rx = mare.task.channel(1)
			local entry = { tx = tx, cancelled = false }
			waiters[#waiters + 1] = entry
			local handed_off_self = false
			local _w_guard <close> = setmetatable({}, {
				__close = function()
					if not handed_off_self then
						entry.cancelled = true
						for i = #waiters, 1, -1 do
							if waiters[i] == entry then
								table.remove(waiters, i)
								break
							end
						end
						-- If a previous writer already handed `writing = true` to us before abort, pass it on.
						if writing and (rx.try_recv and rx:try_recv() ~= nil) then
							local next_handed = false
							while #waiters > 0 do
								local next_entry = table.remove(waiters, 1)
								if not next_entry.cancelled and next_entry.tx:send(true) then
									next_handed = true
									break
								end
							end
							if not next_handed then
								writing = false
							end
						end
					end
				end,
			})
			local woken = rx:recv()
			if not woken then
				return false
			end
			handed_off_self = true
		else
			writing = true
		end
		local _guard <close> = setmetatable({}, {
			__close = function()
				local handed_off = false
				while #waiters > 0 do
					local next_entry = table.remove(waiters, 1)
					if not next_entry.cancelled and next_entry.tx:send(true) then
						handed_off = true
						break
					end
				end
				if not handed_off then
					writing = false
				end
			end,
		})
		return fn()
	end

	local function write_record(kind, data, sync)
		if state.disabled or state.failed then
			return false
		end
		local session = get_session()
		local ok_now, cur = session_writable(session)
		if not ok_now then
			state.failed = true
			return false
		end
		if state.owner and (cur.session_id ~= state.owner.id or cur.session_epoch ~= state.owner.generation) then
			state.failed = true
			state.last_error = "session changed during workflow recording"
			return false
		end
		local opts = { persist = true, sync = sync == true }
		if state.owner then
			opts.session_id = state.owner.id
			opts.session_epoch = state.owner.generation
		end
		local ok, saved, err = pcall(session.add_record, session, kind, data, opts)
		if not ok or not saved then
			state.failed = true
			state.last_error = ok and tostring(require("mare_lib").error_message(err) or err or "write failed")
				or tostring(require("mare_lib").error_message(saved) or saved)
			if mare and type(mare.log) == "function" then
				pcall(mare.log, "warn", ("workflow record %s failed: %s"):format(kind, state.last_error))
			end
			return false
		end
		return true
	end

	local writer = {}

	function writer.run_start(data)
		return with_write_lock(function()
			if state.disabled or state.failed or state.started or state.ended then
				return false
			end
			if not write_record("workflow/run-start", data, true) then
				return false
			end
			state.started = true
			return true
		end)
	end

	function writer.agent_start(seq, data)
		return with_write_lock(function()
			if not state.started or state.ended or state.failed or state.disabled then
				return false
			end
			if state.seen_seqs[seq] then
				return false
			end
			if not write_record("workflow/agent-start", data, false) then
				return false
			end
			state.seen_seqs[seq] = true
			state.open_seqs[seq] = true
			return true
		end)
	end

	function writer.agent_end(seq, data)
		return with_write_lock(function()
			if not state.started or state.ended or state.failed or state.disabled then
				return false
			end
			if not state.open_seqs[seq] then
				return false
			end
			if not write_record("workflow/agent-end", data, false) then
				return false
			end
			state.open_seqs[seq] = nil
			return true
		end)
	end

	function writer.run_end(data)
		return with_write_lock(function()
			if not state.started or state.ended or state.failed or state.disabled then
				return false
			end
			if next(state.open_seqs) ~= nil then
				return false
			end
			if not write_record("workflow/run-end", data, true) then
				return false
			end
			state.ended = true
			return true
		end)
	end

	function writer.status()
		return {
			disabled = state.disabled,
			failed = state.failed,
			started = state.started,
			ended = state.ended,
			last_error = state.last_error,
		}
	end

	return writer
end

--- Reconstruct workflow run summaries from parent session records (for /resume & history).
function M.reconstruct(session)
	if not session or not require("mare_lib").callable(session.list_records) then
		return {}
	end
	local function fetch(kind)
		local ok, list = pcall(require("mare_lib").all_records, session, kind)
		return ok and type(list) == "table" and list or {}
	end

	local runs_by_id = {}
	local order = {}

	for _, r in ipairs(fetch("workflow/run-start")) do
		if type(r) == "table" and type(r.run_id) == "string" and not runs_by_id[r.run_id] then
			local run = {
				run_id = r.run_id,
				name = r.name or r.run_id,
				description = r.description or "",
				meta = r.meta,
				started_at_ms = r.started_at_ms,
				ended_at_ms = nil,
				duration_ms = nil,
				status = "interrupted",
				recorded_in_session = true,
				background = r.background == true,
				agents = {},
				by_seq = {},
				phases = {},
			}
			runs_by_id[r.run_id] = run
			order[#order + 1] = run
		end
	end

	for _, r in ipairs(fetch("workflow/agent-start")) do
		local run = type(r) == "table" and runs_by_id[r.run_id]
		if run and r.seq ~= nil and not run.by_seq[r.seq] then
			local agent = {
				seq = r.seq,
				label = r.label or ("agent-" .. tostring(r.seq)),
				phase = r.phase,
				model = r.model,
				provider = r.provider,
				started_at_ms = r.started_at_ms,
				status = "interrupted",
				ok = false,
			}
			run.by_seq[r.seq] = agent
			run.agents[#run.agents + 1] = agent
		end
	end

	for _, r in ipairs(fetch("workflow/agent-end")) do
		local run = type(r) == "table" and runs_by_id[r.run_id]
		local agent = run and run.by_seq[r.seq]
		if agent then
			agent.status = r.status or (r.ok and "completed" or "failed")
			agent.ok = r.ok == true
			agent.error = r.error
			agent.duration_ms = r.duration_ms
			agent.ended_at_ms = r.ended_at_ms
			agent.usage = r.usage
			agent.summary = r.summary
		end
	end

	for _, r in ipairs(fetch("workflow/run-end")) do
		local run = type(r) == "table" and runs_by_id[r.run_id]
		if run then
			run.status = r.status or "completed"
			run.ended_at_ms = r.ended_at_ms
			run.duration_ms = r.duration_ms
			run.error = r.error
			run.stop_unconfirmed = r.stop_unconfirmed == true
			if r.background ~= nil then
				run.background = r.background == true
			end
		end
	end

	for _, run in ipairs(order) do
		table.sort(run.agents, function(a, b)
			return (tonumber(a.seq) or 0) < (tonumber(b.seq) or 0)
		end)
		local completed, failed, cancelled, interrupted = 0, 0, 0, 0
		for _, a in ipairs(run.agents) do
			if a.status == "completed" then
				completed = completed + 1
			elseif a.status == "cancelled" then
				cancelled = cancelled + 1
			elseif a.status == "interrupted" or a.status == "stop_unconfirmed" then
				interrupted = interrupted + 1
			else
				failed = failed + 1
			end
		end
		run.counts = {
			total = #run.agents,
			completed = completed,
			failed = failed,
			cancelled = cancelled,
			interrupted = interrupted,
		}
	end

	return order
end

return M
