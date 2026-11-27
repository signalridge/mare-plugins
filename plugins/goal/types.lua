---@meta
-- Public plugin contract; control callers own explicit user authorization.
---@class mare.GoalRef
---@field goal_id string
---@field revision integer Lifecycle revision; usage and round accounting do not invalidate it.
---@field session_id string
---@field generation string
---@class mare.GoalSnapshot
---@field id string
---@field revision integer
---@field ref mare.GoalRef
---@field objective string
---@field status "active"|"paused"|"blocked"|"complete"|"budget_limited"|"usage_limited"
---@field token_budget? integer
---@field tokens_used integer Reported input/cache/output tokens, never estimated unknown usage.
---@field usage_complete boolean
---@field time_used_seconds number
---@field rounds_started integer Admitted automatic rounds which reached request history.
---@field audit_rounds integer Consecutive automatic rounds in the current audit epoch.
---@field audit_epoch integer
---@field empty_rounds integer
---@field created_at integer Epoch milliseconds.
---@field updated_at integer
---@field last_round_id? string
---@field last_finished_round_id? string
---@field last_reason? string
---@field stop_reason? string
---@field activation "armed"|"disarmed"
---@field remaining_tokens? integer
---@field max_goal_rounds integer
---@field blocker? {code:string,message:string}
---@field continuation_stopped boolean
---@class mare.GoalView
---@field goal? mare.GoalSnapshot
---@field revision integer Journal revision, distinct from the lifecycle reference.
---@field owner {id:string,generation:string}
---@field fault? string
---@field resume? {status:"foreground"|"pending",receipt?:{status:"started",turn_id:string,input_id:string}} Retained foreground input takes priority without resuming or charging the goal.
---@class mare.Ctx
---@field goals? mare.GoalsService

---@class mare.GoalsService
local Goals = {}
---@return mare.GoalView
function Goals:get() end
---@async
---@param objective string
---@param token_budget? integer Only when explicitly requested.
---@param max_goal_rounds? integer Defaults to goal.default_max_rounds.
---@return mare.GoalView Raises structured error (`goals.invalid_goal`, `goals.goal_fault`, `goals.goal_unavailable`).
function Goals:create(objective, token_budget, max_goal_rounds) end
---@async
---@param ref mare.GoalRef
---@param objective string
---@param token_budget? integer
---@param max_goal_rounds? integer Must cover already admitted rounds.
---@return mare.GoalView Raises structured error (`goals.invalid_goal`, `goals.stale_ref`, `goals.goal_fault`, `goals.goal_unavailable`).
function Goals:edit(ref, objective, token_budget, max_goal_rounds) end
---@async
---@param ref mare.GoalRef
---@return mare.GoalView Raises structured error (`goals.stale_ref`, `goals.goal_fault`, `goals.goal_unavailable`).
--- Host pause cancels only this goal's owned turn and retains the canonical inbox.
function Goals:pause(ref) end
---@async
---@param ref mare.GoalRef
---@return mare.GoalView Raises structured error (`goals.stale_ref`, `goals.goal_fault`, `goals.goal_unavailable`).
--- Resource checks precede foreground delivery. A foreground/pending result leaves
--- the goal's phase unchanged; pending retries after the exact current run settles.
function Goals:resume(ref) end
---@async
---@param ref mare.GoalRef
---@return mare.GoalView Raises structured error (`goals.stale_ref`, `goals.goal_fault`, `goals.goal_unavailable`).
function Goals:clear(ref) end

---@async
---@param ref mare.GoalRef
---@return mare.GoalView Raises structured error (`goals.invalid_goal`, `goals.stale_ref`, `goals.goal_fault`, `goals.goal_unavailable`).
function Goals:complete(ref) end
---@async
---@param ref mare.GoalRef
---@param reason {code:string,message:string}
---@return mare.GoalView Raises structured error (`goals.invalid_goal`, `goals.stale_ref`, `goals.goal_fault`, `goals.goal_unavailable`).
function Goals:block(ref, reason) end

--- Explicit operator replacement, not model create: validates first, then writes a
--- clear tombstone and fresh snapshot serially. A failed second ACK leaves the clear.
---@async
---@param ref mare.GoalRef
---@param objective string
---@param token_budget? integer
---@param max_goal_rounds? integer
---@return mare.GoalView Raises structured error (`goals.invalid_goal`, `goals.stale_ref`, `goals.goal_fault`, `goals.goal_unavailable`).
function Goals:replace(ref, objective, token_budget, max_goal_rounds) end
