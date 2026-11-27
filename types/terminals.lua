---@meta
-- Public LuaLS type annotations for the `terminals` plugin.

---@class mare.TerminalsBackend
---@field open fun(options: table, cancel: mare.Token): mare.Pty Must return the public bounded/policy-fenced transport.
---@field bootstrap? string Input queued before startup readiness.

---@class mare.Ctx
---@field terminals? mare.TerminalsService

---@class mare.TerminalsService
local Terminals = {}

--- Register a backend for terminal_open.type. Registration is withdrawn with caller scope.
---@param name string
---@param backend mare.TerminalsBackend
function Terminals:register(name, backend) end

---@return string[]
function Terminals:list() end
