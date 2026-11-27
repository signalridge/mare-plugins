-- Durable reservation and receipt state machine.
local V = require("schedule.value")
local Timing = require("schedule.timing")

return function(ctx, cfg, store)
	local engine = {
		floor_end = store.floor_end,
		drain_notices = store.drain_notices,
	}

	local function is_recurring(task)
		local kind = task.record and task.record.kind
		return kind ~= "after" and kind ~= "at"
	end

	local function build_reservation(instance, task, now, occurrence, manual)
		local next_at, resolved_empty = nil, nil
		if not manual then
			if occurrence.next_ms ~= nil and occurrence.next_ms ~= mare.json.null then
				next_at = assert(V.iso(occurrence.next_ms))
			else
				resolved_empty = true
			end
		end
		return {
			id = mare.crypto.uuid(),
			owner = instance,
			phase = "reserved",
			prompt = task.record.prompt,
			pattern = V.copy(task.pattern),
			timing = V.copy(task.timing),
			target = V.copy(task.target),
			manual = manual,
			scheduled_at = task.record.scheduled_at,
			occurrence_at = assert(V.iso(occurrence.occurrence_ms)),
			reserved_at = assert(V.iso(now)),
			next_at = next_at,
			resolved_empty = resolved_empty,
			coalesced_count = not manual and occurrence.coalesced_count or nil,
			coalesced_capped = not manual and occurrence.coalesced_capped or nil,
		}
	end

	function engine.reserve_due(instance, manual_id, cancel)
		return store.mutate(function(data)
			local now = math.floor(mare.task.now())
			local info = ctx.session:info()
			for _, task in ipairs(data.tasks) do
				if
					(
						manual_id == task.record.id
						or not manual_id
							and task.status == "active"
							and assert(V.ms(task.record.scheduled_at)) <= now
					)
					and task.target.session_id == info.session_id
					and store.floor_end(task) <= now
				then
					if
						task.reservation
						and (task.reservation.phase == "reserved" or task.reservation.phase == "rejected")
					then
						task.reservation = nil
					end
					if task.reservation then
						if manual_id then
							return false,
								nil,
								{
									code = "recovery_required",
									message = "An outstanding reservation needs reconciliation before another delivery",
								}
						end
					else
						local occurrence, e
						if manual_id then
							occurrence = { occurrence_ms = now }
						else
							occurrence, e = Timing.resolve(task, now)
						end
						if not occurrence then
							return false, nil, e
						end
						task.reservation = build_reservation(instance, task, now, occurrence, manual_id ~= nil)
						store.stamp(task, now)
						return true, task
					end
				end
			end
			return false, nil
		end, cancel, { source = "delivery", change = "reserve", id = manual_id })
	end

	function engine.reserve_due_group(instance, skip_ids, cancel)
		return store.mutate(function(data)
			local now = math.floor(mare.task.now())
			local info = ctx.session:info()
			local candidates = {}
			for index, task in ipairs(data.tasks) do
				local scheduled_ms = assert(V.ms(task.record.scheduled_at))
				local has_pending = task.reservation
					and task.reservation.phase ~= "reserved"
					and task.reservation.phase ~= "rejected"
				if
					task.status == "active"
					and scheduled_ms <= now
					and task.target.session_id == info.session_id
					and store.floor_end(task) <= now
					and not (skip_ids and skip_ids[task.record.id])
					and not has_pending
				then
					candidates[#candidates + 1] = { task = task, scheduled_ms = scheduled_ms, index = index }
				end
			end
			if #candidates == 0 then
				return false, nil
			end
			table.sort(candidates, function(a, b)
				if a.scheduled_ms ~= b.scheduled_ms then
					return a.scheduled_ms < b.scheduled_ms
				end
				return a.index < b.index
			end)
			local head = candidates[1].task
			local chosen = { head }
			if is_recurring(head) then
				for i = 2, #candidates do
					if #chosen >= 64 then
						break
					end
					if is_recurring(candidates[i].task) then
						chosen[#chosen + 1] = candidates[i].task
					end
				end
			end
			local reserved = {}
			for _, task in ipairs(chosen) do
				local occurrence, e = Timing.resolve(task, now)
				if not occurrence then
					return false, nil, e
				end
				task.reservation = build_reservation(instance, task, now, occurrence, false)
				store.stamp(task, now)
				reserved[#reserved + 1] = task
			end
			return true, reserved
		end, cancel, { source = "delivery", change = "reserve" })
	end

	function engine.submitting_batch(pairs)
		return store.mutate(function(data)
			local now = math.floor(mare.task.now())
			local updated = {}
			for _, pair in ipairs(pairs) do
				local task = store.find(data, pair.id)
				if not task or not task.reservation or task.reservation.id ~= pair.reservation then
					return false, nil, { code = "stale_reservation", message = "Reservation changed" }
				end
				if task.reservation.phase ~= "reserved" then
					return false,
						nil,
						{ code = "recovery_required", message = "Submission outcome requires reconciliation" }
				end
			end
			for _, pair in ipairs(pairs) do
				local task = store.find(data, pair.id)
				task.reservation.phase = "submitting"
				store.stamp(task, now)
				updated[#updated + 1] = task
			end
			return true, updated
		end, nil, { source = "delivery", change = "submitting" })
	end

	function engine.submitting(id, reservation)
		local res, err = engine.submitting_batch({ { id = id, reservation = reservation } })
		if not res then
			return nil, err
		end
		return res[1]
	end

	function engine.failed_batch(pairs, code, message, known_rejected)
		return store.mutate(function(data)
			local now = math.floor(mare.task.now())
			local changed = false
			local updated = {}
			for _, pair in ipairs(pairs) do
				local task = store.find(data, pair.id)
				if task and task.reservation and task.reservation.id == pair.reservation then
					task.reservation.phase = known_rejected and "rejected" or "unknown"
					task.last_error = { code = code, message = message, at = assert(V.iso(now)) }
					store.stamp(task, now)
					updated[#updated + 1] = task
					changed = true
				end
			end
			if not changed then
				return false, nil
			end
			return true, updated
		end, nil, { source = "delivery", change = "failed" })
	end

	function engine.failed(id, reservation, code, message, known_rejected)
		local res, err = engine.failed_batch({ { id = id, reservation = reservation } }, code, message, known_rejected)
		if not res then
			return nil, err
		end
		return res[1]
	end

	function engine.reconcile_absent(id, reservation)
		return store.mutate(function(data)
			local task = store.find(data, id)
			if not task or not task.reservation or task.reservation.id ~= reservation then
				return false, nil
			end
			if task.reservation.phase ~= "unknown" and task.reservation.phase ~= "submitting" then
				return false, nil
			end
			local now = math.floor(mare.task.now())
			task.reservation = nil
			store.stamp(task, now)
			return true, task
		end, nil, { source = "delivery", change = "reconciled_absent", id = id })
	end

	local function has_receipt(task, input_id)
		for _, record in ipairs(task.delivery_history.records) do
			if record.message_id == input_id then
				return true
			end
		end
		return false
	end

	function engine.acknowledge_batch(pairs, receipt)
		assert(
			receipt.status == "queued" and receipt.durable == true and type(receipt.input_id) == "string",
			"A real durable input receipt is required"
		)
		return store.mutate(function(data)
			local now = math.floor(mare.task.now())
			local changed = false
			local out = {}
			for _, pair in ipairs(pairs) do
				local task = store.find(data, pair.id)
				if not task then
					return false, nil
				end
				if has_receipt(task, receipt.input_id) then
					if task.reservation and task.reservation.id == pair.reservation then
						task.reservation, task.last_error = nil, nil
						store.stamp(task, now)
						changed = true
					end
					out[#out + 1] = task
				else
					local reserved = task.reservation
					if not reserved or reserved.id ~= pair.reservation then
						return false,
							nil,
							{
								code = "stale_reservation",
								message = "Cannot attach an old receipt to a new reservation",
							}
					end
					local saved = {
						message_id = receipt.input_id,
						input_id = receipt.input_id,
						target_session_id = receipt.session_id,
						scheduled_at = reserved.occurrence_at,
						delivered_at = assert(V.iso(now)),
						prompt = reserved.prompt,
					}
					task.delivery_history.records[#task.delivery_history.records + 1] = saved
					task.last_delivery = V.copy(saved)
					local records = task.delivery_history.records
					for index = #records - 1, 1, -1 do
						if assert(V.ms(records[index].delivered_at)) < now - cfg.delivery_history_days * 86400000 then
							table.remove(records, index)
							task.delivery_history.earlier_records_pruned = true
						end
					end
					while #records > cfg.delivery_history_records do
						table.remove(records, 1)
						task.delivery_history.earlier_records_pruned = true
					end
					if
						not reserved.manual
						and mare.json.encode_strict(task.timing) == mare.json.encode_strict(reserved.timing)
					then
						local future, e
						if reserved.next_at ~= nil then
							future = assert(V.ms(reserved.next_at))
						elseif reserved.resolved_empty == true then
							future = nil
						else
							local floor_ms =
								math.max(now, assert(V.ms(reserved.occurrence_at)), assert(V.ms(reserved.reserved_at)))
							future, e = V.next(reserved.pattern, floor_ms)
						end
						if e then
							return false, nil, e
						end
						if future then
							task.record.scheduled_at = assert(V.iso(future))
						elseif task.status == "active" then
							task.status = "ended"
						end
					end
					task.reservation, task.last_error = nil, nil
					store.stamp(task, now)
					changed = true
					out[#out + 1] = task
				end
			end
			if not changed then
				return false, out
			end
			return true, out
		end, nil, { source = "delivery", change = "acknowledge" })
	end

	function engine.acknowledge(id, reservation, receipt)
		local res, err = engine.acknowledge_batch({ { id = id, reservation = reservation } }, receipt)
		if not res then
			return nil, err
		end
		return res[1]
	end

	function engine.catalog()
		local data, err = store.read()
		if not data then
			return nil, err
		end
		return V.copy(data.tasks)
	end

	return engine
end
