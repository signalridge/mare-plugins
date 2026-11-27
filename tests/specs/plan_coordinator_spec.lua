-- Plan-mode coordinator scenarios for selections, persistence, and session changes.
-- Covers queued busy selection, no-op set, between-turns commit/reversal, pre-step flush,
-- flip cancellation, append failure retention, log projection, and revision replay.
-- Barriers are channels only: the fake session:record reports each arrival and blocks on its own
-- release channel; the state module's changed(reason) callback reports every transition. No sleep, no polling.
local support = assert(load(mare.fs.read("tests/specs/support.lua"), "@tests/specs/support.lua"))()
support.preload_modules("plan-mode", { "plan_mode.coordinator", "plan_mode.state", "plan_mode.gate" })
local new_state = require("plan_mode.state")
local new_gate = require("plan_mode.gate")
local coordinator = require("plan_mode.coordinator")

local describe, it, after_each, expect = mare.test.describe, mare.test.it, mare.test.after_each, mare.test.expect

local LIMIT_MS = 5000

local function recv(rx, what)
	local done, value = mare.task.timeout(LIMIT_MS, function()
		return rx:recv()
	end)
	assert(done, "timed out waiting for " .. what)
	return value
end

local function max_rev(log)
	local n = 0
	for _, r in ipairs(log) do
		if type(r.revision) == "number" and r.revision > n then
			n = r.revision
		end
	end
	return n
end

local live = {}

local function harness(opts)
	opts = opts or {}
	local h = {
		logs = { A = {}, B = {} },
		cur = { id = "A", generation = 1 },
		next_generation = 1,
		busy = false,
		readonly = false,
		attempts = {},
		stale = 0,
		overlap = false,
		inflight = false,
		events = {},
		disposers = {},
		tasks = {},
		notes = {},
	}
	if opts.initial == true then
		h.logs.A = { { version = 1, active = true, entered = true, revision = 1 } }
	end
	for sid, recs in pairs(opts.logs or {}) do
		h.logs[sid] = recs
	end
	local arr_tx, arr_rx = mare.task.channel()
	local chg_tx, chg_rx = mare.task.channel()
	local ret_tx, ret_rx = mare.task.channel()

	local function make_ctx(events, disposers)
		return {
			session = {
				info = function()
					return {
						session_id = h.cur.id,
						session_epoch = h.cur.generation,
						readonly = h.readonly,
						ephemeral = false,
					}
				end,
				entries = function()
					return {}
				end,
				list_records = function(_, kind)
					assert(kind == "plan-mode/state")
					local out = {}
					for i, v in ipairs(h.logs[h.cur.id]) do
						out[i] = v
					end
					return { data = out }
				end,
				-- Like the core (session/recorder.lua:46-51, store.lua:379-384): a stale identity is
				-- refused before anything is written. Serial use is asserted on every call.
				add_record = function(_, kind, value, o)
					assert(kind == "plan-mode/state")
					if h.inflight then
						h.overlap = true
					end
					if o.session_id ~= h.cur.id or o.session_epoch ~= h.cur.generation then
						h.stale = h.stale + 1
						error("stale session identity", 0)
					end
					h.inflight = true
					local tx, rx = mare.task.channel()
					local w = {
						n = #h.attempts + 1,
						value = value,
						sid = o.session_id,
						generation = o.session_epoch,
						log_max = max_rev(h.logs[o.session_id]),
						tx = tx,
					}
					h.attempts[#h.attempts + 1] = w
					arr_tx:send(w)
					local how = rx:recv()
					h.inflight = false
					w.outcome = how
					if how == "ok" or how == "fail_landed" or how == "throw_landed" then
						table.insert(h.logs[o.session_id], value)
					end
					ret_tx:send(w)
					if how == "ok" then
						return { durable = true }
					elseif how == "throw" or how == "throw_landed" then
						error("append exploded")
					elseif how == "stale" then
						error("stale session identity", 0)
					end
					error("disk failure", 0)
				end,
			},
			context = { invalidate = function() end },
			agent = {
				get = function()
					return { busy = h.busy }
				end,
				notify = function(_, text)
					h.notes[#h.notes + 1] = text
				end,
			},
			on = function(_, name, fn)
				events[name] = fn
			end,
			effect = function(_, setup)
				local fn = setup()
				disposers[#disposers + 1] = fn
			end,
			spawn = function(_, fn, ...)
				local t = mare.task.spawn(fn, ...)
				h.tasks[#h.tasks + 1] = t
				return t
			end,
		}
	end

	h.state = new_state(make_ctx(h.events, h.disposers), function(reason)
		if h.on_change then
			h.on_change(reason)
		end
		chg_tx:send(reason)
	end)
	h.state.restore()
	h.gate_rules = new_gate({ allow_tools = {} }, h.state)

	function h.gate()
		local v = h.gate_rules.vote({ name = "write", arguments = {} }, { side_effect = "write" })
		return v ~= nil and v.decision == "deny"
	end
	function h.drain()
		while chg_rx:try_recv() ~= nil do
		end
	end
	function h.change(reason)
		while true do
			if recv(chg_rx, "state change " .. reason) == reason then
				return
			end
		end
	end
	function h.arrive()
		local w = recv(arr_rx, "record arrival")
		assert(not h.overlap, "two session:record calls overlapped")
		return w
	end
	function h.release(w, how)
		assert(not w.released, "write released twice")
		w.released = true
		w.tx:send(how)
	end
	-- Barrier: the held record has returned to its caller (even when that caller is a closed coordinator).
	function h.returned(w)
		while true do
			if recv(ret_rx, "record return") == w then
				return
			end
		end
	end
	function h.spawn(fn)
		local t = mare.task.spawn(fn)
		h.tasks[#h.tasks + 1] = t
		return t
	end
	-- A selection that must wait for convergence; returns its task once it is registered.
	function h.select_wait(active, plan)
		h.drain()
		local t = h.spawn(function()
			return h.state.select(active, true, plan)
		end)
		h.change("waiting")
		return t
	end
	function h.select_now(active, plan)
		return h.state.select(active, true, plan)
	end
	function h.turn_wait()
		h.drain()
		local t = h.spawn(function()
			h.events["step/started"]({})
			return "returned"
		end)
		h.change("waiting")
		return t
	end
	function h.turn_now()
		h.events["step/started"]({})
	end
	function h.switch(id)
		h.next_generation = h.next_generation + 1
		h.cur = { id = id, generation = h.next_generation }
		h.events["session/changed"]()
	end
	function h.dispose()
		h.disposed = true
		for _, fn in ipairs(h.disposers) do
			fn()
		end
	end
	-- Restore check: a fresh state instance over the same log (what a restart would see).
	function h.restored()
		local events, disposers = {}, {}
		local probe = new_state(make_ctx(events, disposers), function() end)
		probe.restore()
		local v = probe.current()
		for _, fn in ipairs(disposers) do
			fn()
		end
		return v.active, v
	end
	-- Writes: count, revision strictly increasing, each above the session log's maximum when it started.
	function h.writes(n)
		expect.eq(#h.attempts, n)
		for i, w in ipairs(h.attempts) do
			assert(
				w.value.revision > w.log_max,
				("write %d rev %d <= log max %d"):format(i, w.value.revision, w.log_max)
			)
			local prev = h.attempts[i - 1]
			if prev and prev.sid == w.sid and prev.generation == w.generation then
				assert(w.value.revision > h.attempts[i - 1].value.revision, "revisions must strictly increase")
			end
		end
		assert(not h.overlap, "two session:record calls overlapped")
	end
	-- Teardown: release held writes, unload the plugin state, then wait until every task has
	-- ended so nothing from this case can run into the next one.
	function h.finish()
		for _, w in ipairs(h.attempts) do
			if not w.released then
				w.released = true
				w.tx:send("fail")
			end
		end
		if not h.disposed then
			h.dispose()
		end
		for _, t in ipairs(h.tasks) do
			local ended = mare.task.timeout(LIMIT_MS, function()
				pcall(t.wait, t)
			end)
			assert(ended, "a task did not end after teardown")
		end
	end
	live[#live + 1] = h
	return h
end

local function result(t)
	local r = table.pack(mare.task.timeout(LIMIT_MS, function()
		return t:wait()
	end))
	assert(r[1], "timed out waiting for a caller's answer")
	return table.pack(table.unpack(r, 2, r.n))
end

local function join(t)
	local r = result(t)
	return table.unpack(r, 1, r.n)
end

local function expect_ok(t, outcome)
	local r = result(t)
	expect.eq(r[1], true)
	expect.eq(r[2], outcome)
end

local function expect_fail(t, kind)
	local r = result(t)
	expect.eq(r[1], nil)
	expect.eq(r[3], kind)
	return r[2]
end

-- Initial on, busy, S(off) queued, T started and its write W1 (off) is held.
-- `x` is the initial state for the mirrored variant.
local function start_c(x)
	local h = harness({ initial = x })
	h.busy = true
	local ok, outcome = h.select_now(not x)
	expect.eq(ok, true)
	expect.eq(outcome, "queued")
	local turn = h.turn_wait()
	local w1 = h.arrive()
	expect.eq(w1.value.active, not x)
	expect.eq(h.gate(), true)
	return h, turn, w1
end

local function pick(cond, a, b)
	if cond then
		return a
	end
	return b
end

local UNKNOWN = {
	{ how = "fail", landed = false },
	{ how = "fail_landed", landed = true },
	{ how = "throw", landed = false },
	{ how = "throw_landed", landed = true },
}

describe("plan-mode coordinator scenarios", function()
	after_each(function()
		for _, h in ipairs(live) do
			h.finish()
		end
		live = {}
	end)

	-- A: idle selections
	it("idle activation gates writes immediately and commits on save", function()
		local h = harness()
		local s = h.select_wait(true)
		local w1 = h.arrive()
		expect.eq(h.gate(), true)
		h.release(w1, "ok")
		expect_ok(s, "committed")
		expect.eq(h.gate(), true)
		expect.eq((h.restored()), true)
		h.writes(1)
	end)

	it("idle deactivation keeps the gate on until the save commits", function()
		local h = harness({ initial = true })
		local s = h.select_wait(false)
		local w1 = h.arrive()
		expect.eq(h.gate(), true)
		h.release(w1, "ok")
		expect_ok(s, "committed")
		expect.eq(h.gate(), false)
		expect.eq((h.restored()), false)
		h.writes(1)
	end)

	it("selecting the current idle state is a no-op without a write", function()
		local h = harness({ initial = true })
		local ok, outcome = h.select_now(true)
		expect.eq(ok, true)
		expect.eq(outcome, "noop")
		expect.eq(h.gate(), true)
		expect.eq((h.restored()), true)
		h.writes(0)
	end)

	for _, x in ipairs({ true, false }) do
		for _, u in ipairs(UNKNOWN) do
			local cell = (x and "initially on" or "initially off")
				.. (u.how:find("throw") and " with thrown error" or "")
			it(
				("%s; state %s; select %s; save %s -> retry with a higher revision"):format(
					cell,
					x and "on" or "off",
					x and "off" or "on",
					u.how
				),
				function()
					local h = harness({ initial = x })
					local s = h.select_wait(not x)
					local w1 = h.arrive()
					expect.eq(h.gate(), true)
					h.release(w1, u.how)
					local msg = expect_fail(s, "unconfirmed")
					assert(msg:find("retrying at the next step", 1, true), msg)
					assert(msg:find(x and "stays on" or "is on for this run", 1, true), msg)
					expect.eq(h.gate(), true)
					expect.eq((h.restored()), pick(u.landed, not x, x))
					expect.eq(h.state.view().status, "unconfirmed")
					local t = h.turn_wait()
					local w2 = h.arrive()
					expect.eq(w2.value.active, not x)
					expect.eq(h.gate(), true)
					h.release(w2, "ok")
					expect.eq(join(t), "returned")
					expect.eq(h.gate(), not x)
					expect.eq((h.restored()), not x)
					h.writes(2)
				end
			)
		end
	end

	for _, u in ipairs(UNKNOWN) do
		it("after an unconfirmed deactivation " .. u.how .. ", selecting on writes again", function()
			local h = harness({ initial = true })
			local s1 = h.select_wait(false)
			h.release(h.arrive(), u.how)
			expect_fail(s1, "unconfirmed")
			local s2 = h.select_wait(true)
			local w2 = h.arrive()
			expect.eq(w2.value.active, true)
			expect.eq(h.gate(), true)
			h.release(w2, "ok")
			expect_ok(s2, "committed")
			expect.eq(h.gate(), true)
			expect.eq((h.restored()), true)
			h.writes(2)
		end)
	end

	it("read-only sessions reject activation without a write", function()
		local h = harness()
		h.readonly = true
		local ok, msg, kind = h.select_now(true)
		expect.eq(ok, nil)
		expect.eq(kind, "rejected")
		assert(msg:find("read-only", 1, true))
		expect.eq(h.gate(), false)
		expect.eq((h.restored()), false)
		h.writes(0)
	end)

	-- B: busy, queued until the next turn-start
	for _, x in ipairs({ false, true }) do
		it(
			("%s; initially %s; select %s while busy; next turn saves"):format(
				x and "deactivation" or "activation",
				x and "on" or "off",
				x and "off" or "on"
			),
			function()
				local h = harness({ initial = x })
				h.busy = true
				local ok, outcome = h.select_now(not x)
				expect.eq(ok, true)
				expect.eq(outcome, "queued")
				expect.eq(h.gate(), x)
				expect.eq(h.state.view().pending, not x)
				local t = h.turn_wait()
				local w1 = h.arrive()
				expect.eq(h.gate(), true)
				h.release(w1, "ok")
				expect.eq(join(t), "returned")
				expect.eq(h.gate(), not x)
				expect.eq((h.restored()), not x)
				h.writes(1)
			end
		)
	end

	it("reversing a busy selection cancels it without a write", function()
		local h = harness({ initial = true })
		h.busy = true
		expect.eq(select(2, h.select_now(false)), "queued")
		expect.eq(select(2, h.select_now(true)), "cancelled")
		h.turn_now()
		expect.eq(h.gate(), true)
		expect.eq((h.restored()), true)
		h.writes(0)
	end)

	it("repeating a busy selection results in one write", function()
		local h = harness({ initial = true })
		h.busy = true
		expect.eq(select(2, h.select_now(false)), "queued")
		local seq = h.state.selection_revision()
		expect.eq(select(2, h.select_now(false)), "queued")
		expect.eq(h.state.selection_revision(), seq)
		local t = h.turn_wait()
		h.release(h.arrive(), "ok")
		join(t)
		expect.eq(h.gate(), false)
		expect.eq((h.restored()), false)
		h.writes(1)
	end)

	for _, x in ipairs({ true, false }) do
		for _, u in ipairs(UNKNOWN) do
			it(
				("%s; initially %s; unconfirmed save %s retries next turn"):format(
					x and "deactivation" or "activation",
					x and "on" or "off",
					u.how
				),
				function()
					local h = harness({ initial = x })
					h.busy = true
					h.select_now(not x)
					local t1 = h.turn_wait()
					local w1 = h.arrive()
					expect.eq(h.gate(), true)
					h.release(w1, u.how)
					expect.eq(join(t1), "returned")
					expect.eq(h.gate(), true)
					expect.eq((h.restored()), pick(u.landed, not x, x))
					local t2 = h.turn_wait()
					local w2 = h.arrive()
					expect.eq(h.gate(), true)
					h.release(w2, "ok")
					join(t2)
					expect.eq(h.gate(), not x)
					expect.eq((h.restored()), not x)
					h.writes(2)
				end
			)
		end
	end

	for _, u in ipairs(UNKNOWN) do
		it("after a busy deactivation is unconfirmed " .. u.how .. ", the next turn saves activation", function()
			local h = harness({ initial = true })
			h.busy = true
			h.select_now(false)
			local t1 = h.turn_wait()
			h.release(h.arrive(), u.how)
			join(t1)
			local ok, outcome = h.select_now(true)
			expect.eq(ok, true)
			expect.eq(outcome, "queued")
			expect.eq(h.gate(), true)
			local t2 = h.turn_wait()
			local w2 = h.arrive()
			expect.eq(w2.value.active, true)
			expect.eq(h.gate(), true)
			h.release(w2, "ok")
			join(t2)
			expect.eq(h.gate(), true)
			expect.eq((h.restored()), true)
			h.writes(2)
		end)
	end

	it("busy exit approval queues and stores the proposed plan on the next turn", function()
		local h = harness({ initial = true })
		h.busy = true
		local ok, outcome = h.state.select(false, false, "# Plan")
		expect.eq(ok, true)
		expect.eq(outcome, "queued")
		expect.eq(h.gate(), true)
		local t = h.turn_wait()
		local w1 = h.arrive()
		expect.eq(w1.value.plan, "# Plan")
		h.release(w1, "ok")
		join(t)
		expect.eq(h.gate(), false)
		local active, view = h.restored()
		expect.eq(active, false)
		expect.eq(view.plan, "# Plan")
		h.writes(1)
	end)

	-- C: selections while a write is in flight (initial x, busy, S(not x) queued, T -> W1 held)
	for _, x in ipairs({ true, false }) do
		local tag = x and "" or " (mirror)"
		it("a reversal waits for the in-flight save and then commits" .. tag, function()
			local h, turn, w1 = start_c(x)
			local s = h.select_wait(x)
			h.release(w1, "ok")
			local w2 = h.arrive()
			expect.eq(w2.value.active, x)
			expect.eq(h.gate(), true)
			h.release(w2, "ok")
			expect_ok(s, "committed")
			join(turn)
			expect.eq(h.gate(), x)
			expect.eq((h.restored()), x)
			h.writes(2)
		end)

		for _, u in ipairs(UNKNOWN) do
			it("an unconfirmed reversal " .. u.how .. " retries on the next turn" .. tag, function()
				local h, turn, w1 = start_c(x)
				local s = h.select_wait(x)
				h.release(w1, "ok")
				local w2 = h.arrive()
				h.release(w2, u.how)
				expect_fail(s, "unconfirmed")
				join(turn)
				expect.eq(h.gate(), true)
				expect.eq((h.restored()), pick(u.landed, x, not x))
				local t = h.turn_wait()
				local w3 = h.arrive()
				expect.eq(w3.value.active, x)
				h.release(w3, "ok")
				join(t)
				expect.eq(h.gate(), x)
				expect.eq((h.restored()), x)
				h.writes(3)
			end)

			it("an unconfirmed in-flight save " .. u.how .. " rewrites the reversal next turn" .. tag, function()
				local h, turn, w1 = start_c(x)
				local s = h.select_wait(x)
				h.release(w1, u.how)
				expect_fail(s, "unconfirmed")
				join(turn)
				expect.eq(h.gate(), true)
				expect.eq((h.restored()), pick(u.landed, not x, x))
				h.writes(1)
				local t = h.turn_wait()
				local w2 = h.arrive()
				expect.eq(w2.value.active, x)
				h.release(w2, "ok")
				join(t)
				expect.eq(h.gate(), x)
				expect.eq((h.restored()), x)
				h.writes(2)
			end)
		end

		it("duplicate reversals both wait until their shared save commits" .. tag, function()
			local h, turn, w1 = start_c(x)
			local s1 = h.select_wait(x)
			local s2 = h.select_wait(x)
			h.release(w1, "ok")
			local w2 = h.arrive()
			expect.eq(s1:done(), false)
			expect.eq(s2:done(), false)
			expect.eq(h.gate(), true)
			h.release(w2, "ok")
			expect_ok(s1, "committed")
			expect_ok(s2, "committed")
			join(turn)
			expect.eq(h.gate(), x)
			expect.eq((h.restored()), x)
			h.writes(2)
		end)

		it("a new selection supersedes a reversal while its save is in flight" .. tag, function()
			local h, turn, w1 = start_c(x)
			local s1 = h.select_wait(x)
			h.release(w1, "ok")
			local w2 = h.arrive()
			local s2 = h.select_wait(not x)
			expect.eq(h.gate(), true)
			h.release(w2, "ok")
			local w3 = h.arrive()
			expect.eq(w3.value.active, not x)
			expect.eq(h.gate(), true)
			h.release(w3, "ok")
			expect_ok(s1, "superseded")
			expect_ok(s2, "committed")
			join(turn)
			expect.eq(h.gate(), not x)
			expect.eq((h.restored()), not x)
			h.writes(3)
		end)
	end

	it("deactivation supersedes a pending activation while deactivation saves", function()
		local h, turn, w1 = start_c(true)
		local s1 = h.select_wait(true)
		local s2 = h.select_wait(false)
		expect.eq(h.gate(), true)
		h.release(w1, "ok")
		expect_ok(s1, "superseded")
		expect_ok(s2, "committed")
		join(turn)
		expect.eq(h.gate(), false)
		expect.eq((h.restored()), false)
		h.writes(1)
	end)

	it("activation supersedes a pending deactivation while activation saves", function()
		local h, turn, w1 = start_c(false)
		local s1 = h.select_wait(false)
		local s2 = h.select_wait(true)
		expect.eq(h.gate(), true)
		h.release(w1, "ok")
		expect_ok(s1, "superseded")
		expect_ok(s2, "committed")
		join(turn)
		expect.eq(h.gate(), true)
		expect.eq((h.restored()), true)
		h.writes(1)
	end)

	-- D: callers force-aborted; the coordinator keeps going and the remaining callers still get answers.
	for _, x in ipairs({ true, false }) do
		local tag = x and "" or " (mirror)"
		it("aborting a reversal caller does not stop its queued saves" .. tag, function()
			local h, turn, w1 = start_c(x)
			local s = h.select_wait(x)
			s:abort()
			h.release(w1, "ok")
			local w2 = h.arrive()
			expect.eq(w2.value.active, x)
			expect.eq(h.gate(), true)
			h.release(w2, "ok")
			join(turn)
			expect.eq(h.gate(), x)
			expect.eq((h.restored()), x)
			h.writes(2)
		end)

		it("aborting one of two reversal callers leaves the other waiting" .. tag, function()
			local h, turn, w1 = start_c(x)
			local s1 = h.select_wait(x)
			local s2 = h.select_wait(x)
			s1:abort()
			h.release(w1, "ok")
			local w2 = h.arrive()
			expect.eq(s2:done(), false)
			expect.eq(h.gate(), true)
			h.release(w2, "ok")
			expect_ok(s2, "committed")
			join(turn)
			expect.eq(h.gate(), x)
			expect.eq((h.restored()), x)
			h.writes(2)
		end)

		it("aborting the turn-start listener does not stop the save" .. tag, function()
			local h, turn, w1 = start_c(x)
			h.drain()
			turn:abort()
			expect.eq(h.gate(), true)
			h.release(w1, "ok")
			h.change("committed")
			expect.eq(h.gate(), not x)
			expect.eq((h.restored()), not x)
			h.writes(1)
		end)

		it("a reversal commits after the turn-start listener is aborted" .. tag, function()
			local h, turn, w1 = start_c(x)
			turn:abort()
			local s = h.select_wait(x)
			h.release(w1, "ok")
			local w2 = h.arrive()
			expect.eq(h.gate(), true)
			h.release(w2, "ok")
			expect_ok(s, "committed")
			expect.eq(h.gate(), x)
			expect.eq((h.restored()), x)
			h.writes(2)
		end)

		for _, how in ipairs({ "ok", "fail", "fail_landed" }) do
			it("an idle selection caller is aborted while save returns " .. how .. tag, function()
				local h = harness({ initial = x })
				local s = h.select_wait(not x)
				local w1 = h.arrive()
				s:abort()
				h.drain()
				h.release(w1, how)
				if how == "ok" then
					h.change("committed")
					expect.eq(h.gate(), not x)
					expect.eq((h.restored()), not x)
				else
					h.change("unconfirmed")
					expect.eq(h.gate(), true)
					expect.eq((h.restored()), pick(how == "fail_landed", not x, x))
				end
				h.writes(1)
			end)
		end

		it("aborting a writer leaves another caller waiting for the same selection" .. tag, function()
			local h = harness({ initial = x })
			local s1 = h.select_wait(not x)
			local w1 = h.arrive()
			local s2 = h.select_wait(not x)
			s1:abort()
			h.release(w1, "ok")
			expect_ok(s2, "committed")
			expect.eq(h.gate(), not x)
			expect.eq((h.restored()), not x)
			h.writes(1)
		end)
	end

	-- E: session switch and dispose (two separate logs, A and B)
	for _, how in ipairs({ "ok", "stale" }) do
		it("switching to an inactive session during save " .. how .. " rejects the old selection", function()
			local h, turn, w1 = start_c(true)
			local s = h.select_wait(true)
			h.switch("B")
			expect_fail(s, "session_changed")
			join(turn)
			expect.eq(h.gate(), false)
			h.release(w1, how)
			h.returned(w1)
			expect.eq(h.gate(), false)
			expect.eq((h.restored()), false)
			expect.eq(#h.logs.B, 0)
			h.writes(1)
			-- The worker is free for the new session.
			h.busy = false
			local s2 = h.select_wait(true)
			local w2 = h.arrive()
			expect.eq(w2.sid, "B")
			h.release(w2, "ok")
			expect_ok(s2, "committed")
		end)
	end

	it("switching to an active session during a save rejects the old selection and follows the new gate", function()
		local h, turn, w1 = start_c(true)
		h.logs.B = { { version = 1, active = true, revision = 3 } }
		local s = h.select_wait(true)
		h.switch("B")
		expect_fail(s, "session_changed")
		join(turn)
		expect.eq(h.gate(), true)
		h.release(w1, "ok")
		h.returned(w1)
		expect.eq(h.gate(), true)
		expect.eq((h.restored()), true)
		expect.eq(#h.logs.B, 1)
		h.writes(1)
	end)

	it("a busy selection from the old session is discarded when the new session starts a turn", function()
		local h = harness({ initial = true })
		h.busy = true
		expect.eq(select(2, h.select_now(false)), "queued")
		h.switch("B")
		h.turn_now()
		expect.eq(h.gate(), false)
		expect.eq((h.restored()), false)
		expect.eq(#h.logs.A, 1)
		expect.eq(h.logs.A[1].active, true)
		expect.eq(#h.logs.B, 0)
		h.writes(0)
	end)

	for _, how in ipairs({ "ok", "stale" }) do
		it("returning to a session after a held save " .. how .. " restores state and advances revision", function()
			local h, _, w1 = start_c(true)
			h.switch("B")
			h.release(w1, how)
			h.returned(w1)
			h.switch("A")
			local landed = how == "ok"
			expect.eq(h.gate(), not landed)
			expect.eq((h.restored()), not landed)
			h.busy = false
			local s = h.select_wait(landed)
			local w2 = h.arrive()
			expect.eq(w2.sid, "A")
			h.release(w2, "ok")
			expect_ok(s, "committed")
			expect.eq(h.gate(), landed)
			h.writes(2)
		end)
	end

	it("same-identity session/changed leaves an in-flight save and reversal intact", function()
		local h, turn, w1 = start_c(true)
		h.events["session/changed"]()
		expect.eq(h.gate(), true)
		expect.eq(h.state.view().status, "committing")
		local s = h.select_wait(true)
		h.release(w1, "ok")
		local w2 = h.arrive()
		h.release(w2, "ok")
		expect_ok(s, "committed")
		join(turn)
		expect.eq(h.gate(), true)
		expect.eq((h.restored()), true)
		h.writes(2)
	end)

	it("disposing during a held save rejects the waiting selection without another write", function()
		local h, turn, w1 = start_c(true)
		local s = h.select_wait(true)
		h.dispose()
		expect_fail(s, "disposed")
		join(turn)
		h.release(w1, "ok")
		expect.eq((h.restored()), true)
		h.writes(1)
	end)

	it("switching before a selection starts writing leaves the new session untouched", function()
		local h = harness({ initial = true })
		h.on_change = function(reason)
			if reason == "waiting" then
				h.on_change = nil
				h.switch("B")
			end
		end
		local s = h.select_wait(false)
		expect_fail(s, "session_changed")
		expect.eq(h.gate(), false)
		expect.eq((h.restored()), false)
		expect.eq(#h.logs.A, 1)
		expect.eq(#h.logs.B, 0)
		h.writes(0)
		local s2 = h.select_wait(true)
		local w = h.arrive()
		expect.eq(w.sid, "B")
		h.release(w, "ok")
		expect_ok(s2, "committed")
	end)

	-- F: restore
	local function restore_of(log)
		local h = harness({ logs = { A = log } })
		return h, h.state.current(), h.state.view()
	end

	it("restore chooses the highest revision over physical order", function()
		local h, cur = restore_of({
			{ version = 1, active = true, revision = 5 },
			{ version = 1, active = false, revision = 4 },
		})
		expect.eq(cur.active, true)
		expect.eq(h.gate(), true)
	end)

	it("restore chooses the later record for equal revisions", function()
		local _, cur = restore_of({
			{ version = 1, active = true, revision = 3 },
			{ version = 1, active = false, revision = 3 },
		})
		expect.eq(cur.active, false)
	end)

	it("restore ignores malformed records", function()
		local _, cur = restore_of({
			{ version = 1, active = true, revision = 1 },
			{ version = 8, active = false, revision = 9 },
			{ version = 1, active = "no", revision = 9 },
			{ version = 1, active = false, revision = -1 },
			{ version = 1, active = false, revision = 9.5 },
			{ version = 1, active = false, revision = 9, plan = 123 },
		})
		expect.eq(cur.active, true)
		expect.eq(cur.revision, 1)
	end)

	it("restore preserves entered across a later off record", function()
		local _, cur = restore_of({
			{ version = 1, active = true, revision = 1 },
			{ version = 1, active = false, revision = 2 },
		})
		expect.eq(cur.active, false)
		expect.eq(cur.entered, true)
	end)

	it("the first write after restore exceeds the log maximum revision", function()
		local h = restore_of({ { version = 1, active = false, entered = false, revision = 9, plan = "# P" } })
		local s = h.select_wait(true)
		local w1 = h.arrive()
		expect.eq(w1.value.revision, 10)
		expect.eq(w1.value.plan, "# P")
		h.release(w1, "ok")
		expect_ok(s, "committed")
		h.writes(1)
	end)

	it("an empty log restores off at revision zero", function()
		local h, cur = restore_of({})
		expect.eq(cur.active, false)
		expect.eq(cur.revision, 0)
		expect.eq(h.gate(), false)
		local s = h.select_wait(true)
		local w1 = h.arrive()
		expect.eq(w1.value.revision, 1)
		h.release(w1, "ok")
		expect_ok(s, "committed")
	end)

	it("uses session_id and session_epoch without legacy id or generation fallbacks", function()
		local c = coordinator.new(
			{ session_id = "sess-1", session_epoch = "epoch-1", ephemeral = false },
			{ active = false, entered = false, plan = nil },
			0,
			{}
		)
		expect.eq(c.id, "sess-1")
		expect.eq(c.generation, "epoch-1")

		local legacy = coordinator.new(
			{ id = "old-id", generation = "old-gen", ephemeral = false },
			{ active = false, entered = false, plan = nil },
			0,
			{}
		)
		expect.eq(legacy.id, nil)
		expect.eq(legacy.generation, nil)
	end)
end)
