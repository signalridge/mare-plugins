---@meta

---@class PresetDefinition
---@field name? string
---@field description? string
---@field order? number
---@field default? boolean Whether this preset is marked as the deployment default.
---@field system? string Literal guidance appended to the system prompt (not interpolated).
---@field prefix? string Persona prefix template (strictly interpolated; shadows global persona).
---@field suffix? string Persona suffix template (strictly interpolated; shadows global suffix).
---@field complete? boolean Make prefix (or system) the complete system prompt.
---@field includeRuntimeContext? boolean Set to false to suppress optional runtime-context sections.
---@field model? string Original model reference or alias; ordinary /model save/recent semantics.
---@field tools? string[] nil leaves tools unchanged; globs (*, ?) supported; {} prohibits declarations.
---@field denylist? string[] Tool names or globs (*, ?) to exclude from declarations.

---@class NormalizedPresetDefinition
---@field name string
---@field description? string
---@field order number
---@field system string
---@field prefix? string
---@field suffix? string
---@field complete boolean
---@field includeRuntimeContext boolean
---@field default boolean
---@field model? string
---@field tools_list? string[]
---@field denylist_list? string[]

---@class PresetRow
---@field id string
---@field name string
---@field description? string
---@field order number
---@field current boolean
---@field default boolean
---@field staged? boolean
---@field broken? string Validation error; other definitions remain usable.

--- Selection state for types registered with ctx.subagent. Type registration and listing live
--- only on ctx.subagent; withdrawing a type makes it unavailable for new selections.
---@class PresetsService
local PresetsService = {}
---@return { id?: string, definition?: NormalizedPresetDefinition }
function PresetsService:current() end
---@param id string "clear" removes prompt/tool selection without restoring a model.
---@return boolean Raises structured error (`presets.unknown_preset`, `presets.presets_unavailable`).
function PresetsService:select(id) end
---@param id? string
---@return boolean Raises structured error (`presets.unknown_preset`, `presets.presets_unavailable`).
function PresetsService:set_default(id) end
---@param id? string
---@return boolean Raises structured error (`presets.unknown_preset`, `presets.presets_unavailable`).
function PresetsService:stage(id) end
---@return { id?: string }
function PresetsService:staged() end

return PresetsService
