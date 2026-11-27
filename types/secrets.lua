---@meta
--- Local trusted service; registration holds no persistent configuration and reads no credential source.
---@class mare.SecretEntry
---@field name string
---@field reference string
---@class mare.SecretStoredInfo
---@field name string
---@field configured boolean
---@field source? "auth"
---@field scope "profile"
---@field writable boolean
---@field masked? string
---@field invalid? boolean
---@class mare.SecretResolveResult
---@field reference string
---@field source "auth"
---@field scope "profile"
---@class mare.Ctx
---@field secrets? mare.Secrets
---@class mare.Secrets
local Secrets = {}
--- Register an explicit UTF-8 value for the current session. Names cannot be replaced implicitly.
---@param name string
---@param value string
---@return string reference Random opaque reference; every tool restoration still requires approval.
function Secrets:register(name, value) end
---@param name string
---@return boolean removed
function Secrets:remove(name) end
---@return mare.SecretEntry[] No plaintext values; detached sorted view.
function Secrets:list() end
--- Save an explicit non-empty UTF-8 value under a named profile credential entry.
---@param name string
---@param value string
---@return mare.SecretStoredInfo
function Secrets:save(name, value) end
--- Re-read a saved profile entry and register a fresh session reference.
---@param name string
---@return string reference Raises structured error (`secrets.not_configured`).
function Secrets:load(name) end
--- Freshly load a saved profile entry and return its session reference and source metadata.
---@param name string
---@return mare.SecretResolveResult Raises structured error (`secrets.not_configured`).
function Secrets:resolve(name) end
--- Delete a saved profile entry and revoke any active local registration for that name.
---@param name string
---@return mare.SecretStoredInfo
function Secrets:delete(name) end
--- Describe configuration metadata for a named profile entry without returning its value.
---@param name string
---@return mare.SecretStoredInfo
function Secrets:describe(name) end
--- Enumerate saved profile entries with configuration metadata and no plaintext values.
---@return mare.SecretStoredInfo[]
function Secrets:stored() end
