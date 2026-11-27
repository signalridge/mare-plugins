---@meta
-- Public LuaLS type annotations for the `codemode` plugin.

---@class mare.Ctx
---@field codemode? mare.CodemodeService

---@class mare.CodemodeService
local Codemode = {}

---@return boolean
function Codemode:available() end
