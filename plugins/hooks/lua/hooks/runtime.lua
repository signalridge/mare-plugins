-- Both dialects share process, matching and failure rules; adapters own event semantics.
local TOOL_ALIAS_GROUPS = {
	{ "bash", "Bash", "shell", "exec_command", "run_command" },
	{ "read", "Read", "read_file", "view_file" },
	{ "edit", "Edit", "edit_file", "apply_patch", "MultiEdit" },
	{ "write", "Write", "write_file", "create_file" },
	{ "glob", "Glob", "find_by_name", "list_dir" },
	{ "grep", "Grep", "grep_search", "search" },
	{ "web_fetch", "WebFetch", "fetch" },
	{ "web_search", "WebSearch", "search_web" },
}
local TOOL_ALIASES = {}
local CLAUDE_TOOL_NAMES = {}
for _, group in ipairs(TOOL_ALIAS_GROUPS) do
	local canonical = group[2]
	for _, name in ipairs(group) do
		TOOL_ALIASES[name] = group
		if name ~= "MultiEdit" then
			CLAUDE_TOOL_NAMES[name] = canonical
		end
	end
end

local function matches_single(command, target)
	if command.literal then
		-- exact alternatives split on "|", empty ones included
		for alternative in (command.matcher .. "|"):gmatch("([^|]*)|") do
			if alternative == target then
				return true
			end
		end
		return false
	elseif command.regex then
		return command.regex:is_match(target)
	end
	return true
end

local function matches_subject(command, event, subject)
	if command.matcher == nil or command.matcher == "" or command.matcher == "*" then
		return true
	end
	if matches_single(command, subject) then
		return true
	end
	if event == "PreToolUse" or event == "PostToolUse" or event == "PermissionRequest" then
		local aliases = TOOL_ALIASES[subject]
		if aliases then
			for _, alias in ipairs(aliases) do
				if alias ~= subject and matches_single(command, alias) then
					return true
				end
			end
		end
	end
	return false
end

local spill = require("hooks.spill")

local MAX_CONCURRENT_ASYNC_HOOKS = 8
local MAX_QUEUED_ASYNC_HOOKS = 64
local MAX_QUEUED_ASYNC_BYTES = 4 * 1024 * 1024

return function(ctx, commands, turn, state)
	local active_runs, recent_runs, replayed_runs = {}, {}, {}
	local next_run_id, working_owned = 0, false
	local lifetime = mare.task and type(mare.task.token) == "function" and mare.task.token() or nil
	local session_token = lifetime and lifetime:child() or nil
	local current_session_key
	local disposed = false
	local async_running = 0
	local async_queue = {}
	local async_head, async_tail = 1, 0
	local async_queued_count, async_queued_bytes = 0, 0
	local dispatcher_woken = false
	local async_tasks = {}
	local async_tx, async_rx, dispatcher_task
	local async_initialized = false
	local active_command_set = {}
	for _, cmd in ipairs(commands) do
		active_command_set[cmd] = true
	end

	local function now_ms()
		if mare.task and type(mare.task.now) == "function" then
			return mare.task.now()
		end
		return nil
	end

	local function ui_connected()
		return mare.ui and type(mare.ui.connected) == "function" and mare.ui.connected()
	end

	local function ui_notify(text, level)
		if mare.ui and type(mare.ui.notify) == "function" then
			pcall(mare.ui.notify, text, level or "warning")
		end
	end

	local function current_owner()
		if not (ctx.session and require("mare_lib").callable(ctx.session.info)) then
			return nil, nil
		end
		local ok, info = pcall(ctx.session.info, ctx.session)
		if not ok or type(info) ~= "table" then
			return nil, nil
		end
		return info.session_id, info.session_epoch
	end

	local function owner_key(id, gen)
		return tostring(id or "") .. "\0" .. tostring(gen or "")
	end

	local function same_owner(expected_id, expected_gen)
		if disposed then
			return false
		end
		local cur_id, cur_gen = current_owner()
		return cur_id == expected_id and cur_gen == expected_gen
	end

	local function refresh_working()
		if not (ui_connected() and type(mare.ui.working) == "function") then
			return
		end
		local active_msg
		for _, item in pairs(active_runs) do
			if item.status_message and item.status_message ~= "" then
				active_msg = item.status_message
				break
			end
		end
		if active_msg then
			working_owned = true
			pcall(mare.ui.working, active_msg)
		elseif working_owned then
			working_owned = false
			pcall(mare.ui.working, nil)
		end
	end

	local function rotate_session_token()
		local cur_id, cur_gen = current_owner()
		local key = owner_key(cur_id, cur_gen)
		if current_session_key == nil then
			current_session_key = key
			return
		end
		if current_session_key == key then
			return
		end
		current_session_key = key
		if session_token then
			pcall(session_token.cancel, session_token)
			session_token = lifetime and lifetime:child() or nil
		end
		local kept = {}
		local kept_tail, kept_bytes = 0, 0
		for i = async_head, async_tail do
			local job = async_queue[i]
			async_queue[i] = nil
			if job and job.owner_id == cur_id and job.owner_gen == cur_gen and active_command_set[job.command] then
				kept_tail = kept_tail + 1
				kept[kept_tail] = job
				kept_bytes = kept_bytes + (job.payload_bytes or 0)
			end
		end
		async_queue = kept
		async_head, async_tail = 1, kept_tail
		async_queued_count, async_queued_bytes = kept_tail, kept_bytes
		for run_id, item in pairs(active_runs) do
			if item.async and (item.owner_id ~= cur_id or item.owner_gen ~= cur_gen) then
				active_runs[run_id] = nil
			end
		end
		refresh_working()
	end

	local function copy_array(list)
		local out = mare.json and type(mare.json.array) == "function" and mare.json.array({}) or {}
		for i, item in ipairs(list) do
			local row = {}
			for k, v in pairs(item) do
				row[k] = v
			end
			out[i] = row
		end
		return out
	end

	if ctx.agent and require("mare_lib").callable(ctx.agent.register_activity) then
		ctx.agent:register_activity("hooks", function()
			local active = mare.json and type(mare.json.array) == "function" and mare.json.array({}) or {}
			for _, item in pairs(active_runs) do
				active[#active + 1] = {
					id = item.id,
					label = item.label,
					event = item.event,
					async = item.async,
					status_message = item.status_message,
					started_at = item.started_at,
				}
			end
			if #active == 0 and #recent_runs == 0 and #replayed_runs == 0 then
				return nil
			end
			return {
				active = active,
				recent = copy_array(recent_runs),
				replayed = copy_array(replayed_runs),
			}
		end)
	end

	ctx:on("session/loaded", function()
		rotate_session_token()
		replayed_runs = {}
		if not (ctx.session and require("mare_lib").callable(ctx.session.list_records)) then
			return
		end
		local ok, recs = pcall(require("mare_lib").all_records, ctx.session, "hooks/audit")
		if not ok or type(recs) ~= "table" or #recs == 0 then
			return
		end
		local counts = { completed = 0, blocked = 0, failed = 0 }
		for _, rec in ipairs(recs) do
			if type(rec) == "table" then
				local entry = {
					id = rec.id,
					label = rec.label,
					event = rec.event,
					async = rec.async,
					status = rec.status or "completed",
					status_message = rec.status_message,
					duration_ms = rec.duration_ms,
					reason = rec.reason,
					timestamp = rec.timestamp,
				}
				replayed_runs[#replayed_runs + 1] = entry
				if #replayed_runs > 20 then
					table.remove(replayed_runs, 1)
				end
				counts[entry.status] = (counts[entry.status] or 0) + 1
			end
		end
		if ui_connected() and #recs > 0 then
			ui_notify(
				string.format(
					"Replayed %d hook audit entry(s) (%d completed, %d blocked, %d failed)",
					#recs,
					counts.completed or 0,
					counts.blocked or 0,
					counts.failed or 0
				),
				"info"
			)
		end
	end) -- session/loaded: the session's own records are ready.

	local function cleanup_async_tasks(wait_drain)
		disposed = true
		async_queue = {}
		async_head, async_tail = 1, 0
		async_queued_count, async_queued_bytes = 0, 0
		dispatcher_woken = false
		if session_token then
			pcall(session_token.cancel, session_token)
		end
		if lifetime then
			pcall(lifetime.cancel, lifetime)
		end
		if async_tx and type(async_tx.send) == "function" then
			pcall(async_tx.send, async_tx, false)
		end
		local pending_tasks = {}
		for task in pairs(async_tasks) do
			pending_tasks[#pending_tasks + 1] = task
		end
		if wait_drain and #pending_tasks > 0 then
			local function wait_all()
				for _, task in ipairs(pending_tasks) do
					if type(task.wait) == "function" then
						pcall(task.wait, task)
					end
				end
			end
			if mare.task and type(mare.task.timeout) == "function" then
				pcall(mare.task.timeout, 3500, wait_all)
			else
				wait_all()
			end
		end
		for _, task in ipairs(pending_tasks) do
			local is_done = type(task.done) == "function" and select(2, pcall(task.done, task))
			if not is_done and type(task.abort) == "function" then
				pcall(task.abort, task)
			end
			async_tasks[task] = nil
		end
		if dispatcher_task then
			if wait_drain and type(dispatcher_task.wait) == "function" then
				if mare.task and type(mare.task.timeout) == "function" then
					pcall(mare.task.timeout, 200, dispatcher_task.wait, dispatcher_task)
				else
					pcall(dispatcher_task.wait, dispatcher_task)
				end
			end
			local is_done = type(dispatcher_task.done) == "function"
				and select(2, pcall(dispatcher_task.done, dispatcher_task))
			if not is_done and type(dispatcher_task.abort) == "function" then
				pcall(dispatcher_task.abort, dispatcher_task)
			end
			dispatcher_task = nil
		end
		active_runs = {}
		if working_owned and ui_connected() and type(mare.ui.working) == "function" then
			working_owned = false
			pcall(mare.ui.working, nil)
		end
	end

	-- one effect drains the async hooks when the plugin unloads (shutdown or reload): unload runs
	-- after every app/shutdown listener returned, and the drain is capped (3500 ms in
	-- cleanup_async_tasks), so background work cannot hold shutdown indefinitely.
	ctx:effect(function()
		return function()
			cleanup_async_tasks(true)
		end
	end)

	local function record_audit(command, event, vote, started_at, ended_at, owner_id, owner_gen)
		local outcome = vote.failed and "failed"
			or ((vote.decision == "deny" or vote.decision == "ask") and "blocked")
			or "completed"
		local entry = {
			id = command.id,
			label = command.label,
			event = event,
			async = command.runs_async or nil,
			status = outcome,
			status_message = command.status_message,
			reason = vote.reason,
			duration_ms = (started_at and ended_at) and math.max(0, ended_at - started_at) or nil,
			timestamp = ended_at,
		}
		recent_runs[#recent_runs + 1] = entry
		if #recent_runs > 20 then
			table.remove(recent_runs, 1)
		end
		if mare.mode ~= "child" and ctx.session and require("mare_lib").callable(ctx.session.add_record) then
			local rec_opts = (type(owner_id) == "string" and type(owner_gen) == "string")
					and { session_id = owner_id, session_epoch = owner_gen }
				or nil
			pcall(ctx.session.add_record, ctx.session, "hooks/audit", entry, rec_opts)
		end
	end

	local function build_invocation(command, event, fields)
		local session = not fields.session_id and ctx.session:info() or nil
		local model = ctx.llm:current()
		local payload = {
			session_id = fields.session_id or (session and session.session_id) or "",
			transcript_path = fields.transcript_path ~= nil and fields.transcript_path
				or (session and not session.ephemeral and (session.path or session.planned) or ""),
			cwd = fields.cwd or mare.cwd,
			hook_event_name = event,
			permission_mode = "default",
		}
		for key, value in pairs(fields) do
			if key ~= "turn_id" or command.source.dialect == "codex" then
				payload[key] = value
			end
		end
		if command.source.dialect == "claude-code" and type(payload.tool_name) == "string" then
			payload.tool_name = CLAUDE_TOOL_NAMES[payload.tool_name] or payload.tool_name
		end
		local env = {}
		if command.source.dialect == "codex" then
			payload.model = model and model.ref or ""
			if event ~= "SessionStart" and event ~= "SessionEnd" then
				payload.turn_id = fields.turn_id or tostring(turn())
			end
			if payload.transcript_path == "" then
				payload.transcript_path = mare.json.null
			end
		else
			env.CLAUDE_PROJECT_DIR, env.CLAUDE_PLUGIN_ROOT = mare.cwd, command.source.plugin_root
		end
		return payload, env
	end

	local function execute_prepared(command, event, payload, env, operation)
		local result = require("hooks.run")(command, payload, env, operation)
		if (event == "SessionStart" or event == "SessionEnd" or event == "PostCompact") and result.exit_code ~= 0 then
			error(event .. " hook exited with code " .. tostring(result.exit_code), 0)
		end
		if event == "Stop" and result.exit_code == 2 and result.stderr_summary == "" then
			error("Stop hook exited with code 2 without continuation feedback", 0)
		end
		if event == "PermissionRequest" and result.exit_code == 2 and result.stderr_summary == "" then
			error("PermissionRequest hook exited with code 2 without denial reason", 0)
		end
		if command.runs_async and result.exit_code == 2 then
			error(
				"hook failed with exit code 2" .. (result.stderr_summary ~= "" and ": " .. result.stderr_summary or ""),
				0
			)
		end
		return result.decision and result or require("hooks.output")(result.stdout, event)
	end

	local function run_async_job(job)
		if
			disposed
			or not active_command_set[job.command]
			or (job.cancel_token and job.cancel_token:is_cancelled())
			or not same_owner(job.owner_id, job.owner_gen)
		then
			return
		end
		next_run_id = next_run_id + 1
		local run_id = next_run_id
		local started_at = now_ms()
		active_runs[run_id] = {
			id = job.command.id,
			label = job.command.label,
			event = job.event,
			async = true,
			owner_id = job.owner_id,
			owner_gen = job.owner_gen,
			status_message = job.command.status_message,
			started_at = started_at,
		}
		refresh_working()
		local job_op = job.cancel_token and { cancel = job.cancel_token } or nil
		local ok, outcome = pcall(function()
			if state then
				local trusted, trust_err, cur_hash = state.is_trusted(job.command)
				if not trusted then
					error(trust_err or "hook handler requires trust confirmation", 0)
				end
				if job.expected_hash then
					if not cur_hash and state.current_hash then
						local cur_err
						cur_hash, cur_err = state.current_hash(job.command)
						if not cur_hash then
							error("plugin content verification failed: " .. tostring(cur_err or "unreadable plugin"), 0)
						end
					end
					if cur_hash and cur_hash ~= job.expected_hash then
						error("plugin contents changed while queued", 0)
					end
				end
			end
			return execute_prepared(job.command, job.event, job.payload, job.env, job_op)
		end)
		active_runs[run_id] = nil
		refresh_working()
		if
			disposed
			or (job.cancel_token and job.cancel_token:is_cancelled())
			or not same_owner(job.owner_id, job.owner_gen)
		then
			return
		end
		if not ok then
			local reason = tostring(outcome):match("[^\n]+")
			mare.log("warn", job.command.label .. ": " .. reason)
			ui_notify(job.command.label .. ": " .. reason, "warning")
			record_audit(
				job.command,
				job.event,
				{ decision = "allow", reason = reason, failed = true },
				started_at,
				now_ms(),
				job.owner_id,
				job.owner_gen
			)
			return
		end
		local failed_reason
		if outcome.context and outcome.context ~= "" then
			local capped, cap_err = spill.cap_context(outcome.context, 65536)
			if not capped then
				failed_reason = cap_err or "async hook context exceeds disclosure limit"
			elseif ctx.agent and require("mare_lib").callable(ctx.agent.notify) then
				local ok_notify, notify_err = pcall(ctx.agent.notify, ctx.agent, capped, { wake = false })
				if not ok_notify then
					failed_reason = tostring(notify_err):match("[^\n]+")
				end
			end
		end
		if failed_reason then
			mare.log("warn", job.command.label .. ": " .. failed_reason)
			record_audit(
				job.command,
				job.event,
				{ decision = "allow", reason = failed_reason, failed = true },
				started_at,
				now_ms(),
				job.owner_id,
				job.owner_gen
			)
			ui_notify(job.command.label .. ": " .. failed_reason, "warning")
		else
			record_audit(
				job.command,
				job.event,
				{ decision = "allow" },
				started_at,
				now_ms(),
				job.owner_id,
				job.owner_gen
			)
			if outcome.system_message and outcome.system_message ~= "" and not outcome.suppress_output then
				ui_notify(outcome.system_message, "warning")
			end
		end
	end

	local pump_async
	local function spawn_async_worker(job)
		async_running = async_running + 1
		local task_ref
		local function worker()
			local ok_err, err = pcall(run_async_job, job)
			if not ok_err and not disposed then
				mare.log("warn", (job.command.label or "async hook") .. ": " .. tostring(err))
			end
			async_running = math.max(0, async_running - 1)
			if task_ref then
				async_tasks[task_ref] = nil
			end
			pump_async()
		end
		local ok_spawn, spawned = pcall(mare.task.spawn, worker)
		if ok_spawn and spawned then
			task_ref = spawned
			local is_done = type(spawned.done) == "function" and select(2, pcall(spawned.done, spawned))
			if not is_done then
				async_tasks[spawned] = true
			end
		else
			async_running = math.max(0, async_running - 1)
			if not ok_spawn and not disposed then
				mare.log("warn", (job.command.label or "async hook") .. ": " .. tostring(spawned))
			end
		end
	end

	pump_async = function()
		while not disposed and async_running < MAX_CONCURRENT_ASYNC_HOOKS and async_head <= async_tail do
			local job = async_queue[async_head]
			async_queue[async_head] = nil
			async_head = async_head + 1
			if async_head > async_tail then
				async_queue = {}
				async_head, async_tail = 1, 0
			end
			if job then
				async_queued_count = math.max(0, async_queued_count - 1)
				async_queued_bytes = math.max(0, async_queued_bytes - (job.payload_bytes or 0))
				spawn_async_worker(job)
			end
		end
	end

	local function schedule_async(job)
		if disposed then
			return false, "hooks runtime disposed"
		end
		local ok_size, encoded = pcall(mare.json.encode_strict, job.payload)
		local payload_bytes = (ok_size and type(encoded) == "string") and #encoded or 0
		if async_queued_count >= MAX_QUEUED_ASYNC_HOOKS then
			return false, "async hook queue limit exceeded (" .. tostring(MAX_QUEUED_ASYNC_HOOKS) .. " pending)"
		end
		if (async_queued_bytes + payload_bytes) > MAX_QUEUED_ASYNC_BYTES then
			return false, "async hook queue byte limit exceeded (" .. tostring(MAX_QUEUED_ASYNC_BYTES) .. " bytes)"
		end
		job.payload_bytes = payload_bytes
		async_tail = async_tail + 1
		async_queue[async_tail] = job
		async_queued_count = async_queued_count + 1
		async_queued_bytes = async_queued_bytes + payload_bytes
		if async_tx and type(async_tx.send) == "function" then
			if not dispatcher_woken then
				dispatcher_woken = true
				local ok_send = pcall(async_tx.send, async_tx, true)
				if not ok_send then
					dispatcher_woken = false
				end
			end
		else
			pump_async()
		end
		return true
	end

	local function ensure_async_dispatcher()
		if async_initialized or disposed then
			return
		end
		local has_async = false
		for _, cmd in ipairs(commands) do
			if cmd.runs_async then
				has_async = true
				break
			end
		end
		if not has_async then
			return
		end
		async_initialized = true
		-- cancel the old session's async hooks before anything else reacts (was priority = 100)
		ctx:on("session/changed", rotate_session_token, { prepend = true })
		ctx:on("session/new", rotate_session_token, { prepend = true })
		if mare.task and type(mare.task.spawn) == "function" and type(mare.task.channel) == "function" then
			async_tx, async_rx = mare.task.channel()
			dispatcher_task = mare.task.spawn(function()
				while not disposed do
					local msg = async_rx:recv()
					dispatcher_woken = false
					if msg == nil or msg == false or disposed then
						break
					end
					pump_async()
				end
			end)
		end
	end

	local function sync_commands()
		local next_set = {}
		for _, cmd in ipairs(commands) do
			next_set[cmd] = true
		end
		active_command_set = next_set
		local kept = {}
		local kept_tail, kept_bytes = 0, 0
		for i = async_head, async_tail do
			local job = async_queue[i]
			async_queue[i] = nil
			if job and active_command_set[job.command] then
				kept_tail = kept_tail + 1
				kept[kept_tail] = job
				kept_bytes = kept_bytes + (job.payload_bytes or 0)
			end
		end
		async_queue = kept
		async_head, async_tail = 1, kept_tail
		async_queued_count, async_queued_bytes = kept_tail, kept_bytes
		ensure_async_dispatcher()
	end

	ensure_async_dispatcher()

	local function dispatch(event, subject, fields, operation)
		rotate_session_token()
		local final, contexts, seen_handlers = { decision = "allow", decided = false }, {}, {}
		local observer = event == "Stop"
			or event == "SessionStart"
			or event == "SessionEnd"
			or event == "PreCompact"
			or event == "PostCompact"
		local sync_commands, async_commands = {}, {}
		for _, command in ipairs(commands) do
			if
				command.event == event
				and (not command.unsupported_type or command.decision_event)
				and (not state or state.is_enabled(command))
			then
				local match_ok, matched = pcall(matches_subject, command, event, subject)
				if not match_ok then
					local reason = tostring(matched):match("[^\n]+")
					if observer then
						mare.log("warn", command.label .. ": " .. reason)
					else
						return { decision = "deny", reason = command.label .. ": " .. reason, failed = true }
					end
					matched = false
				end
				local deduped = false
				if matched and command.dedup_key then
					local prev_group = seen_handlers[command.dedup_key]
					if prev_group ~= nil and prev_group ~= command.group_id then
						deduped = true
					else
						seen_handlers[command.dedup_key] = command.group_id
					end
				end
				if matched and not deduped then
					if command.runs_async then
						async_commands[#async_commands + 1] = command
					else
						sync_commands[#sync_commands + 1] = command
					end
				end
			end
		end

		for _, command in ipairs(async_commands) do
			if not (mare.task and type(mare.task.spawn) == "function") then
				local reason = "async hook requires mare.task.spawn"
				mare.log("warn", command.label .. ": " .. reason)
				record_audit(command, event, { decision = "allow", reason = reason, failed = true }, now_ms(), now_ms())
			else
				local trusted, trust_err, expected_hash = true, nil, nil
				if state then
					trusted, trust_err, expected_hash = state.ensure_trusted(command)
				end
				if not trusted then
					local reason = tostring(trust_err or "hook handler requires trust confirmation")
					mare.log("warn", command.label .. ": " .. reason)
					ui_notify(command.label .. ": " .. reason, "warning")
					record_audit(
						command,
						event,
						{ decision = "allow", reason = reason, failed = true },
						now_ms(),
						now_ms()
					)
				else
					if not expected_hash and state and state.current_hash then
						expected_hash = state.current_hash(command)
					end
					local owner_id, owner_gen = current_owner()
					local payload, env = build_invocation(command, event, fields)
					local queued_ok, queue_err = schedule_async({
						command = command,
						event = event,
						payload = payload,
						env = env,
						expected_hash = expected_hash,
						owner_id = owner_id,
						owner_gen = owner_gen,
						cancel_token = session_token or lifetime,
					})
					if not queued_ok then
						local reason = tostring(queue_err or "async hook queue limit exceeded")
						mare.log("warn", command.label .. ": " .. reason)
						ui_notify(command.label .. ": " .. reason, "warning")
						record_audit(
							command,
							event,
							{ decision = "allow", reason = reason, failed = true },
							now_ms(),
							now_ms(),
							owner_id,
							owner_gen
						)
					end
				end
			end
		end

		local function run_one(command)
			next_run_id = next_run_id + 1
			local run_id = next_run_id
			local started_at = now_ms()
			active_runs[run_id] = {
				id = command.id,
				label = command.label,
				event = event,
				status_message = command.status_message,
				started_at = started_at,
			}
			refresh_working()
			local ok, vote = pcall(function()
				if command.unsupported_type then
					error(
						string.format(
							"%s hook of type %q from %s is not supported",
							event,
							command.unsupported_type,
							command.source_name or command.label
						),
						0
					)
				end
				if state then
					local trusted, trust_err = state.ensure_trusted(command)
					if not trusted then
						error(trust_err, 0)
					end
				end
				local payload, env = build_invocation(command, event, fields)
				return execute_prepared(command, event, payload, env, operation)
			end)
			active_runs[run_id] = nil
			refresh_working()
			if not ok then
				local reason = tostring(vote):match("[^\n]+")
				if observer then
					mare.log("warn", command.label .. ": " .. reason)
				end
				vote = { decision = observer and "allow" or "deny", reason = reason, failed = true }
			end
			record_audit(command, event, vote, started_at, now_ms())
			return vote
		end

		local votes = {}
		if #sync_commands > 1 and mare.task and type(mare.task.spawn) == "function" then
			local tasks = {}
			for i, command in ipairs(sync_commands) do
				tasks[i] = mare.task.spawn(function()
					return run_one(command)
				end)
			end
			for i, task in ipairs(tasks) do
				votes[i] = task:wait()
			end
		else
			for i, command in ipairs(sync_commands) do
				votes[i] = run_one(command)
			end
		end

		for i, vote in ipairs(votes) do
			local command = sync_commands[i]
			if vote.system_message and vote.system_message ~= "" and not vote.suppress_output then
				ui_notify(vote.system_message, "warning")
			end
			if vote.context then
				contexts[#contexts + 1] = vote.context
			end
			if vote.reason then
				vote.reason = command.label .. ": " .. vote.reason
			end
			if event == "PreCompact" and vote.decision == "deny" and not vote.abort then
				mare.log("warn", vote.reason or (command.label .. ": PreCompact hook denied"))
			elseif vote.decision == "deny" then
				if final.decision ~= "deny" then
					final = vote
				elseif vote.abort and not final.abort then
					final.abort = true
					if not final.reason or final.reason == "" then
						final.reason = vote.reason
					end
				end
			elseif vote.decision == "ask" then
				if final.decision ~= "deny" and final.decision ~= "ask" then
					final = vote
				end
			elseif vote.decided then
				final.decided = true
			end
		end
		final.context = #contexts > 0 and table.concat(contexts, "\n\n") or nil
		return final
	end

	return dispatch, sync_commands
end
