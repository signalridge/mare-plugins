---@meta
-- Public LuaLS type annotations for the `schedule` plugin.

---@class mare.Ctx
---@field schedule? mare.ScheduleService

---@class mare.ScheduleService
local Schedule = {}

---@param prompt string
---@param interval_ms? integer
---@return string Raises structured error (`schedule.invalid_schedule`, `schedule.schedule_unavailable`).
function Schedule:create(prompt, interval_ms) end

---@return table[]
function Schedule:list() end

---@param action "pause"|"resume"|"stop"
---@param target? string
---@return { ok: boolean, note: string } Raises structured error (`schedule.invalid_schedule`, `schedule.not_found`, `schedule.schedule_unavailable`).
function Schedule:control(action, target) end

---@param args table
---@return boolean Raises structured error (`schedule.invalid_schedule`, `schedule.schedule_unavailable`).
function Schedule:submit(args) end

---@async
---@param args table
---@param options? { cancel?: mare.Token }
---@return table Raises structured error (`schedule.invalid_schedule`, `schedule.schedule_unavailable`).
function Schedule:create_durable(args, options) end

---@param filter? table
---@return table Raises structured error (`schedule.invalid_schedule`, `schedule.schedule_unavailable`).
function Schedule:list_durable(filter) end

---@param request table
---@return table Raises structured error (`schedule.invalid_schedule`, `schedule.not_found`, `schedule.schedule_unavailable`).
function Schedule:view(request) end

---@async
---@param request table
---@param options? { cancel?: mare.Token }
---@return table Raises structured error (`schedule.invalid_schedule`, `schedule.not_found`, `schedule.schedule_unavailable`).
function Schedule:edit(request, options) end

---@param request table
---@return table Raises structured error (`schedule.invalid_schedule`, `schedule.not_found`, `schedule.schedule_unavailable`).
function Schedule:history(request) end

---@async
---@param options? { cancel?: mare.Token }
---@return table Raises structured error (`schedule.invalid_schedule`, `schedule.schedule_unavailable`).
function Schedule:delete_inactive(options) end

---@async
---@param request table
---@param options? { cancel?: mare.Token }
---@return table Raises structured error (`schedule.invalid_schedule`, `schedule.not_found`, `schedule.schedule_unavailable`).
function Schedule:run(request, options) end

---@return table
function Schedule:delivery_limits() end
