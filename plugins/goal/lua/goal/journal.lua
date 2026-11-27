-- Independent strict fold for durable goal journal records.
-- Resource statuses and durable usage snapshots keep lifecycle refs separate
-- separate from journal sequence so an observed usage event cannot stale every model update.
local M = {}
local MAX = 9007199254740991
local statuses =
	{ active = true, paused = true, blocked = true, complete = true, budget_limited = true, usage_limited = true }
local keys = {
	id = true,
	revision = true,
	objective = true,
	status = true,
	token_budget = true,
	tokens_used = true,
	time_used_seconds = true,
	usage_complete = true,
	audit_epoch = true,
	audit_rounds = true,
	empty_rounds = true,
	rounds_started = true,
	max_goal_rounds = true,
	created_at = true,
	updated_at = true,
	last_reason = true,
	stop_reason = true,
	blocker = true,
	last_round_id = true,
	last_finished_round_id = true,
}
function M.integer(v, min)
	return type(v) == "number" and v == v and v >= min and v <= MAX and v % 1 == 0
end
local function finite(v)
	return type(v) == "number" and v == v and v >= 0 and v <= MAX
end
local function text(v)
	return type(v) == "string" and v:find("%S") and v == v:match("^%s*(.-)%s*$")
end
function M.goal(g)
	if type(g) ~= "table" then
		return nil, "goal must be an object"
	end
	for key in pairs(g) do
		if not keys[key] then
			return nil, "unknown goal field: " .. tostring(key)
		end
	end
	if
		not text(g.id)
		or not text(g.objective)
		or not statuses[g.status]
		or not M.integer(g.revision, 1)
		or not M.integer(g.tokens_used, 0)
		or not finite(g.time_used_seconds)
		or type(g.usage_complete) ~= "boolean"
		or not M.integer(g.audit_epoch, 1)
		or not M.integer(g.audit_rounds, 0)
		or not M.integer(g.empty_rounds, 0)
		or not M.integer(g.rounds_started, 0)
		or not M.integer(g.max_goal_rounds, 1)
		or g.rounds_started > g.max_goal_rounds
		or g.audit_rounds > g.rounds_started
		or not M.integer(g.created_at, 0)
		or not M.integer(g.updated_at, 0)
		or g.updated_at < g.created_at
		or (g.token_budget ~= nil and not M.integer(g.token_budget, 1))
	then
		return nil, "invalid goal fields or integer ranges"
	end
	if (g.rounds_started > 0 and not text(g.last_round_id)) or (g.rounds_started == 0 and g.last_round_id ~= nil) then
		return nil, "invalid round identity"
	end
	for _, key in ipairs({ "last_reason", "stop_reason" }) do
		if g[key] ~= nil and not text(g[key]) then
			return nil, "invalid reason"
		end
	end
	if g.status == "blocked" then
		local b = g.blocker
		if
			type(b) ~= "table"
			or not text(b.code)
			or (not b.code:match("^[a-z][a-z0-9-]*$") or b.code:find("--", 1, true) or b.code:sub(-1) == "-")
			or not text(b.message)
		then
			return nil, "blocked goal requires code and message"
		end
		for key in pairs(b) do
			if key ~= "code" and key ~= "message" then
				return nil, "invalid blocker field"
			end
		end
	elseif g.blocker ~= nil then
		return nil, "only blocked goals carry a blocker"
	end
	if g.status == "budget_limited" and (not g.token_budget or g.tokens_used < g.token_budget) then
		return nil, "invalid budget limit"
	end
	if
		g.status ~= "budget_limited"
		and g.status ~= "complete"
		and g.token_budget
		and g.tokens_used >= g.token_budget
	then
		return nil, "budget exhaustion must take precedence"
	end
	if g.rounds_started == 0 and g.last_finished_round_id ~= nil then
		return nil, "finished round without an admission"
	end
	if g.last_finished_round_id ~= nil and not text(g.last_finished_round_id) then
		return nil, "invalid finished round identity"
	end
	return true
end
local transitions = {
	active = {
		active = true,
		paused = true,
		blocked = true,
		complete = true,
		budget_limited = true,
		usage_limited = true,
	},
	paused = { paused = true, active = true, complete = true, budget_limited = true, usage_limited = true },
	blocked = { blocked = true, active = true, complete = true, budget_limited = true },
	complete = { complete = true, active = true, budget_limited = true },
	budget_limited = { budget_limited = true, active = true, complete = true },
	usage_limited = { usage_limited = true, active = true, budget_limited = true },
}
local function validate_record_header(state, r)
	if
		type(r) ~= "table"
		or r.version ~= 2
		or not M.integer(r.revision, 1)
		or r.revision ~= state.revision + 1
		or type(r.cleared) ~= "boolean"
	then
		return nil, "invalid goal record version or revision"
	end
	for key in pairs(r) do
		if
			key ~= "version"
			and key ~= "revision"
			and key ~= "cleared"
			and key ~= "goal"
			and key ~= "goal_id"
			and key ~= "goal_revision"
			and key ~= "round"
		then
			return nil, "unknown journal field"
		end
	end
	return true
end

local function validate_create_snapshot(state, r, g, previous)
	if (previous and previous.status ~= "complete") or state.seen[g.id] then
		return nil, "unfinished or reused goal identity"
	end
	if
		g.status ~= "active"
		or g.revision ~= 1
		or g.tokens_used ~= 0
		or g.time_used_seconds ~= 0
		or g.audit_epoch ~= 1
		or g.audit_rounds ~= 0
		or g.empty_rounds ~= 0
		or g.rounds_started ~= 0
		or r.round ~= nil
	then
		return nil, "invalid create snapshot"
	end
	return true
end

local function validate_update_snapshot(state, r, g, previous)
	if g.revision ~= previous.revision and g.revision ~= previous.revision + 1 then
		return nil, "non-sequential goal revision"
	end
	local old_blocker, new_blocker = previous.blocker or {}, g.blocker or {}
	local controlled = old_blocker.code ~= new_blocker.code
		or old_blocker.message ~= new_blocker.message
		or g.objective ~= previous.objective
		or g.token_budget ~= previous.token_budget
		or g.max_goal_rounds ~= previous.max_goal_rounds
		or g.status ~= previous.status
	if controlled and g.revision ~= previous.revision + 1 then
		return nil, "controlled mutation must advance goal revision"
	end
	if not transitions[previous.status][g.status] then
		return nil, "illegal goal status transition"
	end
	if
		g.created_at ~= previous.created_at
		or g.updated_at < previous.updated_at
		or g.tokens_used < previous.tokens_used
		or g.time_used_seconds < previous.time_used_seconds
	then
		return nil, "non-monotonic goal accounting"
	end
	local delta = g.rounds_started - previous.rounds_started
	if delta ~= 0 and delta ~= 1 then
		return nil, "non-sequential goal rounds"
	end
	local reset = g.audit_epoch == previous.audit_epoch + 1 and g.audit_rounds == 0
	if not reset and (g.audit_epoch ~= previous.audit_epoch or g.audit_rounds ~= previous.audit_rounds + delta) then
		return nil, "invalid audit round continuity"
	end
	if g.revision == previous.revision + 1 and not controlled and not reset then
		return nil, "lifecycle revision advanced without a lifecycle mutation"
	end
	if
		previous.status == "complete"
		and g.status == "complete"
		and (g.tokens_used ~= previous.tokens_used or g.time_used_seconds ~= previous.time_used_seconds)
	then
		return nil, "completed accounting cannot restart without an edit"
	end
	if
		g.empty_rounds ~= previous.empty_rounds
		and not reset
		and g.status == previous.status
		and g.last_finished_round_id == previous.last_finished_round_id
	then
		return nil, "empty-round counter changed without a round outcome"
	end
	if g.empty_rounds > previous.empty_rounds + 1 then
		return nil, "non-sequential empty round counter"
	end
	local edited = g.objective ~= previous.objective
		or g.token_budget ~= previous.token_budget
		or g.max_goal_rounds ~= previous.max_goal_rounds
	if
		g.status == "budget_limited"
		and previous.status ~= "active"
		and previous.status ~= "budget_limited"
		and not edited
	then
		return nil, "stopped goals cannot acquire usage without a budget edit"
	end
	if edited then
		local expected = (previous.status == "complete" or previous.status == "budget_limited") and "active"
			or previous.status
		if g.status ~= expected and g.status ~= "budget_limited" then
			return nil, "edit cannot perform a separate phase transition"
		end
		if
			previous.status == "blocked"
			and g.status == "blocked"
			and (old_blocker.code ~= new_blocker.code or old_blocker.message ~= new_blocker.message)
		then
			return nil, "edit cannot rewrite a blocker"
		end
	end
	if edited and not reset then
		return nil, "edited goal must reset its audit"
	end
	if previous.status ~= "active" and g.status == "active" and not reset then
		return nil, "resumed goal must reset its audit"
	end
	if delta == 1 then
		if
			previous.status ~= "active"
			or g.status ~= "active"
			or reset
			or edited
			or type(r.round) ~= "table"
			or r.round.source ~= "goal"
			or r.round.turn_id ~= g.last_round_id
			or r.round.index ~= g.rounds_started
			or r.round.audit_epoch ~= g.audit_epoch
			or state.rounds[g.last_round_id]
		then
			return nil, "invalid or repeated automatic round admission"
		end
		for key in pairs(r.round) do
			if key ~= "source" and key ~= "turn_id" and key ~= "index" and key ~= "audit_epoch" then
				return nil, "unknown round field"
			end
		end
	elseif r.round ~= nil or g.last_round_id ~= previous.last_round_id then
		return nil, "round changed without an admission"
	end
	return true
end

local function validate_finished_round(state, g, previous)
	if g.last_finished_round_id then
		local finished = state.rounds[g.last_finished_round_id]
		if type(finished) ~= "table" or finished.goal_id ~= g.id or finished.index > g.rounds_started then
			return nil, "unadmitted finished round"
		end
		if previous and previous.last_finished_round_id then
			local old = state.rounds[previous.last_finished_round_id]
			if type(old) ~= "table" or finished.index < old.index then
				return nil, "finished round regressed"
			end
		end
	elseif previous and previous.id == g.id and previous.last_finished_round_id then
		return nil, "finished round cannot disappear"
	end
	return true
end

local function copy_keys(src)
	local out = {}
	for k, v in pairs(src) do
		out[k] = v
	end
	return out
end

local function copy_rounds(src)
	local out = {}
	for k, v in pairs(src) do
		out[k] = type(v) == "table" and { goal_id = v.goal_id, index = v.index } or v
	end
	return out
end

local function next_journal_state(state, r, g)
	if not g then
		return { revision = r.revision, value = nil, seen = copy_keys(state.seen), rounds = copy_rounds(state.rounds) }
	end
	local seen = copy_keys(state.seen)
	seen[g.id] = true
	local rounds = copy_rounds(state.rounds)
	if r.round then
		rounds[g.last_round_id] = { goal_id = g.id, index = g.rounds_started }
	end
	return { revision = r.revision, value = g, seen = seen, rounds = rounds }
end

function M.validate(state, r)
	local ok, err = validate_record_header(state, r)
	if not ok then
		return nil, err
	end
	local previous = state.value
	if r.cleared then
		if
			not previous
			or r.goal ~= nil
			or r.goal_id ~= previous.id
			or not M.integer(r.goal_revision, 1)
			or r.goal_revision ~= previous.revision + 1
			or r.round ~= nil
		then
			return nil, "invalid clear tombstone"
		end
		return true, nil
	end
	if r.goal_id ~= nil or r.goal_revision ~= nil then
		return nil, "snapshot cannot contain tombstone identity"
	end
	local g = r.goal
	ok, err = M.goal(g)
	if not ok then
		return nil, err
	end
	if not previous or previous.id ~= g.id then
		ok, err = validate_create_snapshot(state, r, g, previous)
	else
		ok, err = validate_update_snapshot(state, r, g, previous)
	end
	if not ok then
		return nil, err
	end
	ok, err = validate_finished_round(state, g, previous)
	if not ok then
		return nil, err
	end
	return true, g
end

function M.advance(acc, r)
	local ok, g_or_err = M.validate(acc, r)
	if not ok then
		return nil, g_or_err
	end
	acc.revision = r.revision
	acc.value = g_or_err
	if g_or_err then
		acc.seen[g_or_err.id] = true
		if r.round then
			acc.rounds[g_or_err.last_round_id] = { goal_id = g_or_err.id, index = g_or_err.rounds_started }
		end
	end
	return acc
end

function M.fold(state, r)
	local ok, g_or_err = M.validate(state, r)
	if not ok then
		return nil, g_or_err
	end
	return next_journal_state(state, r, g_or_err)
end

function M.fold_all(records)
	local acc = { revision = 0, value = nil, seen = {}, rounds = {} }
	for _, r in ipairs(records) do
		local ok, err = M.advance(acc, r)
		if not ok then
			return nil, err, acc
		end
	end
	return acc
end
return M
