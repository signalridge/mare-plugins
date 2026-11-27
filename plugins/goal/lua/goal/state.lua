-- Durable snapshots, exact refs, revisioned tombstones, and strict replay.
return function(ctx)
	local journal = require("goal.journal")
	local M = { revision = 0, value = nil, fault = nil }
	local folded = { revision = 0, value = nil, seen = {}, rounds = {} }
	local function copy(v)
		return v and mare.json.decode(mare.json.encode(v)) or nil
	end
	function M.owner()
		local i = ctx.session:info()
		return { id = i.session_id, generation = i.session_epoch }
	end
	function M.same(a, b)
		return a.id == b.id and a.generation == b.generation
	end
	function M.writable()
		local i = ctx.session:info()
		-- available() also rejects an ordinary in-flight persistence callback. A
		-- nested goal accounting write must use the record(sync) acknowledgement,
		-- which distinguishes a real write failure from that transient barrier.
		if i.ephemeral or mare.mode == "child" or i.readonly or i.unstable or i.resume_error then
			return nil, "goal requires a stable writable saved session"
		end
		if M.fault then
			return nil, M.fault
		end
		return true
	end
	function M.restore()
		M.value, M.revision, M.fault = nil, 0, nil
		folded = { revision = 0, value = nil, seen = {}, rounds = {} }
		for _, r in ipairs(require("mare_lib").all_records(ctx.session, "goal/state") or {}) do
			local next, err = journal.advance(folded, r)
			if not next then
				M.fault = "Invalid latest goal journal: " .. err
				M.value = nil
				break
			end
			M.revision = next.revision
		end
		if not M.fault and folded.value then
			local detached = copy(folded.value)
			folded.value = detached
			M.value = copy(detached)
		end
		ctx.context:invalidate()
	end
	function M.get()
		return copy(M.value)
	end
	function M.preview_replace(value)
		if not M.value then
			return nil, "no goal to replace"
		end
		local clear = {
			version = 2,
			revision = M.revision + 1,
			cleared = true,
			goal_id = M.value.id,
			goal_revision = M.value.revision + 1,
		}
		local next, err = journal.fold(folded, clear)
		if not next then
			return nil, err
		end
		return journal.fold(next, { version = 2, revision = M.revision + 2, cleared = false, goal = copy(value) })
	end
	function M.commit(value, expected, owner)
		local ok, err = M.writable()
		if not ok then
			return nil, err
		end
		if expected ~= M.revision or not M.same(owner, M.owner()) then
			return nil, "stale goal revision or session"
		end
		if value then
			value.updated_at = math.max(value.updated_at or value.created_at, math.floor(mare.task.now()))
		end
		local goal_copy = copy(value)
		local r = { version = 2, revision = expected + 1, cleared = value == nil, goal = goal_copy }
		if not value then
			r.goal_id = M.value and M.value.id
			r.goal_revision = M.value and M.value.revision + 1
		end
		if value and M.value and value.rounds_started == M.value.rounds_started + 1 then
			r.round = {
				source = "goal",
				turn_id = value.last_round_id,
				index = value.rounds_started,
				audit_epoch = value.audit_epoch,
			}
		end
		local valid, failure = journal.validate(folded, r)
		if not valid then
			return nil, failure
		end
		local saved
		ok, saved, err = pcall(
			ctx.session.add_record,
			ctx.session,
			"goal/state",
			r,
			{ sync = true, session_id = owner.id, session_epoch = owner.generation }
		)
		if not ok or not saved then
			local detail = not ok and (require("mare_lib").error_message(saved) or saved)
				or (require("mare_lib").error_message(err) or err)
			failure = "Goal persistence acknowledgement failed: " .. tostring(detail)
			if M.same(owner, M.owner()) then
				M.fault = failure
			end
			return nil, failure
		end
		if not M.same(owner, M.owner()) or M.revision ~= expected then
			return nil, "session or goal changed while saving"
		end
		local committed = copy(goal_copy)
		folded.revision = r.revision
		folded.value = committed
		if committed then
			folded.seen[committed.id] = true
			if r.round then
				folded.rounds[committed.last_round_id] = { goal_id = committed.id, index = committed.rounds_started }
			end
		end
		M.value = copy(committed)
		M.revision = r.revision
		ctx.context:invalidate()
		return true,
			nil,
			{
				goal = M.get(),
				revision = M.revision,
				owner = owner,
				cleared = value == nil,
				goal_id = r.goal_id,
				goal_revision = r.goal_revision,
			}
	end
	function M.publish(event)
		if not M.same(event.owner, M.owner()) then
			return
		end
		ctx.bus:emit("goal/changed", event)
	end
	return M
end
