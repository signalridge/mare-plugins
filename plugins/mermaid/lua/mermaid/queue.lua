local M = {}

local DEFAULT_MAX_CONCURRENT = 2
local DEFAULT_MAX_WAITERS = 16

--- Wait for `done_token` unless `cancel_token` fires first.
local function await_token(done_token, cancel_token)
	if done_token:is_cancelled() then
		return true
	end
	if cancel_token and cancel_token:is_cancelled() then
		return false
	end
	if not cancel_token then
		done_token:wait()
		return true
	end
	local winner = mare.task.select(function()
		done_token:wait()
		return 1
	end, function()
		cancel_token:wait()
		return 2
	end)
	return winner == 1
end

--- Create a bounded priority render queue with occurrence superseding and inflight dedup.
function M.new(opts)
	opts = opts or {}
	local max_concurrent = opts.max_concurrent or DEFAULT_MAX_CONCURRENT
	local max_waiters = opts.max_waiters or DEFAULT_MAX_WAITERS
	local max_inflight = max_concurrent + max_waiters

	local inflight = {}
	local occurrences = {}
	local active_workers = 0
	local worker_waiters = {}
	local next_waiter_seq = 0
	local queue = {}

	local function remove_waiter(target)
		if not target then
			return
		end
		target.cancelled = true
		for index = #worker_waiters, 1, -1 do
			if worker_waiters[index] == target then
				table.remove(worker_waiters, index)
			end
		end
	end

	local function prune_waiters()
		for index = #worker_waiters, 1, -1 do
			local w = worker_waiters[index]
			if
				w.cancelled
				or w.ready:is_cancelled()
				or (w.job and (w.job.cancel:is_cancelled() or w.job.done:is_cancelled()))
			then
				w.cancelled = true
				table.remove(worker_waiters, index)
			end
		end
	end

	local function worst_waiter_index()
		local worst_idx, worst = nil, nil
		for index, w in ipairs(worker_waiters) do
			if not worst or w.priority > worst.priority or (w.priority == worst.priority and w.seq > worst.seq) then
				worst_idx, worst = index, w
			end
		end
		return worst_idx, worst
	end

	local function evict_waiter(index, waiter)
		if index and worker_waiters[index] == waiter then
			table.remove(worker_waiters, index)
		else
			remove_waiter(waiter)
		end
		waiter.cancelled = true
		waiter.ready:cancel()
		local job = waiter.job
		if job then
			if job.slot_waiter == waiter then
				job.slot_waiter = nil
			end
			if inflight[job.inflight_key] == job then
				inflight[job.inflight_key] = nil
			end
			if not job.done:is_cancelled() then
				job.cancel:cancel()
			end
		end
	end

	local function detach_waiter(job, waiter)
		if not job or not waiter or not job.waiters[waiter] then
			return
		end
		job.waiters[waiter] = nil
		if next(job.waiters) == nil then
			if inflight[job.inflight_key] == job then
				inflight[job.inflight_key] = nil
			end
			if job.slot_waiter then
				local slot_waiter = job.slot_waiter
				job.slot_waiter = nil
				remove_waiter(slot_waiter)
				slot_waiter.ready:cancel()
			end
			if not job.done:is_cancelled() then
				job.cancel:cancel()
			end
		end
	end

	local function inflight_capacity_for(priority)
		local count = 0
		for k, existing in pairs(inflight) do
			if existing.done:is_cancelled() or existing.cancel:is_cancelled() or next(existing.waiters) == nil then
				inflight[k] = nil
			else
				count = count + 1
			end
		end
		if count < max_inflight then
			return true
		end
		prune_waiters()
		local worst_idx, worst = worst_waiter_index()
		if worst and priority < worst.priority then
			evict_waiter(worst_idx, worst)
			return true
		end
		return false
	end

	--- Acquire a worker slot, waiting in priority order if all slots are busy.
	function queue:acquire_slot(cancel_token, priority, job)
		if cancel_token and cancel_token:is_cancelled() then
			return false
		end
		if active_workers < max_concurrent then
			active_workers = active_workers + 1
			return true
		end
		prune_waiters()
		local eff_priority = priority or 2
		if #worker_waiters >= max_waiters then
			local worst_idx, worst = worst_waiter_index()
			if worst and eff_priority < worst.priority then
				evict_waiter(worst_idx, worst)
			else
				return false
			end
		end
		next_waiter_seq = next_waiter_seq + 1
		local waiter = {
			ready = mare.task.token(),
			priority = eff_priority,
			seq = next_waiter_seq,
			granted = false,
			cancelled = false,
			job = job,
		}
		if job then
			job.slot_waiter = waiter
		end
		worker_waiters[#worker_waiters + 1] = waiter
		await_token(waiter.ready, cancel_token)
		if job and job.slot_waiter == waiter then
			job.slot_waiter = nil
		end
		if waiter.granted then
			return true, waiter
		end
		remove_waiter(waiter)
		return false, waiter
	end

	--- Release an active worker slot, handing off directly to the highest-priority waiter.
	function queue:release_slot()
		local best_index, best_waiter = nil, nil
		for index = #worker_waiters, 1, -1 do
			local w = worker_waiters[index]
			if w.cancelled or w.ready:is_cancelled() then
				table.remove(worker_waiters, index)
			elseif
				not best_waiter
				or w.priority < best_waiter.priority
				or (w.priority == best_waiter.priority and w.seq < best_waiter.seq)
			then
				best_index, best_waiter = index, w
			end
		end
		if best_index and best_waiter then
			table.remove(worker_waiters, best_index)
			best_waiter.granted = true
			if best_waiter.job and best_waiter.job.slot_waiter == best_waiter then
				best_waiter.job.slot_waiter = nil
			end
			best_waiter.ready:cancel()
			return
		end
		active_workers = math.max(0, active_workers - 1)
	end

	--- Join an active inflight job or spawn one, handling slot execution and cleanup.
	function queue:run_deduped(inflight_key, occ_key, priority, cancel_token, execute_fn)
		local prev_occ = occurrences[occ_key]
		local self_waiter = { key = occ_key, priority = priority }
		local job = inflight[inflight_key]
		if job and not job.done:is_cancelled() and not job.cancel:is_cancelled() then
			job.waiters[self_waiter] = true
			if prev_occ then
				prev_occ.superseded = true
				detach_waiter(prev_occ.job, prev_occ.waiter)
			end
			if priority < (job.priority or 2) then
				job.priority = priority
				if job.slot_waiter then
					job.slot_waiter.priority = math.min(job.slot_waiter.priority, priority)
				end
			end
			occurrences[occ_key] = { job = job, waiter = self_waiter }
		else
			if prev_occ then
				prev_occ.superseded = true
				detach_waiter(prev_occ.job, prev_occ.waiter)
				occurrences[occ_key] = nil
			end
			if not inflight_capacity_for(priority) then
				return false, nil, nil
			end
			job = {
				inflight_key = inflight_key,
				priority = priority,
				cancel = mare.task.token(),
				done = mare.task.token(),
				waiters = { [self_waiter] = true },
				artifact = nil,
				err = nil,
			}
			inflight[inflight_key] = job
			occurrences[occ_key] = { job = job, waiter = self_waiter }
			mare.task.spawn(function()
				local ok, rendered
				if queue:acquire_slot(job.cancel, priority, job) then
					ok, rendered = pcall(execute_fn, job.cancel)
					queue:release_slot()
				else
					ok, rendered = true, nil
				end
				if inflight[inflight_key] == job then
					inflight[inflight_key] = nil
				end
				if ok then
					job.artifact = rendered
				else
					job.err = rendered
				end
				job.done:cancel()
			end)
		end
		local settled = await_token(job.done, cancel_token)
		detach_waiter(job, self_waiter)
		if occurrences[occ_key] and occurrences[occ_key].waiter == self_waiter then
			occurrences[occ_key] = nil
		end
		return settled, job.artifact, job.err
	end

	--- Cancel all inflight jobs, occurrences, and queued waiters.
	function queue:cancel_all()
		for _, job in pairs(inflight) do
			job.slot_waiter = nil
			job.cancel:cancel()
			job.done:cancel()
		end
		inflight = {}
		occurrences = {}
		while #worker_waiters > 0 do
			local waiter = table.remove(worker_waiters, 1)
			waiter.cancelled = true
			waiter.ready:cancel()
		end
	end

	return queue
end

return M
