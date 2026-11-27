-- Independently implemented public goals service (detached views and exact refs).
-- Session ID/generation extends that ref because Mare can replace its live session.
-- Control callers must have an explicit user instruction; model access is via goal tools.
return function(ctx, store, runtime)
	local function fail(code, msg)
		local text = tostring(msg or "goal error")
		if mare and type(mare.error) == "function" then
			error(mare.error("goals." .. code, text), 0)
		end
		error(text, 0)
	end
	local function classify_error(err)
		if store.fault then
			return "goal_fault"
		end
		local lower = tostring(err):lower()
		if lower:find("stale goal", 1, true) then
			return "stale_ref"
		end
		if
			lower:find("exhaust", 1, true)
			or lower:find("already complete", 1, true)
			or lower:find("no current goal", 1, true)
			or lower:find("not paused", 1, true)
			or lower:find("not active", 1, true)
			or lower:find("not blocked", 1, true)
		then
			return "goal_unavailable"
		end
		if
			lower:find("objective", 1, true)
			or lower:find("budget", 1, true)
			or lower:find("round", 1, true)
			or lower:find("blocker", 1, true)
			or lower:find("invalid", 1, true)
			or lower:find("must be", 1, true)
			or lower:find("exceed", 1, true)
		then
			return "invalid_goal"
		end
		return "goal_unavailable"
	end
	local function check(ref)
		if store.fault then
			fail("goal_fault", store.fault)
		end
		local g, owner = store.get(), store.owner()
		if
			type(ref) ~= "table"
			or not g
			or ref.goal_id ~= g.id
			or ref.revision ~= g.revision
			or ref.session_id ~= owner.id
			or ref.generation ~= owner.generation
		then
			fail("stale_ref", "stale goal reference; read goals:get() again")
		end
	end
	local function changed(value, err)
		if err then
			fail(classify_error(err), err)
		end
		if value and value.status == "active" then
			runtime.stopped = false
			runtime.ready = true
			runtime.attach()
			runtime.kick()
		end
		return runtime.view()
	end
	require("mare_lib").service(ctx, "goals", {
		get = function()
			return runtime.view()
		end,
		create = function(_, _, objective, budget, max_rounds)
			return changed(runtime.create(objective, budget, max_rounds))
		end,
		replace = function(_, _, ref, objective, budget, max_rounds)
			check(ref)
			return changed(runtime.replace(ref, objective, budget, max_rounds))
		end,
		edit = function(_, _, ref, objective, budget, max_rounds)
			check(ref)
			return changed(runtime.edit(objective, budget, max_rounds, nil, ref))
		end,
		pause = function(_, _, ref)
			check(ref)
			local value, failure = runtime.status("paused", true, ref)
			if value then
				runtime.cancel()
			end
			return changed(value, failure)
		end,
		resume = function(_, _, ref)
			check(ref)
			local value, failure, kind, receipt = runtime.resume_user(ref)
			if failure then
				fail(classify_error(failure), failure)
			end
			if kind == "goal" then
				return changed(value)
			end
			local view = runtime.view()
			view.resume = { status = kind, receipt = receipt }
			return view
		end,
		complete = function(_, _, ref)
			check(ref)
			return changed(runtime.status("complete", true, ref))
		end,
		block = function(_, _, ref, reason)
			check(ref)
			if
				type(reason) ~= "table"
				or type(reason.code) ~= "string"
				or type(reason.message) ~= "string"
				or not reason.code:match("^[a-z][a-z0-9-]*$")
				or reason.code:find("--", 1, true)
				or reason.code:sub(-1) == "-"
				or not reason.message:find("%S")
			then
				fail("invalid_goal", "block requires a stable code and concrete message")
			end
			for key in pairs(reason) do
				if key ~= "code" and key ~= "message" then
					fail("invalid_goal", "unknown blocker field")
				end
			end
			return changed(runtime.status("blocked", true, ref, reason.message, reason.code))
		end,
		clear = function(_, _, ref)
			check(ref)
			local _, failure, written = runtime.mutate(function(g)
				if not g or not runtime.matches_ref(g, store.owner(), ref) then
					return nil, "stale goal reference; read goals:get() again"
				end
				return nil
			end)
			if not written then
				fail(store.fault and "goal_fault" or classify_error(failure), failure)
			end
			runtime.cancel()
			return runtime.view()
		end,
	})
end
