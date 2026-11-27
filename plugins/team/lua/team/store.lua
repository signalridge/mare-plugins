local board_mod = require("team.board")

local M = {}

local function now_ms()
	return mare and mare.task and mare.task.now and math.floor(mare.task.now()) or 0
end

local function is_cancelled(cancel)
	return cancel ~= nil and type(cancel.is_cancelled) == "function" and cancel:is_cancelled()
end

local function emit_event(ctx, name, payload)
	if not ctx then
		return
	end
	local bus = ctx.bus
	if type(bus) == "table" and type(bus.emit) == "function" then
		local ok, err = pcall(bus.emit, bus, name, payload)
		if not ok and mare and type(mare.log) == "function" then
			pcall(mare.log, "warn", ("team event %s failed: %s"):format(tostring(name), tostring(err)))
		end
	elseif type(ctx.emit) == "function" then
		pcall(ctx.emit, ctx, name, payload)
	end
end

local function safe_name(s)
	return tostring(s):gsub("[^%w._-]", "_")
end

local function serialize_board(board)
	local cloned = board_mod.clone_board(board)
	local order = mare and mare.json and mare.json.array and mare.json.array({}) or {}
	for i, id in ipairs(cloned.order) do
		order[i] = id
	end
	cloned.order = order
	return cloned
end

function M.create(ctx, cfg, svc, on_change)
	local S = {
		board = board_mod.new_board(),
		fault = nil,
		journal_flushed_seq = 0,
	}

	-- FIFO mutex queue with cancellation removal & wakeup handoff.
	local locked = false
	local waiters = {}

	local function wake_next()
		while #waiters > 0 do
			local entry = table.remove(waiters, 1)
			if not entry.cancelled and entry.tx:send(true) then
				return true
			end
		end
		return false
	end

	local function remove_waiter(entry)
		for i = #waiters, 1, -1 do
			if waiters[i] == entry then
				table.remove(waiters, i)
				return true
			end
		end
		return false
	end

	local function acquire_queue(cancel)
		if is_cancelled(cancel) then
			return false, "cancelled", "cancelled"
		end
		while locked do
			local tx, rx = mare.task.channel(1)
			local entry = { tx = tx, cancelled = false }
			waiters[#waiters + 1] = entry
			local settled = false
			local _waiter_guard <close> = setmetatable({}, {
				__close = function()
					if not settled then
						entry.cancelled = true
						remove_waiter(entry)
						if not locked then
							wake_next()
						end
					end
				end,
			})
			local picked = true
			if cancel and type(cancel.wait) == "function" then
				local idx = mare.task.select(function()
					rx:recv()
					return true
				end, function()
					cancel:wait()
					return false
				end)
				picked = idx == 1
			else
				rx:recv()
			end
			if not picked or is_cancelled(cancel) then
				entry.cancelled = true
				remove_waiter(entry)
				settled = true
				if not locked then
					wake_next()
				end
				return false, "cancelled", "cancelled"
			end
			settled = true
		end
		locked = true
		return true
	end

	local function release_queue()
		locked = false
		wake_next()
	end

	local host_tx, host_rx
	if type(ctx.spawn) == "function" and mare and mare.task and type(mare.task.channel) == "function" then
		host_tx, host_rx = mare.task.channel()
		ctx:spawn(function()
			while true do
				local work = host_rx:recv()
				if not work then
					break
				end
				local result = table.pack(pcall(work.run))
				if work.reply then
					work.reply:send(result)
				end
			end
		end)
		local ok_eff, eff_fn = pcall(function()
			return ctx.effect
		end)
		if ok_eff and type(eff_fn) == "function" then
			eff_fn(ctx, function()
				return function()
					if host_tx then
						pcall(host_tx.close, host_tx)
					end
				end
			end)
		end
	end

	local function in_host(fn)
		if not host_tx then
			return fn()
		end
		local tx, rx = mare.task.channel()
		local _rx_guard <close> = setmetatable({}, {
			__close = function()
				rx:close()
			end,
		})
		if not host_tx:send({ run = fn, reply = tx }) then
			return nil, "team persistence worker is unavailable", "persist_failed"
		end
		local result = rx:recv()
		if not result then
			return nil, "team persistence worker stopped", "persist_failed"
		end
		if not result[1] then
			error(result[2], 0)
		end
		return table.unpack(result, 2, result.n)
	end

	local function session_info()
		local sess = svc.session
		if not sess or type(sess.info) ~= "function" then
			return {}
		end
		local ok, info = pcall(sess.info, sess)
		return ok and type(info) == "table" and info or {}
	end

	function S.session_info()
		return session_info()
	end

	local function ensure_parent_dir(path)
		if not (mare and mare.fs and mare.fs.mkdir) then
			return true
		end
		local dir = path:match("^(.+)/[^/]+$")
		if not dir then
			return true
		end
		local ok, err = pcall(mare.fs.mkdir, dir)
		if not ok then
			return false, tostring(err)
		end
		return true
	end

	local function with_file_lock(path, cancel, fn)
		if not (mare and mare.lock and type(mare.lock.file) == "function") then
			return fn()
		end
		local ok_dir, derr = ensure_parent_dir(path)
		if not ok_dir then
			return nil, "failed to prepare team directory: " .. tostring(derr), "persist_failed"
		end
		local ok_l, guard_or_err = pcall(mare.lock.file, path .. ".lock", { timeout_ms = 5000, cancel = cancel })
		if not ok_l or not guard_or_err then
			local msg = tostring(guard_or_err or "lock failed")
			if msg:find("aborted", 1, true) or is_cancelled(cancel) then
				return nil, "cancelled", "cancelled"
			end
			return nil, "failed to lock team board: " .. msg, "persist_failed"
		end
		local guard = guard_or_err
		local _lock_guard <close> = setmetatable({}, {
			__close = function()
				pcall(guard.release, guard)
			end,
		})
		return fn()
	end

	local cached_session_id = nil
	local cached_parent_session_id = nil

	local function resolve_parent_session_id(info)
		if type(info) ~= "table" or info.ephemeral then
			return nil
		end
		local sid = (type(info.session_id) == "string" and info.session_id ~= "") and info.session_id or nil
		if not sid then
			return nil
		end
		if cached_session_id == sid then
			return cached_parent_session_id
		end
		cached_session_id = sid
		cached_parent_session_id = nil
		local sess = svc.session
		if sess and require("mare_lib").callable(sess.get) then
			local ok_g, snap = pcall(sess.get, sess, sid)
			if
				ok_g
				and type(snap) == "table"
				and type(snap.parent_session_id) == "string"
				and snap.parent_session_id ~= ""
			then
				cached_parent_session_id = snap.parent_session_id
			end
		end
		return cached_parent_session_id
	end

	local function resolve_shared_context(info)
		if cfg.shared_file == false then
			return nil, nil
		end
		local state_dir = mare and mare.paths and mare.paths.state
		if type(state_dir) ~= "string" or state_dir == "" then
			return nil, nil
		end
		if mare and mare.mode == "child" then
			local sid = (type(cfg.session_id) == "string" and cfg.session_id ~= "") and cfg.session_id
				or resolve_parent_session_id(info)
			if sid then
				return state_dir .. "/team/" .. safe_name(sid) .. ".json", sid
			end
			return nil, nil
		end
		if type(info) ~= "table" or info.ephemeral or type(info.session_id) ~= "string" or info.session_id == "" then
			return nil, nil
		end
		local sid = (type(cfg.session_id) == "string" and cfg.session_id ~= "") and cfg.session_id or info.session_id
		return state_dir .. "/team/" .. safe_name(sid) .. ".json", sid
	end

	local function read_disk_locked(path, session_id)
		if not (path and mare and mare.fs and mare.fs.read) then
			return nil, nil, nil
		end
		local ok_r, raw, r_err, r_kind = pcall(mare.fs.read, path)
		if not ok_r then
			return nil, "failed to read team mirror: " .. tostring(raw), "persist_failed"
		end
		if raw == nil then
			if r_kind == "not_found" then
				return nil, nil, nil
			end
			return nil, "failed to read team mirror: " .. tostring(r_err or "read failed"), "persist_failed"
		end
		if type(raw) ~= "string" or raw == "" then
			return nil, "corrupt team mirror: empty or non-string document", "persist_failed"
		end
		local ok_d, doc = pcall(mare.json.decode_lossless, raw)
		if not ok_d or type(doc) ~= "table" or doc.version ~= 1 then
			return nil, "corrupt team mirror: invalid JSON or unsupported version", "persist_failed"
		end
		if session_id and doc.session_id ~= nil and doc.session_id ~= session_id then
			return nil, "team mirror session mismatch", "persist_failed"
		end
		return doc, nil, nil
	end

	local function write_disk_locked(path, session_id, board, ops)
		if not (mare and mare.fs and mare.fs.write) then
			return false, "mare.fs.write unavailable"
		end
		local ok_dir, derr = ensure_parent_dir(path)
		if not ok_dir then
			return false, derr
		end
		local ops_arr = mare and mare.json and mare.json.array and mare.json.array({}) or {}
		for i, op in ipairs(ops or {}) do
			ops_arr[i] = op
		end
		local payload = mare.json.encode({
			version = 1,
			session_id = session_id,
			board = serialize_board(board),
			ops = ops_arr,
		})
		local ok_w, wres, werr = pcall(mare.fs.write, path, payload, { atomic = true, mode = 384 })
		if not ok_w then
			return false, tostring(wres)
		end
		if wres == false or wres == nil then
			return false, tostring(werr or "write failed")
		end
		return true
	end

	local function can_record_session(info)
		local sess = svc.session
		if mare and mare.mode == "child" then
			return false
		end
		if not sess or not require("mare_lib").callable(sess.add_record) or info.ephemeral or info.readonly then
			return false
		end
		return true, sess
	end

	local function append_session_record(info, rec)
		local ok_can, sess = can_record_session(info)
		if not ok_can then
			return true
		end
		local ok, saved, err = pcall(sess.add_record, sess, "team/task", rec, {
			persist = true,
			sync = true,
			session_id = info.session_id,
			session_epoch = info.session_epoch,
		})
		if not ok or not saved then
			local detail = not ok and (require("mare_lib").error_message(saved) or saved)
				or (require("mare_lib").error_message(err) or err)
			return false, "failed to persist team record: " .. tostring(detail), "persist_failed"
		end
		local after = session_info()
		if after.session_id ~= info.session_id or after.session_epoch ~= info.session_epoch then
			return false, "session changed while saving team record", "stale_session"
		end
		if type(rec.seq) == "number" and rec.seq > S.journal_flushed_seq then
			S.journal_flushed_seq = rec.seq
		end
		return true
	end

	local function apply_disk_doc_to(target_board, doc)
		local ops = type(doc.ops) == "table" and doc.ops or {}
		local board = target_board
		if type(doc.board) == "table" and (doc.board.journal_seq or 0) > (board.journal_seq or 0) then
			local adopted = board_mod.clone_board(doc.board)
			for _, op in ipairs(ops) do
				if type(op) == "table" and (op.seq or 0) > (adopted.journal_seq or 0) then
					board_mod.apply_record(adopted, op)
				end
			end
			board = adopted
		elseif #ops > 0 then
			for _, op in ipairs(ops) do
				if type(op) == "table" and (op.seq or 0) > (board.journal_seq or 0) then
					board_mod.apply_record(board, op)
				end
			end
		end
		return board, ops
	end

	local function reconcile_locked(path, session_id, info)
		local doc, r_err, r_code = read_disk_locked(path, session_id)
		if not doc then
			if r_err then
				return nil, false, r_err, r_code, true, 0
			end
			return {}, true, nil, nil, false, 0
		end
		local disk_seq = type(doc.board) == "table" and (doc.board.journal_seq or 0) or 0
		local working, ops = apply_disk_doc_to(board_mod.clone_board(S.board), doc)
		-- Flush any child-originated disk ops into parent session journal for /resume fidelity.
		if can_record_session(info) then
			for _, op in ipairs(ops) do
				if type(op) == "table" and (op.seq or 0) > S.journal_flushed_seq then
					local ok_p, p_err, p_code = append_session_record(info, op)
					if not ok_p then
						return ops, false, p_err, p_code, true, disk_seq
					end
				end
			end
		end
		S.board = working
		return ops, true, nil, nil, true, disk_seq
	end

	local MAX_OPS_HISTORY = 256

	local function build_next_ops(existing_ops, rec, info)
		if rec.op == "clear" then
			return { rec }
		end
		local next_ops = {}
		for _, op in ipairs(existing_ops or {}) do
			next_ops[#next_ops + 1] = op
		end
		next_ops[#next_ops + 1] = rec
		if #next_ops > MAX_OPS_HISTORY then
			local kept = {}
			local start_idx = #next_ops - MAX_OPS_HISTORY + 1
			for i, op in ipairs(next_ops) do
				local unflushed = can_record_session(info)
					and type(op) == "table"
					and (op.seq or 0) > S.journal_flushed_seq
				if i >= start_idx or unflushed then
					kept[#kept + 1] = op
				end
			end
			next_ops = kept
		end
		return next_ops
	end

	local function mutate(cancel, fn)
		local function run_committed()
			local ok_q, q_err, q_code = acquire_queue(cancel)
			if not ok_q then
				return nil, q_err, q_code
			end
			local _guard <close> = setmetatable({}, {
				__close = function()
					release_queue()
				end,
			})
			if S.fault then
				return nil, S.fault, "persist_failed"
			end
			local info = session_info()
			if info.readonly then
				return nil, "team board cannot be modified in a read-only session", "read_only"
			end
			if is_cancelled(cancel) then
				return nil, "team operation cancelled before saving", "cancelled"
			end

			local function run_locked(mirror_path, mirror_sid)
				local existing_ops, ok_rec, r_err, r_code, had_doc = {}, true, nil, nil, false
				if mirror_path then
					existing_ops, ok_rec, r_err, r_code, had_doc = reconcile_locked(mirror_path, mirror_sid, info)
					if not ok_rec then
						return nil, r_err, r_code
					end
				end
				local prev_board = board_mod.clone_board(S.board)
				local staged = board_mod.clone_board(S.board)
				local now = now_ms()
				local rec, err, code = fn(staged, now, info)
				if not rec then
					return nil, err, code
				end

				if is_cancelled(cancel) then
					return nil, "team operation cancelled before saving", "cancelled"
				end

				local next_ops = build_next_ops(existing_ops, rec, info)

				if mirror_path then
					local ok_w, werr = write_disk_locked(mirror_path, mirror_sid, staged, next_ops)
					if not ok_w then
						return nil, "failed to write shared team state: " .. tostring(werr), "persist_failed"
					end
				end

				if can_record_session(info) then
					local ok_p, p_err, p_code = append_session_record(info, rec)
					if not ok_p then
						if mirror_path then
							if had_doc then
								write_disk_locked(mirror_path, mirror_sid, prev_board, existing_ops)
							elseif mare and mare.fs and type(mare.fs.remove) == "function" then
								pcall(mare.fs.remove, mirror_path)
							else
								write_disk_locked(mirror_path, mirror_sid, prev_board, existing_ops)
							end
						end
						return nil, p_err, p_code
					end
				end

				S.board = staged
				local target_id = (rec.task and rec.task.id) or rec.id
				local view_snap = target_id
						and staged.tasks[target_id]
						and board_mod.task_view(staged, staged.tasks[target_id], now)
					or nil
				return { rec = rec, view = view_snap }
			end

			return in_host(function()
				local mirror_path, mirror_sid = resolve_shared_context(info)
				if mirror_path then
					return with_file_lock(mirror_path, cancel, function()
						return run_locked(mirror_path, mirror_sid)
					end)
				end
				return run_locked(nil, nil)
			end)
		end

		local res, err, code = run_committed()
		if not res then
			return nil, err, code
		end
		if on_change then
			pcall(on_change)
		end
		return res.rec, res.view
	end

	local function sync_from_disk_readonly()
		local ok_q = acquire_queue()
		if not ok_q then
			return
		end
		local _guard <close> = setmetatable({}, {
			__close = function()
				release_queue()
			end,
		})
		local info = session_info()
		in_host(function()
			local mirror_path, mirror_sid = resolve_shared_context(info)
			if not mirror_path then
				return
			end
			if mare and mare.fs and type(mare.fs.exists) == "function" and not mare.fs.exists(mirror_path) then
				return
			end
			with_file_lock(mirror_path, nil, function()
				local doc = read_disk_locked(mirror_path, mirror_sid)
				if doc then
					S.board = apply_disk_doc_to(S.board, doc)
				end
			end)
		end)
	end

	function S.cached_snapshot(opts)
		return board_mod.snapshot(S.board, opts, now_ms())
	end

	function S.restore()
		local ok_q = acquire_queue()
		if not ok_q then
			return false, "cancelled"
		end
		local _guard <close> = setmetatable({}, {
			__close = function()
				release_queue()
			end,
		})
		S.fault = nil
		S.journal_flushed_seq = 0

		in_host(function()
			local info = session_info()
			local sess = svc.session
			local loaded_from_journal = false
			if not (mare and mare.mode == "child") and sess and require("mare_lib").callable(sess.list_records) then
				local ok_r, recs = pcall(require("mare_lib").all_records, sess, "team/task")
				if ok_r and type(recs) == "table" then
					local rebuilt, err = board_mod.replay(recs)
					if not rebuilt then
						S.fault = "Invalid team journal: " .. tostring(err)
						S.board = board_mod.new_board()
					else
						S.board = rebuilt
						S.journal_flushed_seq = rebuilt.journal_seq or 0
						loaded_from_journal = true
					end
				end
			end
			if not loaded_from_journal and not S.fault then
				S.board = board_mod.new_board()
			end

			if not S.fault then
				local mirror_path, mirror_sid = resolve_shared_context(info)
				if mirror_path then
					if info.readonly then
						if
							not (
								mare
								and mare.fs
								and type(mare.fs.exists) == "function"
								and not mare.fs.exists(mirror_path)
							)
						then
							local doc, r_err = read_disk_locked(mirror_path, mirror_sid)
							if doc then
								S.board = apply_disk_doc_to(S.board, doc)
							elseif r_err then
								S.fault = r_err
								S.board = board_mod.new_board()
							end
						end
					else
						local _, lerr = with_file_lock(mirror_path, nil, function()
							local ops, ok_rec, r_err, _, had_doc, disk_seq =
								reconcile_locked(mirror_path, mirror_sid, info)
							if not ok_rec then
								S.fault = r_err
								S.board = board_mod.new_board()
								return nil, r_err
							end
							if
								not (mare and mare.mode == "child")
								and (S.board.journal_seq or 0) > 0
								and (not had_doc or (S.board.journal_seq or 0) > disk_seq)
							then
								local ok_w, werr = write_disk_locked(mirror_path, mirror_sid, S.board, ops)
								if not ok_w then
									return nil, werr
								end
							end
							return true
						end)
						if lerr and not S.fault and mare and type(mare.log) == "function" then
							pcall(mare.log, "warn", "team mirror seed on restore failed: " .. tostring(lerr))
						end
					end
				end
			end
		end)
		if on_change then
			pcall(on_change)
		end
		return S.fault == nil, S.fault
	end

	function S.list(opts)
		sync_from_disk_readonly()
		return board_mod.snapshot(S.board, opts, now_ms())
	end

	function S.create(args, cancel)
		local rec, task, code = mutate(cancel, function(b, now)
			return board_mod.create(b, args, now, cfg)
		end)
		if not rec then
			return nil, task, code
		end
		emit_event(ctx, "team/task-created", { task_id = task.id, title = task.title, status = task.status })
		return task
	end

	function S.claim(args, cancel)
		local rec, task, code = mutate(cancel, function(b, now)
			return board_mod.claim(b, args, now, cfg)
		end)
		if not rec then
			return nil, task, code
		end
		emit_event(ctx, "team/task-claimed", { task_id = task.id, owner = task.owner, revision = task.revision })
		return task
	end

	function S.update(args, cancel)
		local unblocked = nil
		local rec, task, code = mutate(cancel, function(b, now)
			local r, u, e = board_mod.update(b, args, now, cfg)
			if type(r) == "table" then
				unblocked = u
				return r
			end
			return nil, u, e
		end)
		if not rec then
			return nil, task, code
		end
		emit_event(ctx, "team/task-updated", { task_id = task.id, status = task.status, revision = task.revision })
		if unblocked ~= nil then
			emit_event(ctx, "team/task-completed", {
				task_id = task.id,
				owner = task.owner,
				unblocked_count = #unblocked,
			})
		end
		return task
	end

	function S.complete(args, cancel)
		local unblocked = nil
		local rec, task, code = mutate(cancel, function(b, now)
			local r, u, e = board_mod.complete(b, args, now)
			if type(r) == "table" then
				unblocked = u
				return r
			end
			return nil, u, e
		end)
		if not rec then
			return nil, task, code
		end
		emit_event(ctx, "team/task-completed", {
			task_id = task.id,
			owner = task.owner,
			unblocked_count = #(unblocked or {}),
		})
		return { task = task, unblocked = unblocked or mare.json.array({}) }
	end

	function S.release_owner(owner_id, reason)
		if not owner_id or owner_id == "" then
			return 0
		end
		return S.release_owners({ owner_id }, reason)
	end

	function S.release_owners(owner_ids, reason, expected_parent)
		if type(owner_ids) ~= "table" or #owner_ids == 0 then
			return 0
		end
		local released_count = 0
		local rec, err = mutate(nil, function(b, now, info)
			if type(expected_parent) == "table" then
				if
					expected_parent.session_id ~= nil
					and info.session_id ~= nil
					and expected_parent.session_id ~= info.session_id
				then
					return nil, "noop", "noop"
				end
				if
					expected_parent.session_epoch ~= nil
					and info.session_epoch ~= nil
					and expected_parent.session_epoch ~= info.session_epoch
				then
					return nil, "noop", "noop"
				end
			end
			local r, n = board_mod.release_owners(b, owner_ids, now, reason)
			if not r then
				return nil, "noop", "noop"
			end
			released_count = n or 0
			return r
		end)
		if not rec then
			if err ~= "noop" and mare and type(mare.log) == "function" then
				pcall(mare.log, "warn", "team release_owners failed: " .. tostring(err))
			end
			return 0
		end
		return released_count
	end

	function S.clear(cancel)
		local cleared = 0
		local rec, err, code = mutate(cancel, function(b, now)
			local r, n = board_mod.clear(b, now)
			cleared = n
			return r
		end)
		if not rec then
			return nil, err, code
		end
		emit_event(ctx, "team/board-cleared", { cleared = cleared })
		return { cleared = cleared }
	end

	return S
end

return M
