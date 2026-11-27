---@meta
--- Public terminals plugin service contract, declared independently in init.lua.
---@class mare.TerminalsBackend
---@field open fun(options: table, cancel: mare.Token): mare.Pty Must return the public bounded/policy-fenced transport. The pending callback is cancelled and joined when its owner unloads or the tool is cancelled. Shell startup must emit OSC 133;D;<status> followed by the controlled mare> prompt.
---@field bootstrap? string Input queued before startup readiness (for shells unable to configure a prompt from environment).
---@class mare.Ctx
---@field terminals? mare.TerminalsService
---@class mare.TerminalsService
local terminals = {}
--- Register a backend for terminal_open.type. Registration is withdrawn with caller scope;
--- live transports from that backend are killed and asynchronously stopped; closing and cleanup_error remain visible if stop cannot be confirmed.
---@param name string
---@param backend mare.TerminalsBackend
function terminals:register(name, backend) end
---@return string[]
function terminals:list() end
