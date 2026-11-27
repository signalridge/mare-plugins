local M = {}

local VALID_STATUS = {
	pending = true,
	in_progress = true,
	completed = true,
	cancelled = true,
}

local VALID_PRIORITY = {
	low = true,
	medium = true,
	high = true,
}

local PRIORITY_RANK = {
	high = 3,
	medium = 2,
	low = 1,
}

local function trim(s)
	if type(s) ~= "string" then
		return ""
	end
	return s:match("^%s*(.-)%s*$") or ""
end

local function copy_list(src)
	local out = mare and mare.json and mare.json.array and mare.json.array({}) or {}
	for i, v in ipairs(src or {}) do
		out[i] = v
	end
	return out
end

local function copy_notes(src)
	local out = mare and mare.json and mare.json.array and mare.json.array({}) or {}
	for i, n in ipairs(src or {}) do
		out[i] = {
			timestamp = n.timestamp,
			author = n.author,
			text = n.text,
		}
	end
	return out
end

local function is_dense_array(list)
	if type(list) ~= "table" then
		return false
	end
	local count = 0
	for k in pairs(list) do
		if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then
			return false
		end
		count = count + 1
	end
	return count == #list
end

local function dedup_ids(list)
	if list ~= nil and not is_dense_array(list) then
		return nil, "blocked_by must be an array of task ID strings"
	end
	local out = {}
	local seen = {}
	for _, id in ipairs(list or {}) do
		if type(id) ~= "string" or trim(id) == "" then
			return nil, "blocked_by entries must be non-empty task ID strings"
		end
		local clean = trim(id)
		if not seen[clean] then
			seen[clean] = true
			out[#out + 1] = clean
		end
	end
	return out
end

function M.new_board()
	return {
		next_seq = 1,
		journal_seq = 0,
		board_gen = 1,
		tasks = {},
		order = {},
	}
end

function M.clone_board(board)
	local copy = {
		next_seq = board.next_seq,
		journal_seq = board.journal_seq,
		board_gen = board.board_gen or 1,
		tasks = {},
		order = {},
	}
	for i, id in ipairs(board.order) do
		copy.order[i] = id
		local t = board.tasks[id]
		if t then
			copy.tasks[id] = {
				id = t.id,
				seq = t.seq,
				title = t.title,
				description = t.description,
				status = t.status,
				priority = t.priority,
				blocked_by = copy_list(t.blocked_by),
				owner = t.owner,
				lease_token = t.lease_token,
				lease_expires_at_ms = t.lease_expires_at_ms,
				revision = t.revision,
				notes = copy_notes(t.notes),
				result = t.result,
				created_at_ms = t.created_at_ms,
				updated_at_ms = t.updated_at_ms,
				completed_at_ms = t.completed_at_ms,
			}
		end
	end
	return copy
end

local function has_path(board, from_id, target_id, visited)
	if from_id == target_id then
		return true
	end
	if visited[from_id] then
		return false
	end
	visited[from_id] = true
	local t = board.tasks[from_id]
	if not t then
		return false
	end
	for _, dep in ipairs(t.blocked_by or {}) do
		if has_path(board, dep, target_id, visited) then
			return true
		end
	end
	return false
end

local function validate_blockers(board, task_id, blockers)
	for _, dep_id in ipairs(blockers) do
		if dep_id == task_id then
			return false, "task cannot depend on itself: " .. task_id, "team.invalid_dependency"
		end
		if not board.tasks[dep_id] then
			return false, "unknown dependency task: " .. dep_id, "team.unknown_task"
		end
		if has_path(board, dep_id, task_id, {}) then
			return false,
				("dependency cycle detected involving %s -> %s"):format(task_id, dep_id),
				"team.invalid_dependency"
		end
	end
	return true
end

local function unresolved_for(board, task)
	local out = mare and mare.json and mare.json.array and mare.json.array({}) or {}
	for _, dep_id in ipairs(task.blocked_by or {}) do
		local dep = board.tasks[dep_id]
		if dep and dep.status ~= "completed" then
			out[#out + 1] = dep_id
		end
	end
	return out
end

local function downstream_blocks(board)
	local map = {}
	for _, id in ipairs(board.order) do
		map[id] = {}
	end
	for _, id in ipairs(board.order) do
		local t = board.tasks[id]
		if t then
			for _, dep_id in ipairs(t.blocked_by or {}) do
				if map[dep_id] then
					table.insert(map[dep_id], id)
				end
			end
		end
	end
	return map
end

function M.task_view(board, task, now, blocks_map)
	local unresolved = unresolved_for(board, task)
	local blocks = blocks_map and blocks_map[task.id] or downstream_blocks(board)[task.id] or {}
	local lease_active = task.status == "in_progress"
		and task.owner ~= nil
		and task.lease_expires_at_ms ~= nil
		and now < task.lease_expires_at_ms
	local lease_stale = task.status == "in_progress"
		and task.owner ~= nil
		and task.lease_expires_at_ms ~= nil
		and now >= task.lease_expires_at_ms
	local ready = task.status == "pending" and #unresolved == 0
	return {
		id = task.id,
		seq = task.seq,
		title = task.title,
		description = task.description,
		status = task.status,
		priority = task.priority,
		blocked_by = copy_list(task.blocked_by),
		blocks = copy_list(blocks),
		unresolved_blockers = unresolved,
		ready = ready,
		blocked = task.status == "pending" and #unresolved > 0,
		owner = task.owner,
		lease_token = task.lease_token,
		lease_expires_at_ms = task.lease_expires_at_ms,
		lease_active = lease_active,
		lease_stale = lease_stale,
		revision = task.revision,
		notes = copy_notes(task.notes),
		result = task.result,
		created_at_ms = task.created_at_ms,
		updated_at_ms = task.updated_at_ms,
		completed_at_ms = task.completed_at_ms,
	}
end

function M.snapshot(board, opts, now)
	opts = opts or {}
	local blocks_map = downstream_blocks(board)
	local tasks = mare and mare.json and mare.json.array and mare.json.array({}) or {}
	local counts = {
		total = 0,
		pending = 0,
		ready = 0,
		blocked = 0,
		in_progress = 0,
		completed = 0,
		cancelled = 0,
	}
	for _, id in ipairs(board.order) do
		local raw = board.tasks[id]
		if raw then
			local v = M.task_view(board, raw, now, blocks_map)
			counts.total = counts.total + 1
			counts[v.status] = counts[v.status] + 1
			if v.ready then
				counts.ready = counts.ready + 1
			elseif v.blocked then
				counts.blocked = counts.blocked + 1
			end
			local keep = true
			if opts.status and v.status ~= opts.status then
				keep = false
			end
			if keep and opts.owner and v.owner ~= opts.owner then
				keep = false
			end
			if keep and opts.ready_only and not v.ready then
				keep = false
			end
			if keep and opts.include_completed == false and (v.status == "completed" or v.status == "cancelled") then
				keep = false
			end
			if keep then
				tasks[#tasks + 1] = v
			end
		end
	end
	return { tasks = tasks, counts = counts }
end

local function make_token()
	if mare and mare.crypto and mare.crypto.random_hex then
		return mare.crypto.random_hex(8)
	end
	return tostring(math.random(100000, 999999))
end

local function validate_lease_ms(lease_ms, default_ms)
	if lease_ms == nil then
		return default_ms
	end
	if type(lease_ms) ~= "number" or lease_ms % 1 ~= 0 or lease_ms < 1 then
		return nil, "lease_ms must be a positive integer"
	end
	return lease_ms
end

function M.create(board, args, now, cfg)
	args = args or {}
	local title = trim(args.title)
	if title == "" then
		return nil, "task title must be a non-empty string", "team.invalid_task"
	end
	if args.description ~= nil and type(args.description) ~= "string" then
		return nil, "task description must be a string", "team.invalid_task"
	end
	local priority = args.priority or "medium"
	if not VALID_PRIORITY[priority] then
		return nil, "priority must be low, medium, or high", "team.invalid_task"
	end
	local blockers, dep_err = dedup_ids(args.blocked_by)
	if not blockers then
		return nil, dep_err, "team.invalid_dependency"
	end
	local lease_ms, lerr = validate_lease_ms(args.lease_ms, cfg.default_lease_ms or 300000)
	if not lease_ms then
		return nil, lerr, "team.invalid_task"
	end

	local seq = board.next_seq
	local id = "T-" .. tostring(seq)
	local ok_dep, d_err, d_code = validate_blockers(board, id, blockers)
	if not ok_dep then
		return nil, d_err, d_code
	end

	local owner = args.owner ~= nil and trim(args.owner) or nil
	if owner == "" then
		owner = nil
	end
	local status = owner and "in_progress" or "pending"
	if status == "in_progress" then
		for _, dep_id in ipairs(blockers) do
			local dep = board.tasks[dep_id]
			if dep and dep.status ~= "completed" then
				return nil, "cannot assign in_progress owner while blocked by " .. dep_id, "team.task_blocked"
			end
		end
	end

	local task = {
		id = id,
		seq = seq,
		title = title,
		description = args.description,
		status = status,
		priority = priority,
		blocked_by = copy_list(blockers),
		owner = owner,
		lease_token = owner and make_token() or nil,
		lease_expires_at_ms = owner and (now + lease_ms) or nil,
		revision = 1,
		notes = mare and mare.json and mare.json.array and mare.json.array({}) or {},
		created_at_ms = now,
		updated_at_ms = now,
	}

	board.next_seq = seq + 1
	board.journal_seq = board.journal_seq + 1
	board.tasks[id] = task
	board.order[#board.order + 1] = id

	return {
		version = 1,
		seq = board.journal_seq,
		op = "create",
		timestamp = now,
		task = M.clone_board({ next_seq = 1, journal_seq = 0, tasks = { [id] = task }, order = { id } }).tasks[id],
	}
end

local function pick_next_ready(board)
	local best = nil
	for _, id in ipairs(board.order) do
		local t = board.tasks[id]
		if t and t.status == "pending" and t.owner == nil and #unresolved_for(board, t) == 0 then
			if
				not best
				or (PRIORITY_RANK[t.priority] or 2) > (PRIORITY_RANK[best.priority] or 2)
				or ((PRIORITY_RANK[t.priority] or 2) == (PRIORITY_RANK[best.priority] or 2) and t.seq < best.seq)
			then
				best = t
			end
		end
	end
	return best
end

function M.claim(board, args, now, cfg)
	args = args or {}
	local owner = trim(args.owner or (mare and mare.agent_id) or "main")
	if owner == "" then
		return nil, "claim owner must be a non-empty string", "team.invalid_task"
	end
	local lease_ms, lerr = validate_lease_ms(args.lease_ms, cfg.default_lease_ms or 300000)
	if not lease_ms then
		return nil, lerr, "team.invalid_task"
	end

	local task
	if args.id ~= nil then
		task = board.tasks[args.id]
		if not task then
			return nil, "unknown task: " .. tostring(args.id), "team.unknown_task"
		end
	else
		task = pick_next_ready(board)
		if not task then
			return nil, "no ready unclaimed task available", "team.no_ready_task"
		end
	end

	if task.status == "completed" or task.status == "cancelled" then
		return nil, ("task %s is already %s"):format(task.id, task.status), "team.invalid_state"
	end
	local unresolved = unresolved_for(board, task)
	if #unresolved > 0 then
		return nil, ("task %s is blocked by: %s"):format(task.id, table.concat(unresolved, ", ")), "team.task_blocked"
	end

	local lease_active = task.status == "in_progress"
		and task.owner ~= nil
		and task.lease_expires_at_ms ~= nil
		and now < task.lease_expires_at_ms
	if lease_active and task.owner ~= owner and args.force ~= true then
		return nil,
			("task %s is actively leased by %s until %d"):format(task.id, task.owner, task.lease_expires_at_ms),
			"team.lease_conflict"
	end

	task.status = "in_progress"
	task.owner = owner
	task.lease_token = make_token()
	task.lease_expires_at_ms = now + lease_ms
	task.revision = task.revision + 1
	task.updated_at_ms = now
	board.journal_seq = board.journal_seq + 1

	return {
		version = 1,
		seq = board.journal_seq,
		op = "claim",
		timestamp = now,
		updated_at_ms = now,
		id = task.id,
		owner = owner,
		lease_token = task.lease_token,
		lease_expires_at_ms = task.lease_expires_at_ms,
		revision = task.revision,
	}
end

local function resolve_caller_owner(args)
	if args.owner ~= nil then
		return trim(args.owner)
	end
	return trim((mare and mare.agent_id) or "main")
end

local function check_ownership_guard(task, args, now)
	if args.expected_revision ~= nil and task.revision ~= args.expected_revision then
		return false,
			("stale revision for %s: expected %s, actual %d"):format(
				task.id,
				tostring(args.expected_revision),
				task.revision
			),
			"team.conflict"
	end
	if args.lease_token ~= nil and task.lease_token ~= args.lease_token then
		return false, ("stale lease_token for %s"):format(task.id), "team.stale_lease"
	end
	if args.force ~= true and task.status == "in_progress" then
		if task.owner == nil then
			return false, ("task %s has no active owner lease"):format(task.id), "team.invalid_state"
		end
		local caller_owner = resolve_caller_owner(args)
		if caller_owner == "" or task.owner ~= caller_owner then
			local expired = task.lease_expires_at_ms ~= nil and now >= task.lease_expires_at_ms
			return false,
				("task %s is owned by %s (%s)"):format(
					task.id,
					task.owner,
					expired and "lease expired; claim first" or "active lease"
				),
				"team.stale_owner"
		end
		if task.lease_expires_at_ms ~= nil and now >= task.lease_expires_at_ms then
			return false,
				("lease expired for task %s (owner %s); reclaim before updating or completing"):format(
					task.id,
					task.owner
				),
				"team.stale_lease"
		end
	end
	return true
end

local function collect_was_blocked(board, task_id)
	local bmap = downstream_blocks(board)
	local was_blocked = {}
	for _, down_id in ipairs(bmap[task_id] or {}) do
		local down = board.tasks[down_id]
		if down and down.status == "pending" and #unresolved_for(board, down) > 0 then
			was_blocked[down_id] = true
		end
	end
	return bmap[task_id] or {}, was_blocked
end

local function collect_newly_unblocked(board, downstream_ids, was_blocked)
	local newly_unblocked = mare and mare.json and mare.json.array and mare.json.array({}) or {}
	for _, down_id in ipairs(downstream_ids) do
		local down = board.tasks[down_id]
		if down and was_blocked[down_id] and #unresolved_for(board, down) == 0 then
			newly_unblocked[#newly_unblocked + 1] = down_id
		end
	end
	return newly_unblocked
end

function M.update(board, args, now, cfg)
	args = args or {}
	local task = board.tasks[args.id]
	if not task then
		return nil, "unknown task: " .. tostring(args.id), "team.unknown_task"
	end
	if task.status == "completed" and args.status ~= nil and args.status ~= "completed" and args.force ~= true then
		return nil, ("completed task %s cannot change status without force=true"):format(task.id), "team.invalid_state"
	end

	local ok_guard, g_err, g_code = check_ownership_guard(task, args, now)
	if not ok_guard then
		return nil, g_err, g_code
	end

	local next_title = task.title
	if args.title ~= nil then
		local t = trim(args.title)
		if t == "" then
			return nil, "task title must be non-empty", "team.invalid_task"
		end
		next_title = t
	end
	local next_description = task.description
	if args.description ~= nil then
		if type(args.description) ~= "string" then
			return nil, "description must be a string", "team.invalid_task"
		end
		next_description = args.description
	end
	local next_priority = task.priority
	if args.priority ~= nil then
		if not VALID_PRIORITY[args.priority] then
			return nil, "priority must be low, medium, or high", "team.invalid_task"
		end
		next_priority = args.priority
	end

	local blockers = copy_list(task.blocked_by)
	if args.remove_blocked_by ~= nil then
		local rem_list, rerr = dedup_ids(args.remove_blocked_by)
		if not rem_list then
			return nil, rerr, "team.invalid_dependency"
		end
		local rem = {}
		for _, r in ipairs(rem_list) do
			rem[r] = true
		end
		local next_b = {}
		for _, b in ipairs(blockers) do
			if not rem[b] then
				next_b[#next_b + 1] = b
			end
		end
		blockers = next_b
	end
	if args.add_blocked_by ~= nil then
		local add, derr = dedup_ids(args.add_blocked_by)
		if not add then
			return nil, derr, "team.invalid_dependency"
		end
		local seen = {}
		for _, b in ipairs(blockers) do
			seen[b] = true
		end
		for _, b in ipairs(add) do
			if not seen[b] then
				seen[b] = true
				blockers[#blockers + 1] = b
			end
		end
	end
	if args.add_blocked_by ~= nil or args.remove_blocked_by ~= nil then
		local ok_dep, d_err, d_code = validate_blockers(board, task.id, blockers)
		if not ok_dep then
			return nil, d_err, d_code
		end
	end

	local next_status = task.status
	if args.status ~= nil then
		if not VALID_STATUS[args.status] then
			return nil, "invalid status: " .. tostring(args.status), "team.invalid_task"
		end
		next_status = args.status
	end
	if
		(task.status == "completed" or task.status == "cancelled")
		and next_status ~= task.status
		and args.force ~= true
	then
		return nil,
			("task %s is already %s (pass force=true to transition)"):format(task.id, task.status),
			"team.invalid_state"
	end

	-- Compute unresolved blockers using the staged blocker list
	local staged_unresolved = unresolved_for(board, { blocked_by = blockers })
	if next_status == "in_progress" and #staged_unresolved > 0 then
		return nil, "cannot mark blocked task in_progress", "team.task_blocked"
	end
	if next_status == "completed" then
		if task.status == "cancelled" and args.force ~= true then
			return nil,
				("cancelled task %s cannot be completed without force=true"):format(task.id),
				"team.invalid_state"
		end
		if #staged_unresolved > 0 then
			return nil,
				("task %s cannot be completed while blocked by: %s"):format(
					task.id,
					table.concat(staged_unresolved, ", ")
				),
				"team.task_blocked"
		end
	end

	local next_lease_ms = nil
	if args.renew_lease == true or args.lease_ms ~= nil then
		local lm, lerr = validate_lease_ms(args.lease_ms, cfg.default_lease_ms or 300000)
		if not lm then
			return nil, lerr, "team.invalid_task"
		end
		next_lease_ms = lm
	end

	local next_owner = task.owner
	local next_token = task.lease_token
	local next_expires = task.lease_expires_at_ms
	local next_completed_at = task.completed_at_ms
	local becoming_in_progress = next_status == "in_progress" and task.status ~= "in_progress"

	if becoming_in_progress then
		if args.owner ~= nil and trim(args.owner) == "" then
			return nil, "owner must be non-empty when transitioning to in_progress", "team.invalid_task"
		end
		local assigned_owner = trim(args.owner or task.owner or (mare and mare.agent_id) or "main")
		if assigned_owner == "" then
			return nil, "cannot transition unclaimed task to in_progress without an owner", "team.invalid_state"
		end
		local lm, lerr = validate_lease_ms(args.lease_ms, cfg.default_lease_ms or 300000)
		if not lm then
			return nil, lerr, "team.invalid_task"
		end
		next_owner = assigned_owner
		next_token = make_token()
		next_expires = now + lm
		next_completed_at = nil
	elseif next_status == "pending" then
		next_owner = nil
		next_token = nil
		next_expires = nil
		next_completed_at = nil
	elseif next_status == "cancelled" then
		next_token = nil
		next_expires = nil
	elseif next_status == "completed" then
		next_token = nil
		next_expires = nil
		next_completed_at = next_completed_at or now
	end

	if next_lease_ms ~= nil then
		if next_status ~= "in_progress" or not next_owner then
			return nil, "cannot renew lease on an unclaimed or non-active task", "team.invalid_state"
		end
		next_expires = now + next_lease_ms
	end

	local newly_unblocked = nil
	local downstream_ids, was_blocked
	if next_status == "completed" and task.status ~= "completed" then
		downstream_ids, was_blocked = collect_was_blocked(board, task.id)
	end

	task.title = next_title
	task.description = next_description
	task.priority = next_priority
	task.blocked_by = copy_list(blockers)
	task.status = next_status
	task.owner = next_owner
	task.lease_token = next_token
	task.lease_expires_at_ms = next_expires
	task.completed_at_ms = next_completed_at

	if next_status == "completed" and downstream_ids then
		newly_unblocked = collect_newly_unblocked(board, downstream_ids, was_blocked)
	end

	if args.note ~= nil then
		local ntext = trim(args.note)
		if ntext ~= "" then
			task.notes[#task.notes + 1] = {
				timestamp = now,
				author = trim(args.owner or task.owner or (mare and mare.agent_id) or "main"),
				text = ntext,
			}
		end
	end

	task.revision = task.revision + 1
	task.updated_at_ms = now
	board.journal_seq = board.journal_seq + 1

	return {
		version = 1,
		seq = board.journal_seq,
		op = "update",
		timestamp = now,
		id = task.id,
		unblocked = newly_unblocked,
		snapshot = {
			title = task.title,
			description = task.description,
			status = task.status,
			priority = task.priority,
			blocked_by = copy_list(task.blocked_by),
			owner = task.owner,
			lease_token = task.lease_token,
			lease_expires_at_ms = task.lease_expires_at_ms,
			completed_at_ms = task.completed_at_ms,
			revision = task.revision,
			notes = copy_notes(task.notes),
			updated_at_ms = task.updated_at_ms,
		},
	},
		newly_unblocked
end

function M.complete(board, args, now)
	args = args or {}
	local task = board.tasks[args.id]
	if not task then
		return nil, "unknown task: " .. tostring(args.id), "team.unknown_task"
	end
	if task.status == "completed" then
		return nil, ("task %s is already completed"):format(task.id), "team.invalid_state"
	end
	if task.status == "cancelled" then
		return nil, ("cancelled task %s cannot be completed"):format(task.id), "team.invalid_state"
	end
	local unresolved = unresolved_for(board, task)
	if #unresolved > 0 then
		return nil,
			("task %s cannot be completed while blocked by: %s"):format(task.id, table.concat(unresolved, ", ")),
			"team.task_blocked"
	end

	local ok_guard, g_err, g_code = check_ownership_guard(task, args, now)
	if not ok_guard then
		return nil, g_err, g_code
	end

	local downstream_ids, was_blocked = collect_was_blocked(board, task.id)

	task.status = "completed"
	task.lease_token = nil
	task.lease_expires_at_ms = nil
	task.completed_at_ms = now
	task.updated_at_ms = now
	task.revision = task.revision + 1
	if args.result ~= nil then
		task.result = tostring(args.result)
	end
	if args.note ~= nil and trim(args.note) ~= "" then
		task.notes[#task.notes + 1] = {
			timestamp = now,
			author = trim(args.owner or task.owner or (mare and mare.agent_id) or "main"),
			text = trim(args.note),
		}
	end

	local newly_unblocked = collect_newly_unblocked(board, downstream_ids, was_blocked)

	board.journal_seq = board.journal_seq + 1
	return {
		version = 1,
		seq = board.journal_seq,
		op = "complete",
		timestamp = now,
		updated_at_ms = now,
		id = task.id,
		result = task.result,
		notes = copy_notes(task.notes),
		revision = task.revision,
		completed_at_ms = now,
		unblocked = newly_unblocked,
	},
		newly_unblocked
end

local function release_matching(board, owner_set, owner_label, now, reason)
	local releases = mare and mare.json and mare.json.array and mare.json.array({}) or {}
	for _, id in ipairs(board.order) do
		local t = board.tasks[id]
		if t and t.status == "in_progress" and t.owner and owner_set[t.owner] then
			local prev_owner = t.owner
			t.status = "pending"
			t.owner = nil
			t.lease_token = nil
			t.lease_expires_at_ms = nil
			t.revision = t.revision + 1
			t.updated_at_ms = now
			t.notes[#t.notes + 1] = {
				timestamp = now,
				author = "system",
				text = reason or ("released stale lease from " .. prev_owner),
			}
			releases[#releases + 1] = {
				id = t.id,
				revision = t.revision,
				notes = copy_notes(t.notes),
			}
		end
	end
	if #releases == 0 then
		return nil
	end
	board.journal_seq = board.journal_seq + 1
	return {
		version = 1,
		seq = board.journal_seq,
		op = "release_batch",
		timestamp = now,
		updated_at_ms = now,
		previous_owner = owner_label,
		releases = releases,
	},
		#releases
end

function M.release_owner(board, owner_id, now, reason)
	if type(owner_id) ~= "string" or owner_id == "" then
		return nil
	end
	return release_matching(board, { [owner_id] = true }, owner_id, now, reason)
end

function M.release_owners(board, owner_ids, now, reason)
	if type(owner_ids) ~= "table" then
		return nil
	end
	local owner_set = {}
	local label = nil
	for _, id in ipairs(owner_ids) do
		if type(id) == "string" and id ~= "" then
			owner_set[id] = true
			label = label or id
		end
	end
	if not label then
		return nil
	end
	return release_matching(board, owner_set, label, now, reason)
end

function M.clear(board, now)
	local count = #board.order
	board.tasks = {}
	board.order = {}
	board.board_gen = (board.board_gen or 1) + 1
	board.journal_seq = board.journal_seq + 1
	return {
		version = 1,
		seq = board.journal_seq,
		op = "clear",
		timestamp = now,
		next_seq = board.next_seq,
		board_gen = board.board_gen,
		cleared = count,
	},
		count
end

function M.apply_record(board, rec)
	if type(rec) ~= "table" or rec.version ~= 1 then
		return false, "unsupported team record version"
	end
	if type(rec.seq) == "number" and rec.seq > board.journal_seq then
		board.journal_seq = rec.seq
	end
	if rec.op == "create" and type(rec.task) == "table" then
		local t = rec.task
		if type(t.id) ~= "string" then
			return false, "missing task id in create record"
		end
		if not board.tasks[t.id] then
			board.order[#board.order + 1] = t.id
		end
		board.tasks[t.id] = {
			id = t.id,
			seq = t.seq or board.next_seq,
			title = t.title,
			description = t.description,
			status = t.status or "pending",
			priority = t.priority or "medium",
			blocked_by = copy_list(t.blocked_by),
			owner = t.owner,
			lease_token = t.lease_token,
			lease_expires_at_ms = t.lease_expires_at_ms,
			revision = t.revision or 1,
			notes = copy_notes(t.notes),
			result = t.result,
			created_at_ms = t.created_at_ms or 0,
			updated_at_ms = t.updated_at_ms or 0,
			completed_at_ms = t.completed_at_ms,
		}
		if (t.seq or 0) >= board.next_seq then
			board.next_seq = (t.seq or 0) + 1
		end
		return true
	elseif rec.op == "claim" then
		local t = board.tasks[rec.id]
		if t then
			t.status = "in_progress"
			t.owner = rec.owner
			t.lease_token = rec.lease_token
			t.lease_expires_at_ms = rec.lease_expires_at_ms
			t.revision = rec.revision or (t.revision + 1)
			t.updated_at_ms = rec.updated_at_ms or t.updated_at_ms
		end
		return true
	elseif rec.op == "update" and type(rec.snapshot) == "table" then
		local t = board.tasks[rec.id]
		if t then
			local s = rec.snapshot
			t.title = s.title or t.title
			t.description = s.description
			t.status = s.status or t.status
			t.priority = s.priority or t.priority
			t.blocked_by = copy_list(s.blocked_by)
			t.owner = s.owner
			t.lease_token = s.lease_token
			t.lease_expires_at_ms = s.lease_expires_at_ms
			t.completed_at_ms = s.completed_at_ms
			t.revision = s.revision or (t.revision + 1)
			t.notes = copy_notes(s.notes)
			t.updated_at_ms = s.updated_at_ms or t.updated_at_ms
		end
		return true
	elseif rec.op == "complete" then
		local t = board.tasks[rec.id]
		if t then
			t.status = "completed"
			t.lease_token = nil
			t.lease_expires_at_ms = nil
			t.result = rec.result
			t.notes = copy_notes(rec.notes)
			t.revision = rec.revision or (t.revision + 1)
			t.completed_at_ms = rec.completed_at_ms
			t.updated_at_ms = rec.updated_at_ms or t.updated_at_ms
		end
		return true
	elseif rec.op == "release" then
		local t = board.tasks[rec.id]
		if t then
			t.status = "pending"
			t.owner = nil
			t.lease_token = nil
			t.lease_expires_at_ms = nil
			t.notes = copy_notes(rec.notes)
			t.revision = rec.revision or (t.revision + 1)
			t.updated_at_ms = rec.updated_at_ms or t.updated_at_ms
		end
		return true
	elseif rec.op == "release_batch" and type(rec.releases) == "table" then
		for _, item in ipairs(rec.releases) do
			local t = board.tasks[item.id]
			if t then
				t.status = "pending"
				t.owner = nil
				t.lease_token = nil
				t.lease_expires_at_ms = nil
				t.notes = copy_notes(item.notes)
				t.revision = item.revision or (t.revision + 1)
				t.updated_at_ms = rec.updated_at_ms or t.updated_at_ms
			end
		end
		return true
	elseif rec.op == "clear" then
		board.tasks = {}
		board.order = {}
		if type(rec.next_seq) == "number" and rec.next_seq > board.next_seq then
			board.next_seq = rec.next_seq
		end
		board.board_gen = type(rec.board_gen) == "number" and rec.board_gen or ((board.board_gen or 1) + 1)
		return true
	end
	return false, "unknown team record op: " .. tostring(rec.op)
end

function M.replay(records)
	local board = M.new_board()
	for _, r in ipairs(records or {}) do
		local ok, err = M.apply_record(board, r)
		if not ok then
			return nil, err
		end
	end
	return board
end

return M
