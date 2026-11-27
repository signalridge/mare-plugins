local M = {}

local function build_preamble(max_workers)
	return ("local __wf_max_workers = %d\n"):format(max_workers)
		.. [[
local __wf_finish
do
local __wf_packed = setmetatable({}, { __mode = "k" })
local __wf_last_agent_err = {}
local __wf_fatal_prefix = "__WF_FATAL__:"
local __wf_fatal_latched = nil

local __wf_raw_json_encode = json.encode
local __wf_raw_json_array = json.array
local __wf_arr_mt = getmetatable(__wf_raw_json_array({}))

local __wf_setTimeout = setTimeout
local __wf_clearTimeout = clearTimeout
local __wf_sleep = sleep
setTimeout = nil
clearTimeout = nil
sleep = nil

local __wf_host_agent = __wf_agent
local __wf_host_check_items = __wf_check_items
local __wf_host_phase = phase
local __wf_host_log = log
local __wf_host_spin_tick = __wf_spin_tick
__wf_agent = nil
__wf_check_items = nil
__wf_spin_tick = nil
local __wf_workers_in_agent = 0
local __wf_slice_epoch = 0

local function __wf_co_key()
	return coroutine.running() or "main"
end

local function __wf_is_fatal(err)
	return type(err) == "string" and err:sub(1, #__wf_fatal_prefix) == __wf_fatal_prefix
end

local function __wf_fatal(msg)
	local clean = tostring(msg or "workflow error")
	if __wf_is_fatal(clean) then
		clean = clean:sub(#__wf_fatal_prefix + 1)
	end
	if __wf_fatal_latched == nil then
		__wf_fatal_latched = clean
	end
	error(__wf_fatal_prefix .. clean, 0)
end

local function __wf_normalize(val, seen)
	if type(val) ~= "table" then
		return val
	end
	seen = seen or {}
	if seen[val] then
		error("cyclic table in workflow return value", 0)
	end
	seen[val] = true
	if __wf_packed[val] then
		local arr = __wf_raw_json_array({})
		local n = val.n or 0
		for i = 1, n do
			local item = val[i]
			if item == nil then
				arr[i] = json.null
			else
				arr[i] = __wf_normalize(item, seen)
			end
		end
		seen[val] = nil
		return arr
	end
	local mt = getmetatable(val)
	if mt ~= nil and mt == __wf_arr_mt then
		local out = __wf_raw_json_array({})
		for i = 1, #val do
			out[i] = __wf_normalize(val[i], seen)
		end
		seen[val] = nil
		return out
	end
	local out = {}
	for k, v in pairs(val) do
		out[k] = __wf_normalize(v, seen)
	end
	seen[val] = nil
	return out
end

json.encode = function(val)
	return __wf_raw_json_encode(__wf_normalize(val))
end

__wf_finish = function(out)
	if __wf_fatal_latched then
		__wf_fatal(__wf_fatal_latched)
	end
	return __wf_normalize(out)
end

local __wf_allowed_agent_opts = {
	label = true,
	phase = true,
	provider = true,
	model = true,
	effort = true,
	system = true,
	cwd = true,
	tools = true,
	schema = true,
}

local function __wf_check_json_safe(val, path, seen)
	local vt = type(val)
	if vt == "nil" or vt == "boolean" or vt == "string" then
		return
	end
	if vt == "number" then
		if val ~= val or val == math.huge or val == -math.huge then
			__wf_fatal(path .. " must be a finite number")
		end
		return
	end
	if vt ~= "table" then
		if val == json.null then
			return
		end
		__wf_fatal(path .. " contains non-JSON value of type " .. vt)
	end
	seen = seen or {}
	if seen[val] then
		__wf_fatal(path .. " contains a cyclic table")
	end
	seen[val] = true
	local has_str, has_num = false, false
	local max_idx, count = 0, 0
	for k, v in pairs(val) do
		local kt = type(k)
		if kt == "string" then
			has_str = true
		elseif kt == "number" then
			if k < 1 or k % 1 ~= 0 then
				__wf_fatal(path .. " has non-positive-integer array key")
			end
			has_num = true
			count = count + 1
			if k > max_idx then
				max_idx = k
			end
		else
			__wf_fatal(path .. " contains non-JSON table key of type " .. kt)
		end
		__wf_check_json_safe(v, path .. "." .. tostring(k), seen)
	end
	if has_str and has_num then
		__wf_fatal(path .. " cannot mix array and object keys")
	end
	if has_num and count ~= max_idx then
		__wf_fatal(path .. " cannot contain sparse array holes")
	end
	if getmetatable(val) == __wf_arr_mt and has_str then
		__wf_fatal(path .. " JSON array cannot have string keys")
	end
	seen[val] = nil
end

local function __wf_validate_agent_args(prompt, opts)
	if type(prompt) ~= "string" or not prompt:find("%S") then
		__wf_fatal("agent() prompt must be a non-empty string")
	end
	if opts == nil then
		return
	end
	if type(opts) ~= "table" or getmetatable(opts) == __wf_arr_mt then
		__wf_fatal("agent() opts must be an object")
	end
	for k in pairs(opts) do
		if type(k) ~= "string" or not __wf_allowed_agent_opts[k] then
			__wf_fatal("agent() unknown option: " .. tostring(k))
		end
	end
	for _, sk in ipairs({ "label", "phase", "provider", "model", "effort", "system", "cwd" }) do
		if opts[sk] ~= nil and type(opts[sk]) ~= "string" then
			__wf_fatal(("agent() opts.%s must be a string"):format(sk))
		end
	end
	if opts.tools ~= nil then
		if type(opts.tools) ~= "table" then
			__wf_fatal("agent() opts.tools must be a string array")
		end
		for k, tname in pairs(opts.tools) do
			if type(k) ~= "number" or k < 1 or k % 1 ~= 0 or type(tname) ~= "string" then
				__wf_fatal("agent() opts.tools must be a dense string array")
			end
		end
		for i = 1, #opts.tools do
			if rawget(opts.tools, i) == nil then
				__wf_fatal("agent() opts.tools must not contain nil holes")
			end
		end
	end
	if opts.schema ~= nil then
		__wf_check_json_safe(opts.schema, "agent().opts.schema")
	end
end

function phase(title)
	if type(title) ~= "string" or not title:find("%S") then
		__wf_fatal("phase() title must be a non-empty string")
	end
	__wf_slice_epoch = __wf_slice_epoch + 1
	local res = __wf_host_phase({ title = title })
	if type(res) == "table" and res.fatal then
		__wf_fatal(res.error or "invalid phase() argument")
	end
	return res
end

function log(msg)
	__wf_check_json_safe(msg, "log()")
	__wf_slice_epoch = __wf_slice_epoch + 1
	return __wf_host_log({ msg = msg })
end

function agent(prompt, opts)
	local key = __wf_co_key()
	__wf_last_agent_err[key] = nil
	__wf_validate_agent_args(prompt, opts)
	__wf_slice_epoch = __wf_slice_epoch + 1
	__wf_workers_in_agent = __wf_workers_in_agent + 1
	local ok_call, res = pcall(__wf_host_agent, { prompt = prompt, opts = opts })
	__wf_workers_in_agent = math.max(0, __wf_workers_in_agent - 1)
	__wf_slice_epoch = __wf_slice_epoch + 1
	if not ok_call then
		__wf_fatal(tostring(res))
	end
	if type(res) ~= "table" then
		__wf_fatal("invalid host agent response")
	end
	if res.fatal then
		__wf_fatal(res.error or "invalid agent arguments")
	end
	if not res.ok then
		__wf_last_agent_err[key] = { kind = "agent", message = tostring(res.error or "subagent failed") }
		return nil
	end
	return res.value
end

local function __wf_check_dense_array(t, fn_name, expect_fn)
	if type(t) ~= "table" or getmetatable(t) == __wf_arr_mt then
		if expect_fn or type(t) ~= "table" then
			__wf_fatal(fn_name .. "() expects a table array")
		end
	end
	if __wf_packed[t] then
		if expect_fn then
			__wf_fatal(fn_name .. "() expects an array of functions")
		end
		return t.n or 0, true
	end
	local max_idx = 0
	for k in pairs(t) do
		if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then
			__wf_fatal(fn_name .. "() input must be a dense 1-based array")
		end
		if k > max_idx then
			max_idx = k
		end
	end
	for i = 1, max_idx do
		local v = rawget(t, i)
		if v == nil then
			__wf_fatal(fn_name .. "() input array must not contain nil holes")
		end
		if expect_fn and type(v) ~= "function" then
			__wf_fatal(fn_name .. "() expects functions at every index")
		end
	end
	return max_idx, false
end

local function __wf_run_pool(n, worker_fn)
	local results = {}
	local errors = {}
	local next_idx = 1
	local done = 0
	local fatal_err = nil
	local workers = math.min(n, __wf_max_workers)
	local active_workers = workers

	local function spawn_worker()
		__wf_setTimeout(function()
			local ok_loop, loop_err = pcall(function()
				while not fatal_err and not __wf_fatal_latched do
					local i = next_idx
					if i > n then
						break
					end
					next_idx = i + 1
					local val, err, is_fatal = worker_fn(i)
					if is_fatal or __wf_fatal_latched then
						fatal_err = err or (__wf_fatal_prefix .. tostring(__wf_fatal_latched))
						break
					end
					results[i] = val
					if err ~= nil then
						errors[i] = err
					end
					__wf_slice_epoch = __wf_slice_epoch + 1
					done = done + 1
				end
			end)
			active_workers = math.max(0, active_workers - 1)
			if not ok_loop and not fatal_err then
				fatal_err = tostring(loop_err)
			end
		end, 0)
	end

	for _ = 1, workers do
		spawn_worker()
	end
	local spin_ticks = 0
	while done < n and not fatal_err and not __wf_fatal_latched do
		__wf_sleep(5)
		if active_workers > __wf_workers_in_agent then
			spin_ticks = spin_ticks + 1
			if spin_ticks >= 4 then
				spin_ticks = 0
				pcall(__wf_host_spin_tick, __wf_slice_epoch)
			end
		else
			spin_ticks = 0
		end
	end
	if __wf_fatal_latched then
		__wf_fatal(__wf_fatal_latched)
	end
	if fatal_err then
		error(fatal_err, 0)
	end
	results.n = n
	results.errors = errors
	__wf_packed[results] = true
	return results
end

function parallel(fns)
	local n = __wf_check_dense_array(fns, "parallel", true)
	local chk = __wf_host_check_items(n)
	if type(chk) == "table" and chk.fatal then
		__wf_fatal(chk.error or "too many items")
	end
	if n == 0 then
		local empty = { n = 0, errors = {} }
		__wf_packed[empty] = true
		return empty
	end
	return __wf_run_pool(n, function(i)
		local co = __wf_co_key()
		__wf_last_agent_err[co] = nil
		local ok, val = pcall(fns[i])
		local agent_err = __wf_last_agent_err[co]
		__wf_last_agent_err[co] = nil
		if __wf_fatal_latched then
			return nil, __wf_fatal_prefix .. tostring(__wf_fatal_latched), true
		end
		if not ok then
			if __wf_is_fatal(val) then
				return nil, val, true
			end
			return nil, { kind = "stage", stage = 1, message = tostring(val) }, false
		end
		if val == nil and agent_err then
			return nil, { kind = "agent", stage = 1, message = agent_err.message }, false
		end
		return val, nil, false
	end)
end

function pipeline(items, ...)
	local n = __wf_check_dense_array(items, "pipeline", false)
	local stage_count = select("#", ...)
	if stage_count == 0 then
		__wf_fatal("pipeline() requires at least one stage function")
	end
	local stages = {}
	for s = 1, stage_count do
		local fn = select(s, ...)
		if type(fn) ~= "function" then
			__wf_fatal(("pipeline() stage %d must be a function"):format(s))
		end
		stages[s] = fn
	end
	local chk = __wf_host_check_items(n)
	if type(chk) == "table" and chk.fatal then
		__wf_fatal(chk.error or "too many items")
	end
	if n == 0 then
		local empty = { n = 0, errors = {} }
		__wf_packed[empty] = true
		return empty
	end
	return __wf_run_pool(n, function(i)
		local item = items[i]
		local val = item
		for s = 1, stage_count do
			local co = __wf_co_key()
			__wf_last_agent_err[co] = nil
			local ok, out = pcall(stages[s], val, item, i)
			local agent_err = __wf_last_agent_err[co]
			__wf_last_agent_err[co] = nil
			if __wf_fatal_latched then
				return nil, __wf_fatal_prefix .. tostring(__wf_fatal_latched), true
			end
			if not ok then
				if __wf_is_fatal(out) then
					return nil, out, true
				end
				return nil, { kind = "stage", stage = s, message = tostring(out) }, false
			end
			val = out
			-- Stop this item immediately if the stage returned the failed nil agent() result.
			if val == nil and agent_err then
				return nil, { kind = "agent", stage = s, message = agent_err.message }, false
			end
		end
		return val, nil, false
	end)
end
]]
end

local function strip_fatal_prefix(msg)
	local text = tostring(msg or "")
	local s, e = text:find("__WF_FATAL__:", 1, true)
	if s then
		return text:sub(e + 1)
	end
	return text
end

M.strip_fatal_prefix = strip_fatal_prefix

--- Execute `script` inside a bounded Lua sandbox VM with workflow capabilities.
--- @param opts table { script, args, cfg, cancel, callbacks, sandbox_new? }
--- @return table { ok: boolean, result?: any, error?: string, cancelled?: boolean, stop_unconfirmed?: boolean }
function M.run(opts)
	local script = opts.script
	if type(script) ~= "string" or not script:find("%S") then
		return { ok = false, error = "script must be a non-empty string" }
	end
	local cfg = opts.cfg
	local callbacks = opts.callbacks
	local cancel = opts.cancel or mare.task.token()
	local vm_cancel = cancel:child()
	local sandbox_new = opts.sandbox_new or (mare and mare.sandbox and mare.sandbox.new)
	if type(sandbox_new) ~= "function" then
		return { ok = false, error = "mare.sandbox is unavailable" }
	end

	local concurrency = opts.concurrency or 4
	local max_workers = math.max(1, math.min(64, concurrency * 2))
	local blocked_in_agent = 0
	local last_activity_ms = mare.task.clock()
	local first_spin_ms = nil
	local last_spin_ms = nil
	local last_spin_epoch = nil
	local sync_timed_out = false
	local finished = false

	local function touch()
		last_activity_ms = mare.task.clock()
	end

	local expose = {
		args = opts.args or {},
		phase = function(payload)
			local title = type(payload) == "table" and payload.title or nil
			return callbacks.phase(title)
		end,
		log = function(payload)
			local msg = type(payload) == "table" and payload.msg or nil
			return callbacks.log(msg)
		end,
		__wf_check_items = function(count)
			return callbacks.check_items(count)
		end,
		__wf_spin_tick = function(epoch)
			local now = mare.task.clock()
			if not first_spin_ms or epoch ~= last_spin_epoch then
				first_spin_ms = now
				last_spin_epoch = epoch
			end
			last_spin_ms = now
			return true
		end,
		__wf_agent = function(payload)
			touch()
			local prompt = type(payload) == "table" and payload.prompt or nil
			local agent_opts = type(payload) == "table" and payload.opts or nil
			blocked_in_agent = blocked_in_agent + 1
			local ok, res = pcall(callbacks.agent, prompt, agent_opts)
			blocked_in_agent = math.max(0, blocked_in_agent - 1)
			touch()
			if blocked_in_agent == 0 then
				first_spin_ms = nil
				last_spin_ms = nil
			end
			if not ok then
				return { ok = false, fatal = true, error = strip_fatal_prefix(res) }
			end
			return res
		end,
	}

	local fn_check, syntax_err = load(script, "=workflow", "t")
	if not fn_check then
		return {
			ok = false,
			error = "workflow script syntax error: " .. tostring(syntax_err),
			cancelled = false,
			stop_unconfirmed = false,
		}
	end

	local stop_grace_ms = math.min(math.max(0, math.floor(tonumber(cfg.stop_grace_ms) or 3000)), 600000)
	local vm_opts = {
		timeout_ms = false,
		cancel = vm_cancel,
		stop_grace_ms = stop_grace_ms,
		grace_ms = stop_grace_ms,
		max_pending_calls = 1024,
		max_instructions = 100000000,
		expose = expose,
		on_output = callbacks.on_output,
	}

	local ok_new, vm_or_err = pcall(sandbox_new, vm_opts)
	if not ok_new then
		return { ok = false, error = "failed to create workflow sandbox VM: " .. tostring(vm_or_err) }
	end
	local vm = vm_or_err

	local sync_timeout_ms = tonumber(cfg.sync_timeout_ms) or 5000
	local watchdog = nil
	local _vm_guard <close> = setmetatable({}, {
		__close = function()
			local aborted_mid_run = not finished
			finished = true
			if watchdog then
				pcall(watchdog.abort, watchdog)
			end
			if aborted_mid_run and type(vm.stop) == "function" then
				pcall(vm.stop, vm)
			end
			vm_cancel:cancel()
		end,
	})

	if sync_timeout_ms > 0 and mare and mare.task and mare.task.spawn then
		watchdog = mare.task.spawn(function()
			local poll_ms = math.max(10, math.min(100, math.floor(sync_timeout_ms / 4)))
			while not finished and not vm_cancel:is_cancelled() do
				mare.task.sleep(poll_ms, vm_cancel)
				if finished or vm_cancel:is_cancelled() then
					break
				end
				local now = mare.task.clock()
				local stale_spin_ms = math.max(50, math.min(sync_timeout_ms - 10, poll_ms * 2))
				if last_spin_ms and (now - last_spin_ms) >= stale_spin_ms then
					first_spin_ms = nil
					last_spin_ms = nil
				end
				local unblocked_timed_out = blocked_in_agent == 0 and (now - last_activity_ms) >= sync_timeout_ms
				local sibling_spin_timed_out = first_spin_ms ~= nil and (now - first_spin_ms) >= sync_timeout_ms
				if unblocked_timed_out or sibling_spin_timed_out then
					sync_timed_out = true
					if type(vm.stop) == "function" then
						pcall(vm.stop, vm)
					end
					vm_cancel:cancel()
					break
				end
			end
		end)
	end

	-- Compile the user function before the preamble declares local runtime helpers
	-- (`__wf_finish`, `__wf_fatal_latched`, etc.) so user code cannot capture or
	-- mutate them as upvalues, and pre-validate with `load()` to block syntactic breakouts.
	local wrapped_code = "local __wf_user_fn = function()\n"
		.. script
		.. "\nend\n"
		.. build_preamble(max_workers)
		.. "\nend\nlocal __wf_out = __wf_user_fn()\n"
		.. "return __wf_finish(__wf_out)\n"

	local res, err, status = vm:run(wrapped_code, vm_opts)
	finished = true
	if watchdog then
		pcall(watchdog.abort, watchdog)
	end

	if sync_timed_out then
		return {
			ok = false,
			error = ("synchronous script slice exceeded sync_timeout_ms (%dms)"):format(sync_timeout_ms),
			cancelled = false,
			stop_unconfirmed = status and status.stop_unconfirmed == true or false,
		}
	end

	if cancel:is_cancelled() or (status and status.cancelled) then
		return {
			ok = false,
			cancelled = true,
			error = "workflow run was cancelled",
			stop_unconfirmed = status and status.stop_unconfirmed == true or false,
		}
	end

	if not res then
		return {
			ok = false,
			error = strip_fatal_prefix(err or "unknown sandbox error"),
			cancelled = false,
			stop_unconfirmed = status and status.stop_unconfirmed == true or false,
		}
	end

	return {
		ok = true,
		result = res.result,
		output = res.output,
	}
end

return M
