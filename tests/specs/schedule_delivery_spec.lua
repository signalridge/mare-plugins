local schedule_support =
	assert(load(mare.fs.read("tests/specs/schedule_support.lua"), "@tests/specs/schedule_support.lua"))()

local describe = mare.test.describe
local it = mare.test.it
local before_each = mare.test.before_each
local after_each = mare.test.after_each
local expect = mare.test.expect

describe("schedule durable delivery", function()
	local env, domain, drive, delivery_helpers

	before_each(function()
		env = schedule_support.fixture()
		domain = env.domain
		drive = env.drive
		delivery_helpers = env.delivery
	end)

	after_each(function()
		env.restore()
	end)

	it("does not wedge on rejected reservation and requires recovery on unknown ACK", function()
		local p_task = assert(domain.create(nil, nil, {
			title = "Recovery task",
			prompt = "Check recovery",
			timing = { kind = "every", every_seconds = 60 },
			target = { kind = "session", session_id = "sess-1" },
		}))

		env.enqueue_behavior = function()
			return { status = "rejected", durable = false, error = "temporary reject" }
		end
		env.now = env.now + 60000
		local rej_res, rej_err = domain.run(nil, nil, { id = p_task.record.id })
		expect.falsy(rej_res)
		expect.eq(rej_err.code, "delivery_rejected")

		local rej_view = assert(domain.view(nil, nil, { id = p_task.record.id }))
		expect.eq(rej_view.reservation.phase, "rejected")
		expect.eq(rej_view.recovery_required, false)

		env.enqueue_behavior = nil
		local retry_res = assert(domain.run(nil, nil, { id = p_task.record.id }))
		expect.eq(retry_res.admitted, true)

		env.enqueue_behavior = function()
			error("lost transport ack")
		end
		env.now = env.now + 60000
		local unk_res, unk_err = domain.run(nil, nil, { id = p_task.record.id })
		expect.falsy(unk_res)
		expect.eq(unk_err.code, "delivery_unknown")

		local unk_view = assert(domain.view(nil, nil, { id = p_task.record.id }))
		expect.eq(unk_view.reservation.phase, "unknown")
		expect.eq(unk_view.recovery_required, true)

		env.enqueue_behavior = nil
		local blocked_res, blocked_err = domain.run(nil, nil, { id = p_task.record.id })
		expect.falsy(blocked_res)
		expect.eq(blocked_err.code, "recovery_required")

		-- Skipped while unstable or persist_error is set; clears as absent when durable logs confirm absent.
		env.session.unstable = true
		drive()
		expect.eq(domain.view(nil, nil, { id = p_task.record.id }).reservation.phase, "unknown")

		env.session.unstable = false
		env.persist_err = "disk write failed"
		drive()
		expect.eq(domain.view(nil, nil, { id = p_task.record.id }).reservation.phase, "unknown")

		env.persist_err = nil
		drive()
		local cleared_view = assert(domain.view(nil, nil, { id = p_task.record.id }))
		expect.eq(cleared_view.reservation, nil)
		expect.eq(cleared_view.recovery_required, false)
	end)

	it("reconciles unknown ACK committed in agent:list_queue() without double enqueue", function()
		local rec_q = assert(domain.create(nil, nil, {
			title = "Reconcile queued",
			prompt = "Check queue",
			timing = { kind = "every", every_seconds = 60 },
			target = { kind = "session", session_id = "sess-1" },
		}))
		local before_count = #env.enqueued_payloads
		env.enqueue_behavior = function(opts)
			env.sequence = env.sequence + 1
			local id = "in-unk-q-" .. env.sequence
			env.queued[#env.queued + 1] =
				{ input_id = id, lane = "follow_up", input_context = env.clone(opts.input_context) }
			error("lost ack after queue write")
		end
		local _, uq_err = domain.run(nil, nil, { id = rec_q.record.id })
		expect.truthy(uq_err)
		expect.eq(uq_err.code, "delivery_unknown")

		env.enqueue_behavior = nil
		drive()
		local rec_q_view = assert(domain.view(nil, nil, { id = rec_q.record.id }))
		expect.eq(rec_q_view.reservation, nil)
		expect.eq(#rec_q_view.delivery_history.records, 1)
		expect.truthy(rec_q_view.last_delivery.message_id:find("in-unk-q-", 1, true))
		expect.eq(#env.enqueued_payloads, before_count)
	end)

	it("reconciles unknown ACK committed in agent:messages() without double enqueue", function()
		local rec_m = assert(domain.create(nil, nil, {
			title = "Reconcile messages",
			prompt = "Check messages",
			timing = { kind = "every", every_seconds = 60 },
			target = { kind = "session", session_id = "sess-1" },
		}))
		local before_count = #env.enqueued_payloads
		env.enqueue_behavior = function(opts)
			env.sequence = env.sequence + 1
			env.messages[#env.messages + 1] = {
				role = "user",
				input_id = "in-unk-m-" .. env.sequence,
				input_context = env.clone(opts.input_context),
			}
			error("lost ack after transcript commit")
		end
		local _, um_err = domain.run(nil, nil, { id = rec_m.record.id })
		expect.truthy(um_err)
		expect.eq(um_err.code, "delivery_unknown")

		env.enqueue_behavior = nil
		drive()
		local rec_m_view = assert(domain.view(nil, nil, { id = rec_m.record.id }))
		expect.eq(rec_m_view.reservation, nil)
		expect.eq(#rec_m_view.delivery_history.records, 1)
		expect.truthy(rec_m_view.last_delivery.message_id:find("in-unk-m-", 1, true))
		expect.eq(#env.enqueued_payloads, before_count)
	end)

	it("batches same-target recurring tasks while keeping one-shot tasks solo", function()
		local batch_a = assert(domain.create(nil, nil, {
			title = "Batch A",
			prompt = "Run A",
			timing = { kind = "every", every_seconds = 60 },
			target = { kind = "session", session_id = "sess-1" },
		}))
		local batch_b = assert(domain.create(nil, nil, {
			title = "Batch B",
			prompt = "Run B",
			timing = { kind = "every", every_seconds = 60 },
			target = { kind = "session", session_id = "sess-1" },
		}))
		local solo_c = assert(domain.create(nil, nil, {
			title = "Solo Once",
			prompt = "Run C",
			timing = { kind = "after", after_seconds = 60 },
			target = { kind = "session", session_id = "sess-1" },
		}))

		env.now = env.now + 60000
		env.queued = {}
		local batch_res = assert(drive())
		expect.eq(batch_res.batched, true)
		expect.eq(#batch_res.ids, 2)

		local last_payload = env.enqueued_payloads[#env.enqueued_payloads]
		expect.truthy(last_payload.text:find("[SCHEDULE REMINDER BATCH]", 1, true))
		expect.truthy(last_payload.text:find("reminders_json", 1, true))
		expect.eq(last_payload.input_context.schedule.batched, true)

		local va = assert(domain.view(nil, nil, { id = batch_a.record.id }))
		local vb = assert(domain.view(nil, nil, { id = batch_b.record.id }))
		local vc = assert(domain.view(nil, nil, { id = solo_c.record.id }))
		expect.eq(va.last_delivery.message_id, vb.last_delivery.message_id)
		expect.eq(vc.last_delivery, nil)

		env.queued = {}
		local solo_res = assert(drive())
		expect.falsy(solo_res.batched)
		expect.eq(solo_res.id, solo_c.record.id)
		expect.truthy(env.enqueued_payloads[#env.enqueued_payloads].text:find("[SCHEDULE REMINDER]", 1, true))
		expect.falsy(env.enqueued_payloads[#env.enqueued_payloads].text:find("[SCHEDULE REMINDER BATCH]", 1, true))
	end)

	it("coalesces missed runs with summary, input_context, and ui.notify", function()
		assert(domain.create(nil, nil, {
			title = "Missed check",
			prompt = "Catch up",
			timing = { kind = "every", every_seconds = 60 },
			target = { kind = "session", session_id = "sess-1" },
		}))
		env.now = env.now + 5 * 60000
		env.queued = {}
		env.ui_notices = {}
		local missed_res = assert(drive())
		expect.truthy(missed_res.coalesced_count >= 4)
		expect.eq(type(missed_res.missed_summary), "string")
		expect.truthy(env.enqueued_payloads[#env.enqueued_payloads].text:find("[Missed runs coalesced:", 1, true))
		expect.truthy(env.enqueued_payloads[#env.enqueued_payloads].input_context.schedule.coalesced_missed_count >= 4)
		expect.truthy(#env.ui_notices >= 1)
		expect.truthy(env.ui_notices[#env.ui_notices].msg:find("coalesced", 1, true))
		delivery_helpers.clear_cooldown()
	end)

	it("enforces Plan-mode fences on agent/input-ready and agent/step-ready", function()
		local step_task = assert(domain.create(nil, nil, {
			title = "Step fence task",
			prompt = "Step prompt",
			timing = { kind = "after", after_seconds = 60 },
			target = { kind = "session", session_id = "sess-1" },
		}))
		env.now = env.now + 60000
		env.queued = {}
		local driven = assert(drive())
		local tracked_msg_id = driven.receipt.message_id
		local owned_turn_id = "turn-d-" .. env.sequence

		env.plan_active = true
		local deny_owned = env.listeners["agent/input-ready"]({
			input_id = tracked_msg_id,
			source = "schedule",
			turn_id = "turn-plan-1",
			input_context = { schedule = { reservation_id = "res-1" } },
		})
		expect.truthy(deny_owned)
		expect.eq(deny_owned.decision, "deny")

		local deny_pending_ctx = env.listeners["agent/input-ready"]({
			input_id = "untracked-input-id",
			source = "schedule",
			input_context = { schedule = { batched = true, reservation_ids = { "res-2" } } },
		})
		expect.truthy(deny_pending_ctx)
		expect.eq(deny_pending_ctx.decision, "deny")

		expect.eq(env.listeners["agent/input-ready"]({ input_id = "human-input-1", source = "user" }), nil)
		expect.eq(
			env.listeners["agent/input-ready"]({
				input_id = "human-input-2",
				source = "user",
				input_context = { schedule = false },
			}),
			nil
		)
		expect.eq(
			env.listeners["agent/input-ready"]({
				input_id = "human-input-3",
				source = "user",
				input_context = { schedule = { reservation_id = "res-1" } },
			}),
			nil
		)

		local orig_resume_input = env.ctx.agent.resume_input
		local seen_resume_opts = {}
		env.ctx.agent.resume_input = function(self, owner, opts)
			seen_resume_opts[#seen_resume_opts + 1] = opts
			return orig_resume_input(self, owner, opts)
		end
		env.plan_active = false
		env.queued = {
			{ input_id = tracked_msg_id, lane = "follow_up", text = "Step prompt" },
			{ input_id = "unrelated-user-input", lane = "follow_up", text = "User prompt" },
		}
		drive()
		expect.eq(#seen_resume_opts, 1)
		expect.eq(seen_resume_opts[1] and seen_resume_opts[1].input_id, tracked_msg_id)
		env.queued = {}
		env.ctx.agent.resume_input = orig_resume_input

		env.plan_active = false
		expect.eq(
			env.listeners["agent/input-ready"]({
				input_id = tracked_msg_id,
				source = "schedule",
				input_context = { schedule = { reservation_id = "res-1" } },
			}),
			nil
		)

		env.plan_active = true
		local step_deny = env.listeners["agent/step-ready"]({ turn_id = owned_turn_id })
		expect.truthy(step_deny)
		expect.eq(step_deny.decision, "deny")
		expect.eq(env.listeners["agent/step-ready"]({ turn_id = "human-turn" }), nil)

		env.listeners["turn/completed"]({ turn_id = owned_turn_id })
		expect.eq(env.listeners["agent/step-ready"]({ turn_id = owned_turn_id }), nil)
		env.plan_active = false
		expect.truthy(step_task.record.id)
	end)

	it("skips snapshot_index when revision is unchanged or inside_mutate is true", function()
		local store = require("schedule.store")(env.ctx, { new_session_interval_seconds = 60 })
		local t1 = assert(domain.create(nil, nil, {
			title = "Index check",
			prompt = "Ping",
			timing = { kind = "every", every_seconds = 60 },
			target = { kind = "session", session_id = "sess-1" },
		}))
		expect.truthy(t1.record.id)

		-- Prime last_seen_revision via store.read
		local _, rev0 = assert(store.read(nil, false))

		local orig_encode_strict = mare.json.encode_strict
		local encode_calls = 0
		mare.json.encode_strict = function(...)
			encode_calls = encode_calls + 1
			return orig_encode_strict(...)
		end

		-- Unchanged revision read: 0 snapshot_index encodes.
		local _, rev1 = assert(store.read(nil, false))
		expect.eq(rev1, rev0)
		expect.eq(encode_calls, 0)

		-- inside_mutate=true even if snapshot was updated externally: 0 snapshot_index encodes.
		local snap = assert(mare.state.snapshot({ namespace = "schedule.tasks" }))
		local mutated_val = env.clone(snap.snapshot.value)
		mutated_val.tasks[1].record.title = "External title"
		assert(mare.state.compare_exchange({
			namespace = "schedule.tasks",
			expected_revision = rev0,
			value = mutated_val,
		}).status == "ok")

		local _, rev2 = assert(store.read(nil, true))
		expect.truthy(rev2 > rev0)
		expect.eq(encode_calls, 0)

		-- External read (inside_mutate=false) with changed revision DOES index and emit diff.
		local _, rev3 = assert(store.read(nil, false))
		expect.eq(rev3, rev2)
		expect.truthy(encode_calls > 0)

		mare.json.encode_strict = orig_encode_strict
	end)

	it(
		"rejects false JSON as storage_corrupt, treats snapshot failure as unavailable, preserves next_ms on rollback, defers on plan_mode active/pending, and tracks scheduled turns",
		function()
			local s = assert(load(mare.fs.read("tests/specs/support.lua"), "@tests/specs/support.lua"))()
			s.preload_modules("schedule", {
				"schedule.value",
				"schedule.codec",
				"schedule.store",
				"schedule.timing",
				"schedule.engine",
				"schedule.domain",
				"schedule.delivery",
			})
			local store_mod = require("schedule.store")
			local domain_mod = require("schedule.domain")
			local delivery_mod = require("schedule.delivery")
			local sched_plugin = dofile("plugins/schedule/init.lua")
			local default_cfg = s.default_config(sched_plugin)

			local orig_state = mare.state
			local orig_now = mare.task.now
			local _restore_sched <close> = setmetatable({}, {
				__close = function()
					mare.state = orig_state
					mare.task.now = orig_now
				end,
			})
			local snap_mode = "false_json"
			local cur_now = 60000
			mare.task.now = function()
				return cur_now
			end
			local cas_doc, cas_rev = nil, 0
			mare.state = {
				snapshot = function()
					if snap_mode == "false_json" then
						return { status = "ok", snapshot = { exists = true, revision = 1, value = false } }
					elseif snap_mode == "transient" then
						return { status = "error", error = { code = "unavailable", message = "transient io" } }
					end
					if cas_doc == nil then
						return { status = "ok", snapshot = { exists = false, revision = 0 } }
					end
					return { status = "ok", snapshot = { exists = true, revision = cas_rev, value = cas_doc } }
				end,
				compare_exchange = function(req)
					if (req.expected_revision or 0) ~= cas_rev then
						return { status = "conflict" }
					end
					cas_rev = cas_rev + 1
					cas_doc = req.value
					return { status = "ok", snapshot = { revision = cas_rev } }
				end,
			}
			local d_teardowns = {}
			local d_listeners, d_voters = {}, {}
			local pm_state = { active = true, pending = false }
			local mem_ctx = {
				bus = {
					emit = function()
						return true
					end,
				},
				session = {
					info = function()
						return { session_id = "s1", session_epoch = "g1", ephemeral = false, readonly = false }
					end,
					switching = function()
						return false
					end,
					entries = function()
						return {}
					end,
				},
				agent = {
					notify = function()
						return true
					end,
					get = function()
						return { busy = false }
					end,
					list_queue = function()
						return { data = {} }
					end,
					enqueue = function()
						return { input_id = "in-queued", turn_id = "turn-q-1" }
					end,
					resume_input = function()
						return { status = "started" }
					end,
				},
				policy = {
					voter = function(_, ev, fn)
						d_voters[ev] = fn
					end,
				},
				on = function(_, ev, fn)
					d_listeners[ev] = d_listeners[ev] or {}
					d_listeners[ev][#d_listeners[ev] + 1] = fn
				end,
				effect = function(_, setup)
					local fn = setup()
					if type(fn) == "function" then
						d_teardowns[#d_teardowns + 1] = fn
					end
				end,
				spawn = function(_, fn)
					return mare.task.spawn(fn)
				end,
				after = function()
					return { abort = function() end }
				end,
			}
			local bad_store = store_mod(mem_ctx, default_cfg)
			local _, err_corrupt = bad_store.read(nil, true)
			expect.eq(err_corrupt.code, "storage_corrupt")
			snap_mode = "transient"
			local _, err_unavail = bad_store.read(nil, true)
			expect.eq(err_unavail.code, "storage_unavailable")

			-- Clock rollback preserves Timing.resolve next_ms on acknowledge_batch
			snap_mode = "memory"
			local domain_svc, eng = domain_mod(mem_ctx, default_cfg)
			local created, c_err = domain_svc.create(nil, nil, {
				title = "Clock rollback",
				prompt = "tick",
				timing = { kind = "every", every_seconds = 60 },
				target = { kind = "session", session_id = "s1" },
			})
			expect.eq(c_err, nil)
			-- Advance past initial next_at = 120000 so Timing.resolve computes next_ms = 180000
			cur_now = 120000
			local reserved, r_err = eng.reserve_due_group("inst-1")
			expect.eq(r_err, nil)
			expect.eq(#reserved, 1)
			local pair = { { id = reserved[1].record.id, reservation = reserved[1].reservation.id } }
			local sub_ok, sub_err = eng.submitting_batch(pair)
			expect.eq(sub_err, nil)
			expect.truthy(sub_ok)
			-- Clock rolls backward before delivery acknowledgement
			cur_now = 110000
			local ack_ok, ack_err =
				eng.acknowledge_batch(pair, { status = "queued", durable = true, input_id = "in-1", session_id = "s1" })
			expect.eq(ack_err, nil)
			expect.truthy(ack_ok)
			local viewed, v_err = domain_svc.view(nil, nil, { id = created.record.id })
			expect.eq(v_err, nil)
			expect.eq(viewed.record.scheduled_at, "1970-01-01T00:03:00.000Z")

			-- delivery.lua plan_mode active/pending + owned turn tracking on agent/input-ready & turn/started
			local _cleanup_del <close> = setmetatable({}, {
				__close = function()
					for _, fn in ipairs(d_teardowns) do
						pcall(fn)
					end
				end,
			})
			local del = delivery_mod(mem_ctx, domain_svc, eng, function()
				return {
					state = function()
						return pm_state
					end,
				}
			end)
			expect.truthy(del)
			-- Deferred when plan_mode active or pending
			local deny_vote = d_voters["agent/input-ready"]({
				input_id = "in-1",
				turn_id = "turn-s1",
				source = "schedule",
				input_context = { schedule = { task_id = created.record.id, reservation_id = "res-1" } },
			})
			expect.eq(deny_vote.decision, "deny")
			-- When plan_mode becomes inactive/not pending, agent/input-ready tracks turn_id for agent/step-ready
			pm_state = { active = false, pending = false }
			local allow_vote = d_voters["agent/input-ready"]({
				input_id = "in-1",
				turn_id = "turn-s1",
				source = "schedule",
				input_context = { schedule = { task_id = created.record.id, reservation_id = "res-1" } },
			})
			expect.eq(allow_vote, nil)
			expect.eq(d_voters["agent/step-ready"]({ turn_id = "turn-s1" }), nil)
			-- If plan_mode flips pending=true mid-turn, tracked turn_id is denied on agent/step-ready
			pm_state = { active = false, pending = true }
			expect.eq(d_voters["agent/step-ready"]({ turn_id = "turn-s1" }).decision, "deny")

			mare.state = orig_state
			mare.task.now = orig_now
		end
	)
end)
