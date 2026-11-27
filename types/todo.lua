---@meta
-- Public LuaLS type annotations for the `todo` plugin.

---@class mare.TodoItem
---@field content string
---@field status string

---@class mare.TodoSnapshot
---@field todos mare.TodoItem[]?
---@field explanation? string

---@class mare.Ctx
---@field todo? mare.TodoService

---@class mare.TodoService
local Todo = {}

---@return mare.TodoSnapshot
function Todo:snapshot() end
