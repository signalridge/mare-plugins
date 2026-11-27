-- Context-driven faux responses: no tool/rewrite, no fabricated delivery receipt.
return {
	name = "schedule-domain-probe",
	inject = { "llm", "commands", "session", "agent", "kernel", "policy" },
	apply = function(ctx)
		local schedule
		ctx:inject({ "schedule" }, function(sub)
			schedule = sub.schedule
		end)
		-- Automatic delivery uses ctx.agent:enqueue; report whether the core provides it so the
		-- driver can skip delivery steps if the durable input queue is unavailable.
		ctx.commands:register("domain-capabilities", {
			description = "Report core capabilities the delivery checks need",
			run = function()
				local ok, enqueue = pcall(function()
					return ctx.agent.enqueue
				end)
				local mt = ok and type(enqueue) == "table" and getmetatable(enqueue)
				local present = ok and (type(enqueue) == "function" or (type(mt) == "table" and mt.__call ~= nil))
				mare.ui.notify("DOMAIN_CAPABILITY agent.enqueue=" .. tostring(present == true))
			end,
		})
		ctx.commands:register("domain-checks", {
			description = "Real domain lifetime and cancellation checks",
			run = function()
				local request = {
					title = "LIFETIME_CHECK",
					prompt = "No execution",
					timing = { kind = "after", after_seconds = 7200 },
					target = { kind = "session", session_id = ctx.session:info().session_id },
				}
				-- Durable tasks already exist (the driver created MODEL_SAVED first): compare snapshots.
				local function snapshot()
					local rows = {}
					for _, task in ipairs(schedule:list_durable({}).items) do
						rows[#rows + 1] = task.record.id .. "@" .. tostring(task.updated_at)
					end
					table.sort(rows)
					return table.concat(rows, ",")
				end
				local before = snapshot()
				local cancelled = mare.task.token()
				cancelled:cancel()
				local ok_cancel, cancel_err = pcall(schedule.create_durable, schedule, request, { cancel = cancelled })
				assert(not ok_cancel and cancel_err and cancel_err.code == "cancelled")
				assert(snapshot() == before, "cancelled create_durable changed the durable task list")
				local allowed = false
				mare.exec.run(
					{ tool = "domain-readonly", lifetime = "ephemeral-read-only", sandbox = { level = "read-only" } },
					function()
						local ok, value = pcall(function()
							return schedule:create_durable(request)
						end)
						allowed = ok and value ~= nil
					end
				)
				assert(not allowed, "readonly domain mutation escaped")
				local old = schedule
				ctx.kernel:reload("schedule")
				local ok, value = pcall(old.create_durable, old, request)
				assert(not ok or value == nil, "retired provider wrote a definition")
				local created = assert(schedule:create_durable(request))
				assert(schedule:edit({
					id = created.record.id,
					action = "delete",
					expected_updated_at = created.updated_at,
				}))
				ui.notify("DOMAIN_LIFETIME_CHECKS_PASSED", "info")
			end,
		})
		local raced = false
		ctx:on("schedule/changed", function()
			if raced then
				return
			end
			local page = schedule:list_durable({})
			if not page then
				return
			end
			for _, task in ipairs(page.items) do
				if
					task.record.title == "PLAN_RESERVE_RACE"
					and task.reservation
					and task.reservation.phase == "reserved"
				then
					raced = true
					ctx.commands:run("/plan")
					ui.notify("PLAN_RESERVE_RACE_BLOCKED", "info")
				end
			end
		end)
		local late = false
		local function trigger_late_plan(text)
			if not late and type(text) == "string" and text:find("PLAN_LATE_RACE", 1, true) then
				late = true
				ctx.commands:run("/plan")
				ui.notify("PLAN_LATE_RACE_BLOCKED", "info")
			end
		end
		ctx:on("turn/started", function(event)
			if event.source == "schedule" or event.trigger == "schedule" then
				trigger_late_plan(event.text)
			end
		end)
		ctx.policy:voter("agent/input-ready", function(event)
			if not late and event.source == "schedule" then
				local first = type(event.content) == "table" and event.content[1]
				trigger_late_plan(first and first.text)
			end
		end, { prepend = true })
		ctx.commands:register("domain-race", {
			description = "Concurrent real run admission fixture",
			run = function(id)
				local a = mare.task.spawn(function()
					return schedule:run({ id = id })
				end)
				local b = mare.task.spawn(function()
					return schedule:run({ id = id })
				end)
				local ok_a, res_a = pcall(a.wait, a)
				local ok_b, res_b = pcall(b.wait, b)
				local function is_winner(ok, res)
					return ok and type(res) == "table" and res.admitted ~= false
				end
				local function is_expected_loser(ok, res)
					if ok then
						return type(res) == "table"
							and res.admitted == false
							and type(res.delivery_floor_ends_at) == "string"
					end
					local code = type(res) == "table" and res.code or nil
					local msg = type(res) == "table" and (res.message or tostring(res)) or tostring(res or "")
					return (
						code == "schedule_unavailable"
						or code == "recovery_required"
						or msg:find("schedule_unavailable", 1, true) ~= nil
					) and msg:find("outstanding reservation", 1, true) ~= nil
				end
				assert(
					(is_winner(ok_a, res_a) and is_expected_loser(ok_b, res_b))
						or (is_winner(ok_b, res_b) and is_expected_loser(ok_a, res_a)),
					("unexpected domain race outcomes: a=(%s,%s) b=(%s,%s)"):format(
						tostring(ok_a),
						tostring(res_a),
						tostring(ok_b),
						tostring(res_b)
					)
				)
				ui.notify("DOMAIN_RACE_FINISHED", "info")
			end,
		})
		local sequence = 0
		ctx.llm:register_provider({
			provider = "faux-domain",
			default_model = "echo",
			is_configured = function()
				return true
			end,
			models = {
				{
					model_id = "echo",
					name = "Domain test faux",
					context_window = 100000,
					max_output = 4096,
					reasoning = true,
					efforts = { "low", "medium", "high" },
					cost = { input = 0, output = 0 },
				},
			},
			stream = function(req, sink)
				local user, index = "", 0
				local notifications = {}
				for i = 1, #req.messages do
					if req.messages[i].role == "user" and req.messages[i].notification then
						local ntext = ""
						for _, b in ipairs(req.messages[i].content) do
							if b.type == "text" then
								ntext = ntext .. b.text
							end
						end
						notifications[#notifications + 1] = ntext
					end
				end
				for i = #req.messages, 1, -1 do
					if req.messages[i].role == "user" and not req.messages[i].notification then
						for _, b in ipairs(req.messages[i].content) do
							if b.type == "text" then
								user = user .. b.text
							end
						end
						index = i
						break
					end
				end
				local log = mare.env("DOMAIN_MODEL_LOG")
				if log then
					assert(
						mare.fs.write(
							log,
							mare.json.encode({ user = user, notifications = notifications }) .. "\n",
							{ append = true }
						)
					)
				end
				if user:find("MODEL_DEFINE", 1, true) then
					local results = {}
					for i = index + 1, #req.messages do
						if req.messages[i].role == "tool_result" then
							local text = ""
							for _, b in ipairs(req.messages[i].content) do
								if b.type == "text" then
									text = text .. b.text
								end
							end
							results[#results + 1] = assert(mare.json.decode_lossless(text))
						end
					end
					local name, args
					if #results == 0 then
						local at = assert(mare.time.query({
							action = "format",
							instant_ms = math.floor(mare.task.now()) + 3600000,
							timezone = "UTC",
							format = "%Y%m%dT%H%M%SZ",
						})).text
						name = "schedule_create"
						args = {
							title = "MODEL_SAVED",
							prompt = "Inspect the actual deployment",
							rrule = "DTSTART:" .. at .. "\nRRULE:FREQ=DAILY;COUNT=2",
							target = "current",
						}
					elseif #results == 1 then
						name = "schedule_view"
						args = { id = results[1].record.id }
					elseif #results == 2 then
						name = "schedule_edit"
						args = {
							id = results[2].record.id,
							action = "update",
							active = false,
							expected_updated_at = results[2].updated_at,
						}
					end
					if name then
						sequence = sequence + 1
						local id = "domain_model_" .. sequence
						sink({ type = "tool_call_start", tool_call_id = id, name = name })
						return {
							role = "assistant",
							content = { { type = "tool_call", id = id, name = name, arguments = args } },
							stop_reason = "tool_use",
							usage = { input = 10, output = 10 },
						}
					end
				end
				if user:find("DELIVERY_ERROR", 1, true) then
					error({ message = "domain fixture model failure", retryable = false })
				end
				if user:find("DELIVERY_CANCEL", 1, true) then
					sink({ type = "text_delta", delta = "DOMAIN_CANCEL_STARTED" })
					mare.task.sleep(10000, req.cancel)
					if req.cancel:is_cancelled() then
						return {
							role = "assistant",
							content = {},
							stop_reason = "aborted",
							usage = { input = 10, output = 1 },
						}
					end
				end
				sink({ type = "text_delta", delta = "DOMAIN_TASK_EXECUTED" })
				return {
					role = "assistant",
					content = { { type = "text", text = "DOMAIN_TASK_EXECUTED" } },
					stop_reason = "stop",
					usage = { input = 10, output = 10 },
				}
			end,
		})
	end,
}
