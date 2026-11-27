-- Independent validation of goal objective, token budget, and automatic round allowance.
local M = {}
function M.validate(cfg, objective, budget, max_rounds)
	local integer = require("goal.journal").integer
	if type(objective) ~= "string" or not objective:find("%S") then
		return nil, "objective must be non-empty"
	end
	if budget == nil then
		budget = cfg.max_token_budget
	end
	if budget ~= nil and not integer(budget, 1) then
		return nil, "token_budget must be a positive safe integer"
	end
	if budget ~= nil and cfg.max_token_budget and budget > cfg.max_token_budget then
		return nil, "token_budget exceeds configured max_token_budget (" .. cfg.max_token_budget .. ")"
	end
	if max_rounds == nil then
		max_rounds = cfg.default_max_rounds
	end
	if not integer(max_rounds, 1) then
		return nil, "max_goal_rounds must be a positive safe integer"
	end
	return { objective = objective:match("^%s*(.-)%s*$"), token_budget = budget, max_goal_rounds = max_rounds }
end
function M.fresh(cfg, objective, budget, max_rounds)
	local value, err = M.validate(cfg, objective, budget, max_rounds)
	if not value then
		return nil, err
	end
	local at = math.floor(mare.task.now())
	return {
		id = mare.crypto.random_hex(16),
		revision = 1,
		objective = value.objective,
		status = "active",
		token_budget = value.token_budget,
		tokens_used = 0,
		usage_complete = true,
		time_used_seconds = 0,
		audit_epoch = 1,
		audit_rounds = 0,
		empty_rounds = 0,
		rounds_started = 0,
		max_goal_rounds = value.max_goal_rounds,
		created_at = at,
		updated_at = at,
	}
end
return M
