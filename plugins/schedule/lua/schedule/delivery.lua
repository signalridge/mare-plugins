-- Use durable input receipts; never derive ACK from snapshots or model completion.
local V = require("schedule.value")
-- plan_mode_of(): the optional plan_mode service or nil (the plugin passes a follower-backed
-- getter natively; without one, a plain ctx field is read raw - a native ctx has no such field)
return function(ctx, domain, engine, plan_mode_of)
	plan_mode_of = plan_mode_of or function()
		return rawget(ctx, "plan_mode")
	end
	local owned_turns, owned_inputs, pending_owned_inputs = {}, {}, {}
	local in_flight, cooldown = {}, {}
	local instance = mare.crypto.uuid()
	local lifetime = mare.task.token()
	ctx:effect(function()
		return function()
			lifetime:cancel()
		end
	end)
	local function planning()
		local plan_mode = plan_mode_of()
		if not plan_mode then
			return false
		end
		local ok, state = pcall(plan_mode.state, plan_mode)
		if not ok or type(state) ~= "table" then
			return true
		end
		return state.active == true or state.pending == true
	end
	local function schedule_ctx_matches(sched, reservation_id)
		if type(sched) ~= "table" then
			return false
		end
		if sched.reservation_id == reservation_id then
			return true
		end
		if type(sched.reservation_ids) == "table" then
			for _, id in ipairs(sched.reservation_ids) do
				if id == reservation_id then
					return true
				end
			end
		end
		return false
	end
	local function reservation_ids_for(sched)
		local set = {}
		if type(sched) ~= "table" then
			return set
		end
		if type(sched.reservation_id) == "string" then
			set[sched.reservation_id] = true
		end
		if type(sched.reservation_ids) == "table" then
			for _, id in ipairs(sched.reservation_ids) do
				if type(id) == "string" then
					set[id] = true
				end
			end
		end
		return set
	end
	local function find_committed_input(reservation_id, session_id)
		local qres = ctx.agent:list_queue()
		for _, entry in ipairs((qres and qres.data) or {}) do
			local id = entry.input_id
			local sched = entry.input_context and entry.input_context.schedule
			if schedule_ctx_matches(sched, reservation_id) and type(id) == "string" and id ~= "" then
				return { status = "queued", durable = true, input_id = id, session_id = session_id }, sched
			end
		end
		if require("mare_lib").callable(ctx.agent.messages) then
			local msgs = ctx.agent:messages()
			for i = #msgs, 1, -1 do
				local msg = msgs[i]
				local sched = msg.input_context and msg.input_context.schedule
				if
					schedule_ctx_matches(sched, reservation_id)
					and type(msg.input_id) == "string"
					and msg.input_id ~= ""
				then
					return { status = "queued", durable = true, input_id = msg.input_id, session_id = session_id },
						sched
				end
			end
		end
		if require("mare_lib").callable(ctx.session.entries) then
			local entries = ctx.session:entries()
			for i = #entries, 1, -1 do
				local entry = entries[i]
				if entry.type == "message" and type(entry.message) == "table" then
					local msg = entry.message
					local sched = msg.input_context and msg.input_context.schedule
					if
						schedule_ctx_matches(sched, reservation_id)
						and type(msg.input_id) == "string"
						and msg.input_id ~= ""
					then
						return {
							status = "queued",
							durable = true,
							input_id = msg.input_id,
							session_id = session_id,
						},
							sched
					end
				elseif entry.type == "custom" and entry.kind == "agent/queue" and type(entry.data) == "table" then
					for _, name in ipairs({ "steer", "follow_up" }) do
						for _, item in ipairs(entry.data[name] or {}) do
							local sched = item.input_context and item.input_context.schedule
							local item_id = item.input_id
							if
								schedule_ctx_matches(sched, reservation_id)
								and type(item_id) == "string"
								and item_id ~= ""
							then
								return {
									status = "queued",
									durable = true,
									input_id = item_id,
									session_id = session_id,
								},
									sched
							end
						end
					end
				end
			end
		end
		return nil
	end
	local function reconcile(catalog)
		local info = ctx.session:info()
		if info.ephemeral or info.readonly or info.unstable or ctx.session:switching() then
			return false
		end
		local changed, handled = false, {}
		for _, task in ipairs(catalog) do
			local reserved = task.reservation
			if
				reserved
				and not handled[reserved.id]
				and (reserved.phase == "unknown" or (reserved.phase == "submitting" and not in_flight[reserved.id]))
				and reserved.target.session_id == info.session_id
			then
				local receipt, sched = find_committed_input(reserved.id, info.session_id)
				if receipt then
					local id_set = reservation_ids_for(sched)
					id_set[reserved.id] = true
					local pairs = {}
					for _, candidate in ipairs(catalog) do
						local r = candidate.reservation
						if r and id_set[r.id] then
							handled[r.id] = true
							pairs[#pairs + 1] = { id = candidate.record.id, reservation = r.id }
						end
					end
					if #pairs > 0 and engine.acknowledge_batch(pairs, receipt) then
						owned_inputs[receipt.input_id] = true
						cooldown[task.record.id] = nil
						changed = true
					end
				else
					handled[reserved.id] = true
					local persist_err = require("mare_lib").callable(ctx.agent.persist_error)
						and ctx.agent:persist_error()
					if not persist_err and engine.reconcile_absent(task.record.id, reserved.id) then
						cooldown[task.record.id] = nil
						changed = true
					end
				end
			end
		end
		return changed
	end
	local function resume()
		if planning() or (ctx.agent:get() or {}).busy then
			return
		end
		local info = ctx.session:info()
		if info.ephemeral or info.readonly or info.unstable or ctx.session:switching() then
			return
		end
		local qres = ctx.agent:list_queue()
		local first = (qres and qres.data or {})[1]
		local first_id = first and first.input_id
		if first_id and owned_inputs[first_id] and require("mare_lib").callable(ctx.agent.resume_input) then
			local result = ctx.agent:resume_input(
				{ session_id = info.session_id, session_epoch = info.session_epoch },
				{ input_id = first_id }
			)
			if result.status == "started" then
				owned_turns[result.turn_id] = true
			end
		end
	end
	local function set_in_flight(tasks, active)
		for _, task in ipairs(tasks) do
			if task.reservation then
				in_flight[task.reservation.id] = active or nil
			end
		end
	end
	local function set_cooldown(tasks, until_ms)
		for _, task in ipairs(tasks) do
			cooldown[task.record.id] = until_ms
		end
	end
	local function build_payload(tasks)
		local total_missed, missed_tasks, any_capped = 0, 0, false
		local earliest_missed, earliest_ms
		local task_ids, reservation_ids, items = {}, {}, {}
		for _, task in ipairs(tasks) do
			local r = task.reservation
			local count = (not r.manual and r.coalesced_count) or 0
			local capped = not r.manual and r.coalesced_capped == true
			task_ids[#task_ids + 1] = task.record.id
			reservation_ids[#reservation_ids + 1] = r.id
			if count > 0 then
				total_missed = total_missed + count
				missed_tasks = missed_tasks + 1
				any_capped = any_capped or capped
				local sched_ms = assert(V.ms(r.scheduled_at))
				if not earliest_ms or sched_ms < earliest_ms then
					earliest_ms = sched_ms
					earliest_missed = r.scheduled_at
				end
			end
			items[#items + 1] = {
				id = task.record.id,
				title = task.record.title,
				kind = task.record.kind,
				prompt = r.prompt,
				scheduled_at = r.scheduled_at,
				occurrence_at = r.occurrence_at,
				coalesced_missed_count = count > 0 and count or nil,
				coalesced_capped = (count > 0 and capped) and true or nil,
			}
		end
		local text, summary
		if #tasks == 1 then
			local task = tasks[1]
			local r = task.reservation
			if total_missed > 0 then
				local plus = any_capped and "+" or ""
				text = "[SCHEDULE REMINDER]\n[Missed runs coalesced: "
					.. tostring(total_missed)
					.. plus
					.. " skipped since "
					.. r.scheduled_at
					.. "; delivering latest occurrence "
					.. r.occurrence_at
					.. "]\n"
					.. r.prompt
				summary = 'Schedule missed-run catch-up for "'
					.. task.record.title
					.. '": coalesced '
					.. tostring(total_missed)
					.. plus
					.. " missed occurrence(s) since "
					.. r.scheduled_at
					.. "; running "
					.. r.occurrence_at
			else
				text = "[SCHEDULE REMINDER]\n" .. r.prompt
			end
			return text,
				{
					schedule = {
						task_id = task.record.id,
						reservation_id = r.id,
						occurrence_at = r.occurrence_at,
						coalesced_missed_count = total_missed > 0 and total_missed or nil,
						coalesced_capped = (total_missed > 0 and any_capped) and true or nil,
						earliest_missed_at = earliest_missed,
					},
				},
				total_missed,
				earliest_missed,
				summary
		end
		local plus = any_capped and "+" or ""
		if total_missed > 0 then
			text = "[SCHEDULE REMINDER BATCH]\n[Missed runs coalesced: "
				.. tostring(total_missed)
				.. plus
				.. " across "
				.. tostring(missed_tasks)
				.. " task(s) since "
				.. earliest_missed
				.. "]\nreminders_json: "
				.. mare.json.encode(items)
			summary = "Schedule missed-run catch-up across "
				.. tostring(missed_tasks)
				.. " task(s): coalesced "
				.. tostring(total_missed)
				.. plus
				.. " missed occurrence(s) since "
				.. earliest_missed
		else
			text = "[SCHEDULE REMINDER BATCH]\nreminders_json: " .. mare.json.encode(items)
		end
		return text,
			{
				schedule = {
					batched = true,
					task_id = tasks[1].record.id,
					reservation_id = tasks[1].reservation.id,
					task_ids = task_ids,
					reservation_ids = reservation_ids,
					occurrence_at = tasks[1].reservation.occurrence_at,
					coalesced_missed_count = total_missed > 0 and total_missed or nil,
					coalesced_capped = (total_missed > 0 and any_capped) and true or nil,
					earliest_missed_at = earliest_missed,
				},
			},
			total_missed,
			earliest_missed,
			summary,
			task_ids
	end
	local function deliver_group(tasks, caller_cancel)
		if planning() then
			return V.fail("plan_mode", "Automatic schedule admission waits for explicit plan-mode exit")
		end
		local info = ctx.session:info()
		for _, task in ipairs(tasks) do
			if
				task.reservation.target.session_id ~= info.session_id
				or info.ephemeral
				or info.readonly
				or info.unstable
			then
				set_cooldown(tasks, math.floor(mare.task.now()) + 5000)
				return V.fail("target_unavailable", "The current durable target is unavailable")
			end
		end
		local pairs = {}
		for _, task in ipairs(tasks) do
			pairs[#pairs + 1] = { id = task.record.id, reservation = task.reservation.id }
		end
		set_in_flight(tasks, true)
		local pending, err = engine.submitting_batch(pairs)
		if not pending then
			set_in_flight(tasks, false)
			if err and err.code == "recovery_required" then
				set_cooldown(tasks, math.floor(mare.task.now()) + 5000)
			end
			return nil, err
		end
		-- Recheck policy after asynchronous reservation publication, before native enqueue.
		if planning() then
			engine.failed_batch(pairs, "plan_mode", "Mode changed before enqueue", true)
			set_in_flight(tasks, false)
			return V.fail("plan_mode", "Mode changed before enqueue")
		end
		local prompt_text, input_context, total_missed, earliest_missed, summary, task_ids = build_payload(tasks)
		local request_id = tasks[1]
			and tasks[1].reservation
			and tasks[1].reservation.id
			and ("schedule:" .. tostring(tasks[1].reservation.id))
		local ok, receipt = pcall(function()
			return V.cancellable(lifetime, caller_cancel, function(cancel)
				return ctx.agent:enqueue(
					{ { type = "text", text = prompt_text } },
					{ session_id = info.session_id, session_epoch = info.session_epoch },
					{
						cancel = cancel,
						source = "schedule",
						delivery = "follow_up",
						request_id = request_id,
						input_context = input_context,
					}
				)
			end)
		end)
		if not ok or receipt.status == "indeterminate" then
			engine.failed_batch(
				pairs,
				"delivery_unknown",
				ok and (receipt.error or "Indeterminate enqueue outcome") or tostring(receipt),
				false
			)
			set_in_flight(tasks, false)
			set_cooldown(tasks, math.floor(mare.task.now()) + 5000)
			return V.fail("delivery_unknown", "Enqueue outcome is unknown; reconcile instead of blindly resubmitting")
		end
		if receipt.status ~= "queued" or receipt.durable ~= true then
			engine.failed_batch(
				pairs,
				"delivery_rejected",
				receipt.error or "No durable receipt",
				receipt.status == "rejected" or receipt.status == "stale"
			)
			set_in_flight(tasks, false)
			set_cooldown(tasks, math.floor(mare.task.now()) + 5000)
			return V.fail("delivery_rejected", receipt.error or "No durable receipt")
		end
		pending_owned_inputs[receipt.input_id] = true
		owned_inputs[receipt.input_id] = true
		local saved
		saved, err = engine.acknowledge_batch(pairs, receipt)
		pending_owned_inputs[receipt.input_id] = nil
		set_in_flight(tasks, false)
		if not saved then
			return nil,
				err or {
					code = "schedule_not_found",
					message = "Task was deleted after inbox delivery; queued input is retained",
				}
		end
		set_cooldown(tasks, nil)
		if summary then
			mare.log("info", summary)
			if mare and mare.ui and type(mare.ui.notify) == "function" then
				mare.ui.notify(summary, "info")
			end
		end
		resume()
		if #tasks == 1 then
			return {
				id = tasks[1].record.id,
				admitted = true,
				receipt = saved[1].last_delivery,
				coalesced_count = total_missed > 0 and total_missed or 0,
				earliest_missed_at = earliest_missed,
				missed_summary = summary,
			}
		end
		local receipts = {}
		for _, t in ipairs(saved) do
			receipts[#receipts + 1] = t.last_delivery
		end
		return {
			batched = true,
			id = tasks[1].record.id,
			ids = task_ids,
			admitted = true,
			receipt = saved[1].last_delivery,
			receipts = receipts,
			coalesced_count = total_missed > 0 and total_missed or 0,
			earliest_missed_at = earliest_missed,
			missed_summary = summary,
		}
	end
	engine.deliver = function(task, caller_cancel)
		return deliver_group({ task }, caller_cancel)
	end
	local function next_wait_ms(catalog, now)
		local info = ctx.session:info()
		local soonest
		for _, task in ipairs(catalog) do
			if task.status == "active" and task.target.session_id == info.session_id then
				local pending = task.reservation
					and (task.reservation.phase == "unknown" or task.reservation.phase == "submitting")
				if not pending then
					local due = math.max(
						assert(V.ms(task.record.scheduled_at)),
						engine.floor_end(task),
						cooldown[task.record.id] or 0
					)
					if not soonest or due < soonest then
						soonest = due
					end
				end
			end
		end
		if not soonest then
			return nil
		end
		return math.max(0, soonest - now)
	end
	local function clear_cooldown(id)
		if id then
			cooldown[id] = nil
		else
			cooldown = {}
		end
	end
	local function is_owned_input(event)
		if type(event) ~= "table" then
			return false
		end
		if event.input_id and (owned_inputs[event.input_id] or pending_owned_inputs[event.input_id]) then
			return true
		end
		if event.turn_id and owned_turns[event.turn_id] then
			return true
		end
		local sched = type(event.input_context) == "table" and event.input_context.schedule or nil
		return event.source == "schedule"
			and type(sched) == "table"
			and (
				(type(sched.reservation_id) == "string" and sched.reservation_id ~= "")
				or (sched.batched == true and type(sched.reservation_ids) == "table" and #sched.reservation_ids > 0)
			)
	end
	ctx.policy:voter("agent/input-ready", function(event)
		if is_owned_input(event) then
			if planning() then
				return {
					decision = "deny",
					reason = "Mode changed after schedule reservation; automatic work is deferred",
				}
			end
			if type(event.turn_id) == "string" and event.turn_id ~= "" then
				owned_turns[event.turn_id] = true
			end
		end
	end)
	ctx.policy:voter("agent/step-ready", function(step)
		if type(step) == "table" and (owned_turns[step.turn_id] or is_owned_input(step)) and planning() then
			return { decision = "deny", reason = "Mode changed after schedule reservation; automatic work is deferred" }
		end
	end)
	if require("mare_lib").callable(ctx.on) then
		ctx:on("turn/started", function(event)
			if is_owned_input(event) and type(event.turn_id) == "string" and event.turn_id ~= "" then
				owned_turns[event.turn_id] = true
			end
		end)
	end
	ctx:on("turn/completed", function(event)
		if type(event) == "table" and event.turn_id then
			owned_turns[event.turn_id] = nil
		end
	end)
	local function is_queued_schedule_entry(entry)
		if type(entry) ~= "table" then
			return false
		end
		if entry.source == "schedule" then
			return true
		end
		return type(entry.input_context) == "table" and type(entry.input_context.schedule) == "table"
	end
	local function drive()
		local catalog, err = engine.catalog()
		if not catalog then
			return nil, err, 5000
		end
		if reconcile(catalog) then
			catalog, err = engine.catalog()
			if not catalog then
				return nil, err, 5000
			end
		end
		local qres = ctx.agent:list_queue()
		local queued_entries = (qres and qres.data) or {}
		local still_queued = {}
		for _, entry in ipairs(queued_entries) do
			local id = entry.input_id
			if id then
				still_queued[id] = true
			end
		end
		local next_owned = {}
		for id in pairs(owned_inputs) do
			if still_queued[id] then
				next_owned[id] = true
			end
		end
		for id in pairs(pending_owned_inputs) do
			next_owned[id] = true
		end
		for _, entry in ipairs(queued_entries) do
			local id = entry.input_id
			if id and is_queued_schedule_entry(entry) then
				next_owned[id] = true
			end
		end
		for _, task in ipairs(catalog) do
			if task.last_delivery then
				next_owned[task.last_delivery.message_id] = true
			end
			for _, rec in ipairs((task.delivery_history and task.delivery_history.records) or {}) do
				if type(rec.message_id) == "string" and rec.message_id ~= "" then
					next_owned[rec.message_id] = true
				end
			end
		end
		owned_inputs = next_owned
		resume()
		if planning() or (ctx.agent:get() or {}).busy then
			return nil, nil, nil
		end
		local info = ctx.session:info()
		if info.ephemeral or info.readonly or info.unstable or ctx.session:switching() then
			return nil, nil, nil
		end
		qres = ctx.agent:list_queue()
		for _, entry in ipairs((qres and qres.data) or {}) do
			local id = entry.input_id
			if id and owned_inputs[id] then
				return nil, nil, nil
			end
		end
		local now = math.floor(mare.task.now())
		local skip = {}
		for id, until_ms in pairs(cooldown) do
			if until_ms > now then
				skip[id] = true
			else
				cooldown[id] = nil
			end
		end
		local group
		group, err = engine.reserve_due_group(instance, skip)
		if group and #group > 0 then
			local res, derr = deliver_group(group)
			if res and res.admitted then
				return res, nil, 0
			end
			local latest = engine.catalog()
			return nil, derr, latest and next_wait_ms(latest, math.floor(mare.task.now())) or 5000
		end
		return nil, err, next_wait_ms(catalog, math.floor(mare.task.now()))
	end
	return drive, { clear_cooldown = clear_cooldown }
end
