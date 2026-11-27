---@meta
-- Public LuaLS type annotations for the `workflow` plugin.

---@class mare.WorkflowPanelConfig
---@field layout? "grid"|"list"
---@field max_height? number Fraction of terminal height (default 0.33)
---@field cell_width? integer Preferred grid cell width in columns (default 30)
---@field bar? "braille"|"block"|"ascii"
---@field collapse_done? boolean Collapse finished members when height is constrained (default true)

---@class mare.WorkflowConfig
---@field tool_enabled? boolean Whether workflow tool & prompt guidance are active (default false)
---@field tool_name? string Registered tool name (default "workflow")
---@field max_result_chars? integer Max formatted return text characters (default 50000)
---@field child_result_chars? integer Max characters retained per child agent result (default 12000)
---@field child_timeout_ms? integer Per-child agent timeout in ms (default 7200000)
---@field stop_grace_ms? integer Cooperative cancel grace period in ms (default 3000)
---@field max_concurrent_agents? integer Max concurrent subagents (0 = auto: min(16, max(1, cpus - 2)))
---@field max_total_agents? integer Max total subagents per workflow run (default 1000)
---@field max_items_per_call? integer Max items per parallel/pipeline call (default 4096)
---@field sync_timeout_ms? integer Max synchronous Lua slice without host progress in ms (default 5000)
---@field provider? string Subagent runner provider ("spawn")
---@field panel? mare.WorkflowPanelConfig

---@class mare.WorkflowPhaseMeta
---@field title string
---@field detail? string
---@field provider? string
---@field model? string

---@class mare.WorkflowMeta
---@field name string Short kebab-case workflow identifier
---@field description string One-line summary of what this run does
---@field when_to_use? string
---@field phases? mare.WorkflowPhaseMeta[]

---@class mare.WorkflowAgentOpts
---@field label? string
---@field phase? string
---@field provider? string
---@field model? string
---@field effort? string
---@field schema? table Restricted JSON Schema (object root)
---@field tools? string[]
---@field system? string
---@field cwd? string
