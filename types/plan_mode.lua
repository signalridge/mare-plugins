---@meta
-- Public LuaLS type annotations for the `plan-mode` plugin.

---@class mare.Ctx
---@field plan_mode? mare.PlanModeService

---@class mare.PlanModeService
local PlanMode = {}

---@return boolean
function PlanMode:active() end

---@return table
function PlanMode:state() end

---@return table?
function PlanMode:effort() end
