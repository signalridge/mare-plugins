-- Plan-mode scoped reasoning effort management.
return function(ctx, cfg, is_active, current_view)
	local M = {}
	local scope_mode = cfg.effort_scope == "global" and "global" or "plan"
	local configured_effort = type(cfg.plan_effort) == "string" and cfg.plan_effort:match("^%s*(.-)%s*$"):lower() or nil
	local override_efforts = {}
	local cleared_models = {}
	local global_applied = false
	local last_owner = nil

	local function get_llm()
		return ctx.llm -- A required dependency keeps the service available for this plugin.
	end

	local function supports_scoped(llm)
		return llm
			and require("mare_lib").callable(llm.set_active_scope)
			and require("mare_lib").callable(llm.scoped_effort)
			and require("mare_lib").callable(llm.clear_scope)
			and require("mare_lib").callable(llm.set_effort)
	end

	local function model_supports_effort(llm, model)
		if not model then
			return false
		end
		if require("mare_lib").callable(llm.effort_options) then
			local opts = llm:effort_options(model)
			return type(opts) == "table" and #opts > 0
		end
		if require("mare_lib").callable(llm.clamp_effort) then
			return llm:clamp_effort(model, "medium") ~= nil
		end
		return true
	end

	local function clamp(llm, model, wanted)
		if not model or not wanted then
			return nil
		end
		if require("mare_lib").callable(llm.clamp_effort) then
			return llm:clamp_effort(model, wanted)
		end
		return wanted
	end

	local function wanted_effort(model)
		local ref = model and model.ref or nil
		if ref and override_efforts[ref] ~= nil then
			return override_efforts[ref]
		end
		if not (ref and cleared_models[ref]) then
			return configured_effort
		end
		return nil
	end

	local function clear_active_plan_scope(llm)
		if supports_scoped(llm) and require("mare_lib").callable(llm.active_scope) and llm:active_scope() == "plan" then
			llm:set_active_scope(nil)
		end
	end

	function M.sync(active)
		local llm = get_llm()
		if not llm then
			return
		end
		local info = ctx.session and require("mare_lib").callable(ctx.session.info) and ctx.session:info() or nil
		local owner = info and (tostring(info.session_id or "") .. "\0" .. tostring(info.session_epoch or "")) or nil
		if owner ~= last_owner then
			last_owner = owner
			global_applied = false
		end
		if not active then
			global_applied = false
			clear_active_plan_scope(llm)
			return
		end
		local model = require("mare_lib").callable(llm.current) and llm:current() or nil
		local has_effort_param = model_supports_effort(llm, model)
		local target = wanted_effort(model)
		if scope_mode == "plan" then
			if not supports_scoped(llm) then
				return
			end
			local scoped = has_effort_param and llm:scoped_effort("plan", model) or nil
			if scoped == nil and target ~= nil and has_effort_param then
				local clamped = clamp(llm, model, target)
				if clamped ~= nil then
					local ok = pcall(llm.set_effort, llm, clamped, { scope_name = "plan", save = false })
					if ok then
						scoped = llm:scoped_effort("plan", model) or clamped
					end
				end
			end
			if scoped ~= nil then
				if not require("mare_lib").callable(llm.active_scope) or llm:active_scope() ~= "plan" then
					llm:set_active_scope("plan")
				end
			else
				clear_active_plan_scope(llm)
			end
			return
		end
		-- Global scope: keep global active scope and apply plan effort globally once per activation.
		clear_active_plan_scope(llm)
		if
			target ~= nil
			and has_effort_param
			and not global_applied
			and require("mare_lib").callable(llm.set_effort)
		then
			local clamped = clamp(llm, model, target)
			if clamped ~= nil then
				local opts = supports_scoped(llm) and { scope_name = "plan", also_global = true, save = false }
					or { save = false }
				if pcall(llm.set_effort, llm, clamped, opts) then
					global_applied = true
				end
			end
		end
	end

	function M.dispose()
		clear_active_plan_scope(get_llm())
	end

	function M.state()
		local llm = get_llm()
		local model = llm and require("mare_lib").callable(llm.current) and llm:current() or nil
		local scoped = supports_scoped(llm) and model and llm:scoped_effort("plan", model) or nil
		local current = llm and require("mare_lib").callable(llm.effort) and llm:effort() or nil
		local active_scope = llm and require("mare_lib").callable(llm.active_scope) and llm:active_scope() or nil
		return {
			scope = scope_mode,
			configured_effort = configured_effort,
			scoped_effort = scoped,
			current_effort = current,
			active_scope = active_scope,
		}
	end

	local function is_temp_flag(tok)
		return tok == "session" or tok == "--session" or tok == "temp" or tok == "--temp"
	end

	local function current_wanted()
		local llm = get_llm()
		local model = llm and require("mare_lib").callable(llm.current) and llm:current() or nil
		return wanted_effort(model)
	end

	function M.summary()
		local st = M.state()
		local parts = {}
		local target = st.scoped_effort or current_wanted()
		if target then
			parts[#parts + 1] = "effort: " .. target .. " (" .. st.scope .. ")"
		elseif st.scope == "global" then
			parts[#parts + 1] = "effort scope: global"
		end
		if st.current_effort then
			parts[#parts + 1] = "current: " .. st.current_effort
		end
		return #parts > 0 and table.concat(parts, ", ") or nil
	end

	function M.command(rest)
		local tokens = {}
		for tok in tostring(rest or ""):gmatch("%S+") do
			tokens[#tokens + 1] = tok:lower()
		end
		local llm = get_llm()
		if #tokens == 0 or tokens[1] == "status" then
			if #tokens > 1 then
				return {
					status = "rejected",
					reason = "Usage: /plan effort [status|clear|scope <plan|global>|<level> [plan|global] [--session]]",
				}
			end
			local st = M.state()
			local target = st.scoped_effort or current_wanted() or "none"
			mare.ui.notify(
				("Plan effort: %s (scope: %s, active scope: %s, current: %s)"):format(
					tostring(target),
					tostring(st.scope),
					tostring(st.active_scope or "global"),
					tostring(st.current_effort or "n/a")
				)
			)
			return nil
		end
		if tokens[1] == "scope" then
			local next_scope = tokens[2]
			if #tokens ~= 2 or (next_scope ~= "plan" and next_scope ~= "global") then
				return { status = "rejected", reason = "Plan effort scope must be 'plan' or 'global'" }
			end
			if next_scope == "plan" and llm and not supports_scoped(llm) then
				return { status = "rejected", reason = "Plan-scoped effort is not supported by this runtime" }
			end
			local previous = scope_mode
			scope_mode = next_scope
			if next_scope == "global" and previous == "plan" and is_active() then
				local model = llm and require("mare_lib").callable(llm.current) and llm:current() or nil
				local scoped = supports_scoped(llm) and model and llm:scoped_effort("plan", model) or nil
				if scoped and model and model.ref then
					override_efforts[model.ref] = scoped
					global_applied = false
				end
			end
			M.sync(is_active())
			mare.ui.notify("Plan effort scope: " .. scope_mode)
			return nil
		end
		if tokens[1] == "clear" or tokens[1] == "off" or tokens[1] == "reset" then
			if #tokens > 2 or (#tokens == 2 and not is_temp_flag(tokens[2])) then
				return { status = "rejected", reason = "Usage: /plan effort clear [--session]" }
			end
			local temporary = #tokens == 2
			local model = llm and require("mare_lib").callable(llm.current) and llm:current() or nil
			local ref = model and model.ref or nil
			if ref then
				cleared_models[ref] = true
				override_efforts[ref] = nil
			end
			global_applied = false
			if supports_scoped(llm) then
				llm:clear_scope("plan", model, { save = not temporary })
			end
			M.sync(is_active())
			mare.ui.notify("Plan effort override cleared" .. (temporary and " (this session)" or ""))
			return nil
		end
		if #tokens > 3 then
			return { status = "rejected", reason = "Usage: /plan effort <level> [plan|global] [--session]" }
		end
		local level = tokens[1]
		local explicit_scope, temporary = nil, false
		for i = 2, #tokens do
			local tok = tokens[i]
			if is_temp_flag(tok) then
				if temporary then
					return { status = "rejected", reason = "Usage: /plan effort <level> [plan|global] [--session]" }
				end
				temporary = true
			elseif tok == "plan" or tok == "global" then
				if explicit_scope ~= nil or temporary then
					return { status = "rejected", reason = "Plan effort scope must be 'plan' or 'global'" }
				end
				explicit_scope = tok
			else
				return { status = "rejected", reason = "Plan effort scope must be 'plan' or 'global'" }
			end
		end
		local target_scope = explicit_scope or scope_mode
		if not llm or not require("mare_lib").callable(llm.set_effort) then
			return { status = "rejected", reason = "LLM effort control is unavailable" }
		end
		if target_scope == "plan" and not supports_scoped(llm) then
			return { status = "rejected", reason = "Plan-scoped effort is not supported by this runtime" }
		end
		local model = require("mare_lib").callable(llm.current) and llm:current() or nil
		if not model then
			return { status = "rejected", reason = "No model selected" }
		end
		if not model_supports_effort(llm, model) then
			return { status = "rejected", reason = (model.ref or "current model") .. " has no effort parameter" }
		end
		local save = not temporary
		local set_opts = target_scope == "plan" and { scope_name = "plan", save = save }
			or (supports_scoped(llm) and { scope_name = "plan", also_global = true, save = save } or { save = save })
		local ok, err = pcall(llm.set_effort, llm, level, set_opts)
		if not ok then
			return { status = "rejected", reason = tostring(err) }
		end
		scope_mode = target_scope
		if model.ref then
			cleared_models[model.ref] = nil
			override_efforts[model.ref] = level
		end
		global_applied = target_scope == "global"
		M.sync(is_active())
		mare.ui.notify(
			("Plan effort set to %s (scope: %s%s)"):format(level, scope_mode, temporary and ", this session" or "")
		)
		return nil
	end

	ctx:on("model/changed", function()
		local lib = require("mare_lib")
		if ctx.session and lib.callable(ctx.session.switching) and ctx.session:switching() then
			return
		end
		local info = ctx.session and lib.callable(ctx.session.info) and ctx.session:info() or nil
		local view = current_view and current_view() or nil
		if
			info
			and view
			and view.generation ~= nil
			and (view.generation ~= info.session_epoch or (view.id ~= nil and view.id ~= info.session_id))
		then
			return
		end
		if is_active() then
			global_applied = false
			M.sync(true)
		end
	end)

	return M
end
