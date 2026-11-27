local D = require("presets.definition")

local function read_persisted_state()
	if mare and mare.state and type(mare.state.read) == "function" then
		local ok, st = pcall(mare.state.read)
		if ok and type(st) == "table" and type(st.presets) == "table" then
			return st.presets
		end
	end
	return {}
end

local function expand_tools(ctx, patterns)
	if patterns == nil then
		return nil
	end
	local out, seen = mare.json.array(), {}
	local function add(name)
		if not seen[name] then
			seen[name], out[#out + 1] = true, name
		end
	end
	for _, pattern in ipairs(patterns) do
		if pattern:find("[*?]") then
			for _, tool in ipairs(ctx.tools:list()) do
				if D.matches_any(tool.name, { pattern }) then
					add(tool.name)
				end
			end
		else
			add(pattern)
		end
	end
	return out
end

local function as_array(t)
	if t == nil then
		return false
	end
	local arr = mare.json.array({})
	for i = 1, #t do
		arr[i] = t[i]
	end
	return arr
end

local function type_signature(def)
	return mare.json.encode(mare.json.array({
		def.name,
		def.description,
		def.when_to_use or false,
		def.system or false,
		def.model or false,
		def.effort or false,
		as_array(def.tools),
		as_array(def.disallowed_tools),
	}))
end

local function tools_signature(ctx)
	return ctx.tools:revision()
end

local function list_has_wildcards(list)
	if not list then
		return false
	end
	for _, pat in ipairs(list) do
		if pat:find("[*?]") then
			return true
		end
	end
	return false
end

local function has_wildcards(value)
	return list_has_wildcards(value.tools_list) or list_has_wildcards(value.denylist_list)
end

local function build_typed_definition(ctx, id, value)
	local description = value.description
	if description == nil or description == "" then
		description = value.name ~= "" and value.name or id
	end
	return {
		name = id,
		description = description,
		system = value.system ~= "" and value.system or nil,
		model = value.model,
		tools = expand_tools(ctx, value.tools_list),
		disallowed_tools = expand_tools(ctx, value.denylist_list),
	}
end

local function init_definitions(ctx, cfg)
	local signatures, broken, broken_lines, disposers = {}, {}, {}, {}
	local ids = {}
	for id in pairs(cfg.definitions) do
		ids[#ids + 1] = id
	end
	table.sort(ids, function(a, b)
		return tostring(a) < tostring(b)
	end)
	local initial_tools_sig = tools_signature(ctx)
	for _, id in ipairs(ids) do
		local raw = cfg.definitions[id]
		local ok, value = pcall(D.validate, id, raw)
		if ok then
			local typed = build_typed_definition(ctx, id, value)
			local registered, release = pcall(ctx.subagent.register_type, ctx.subagent, typed, { replace = true })
			if registered then
				disposers[id] = release
				signatures[id] = type_signature(typed)
			else
				ok, value = false, release
			end
		end
		if not ok then
			local key, reason = tostring(id), tostring(value)
			broken[key], broken_lines[key] = reason, D.build_broken_lines(reason, raw)
		end
	end
	return signatures, broken, broken_lines, disposers, initial_tools_sig
end

local function selection_definition(s, def)
	local id = def.name
	-- The registry is the only live type table. Legacy selection and prompt
	-- options are read from the configured preset only while our registered
	-- type is still the visible definition.
	local opt = {}
	if s.type_signatures[id] == type_signature(def) and s.cfg.definitions[id] then
		local ok, value = pcall(D.validate, id, s.cfg.definitions[id])
		if ok then
			opt = value
		end
	end
	return {
		name = opt.name or id,
		description = def.description,
		order = opt.order or 0,
		system = def.system or "",
		model = def.model,
		effort = def.effort,
		tools_list = opt.tools_list or def.tools,
		denylist_list = opt.denylist_list or def.disallowed_tools,
		prefix = opt.prefix,
		suffix = opt.suffix,
		complete = opt.complete == true,
		includeRuntimeContext = opt.includeRuntimeContext ~= false,
		default = opt.default == true,
	}
end

local function lookup(s, id)
	for _, def in ipairs(s.ctx.subagent:list_types().data) do
		if def.name == id then
			return selection_definition(s, def)
		end
	end
end

local function warn(msg)
	mare.log("warn", msg)
end

local function write_persisted_field(s, key, value)
	if mare and mare.mode ~= "child" and mare.state and type(mare.state.update) == "function" then
		local ok, res, res_err = pcall(mare.state.update, function(st)
			st = type(st) == "table" and st or {}
			st.presets = type(st.presets) == "table" and st.presets or {}
			st.presets[key] = value
			if next(st.presets) == nil then
				st.presets = nil
			end
			return st
		end)
		if not ok or res == false or (res == nil and res_err ~= nil) then
			local msg = "presets state.json: " .. tostring(not ok and res or res_err or "update failed")
			warn(msg)
			return nil, msg
		end
	end
	return true
end

local function set_staged(s, id)
	local ok, err = write_persisted_field(s, "staged", id)
	if not ok then
		return nil, err
	end
	s.staged_id = id
	s.ctx.bus:emit("presets/updated", { id = id, action = "staged" })
	return true
end

local function dispose_context(s)
	for _, dispose in ipairs(s.context_disposers) do
		pcall(dispose)
	end
	s.context_disposers = {}
	s.ctx.context:invalidate()
end

local function refresh_types(s)
	if s.disposed then
		return
	end
	local sig = tools_signature(s.ctx)
	if sig == s.last_tools_signature then
		return
	end
	s.last_tools_signature = sig
	local current_types
	for id, raw in pairs(s.cfg.definitions) do
		if not s.broken[id] then
			local ok, value = pcall(D.validate, id, raw)
			if ok and has_wildcards(value) then
				local typed = build_typed_definition(s.ctx, id, value)
				local new_sig = type_signature(typed)
				if new_sig ~= s.type_signatures[id] then
					if not current_types then
						current_types = {}
						for _, def in ipairs(s.ctx.subagent:list_types().data) do
							current_types[def.name] = def
						end
					end
					local existing = current_types[id]
					if existing and type_signature(existing) == s.type_signatures[id] then
						local old_release = s.type_disposers[id]
						if old_release then
							pcall(old_release)
							s.type_disposers[id] = nil
						end
						local registered, release =
							pcall(s.ctx.subagent.register_type, s.ctx.subagent, typed, { replace = true })
						if registered then
							s.type_disposers[id] = release
							s.type_signatures[id] = new_sig
						else
							s.broken[id], s.broken_lines[id] =
								tostring(release), D.build_broken_lines(tostring(release), raw)
						end
					end
				end
			end
		end
	end
end

local function sync(s)
	refresh_types(s)
	local current = s.ctx.session:info().session_epoch
	if s.generation ~= current then
		s.active, s.active_signature, s.generation = nil, nil, current
		dispose_context(s)
	elseif s.active then
		local def = lookup(s, s.active)
		if not def or mare.json.encode(def) ~= s.active_signature then
			s.active, s.active_signature = nil, nil
			dispose_context(s)
		end
	end
end

local function constrain_tools(s)
	sync(s)
	local def = s.active and lookup(s, s.active)
	if not def or (not def.tools_list and not def.denylist_list) then
		return nil
	end
	if def.tools_list and not def.denylist_list and not table.concat(def.tools_list):find("[*?]") then
		return D.copy(def.tools_list)
	end
	local allowed = {}
	for _, tool in ipairs(s.ctx.tools:list()) do
		local ok_allow = def.tools_list == nil or D.matches_any(tool.name, def.tools_list)
		local ok_deny = def.denylist_list == nil or not D.matches_any(tool.name, def.denylist_list)
		if ok_allow and ok_deny then
			allowed[#allowed + 1] = tool.name
		end
	end
	return allowed
end

local function validate_prompt_preview(s, def, model)
	local candidate_sections = D.build_sections(def)
	if #candidate_sections == 0 and def.includeRuntimeContext then
		return true
	end
	local ok, preview = pcall(
		s.ctx.context.preview,
		s.ctx.context,
		model,
		nil,
		{ sections = candidate_sections, replace = true, suppress_runtime = not def.includeRuntimeContext }
	)
	sync(s)
	if not ok then
		return nil, "Preset prompt could not be assembled: " .. tostring(preview)
	end
	local candidate_names = {}
	for _, sec in ipairs(candidate_sections) do
		candidate_names[sec.name] = true
	end
	for _, sec in ipairs(preview.sections or {}) do
		if sec.candidate then
			if sec.status == "shadowed" then
				local by = sec.shadowed_by
				return nil,
					("Preset section %q is shadowed by %s (%s); preset not applied"):format(
						sec.name,
						by and by.name or "another section",
						by and by.layer or "unknown"
					)
			elseif sec.status == "removed" then
				return nil, ("Preset section %q is removed; preset not applied"):format(sec.name)
			elseif
				sec.status == "preempted_by_complete"
				and not (def.complete and preview.complete and candidate_names[preview.complete])
			then
				return nil, "Preset prompt is hidden by a complete system replacement; preset not applied"
			elseif sec.active and not sec.preserved then
				return nil, "Preset prompt was not preserved after context hooks; preset not applied"
			end
		end
	end
	return true
end

local function release_lock(s)
	while #s.lock_waiters > 0 do
		local next_waiter = table.remove(s.lock_waiters, 1)
		if not next_waiter.cancelled then
			next_waiter.granted = true
			if not next_waiter.tx or next_waiter.tx:send(true) then
				return
			end
			next_waiter.granted = false
		end
	end
	s.lock_held = false
end

local function with_serial_lock(s, fn)
	local mine = { granted = false, cancelled = false }
	local guard <close> = setmetatable({}, {
		__close = function()
			if mine.granted then
				mine.granted = false
				release_lock(s)
			else
				mine.cancelled = true
			end
		end,
	})
	if s.lock_held then
		if mare and mare.task and type(mare.task.channel) == "function" then
			local rx
			mine.tx, rx = mare.task.channel()
			s.lock_waiters[#s.lock_waiters + 1] = mine
			rx:recv()
		elseif coroutine.isyieldable() then
			s.lock_waiters[#s.lock_waiters + 1] = mine
			while not mine.granted do
				coroutine.yield()
			end
		else
			return nil, "Preset selection already in progress"
		end
	else
		s.lock_held = true
		mine.granted = true
	end
	if s.disposed then
		return nil, "Presets plugin disposed"
	end
	return fn()
end

local function unavailable_err(s, id)
	return s.broken[id] and ("Broken preset: " .. s.broken[id]) or ("Unknown preset: " .. tostring(id))
end

local function blocked(s, allow_switching)
	return ((s.ctx.agent:get() or {}).busy == true) or (not allow_switching and s.ctx.session:switching())
end

local function clear_preset(s)
	if s.active == nil then
		dispose_context(s)
		return true
	end
	s.active, s.active_signature = nil, nil
	dispose_context(s)
	s.ctx.bus:emit("presets/selection-changed", { cleared = true, generation = s.generation })
	return true
end

local function check_preset_tools_and_model(s, def)
	for _, name in ipairs(def.tools_list or {}) do
		if not name:find("[*?]") and not s.ctx.tools:get(name) then
			return nil, "Preset tool is unavailable: " .. name
		end
	end
	if def.model then
		local model = s.ctx.llm:resolve(def.model)
		if not model then
			return nil, "Unknown preset model: " .. def.model
		end
		return model
	end
	return s.ctx.llm:current()
end

local function commit_preset(s, id, def)
	dispose_context(s)
	for _, sec in ipairs(D.build_sections(def)) do
		s.context_disposers[#s.context_disposers + 1] = s.ctx.context:section(sec)
	end
	if not def.includeRuntimeContext then
		s.context_disposers[#s.context_disposers + 1] = s.ctx.context:suppress_runtime()
	end
	s.active, s.active_signature = id, mare.json.encode(def)
	s.ctx.context:invalidate()
	s.ctx.bus:emit("presets/selection-changed", { id = id, generation = s.generation })
	return true
end

local function apply_locked(s, id, opts, caller_generation)
	sync(s)
	if s.generation ~= caller_generation then
		return nil, "Session changed while waiting to apply preset; preset not applied"
	end
	local allow_switching = opts and opts.allow_switching == true
	if blocked(s, allow_switching) then
		return nil, "Apply presets only while the agent and session are idle"
	end
	if s.ctx.session:info().readonly then
		return nil, "Cannot apply a preset in a read-only session"
	end
	if id == nil or id == "clear" then
		return clear_preset(s)
	end
	local def = lookup(s, id)
	if not def then
		return nil, unavailable_err(s, id)
	end
	if s.active == id and s.active_signature == mare.json.encode(def) and not def.model then
		return true
	end
	local model, req_err = check_preset_tools_and_model(s, def)
	if req_err then
		return nil, req_err
	end
	local owner = s.generation
	local ok_preview, preview_err = validate_prompt_preview(s, def, model)
	if not ok_preview then
		return nil, preview_err
	end
	if owner ~= s.generation or blocked(s, allow_switching) then
		return nil, "Session or agent changed while checking the preset; preset not applied"
	end
	if def.model then
		-- Ordinary /model semantics: the original alias applies its pinned parameters
		-- and the service saves the default/recent model. Never pretend to roll back.
		local ok, selected = pcall(s.ctx.llm.set_model, s.ctx.llm, def.model)
		s.ctx.context:invalidate()
		sync(s)
		if not ok or not selected then
			return nil,
				"Preset model selection failed; the model may have changed, and no rollback was attempted: "
					.. tostring(selected)
		end
		if owner ~= s.generation or blocked(s, allow_switching) then
			return nil,
				"Session or agent changed after model selection; the model was not rolled back and preset guidance was not applied"
		end
	end
	return commit_preset(s, id, def)
end

local function apply(s, id, opts)
	sync(s)
	local caller_generation = s.generation
	return with_serial_lock(s, function()
		return apply_locked(s, id, opts, caller_generation)
	end)
end

local function effective_default(s, definitions)
	if s.selected_default ~= nil then
		return s.selected_default
	end
	local best_id, best_def
	for _, item in ipairs(definitions or s.ctx.subagent:list_types().data) do
		local id, def = item.name, selection_definition(s, item)
		if def.default == true then
			if not best_id or def.order < best_def.order or (def.order == best_def.order and id < best_id) then
				best_id, best_def = id, def
			end
		end
	end
	return best_id
end

local function is_default(s, id)
	return id ~= nil and id == effective_default(s)
end

local function apply_initial(s, allow_switching)
	sync(s)
	if s.auto_applied_generation == s.generation then
		return
	end
	local info = s.ctx.session:info()
	local has_messages = require("mare_lib").callable(s.ctx.agent.messages) and #s.ctx.agent:messages() > 0
	if s.active ~= nil or info.readonly or info.resume_error or has_messages then
		s.auto_applied_generation = s.generation
		return
	end
	local target, was_staged = s.staged_id, s.staged_id ~= nil
	if not was_staged then
		target = effective_default(s)
	end
	if target == nil then
		s.auto_applied_generation = s.generation
		return
	end
	local ok, err = apply(s, target, { allow_switching = allow_switching })
	if not ok then
		if err then
			warn("Preset auto-apply failed: " .. tostring(err))
			if mare.ui and mare.ui.connected and mare.ui.connected() and mare.ui.notify then
				pcall(mare.ui.notify, "Preset auto-apply failed: " .. tostring(err), "warning")
			end
		end
		return
	end
	s.auto_applied_generation = s.generation
	if was_staged and s.staged_id == target then
		local cleared, clear_err = set_staged(s, nil)
		if not cleared then
			warn("Preset staged clear failed: " .. tostring(clear_err))
		end
	end
end

local function list_presets(s)
	sync(s)
	local result = (mare and mare.json and mare.json.array) and mare.json.array({}) or {}
	local definitions = s.ctx.subagent:list_types().data
	local default_id = effective_default(s, definitions)
	for _, item in ipairs(definitions) do
		local id, def = item.name, selection_definition(s, item)
		result[#result + 1] = {
			id = id,
			name = def.name,
			description = def.description,
			order = def.order,
			current = s.active == id,
			default = default_id == id,
			staged = s.staged_id == id,
			definition = def,
		}
	end
	for id, reason in pairs(s.broken) do
		result[#result + 1] =
			{ id = id, name = id, order = 0, broken = reason, current = false, default = false, staged = false }
	end
	table.sort(result, function(a, b)
		return a.order < b.order or (a.order == b.order and a.id < b.id)
	end)
	return result
end

local function set_default(s, id)
	if id ~= nil and not lookup(s, id) then
		return nil, unavailable_err(s, id)
	end
	local ok, err = write_persisted_field(s, "default", id)
	if not ok then
		return nil, err
	end
	s.selected_default = id == nil and s.cfg.default or id
	s.ctx.bus:emit("presets/updated", { id = s.selected_default, action = "default" })
	return true
end

local function stage_preset(s, id)
	if id ~= nil and not lookup(s, id) then
		return nil, unavailable_err(s, id)
	end
	return set_staged(s, id)
end

local function raise_preset_error(err, default_code)
	local msg = tostring(err or "preset operation failed")
	local lower = msg:lower()
	local code = default_code or "presets_unavailable"
	if lower:find("unknown preset", 1, true) or lower:find("broken", 1, true) or lower:find("invalid", 1, true) then
		code = "unknown_preset"
	end
	if mare and type(mare.error) == "function" then
		error(mare.error("presets." .. code, msg), 0)
	end
	error(msg, 0)
end

local function unwrap_preset(res, err, default_code)
	if res == nil and err ~= nil then
		raise_preset_error(err, default_code)
	end
	return res
end

local function provide_service(s)
	require("mare_lib").service(s.ctx, "presets", {
		current = function()
			sync(s)
			return {
				id = s.active,
				definition = s.active and lookup(s, s.active) or nil,
			}
		end,
		select = function(_, _, id)
			return unwrap_preset(apply(s, id))
		end,
		set_default = function(_, _, id)
			return unwrap_preset(set_default(s, id))
		end,
		stage = function(_, _, id)
			return unwrap_preset(stage_preset(s, id))
		end,
		staged = function()
			return { id = s.staged_id }
		end,
	})
end

local function register_hooks(s)
	s.ctx:effect(function()
		return function()
			s.disposed = true
			for _, release in pairs(s.type_disposers) do
				pcall(release)
			end
			if s.on_dispose_ui then
				pcall(s.on_dispose_ui)
			end
			dispose_context(s)
		end
	end)
	s.ctx.llm:constrain_tools(function()
		return constrain_tools(s)
	end)
	for _, ev_name in ipairs({ "mcp/ready", "mcp/changed", "profile/tools-changed", "turn/started", "step/started" }) do
		s.ctx:on(ev_name, function()
			refresh_types(s)
		end)
	end
	s.ctx:on("session/changed", function(ev)
		sync(s)
		if ev and ev.reason == "new" then
			apply_initial(s, true)
		end
	end)
	s.ctx:on("session/new", function()
		apply_initial(s, true)
	end)
	s.ctx:on("session/started", function(ev)
		sync(s)
		if not (ev and ev.resumed) then
			apply_initial(s, false)
		end
	end)
end

return function(ctx, cfg)
	local signatures, broken, broken_lines, type_disposers, initial_tools_sig = init_definitions(ctx, cfg)
	local persisted = read_persisted_state()
	local s = {
		ctx = ctx,
		cfg = cfg,
		type_signatures = signatures,
		type_disposers = type_disposers,
		last_tools_signature = initial_tools_sig,
		broken = broken,
		broken_lines = broken_lines,
		active = nil,
		active_signature = nil,
		generation = nil,
		auto_applied_generation = nil,
		selected_default = type(persisted.default) == "string" and persisted.default or cfg.default,
		staged_id = type(persisted.staged) == "string" and persisted.staged or nil,
		context_disposers = {},
		lock_held = false,
		lock_waiters = {},
		disposed = false,
		on_dispose_ui = nil,
	}

	register_hooks(s)
	provide_service(s)

	return {
		read = function(id)
			return lookup(s, id)
		end,
		broken_lines = s.broken_lines,
		sync = function()
			return sync(s)
		end,
		generation = function()
			return s.generation
		end,
		active = function()
			return s.active
		end,
		staged_id = function()
			return s.staged_id
		end,
		effective_default = function()
			return effective_default(s)
		end,
		is_default = function(id)
			return is_default(s, id)
		end,
		list = function()
			return list_presets(s)
		end,
		apply = function(id, opts)
			return apply(s, id, opts)
		end,
		set_default = function(id)
			return set_default(s, id)
		end,
		stage_preset = function(id)
			return stage_preset(s, id)
		end,
		set_on_dispose = function(fn)
			s.on_dispose_ui = fn
		end,
	}
end
