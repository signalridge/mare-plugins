-- Schedule model management tools; CLI is a Mare UI adapter.
local V = require("schedule.value")
return function(ctx, domain, engine)
	local function invoke(method, args, tctx)
		if mare.agent_id then
			return {
				content = mare.json.encode({
					code = "subagent_session",
					message = "Delegated agents cannot manage scheduled tasks",
				}),
				is_error = true,
			}
		end
		local opts = tctx and { cancel = tctx.cancel }
		local by_actor = engine and (method == "create" or method == "edit") and engine[method .. "_by"]
		local result, err
		if by_actor then
			result, err = by_actor(ctx.session:info().session_id, args, opts)
		else
			result, err = domain[method](nil, nil, args, opts)
		end
		return { content = mare.json.encode(result or err), is_error = result == nil }
	end
	local function destination(choice)
		return choice == "current" and { kind = "session", session_id = ctx.session:info().session_id }
			or { kind = choice }
	end
	local function object(properties, required)
		return {
			type = "object",
			additionalProperties = false,
			properties = properties,
			required = mare.json.array(required or {}),
		}
	end
	local function register(name, description, parameters, method, adapt, read)
		ctx.tools:register(name, {
			description = description,
			side_effect = read and "read" or "write",
			idempotent = read == true,
			parameters = parameters,
			execute = function(args, tctx)
				return invoke(method, adapt and adapt(args) or args, tctx)
			end,
		})
	end
	register(
		"schedule_create",
		"Save a durable scheduled instruction for the current durable session. RRULE has DTSTART then RRULE; use COUNT=1 for a one-shot. For approximate recurring times (e.g. hourly or around top/half hour), prefer off-peak minutes rather than 0 or 30 to avoid thundering herds. Current durable session targets use native inbox receipts. A saved definition or reservation is not delivery, and an inbox receipt is not model completion.",
		object({
			title = { type = "string" },
			prompt = { type = "string" },
			rrule = { type = "string" },
			target = { type = "string", enum = { "current" } },
		}, { "title", "prompt", "rrule", "target" }),
		"create",
		function(a)
			return {
				title = a.title,
				prompt = a.prompt,
				timing = { kind = "rrule", rrule = a.rrule },
				target = destination(a.target),
			}
		end
	)
	register(
		"schedule_list",
		"List durable Host definitions with active filter and bounded pagination; not the temporary /loop list.",
		object({ active = { type = "boolean" }, limit = { type = "integer" }, offset = { type = "integer" } }),
		"list",
		nil,
		true
	)
	register(
		"schedule_view",
		"Read one durable definition, committed occurrence, target, outstanding reservation and delivery error. A reservation is not an input receipt.",
		object({ id = { type = "string" } }, { "id" }),
		"view",
		nil,
		true
	)
	register(
		"schedule_edit",
		"Edit title/prompt/RRULE/target, pause/resume, or delete a durable task. Send expected_updated_at from the latest view for CAS. Deletion stops future dispatch; it is not cancellation of a delivered message.",
		object({
			id = { type = "string" },
			action = { type = "string", enum = { "update", "delete" } },
			title = { type = "string" },
			prompt = { type = "string" },
			rrule = { type = "string" },
			target = { type = "string", enum = { "current" } },
			active = { type = "boolean" },
			expected_updated_at = { type = "string" },
		}, { "id", "action" }),
		"edit",
		function(a)
			local request = { id = a.id, action = a.action, expected_updated_at = a.expected_updated_at }
			local patch = {
				title = a.title,
				prompt = a.prompt,
				active = a.active,
				timing = a.rrule and { kind = "rrule", rrule = a.rrule },
				target = a.target and destination(a.target),
			}
			if a.action == "update" or next(patch) ~= nil then
				request.patch = patch
			end
			return request
		end
	)
	ctx.commands:register("schedule", {
		description = "Durable definitions: list/view/create/edit/history/pause/resume/delete/run; JSON inputs for creation/editing",
		args = "<action> [JSON|id]",
		run = function(raw)
			local action, body = raw:match("^(%S+)%s*(.-)%s*$")
			action = action or "list"
			local method, args = action, {}
			if action == "pause" or action == "resume" or action == "delete" then
				local task, err = domain.view(nil, nil, { id = body })
				if not task then
					mare.ui.notify(err.message, "error")
					return { status = "rejected", reason = err.message }
				end
				method = "edit"
				args = {
					id = body,
					action = action == "delete" and "delete" or "update",
					expected_updated_at = task.updated_at,
					patch = action ~= "delete" and { active = action == "resume" } or nil,
				}
			elseif action == "view" or action == "run" then
				args = { id = body }
			elseif action == "history" then
				args = { id = body, limit = 20 }
			elseif action == "delete-inactive" then
				method = "delete_inactive"
			elseif action ~= "list" and action ~= "create" and action ~= "edit" and action ~= "limits" then
				mare.ui.notify("Unknown schedule action", "error")
				return { status = "rejected", reason = "Unknown action" }
			elseif action == "limits" then
				method = "delivery_limits"
			elseif body and body ~= "" then
				local decoded, err = mare.json.decode_lossless(body)
				if not decoded then
					mare.ui.notify(tostring(err), "error")
					return { status = "rejected", reason = tostring(err) }
				end
				args = decoded
			end
			local result, err = domain[method](nil, nil, args)
			mare.ui.notify(
				result
						and "Definition/history data (inbox receipt is not execution completion):\n" .. mare.json.encode(
							result
						)
					or err.code .. ": " .. err.message,
				result and "info" or "error"
			)
			return result and { status = "completed" } or { status = "rejected", reason = err.message }
		end,
	})
end
