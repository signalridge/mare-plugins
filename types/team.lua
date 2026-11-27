---@meta
-- Public LuaLS type annotations for the `team` plugin.

---@alias mare.TeamTaskStatus "pending"|"in_progress"|"completed"|"cancelled"
---@alias mare.TeamTaskPriority "low"|"medium"|"high"

---@class mare.TeamTaskNote
---@field timestamp integer
---@field author string
---@field text string

---@class mare.TeamTask
---@field id string
---@field seq integer
---@field title string
---@field description? string
---@field status mare.TeamTaskStatus
---@field priority mare.TeamTaskPriority
---@field blocked_by string[]
---@field blocks string[]
---@field unresolved_blockers string[]
---@field ready boolean
---@field blocked boolean
---@field owner? string
---@field lease_token? string
---@field lease_expires_at_ms? integer
---@field lease_active boolean
---@field lease_stale boolean
---@field revision integer
---@field notes mare.TeamTaskNote[]
---@field result? string
---@field created_at_ms integer
---@field updated_at_ms integer
---@field completed_at_ms? integer

---@class mare.TeamSnapshot
---@field tasks mare.TeamTask[]
---@field counts {total: integer, pending: integer, ready: integer, blocked: integer, in_progress: integer, completed: integer, cancelled: integer}

---@class mare.TeamService
local TeamService = {}
---@async
---@param args {title: string, description?: string, priority?: mare.TeamTaskPriority, blocked_by?: string[], owner?: string, lease_ms?: integer}
---@return mare.TeamTask
function TeamService:create(args) end
---@param opts? {status?: mare.TeamTaskStatus, owner?: string, ready_only?: boolean, include_completed?: boolean}
---@return mare.TeamSnapshot
function TeamService:list(opts) end
---@async
---@param args? {id?: string, owner?: string, lease_ms?: integer, force?: boolean}
---@return mare.TeamTask
function TeamService:claim(args) end
---@async
---@param args {id: string, title?: string, description?: string, status?: mare.TeamTaskStatus, priority?: mare.TeamTaskPriority, owner?: string, add_blocked_by?: string[], remove_blocked_by?: string[], note?: string, renew_lease?: boolean, lease_ms?: integer, expected_revision?: integer, lease_token?: string, force?: boolean}
---@return mare.TeamTask
function TeamService:update(args) end
---@async
---@param args {id: string, owner?: string, result?: string, note?: string, expected_revision?: integer, lease_token?: string, force?: boolean}
---@return {task: mare.TeamTask, unblocked: string[]}
function TeamService:complete(args) end
---@async
---@return {cleared: integer}
function TeamService:clear() end

---@class mare.Ctx
---@field team? mare.TeamService
