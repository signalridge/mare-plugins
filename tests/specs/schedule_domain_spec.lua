local schedule_support =
	assert(load(mare.fs.read("tests/specs/schedule_support.lua"), "@tests/specs/schedule_support.lua"))()

local describe = mare.test.describe
local it = mare.test.it
local before_each = mare.test.before_each
local after_each = mare.test.after_each
local expect = mare.test.expect

describe("schedule durable domain", function()
	local env, domain, engine, drive

	before_each(function()
		env = schedule_support.fixture()
		domain = env.domain
		engine = env.engine
		drive = env.drive
	end)

	after_each(function()
		env.restore()
	end)

	it("validates delivery limits and rejects unavailable target runtime", function()
		local limits = domain.delivery_limits()
		expect.eq(limits.minimum_seconds, 60)
		expect.eq(limits.delivery_available, true)
		expect.eq(limits.background_targets_available, false)

		local bad_target, terr = domain.create(nil, nil, {
			title = "bg",
			prompt = "p",
			timing = { kind = "after", after_seconds = 60 },
			target = { kind = "new" },
		})
		expect.falsy(bad_target)
		expect.eq(terr.code, "target_runtime_unavailable")

		for _, tool_name in ipairs({ "schedule_create", "schedule_edit" }) do
			local target_prop = env.tools[tool_name].parameters.properties.target
			expect.eq(#target_prop.enum, 1)
			expect.eq(target_prop.enum[1], "current")
		end
	end)

	it("prunes delivery_history oldest-first by count and age", function()
		local rec_task = assert(domain.create(nil, nil, {
			title = "Prune test",
			prompt = "Check history",
			timing = { kind = "every", every_seconds = 60 },
			target = { kind = "session", session_id = "sess-1" },
		}))
		local recorded_ids = {}
		for i = 1, 5 do
			env.now = env.now + 60000
			local res = assert(drive())
			expect.truthy(res.admitted)
			recorded_ids[i] = res.receipt.message_id
		end

		local viewed = assert(domain.view(nil, nil, { id = rec_task.record.id }))
		expect.eq(#viewed.delivery_history.records, 3)
		expect.eq(viewed.delivery_history.earlier_records_pruned, true)
		expect.eq(viewed.delivery_history.records[1].message_id, recorded_ids[3])
		expect.eq(viewed.delivery_history.records[2].message_id, recorded_ids[4])
		expect.eq(viewed.delivery_history.records[3].message_id, recorded_ids[5])

		env.now = env.now + 3 * 86400000
		local age_res = assert(drive())
		local viewed_age = assert(domain.view(nil, nil, { id = rec_task.record.id }))
		expect.eq(#viewed_age.delivery_history.records, 1)
		expect.eq(viewed_age.delivery_history.records[1].message_id, age_res.receipt.message_id)
	end)

	it("supports cursor pagination on delivery history", function()
		local p_task = assert(domain.create(nil, nil, {
			title = "History page",
			prompt = "Page",
			timing = { kind = "every", every_seconds = 60 },
			target = { kind = "session", session_id = "sess-1" },
		}))
		local page_ids = {}
		for i = 1, 3 do
			env.now = env.now + 60000
			local r = assert(domain.run(nil, nil, { id = p_task.record.id }))
			page_ids[i] = r.receipt.message_id
		end

		local page1 = assert(domain.history(nil, nil, { id = p_task.record.id, limit = 2 }))
		expect.eq(#page1.records, 2)
		expect.eq(page1.records[1].message_id, page_ids[3])
		expect.eq(page1.records[2].message_id, page_ids[2])
		expect.eq(page1.next_before, page_ids[2])

		local page2 = assert(domain.history(nil, nil, { id = p_task.record.id, limit = 2, before = page1.next_before }))
		expect.eq(#page2.records, 1)
		expect.eq(page2.records[1].message_id, page_ids[1])
		expect.eq(page2.next_before, nil)

		local _, bad_cursor = domain.history(nil, nil, { id = p_task.record.id, limit = 2, before = "missing" })
		expect.eq(bad_cursor.code, "delivery_cursor_not_found")
	end)

	it("refuses subagent tool calls and handles /schedule management commands", function()
		local rec_task = assert(domain.create(nil, nil, {
			title = "Cmd test",
			prompt = "Run cmd",
			timing = { kind = "every", every_seconds = 60 },
			target = { kind = "session", session_id = "sess-1" },
		}))

		mare.agent_id = "sub-1"
		local sub_res = env.tools.schedule_list.execute({})
		expect.truthy(sub_res.is_error)
		expect.truthy(sub_res.content:find("subagent_session", 1, true))
		mare.agent_id = nil

		expect.eq(env.cmds.schedule.run("limits").status, "completed")
		expect.eq(env.cmds.schedule.run("unknown-action").status, "rejected")
		expect.eq(env.cmds.schedule.run("pause " .. rec_task.record.id).status, "completed")
		expect.eq(domain.view(nil, nil, { id = rec_task.record.id }).status, "paused")
		expect.eq(env.cmds.schedule.run("resume " .. rec_task.record.id).status, "completed")
		expect.eq(domain.view(nil, nil, { id = rec_task.record.id }).status, "active")
		expect.eq(env.cmds.schedule.run("delete " .. rec_task.record.id).status, "completed")
		expect.eq(env.cmds.schedule.run("view " .. rec_task.record.id).status, "rejected")
	end)

	it(
		"emits non-waking change notices for external edits, skips self-actor, and keeps delete_inactive silent",
		function()
			local p_task = assert(domain.create(nil, nil, {
				title = "Editable task",
				prompt = "Original",
				timing = { kind = "every", every_seconds = 60 },
				target = { kind = "session", session_id = "sess-1" },
			}))
			expect.eq(env.cmds.schedule.run("pause " .. p_task.record.id).status, "completed")

			env.agent_notices = {}
			local tool_created = env.tools.schedule_create.execute({
				title = "Self tool task",
				prompt = "Self check",
				rrule = "DTSTART:20261201T000000Z\nRRULE:FREQ=DAILY;COUNT=2",
				target = "current",
			})
			expect.falsy(tool_created.is_error)
			expect.eq(#env.agent_notices, 0)

			local ext_edit = domain.edit(nil, nil, {
				id = p_task.record.id,
				action = "update",
				expected_updated_at = assert(domain.view(nil, nil, { id = p_task.record.id })).updated_at,
				patch = { title = "History Page Edited", prompt = "Updated prompt" },
			})
			expect.truthy(ext_edit)
			expect.eq(#env.agent_notices, 1)
			expect.eq(env.agent_notices[1].wake, false)
			expect.truthy(env.agent_notices[1].text:find("[SCHEDULE CHANGE]", 1, true))
			expect.truthy(env.agent_notices[1].text:find("schedule_title_json", 1, true))

			local one_shot = assert(domain.create(nil, nil, {
				title = "Ended cleanup",
				prompt = "Done once",
				timing = { kind = "after", after_seconds = 60 },
				target = { kind = "session", session_id = "sess-1" },
			}))
			env.now = env.now + 60000
			env.queued = {}
			expect.truthy(drive())
			expect.eq(domain.view(nil, nil, { id = one_shot.record.id }).status, "ended")

			env.agent_notices = {}
			local del_res = assert(domain.delete_inactive())
			expect.eq(del_res.deleted, 1)
			expect.eq(#env.agent_notices, 0)
			engine.drain_notices()
		end
	)

	it("emits durable fork reminder only when source session has non-ended tasks", function()
		assert(domain.create(nil, nil, {
			title = "Source durable task",
			prompt = "Check fork",
			timing = { kind = "every", every_seconds = 60 },
			target = { kind = "session", session_id = "sess-1" },
		}))

		local init_listeners, init_disposed = {}, {}
		local init_session = {
			session_id = "sess-1",
			session_epoch = "gen-1",
			ephemeral = false,
			readonly = false,
			unstable = false,
		}
		local init_notices = {}
		local init_ctx = {
			session = {
				info = function()
					return init_session
				end,
				switching = function()
					return false
				end,
				entries = function()
					return {}
				end,
			},
			agent = {
				get = function()
					return { busy = false }
				end,
				list_queue = function()
					return { data = mare.json.array({}) }
				end,
				messages = function()
					return {}
				end,
				persist_error = function()
					return nil
				end,
				notify = function(_, text, nopts)
					init_notices[#init_notices + 1] = { text = text, wake = nopts and nopts.wake }
					return true
				end,
			},
			tools = { register = function() end },
			commands = { register = function() end },
			on = function(_, name, fn)
				init_listeners[name] = init_listeners[name] or {}
				init_listeners[name][#init_listeners[name] + 1] = fn
			end,
			effect = function(_, setup)
				local fn = setup()
				init_disposed[#init_disposed + 1] = fn
			end,
			provide = function() end,
			spawn = function() end,
			emit = function() end,
			log = function() end,
		}

		local base_support = assert(load(mare.fs.read("tests/specs/support.lua"), "@tests/specs/support.lua"))()
		schedule_support.plugin.apply(init_ctx, base_support.default_config(schedule_support.plugin))

		init_session = {
			session_id = "sess-fork-1",
			session_epoch = "gen-fork-1",
			ephemeral = false,
			readonly = false,
			unstable = false,
		}
		for _, fn in ipairs(init_listeners["session/changed"]) do
			fn({ session_id = "sess-fork-1", reason = "fork" })
		end
		expect.eq(#init_notices, 1)
		expect.eq(init_notices[1].wake, false)
		expect.truthy(init_notices[1].text:find("durable scheduled tasks", 1, true))

		init_session = {
			session_id = "sess-fork-2",
			session_epoch = "gen-fork-2",
			ephemeral = false,
			readonly = false,
			unstable = false,
		}
		for _, fn in ipairs(init_listeners["session/changed"]) do
			fn({ session_id = "sess-fork-2", reason = "fork" })
		end
		expect.eq(#init_notices, 1)

		for _, fn in ipairs(init_disposed) do
			fn()
		end
	end)

	it("resets next_at when editing an after task with the same after_seconds", function()
		local one = assert(domain.create(nil, nil, {
			title = "Same after",
			prompt = "Ping",
			timing = { kind = "after", after_seconds = 60 },
			target = { kind = "session", session_id = "sess-1" },
		}))
		local initial_sched = one.record.scheduled_at
		env.now = env.now + 25000
		local updated = assert(domain.edit(nil, nil, {
			id = one.record.id,
			action = "update",
			expected_updated_at = one.record.updated_at,
			patch = {
				timing = { kind = "after", after_seconds = 60 },
			},
		}))
		expect.truthy(updated.record.scheduled_at > initial_sched)
	end)

	it("recovers notice queue and drain_notices when a notice callback throws", function()
		local make_store = require("schedule.store")
		local info_calls, notified = 0, 0
		local spawned = {}
		local sctx = {
			session = {
				info = function()
					info_calls = info_calls + 1
					if info_calls == 1 then
						error("transient session info error", 0)
					end
					return {
						session_id = "s-target",
						session_epoch = "g1",
						ephemeral = false,
						readonly = false,
						unstable = false,
					}
				end,
				switching = function()
					return false
				end,
				list = function()
					return { data = {} }
				end,
				list_records = function()
					return { data = {} }
				end,
			},
			agent = {
				notify = function()
					notified = notified + 1
				end,
			},
			spawn = function(_, fn)
				spawned[#spawned + 1] = fn
			end,
			on = function() end,
			effect = function() end,
			emit = function() end,
			bus = { emit = function() end },
		}
		local st = make_store(sctx, { cooldown_seconds = 1 })
		local notice_payload = function(id, title)
			return true,
				true,
				nil,
				{
					change = "created",
					task = {
						record = { id = id, title = title },
						target = { session_id = "s-target" },
						involved_session_ids = { "s-target" },
					},
					actor_session_id = "s-other",
				}
		end
		assert(st.mutate(function()
			return notice_payload("t-1", "Notice recovery")
		end))
		assert(st.mutate(function()
			return notice_payload("t-2", "Second notice")
		end))
		expect.eq(#spawned, 1)
		spawned[1]()
		expect.eq(notified, 1)
		expect.eq(st.drain_notices(), true)
	end)
end)
