-- Strict v1 definition codec, independent from writers and delivery.
local V = require("schedule.value")
local Timing = require("schedule.timing")
local function target(value)
	assert(type(value) == "table", "Invalid target")
	if value.kind == "session" then
		assert(
			V.object(value, { kind = true, session_id = true }, { "session_id" })
				and type(value.session_id) == "string"
				and value.session_id ~= "",
			"Invalid session target"
		)
	else
		assert(value.kind == "new" or value.kind == "new_once", "Unknown target kind")
		assert(
			V.object(value, { kind = true, session_id = value.kind == "new_once", create = true }),
			"Invalid creating target"
		)
		if value.kind == "new_once" then
			assert(type(value.session_id) == "string" and value.session_id ~= "", "Invalid reserved target ID")
		end
		if value.create then
			assert(V.object(value.create, { cwd = true, agent_preset = true }), "Invalid target creation options")
			assert(value.create.cwd == nil or type(value.create.cwd) == "string", "Invalid target cwd")
			assert(
				value.create.agent_preset == nil or type(value.create.agent_preset) == "string",
				"Invalid target preset"
			)
		end
	end
end
return function(data)
	assert(
		type(data) == "table" and data.version == 1 and mare.json.is_array(data.tasks),
		"Unsupported or corrupt scheduler domain"
	)
	for key in pairs(data) do
		assert(key == "version" or key == "tasks", "Unknown scheduler domain field")
	end
	local ids = {}
	for _, task in ipairs(data.tasks) do
		assert(type(task) == "table" and type(task.record) == "table", "Invalid task")
		for key in pairs(task) do
			assert(
				({
					record = true,
					timing = true,
					pattern = true,
					target = true,
					status = true,
					created_at = true,
					updated_at = true,
					revision = true,
					delivery_history = true,
					last_delivery = true,
					reservation = true,
					last_error = true,
					involved_session_ids = true,
				})[key],
				"Unknown task field"
			)
		end
		local record = task.record
		assert(type(record.id) == "string" and record.id ~= "" and not ids[record.id], "Invalid/duplicate task ID")
		ids[record.id] = true
		assert(
			type(record.title) == "string"
				and type(record.prompt) == "string"
				and V.text(record.title, "title", 120) == record.title
				and V.text(record.prompt, "prompt") == record.prompt,
			"Invalid task text"
		)
		assert(
			V.object(
				record,
				{ id = true, kind = true, title = true, prompt = true, scheduled_at = true },
				{ "id", "kind", "title", "prompt", "scheduled_at" }
			),
			"Unknown record field"
		)
		assert(task.status == "active" or task.status == "paused" or task.status == "ended", "Invalid task status")
		assert(
			V.integer(task.revision, 1)
				and V.ms(task.created_at)
				and V.ms(task.updated_at)
				and V.ms(record.scheduled_at),
			"Invalid task revision/time"
		)
		assert(V.ms(task.updated_at) >= V.ms(task.created_at), "Task revision time predates creation")
		assert(task.timing.kind == record.kind, "Timing/record kind mismatch")
		target(task.target)
		assert(
			mare.time.query({ action = "next", pattern = task.pattern, after_ms = assert(V.ms(record.scheduled_at)) }),
			"Invalid stored pattern"
		)
		Timing.validate(task)
		assert(
			type(task.delivery_history) == "table" and mare.json.is_array(task.delivery_history.records),
			"Invalid history"
		)
		assert(
			V.object(
				task.delivery_history,
				{ records = true, earlier_records_unavailable = true, earlier_records_pruned = true }
			),
			"Unknown history field"
		)
		assert(
			type(task.delivery_history.earlier_records_unavailable) == "boolean"
				and type(task.delivery_history.earlier_records_pruned) == "boolean",
			"Invalid history availability flags"
		)
		local receipts = {}
		for _, receipt in ipairs(task.delivery_history.records) do
			assert(
				V.object(receipt, {
					message_id = true,
					input_id = true,
					target_session_id = true,
					scheduled_at = true,
					delivered_at = true,
					prompt = true,
				}),
				"Unknown receipt field"
			)
			assert(
				type(receipt.message_id) == "string"
					and type(receipt.target_session_id) == "string"
					and V.ms(receipt.scheduled_at)
					and V.ms(receipt.delivered_at),
				"Invalid delivery receipt"
			)
			assert(
				receipt.message_id ~= "" and receipt.target_session_id ~= "" and not receipts[receipt.message_id],
				"Empty/duplicate receipt identity"
			)
			receipts[receipt.message_id] = true
			assert(receipt.input_id == nil or receipt.input_id == receipt.message_id, "Input/message identity mismatch")
			assert(receipt.prompt == nil or type(receipt.prompt) == "string", "Invalid prompt snapshot")
		end
		local last = task.delivery_history.records[#task.delivery_history.records]
		assert(
			(last == nil and task.last_delivery == nil)
				or last ~= nil and mare.json.encode_strict(last) == mare.json.encode_strict(task.last_delivery),
			"Latest receipt/history disagreement"
		)
		if task.reservation then
			local r = task.reservation
			assert(
				V.object(r, {
					id = true,
					owner = true,
					phase = true,
					prompt = true,
					pattern = true,
					timing = true,
					target = true,
					manual = true,
					scheduled_at = true,
					occurrence_at = true,
					reserved_at = true,
					next_at = true,
					resolved_empty = true,
					coalesced_count = true,
					coalesced_capped = true,
				}),
				"Unknown reservation field"
			)
			assert(
				(r.next_at == nil or V.ms(r.next_at))
					and (r.resolved_empty == nil or type(r.resolved_empty) == "boolean")
					and (r.coalesced_count == nil or V.integer(r.coalesced_count, 0))
					and (r.coalesced_capped == nil or type(r.coalesced_capped) == "boolean"),
				"Invalid reservation coalescing metadata"
			)
			assert(
				type(task.reservation.id) == "string"
					and type(task.reservation.owner) == "string"
					and V.ms(task.reservation.occurrence_at),
				"Invalid reservation"
			)
			assert(
				r.phase == "reserved" or r.phase == "submitting" or r.phase == "rejected" or r.phase == "unknown",
				"Invalid reservation phase"
			)
			assert(
				type(r.prompt) == "string"
					and type(r.manual) == "boolean"
					and V.ms(r.reserved_at)
					and V.ms(r.scheduled_at),
				"Invalid reservation snapshot"
			)
			target(r.target)
			assert(
				mare.time.query({ action = "next", pattern = r.pattern, after_ms = assert(V.ms(r.occurrence_at)) }),
				"Invalid reserved pattern"
			)
		end
		if task.involved_session_ids ~= nil then
			assert(mare.json.is_array(task.involved_session_ids), "Invalid involved_session_ids")
			local seen_sessions = {}
			for _, sid in ipairs(task.involved_session_ids) do
				assert(
					type(sid) == "string" and sid ~= "" and not seen_sessions[sid],
					"Invalid/duplicate involved session ID"
				)
				seen_sessions[sid] = true
			end
		end
		if task.last_error then
			assert(V.object(task.last_error, { code = true, message = true, at = true }), "Unknown error field")
			assert(
				type(task.last_error.code) == "string"
					and type(task.last_error.message) == "string"
					and V.ms(task.last_error.at),
				"Invalid saved error"
			)
		end
	end
	return data
end
