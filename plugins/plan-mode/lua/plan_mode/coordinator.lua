-- Per-session plan-mode coordinator.
-- Serial per-session event dispatcher:
-- one owner applies selections in order. mare's session:record yields and may leave an unknown
-- result, so the owner also keeps an unconfirmed (dirty) flag and rewrites with a newer revision.
--
-- Coordinator invariants:
--   1. Only `run` (executed by the plugin's single worker task) calls record, one write at a time.
--   2. Revisions are allocated when a write starts; `seq` is the in-memory selection id.
--   3. `gate` becomes false only at the convergence point with a confirmed inactive record.
local M = {}
M.__index = M

local function unconfirmed_message(active, err)
	if active then
		return ("Plan mode is on for this run but could not be saved (%s); retrying at the next step."):format(err)
	end
	return ("Plan mode stays on: could not save (%s); retrying at the next step."):format(err)
end

--- deps: record(E, value) -> ok, err; changed(E, reason); settled(E, written) after convergence.
function M.new(identity, committed, rev, deps)
	return setmetatable({
		id = identity.session_id,
		generation = identity.session_epoch,
		ephemeral = identity.ephemeral,
		open = true,
		committed = committed,
		desired = nil,
		writing = nil,
		dirty = false,
		gate = committed.active,
		rev = rev,
		seq = 0,
		waiters = {},
		running = false,
		kicked = false,
		deps = deps,
	}, M)
end

function M:converged()
	return self.desired == nil and self.writing == nil and not self.dirty and not self.running
end

function M:status()
	if not self.open then
		return "closed"
	end
	if self.writing then
		return "committing"
	end
	if self.dirty then
		return "unconfirmed"
	end
	if self.desired then
		return "queued"
	end
	return "settled"
end

--- Record a selection; returns the desired entry. Same-direction repeats keep their seq.
function M:intend(active, narrate, plan)
	local d = self.desired
	if d and d.active == active and plan == nil then
		d.narrate = d.narrate or narrate
		return d
	end
	self.seq = self.seq + 1
	self.desired = { seq = self.seq, active = active, plan = plan, narrate = narrate }
	return self.desired
end

--- Register a waiter and block until convergence, failure, or close.
--- `active` is the caller's target (nil for the turn-start listener).
function M:wait(active)
	local tx, rx = mare.task.channel()
	self.waiters[#self.waiters + 1] = { active = active, tx = tx }
	self.deps.changed(self, "waiting")
	local res = rx:recv()
	return table.unpack(res, 1, res.n)
end

local function reply_all(self, fn)
	local waiters = self.waiters
	self.waiters = {}
	for _, w in ipairs(waiters) do
		pcall(w.tx.send, w.tx, table.pack(fn(w)))
	end
end

function M:close(message, kind)
	if not self.open then
		return
	end
	self.open, self.desired = false, nil
	reply_all(self, function()
		return nil, message, kind
	end)
end

--- The single commit point. Executed only by the worker task.
function M:run()
	self.kicked = false
	if not self.open or self.running then
		return
	end
	self.running = true
	local written
	while self.open and self.desired do
		local want = self.desired
		if not self.dirty and want.plan == nil and want.active == self.committed.active then
			self.desired = nil
			break
		end
		self.rev = self.rev + 1
		local value = {
			version = 1,
			active = want.active,
			entered = self.committed.entered or want.active,
			revision = self.rev,
			plan = want.plan or self.committed.plan,
			narrate = want.narrate == true,
		}
		self.writing = value
		if value.active then
			self.gate = true
		end
		self.deps.changed(self, "committing")
		local ok, res, err = pcall(self.deps.record, self, value)
		-- The core publishes a new identity before session/changed arrives: a write
		-- returning into another identity is handled as closed; session/changed answers waiters.
		if not self.open or not self.deps.alive(self) then
			return
		end
		self.writing = nil
		if ok and res then
			self.committed, self.dirty, written = value, false, value
			if self.desired == want then
				self.desired = nil
			end
		else
			self.dirty, self.running = true, false
			if value.active then
				self.gate = true
			end
			local reason = tostring(ok and (err or "record failed") or res)
			local message = unconfirmed_message(value.active, reason)
			reply_all(self, function()
				return nil, message, "unconfirmed"
			end)
			self.deps.changed(self, "unconfirmed", message)
			return
		end
	end
	self.running = false
	if not self.open then
		return
	end
	self.gate = self.committed.active
	local committed = self.committed.active
	reply_all(self, function(w)
		if w.active == nil then
			return true
		end
		return true, w.active == committed and "committed" or "superseded"
	end)
	self.deps.settled(self, written)
	self.deps.changed(self, written and "committed" or "cancelled")
end

M.unconfirmed_message = unconfirmed_message
return M
