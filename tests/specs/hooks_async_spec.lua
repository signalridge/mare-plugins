local H = assert(load(mare.fs.read("tests/specs/hooks_support.lua"), "@tests/specs/hooks_support.lua"))()

local mono_clock = mare.task.clock
local orig_now = mare.task.now
local orig_spawn = mare.task.spawn

local describe = mare.test.describe
local it = mare.test.it
local before_each = mare.test.before_each
local after_each = mare.test.after_each
local expect = mare.test.expect

local S, ctx, plugin = H.S, H.ctx, H.plugin

describe("hooks async", function()
	local real_log = mare.log
	mare.test.after_each(function()
		mare.log = real_log
	end)
	local clock
	local working_history, spilled, recorded, agent_notifies
	local activity_fn, listener_map, dispose_cbs
	local inflight, spawned_tasks, tasks_by_co
	local applying = false

	local function make_async_env()
		clock = 1000
		working_history, spilled, recorded, agent_notifies = {}, {}, {}, {}
		activity_fn, listener_map, dispose_cbs = nil, {}, {}
		inflight, spawned_tasks, tasks_by_co = {}, {}, {}

		mare.task.now = function()
			clock = clock + 10
			return clock
		end
		mare.task.spawn = function(fn, ...)
			local tracker = { done = false, status = "running", err = nil, expect_aborted = applying }
			spawned_tasks[#spawned_tasks + 1] = tracker
			local task = orig_spawn(function(...)
				local co = coroutine.running()
				tasks_by_co[co] = tracker
				local ok, err = pcall(fn, ...)
				tasks_by_co[co] = nil
				tracker.status = ok and "ok" or "error"
				tracker.err = not ok and err or nil
				tracker.done = true
				if not ok then
					error(err)
				end
			end, ...)
			tracker.task = task
			return task
		end
		mare.ui.connected = function()
			return true
		end
		mare.ui.working = function(msg)
			if msg == nil then
				msg = false
			end
			working_history[#working_history + 1] = msg
		end
		mare.paths = { state = "/state" }
		mare.proc.spill_write = function(prefix, path, text)
			expect.eq(prefix, "hooks")
			spilled[path] = text
			return true
		end
		mare.proc.spill_remove = function(prefix, path)
			expect.eq(prefix, "hooks")
			spilled[path] = nil
		end
		ctx.agent.notify = function(_, text, opts)
			agent_notifies[#agent_notifies + 1] = { text = text, opts = opts }
		end
		ctx.agent.register_activity = function(_, name, fn)
			if name == "hooks" then
				activity_fn = fn
			end
			return function() end
		end
		ctx.session.add_record = function(_, kind, entry, opts)
			if kind == "hooks/audit" then
				recorded[#recorded + 1] = { entry = entry, opts = opts }
			end
			return { durable = true }
		end
		ctx.on = function(_, ev, fn, opts)
			listener_map[ev] = listener_map[ev] or {}
			listener_map[ev][#listener_map[ev] + 1] = { fn = fn, prio = (opts and opts.priority) or 0 }
			table.sort(listener_map[ev], function(a, b)
				return a.prio > b.prio
			end)
			S.events[ev] = fn
			S.registered[ev] = opts or {}
		end
		ctx.effect = function(_, setup)
			local fn = setup()
			dispose_cbs[#dispose_cbs + 1] = fn
		end
	end

	local function emit_all(ev, ...)
		local out
		for _, item in ipairs(listener_map[ev] or {}) do
			local r = item.fn(...)
			if out == nil and r ~= nil then
				out = r
			end
		end
		return out
	end

	-- unloading the plugin (shutdown or reload) runs its effects' cleanups
	local function unload()
		for _, cb in ipairs(dispose_cbs) do
			cb()
		end
		dispose_cbs = {}
	end

	local function wait_until(pred, msg_fn, timeout_ms)
		local deadline = mono_clock() + (timeout_ms or 5000)
		while true do
			if pred() then
				return
			end
			if mono_clock() >= deadline then
				local msg = type(msg_fn) == "function" and msg_fn() or msg_fn
				error(msg or "condition barrier timed out")
			end
			mare.task.sleep(2)
		end
	end

	local function worker_outcome(tracker)
		if not tracker then
			return nil
		end
		if tracker.done then
			return tracker.status
		end
		if tracker.task and type(tracker.task.done) == "function" then
			local ok, res = pcall(tracker.task.done, tracker.task)
			if ok and res == true then
				return tracker.status == "running" and "aborted" or tracker.status
			end
		end
		return nil
	end

	local function worker_is_done(tracker)
		return worker_outcome(tracker) ~= nil
	end

	local function all_tasks_done()
		for _, tracker in ipairs(spawned_tasks) do
			if not worker_is_done(tracker) then
				return false
			end
		end
		return true
	end

	local function label_for_command(cmd)
		for si, src in ipairs(S.config and S.config.sources or {}) do
			for ev_name, groups in pairs(src.hooks or {}) do
				for gi, g in ipairs(groups) do
					for hi, h in ipairs(g.hooks or {}) do
						if h.command == cmd then
							return ("%s %s %d:%d:%d"):format(src.dialect, ev_name, si, gi, hi)
						end
					end
				end
			end
		end
		return cmd
	end

	local function find_audit(label, from_idx)
		for i = (from_idx or 1), #recorded do
			local entry = recorded[i].entry
			if entry and entry.label == label then
				return entry, i
			end
		end
		return nil, nil
	end

	local function is_active_label(label)
		local act = activity_fn and activity_fn()
		if not act or type(act.active) ~= "table" then
			return false
		end
		for _, item in ipairs(act.active) do
			if item.label == label then
				return true
			end
		end
		return false
	end

	local orig_apply = plugin.apply
	plugin.apply = function(...)
		applying = true
		local ok, err = pcall(orig_apply, ...)
		applying = false
		if not ok then
			error(err, 0)
		end
	end

	local function wait_inflight(target)
		wait_until(function()
			return #inflight >= target
		end, function()
			return ("inflight target %d not reached (got %d)"):format(target, #inflight)
		end)
	end

	local function release_one(idx, res, opts)
		local entry = table.remove(inflight, idx)
		assert(entry, "missing inflight async run")
		local prev_recorded = #recorded
		local label = label_for_command(entry.cmd)
		local sent = entry.tx:send(res)
		assert(sent ~= false, "async run receiver already closed before send for " .. tostring(entry.cmd))
		wait_until(function()
			local outcome = worker_outcome(entry.worker)
			if outcome == "error" or outcome == "aborted" then
				error(
					("worker %q ended with %s: %s"):format(
						tostring(entry.cmd),
						tostring(outcome),
						tostring(entry.worker and entry.worker.err)
					)
				)
			end
			if not entry.done or outcome ~= "ok" then
				return false
			end
			if opts and opts.mode == "cancelled" then
				return true
			end
			if opts and opts.mode == "stale" then
				return not is_active_label(label)
			end
			return find_audit(label, prev_recorded + 1) ~= nil
		end, function()
			return ("released async run %q (%s) did not settle (done=%s outcome=%s rec=%d->%d active=%s)"):format(
				tostring(entry.cmd),
				tostring(label),
				tostring(entry.done),
				tostring(worker_outcome(entry.worker)),
				prev_recorded,
				#recorded,
				tostring(is_active_label(label))
			)
		end)
	end

	local function park_proc(opts)
		S.runs = S.runs + 1
		S.proc_opts = opts
		local tx, rx = mare.task.channel()
		local cmd = opts and opts.args and opts.args[2] or nil
		local worker = tasks_by_co[coroutine.running()]
		local entry = { opts = opts, tx = tx, cmd = cmd, worker = worker, done = false }
		inflight[#inflight + 1] = entry
		local res = rx:recv()
		entry.done = true
		return res
	end

	local function json_ok(tbl)
		return { code = 0, stdout = mare.json.encode_strict(tbl), stderr = "", dropped = 0 }
	end

	before_each(function()
		H.reset()
		make_async_env()
		S.skip_proc_assert = true
	end)

	after_each(function()
		local ok, cleanup_err = pcall(function()
			while #inflight > 0 do
				local entry = table.remove(inflight, 1)
				if not worker_is_done(entry.worker) then
					local ok_send, sent = pcall(
						entry.tx.send,
						entry.tx,
						{ code = nil, stdout = "", stderr = "", dropped = 0, cancelled = true }
					)
					if ok_send and sent == false and not worker_is_done(entry.worker) then
						error("receiver closed while worker still running for " .. tostring(entry.cmd))
					end
				end
			end
			for _, cb in ipairs(dispose_cbs) do
				pcall(cb)
			end
			wait_until(all_tasks_done, function()
				return "async worker tasks did not finish before teardown"
			end)
			for i, tracker in ipairs(spawned_tasks) do
				local outcome = worker_outcome(tracker)
				if outcome == "error" then
					error(("async task #%d errored: %s"):format(i, tostring(tracker.err)))
				end
				if outcome == "aborted" and not tracker.expect_aborted then
					error(("async task #%d aborted unexpectedly"):format(i))
				end
			end
		end)
		mare.task.spawn = orig_spawn
		mare.task.now = orig_now
		H.teardown()
		if not ok then
			error(cleanup_err)
		end
	end)

	it("runs async hooks non-blocking, ignores async vetoes, and delivers capped context", function()
		mare.proc.run = park_proc
		S.config = {
			sources = {
				{
					dialect = "claude-code",
					hooks = {
						PreToolUse = {
							{
								matcher = "probe",
								hooks = {
									{
										command = "async-pre",
										async = true,
										timeout = 5,
										statusMessage = "Async pre...",
									},
								},
							},
						},
						Stop = {
							{
								hooks = {
									{ command = "async-stop", async = true, timeout = 5 },
								},
							},
						},
						SessionEnd = {
							{
								hooks = {
									{ command = "sync-end", async = true, timeout = 2 },
								},
							},
						},
					},
				},
			},
		}
		plugin.apply(ctx, S.config)
		expect.eq(#S.diagnostics, 1)
		expect.truthy(S.diagnostics[1]:find("running async SessionEnd hook synchronously", 1, true))

		local pre_res = emit_all("tool/before", { id = "c1", name = "probe", cwd = "/actual", arguments = {} })
		expect.eq(pre_res.decision, "allow")
		wait_inflight(1)
		expect.eq(#inflight, 1)
		expect.falsy(inflight[1].opts.cancel:is_cancelled())

		local act = activity_fn()
		expect.truthy(act)
		expect.eq(#act.active, 1)
		expect.eq(act.active[1].async, true)
		expect.eq(act.active[1].status_message, "Async pre...")
		expect.eq(working_history[#working_history], "Async pre...")

		release_one(
			1,
			json_ok({
				systemMessage = "Async lint notice",
				hookSpecificOutput = {
					hookEventName = "PreToolUse",
					permissionDecision = "deny",
					permissionDecisionReason = "ignored async deny",
					additionalContext = string.rep("X", 70000),
				},
			})
		)
		expect.eq(working_history[#working_history], false)
		expect.eq(#agent_notifies, 1)
		expect.truthy(agent_notifies[1].opts)
		expect.eq(agent_notifies[1].opts.wake, false)
		expect.truthy(#agent_notifies[1].text <= 8192)
		expect.truthy(agent_notifies[1].text:find("saved to /state/spill/hooks-", 1, true))
		expect.eq(#S.notifications, 1)
		expect.eq(S.notifications[1].text, "Async lint notice")
		expect.eq(#recorded, 1)
		expect.eq(recorded[1].entry.status, "completed")
		expect.eq(recorded[1].entry.async, true)

		local stop_res = emit_all("agent/turn-stopping", { turn_id = "t-async", cancel = mare.task.token() })
		expect.eq(stop_res, nil)
		wait_inflight(1)
		expect.eq(#inflight, 1)

		release_one(
			1,
			json_ok({
				["continue"] = false,
				stopReason = "should be ignored",
				systemMessage = "Background summary",
			})
		)
		expect.eq(S.agent_aborted, nil)
		expect.eq(S.notifications[#S.notifications].text, "Background summary")
		expect.eq(recorded[#recorded].entry.status, "completed")
	end)

	it("does not allow async hooks to override sync policy denial", function()
		local sync_ran = 0
		mare.proc.run = function(opts)
			if opts.args[2] == "sync-deny" then
				S.runs = S.runs + 1
				sync_ran = sync_ran + 1
				return { code = 2, stdout = "", stderr = "sync denied", dropped = 0 }
			end
			return park_proc(opts)
		end
		S.config = {
			sources = {
				{
					dialect = "claude-code",
					hooks = {
						PreToolUse = {
							{
								matcher = "probe",
								hooks = {
									{ command = "async-allow", async = true, timeout = 5 },
									{ command = "sync-deny", timeout = 5 },
								},
							},
						},
					},
				},
			},
		}
		plugin.apply(ctx, S.config)
		local combined = emit_all("tool/before", { id = "c2", name = "probe", cwd = "/actual", arguments = {} })
		expect.eq(sync_ran, 1)
		expect.eq(combined.decision, "deny")
		wait_inflight(1)
		expect.eq(#inflight, 1)
		release_one(1, json_ok({ hookSpecificOutput = { hookEventName = "PreToolUse", permissionDecision = "allow" } }))
	end)

	it("enforces MAX_CONCURRENT_ASYNC_HOOKS = 8, drops stale generation, and reaps on shutdown", function()
		local sync_end_ran = 0
		mare.proc.run = function(opts)
			if opts.args[2] == "sync-end" then
				S.runs = S.runs + 1
				sync_end_ran = sync_end_ran + 1
				return { code = 0, stdout = "", stderr = "", dropped = 0 }
			end
			return park_proc(opts)
		end
		local hooks_10 = {}
		for i = 1, 10 do
			hooks_10[i] = { command = "async-" .. i, async = true, timeout = 5 }
		end
		S.config = {
			sources = {
				{
					dialect = "claude-code",
					hooks = {
						PreToolUse = { { matcher = "probe", hooks = hooks_10 } },
						SessionEnd = { { hooks = { { command = "sync-end", async = true, timeout = 2 } } } },
					},
				},
			},
		}
		plugin.apply(ctx, S.config)
		emit_all("tool/before", { id = "q1", name = "probe", cwd = "/actual", arguments = {} })
		wait_inflight(8)
		expect.eq(#inflight, 8)

		release_one(1, json_ok({ hookSpecificOutput = { hookEventName = "PreToolUse", additionalContext = "done-1" } }))
		wait_inflight(8)
		expect.eq(#inflight, 8)
		expect.eq(#agent_notifies, 1)

		S.session_info.session_epoch = "epoch-2"
		release_one(
			1,
			json_ok({
				systemMessage = "STALE_MSG",
				hookSpecificOutput = { hookEventName = "PreToolUse", additionalContext = "STALE_CTX" },
			}),
			{ mode = "stale" }
		)
		expect.eq(#agent_notifies, 1)
		expect.eq(#S.notifications, 0)
		expect.eq(#recorded, 1)

		local forced_entries = {}
		local cancelled_tokens = {}
		while #inflight > 0 do
			local entry = table.remove(inflight, 1)
			entry.worker.expect_aborted = true
			forced_entries[#forced_entries + 1] = entry
			cancelled_tokens[#cancelled_tokens + 1] = entry.opts.cancel
		end
		emit_all("session/closed", { session_id = "session", cwd = mare.cwd, reason = "other" })
		expect.eq(sync_end_ran, 1)
		-- Forced abort path:
		-- unloading (shutdown) aborts remaining workers without delivering extra context or notifications.
		unload() -- The plugin's effect drains background hooks.
		for _, tok in ipairs(cancelled_tokens) do
			expect.truthy(tok:is_cancelled())
		end
		wait_until(function()
			for _, entry in ipairs(forced_entries) do
				if not worker_is_done(entry.worker) then
					return false
				end
			end
			return true
		end, function()
			return "forced-aborted worker handles did not terminate after unload"
		end)
		for _, entry in ipairs(forced_entries) do
			expect.eq(worker_outcome(entry.worker), "aborted")
		end
		expect.eq(S.runs, 10)
		expect.eq(#agent_notifies, 1)
		expect.eq(#S.notifications, 0)
	end)

	it("drops cooperative cancel results under the same generation", function()
		mare.proc.run = park_proc
		S.config = {
			sources = {
				{
					dialect = "claude-code",
					hooks = {
						PreToolUse = {
							{
								matcher = "probe",
								hooks = {
									{ command = "coop-cancel", async = true, timeout = 5 },
								},
							},
						},
					},
				},
			},
		}
		plugin.apply(ctx, S.config)
		emit_all("tool/before", { id = "cf-1", name = "probe", cwd = "/actual", arguments = {} })
		wait_inflight(1)
		expect.eq(#inflight, 1)

		local coop_entry = inflight[1]
		local coop_tok = coop_entry.opts.cancel
		expect.falsy(coop_tok:is_cancelled())
		coop_tok:cancel()
		expect.truthy(coop_tok:is_cancelled())

		release_one(
			1,
			json_ok({
				systemMessage = "CANCELLED_MSG",
				hookSpecificOutput = { hookEventName = "PreToolUse", additionalContext = "CANCELLED_CTX" },
			}),
			{ mode = "cancelled" }
		)
		expect.eq(worker_outcome(coop_entry.worker), "ok")
		expect.eq(#recorded, 0)
		expect.eq(#agent_notifies, 0)
		expect.eq(#S.notifications, 0)
	end)

	it("cancels token and force-aborts parked async workers on unload (shutdown)", function()
		mare.proc.run = park_proc
		S.config = {
			sources = {
				{
					dialect = "claude-code",
					hooks = {
						PreToolUse = {
							{
								matcher = "probe",
								hooks = {
									{ command = "force-abort", async = true, timeout = 5 },
								},
							},
						},
					},
				},
			},
		}
		plugin.apply(ctx, S.config)
		emit_all("tool/before", { id = "cf-2", name = "probe", cwd = "/actual", arguments = {} })
		wait_inflight(1)
		expect.eq(#inflight, 1)

		local force_entry = table.remove(inflight, 1)
		force_entry.worker.expect_aborted = true
		expect.falsy(force_entry.opts.cancel:is_cancelled())
		unload() -- The plugin's effect drains background hooks.
		expect.truthy(force_entry.opts.cancel:is_cancelled())
		wait_until(function()
			return worker_is_done(force_entry.worker)
		end, function()
			return "force-aborted worker handle did not terminate"
		end)
		expect.eq(worker_outcome(force_entry.worker), "aborted")
		expect.eq(#recorded, 0)
		expect.eq(#agent_notifies, 0)
		expect.eq(#S.notifications, 0)
	end)

	it("cancels live tokens on dispose and enforces trust + fingerprint for async hooks", function()
		local async_tree = { ["/async-pkg/hook.py"] = "print('v1')" }
		mare.fs = H.make_fs_tree(async_tree)
		mare.proc.run = park_proc
		S.config = {
			requireTrust = true,
			sources = {
				{
					dialect = "claude-code",
					plugin_root = "/async-pkg",
					hooks = {
						PreToolUse = {
							{ matcher = "probe", hooks = { { command = "trusted-async", async = true, timeout = 5 } } },
						},
					},
				},
			},
		}
		plugin.apply(ctx, S.config)
		local trusted_label = label_for_command("trusted-async")
		local untrusted_res = emit_all("tool/before", { id = "u1", name = "probe", cwd = "/actual", arguments = {} })
		local u1_audit, u1_idx
		wait_until(function()
			u1_audit, u1_idx = find_audit(trusted_label, 1)
			return u1_audit ~= nil
		end, function()
			return "untrusted async rejection audit for trusted-async not recorded"
		end)
		expect.eq(untrusted_res.decision, "allow")
		expect.eq(u1_audit.label, trusted_label)
		expect.eq(u1_audit.status, "failed")
		expect.truthy(u1_audit.reason and u1_audit.reason:find("untrusted or modified", 1, true))
		expect.eq(S.runs, 0)
		expect.eq(#inflight, 0)
		expect.eq(#recorded, 1)

		S.select_fn = function()
			return 2
		end
		emit_all("tool/before", { id = "u2", name = "probe", cwd = "/actual", arguments = {} })
		wait_inflight(1)
		expect.eq(S.runs, 1)
		expect.eq(#inflight, 1)

		async_tree["/async-pkg/hook.py"] = "print('v2-modified')"
		S.select_fn = nil
		emit_all("tool/before", { id = "u3", name = "probe", cwd = "/actual", arguments = {} })
		local u3_audit
		wait_until(function()
			u3_audit = find_audit(trusted_label, (u1_idx or 1) + 1)
			return u3_audit ~= nil
		end, function()
			return "tampered async rejection audit for trusted-async not recorded"
		end)
		expect.eq(u3_audit.label, trusted_label)
		expect.eq(u3_audit.status, "failed")
		expect.truthy(u3_audit.reason and u3_audit.reason:find("untrusted or modified", 1, true))
		expect.eq(S.runs, 1)
		expect.eq(#inflight, 1)

		local live_entry = table.remove(inflight, 1)
		live_entry.worker.expect_aborted = true
		local live_tok = live_entry.opts.cancel
		for _, cb in ipairs(dispose_cbs) do
			cb()
		end
		expect.truthy(live_tok:is_cancelled())
		wait_until(function()
			return worker_is_done(live_entry.worker)
		end, function()
			return "disposed worker handle did not terminate"
		end)
		expect.eq(worker_outcome(live_entry.worker), "aborted")
	end)

	it("re-verifies queued async hook package fingerprint after acquiring concurrency slot", function()
		local queued_tree = { ["/queued-pkg/hook.py"] = "print('v1')" }
		mare.fs = H.make_fs_tree(queued_tree)
		mare.proc.run = park_proc
		local queued_hooks = {}
		for i = 1, 9 do
			queued_hooks[i] = { command = "queued-" .. i, async = true, timeout = 5 }
		end
		S.config = {
			requireTrust = true,
			sources = {
				{
					dialect = "claude-code",
					plugin_root = "/queued-pkg",
					hooks = {
						PreToolUse = { { matcher = "probe", hooks = queued_hooks } },
					},
				},
			},
		}
		plugin.apply(ctx, S.config)
		S.select_fn = function()
			return 2
		end
		emit_all("tool/before", { id = "q-trust", name = "probe", cwd = "/actual", arguments = {} })
		wait_inflight(8)
		S.select_fn = nil
		expect.eq(S.runs, 8)
		expect.eq(#inflight, 8)

		-- Mutate package content while the 9th hook is waiting in async_queue.
		queued_tree["/queued-pkg/hook.py"] = "print('v2-tampered-while-queued')"
		local prev_spawned = #spawned_tasks
		release_one(1, json_ok({ hookSpecificOutput = { hookEventName = "PreToolUse", additionalContext = "ok-1" } }))

		local ninth_worker
		wait_until(function()
			ninth_worker = spawned_tasks[prev_spawned + 1]
			return ninth_worker ~= nil and worker_outcome(ninth_worker) == "ok"
		end, function()
			return ("queued-9 worker handle did not finish (spawned=%d->%d outcome=%s)"):format(
				prev_spawned,
				#spawned_tasks,
				tostring(worker_outcome(ninth_worker))
			)
		end)

		local ninth_label = label_for_command("queued-9")
		local ninth_audit = find_audit(ninth_label, 1)
		expect.truthy(ninth_audit)
		expect.eq(ninth_audit.label, ninth_label)
		expect.eq(ninth_audit.status, "failed")
		expect.truthy(ninth_audit.reason and ninth_audit.reason:find("untrusted or modified", 1, true))
		expect.eq(S.runs, 8)
		expect.eq(#inflight, 7)
		expect.eq(#agent_notifies, 1)
		local found_trust_warn = false
		for _, n in ipairs(S.notifications) do
			if
				n.level == "warning"
				and n.text
				and n.text:find(ninth_label, 1, true)
				and n.text:find("untrusted or modified", 1, true)
			then
				found_trust_warn = true
				break
			end
		end
		expect.truthy(found_trust_warn)

		while #inflight > 0 do
			release_one(1, json_ok({}))
		end
		expect.eq(S.runs, 8)
		expect.eq(#agent_notifies, 1)
	end)

	-- Invalid structured JSON output from async hook:
	it("treats invalid structured JSON output from async hook without delivering bad context", function()
		mare.proc.run = park_proc
		S.config = {
			sources = {
				{
					dialect = "claude-code",
					hooks = {
						PreToolUse = {
							{
								matcher = "probe",
								hooks = { { command = "async-bad-json", async = true, timeout = 5 } },
							},
						},
					},
				},
			},
		}
		plugin.apply(ctx, S.config)
		emit_all("tool/before", { id = "bad-1", name = "probe", cwd = "/actual", arguments = {} })
		wait_inflight(1)
		release_one(1, {
			code = 0,
			stdout = '{"systemMessage": 123, "hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": "SHOULD_NOT_DELIVER_BAD_JSON"}}',
			stderr = "",
			dropped = 0,
		})
		local bad_label = label_for_command("async-bad-json")
		local audit = find_audit(bad_label, 1)
		expect.truthy(audit)
		expect.eq(audit.label, bad_label)
		expect.eq(audit.status, "failed")
		expect.truthy(audit.reason and audit.reason:find("systemMessage", 1, true))
		expect.eq(#agent_notifies, 0)
		expect.eq(#S.notifications, 1)
		expect.eq(S.notifications[1].level, "warning")
	end)

	it(
		"preserves FIFO order and uses 2x (not 4x) trust digest scans on queued trusted async hooks while still catching tampering",
		function()
			local orig_shell = mare.proc.shell
			mare.proc.shell = function()
				return { path = "/bin/sh", args = { "-c" }, transport = "argv" }
			end
			local ok_test, test_err = pcall(function()
				local pkg_tree = { ["/fifo-pkg/hook.py"] = "print('v1')" }
				local real_fs = H.make_fs_tree(pkg_tree)
				local dir_scans = 0
				mare.fs = {
					stat = real_fs.stat,
					read = real_fs.read,
					list = function(path, opts)
						if path == "/fifo-pkg" then
							dir_scans = dir_scans + 1
						end
						return real_fs.list(path, opts)
					end,
				}
				local run_order = {}
				mare.proc.run = function(opts)
					run_order[#run_order + 1] = opts and opts.args and opts.args[2] or ""
					return park_proc(opts)
				end

				local hooks_list = {}
				for i = 1, 12 do
					hooks_list[i] = { command = "fifo-" .. i, async = true, timeout = 5 }
				end
				S.config = {
					requireTrust = true,
					sources = {
						{
							dialect = "claude-code",
							plugin_root = "/fifo-pkg",
							hooks = {
								PreToolUse = { { matcher = "probe", hooks = hooks_list } },
							},
						},
					},
				}
				plugin.apply(ctx, S.config)

				-- Trigger once with select=1 ("Trust and run (remember)"), then measure a fresh trusted burst.
				S.select_fn = function()
					return 1
				end
				emit_all("tool/before", { id = "warm", name = "probe", cwd = "/actual", arguments = {} })
				wait_inflight(8)
				wait_until(function()
					while #inflight > 0 do
						release_one(1, json_ok({}))
					end
					return #recorded >= 12
				end, function()
					return ("warm async hooks did not finish (recorded=%d)"):format(#recorded)
				end)
				expect.eq(#run_order, 12)
				for i = 1, 12 do
					expect.truthy(run_order[i]:find("fifo-" .. i, 1, true))
				end

				-- Fresh burst while already trusted: each queued async hook must do 2 scans (enqueue + run), NOT 4!
				S.select_fn = nil
				run_order = {}
				dir_scans = 0
				local rec_base = #recorded
				emit_all("tool/before", { id = "trusted-burst", name = "probe", cwd = "/actual", arguments = {} })
				wait_inflight(8)
				-- While 8 are running, all 12 were scanned once on enqueue (= 12) + 8 scanned on run (= 20) -> <= 20 scans!
				expect.truthy(dir_scans <= 20)
				wait_until(function()
					while #inflight > 0 do
						release_one(1, json_ok({}))
					end
					return (#recorded - rec_base) >= 12
				end, function()
					return ("trusted async burst did not finish (recorded=%d)"):format(#recorded - rec_base)
				end)
				-- Total for 12 trusted async hooks = 24 scans (2x per hook, not 48)!
				expect.eq(dir_scans, 24)
				expect.eq(#run_order, 12)
				for i = 1, 12 do
					expect.truthy(run_order[i]:find("fifo-" .. i, 1, true))
				end

				-- Tamper between enqueue and slot acquisition still rejects queued hooks!
				emit_all("tool/before", { id = "tamper-burst", name = "probe", cwd = "/actual", arguments = {} })
				wait_inflight(8)
				pkg_tree["/fifo-pkg/hook.py"] = "print('tampered-in-queue')"
				local runs_before_release = #run_order
				local rec_tamper = #recorded
				while #inflight > 0 do
					release_one(1, json_ok({}))
				end
				wait_until(function()
					return (#recorded - rec_tamper) >= 12
				end, function()
					return "tampered queued hooks did not finish recording audits"
				end)
				-- The 4 queued hooks (9..12) must NOT have executed after tampering!
				expect.eq(#run_order, runs_before_release)
				local failed_queued = 0
				for idx = rec_tamper + 1, #recorded do
					if recorded[idx].entry.status == "failed" then
						failed_queued = failed_queued + 1
					end
				end
				expect.eq(failed_queued, 4)
			end)
			mare.proc.shell = orig_shell
			if not ok_test then
				error(test_err, 0)
			end
		end
	)

	it("bounds async waiting queue count and bytes and records overflow in audit", function()
		mare.proc.run = park_proc
		local hooks_list = {}
		for i = 1, 75 do
			hooks_list[i] = { command = "backlog-" .. i, async = true, timeout = 5 }
		end
		S.config = {
			sources = {
				{
					dialect = "claude-code",
					hooks = {
						PreToolUse = { { matcher = "probe", hooks = hooks_list } },
					},
				},
			},
		}
		plugin.apply(ctx, S.config)
		emit_all("tool/before", { id = "overflow-1", name = "probe", cwd = "/actual", arguments = {} })
		wait_inflight(8)
		local overflow_audits = 0
		for _, rec in ipairs(recorded) do
			if
				rec.entry
				and rec.entry.status == "failed"
				and rec.entry.reason
				and rec.entry.reason:find("queue limit exceeded", 1, true)
			then
				overflow_audits = overflow_audits + 1
			end
		end
		expect.truthy(overflow_audits > 0)
		while #inflight > 0 do
			release_one(1, json_ok({}))
		end

		-- Oversized single payload (>4MiB) also triggers byte-limit audit failure.
		local before_rec = #recorded
		emit_all("tool/before", {
			id = "overflow-bytes",
			name = "probe",
			cwd = "/actual",
			arguments = { big = string.rep("Z", 4 * 1024 * 1024) },
		})
		local saw_byte_limit = false
		for i = before_rec + 1, #recorded do
			local e = recorded[i].entry
			if e and e.status == "failed" and e.reason and e.reason:find("queue byte limit exceeded", 1, true) then
				saw_byte_limit = true
				break
			end
		end
		expect.truthy(saw_byte_limit)
		while #inflight > 0 do
			release_one(1, json_ok({}))
		end
	end)
end)
