local config = require("workflow.config")
local schema = require("workflow.schema")
local events = require("workflow.events")
local records = require("workflow.records")
local vm = require("workflow.vm")

local M = {}

local ALLOWED_AGENT_OPTS = {
	label = true,
	phase = true,
	provider = true,
	model = true,
	effort = true,
	schema = true,
	tools = true,
	system = true,
	cwd = true,
}

local function now_ms()
	return mare and mare.task and mare.task.now and math.floor(mare.task.now()) or 0
end

local function is_plain_object(v)
	return type(v) == "table" and not (mare and mare.json and mare.json.is_array and mare.json.is_array(v))
end

local function truncate_chars(text, max_chars)
	if type(text) ~= "string" then
		return "", 0
	end
	local len = utf8.len(text)
	if len and len <= max_chars then
		return text, 0
	end
	if not len and #text <= max_chars then
		return text, 0
	end
	local cut = mare and mare.text and mare.text.cut and mare.text.cut(text, max_chars, { unit = "chars" })
		or text:sub(1, max_chars)
	local kept_len = utf8.len(cut) or #cut
	local total_len = len or #text
	return cut, math.max(0, total_len - kept_len)
end

local function first_nonempty_line(text)
	if type(text) ~= "string" then
		return nil
	end
	for line in text:gmatch("[^\r\n]+") do
		local trimmed = line:match("^%s*(.-)%s*$")
		if trimmed ~= "" then
			return trimmed
		end
	end
	return nil
end

local MAX_RUN_LOGS = 500
local MAX_LOG_CHARS = 4096

local function make_semaphore(limit)
	local active = 0
	local unconfirmed = 0
	local exhausted = false
	local waiters = {}

	local function wake_next()
		while #waiters > 0 do
			local entry = table.remove(waiters, 1)
			if not entry.cancelled and entry.tx:send(true) then
				return true
			end
		end
		return false
	end

	local function acquire(cancel)
		while active >= limit do
			if exhausted then
				return false, "exhausted"
			end
			if cancel and cancel:is_cancelled() then
				return false
			end
			local tx, rx = mare.task.channel(1)
			local entry = { tx = tx, cancelled = false, rejected = false }
			waiters[#waiters + 1] = entry
			local idx = mare.task.select(function()
				rx:recv()
				return true
			end, function()
				cancel:wait()
				return false
			end)
			if exhausted or entry.rejected then
				return false, "exhausted"
			end
			if idx == 2 or (cancel and cancel:is_cancelled()) then
				entry.cancelled = true
				for i = #waiters, 1, -1 do
					if waiters[i] == entry then
						table.remove(waiters, i)
						break
					end
				end
				if (idx == 1 or (rx.try_recv and rx:try_recv() ~= nil)) and active < limit then
					wake_next()
				end
				return false
			end
		end
		if exhausted then
			return false, "exhausted"
		end
		active = active + 1
		return true
	end

	local function release()
		if active > 0 then
			active = active - 1
		end
		if not exhausted and active < limit then
			wake_next()
		end
	end

	-- When a child times out without stop confirmation, it retains its occupied
	-- semaphore slot permanently. Once all slots are occupied by unconfirmed
	-- children, wake and reject all queued waiters instead of hanging forever.
	local function mark_unconfirmed()
		unconfirmed = unconfirmed + 1
		if unconfirmed >= limit then
			exhausted = true
			while #waiters > 0 do
				local entry = table.remove(waiters, 1)
				if not entry.cancelled then
					entry.rejected = true
					entry.tx:send(true)
				end
			end
		end
	end

	return { acquire = acquire, release = release, mark_unconfirmed = mark_unconfirmed }
end

local function make_job_buffer(max_bytes)
	local chunks = {}
	local total = 0
	local dropped = 0
	local read_pos = 0
	local limit = max_bytes or (512 * 1024)

	local function full_text()
		return table.concat(chunks)
	end

	local function utf8_cut_bytes(text, bytes, keep)
		if bytes <= 0 or text == "" then
			return ""
		end
		if mare and mare.text and type(mare.text.cut) == "function" then
			return mare.text.cut(text, bytes, { keep = keep, unit = "bytes" })
		end
		if #text <= bytes then
			return text
		end
		if keep == "tail" then
			return text:sub(#text - bytes + 1)
		end
		return text:sub(1, bytes)
	end

	local function utf8_next_char_start(text, idx)
		local len = #text
		while idx <= len do
			local b = text:byte(idx)
			if b < 0x80 or b >= 0xC0 then
				return idx
			end
			idx = idx + 1
		end
		return len + 1
	end

	local function append(line)
		local s = tostring(line)
		if not s:match("\n$") then
			s = s .. "\n"
		end
		chunks[#chunks + 1] = s
		total = total + #s
		local joined = full_text()
		if #joined > limit then
			local before_len = #joined
			joined = utf8_cut_bytes(joined, limit, "tail")
			dropped = dropped + (before_len - #joined)
			chunks = { joined }
		end
	end

	local function read_at(offset, opts)
		local text = full_text()
		local base = total - #text
		local start_abs = math.max(base, tonumber(offset) or 0)
		local rel = utf8_next_char_start(text, start_abs - base + 1)
		start_abs = base + rel - 1
		local slice = rel <= #text and text:sub(rel) or ""
		local cap = opts and tonumber(opts.max_bytes)
		if cap ~= nil then
			if cap < 4 then
				error("max_bytes must be at least 4 to fit a UTF-8 character", 0)
			end
			if #slice > cap then
				slice = utf8_cut_bytes(slice, cap, "head")
			end
		end
		return {
			text = slice,
			next = start_abs + #slice,
			dropped = start_abs > (tonumber(offset) or 0) and (start_abs - (tonumber(offset) or 0)) or 0,
		}
	end

	local function read_consuming(opts)
		local r = read_at(read_pos, opts)
		read_pos = r.next
		return {
			text = r.text,
			dropped = r.dropped,
			done = false,
		}
	end

	local function tail(n)
		local text = full_text()
		local bytes = tonumber(n) or 4096
		if #text <= bytes then
			return text
		end
		return utf8_cut_bytes(text, bytes, "tail")
	end

	return {
		append = append,
		read_at = read_at,
		read_consuming = read_consuming,
		tail = tail,
		stats = function()
			return total, math.max(0, total - read_pos)
		end,
	}
end

local function parse_structured_output(res, compiled_schema, max_chars)
	local value = nil
	if type(res.text) == "string" and res.text ~= "" then
		local ok, decoded = pcall(mare.json.decode_lossless, res.text)
		if ok and type(decoded) == "table" then
			value = decoded
		end
	end
	if value == nil then
		value = res.structured
	end
	if value == nil then
		return nil, "subagent did not produce structured JSON matching schema"
	end
	local ok_val, err = schema.validate_value(compiled_schema, value)
	if not ok_val then
		return nil, "schema validation failed: " .. tostring(err)
	end
	if max_chars and max_chars > 0 and mare and mare.json and type(mare.json.encode) == "function" then
		local ok_enc, encoded = pcall(mare.json.encode, value)
		if ok_enc and type(encoded) == "string" then
			local clen = utf8.len(encoded) or #encoded
			if clen > max_chars then
				return nil, ("structured output exceeds child_result_chars limit (%d > %d)"):format(clen, max_chars)
			end
		end
	end
	return value
end

local function default_spawn_runner(spawn_opts, opts)
	local spawn_fn = mare and mare.subagent and mare.subagent.start
	if type(spawn_fn) ~= "function" then
		return { ok = false, status = "failed", error = "mare.subagent.start is unavailable" }
	end
	local ok, handle_or_err = pcall(spawn_fn, spawn_opts)
	if not ok then
		return { ok = false, status = "failed", error = tostring(handle_or_err) }
	end
	local handle = handle_or_err
	local active = true
	if opts.on_handle then
		opts.on_handle(handle)
	end

	local ev_task = nil
	if type(handle.next_event) == "function" and opts.on_event then
		ev_task = mare.task.spawn(function()
			while active do
				local ok_ev, ev = pcall(handle.next_event, handle)
				if not ok_ev or not ev then
					break
				end
				opts.on_event(ev)
			end
		end)
	end

	local wait_settled = false
	local wait_ok, res = nil, nil
	local wait_task = mare.task.spawn(function()
		local wok, wres = pcall(handle.wait, handle)
		wait_ok, res = wok, wres
		wait_settled = true
		return wok, wres
	end)

	local timeout_ms = opts.timeout_ms
	local cancel = opts.cancel
	local done

	if timeout_ms and timeout_ms > 0 then
		local finished, idx = mare.task.timeout(timeout_ms, function()
			return mare.task.select(function()
				wait_task:wait()
				return true
			end, function()
				cancel:wait()
				return false
			end)
		end)
		if not finished then
			done = "timed_out"
		elseif idx == 2 then
			done = "cancelled"
		else
			done = "settled"
		end
	else
		local idx = mare.task.select(function()
			wait_task:wait()
			return true
		end, function()
			cancel:wait()
			return false
		end)
		if idx == 2 then
			done = "cancelled"
		else
			done = "settled"
		end
	end

	local stop_unconfirmed = false
	if done == "timed_out" or done == "cancelled" then
		pcall(handle.cancel, handle)
		if not wait_settled then
			local rem_ms = opts.stop_grace_ms or 3000
			if opts.get_stop_deadline then
				rem_ms = math.max(0, math.floor(opts.get_stop_deadline() - mare.task.clock()))
			end
			if rem_ms > 0 then
				mare.task.timeout(rem_ms, function()
					pcall(wait_task.wait, wait_task)
				end)
			end
		end
		if not wait_settled then
			stop_unconfirmed = true
			pcall(wait_task.abort, wait_task)
		end
	end

	active = false
	if ev_task then
		pcall(ev_task.abort, ev_task)
	end

	if stop_unconfirmed then
		return {
			ok = false,
			status = "stop_unconfirmed",
			stop_unconfirmed = true,
			error = done == "timed_out" and ("subagent timed out and stop_unconfirmed after %dms"):format(timeout_ms)
				or "stop_unconfirmed",
		}
	end
	if done == "timed_out" then
		return { ok = false, status = "failed", error = ("subagent timed out after %dms"):format(timeout_ms) }
	end
	if done == "cancelled" or (cancel and cancel:is_cancelled()) then
		return { ok = false, status = "cancelled", error = "cancelled" }
	end
	if not wait_ok then
		local msg = tostring(res)
		local st = msg:find("cancelled", 1, true) and "cancelled" or "failed"
		return { ok = false, status = st, error = msg }
	end
	if type(res) ~= "table" then
		return { ok = false, status = "failed", error = "unexpected subagent result" }
	end
	if res.error then
		return {
			ok = false,
			status = res.error_kind == "cancelled" and "cancelled" or "failed",
			error = tostring(require("mare_lib").error_message(res.error) or res.error),
			usage = res.usage,
		}
	end
	return {
		ok = true,
		status = "completed",
		text = res.text or "",
		structured = res.structured,
		usage = res.usage,
	}
end

function M.new(deps)
	local ctx = deps.ctx
	local get_cfg = deps.get_cfg
	local svc = deps.svc
	local panel = deps.panel
	local summary = deps.summary
	local custom_runner = deps.runner

	local E = {}
	local active_runs = {}

	local function current_session_info()
		local sess = svc.session
		if not sess or type(sess.info) ~= "function" then
			return {}
		end
		local ok, info = pcall(sess.info, sess)
		return ok and type(info) == "table" and info or {}
	end

	function E.on_session_changed()
		local cur = current_session_info()
		for _, entry in pairs(active_runs) do
			local o = entry.origin
			if o and (o.id ~= nil or o.generation ~= nil) then
				if cur.session_id ~= o.id or cur.session_epoch ~= o.generation then
					entry.session_switched = true
					entry.cancel:cancel()
				end
			end
		end
	end

	local DISALLOWED_CHILD_TOOLS = {
		subagent = true,
		subagent_wait = true,
		subagent_steer = true,
		subagent_cancel = true,
		subagent_list = true,
	}

	local function to_string_set(list)
		if type(list) ~= "table" then
			return nil
		end
		local set = {}
		for _, v in ipairs(list) do
			if type(v) == "string" then
				set[v] = true
			end
		end
		return set
	end

	local function resolve_tool_ceiling(tctx)
		local declared_list = nil
		local declared_set = nil
		if tctx and type(tctx.declared_tools) == "table" then
			declared_list = {}
			declared_set = {}
			for _, tname in ipairs(tctx.declared_tools) do
				if type(tname) == "string" and not declared_set[tname] then
					declared_set[tname] = true
					declared_list[#declared_list + 1] = tname
				end
			end
		end

		local cli_agent = nil
		local cli_name = mare and mare.args and mare.args.agent or nil
		if
			type(cli_name) == "string"
			and cli_name ~= ""
			and svc.subagent
			and type(svc.subagent.list_types) == "function"
		then
			local ok_defs, defs = pcall(svc.subagent.list_types, svc.subagent)
			local list = ok_defs and type(defs) == "table" and type(defs.data) == "table" and defs.data or nil
			if list then
				for _, def in ipairs(list) do
					if type(def) == "table" and def.name == cli_name then
						cli_agent = def
						break
					end
				end
			end
		end

		if
			declared_list == nil
			and cli_agent
			and cli_agent.tools == nil
			and cli_agent.disallowed_tools ~= nil
			and ctx
			and ctx.tools
			and type(ctx.tools.definitions) == "function"
		then
			local model = svc.llm and type(svc.llm.current) == "function" and svc.llm:current() or nil
			local ok_tools, defs = pcall(ctx.tools.definitions, ctx.tools, model)
			if ok_tools and type(defs) == "table" then
				declared_list = {}
				declared_set = {}
				for _, td in ipairs(defs) do
					if type(td) == "table" and type(td.name) == "string" and not declared_set[td.name] then
						declared_set[td.name] = true
						declared_list[#declared_list + 1] = td.name
					end
				end
			end
		end

		return {
			declared_list = declared_list,
			declared_set = declared_set,
			cli_agent = cli_agent,
		}
	end

	local function filter_child_tools(tools_list, workflow_tool_name, ceiling)
		ceiling = ceiling or {}
		local declared_set = ceiling.declared_set
		local declared_list = ceiling.declared_list
		local cli_agent = ceiling.cli_agent
		local cli_allow = cli_agent and to_string_set(cli_agent.tools) or nil
		local cli_deny = cli_agent and to_string_set(cli_agent.disallowed_tools) or nil

		local candidate = tools_list
		if type(candidate) ~= "table" then
			if declared_list ~= nil then
				candidate = declared_list
			elseif cli_agent and type(cli_agent.tools) == "table" then
				candidate = cli_agent.tools
			else
				return nil
			end
		end

		local out = mare and mare.json and mare.json.array and mare.json.array({}) or {}
		local seen = {}
		for _, tname in ipairs(candidate) do
			if
				type(tname) == "string"
				and not seen[tname]
				and not DISALLOWED_CHILD_TOOLS[tname]
				and tname ~= workflow_tool_name
				and (declared_set == nil or declared_set[tname])
				and (cli_allow == nil or cli_allow[tname])
				and (cli_deny == nil or not cli_deny[tname])
			then
				seen[tname] = true
				out[#out + 1] = tname
			end
		end
		return out
	end

	local function validate_agent_call(prompt, agent_opts, total_agents, cfg, phase_meta, current_phase)
		if type(prompt) ~= "string" or not prompt:find("%S") then
			return false, "agent() prompt must be a non-empty string"
		end
		if agent_opts ~= nil then
			if not is_plain_object(agent_opts) then
				return false, "agent() opts must be an object"
			end
			for k in pairs(agent_opts) do
				if not ALLOWED_AGENT_OPTS[k] then
					return false, "agent() unknown option: " .. tostring(k)
				end
			end
			for _, sk in ipairs({ "label", "phase", "provider", "model", "effort", "system", "cwd" }) do
				if agent_opts[sk] ~= nil and type(agent_opts[sk]) ~= "string" then
					return false, ("agent() opts.%s must be a string"):format(sk)
				end
			end
			if agent_opts.tools ~= nil then
				if type(agent_opts.tools) ~= "table" then
					return false, "agent() opts.tools must be a string array"
				end
				for i, tname in ipairs(agent_opts.tools) do
					if type(tname) ~= "string" then
						return false, ("agent() opts.tools[%d] must be a string"):format(i)
					end
				end
			end
			if agent_opts.schema ~= nil then
				local ok_s, err_s = pcall(schema.validate_schema, agent_opts.schema)
				if not ok_s then
					return false, tostring(err_s)
				end
			end
		end
		if total_agents >= (cfg.max_total_agents or 1000) then
			return false, ("max_total_agents limit exceeded (%d)"):format(cfg.max_total_agents or 1000)
		end
		local phase = (agent_opts and agent_opts.phase) or current_phase
		local pmeta = phase and phase_meta and phase_meta[phase] or nil
		local resolved_provider = (agent_opts and agent_opts.provider)
			or (pmeta and pmeta.provider)
			or cfg.provider
			or "spawn"
		if not custom_runner and resolved_provider ~= "spawn" then
			return false,
				('unsupported workflow provider %q (only "spawn" is supported)'):format(tostring(resolved_provider))
		end
		return true
	end

	local function execute_run(params, exec_opts)
		exec_opts = exec_opts or {}
		local cfg = get_cfg()
		if mare and mare.mode == "child" then
			return {
				is_error = true,
				content = "Error: workflow run failed: subagents cannot start nested workflows (depth limit 1)",
			}
		end
		if type(params) ~= "table" then
			return { is_error = true, content = "Error: workflow run failed: arguments must be an object" }
		end
		if type(params.script) ~= "string" or not params.script:find("%S") then
			return { is_error = true, content = "Error: workflow run failed: script must be a non-empty string" }
		end
		local ok_meta, meta_err = schema.validate_meta(params.meta)
		if not ok_meta then
			return { is_error = true, content = "Error: workflow run failed: " .. tostring(meta_err) }
		end
		if params.args ~= nil and not is_plain_object(params.args) then
			return { is_error = true, content = "Error: workflow run failed: args must be a JSON object" }
		end

		local meta = params.meta
		local concurrency = config.resolve_concurrency(cfg)
		local sem = make_semaphore(concurrency)
		local cancel = exec_opts.cancel and exec_opts.cancel:child() or mare.task.token()
		local run_id = "wf-" .. mare.crypto.random_hex(6)
		local sess_info = current_session_info()
		local origin_session = exec_opts.origin_session
			or {
				id = sess_info.session_id,
				generation = sess_info.session_epoch,
				ephemeral = sess_info.ephemeral == true,
			}
		local run_state = { cancel = cancel, origin = origin_session, session_switched = false }
		active_runs[run_id] = run_state

		local function session_switched()
			if run_state.session_switched then
				return true
			end
			if origin_session.id == nil and origin_session.generation == nil then
				return false
			end
			local cur = current_session_info()
			if cur.session_id ~= origin_session.id or cur.session_epoch ~= origin_session.generation then
				run_state.session_switched = true
				return true
			end
			return false
		end

		if session_switched() then
			active_runs[run_id] = nil
			return {
				content = "Error: workflow run was cancelled",
				is_error = true,
				cancelled = true,
				stop_unconfirmed = false,
			}
		end

		local stop_deadline_clock = nil
		local function ensure_stop_deadline()
			if not stop_deadline_clock then
				stop_deadline_clock = mare.task.clock() + (cfg.stop_grace_ms or 3000)
			end
			return stop_deadline_clock
		end

		local writer = records.new_writer(function()
			return svc.session
		end, origin_session)

		local phase_meta = {}
		for _, p in ipairs(meta.phases or {}) do
			phase_meta[p.title] = p
		end

		local run = {
			run_id = run_id,
			name = meta.name,
			description = meta.description,
			meta = meta,
			cwd = exec_opts.cwd or mare.cwd,
			started_at_ms = now_ms(),
			started_clock = mare.task.clock(),
			ended_at_ms = nil,
			status = "running",
			current_phase = meta.phases and meta.phases[1] and meta.phases[1].title or nil,
			phases = {},
			phase_order = {},
			agents = {},
			by_seq = {},
			logs = {},
			total = 0,
			completed = 0,
			failed = 0,
			cancelled = 0,
			stop_unconfirmed = false,
			background = exec_opts.background == true,
			model = exec_opts.model,
			effort = exec_opts.effort,
		}

		local active_handles = {}
		local inflight_tasks = {}
		local seq_counter = 0
		local attached_panel = false
		local finished_normally = false
		local tool_ceiling = exec_opts.tool_ceiling or {}

		local _run_guard <close> = setmetatable({}, {
			__close = function()
				active_runs[run_id] = nil
				if not finished_normally then
					cancel:cancel()
					for _, h in pairs(active_handles) do
						if h and type(h.cancel) == "function" then
							pcall(h.cancel, h)
						end
					end
					if attached_panel and panel then
						pcall(panel.finish, run)
					end
				end
			end,
		})

		local function ensure_phase(title)
			if not title or title == "" then
				return
			end
			if not run.phases[title] then
				run.phases[title] = { title = title, agents = {} }
				run.phase_order[#run.phase_order + 1] = title
			end
		end

		local function job_log(line)
			if exec_opts.on_log then
				exec_opts.on_log(line)
			end
		end

		local function emit_changed()
			if not run.background and panel then
				panel.invalidate()
			end
		end

		if summary then
			summary.track_run(run)
		end
		run.recorded_in_session = writer.run_start({
			run_id = run_id,
			name = meta.name,
			description = meta.description,
			meta = meta,
			background = run.background,
			started_at_ms = run.started_at_ms,
		})

		local start_payload = {
			run_id = run_id,
			name = meta.name,
			description = meta.description,
			total = 0,
			parent_session_id = sess_info.session_id,
			parent_session_epoch = sess_info.session_epoch,
			status = "running",
			started_at_ms = run.started_at_ms,
		}
		events.emit(ctx, "workflow/started", start_payload)
		job_log(("workflow %s started: %s"):format(meta.name, meta.description))

		if not run.background and panel then
			panel.attach(run)
			attached_panel = true
		end

		local callbacks = {
			phase = function(title)
				if type(title) ~= "string" or not title:find("%S") then
					return { fatal = true, error = "phase() title must be a non-empty string" }
				end
				run.current_phase = title
				ensure_phase(title)
				events.emit(ctx, "workflow/phase", { run_id = run_id, phase = title, title = title })
				job_log("[phase] " .. title)
				emit_changed()
				return true
			end,
			log = function(msg)
				local raw
				if msg == nil then
					raw = "nil"
				elseif type(msg) == "string" then
					raw = msg
				else
					local ok_enc, encoded = pcall(mare.json.encode_strict, msg)
					raw = ok_enc and encoded or tostring(msg)
				end
				local text, omitted = truncate_chars(raw, MAX_LOG_CHARS)
				if omitted > 0 then
					text = text .. (" [+%d chars]"):format(omitted)
				end
				if #run.logs >= (deps.max_run_logs or MAX_RUN_LOGS) then
					table.remove(run.logs, 1)
				end
				run.logs[#run.logs + 1] = { timestamp = now_ms(), message = text, phase = run.current_phase }
				events.emit(ctx, "workflow/log", {
					run_id = run_id,
					message = text,
					phase = run.current_phase,
				})
				job_log("[log] " .. text)
				return true
			end,
			check_items = function(count)
				local max_items = cfg.max_items_per_call or 4096
				if count > max_items then
					return {
						fatal = true,
						error = ("max_items_per_call limit exceeded (%d > %d)"):format(count, max_items),
					}
				end
				return { ok = true }
			end,
			agent = function(prompt, agent_opts)
				local ok_arg, arg_err =
					validate_agent_call(prompt, agent_opts, run.total, cfg, phase_meta, run.current_phase)
				if not ok_arg then
					return { fatal = true, error = arg_err }
				end
				if session_switched() then
					cancel:cancel()
					return { ok = false, error = "session changed; workflow cancelled" }
				end
				if cancel:is_cancelled() then
					return { ok = false, error = "workflow run was cancelled" }
				end

				agent_opts = agent_opts or {}
				seq_counter = seq_counter + 1
				local seq = seq_counter
				local phase = agent_opts.phase or run.current_phase
				if phase then
					ensure_phase(phase)
				end
				local pmeta = phase and phase_meta[phase] or nil
				local label = agent_opts.label or ("agent-" .. seq)
				local model = agent_opts.model or (pmeta and pmeta.model) or nil
				local provider = agent_opts.provider or (pmeta and pmeta.provider) or cfg.provider or "spawn"
				local member = {
					seq = seq,
					label = label,
					phase = phase,
					provider = provider,
					model = model,
					effort = agent_opts.effort,
					prompt = prompt,
					status = "queued",
					started_at_ms = now_ms(),
					started_clock = mare.task.clock(),
					tool_calls = 0,
					preview = "queued…",
				}
				run.total = run.total + 1
				run.agents[#run.agents + 1] = member
				run.by_seq[seq] = member
				if phase and run.phases[phase] then
					table.insert(run.phases[phase].agents, member)
				end

				writer.agent_start(seq, {
					run_id = run_id,
					seq = seq,
					label = label,
					phase = phase,
					model = model,
					provider = provider,
					started_at_ms = member.started_at_ms,
				})
				local astart = {
					run_id = run_id,
					member_id = ("%s#%d"):format(run_id, seq),
					seq = seq,
					label = label,
					phase = phase,
					total = run.total,
				}
				events.emit(ctx, "workflow/agent-started", astart)
				job_log(("[#%d %s] queued"):format(seq, label))
				emit_changed()

				local task_entry = { seq = seq, settled = false }
				inflight_tasks[seq] = task_entry
				local acquired, acq_err = sem.acquire(cancel)
				if not acquired or cancel:is_cancelled() or session_switched() then
					if session_switched() then
						cancel:cancel()
					end
					if acquired then
						sem.release()
					end
					local is_exhausted = acq_err == "exhausted" and not cancel:is_cancelled() and not session_switched()
					member.status = is_exhausted and "failed" or "cancelled"
					member.ok = false
					member.error = session_switched() and "session changed; workflow cancelled"
						or (is_exhausted and "concurrency slots exhausted by stop_unconfirmed children" or "cancelled")
					member.ended_at_ms = now_ms()
					member.duration_ms = member.ended_at_ms - member.started_at_ms
					if is_exhausted then
						run.failed = run.failed + 1
					else
						run.cancelled = run.cancelled + 1
					end
					task_entry.settled = true
					inflight_tasks[seq] = nil
					writer.agent_end(seq, {
						run_id = run_id,
						seq = seq,
						label = label,
						phase = phase,
						status = member.status,
						ok = false,
						error = member.error,
						duration_ms = member.duration_ms,
						ended_at_ms = member.ended_at_ms,
					})
					local aend = {
						run_id = run_id,
						member_id = ("%s#%d"):format(run_id, seq),
						seq = seq,
						label = label,
						phase = phase,
						total = run.total,
						ok = false,
						status = member.status,
						error = member.error,
					}
					events.emit(ctx, "workflow/agent-completed", aend)
					emit_changed()
					return { ok = false, error = member.error }
				end

				member.status = "running"
				member.preview = "running…"
				job_log(("[#%d %s] started"):format(seq, label))
				emit_changed()

				local child_handle = nil
				local child_plugins_cfg = {
					subagent = { enabled = false },
					workflow = { enabled = false },
				}
				if origin_session.id and not origin_session.ephemeral then
					child_plugins_cfg.team = { session_id = origin_session.id }
				end
				local spawn_spec = {
					prompt = prompt,
					run_id = run_id,
					seq = seq,
					label = label,
					phase = phase,
					task = first_nonempty_line(prompt),
					model = model,
					effort = agent_opts.effort,
					tools = filter_child_tools(agent_opts.tools, cfg.tool_name, tool_ceiling),
					system = agent_opts.system,
					cwd = agent_opts.cwd or run.cwd,
					output_schema = agent_opts.schema,
					config = {
						plugins = child_plugins_cfg,
					},
				}
				local runner_fn = custom_runner or default_spawn_runner
				local r_ok, r_res = pcall(runner_fn, spawn_spec, {
					provider = provider,
					timeout_ms = cfg.child_timeout_ms,
					stop_grace_ms = cfg.stop_grace_ms,
					get_stop_deadline = function()
						if cancel:is_cancelled() then
							return ensure_stop_deadline()
						end
						return mare.task.clock() + (cfg.stop_grace_ms or 3000)
					end,
					cancel = cancel,
					on_handle = function(h)
						child_handle = h
						active_handles[seq] = h
					end,
					on_event = function(ev)
						if type(ev) ~= "table" then
							return
						end
						if ev.name == "item/started" and type(ev.payload) == "table" then
							local item = ev.payload.item
							if type(item) == "table" and item.type == "tool_call" then
								member.tool_calls = member.tool_calls + 1
								member.preview = "● " .. tostring(item.name or "tool")
								emit_changed()
							end
						elseif ev.name == "item/delta" and type(ev.payload) == "table" then
							if ev.payload.kind == "text" and type(ev.payload.delta) == "string" then
								local line = first_nonempty_line(ev.payload.delta)
								if line then
									member.preview = line
									emit_changed()
								end
							end
						end
					end,
				})
				local outcome = r_ok and type(r_res) == "table" and r_res
					or { ok = false, status = "failed", error = tostring(r_res) }
				if outcome.stop_unconfirmed then
					sem.mark_unconfirmed()
				else
					active_handles[seq] = nil
					sem.release()
				end
				local final_value = nil
				local final_ok = outcome.ok == true
				local final_status = outcome.status or (final_ok and "completed" or "failed")
				local final_err = outcome.error

				if outcome.stop_unconfirmed then
					final_ok = false
					final_status = "stop_unconfirmed"
					member.stop_unconfirmed = true
					run.stop_unconfirmed = true
				end

				if final_ok then
					if agent_opts.schema ~= nil then
						local parsed, p_err =
							parse_structured_output(outcome, agent_opts.schema, cfg.child_result_chars or 12000)
						if parsed ~= nil then
							final_value = parsed
						else
							final_ok = false
							final_status = "failed"
							final_err = p_err
						end
					else
						local text = tostring(outcome.text or "")
						local capped = truncate_chars(text, cfg.child_result_chars or 12000)
						final_value = capped
					end
				end

				member.ended_at_ms = now_ms()
				member.duration_ms = math.max(0, member.ended_at_ms - member.started_at_ms)
				member.ok = final_ok
				member.status = final_status
				member.error = final_err
				member.usage = outcome.usage
				member.summary = final_ok
						and (type(final_value) == "string" and first_nonempty_line(final_value) or "structured result")
					or final_err
				member.preview = member.summary or final_status

				if final_ok then
					run.completed = run.completed + 1
				elseif final_status == "cancelled" then
					run.cancelled = run.cancelled + 1
				else
					run.failed = run.failed + 1
				end

				task_entry.settled = true
				inflight_tasks[seq] = nil

				writer.agent_end(seq, {
					run_id = run_id,
					seq = seq,
					label = label,
					phase = phase,
					status = final_status,
					ok = final_ok,
					error = final_err,
					duration_ms = member.duration_ms,
					ended_at_ms = member.ended_at_ms,
					usage = outcome.usage,
					summary = member.summary,
				})
				local aend = {
					run_id = run_id,
					member_id = ("%s#%d"):format(run_id, seq),
					seq = seq,
					label = label,
					phase = phase,
					total = run.total,
					ok = final_ok,
					status = final_status,
					error = final_err,
					duration_ms = member.duration_ms,
				}
				events.emit(ctx, "workflow/agent-completed", aend)
				job_log(
					("[#%d %s] %s%s"):format(
						seq,
						label,
						final_status,
						final_err and (" — " .. tostring(final_err)) or ""
					)
				)
				emit_changed()

				if not final_ok then
					return { ok = false, error = final_err or final_status }
				end
				return { ok = true, value = final_value }
			end,
		}

		local vm_res = vm.run({
			script = params.script,
			args = params.args or {},
			cfg = cfg,
			concurrency = concurrency,
			cancel = cancel,
			sandbox_new = deps.sandbox_new,
			callbacks = callbacks,
		})

		-- Cooperative cancellation & grace wait if any child handles/tasks remain open.
		if vm_res.cancelled or session_switched() or next(inflight_tasks) ~= nil or next(active_handles) ~= nil then
			local deadline = ensure_stop_deadline()
			cancel:cancel()
			for _, h in pairs(active_handles) do
				if h and type(h.cancel) == "function" then
					pcall(h.cancel, h)
				end
			end
			while next(inflight_tasks) ~= nil and mare.task.clock() < deadline do
				mare.task.sleep(20)
			end
			for seq, entry in pairs(inflight_tasks) do
				if not entry.settled then
					local m = run.by_seq[seq]
					if m then
						local unconfirmed = active_handles[seq] ~= nil
						m.status = unconfirmed and "stop_unconfirmed" or "cancelled"
						m.ok = false
						m.error = m.status
						m.ended_at_ms = now_ms()
						m.duration_ms = math.max(0, m.ended_at_ms - m.started_at_ms)
						if unconfirmed then
							m.stop_unconfirmed = true
							run.stop_unconfirmed = true
						end
						run.cancelled = run.cancelled + 1
						writer.agent_end(seq, {
							run_id = run_id,
							seq = seq,
							label = m.label,
							phase = m.phase,
							status = m.status,
							ok = false,
							error = m.error,
							duration_ms = m.duration_ms,
							ended_at_ms = m.ended_at_ms,
						})
					end
					inflight_tasks[seq] = nil
				end
			end
		end

		active_runs[run_id] = nil
		run.ended_at_ms = now_ms()
		run.duration_ms = math.max(0, run.ended_at_ms - run.started_at_ms)
		if vm_res.cancelled or run_state.session_switched then
			run.status = "cancelled"
		elseif not vm_res.ok then
			run.status = "failed"
			run.error = vm_res.error
		else
			run.status = "completed"
		end
		if vm_res.stop_unconfirmed then
			run.stop_unconfirmed = true
		end

		writer.run_end({
			run_id = run_id,
			name = meta.name,
			background = run.background,
			status = run.status,
			total = run.total,
			completed = run.completed,
			failed = run.failed,
			cancelled = run.cancelled,
			stop_unconfirmed = run.stop_unconfirmed or nil,
			error = run.error,
			duration_ms = run.duration_ms,
			ended_at_ms = run.ended_at_ms,
		})

		local end_payload = {
			run_id = run_id,
			name = meta.name,
			status = run.status,
			total = run.total,
			completed = run.completed,
			failed = run.failed,
			cancelled = run.cancelled,
			stop_unconfirmed = run.stop_unconfirmed or nil,
			duration_ms = run.duration_ms,
		}
		events.emit(ctx, "workflow/completed", end_payload)

		if not run.background and panel then
			panel.finish(run)
			attached_panel = false
		end
		finished_normally = true
		if summary and not session_switched() then
			summary.record_run(run)
		end

		if vm_res.cancelled or run_state.session_switched then
			job_log("workflow cancelled")
			return {
				content = "Error: workflow run was cancelled",
				is_error = true,
				cancelled = true,
				stop_unconfirmed = run.stop_unconfirmed == true,
				details = { run = run },
			}
		end
		if not vm_res.ok then
			job_log("workflow failed: " .. tostring(vm_res.error))
			return {
				content = "Error: workflow run failed: " .. tostring(vm_res.error),
				is_error = true,
				stop_unconfirmed = run.stop_unconfirmed == true,
				details = { run = run },
			}
		end

		local encoded = mare.json.encode(vm_res.result, { pretty = true })
		local capped, omitted = truncate_chars(encoded, cfg.max_result_chars or 50000)
		if omitted > 0 then
			capped = capped .. ("\n[truncated: omitted %d characters]"):format(omitted)
		end
		local text = ('workflow "%s" completed (%d agents).\n\nReturn value:\n%s'):format(meta.name, run.total, capped)
		job_log(("workflow %s completed (%d agents)"):format(meta.name, run.total))
		return {
			content = text,
			stop_unconfirmed = run.stop_unconfirmed == true,
			details = {
				run = run,
				result = vm_res.result,
			},
		}
	end

	function E.run(params, tctx)
		tctx = tctx or {}
		local cfg = get_cfg()
		local tool_ceiling = resolve_tool_ceiling(tctx)
		if params and params.run_in_background == true then
			if mare and mare.mode == "child" then
				return {
					is_error = true,
					content = "Error: workflow run failed: subagents cannot start nested workflows (depth limit 1)",
				}
			end
			if type(params.script) ~= "string" or not params.script:find("%S") then
				return { is_error = true, content = "Error: workflow run failed: script must be a non-empty string" }
			end
			local ok_meta, meta_err = schema.validate_meta(params.meta)
			if not ok_meta then
				return { is_error = true, content = "Error: workflow run failed: " .. tostring(meta_err) }
			end
			if params.args ~= nil and not is_plain_object(params.args) then
				return { is_error = true, content = "Error: workflow run failed: args must be a JSON object" }
			end
			local jobs_svc = svc.jobs
			if not jobs_svc or type(jobs_svc.track) ~= "function" then
				return {
					is_error = true,
					content = "Error: workflow run failed: run_in_background requires the jobs service",
				}
			end

			local origin_info = current_session_info()
			local origin_session = {
				id = origin_info.session_id,
				generation = origin_info.session_epoch,
				ephemeral = origin_info.ephemeral == true,
			}
			local buf = make_job_buffer()
			local bg_cancel = mare.task.token()
			local done_tx, done_rx = mare.task.channel(1)
			local state = "running"
			local code = nil
			local final_stop_unconfirmed = false
			local started_clock = mare.task.clock()
			local waiters = {}
			local finalized = false

			local function finalize_job(final_code, err_note, unconfirmed)
				if finalized then
					return
				end
				finalized = true
				if err_note then
					buf.append(err_note)
				end
				if unconfirmed then
					final_stop_unconfirmed = true
				end
				state = "exited"
				code = final_code
				done_tx:send(true)
				for _, w in ipairs(waiters) do
					w:send(true)
				end
				waiters = {}
			end

			local handle = {
				status = function()
					local total, unread = buf.stats()
					return {
						state = state,
						code = code,
						elapsed_ms = mare.task.clock() - started_clock,
						unread = unread,
						bytes = total,
						stop_unconfirmed = final_stop_unconfirmed,
					}
				end,
				read = function(_, ropts)
					local r = buf.read_consuming(ropts)
					local _, unread = buf.stats()
					r.done = (state == "exited") and (unread == 0)
					return r
				end,
				read_at = function(_, offset, ropts)
					return buf.read_at(offset, ropts)
				end,
				tail = function(_, n)
					return buf.tail(n)
				end,
				wait = function(_, wopts)
					if state == "exited" then
						return { state = state, code = code, stop_unconfirmed = final_stop_unconfirmed }
					end
					wopts = wopts or {}
					local wtok = wopts.cancel
					local wait_ch_tx, wait_ch_rx = mare.task.channel(1)
					waiters[#waiters + 1] = wait_ch_tx
					local function await_done()
						if state == "exited" then
							return
						end
						if wtok then
							mare.task.select(function()
								return wait_ch_rx:recv()
							end, function()
								wtok:wait()
								return nil
							end)
						else
							wait_ch_rx:recv()
						end
					end
					if wopts.timeout_ms then
						mare.task.timeout(wopts.timeout_ms, await_done)
					else
						await_done()
					end
					return { state = state, code = code, stop_unconfirmed = final_stop_unconfirmed }
				end,
				stop = function()
					bg_cancel:cancel()
					if state ~= "exited" then
						local grace_ms = cfg.stop_grace_ms or 3000
						mare.task.timeout(grace_ms, function()
							done_rx:recv()
						end)
					end
					return { stop_unconfirmed = final_stop_unconfirmed or (state ~= "exited") }
				end,
				kill = function()
					bg_cancel:cancel()
				end,
			}

			local ok_track, job_or_err = pcall(jobs_svc.track, jobs_svc, {
				kind = "workflow",
				label = params.meta.name,
				description = params.meta.description,
				handle = handle,
				background = true,
			})
			if not ok_track or not job_or_err then
				finalize_job(1, "workflow background track failed: " .. tostring(job_or_err), false)
				return {
					is_error = true,
					content = "Error: workflow run failed: could not track background job: " .. tostring(job_or_err),
				}
			end
			local job = job_or_err
			if job.over_limit then
				bg_cancel:cancel()
				finalize_job(1, "too many background jobs running", false)
				if type(jobs_svc.kill) == "function" and job.job_id then
					pcall(jobs_svc.kill, jobs_svc, job.job_id)
				end
				return {
					is_error = true,
					content = ("Error: workflow run failed: too many background jobs running (%s); stop one with job_kill first"):format(
						tostring(job.over_limit)
					),
				}
			end

			local ok_spawn, spawn_err = pcall(ctx.spawn, ctx, function()
				local _close_guard <close> = setmetatable({}, {
					__close = function()
						bg_cancel:cancel()
						finalize_job(1, "workflow background worker terminated", false)
					end,
				})
				local ok_exec, res = pcall(execute_run, params, {
					cancel = bg_cancel,
					cwd = tctx.cwd,
					background = true,
					origin_session = origin_session,
					tool_ceiling = tool_ceiling,
					on_log = function(line)
						buf.append(line)
					end,
				})
				if not ok_exec then
					finalize_job(1, "Error: workflow background error: " .. tostring(res), false)
					return
				end
				if res and res.content then
					buf.append(res.content)
				end
				local unconf = res and res.stop_unconfirmed == true
				finalize_job(((res and res.is_error) or unconf) and 1 or 0, nil, unconf)
			end)
			if not ok_spawn then
				bg_cancel:cancel()
				finalize_job(1, "Error: workflow background spawn failed: " .. tostring(spawn_err), false)
				return {
					is_error = true,
					content = "Error: workflow run failed: background spawn error: " .. tostring(spawn_err),
				}
			end

			return {
				content = ('workflow "%s" started in the background as job %s. Use job_output(%q) to read progress or job_kill(%q) to cancel.'):format(
					params.meta.name,
					tostring(job.job_id),
					tostring(job.job_id),
					tostring(job.job_id)
				),
				details = { job_id = job.job_id, name = params.meta.name, background = true },
			}
		end

		return execute_run(params, {
			cancel = tctx.cancel,
			cwd = tctx.cwd,
			background = false,
			tool_ceiling = tool_ceiling,
		})
	end

	return E
end

M.make_job_buffer = make_job_buffer

return M
