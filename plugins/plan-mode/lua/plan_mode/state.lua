-- State is the projection of `plan-mode/state` records; selections go through
-- one coordinator per session identity, which alone writes records (see plan_mode/coordinator.lua).
local Coordinator = require("plan_mode.coordinator")

local EMPTY = { version = 1, active = false, entered = false, revision = 0 }

local function normalized(value)
	if type(value) ~= "table" or value.version ~= 1 or type(value.active) ~= "boolean" then
		return nil
	end
	local revision = value.revision or 0
	if type(revision) ~= "number" or revision < 0 or revision % 1 ~= 0 then
		return nil
	end
	if value.plan ~= nil and type(value.plan) ~= "string" then
		return nil
	end
	return {
		version = 1,
		active = value.active,
		entered = value.entered == true or value.active,
		revision = revision,
		plan = value.plan,
		narrate = value.narrate == true,
	}
end

--- Highest revision wins; equal revisions take the later record; `entered` is the union.
local function project(records)
	local value, entered = EMPTY, false
	for _, record in ipairs(records) do
		local restored = normalized(record)
		if restored then
			entered = entered or restored.entered
			if restored.revision >= value.revision then
				value = restored
			end
		end
	end
	if entered and not value.entered then
		value = {
			version = 1,
			active = value.active,
			entered = true,
			revision = value.revision,
			plan = value.plan,
			narrate = value.narrate,
		}
	end
	return value
end

return function(ctx, changed)
	local E
	local last_request_active = nil
	local kick_tx, kick_rx = mare.task.channel()
	local worker

	local function maybe_narrate(active, narrate)
		if narrate and last_request_active ~= nil and last_request_active ~= active then
			last_request_active = active
			ctx.agent:notify("The user switched plan mode " .. (active and "on" or "off") .. ".", { wake = false })
		end
	end

	local deps = {}
	function deps.record(e, value)
		local persistent = not e.ephemeral and mare.mode ~= "child"
		local ok, saved, err = pcall(
			ctx.session.add_record,
			ctx.session,
			"plan-mode/state",
			value,
			{ persist = persistent, sync = persistent, session_id = e.id, session_epoch = e.generation }
		)
		if not ok or not saved then
			local detail = not ok and (require("mare_lib").error_message(saved) or saved)
				or (require("mare_lib").error_message(err) or err)
			mare.log("warn", "Plan mode could not be saved: " .. tostring(detail))
			return nil, detail
		end
		return true
	end
	function deps.changed(e, reason)
		if e ~= E then
			return
		end
		ctx.context:invalidate()
		changed(reason)
	end
	function deps.alive(e)
		local info = ctx.session:info()
		return e.id == info.session_id and e.generation == info.session_epoch
	end
	function deps.settled(e, written)
		if written and e == E then
			maybe_narrate(e.committed.active, written.narrate)
		end
	end

	local function kick(e)
		if not e.kicked and not e.running then
			e.kicked = true
			kick_tx:send(e)
		end
	end

	local function build(info)
		local committed = project(require("mare_lib").all_records(ctx.session, "plan-mode/state") or {})
		E = Coordinator.new(info, committed, committed.revision, deps)
		local has_entries = committed.active
			and require("mare_lib").callable(ctx.session.entries)
			and #ctx.session:entries() > 0
		last_request_active = has_entries and true or nil
	end

	local function close(message, kind)
		if E then
			local old = E
			E = nil
			old:close(message, kind)
		end
	end

	local M = {}

	--- Bring the coordinator in line with the session: a new identity closes the old one
	--- (its waiters fail, its pending choice is dropped) and projects the new session's log.
	function M.restore()
		local info = ctx.session:info()
		if E and E.id == info.session_id and E.generation == info.session_epoch then
			if not E:converged() then
				return
			end
			local committed = project(require("mare_lib").all_records(ctx.session, "plan-mode/state") or {})
			E.committed, E.gate = committed, committed.active
			E.rev = math.max(E.rev, committed.revision)
		else
			close("Session changed while saving plan mode", "session_changed")
			build(info)
		end
		ctx.context:invalidate()
		changed("restore")
	end

	local function current_coordinator()
		local info = ctx.session:info()
		if not E or E.id ~= info.session_id or E.generation ~= info.session_epoch then
			M.restore()
		end
		return E
	end

	--- Every reader (gate, prompt section, banner, plan_mode.active) sees `active = gate`.
	function M.current()
		local e = E
		if not e then
			return EMPTY
		end
		local c = e.committed
		return { version = 1, active = e.gate, entered = c.entered or e.gate, revision = c.revision, plan = c.plan }
	end

	function M.request_active()
		return E ~= nil and E.gate
	end

	--- In-memory selection id: changes only when the user's choice changes, never on a retry.
	function M.selection_revision()
		return E and E.seq or 0
	end

	function M.view()
		local e = E
		if not e then
			return { active = false, revision = 0, entered = false, status = "closed" }
		end
		return {
			id = e.id,
			active = e.gate,
			pending = e.desired and e.desired.active,
			status = e:status(),
			unconfirmed = e.dirty,
			revision = e.committed.revision,
			entered = e.committed.entered or e.gate,
			generation = e.generation,
			plan = e.committed.plan,
		}
	end

	--- Returns `true, outcome` (noop|committed|queued|cancelled|superseded) or `nil, message, kind`
	--- (rejected|unconfirmed|session_changed|disposed).
	function M.select(active, narrate, plan)
		if ctx.session:info().readonly then
			return nil, "Plan mode cannot change in a read-only session", "rejected"
		end
		local e = current_coordinator()
		if e:converged() and active == e.committed.active and plan == nil then
			return true, "noop"
		end
		local busy = (ctx.agent:get() or {}).busy == true
		if busy and not e.running and not e.dirty and active == e.committed.active and plan == nil then
			e.desired = nil
			e.seq = e.seq + 1 -- the latest choice changed: an open review becomes stale.
			ctx.context:invalidate()
			changed("cancelled")
			return true, "cancelled"
		end
		e:intend(active, narrate == true, plan)
		if busy and not e.running then
			ctx.context:invalidate()
			changed("queued")
			return true, "queued"
		end
		kick(e)
		return e:wait(active)
	end

	-- Runs before the request is assembled; returns once the coordinator converged or failed.
	ctx:on("step/started", function()
		local e = current_coordinator()
		if e:converged() then
			return
		end
		if e.desired then
			kick(e)
		end
		if e.running or e.kicked then
			e:wait(nil)
		end
	end, { prepend = true }) -- first: later listeners see the converged mode (was priority maxinteger)
	-- request/build is a waterfall: pass the request on unchanged
	ctx:on("request/build", function(req, ev)
		last_request_active = E ~= nil and E.gate
		return ev.next(req)
	end)
	ctx:on("session/changed", M.restore)
	ctx:on("session/transition-completed", M.restore)
	ctx:effect(function()
		return function()
			close("Plan mode was unloaded while saving", "disposed")
			if worker then
				worker:abort()
			end
		end
	end)

	-- The only task that writes records, created in the host context.
	worker = ctx:spawn(function()
		while true do
			local e = kick_rx:recv()
			if e == nil then
				return
			end
			e:run()
		end
	end)
	return M
end
