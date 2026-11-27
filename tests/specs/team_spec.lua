local support = assert(load(mare.fs.read("tests/specs/support.lua"), "@tests/specs/support.lua"))()

local describe = mare.test.describe
local it = mare.test.it
local before_each = mare.test.before_each
local after_each = mare.test.after_each
local expect = mare.test.expect

local team_plugin = support.load_plugin("team", { "team.board", "team.store", "team.view" })
local board_mod = require("team.board")
local view_mod = require("team.view")

describe("team", function()
	local tools, commands, events, records, sections, widgets, provided
	local session_info, fail_persist, last_select, notices
	local orig_select, orig_notify, orig_now, fake_now

	before_each(function()
		tools, commands, events, records, sections, widgets, provided = {}, {}, {}, {}, {}, {}, nil
		session_info = { session_id = "sess-team", session_epoch = "epoch-1", ephemeral = false, readonly = false }
		fail_persist, last_select, notices = false, nil, {}
		fake_now = 10000

		orig_select = mare.ui.select
		orig_notify = mare.ui.notify
		orig_now = mare.task.now
		mare.ui.select = function(spec)
			last_select = spec
		end
		mare.ui.notify = function(msg, level)
			notices[#notices + 1] = { msg = msg, level = level }
		end
		mare.task.now = function()
			return fake_now
		end

		local ctx = {
			tools = {
				register = function(_, name, def)
					tools[name] = def
				end,
			},
			commands = {
				register = function(_, name, def)
					commands[name] = def
				end,
			},
			context = {
				section = function(_, def)
					sections[def.name] = def
				end,
				invalidate = function() end,
			},
			ui = {
				widget = function(_, name, def)
					widgets[name] = def
				end,
				invalidate = function() end,
			},
			session = {
				info = function()
					return session_info
				end,
				list_records = function(_, kind)
					local out = {}
					for _, r in ipairs(records) do
						if r.kind == kind then
							out[#out + 1] = r.data
						end
					end
					return { data = out }
				end,
				add_record = function(_, kind, data)
					if fail_persist then
						error("disk error", 0)
					end
					records[#records + 1] = { kind = kind, data = data }
					return { durable = true }
				end,
			},
			provide = function(_, name, impl)
				expect.eq(name, "team")
				provided = impl
			end,
			on = function(_, name, fn)
				events[name] = fn
			end,
			spawn = function(_, fn)
				return mare.task.spawn(fn)
			end,
		}
		team_plugin.apply(ctx, {
			default_lease_ms = 5000,
			release_on_agent_end = true,
			widget = true,
			shared_file = false,
		})
	end)

	after_each(function()
		mare.ui.select = orig_select
		mare.ui.notify = orig_notify
		mare.task.now = orig_now
	end)

	it("manages dependencies, auto-unblock, cycle rejection, and priority claiming", function()
		expect.eq(sections["team:board"].text(), nil)
		expect.eq(widgets.team.render(80), nil)

		local t1 = tools.team_create.execute({ title = "Design schema", priority = "medium" })
		expect.falsy(t1.is_error)
		expect.eq(t1.details.id, "T-1")
		expect.truthy(t1.details.ready)

		local t2 = tools.team_create.execute({
			title = "Implement parser",
			priority = "high",
			blocked_by = { "T-1" },
		})
		expect.falsy(t2.is_error)
		expect.eq(t2.details.blocked, true)
		expect.eq(t2.details.ready, false)

		local t3 = tools.team_create.execute({ title = "Write docs", priority = "low" })
		expect.falsy(t3.is_error)

		-- Cycle detection: T-1 blocked by T-2 creates T-1 -> T-2 -> T-1
		local cyc = tools.team_update.execute({ id = "T-1", add_blocked_by = { "T-2" } })
		expect.truthy(cyc.is_error)
		expect.eq(cyc.error_code, "team.invalid_dependency")

		-- Blocked task cannot be claimed or completed
		local blk_claim = tools.team_claim.execute({ id = "T-2", owner = "agent-1" })
		expect.truthy(blk_claim.is_error)
		expect.eq(blk_claim.error_code, "team.task_blocked")

		local blk_comp = tools.team_complete.execute({ id = "T-2" })
		expect.truthy(blk_comp.is_error)
		expect.eq(blk_comp.error_code, "team.task_blocked")

		-- Next ready claim picks T-1 (medium > low, since T-2 is blocked)
		local c1 = tools.team_claim.execute({ owner = "agent-1" })
		expect.falsy(c1.is_error)
		expect.eq(c1.details.id, "T-1")
		expect.eq(c1.details.owner, "agent-1")

		-- Complete T-1 auto-unblocks T-2
		local done1 = tools.team_complete.execute({
			id = "T-1",
			owner = "agent-1",
			result = "Schema ready",
		})
		expect.falsy(done1.is_error)
		expect.eq(#done1.details.unblocked, 1)
		expect.eq(done1.details.unblocked[1], "T-2")

		-- Now next claim picks T-2 (high priority > T-3 low)
		local c2 = tools.team_claim.execute({ owner = "agent-2" })
		expect.falsy(c2.is_error)
		expect.eq(c2.details.id, "T-2")
	end)

	it("enforces lease conflicts, stale-owner/revision/token safety, and lease expiry reclaim", function()
		tools.team_create.execute({ title = "Shared work" })
		local claimed = tools.team_claim.execute({ id = "T-1", owner = "agent-a", lease_ms = 1000 })
		expect.falsy(claimed.is_error)
		local token_a = claimed.details.lease_token

		-- Active lease blocks another owner
		local steal = tools.team_claim.execute({ id = "T-1", owner = "agent-b" })
		expect.truthy(steal.is_error)
		expect.eq(steal.error_code, "team.lease_conflict")

		-- Stale owner cannot update or complete without force
		local stale_upd = tools.team_update.execute({ id = "T-1", owner = "agent-b", note = "hi" })
		expect.truthy(stale_upd.is_error)
		expect.eq(stale_upd.error_code, "team.stale_owner")

		local stale_comp = tools.team_complete.execute({ id = "T-1", owner = "agent-b" })
		expect.truthy(stale_comp.is_error)
		expect.eq(stale_comp.error_code, "team.stale_owner")

		-- Wrong expected_revision / lease_token rejected
		local bad_rev =
			tools.team_update.execute({ id = "T-1", owner = "agent-a", expected_revision = 999, note = "x" })
		expect.truthy(bad_rev.is_error)
		expect.eq(bad_rev.error_code, "team.conflict")

		local bad_tok = tools.team_complete.execute({ id = "T-1", owner = "agent-a", lease_token = "wrong" })
		expect.truthy(bad_tok.is_error)
		expect.eq(bad_tok.error_code, "team.stale_lease")

		-- Advance clock past lease expiry -> agent-b can reclaim
		fake_now = fake_now + 1500
		local listed = tools.team_list.execute({})
		expect.eq(listed.details.tasks[1].lease_stale, true)

		local reclaimed = tools.team_claim.execute({ id = "T-1", owner = "agent-b" })
		expect.falsy(reclaimed.is_error)
		expect.eq(reclaimed.details.owner, "agent-b")
		expect.truthy(reclaimed.details.lease_token ~= token_a)
	end)

	it(
		"serializes concurrent claims, honors cancellation, rebuilds on /resume, and releases on subagent exit",
		function()
			tools.team_create.execute({ title = "Race task" })

			local r1, r2
			local t1 = mare.task.spawn(function()
				r1 = tools.team_claim.execute({ id = "T-1", owner = "worker-1" })
			end)
			local t2 = mare.task.spawn(function()
				r2 = tools.team_claim.execute({ id = "T-1", owner = "worker-2" })
			end)
			t1:wait()
			t2:wait()
			expect.truthy((not r1.is_error and r2.is_error) or (r1.is_error and not r2.is_error))

			-- Subagent completion releases active lease held by that subagent
			local winner = not r1.is_error and "worker-1" or "worker-2"
			events["subagent/completed"]({ agent_id = winner, status = "failed" })
			local after_rel = tools.team_list.execute({}).details.tasks[1]
			expect.eq(after_rel.status, "pending")
			expect.eq(after_rel.owner, nil)

			-- Cancelled token aborts before mutating
			local tok = mare.task.token()
			tok:cancel()
			local c_res = tools.team_create.execute({ title = "Never saved" }, { cancel = tok })
			expect.truthy(c_res.is_error)
			expect.eq(c_res.error_code, "cancelled")
			expect.eq(tools.team_list.execute({}).details.counts.total, 1)

			-- Persistence failure rolls back mutation
			fail_persist = true
			local p_err = tools.team_create.execute({ title = "Disk fail" })
			expect.truthy(p_err.is_error)
			expect.eq(p_err.error_code, "persist_failed")
			expect.eq(tools.team_list.execute({}).details.counts.total, 1)
			fail_persist = false

			-- Readonly session refuses mutations
			session_info.readonly = true
			local ro = tools.team_create.execute({ title = "Readonly" })
			expect.truthy(ro.is_error)
			expect.eq(ro.error_code, "read_only")
			session_info.readonly = false

			-- /resume rebuild from session records
			local saved_count = #records
			expect.truthy(saved_count >= 2)
			provided.clear()
			expect.eq(provided.list().counts.total, 0)
			-- Restore from earlier records (drop the clear record at tail)
			records[#records] = nil
			events["session/loaded"]()
			expect.eq(provided.list().counts.total, 1)
			expect.eq(provided.list().tasks[1].title, "Race task")

			-- /team inspector & widget & context
			expect.truthy(widgets.team.render(80) ~= nil)
			expect.match(sections["team:board"].text(), "Race task")
			commands.team.run("")
			mare.task.sleep(20)
			expect.truthy(last_select)
			expect.eq(last_select.title, "Team Board")
			expect.eq(#last_select.tabs, 5)
			local prev = last_select.on_highlight(1, 1)
			expect.match(mare.json.encode(prev), "Race task")
		end
	)

	it(
		"enforces team invariants: strict Cordis bus inject, shared file cross-VM, lease expiry, update DAG/lease transitions, cancelled waiter handoff, monotonic IDs, and live inspector clock",
		function()
			-- 1. Strict Cordis-like plugin context verifying `bus` is declared in `inject`
			local inject_set = {}
			for _, dep in ipairs(team_plugin.inject or {}) do
				inject_set[dep] = true
			end
			expect.truthy(inject_set.bus)

			local strict_tools, strict_records, strict_emitted = {}, {}, {}
			local strict_ctx = setmetatable({
				tools = {
					register = function(_, name, def)
						strict_tools[name] = def
					end,
				},
				commands = { register = function() end },
				context = { section = function() end, invalidate = function() end },
				ui = { widget = function() end, invalidate = function() end },
				session = {
					info = function()
						return { session_id = "strict-sess", session_epoch = "g1", ephemeral = false, readonly = false }
					end,
					list_records = function()
						return { data = strict_records }
					end,
					add_record = function(_, _, data)
						strict_records[#strict_records + 1] = data
						return { durable = true }
					end,
				},
				bus = {
					emit = function(_, name, payload)
						strict_emitted[#strict_emitted + 1] = { name = name, payload = payload }
					end,
				},
				provide = function() end,
				on = function() end,
				spawn = function(_, fn)
					return mare.task.spawn(fn)
				end,
			}, {
				__index = function(_, key)
					if not inject_set[key] then
						error(("cannot get property %q without inject"):format(tostring(key)), 2)
					end
					return nil
				end,
			})
			team_plugin.apply(strict_ctx, { default_lease_ms = 2000, shared_file = false })
			local st1 = strict_tools.team_create.execute({ title = "Strict task" })
			expect.falsy(st1.is_error)
			expect.eq(#strict_records, 1)
			expect.eq(strict_emitted[#strict_emitted].name, "team/task-created")

			-- 2. Shared board across two VM stores via mare.lock.file + --no-session skip
			local orig_state_path = mare.paths.state
			local tmp_dir = orig_state_path .. "/team-spec-" .. mare.crypto.random_hex(4)
			mare.fs.mkdir(tmp_dir)
			mare.paths.state = tmp_dir
			local store_mod = require("team.store")
			local eph_store = store_mod.create(strict_ctx, { shared_file = true, default_lease_ms = 5000 }, {
				session = {
					info = function()
						return { session_id = "eph-1", session_epoch = "g1", ephemeral = true, readonly = false }
					end,
				},
			})
			eph_store.create({ title = "Ephemeral only" })
			expect.falsy(mare.fs.exists(tmp_dir .. "/team/eph-1.json"))

			local parent_store = store_mod.create(strict_ctx, { shared_file = true, default_lease_ms = 5000 }, {
				session = {
					info = function()
						return { session_id = "shared-sess", session_epoch = "g1", ephemeral = false, readonly = false }
					end,
					list_records = function()
						return { data = {} }
					end,
					add_record = function()
						return { durable = true }
					end,
				},
			})
			local p_task, p_err = parent_store.create({ title = "Parent task" })
			expect.falsy(p_err)
			expect.truthy(p_task)
			expect.truthy(mare.fs.exists(tmp_dir .. "/team/shared-sess.json"))

			local orig_mode = mare.mode
			mare.mode = "child"
			local child_store = store_mod.create(
				strict_ctx,
				{ shared_file = true, session_id = "shared-sess", default_lease_ms = 5000 },
				{
					session = {
						info = function()
							return { session_id = "child-vm", session_epoch = "g1", ephemeral = true, readonly = false }
						end,
					},
				}
			)
			child_store.restore()
			local child_list = child_store.list()
			expect.eq(#child_list.tasks, 1)
			expect.eq(child_list.tasks[1].title, "Parent task")
			local claimed_child = child_store.claim({ id = "T-1", owner = "worker-child" })
			expect.truthy(claimed_child)
			expect.eq(claimed_child.owner, "worker-child")
			mare.mode = orig_mode
			local parent_saw = parent_store.list()
			expect.eq(parent_saw.tasks[1].status, "in_progress")
			expect.eq(parent_saw.tasks[1].owner, "worker-child")
			mare.paths.state = orig_state_path

			-- 3. Active lease + expiry check even when args.owner omitted
			local t1 = tools.team_create.execute({ title = "Owned work" })
			local blk_dep = tools.team_create.execute({ title = "Dependent", blocked_by = { t1.details.id } })
			expect.truthy(tools.team_claim.execute({ id = t1.details.id, owner = "alice", lease_ms = 1000 }))
			local anon_comp = tools.team_complete.execute({ id = t1.details.id })
			expect.truthy(anon_comp.is_error)
			expect.eq(anon_comp.error_code, "team.stale_owner")

			-- Object-shaped blocked_by is rejected
			local bad_dep = tools.team_create.execute({ title = "Bad deps", blocked_by = { foo = "T-1" } })
			expect.truthy(bad_dep.is_error)
			expect.eq(bad_dep.error_code, "team.invalid_dependency")

			-- team_update enforces DAG & lease rules
			local jump_done = tools.team_update.execute({ id = blk_dep.details.id, status = "completed" })
			expect.truthy(jump_done.is_error)
			expect.eq(jump_done.error_code, "team.task_blocked")

			-- Advance clock past lease expiry -> even matching owner must reclaim
			fake_now = fake_now + 1500
			local exp_upd = tools.team_update.execute({ id = t1.details.id, owner = "alice", renew_lease = true })
			expect.truthy(exp_upd.is_error)
			expect.eq(exp_upd.error_code, "team.stale_lease")

			-- Live inspector preview checks current clock dynamically
			local view_inst = view_mod.build_inspector({
				list = function()
					return tools.team_list.execute({}).details
				end,
			})
			local prev_exp = mare.json.encode(view_inst.on_highlight(1, 1))
			expect.match(prev_exp, "expired")

			-- Reclaim and complete via team_update -> auto-unblocks blk_dep
			local recl = tools.team_claim.execute({ id = t1.details.id, owner = "alice" })
			expect.falsy(recl.is_error)
			local upd_done = tools.team_update.execute({ id = t1.details.id, owner = "alice", status = "completed" })
			expect.falsy(upd_done.is_error)
			local after_blk = tools.team_list.execute({ ready_only = true }).details
			local found_unblocked = false
			for _, tk in ipairs(after_blk.tasks) do
				if tk.id == blk_dep.details.id then
					found_unblocked = true
				end
			end
			expect.truthy(found_unblocked)

			-- 4. Subagent completion handles nil gaps (agent_id=nil, child_session_id set) and ignores stale session_epoch
			local t_rel = tools.team_create.execute({ title = "Child owned" })
			tools.team_claim.execute({ id = t_rel.details.id, owner = "cs-unique" })
			events["subagent/completed"]({
				child_session_id = "cs-unique",
				parent_session_id = "sess-team",
				parent_session_epoch = "old-epoch",
			})
			expect.eq(tools.team_list.execute({ owner = "cs-unique" }).details.counts.in_progress, 1)
			events["subagent/completed"]({
				child_session_id = "cs-unique",
				parent_session_id = "sess-team",
				parent_session_epoch = "epoch-1",
			})
			expect.eq(tools.team_list.execute({ owner = "cs-unique" }).details.counts.in_progress, 0)

			-- 5. Monotonic IDs across clear
			local seq_before = tonumber(t_rel.details.id:match("T%-(%d+)"))
			provided.clear()
			local after_clear = tools.team_create.execute({ title = "Fresh after clear" })
			local seq_after = tonumber(after_clear.details.id:match("T%-(%d+)"))
			expect.truthy(seq_after > seq_before)
			local stale_ref = tools.team_update.execute({ id = t1.details.id, note = "stale" })
			expect.truthy(stale_ref.is_error)
			expect.eq(stale_ref.error_code, "team.unknown_task")

			-- 6. Cancelled waiter in mutex queue does not strand later live waiter
			local hold_tok = mare.task.token()
			local w_res1, w_res2
			local slow_record = strict_ctx.session.add_record
			local slow_store = store_mod.create(strict_ctx, { shared_file = false }, {
				session = {
					info = function()
						return { session_id = "q-sess", session_epoch = "g1", ephemeral = false, readonly = false }
					end,
					list_records = function()
						return { data = {} }
					end,
					add_record = function(...)
						mare.task.sleep(60)
						return slow_record(...)
					end,
				},
			})
			local f_hold = mare.task.spawn(function()
				slow_store.create({ title = "Holder" })
			end)
			mare.task.sleep(10)
			local f_cancel = mare.task.spawn(function()
				w_res1 = slow_store.create({ title = "Cancelled waiter" }, hold_tok)
			end)
			local f_live = mare.task.spawn(function()
				w_res2 = slow_store.create({ title = "Live waiter" })
			end)
			mare.task.sleep(15)
			hold_tok:cancel()
			f_hold:wait()
			f_cancel:wait()
			f_live:wait()
			expect.eq(w_res1, nil)
			expect.truthy(w_res2 ~= nil and w_res2.title == "Live waiter")

			-- 7. Shared mirror seeding, ephemeral isolation, journal rollback, lock-free on_change, release ownership, terminal guard, and view cleared fallback
			local recheck_dir = orig_state_path .. "/team-recheck-" .. mare.crypto.random_hex(4)
			mare.fs.mkdir(recheck_dir)
			mare.paths.state = recheck_dir

			-- Restored parent whose shared mirror is absent seeds mirror so child creates T-2 (not T-1)
			local restored_parent = store_mod.create(strict_ctx, { shared_file = true, default_lease_ms = 5000 }, {
				session = {
					info = function()
						return { session_id = "res-sess", session_epoch = "g1", ephemeral = false, readonly = false }
					end,
					list_records = function()
						return {
							data = {
								{
									version = 1,
									seq = 1,
									op = "create",
									timestamp = 1000,
									task = {
										id = "T-1",
										seq = 1,
										title = "Restored task",
										status = "pending",
										priority = "medium",
										blocked_by = {},
										revision = 1,
										notes = {},
										created_at_ms = 1000,
										updated_at_ms = 1000,
									},
								},
							},
						}
					end,
					add_record = function()
						return { durable = true }
					end,
				},
			})
			restored_parent.restore()
			expect.truthy(mare.fs.exists(recheck_dir .. "/team/res-sess.json"))

			local orig_mode2 = mare.mode
			mare.mode = "child"
			local res_child = store_mod.create(strict_ctx, { shared_file = true, session_id = "res-sess" }, {
				session = {
					info = function()
						return { session_id = "c-vm", session_epoch = "g1", ephemeral = true, readonly = false }
					end,
				},
			})
			local ct2 = res_child.create({ title = "Child second" })
			expect.truthy(ct2)
			expect.eq(ct2.id, "T-2")

			-- --no-session ephemeral child with NO session_id never reads/mutates saved session board
			local eph_child = store_mod.create(strict_ctx, { shared_file = true }, {
				session = {
					info = function()
						return { session_id = "eph-c", session_epoch = "g1", ephemeral = true, readonly = false }
					end,
				},
			})
			expect.eq(#eph_child.list().tasks, 0)

			-- Non-workflow child discovers parent session via ctx.session:get without cfg.session_id, mare.args, or direct JSONL reads
			local child_transcript = recheck_dir .. "/child-transcript.jsonl"
			-- Ephemeral child with path must still stay isolated
			local orig_args = mare.args
			mare.args = {
				no_session = false,
				recorded_session_path = child_transcript,
			}
			local eph_with_path = store_mod.create(strict_ctx, { shared_file = true }, {
				session = {
					info = function()
						return {
							session_id = "eph-c-path",
							session_epoch = "g1",
							path = child_transcript,
							ephemeral = true,
							readonly = false,
						}
					end,
					get = function()
						error("ephemeral child must not query parent session metadata")
					end,
				},
			})
			eph_with_path.restore()
			expect.eq(#eph_with_path.list().tasks, 0)

			-- Recorded child resolves parent via ctx.session:get(info.session_id) without reading transcript files directly
			mare.args = {}
			local get_calls = 0
			local subagent_child = store_mod.create(strict_ctx, { shared_file = true }, {
				session = {
					info = function()
						return {
							session_id = "c-subagent",
							session_epoch = "g1",
							path = child_transcript,
							readonly = false,
						}
					end,
					get = function(_, selector)
						get_calls = get_calls + 1
						expect.eq(selector, "c-subagent")
						return { session_id = "c-subagent", parent_session_id = "res-sess" }
					end,
				},
			})
			subagent_child.restore()
			local sub_tasks = subagent_child.list().tasks
			expect.eq(#sub_tasks, 2)
			expect.eq(get_calls, 1)
			local ct3 = subagent_child.create({ title = "Child third via session:get" })
			expect.truthy(ct3)
			expect.eq(ct3.id, "T-3")
			expect.eq(get_calls, 1)
			mare.args = orig_args

			mare.mode = orig_mode2
			expect.eq(#restored_parent.list().tasks, 3)

			-- Journal failure after mirror write rolls back mirror cleanly
			local fail_next = true
			local rb_store = store_mod.create(strict_ctx, { shared_file = true }, {
				session = {
					info = function()
						return { session_id = "rb-sess", session_epoch = "g1", ephemeral = false, readonly = false }
					end,
					list_records = function()
						return { data = {} }
					end,
					add_record = function()
						if fail_next then
							error("disk full", 0)
						end
						return { durable = true }
					end,
				},
			})
			local rb1, _, rb_code = rb_store.create({ title = "Should rollback" })
			expect.eq(rb1, nil)
			expect.eq(rb_code, "persist_failed")
			expect.eq(#rb_store.list().tasks, 0)
			fail_next = false
			local rb2 = rb_store.create({ title = "Retry succeeds as T-1" })
			expect.truthy(rb2)
			expect.eq(rb2.id, "T-1")

			-- on_change runs outside lock and can call store.list() safely
			local change_saw = nil
			local oc_store
			oc_store = store_mod.create(strict_ctx, { shared_file = true }, {
				session = {
					info = function()
						return { session_id = "oc-sess", session_epoch = "g1", ephemeral = false, readonly = false }
					end,
					list_records = function()
						return { data = {} }
					end,
					add_record = function()
						return { durable = true }
					end,
				},
			}, function()
				change_saw = #oc_store.list().tasks
			end)
			oc_store.create({ title = "Hook outside lock" })
			expect.eq(change_saw, 1)

			-- Child named "main" never releases main's task; subagent_id releases child's task
			local t_main = tools.team_create.execute({ title = "Main task" })
			local t_child = tools.team_create.execute({ title = "Sub task" })
			tools.team_claim.execute({ id = t_main.details.id, owner = "main" })
			tools.team_claim.execute({ id = t_child.details.id, owner = "sub-canon-1" })
			events["subagent/completed"]({
				subagent_id = "sub-canon-1",
				name = "main",
				parent_session_id = "sess-team",
				parent_session_epoch = "epoch-1",
			})
			local after_rel = tools.team_list.execute({}).details.tasks
			local by_id = {}
			for _, tk in ipairs(after_rel) do
				by_id[tk.id] = tk
			end
			expect.eq(by_id[t_main.details.id].status, "in_progress")
			expect.eq(by_id[t_main.details.id].owner, "main")
			expect.eq(by_id[t_child.details.id].status, "pending")
			expect.eq(by_id[t_child.details.id].owner, nil)

			-- team_update blocks transition out of cancelled/completed without force
			local t_can = tools.team_create.execute({ title = "Terminal guard" })
			tools.team_update.execute({ id = t_can.details.id, status = "cancelled" })
			local reopen_err = tools.team_update.execute({ id = t_can.details.id, status = "in_progress" })
			expect.truthy(reopen_err.is_error)
			expect.eq(reopen_err.error_code, "team.invalid_state")
			local reopen_forced = tools.team_update.execute({
				id = t_can.details.id,
				status = "in_progress",
				owner = "alice",
				force = true,
			})
			expect.falsy(reopen_forced.is_error)

			-- Clear fallback check in team/view.lua
			local view_tasks = {
				{
					id = "T-LIVE",
					title = "Vanishing",
					status = "pending",
					priority = "medium",
					blocked_by = {},
					unresolved_blockers = {},
					ready = true,
					blocked = false,
					revision = 1,
					notes = {},
				},
			}
			local stale_view = view_mod.build_inspector({
				list = function()
					return {
						tasks = view_tasks,
						counts = {
							total = #view_tasks,
							pending = #view_tasks,
							in_progress = 0,
							ready = #view_tasks,
							blocked = 0,
							completed = 0,
							cancelled = 0,
						},
					}
				end,
			})
			view_tasks = {}
			local missing_prev = mare.json.encode(stale_view.on_highlight(1, 1))
			expect.match(missing_prev, "no longer on the board")

			mare.paths.state = orig_state_path
		end
	)

	it(
		"fails closed on corrupt/mismatched disk, bounds ops on clear, enforces 0600, honors readonly restore, and fixes team contracts",
		function()
			local support_mod = assert(load(mare.fs.read("tests/specs/support.lua"), "@tests/specs/support.lua"))()
			support_mod.preload_modules("team", { "team.store" })
			local store_mod = require("team.store")
			local plugin = dofile("plugins/team/init.lua")
			expect.eq(plugin.contracts.team.methods.create.result ~= plugin.contracts.team.methods.list.result, true)
			expect.eq(plugin.contracts.team.methods.complete.result ~= plugin.contracts.team.methods.clear.result, true)
			expect.eq(plugin.contracts.team.methods.create.lua.options, "{ cancel?: mare.Token }?")

			local files = {}
			local modes = {}
			local sess = { session_id = "sess-safe", ephemeral = false, readonly = false }
			local mem_ctx = {
				session = {
					info = function()
						return sess
					end,
					add_record = function()
						return { durable = true }
					end,
					entries = function()
						return {}
					end,
				},
				fs = {
					stat = function(_, p)
						return files[p] and { size = #files[p] } or nil, files[p] and nil or "not_found"
					end,
					read = function(_, p)
						if not files[p] then
							return nil, "not_found"
						end
						return files[p]
					end,
					write = function(_, p, data, opts)
						files[p] = data
						modes[p] = opts and opts.mode or nil
						return true
					end,
					mkdir_p = function()
						return true
					end,
				},
				on = function() end,
				effect = function() end,
				emit = function() end,
				log = function() end,
				spawn = function(_, fn)
					mare.task.spawn(fn)
				end,
				agent = { notify = function() end },
				tools = { register = function() end },
				ui = { register_widget = function() end },
				provide = function() end,
				after = function()
					return { cancel = function() end }
				end,
			}

			local orig_state_path = mare.paths.state
			local orig_read, orig_write, orig_mkdir, orig_exists =
				mare.fs.read, mare.fs.write, mare.fs.mkdir, mare.fs.exists
			local write_count = 0
			local _restore_fs <close> = setmetatable({}, {
				__close = function()
					mare.fs.read = orig_read
					mare.fs.write = orig_write
					mare.fs.mkdir = orig_mkdir
					mare.fs.exists = orig_exists
					mare.paths.state = orig_state_path
				end,
			})
			local tmp_team_dir = orig_state_path .. "/team-p1-safety-" .. mare.crypto.random_hex(4)
			orig_mkdir(tmp_team_dir)
			mare.paths.state = tmp_team_dir
			mare.fs.mkdir = function(d)
				return orig_mkdir(d)
			end
			mare.fs.exists = function(p)
				return files[p] ~= nil
			end
			mare.fs.read = function(p)
				if not files[p] then
					return nil, "not_found", "not_found"
				end
				return files[p]
			end
			mare.fs.write = function(p, data, opts)
				write_count = write_count + 1
				files[p] = data
				modes[p] = opts and opts.mode or nil
				return true
			end
			local s = store_mod.create(
				mem_ctx,
				{ max_tasks = 50, default_lease_ms = 60000 },
				{ session = mem_ctx.session }
			)
			local ok_t, err_t = s.create({ title = "Write 0600" })
			expect.truthy(ok_t)
			expect.eq(err_t, nil)
			local path = tmp_team_dir .. "/team/sess-safe.json"
			expect.eq(modes[path], 384)

			-- Clear bounds ops to <= 256 (exact 1 clear marker) and keeps monotonic IDs across clear
			for i = 1, 30 do
				s.create({ title = "Task " .. i })
			end
			local clr, clr_err = s.clear()
			expect.truthy(clr)
			expect.eq(clr_err, nil)
			local persisted = mare.json.decode(files[path])
			expect.eq(#persisted.ops, 1)
			expect.eq(persisted.ops[1].op, "clear")

			-- Corrupt JSON on disk fails closed and does NOT overwrite file
			local saved_corrupt = "{broken json"
			files[path] = saved_corrupt
			local r_corrupt, _, code_corrupt = s.create({ title = "Should fail closed" })
			expect.eq(r_corrupt, nil)
			expect.eq(code_corrupt, "persist_failed")
			expect.eq(files[path], saved_corrupt)

			-- Session mismatch on disk fails closed and does NOT overwrite file
			files[path] =
				mare.json.encode({ version = 1, session_id = "other-sess", next_id = 5, tasks = {}, ops = {} })
			local wrong_snap = files[path]
			local r_mis, _, code_mis = s.create({ title = "Mismatch" })
			expect.eq(r_mis, nil)
			expect.eq(code_mis, "persist_failed")
			expect.eq(files[path], wrong_snap)

			-- Readonly restore reads persisted disk state without mutating disk or acquiring write lock
			files[path] = persisted and mare.json.encode(persisted) or ""
			local before_ro_writes = write_count
			sess.readonly = true
			local rr_ok, rr_err = s.restore()
			expect.truthy(rr_ok)
			expect.eq(rr_err, nil)
			expect.eq(write_count, before_ro_writes)
			sess.readonly = false

			-- Contract cancel token forwards from services.team.create(..., { cancel = tok })
			local provided = nil
			local c_ctx = support_mod.adapt_mock({
				session = mem_ctx.session,
				fs = mem_ctx.fs,
				ui = mem_ctx.ui,
				agent = mem_ctx.agent,
				tools = mem_ctx.tools,
				on = function() end,
				get = function(_, name)
					return name == "session" and mem_ctx.session or nil
				end,
			}, true)
			c_ctx.spawn = function(_, fn)
				mare.task.spawn(fn)
			end
			c_ctx.after = function()
				return { cancel = function() end }
			end
			c_ctx.effect = function() end
			c_ctx.inject = function(_, _, fn)
				if type(fn) == "function" then
					fn({
						context = { section = function() end },
						ui = { widget = function() end },
						commands = { register = function() end },
					})
				end
			end
			c_ctx.provide = function(_, name, svc)
				if name == "team" then
					provided = svc
				end
			end
			plugin.apply(c_ctx, {})
			local tok = mare.task.token()
			tok:cancel()
			expect.error(function()
				provided:create(nil, { title = "Cancelled" }, { cancel = tok })
			end)

			mare.fs.read = orig_read
			mare.fs.write = orig_write
			mare.fs.mkdir = orig_mkdir
			mare.paths.state = orig_state_path
		end
	)

	it("uses cached_snapshot in view.context_text and applies updated_at_ms without rec.timestamp", function()
		local list_called = false
		local cached_opts = nil
		local fake_store = {
			list = function()
				list_called = true
				return { tasks = {} }
			end,
			cached_snapshot = function(opts)
				cached_opts = opts
				return {
					tasks = {
						{
							id = "T-1",
							title = "Cached item",
							status = "pending",
							ready = true,
							unresolved_blockers = {},
							revision = 1,
						},
					},
				}
			end,
		}
		local out = view_mod.context_text(fake_store)
		expect.eq(list_called, false)
		expect.eq(cached_opts.include_completed, false)
		expect.truthy(out:find("Cached item", 1, true))

		local board = board_mod.new_board()
		local create_rec =
			assert(board_mod.create(board, { title = "Track timestamps" }, 100, { default_lease_ms = 5000 }))
		local claim_rec =
			assert(board_mod.claim(board, { id = create_rec.task.id, owner = "a1" }, 200, { default_lease_ms = 5000 }))
		local rel_rec = assert(board_mod.release_owner(board, "a1", 300))
		local comp_rec = assert(board_mod.complete(board, { id = create_rec.task.id }, 400))
		expect.eq(claim_rec.updated_at_ms, 200)
		expect.eq(rel_rec.updated_at_ms, 300)
		expect.eq(comp_rec.updated_at_ms, 400)

		local replayed = assert(board_mod.replay({
			create_rec,
			{
				version = 1,
				seq = 2,
				op = "claim",
				id = create_rec.task.id,
				owner = "a1",
				lease_expires_at_ms = 5200,
				revision = 2,
				updated_at_ms = 250,
			},
			{
				version = 1,
				seq = 3,
				op = "release_batch",
				releases = { { id = create_rec.task.id, revision = 3, notes = {} } },
				updated_at_ms = 350,
			},
			{
				version = 1,
				seq = 4,
				op = "complete",
				id = create_rec.task.id,
				completed_at_ms = 450,
				updated_at_ms = 450,
				revision = 4,
				notes = {},
			},
		}))
		expect.eq(replayed.tasks[create_rec.task.id].updated_at_ms, 450)
		expect.eq(replayed.tasks[create_rec.task.id].completed_at_ms, 450)
	end)
end)
