---@meta
-- Public LuaLS type annotations for the `session-title` plugin.

---@class mare.Ctx
---@field session_title? mare.SessionTitleService

---@class mare.SessionTitleService
local SessionTitle = {}

---@return table?
function SessionTitle:get() end

---@async
---@param opts? table
---@return table|boolean Raises structured error (`session_title.title_unavailable`).
function SessionTitle:refresh(opts) end

---@async
---@param name string
---@return boolean Raises structured error (`session_title.invalid_title`, `session_title.title_unavailable`).
function SessionTitle:rename(name) end

---@param opts { id: string, automatic: "first-prompt"|"all-prompts" }
---@param callbacks { generate: fun(work: table): table? }
---@return table
function SessionTitle:register(opts, callbacks) end

---@return boolean
function SessionTitle:cancel() end
