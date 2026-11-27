local M = {}

M.DEFAULTS = {
	tool_enabled = false,
	enabled = false,
	tool_name = "workflow",
	max_result_chars = 50000,
	child_result_chars = 12000,
	child_timeout_ms = 7200000,
	stop_grace_ms = 3000,
	max_concurrent_agents = 0,
	max_total_agents = 1000,
	max_items_per_call = 4096,
	sync_timeout_ms = 5000,
	provider = "spawn",
	panel = {
		layout = "grid",
		max_height = 0.33,
		cell_width = 30,
		bar = "braille",
		collapse_done = true,
	},
}

M.CONFIG_SCHEMA = {
	enabled = {
		type = "boolean",
		default = false,
		apply = "live",
		desc = "Enable the workflow orchestration tool and guidance (toggled by /workflow on|off in state.json).",
	},
	tool_name = {
		type = "string",
		default = "workflow",
		apply = "reload",
		desc = "Name of the registered workflow orchestration tool.",
	},
	max_result_chars = {
		type = "integer",
		default = 50000,
		min = 1,
		apply = "next_op",
		desc = "Maximum characters of the formatted workflow return value.",
	},
	child_result_chars = {
		type = "integer",
		default = 12000,
		min = 1,
		apply = "next_op",
		desc = "Maximum characters retained from a single subagent output.",
	},
	child_timeout_ms = {
		type = "integer",
		default = 7200000,
		min = 1,
		unit = "ms",
		apply = "next_op",
		desc = "Timeout per child subagent invocation in milliseconds.",
	},
	stop_grace_ms = {
		type = "integer",
		default = 3000,
		min = 1,
		max = 600000,
		unit = "ms",
		apply = "next_op",
		desc = "Grace period to wait for child subagents and sandbox VM cleanup on cancellation.",
	},
	max_concurrent_agents = {
		type = "integer",
		default = 0,
		min = 0,
		apply = "next_op",
		desc = "Maximum concurrent subagents (0 = auto: min(16, max(1, cpus - 2))).",
	},
	max_total_agents = {
		type = "integer",
		default = 1000,
		min = 1,
		apply = "next_op",
		desc = "Maximum total subagent invocations allowed in a single workflow run.",
	},
	max_items_per_call = {
		type = "integer",
		default = 4096,
		min = 1,
		apply = "next_op",
		desc = "Maximum items accepted by a single parallel() or pipeline() call.",
	},
	sync_timeout_ms = {
		type = "integer",
		default = 5000,
		min = 1,
		unit = "ms",
		apply = "next_op",
		desc = "Watchdog timeout for synchronous script slices without host progress.",
	},
	provider = {
		type = "string",
		default = "spawn",
		apply = "next_op",
		desc = "Subagent runner backend (default: spawn).",
	},
	panel = {
		type = "object",
		desc = "Live workflow progress panel appearance and layout.",
		fields = {
			layout = {
				type = "enum",
				choices = { "grid", "list" },
				default = "grid",
				apply = "live",
				desc = "Panel layout style: grid or list.",
			},
			max_height = {
				type = "number",
				default = 0.33,
				min = 0.05,
				max = 1.0,
				apply = "live",
				desc = "Maximum fraction of terminal height occupied by the workflow panel.",
			},
			cell_width = {
				type = "integer",
				default = 30,
				min = 12,
				apply = "live",
				desc = "Preferred cell width in columns for grid layout.",
			},
			bar = {
				type = "enum",
				choices = { "braille", "block", "ascii" },
				default = "braille",
				apply = "live",
				desc = "Progress bar glyph style (falls back to ascii when terminal is not UTF-8).",
			},
			collapse_done = {
				type = "boolean",
				default = true,
				apply = "live",
				desc = "Collapse completed members into a summary line when vertical space is tight.",
			},
		},
	},
}

local function merge_defaults(raw, defaults)
	local out = {}
	raw = type(raw) == "table" and raw or {}
	for k, v in pairs(defaults) do
		if type(v) == "table" then
			out[k] = merge_defaults(raw[k], v)
		elseif raw[k] ~= nil then
			out[k] = raw[k]
		else
			out[k] = v
		end
	end
	return out
end

function M.normalize(raw)
	local cfg = merge_defaults(raw, M.DEFAULTS)
	if type(cfg.tool_name) ~= "string" or cfg.tool_name:match("^%s*$") then
		cfg.tool_name = M.DEFAULTS.tool_name
	end
	cfg.stop_grace_ms = math.max(1, math.min(600000, math.floor(tonumber(cfg.stop_grace_ms) or 3000)))
	cfg.panel.max_height = math.max(0.05, math.min(1.0, tonumber(cfg.panel.max_height) or 0.33))
	cfg.panel.cell_width = math.max(12, math.floor(tonumber(cfg.panel.cell_width) or 30))
	if cfg.panel.layout ~= "grid" and cfg.panel.layout ~= "list" then
		cfg.panel.layout = "grid"
	end
	if cfg.panel.bar ~= "braille" and cfg.panel.bar ~= "block" and cfg.panel.bar ~= "ascii" then
		cfg.panel.bar = "braille"
	end
	return cfg
end

function M.detect_cpus()
	local env_cpus = mare and mare.env and mare.env.get and tonumber(mare.env.get("MARE_WORKFLOW_CPUS"))
	if env_cpus and env_cpus >= 1 then
		return math.floor(env_cpus)
	end
	if mare and mare.fs and mare.fs.read then
		local ok, cpuinfo = pcall(mare.fs.read, "/proc/cpuinfo")
		if ok and type(cpuinfo) == "string" and cpuinfo ~= "" then
			local count = 0
			for _ in cpuinfo:gmatch("processor%s*:") do
				count = count + 1
			end
			if count > 0 then
				return count
			end
		end
	end
	return 4
end

function M.resolve_concurrency(cfg)
	local n = tonumber(cfg and cfg.max_concurrent_agents) or 0
	if n > 0 then
		return math.floor(n)
	end
	local cpus = M.detect_cpus()
	return math.min(16, math.max(1, cpus - 2))
end

function M.load_enabled(cfg)
	local fallback = false
	if type(cfg) == "table" then
		if type(cfg.tool_enabled) == "boolean" then
			fallback = cfg.tool_enabled
		elseif type(cfg.enabled) == "boolean" then
			fallback = cfg.enabled
		end
	end
	if not (mare and mare.state and type(mare.state.read) == "function") then
		return fallback
	end
	local ok, st = pcall(mare.state.read)
	if ok and type(st) == "table" and type(st.workflow_enabled) == "boolean" then
		return st.workflow_enabled
	end
	return fallback
end

function M.save_enabled(enabled)
	if not (mare and mare.state and type(mare.state.set) == "function") then
		return false, "state storage is unavailable"
	end
	local ok, err = pcall(mare.state.set, "workflow_enabled", enabled == true)
	if not ok then
		return false, tostring(err)
	end
	return true
end

return M
