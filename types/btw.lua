---@meta
-- Public LuaLS type annotations for the `btw` plugin.

---@class mare.Ctx
---@field btw? mare.BtwService

---@class mare.BtwService
local Btw = {}

---@return table
function Btw:status() end

---@return table
function Btw:transcript() end

function Btw:view() end

---@return table Raises structured error (`btw.btw_unavailable`).
function Btw:toggle() end

---@return boolean Raises structured error (`btw.btw_unavailable`).
function Btw:close() end

---@param text string
---@param opts? table
---@return table
function Btw:ask(text, opts) end
