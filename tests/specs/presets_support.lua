local support = assert(load(mare.fs.read("tests/specs/support.lua"), "@tests/specs/support.lua"))()

local plugin = support.load_plugin("presets", {
	"presets.definition",
	"presets.runtime",
	"presets.ui",
})

local M = {}

M.definitions = {
	review = { system = "review {{literal}}", tools = { "read" }, default = true },
	all = { system = "all tools" },
	none = { tools = {} },
	missing = { tools = { "unavailable" } },
	selected = { model = "alias-high", system = "selected guidance", tools = { "read" } },
	unknown_model = { model = "missing/model" },
	persona_only = {
		prefix = "You are {{model}} helper.",
		suffix = "Always be concise.",
		includeRuntimeContext = false,
	},
	complete_persona = {
		prefix = "Complete {{model}} persona.",
		complete = true,
	},
	bad_var = {
		prefix = "Hello {{unknown_var}}",
	},
	glob_deny = {
		tools = { "read*" },
		denylist = { "read_file" },
	},
	deny_only = {
		denylist = { "bash", "write" },
	},
}

function M.clear_persisted_state()
	if mare and mare.state and type(mare.state.update) == "function" then
		mare.state.update(function(st)
			st = type(st) == "table" and st or {}
			st.presets = nil
			return st
		end)
	end
end

function M.fixture(defs, extra_cfg, opts)
	opts = opts or {}
	local f = {
		generation = "one",
		invalidations = 0,
		notices = {},
		events = {},
		hooks = {},
		model = { ref = "original", id = "orig-id" },
		calls = {},
		sections = {},
		suppress_count = 0,
		models = {
			["alias-high"] = { ref = "other/model", id = "other-id" },
		},
		types = require("presets.definition").copy(opts.initial_types or {}),
		list_type_calls = 0,
		available_tools = { "read", "read_file", "bash", "write" },
	}
	if opts.models then
		for ref, model in pairs(opts.models) do
			f.models[ref] = model
		end
	end
	f.alternate = f.models["alias-high"]

	mare.ui.connected = function()
		return f.connected
	end
	mare.ui.select = function(options)
		f.dialog = options
		if f.picker_hook then
			f.picker_hook()
		end
		return f.pick
	end
	mare.ui.notify = function(text, level)
		f.notices[#f.notices + 1] = { text = text, level = level }
	end

	local function render_section(sec, model)
		local text = type(sec.text) == "function" and sec.text(model) or sec.text
		if not text or text == "" then
			return nil
		end
		if sec.interpolate ~= false then
			text = text:gsub("{{([%w_]+)}}", function(var)
				if var == "model" then
					return model and model.id or "unknown"
				end
				error("unknown prompt variable {{" .. var .. "}}")
			end)
		end
		return text
	end

	local function model_known(model)
		if model == f.model then
			return true
		end
		for _, candidate in pairs(f.models) do
			if model == candidate then
				return true
			end
		end
		return false
	end

	local ctx = {
		effect = function(_, setup)
			local callback = setup()
			f.dispose = callback
		end,
		provide = function(_, name, service)
			assert(name == "presets")
			f.service = service
		end,
		emit = function(_, event, payload)
			local snap = {
				event = event,
				payload = payload,
				model = f.model and f.model.ref,
				prompt = f.sections and f:prompt() or nil,
				tools = f.constraint and f.constraint() or nil,
			}
			f.events[#f.events + 1] = snap
			if f.on_emit then
				f.on_emit(event, payload, snap)
			end
		end,
		agent = {
			get = function()
				return { busy = f.busy }
			end,
		},
		session = {
			info = function()
				return {
					session_epoch = f.generation,
					readonly = f.readonly,
					count = f.session_count,
					resume_error = f.resume_error,
				}
			end,
			switching = function()
				return f.switching
			end,
		},
		llm = {
			constrain_tools = opts.with_constrain_tools ~= false and function(_, callback)
				f.constraint = callback
			end or nil,
			current = function()
				return f.model
			end,
			resolve = function(_, ref)
				return f.models[ref]
			end,
			set_model = function(_, ref, ...)
				assert(f.models[ref] and select("#", ...) == 0)
				f.calls[#f.calls + 1] = ref
				f.model, f.saved, f.recent, f.effort = f.models[ref], ref, { ref }, "high"
				if f.setter_failure then
					error("setter failed after model changed")
				end
				if f.on_set_model then
					f.on_set_model(ref)
				end
				return f.model
			end,
		},
		subagent = {
			register_type = function(_, def, options)
				local previous = f.types[def.name]
				assert(previous == nil or (options and options.replace), "duplicate subagent type")
				local entry = require("presets.definition").copy(def)
				f.types[def.name] = entry
				return function()
					if f.types[def.name] == entry then
						f.types[def.name] = previous
					end
				end
			end,
			list_types = function()
				f.list_type_calls = f.list_type_calls + 1
				local out = {}
				for _, def in pairs(f.types) do
					out[#out + 1] = require("presets.definition").copy(def)
				end
				table.sort(out, function(a, b)
					return a.name < b.name
				end)
				return { data = out }
			end,
		},
		tools = {
			revision = function()
				f.tool_revision_calls = (f.tool_revision_calls or 0) + 1
				return #f.available_tools
			end,
			get = function(_, name)
				for _, candidate in ipairs(f.available_tools) do
					if candidate == name then
						return true
					end
				end
				return false
			end,
			list = function()
				local result = {}
				for _, name in ipairs(f.available_tools) do
					result[#result + 1] = { name = name }
				end
				return result
			end,
		},
		commands = {
			register = function(_, name, def)
				assert(name == "preset" and def.availability == "idle")
				f.command = def.run
			end,
		},
		context = {
			section = function(_, section)
				f.sections[#f.sections + 1] = section
				local disposed = false
				return function()
					if disposed then
						return
					end
					disposed = true
					for i, item in ipairs(f.sections) do
						if item == section then
							table.remove(f.sections, i)
							break
						end
					end
				end
			end,
			suppress_runtime = function()
				f.suppress_count = f.suppress_count + 1
				local disposed = false
				return function()
					if disposed then
						return
					end
					disposed = true
					f.suppress_count = f.suppress_count - 1
				end
			end,
			invalidate = function()
				f.invalidations = f.invalidations + 1
				f.cached = nil
			end,
			preview = function(_, model, _, preview_opts)
				assert(model_known(model))
				if f.prompt_error then
					error("assembly failed")
				end
				if f.swap then
					f.generation = "other"
				end
				local diag = {}
				local complete_name = f.complete and "external:complete" or nil
				for _, sec in ipairs((preview_opts and preview_opts.sections) or {}) do
					if sec.complete and f.complete then
						error('two complete prompt sections are active: "external:complete" and "' .. sec.name .. '"')
					end
					local rendered = render_section(sec, model)
					if sec.complete and rendered then
						complete_name = sec.name
					end
				end
				for _, sec in ipairs((preview_opts and preview_opts.sections) or {}) do
					local status = "active"
					local active = true
					local shadowed_by = nil
					if f.shadowed == sec.name then
						status = "shadowed"
						active = false
						shadowed_by = { name = sec.name, layer = "agent", owner = "other" }
					elseif complete_name and complete_name ~= sec.name then
						status = "preempted_by_complete"
						active = false
					end
					diag[#diag + 1] = {
						name = sec.name,
						candidate = true,
						status = status,
						active = active,
						preserved = not f.unpreserved,
						shadowed_by = shadowed_by,
					}
				end
				return {
					text = "preview",
					complete = complete_name,
					runtime_suppressed = preview_opts and preview_opts.suppress_runtime or false,
					sections = diag,
				}
			end,
			system_prompt = function(_, model)
				assert(model_known(model))
				if f.prompt_error then
					error("assembly failed")
				end
				if f.complete then
					return "complete"
				end
				local parts = { "base" }
				for _, sec in ipairs(f.sections) do
					local text = render_section(sec, model)
					if text then
						parts[#parts + 1] = text
					end
				end
				f.cached = f.cached or table.concat(parts, " ")
				return f.cached
			end,
		},
		on = function(_, event, callback)
			f.hooks[event] = callback
		end,
	}
	f.context = ctx.context
	f.subagent = ctx.subagent

	local cfg = { definitions = defs or M.definitions }
	if extra_cfg then
		for k, v in pairs(extra_cfg) do
			cfg[k] = v
		end
	end
	plugin.apply(ctx, cfg)

	function f:last()
		return self.notices[#self.notices]
	end

	function f:prompt()
		return self.context:system_prompt(self.model)
	end

	return f
end

return M
