-- Durable definition service API.
local V = require("schedule.value")
local Timing = require("schedule.timing")

return function(ctx, cfg)
	local store = require("schedule.store")(ctx, cfg)
	local engine = require("schedule.engine")(ctx, cfg, store)
	local service = {}

	function engine.create_by(actor_session_id, raw, options)
		local valid, problem = V.options(options)
		if not valid then
			return nil, problem
		end
		local request = V.copy(raw)
		local ok, err = V.object(request, { title = true, prompt = true, timing = true, target = true })
		if not ok then
			return nil, err
		end
		local title, e = V.text(request.title, "title", 120)
		if not title then
			return nil, e
		end
		local prompt
		prompt, e = V.text(request.prompt, "prompt")
		if not prompt then
			return nil, e
		end
		local destination
		destination, e = store.target(request.target)
		if not destination then
			return nil, e
		end
		local now = math.floor(mare.task.now())
		local prepared
		prepared, e = Timing.normalize(request.timing, now)
		if not prepared then
			return nil, e
		end
		if not prepared.next_ms then
			return V.fail("not_future", "Timing has no future occurrence")
		end
		local id, timestamp = mare.crypto.uuid(), assert(V.iso(now))
		return store.mutate(function(data)
			local task = {
				revision = 1,
				record = {
					id = id,
					title = title,
					prompt = prompt,
					kind = prepared.timing.kind,
					scheduled_at = assert(V.iso(prepared.next_ms)),
				},
				timing = prepared.timing,
				pattern = prepared.pattern,
				target = destination,
				involved_session_ids = mare.json.array({}),
				status = "active",
				created_at = timestamp,
				updated_at = timestamp,
				delivery_history = {
					records = mare.json.array({}),
					earlier_records_unavailable = false,
					earlier_records_pruned = false,
				},
			}
			store.record_involved(task, destination.session_id)
			store.record_involved(task, actor_session_id)
			data.tasks[#data.tasks + 1] = task
			return true, task, nil, { change = "created", task = task, actor_session_id = actor_session_id }
		end, options and options.cancel, { change = "created", id = id })
	end

	function service.create(_, _, raw, options)
		return engine.create_by(nil, raw, options)
	end

	function service.list(_, _, request)
		request = V.copy(request or {})
		local ok, err = V.object(request, { active = true, limit = true, offset = true })
		if not ok then
			return nil, err
		end
		local limit, offset = request.limit or 100, request.offset or 0
		if
			not V.integer(limit, 1, 500)
			or not V.integer(offset, 0)
			or request.active ~= nil and type(request.active) ~= "boolean"
		then
			return V.fail("invalid_rule", "Invalid active filter or pagination")
		end
		local data
		data, err = store.read()
		if not data then
			return nil, err
		end
		local all = {}
		for _, task in ipairs(data.tasks) do
			if request.active == nil or (task.status == "active") == request.active then
				all[#all + 1] = task
			end
		end
		table.sort(all, function(a, b)
			return a.created_at == b.created_at and a.record.id < b.record.id or a.created_at < b.created_at
		end)
		local items = mare.json.array({})
		for i = offset + 1, math.min(#all, offset + limit) do
			items[#items + 1] = all[i]
		end
		return V.copy({ items = items, total = #all, shown = #items, limit = limit, offset = offset })
	end

	function service.view(_, _, request)
		request = V.copy(request)
		local ok, err = V.object(request, { id = true }, { "id" })
		if not ok then
			return nil, err
		end
		local data
		data, err = store.read()
		if not data then
			return nil, err
		end
		local task = store.find(data, request.id)
		if not task then
			return V.fail("schedule_not_found", "Unknown task")
		end
		local result = V.copy(task)
		result.recovery_required = result.reservation ~= nil
			and (result.reservation.phase == "submitting" or result.reservation.phase == "unknown")
		local limit = store.floor_end(task)
		if limit > mare.task.now() then
			result.delivery_floor_ends_at = assert(V.iso(limit))
		end
		return result
	end

	function engine.edit_by(actor_session_id, raw, options)
		local valid, problem = V.options(options)
		if not valid then
			return nil, problem
		end
		local request = V.copy(raw)
		local ok, err = V.object(
			request,
			{ id = true, action = true, patch = true, expected_updated_at = true },
			{ "id", "action" }
		)
		if not ok then
			return nil, err
		end
		if request.action ~= "update" and request.action ~= "delete" then
			return V.fail("invalid_selector", "Action must be update or delete")
		end
		local patch = request.patch or {}
		ok, err = V.object(patch, { title = true, prompt = true, timing = true, target = true, active = true })
		if not ok then
			return nil, err
		end
		if request.action == "update" and next(patch) == nil or request.action == "delete" and request.patch ~= nil then
			return V.fail("invalid_selector", "Update requires fields; delete rejects a patch")
		end
		return store.mutate(
			function(data)
				local task, index = store.find(data, request.id)
				if not task then
					return false, nil, { code = "schedule_not_found", message = "Unknown task" }
				end
				if request.expected_updated_at ~= nil and request.expected_updated_at ~= task.updated_at then
					return false, nil, { code = "schedule_conflict", message = "Task changed; reread before saving" }
				end
				if request.action == "delete" then
					local snapshot = V.copy(task)
					table.remove(data.tasks, index)
					return true,
						{ id = request.id, deleted = true },
						nil,
						{
							change = "deleted",
							task = snapshot,
							actor_session_id = actor_session_id,
						}
				end
				local now = math.floor(mare.task.now())
				local e
				if patch.title ~= nil then
					task.record.title, e = V.text(patch.title, "title", 120)
					if not task.record.title then
						return false, nil, e
					end
				end
				if patch.prompt ~= nil then
					task.record.prompt, e = V.text(patch.prompt, "prompt")
					if not task.record.prompt then
						return false, nil, e
					end
				end
				if patch.active ~= nil and type(patch.active) ~= "boolean" then
					return false, nil, { code = "invalid_rule", message = "active must be boolean" }
				end
				if patch.target ~= nil or patch.timing ~= nil or patch.active == true then
					local destination
					destination, e = store.target(patch.target or task.target)
					if not destination then
						return false, nil, e
					end
					task.target = destination
				end
				local changed = false
				if patch.timing ~= nil then
					local prepared
					prepared, e = Timing.normalize(patch.timing, now)
					if not prepared then
						return false, nil, e
					end
					changed = mare.json.encode_strict(prepared.timing) ~= mare.json.encode_strict(task.timing)
						or patch.timing.kind == "after"
					if changed then
						if not prepared.next_ms then
							return false, nil, { code = "not_future", message = "Timing has no future occurrence" }
						end
						task.timing, task.pattern, task.record.kind =
							prepared.timing, prepared.pattern, prepared.timing.kind
						task.record.scheduled_at = assert(V.iso(prepared.next_ms))
					end
				end
				if patch.active == true and not changed then
					local future
					future, e = V.next(task.pattern, now)
					if not future then
						return false,
							nil,
							e or { code = "not_future", message = "Supply new future timing before resuming" }
					end
					task.record.scheduled_at = assert(V.iso(future))
				end
				if patch.active == false then
					task.status = "paused"
				elseif patch.active == true or changed and task.status == "ended" then
					task.status = "active"
				end
				if
					task.reservation
					and task.reservation.phase ~= "rejected"
					and task.reservation.phase ~= "reserved"
				then
				-- The old admitted occurrence keeps its immutable snapshot across edits.
				else
					task.reservation = nil
				end
				store.record_involved(task, task.target.session_id)
				store.record_involved(task, actor_session_id)
				task.last_error = nil
				store.stamp(task, now)
				return true, task, nil, { change = "updated", task = task, actor_session_id = actor_session_id }
			end,
			options and options.cancel,
			{ change = request.action == "delete" and "deleted" or "updated", id = request.id }
		)
	end

	function service.edit(_, _, raw, options)
		return engine.edit_by(nil, raw, options)
	end

	function service.history(_, _, request)
		request = V.copy(request)
		local ok, err = V.object(request, { id = true, limit = true, before = true }, { "id", "limit" })
		if not ok then
			return nil, err
		end
		if not V.integer(request.limit, 1, 100) then
			return V.fail("invalid_rule", "History limit must be 1..100")
		end
		if request.before ~= nil and type(request.before) ~= "string" then
			return V.fail("invalid_rule", "History cursor must be text")
		end
		local task
		task, err = service.view(nil, nil, { id = request.id })
		if not task then
			return nil, err
		end
		local records = task.delivery_history.records
		local index = #records
		if request.before ~= nil then
			local found = false
			for i, r in ipairs(records) do
				if r.message_id == request.before then
					index = i - 1
					found = true
					break
				end
			end
			if not found then
				return V.fail("delivery_cursor_not_found", "Unknown saved receipt cursor")
			end
		end
		local page = mare.json.array({})
		for i = index, math.max(1, index - request.limit + 1), -1 do
			page[#page + 1] = records[i]
		end
		return {
			id = request.id,
			records = page,
			earlier_records_unavailable = task.delivery_history.earlier_records_unavailable,
			earlier_records_pruned = task.delivery_history.earlier_records_pruned,
			retention = { days = cfg.delivery_history_days, records = cfg.delivery_history_records },
			next_before = index > #page and page[#page].message_id or nil,
		}
	end

	function service.delete_inactive(_, _, options)
		local valid, problem = V.options(options)
		if not valid then
			return nil, problem
		end
		return store.mutate(function(data)
			local count = 0
			for i = #data.tasks, 1, -1 do
				if data.tasks[i].status == "ended" then
					table.remove(data.tasks, i)
					count = count + 1
				end
			end
			return count > 0, { deleted = count }
		end, options and options.cancel, { change = "delete_inactive" })
	end

	function service.run(_, _, request, options)
		local valid, problem = V.options(options)
		if not valid then
			return nil, problem
		end
		request = V.copy(request)
		local live, lerr = store.available(options and options.cancel)
		if not live then
			return nil, lerr
		end
		local ok, err = V.object(request, { id = true }, { "id" })
		if not ok then
			return nil, err
		end
		local task
		task, err = service.view(nil, nil, request)
		if not task then
			return nil, err
		end
		if task.target.session_id ~= ctx.session:info().session_id then
			return V.fail("target_unavailable", "The selected target is not the current runtime")
		end
		if store.floor_end(task) > mare.task.now() then
			return { id = request.id, admitted = false, delivery_floor_ends_at = assert(V.iso(store.floor_end(task))) }
		end
		task, err = engine.reserve_due(mare.crypto.uuid(), request.id, options and options.cancel)
		if not task then
			if not err then
				local latest = service.view(nil, nil, request)
				if latest and latest.delivery_floor_ends_at then
					return {
						id = request.id,
						admitted = false,
						delivery_floor_ends_at = latest.delivery_floor_ends_at,
					}
				end
				return V.fail("schedule_unavailable", "Task could not be reserved for delivery")
			end
			return nil, err
		end
		if not engine.deliver then
			return V.fail("delivery_unavailable", "The input receipt adapter is unavailable")
		end
		return engine.deliver(task, options and options.cancel)
	end

	function service.delivery_limits()
		return {
			minimum_seconds = 60,
			new_session_interval_seconds = cfg.new_session_interval_seconds,
			delivery_available = require("mare_lib").callable(ctx.agent.enqueue)
				and require("mare_lib").callable(ctx.agent.resume_input),
			background_targets_available = false,
		}
	end

	return service, engine
end
