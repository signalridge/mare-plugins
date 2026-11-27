local support = assert(load(mare.fs.read("tests/specs/support.lua"), "@tests/specs/support.lua"))()

local describe = mare.test.describe
local it = mare.test.it
local before_each = mare.test.before_each
local after_each = mare.test.after_each
local expect = mare.test.expect

support.preload_modules("schedule", { "schedule.policy", "schedule.scheduler" })
local make_scheduler = require("schedule.scheduler")

describe("schedule /loop scheduler", function()
	local now, timers, listeners, current, calls, loop_notices, identity
	local orig_now
	local ctx, scheduler

	local function active_timers()
		local n = 0
		for _, t in ipairs(timers) do
			if not t.cancelled and not t.fired then
				n = n + 1
			end
		end
		return n
	end

	local function advance(ms)
		local target = now + ms
		while true do
			local due
			for _, t in ipairs(timers) do
				if not t.cancelled and not t.fired and t.due <= target and (not due or t.due < due.due) then
					due = t
				end
			end
			if not due then
				now = target
				return
			end
			now, due.fired = due.due, true
			due.fn()
		end
	end

	local function create(prompt, interval)
		return assert(scheduler.create(nil, nil, prompt, interval))
	end

	local function control(action, id)
		return scheduler.control(nil, nil, action, id)
	end

	local function finish(err)
		local turn = current
		current = nil
		listeners["turn/completed"]({ turn_id = turn, error = err })
		advance(0)
	end

	before_each(function()
		now = 0
		timers = {}
		listeners = {}
		current = nil
		calls = {}
		loop_notices = {}
		identity = { session_id = "A", session_epoch = "one" }

		orig_now = mare.task.now
		mare.task.now = function()
			return now
		end

		ctx = support.adapt_mock({ session = {}, agent = {} })
		function ctx.session:info()
			return identity
		end
		function ctx.session:switching()
			return false
		end
		function ctx.agent:get()
			return { turn_id = current, busy = current ~= nil }
		end
		function ctx.agent:notify(text, opts)
			loop_notices[#loop_notices + 1] = { text = text, wake = opts and opts.wake }
			return true
		end
		function ctx.agent:prompt(text, opts)
			if opts and opts.expected_session then
				expect.eq(opts.expected_session.session_id, identity.session_id)
			end
			if current then
				error(mare.error("busy", "agent is busy"), 0)
			end
			current = "turn-" .. (#calls + 1)
			calls[#calls + 1] = { text = text, turn = current, at = now }
			return { status = "started", turn_id = current }
		end
		function ctx:after(delay, fn)
			local handle = { due = now + delay, fn = fn }
			function handle:abort()
				self.cancelled = true
			end
			timers[#timers + 1] = handle
			return handle
		end
		function ctx:on(event, fn)
			listeners[event] = fn
		end
		function ctx:effect(setup)
			local fn = setup()
			listeners.dispose = fn
		end
		-- core agent:cancel: cancels only the named turn, and only while it is the active one
		function ctx.agent:cancel(req)
			if current and current == req.turn_id then
				current = nil
				return true
			end
			return false, "no active turn to interrupt"
		end

		scheduler = make_scheduler(ctx)
	end)

	after_each(function()
		if listeners and listeners.dispose then
			listeners.dispose()
		end
		mare.task.now = orig_now
	end)

	it("rejects intervals under 60s and maintains a single next-due timer across multiple tasks", function()
		expect.falsy(scheduler.create(nil, nil, "too short", 59999))

		local single_a = create("one", 60000)
		local single_b = create("two", 120000)
		local single_c = create("three", 180000)
		expect.eq(active_timers(), 1)
		expect.truthy(control("pause", single_b))
		expect.eq(active_timers(), 1)
		expect.truthy(control("stop", single_a))
		expect.truthy(control("stop", single_b))
		expect.truthy(control("stop", single_c))
		expect.eq(active_timers(), 0)
	end)

	it("runs fixed-interval tasks, supports pause/resume/stop, and preserves prompt text", function()
		local fixed = create("/lua must remain text", 60000)
		advance(59999)
		expect.eq(#calls, 0)
		advance(1)
		expect.eq(#calls, 1)
		expect.truthy(calls[1].text:find("/lua must remain text", 1, true))

		finish()
		advance(60000)
		expect.eq(#calls, 2)
		finish()

		expect.truthy(control("pause", fixed))
		advance(600000)
		expect.eq(#calls, 2)
		expect.truthy(control("resume", fixed))
		advance(59999)
		expect.eq(#calls, 2)
		advance(1)
		expect.eq(#calls, 3)

		expect.truthy(control("stop", fixed))
		expect.eq(current, nil)
		expect.eq(#scheduler.list(), 0)
	end)

	it("supports adaptive scheduling with submit validation and fallback", function()
		local adaptive = create("watch")
		advance(60000)
		local prompt = calls[#calls].text
		local id, rev, token = prompt:match("task_id=(%d+), revision=(%d+), run_token=([%x]+)")
		expect.eq(id, adaptive)

		local args = { task_id = id, revision = tonumber(rev), run_token = token, delay_ms = 59999, reason = "bad" }
		expect.falsy(scheduler.submit(nil, nil, args))
		args.delay_ms = 3600000
		expect.truthy(scheduler.submit(nil, nil, args))
		expect.falsy(scheduler.submit(nil, nil, args))

		finish()
		expect.eq(scheduler.list()[1].effective_delay, 3600000)
		advance(3600000)
		finish()
		expect.truthy(scheduler.list()[1].delay_reason:find("No valid interval", 1, true))
		expect.truthy(control("stop", adaptive))
	end)

	it("defers during busy periods and pauses on aborted turn", function()
		current = "human"
		local pending = create("pending", 60000)
		advance(180000)
		expect.truthy(scheduler.list()[1].pending)
		expect.eq(current, "human")

		local before = #calls
		finish()
		expect.eq(#calls, before + 1)
		finish("aborted")
		expect.eq(scheduler.list()[1].status, "paused")
		expect.truthy(control("stop", pending))
	end)

	it("keeps task active and pending when foreground input is owned", function()
		local foreground_blocked = true
		local orig_prompt = ctx.agent.prompt
		function ctx.agent:prompt(text, opts)
			if foreground_blocked then
				return { status = "foreground", error = "owned input must be resumed first" }
			end
			return orig_prompt(self, text, opts)
		end

		local fg_task = create("wait for foreground", 60000)
		local fg_before = #calls
		advance(60000)
		expect.eq(#calls, fg_before)
		expect.eq(scheduler.list()[1].status, "active")
		expect.eq(scheduler.list()[1].pending, true)

		foreground_blocked = false
		finish()
		expect.eq(#calls, fg_before + 1)
		finish()
		expect.truthy(control("stop", fg_task))
	end)

	it("expires paused tasks after 7 days and rejects resume", function()
		local expiring = create("seven days", 60000)
		expect.truthy(control("pause", expiring))
		advance(7 * 24 * 60 * 60000)
		expect.eq(scheduler.list()[1].status, "expired")
		expect.falsy(control("resume", expiring))
		expect.truthy(control("stop", expiring))
	end)

	it(
		"clears tasks on session switch, emits fork reminder only when non-empty, and rejects create after dispose",
		function()
			local old = create("old", 60000)
			identity = { session_id = "B", session_epoch = "two" }
			listeners["session/changed"]({ id = "B", reason = "switch" })
			advance(60000)
			expect.eq(#scheduler.list(), 0)
			expect.falsy(control("resume", old))
			expect.eq(#loop_notices, 0)

			local fork_src = create("fork-src", 60000)
			expect.truthy(fork_src)
			identity = { session_id = "C", session_epoch = "three" }
			listeners["session/changed"]({ id = "C", reason = "fork" })
			expect.eq(#scheduler.list(), 0)
			expect.eq(#loop_notices, 1)
			expect.eq(loop_notices[1].wake, false)
			expect.truthy(loop_notices[1].text:find("forked session", 1, true))

			identity = { session_id = "D", session_epoch = "four" }
			listeners["session/changed"]({ id = "D", reason = "fork" })
			expect.eq(#loop_notices, 1)

			listeners.dispose()
			expect.falsy(scheduler.create(nil, nil, "disposed"))
		end
	)

	it(
		"defers /loop delivery while plan_mode is active or pending, sets input_context.schedule, and tracks step-ready turns",
		function()
			local pm_state = { active = false, pending = true }
			local submitted_opts = {}
			local orig_prompt = ctx.agent.prompt
			function ctx.agent:prompt(text, opts)
				submitted_opts[#submitted_opts + 1] = opts
				return orig_prompt(self, text, opts)
			end
			local step_vote = nil
			function ctx:on(ev, fn)
				listeners[ev] = fn
			end
			local voters = {}
			ctx.policy = {
				voter = function(_, ev, fn)
					voters[ev] = fn
				end,
			}
			local pm_sched = make_scheduler(ctx, function()
				return {
					state = function()
						return pm_state
					end,
				}
			end)

			local id = assert(pm_sched.create(nil, nil, "loop-pm", 60000))
			advance(60000)
			-- Deferred while plan_mode pending == true
			expect.eq(#calls, 0)
			expect.eq(pm_sched.list()[1].pending, true)

			-- Un-gate via plan-mode/changed -> delivers immediately with input_context.schedule
			pm_state = { active = false, pending = false }
			listeners["plan-mode/changed"](pm_state)
			advance(0)
			expect.eq(#calls, 1)
			expect.truthy(submitted_opts[1].input_context and submitted_opts[1].input_context.schedule)
			expect.eq(submitted_opts[1].input_context.schedule.loop, true)
			expect.eq(submitted_opts[1].input_context.schedule.task_id, id)

			-- Tracked turn passes agent/step-ready plan-mode voter when inactive, denies if plan_mode flips active
			expect.eq(voters["agent/step-ready"]({ turn_id = current }), nil)
			pm_state = { active = true, pending = false }
			local vote = voters["agent/step-ready"]({ turn_id = current })
			expect.eq(vote.decision, "deny")
			expect.truthy(pm_sched.control(nil, nil, "stop", id))
		end
	)
end)
