-- Independently implemented using public mare APIs; no upstream code copied.
return {
	name = "presets",
	tags = {},
	inject = { "agent", "commands", "context", "llm", "session", "subagent", "tools", "bus" },
	provide = { "presets" },
	contracts = {
		presets = {
			doc = "Named model, prompt, and toolset presets.",
			events = {
				updated = {
					doc = "Staged or default preset was updated.",
					mode = "emit",
					expose = "lua",
					data = {
						type = "object",
						properties = {
							action = { type = "string", enum = { "staged", "default" } },
							id = { type = { "string", "null" } },
						},
						required = { "action" },
						additionalProperties = true,
					},
				},
				["selection-changed"] = {
					doc = "Active session preset selection changed.",
					mode = "emit",
					expose = "lua",
					retain = "last",
					data = {
						type = "object",
						properties = {
							id = { type = { "string", "null" } },
							cleared = { type = "boolean" },
							generation = { type = "string" },
						},
						additionalProperties = true,
					},
				},
			},
			errors = {
				unknown_preset = {
					doc = "no configured or registered preset has that id, or its definition is invalid",
				},
				presets_unavailable = { doc = "preset state or persistence failed" },
			},
			methods = {
				current = {
					doc = "Return the currently active preset id and its definition.",
					expose = "lua",
					scope = "session",
					params = {
						type = "object",
						properties = {},
						additionalProperties = false,
					},
					order = {},
					result = {
						type = "object",
						properties = {
							id = { type = "string" },
							definition = { type = "object" },
						},
						additionalProperties = false,
					},
				},
				select = {
					doc = "Activate a preset by id or clear the active preset when nil.",
					expose = "lua",
					scope = "session",
					params = {
						type = "object",
						properties = { id = { type = { "string", "null" } } },
						additionalProperties = false,
					},
					order = { "id" },
					result = { type = "boolean" },
					errors = { "unknown_preset", "presets_unavailable" },
				},
				set_default = {
					doc = "Set or clear the default preset id.",
					expose = "lua",
					scope = "host",
					optional = true,
					params = {
						type = "object",
						properties = { id = { type = { "string", "null" } } },
						additionalProperties = false,
					},
					order = { "id" },
					result = { type = "boolean" },
					errors = { "unknown_preset", "presets_unavailable" },
				},
				stage = {
					doc = "Stage a preset id in shared state.json to apply on the next request or session transition.",
					expose = "lua",
					scope = "host",
					optional = true,
					params = {
						type = "object",
						properties = { id = { type = { "string", "null" } } },
						additionalProperties = false,
					},
					order = { "id" },
					result = { type = "boolean" },
					errors = { "unknown_preset", "presets_unavailable" },
				},
				staged = {
					doc = "Return the currently staged preset id from shared state.json, if any.",
					expose = "lua",
					scope = "host",
					optional = true,
					params = {
						type = "object",
						properties = {},
						additionalProperties = false,
					},
					order = {},
					result = {
						type = "object",
						properties = {
							id = { type = "string" },
						},
						additionalProperties = false,
					},
				},
			},
		},
	},
	config_schema = {
		definitions = {
			type = "map",
			values = { type = "object" },
			default = {},
			desc = "Named preset definitions mapping preset names to configuration objects.",
			apply = "reload",
		},
		default = {
			type = "string",
			default = nil,
			nullable = true,
			desc = "Optional default preset name applied on startup.",
			apply = "reload",
		},
	},
	apply = function(ctx, cfg)
		local rt = require("presets.runtime")(ctx, cfg)
		require("presets.ui")(ctx, rt)
		rt.sync()
	end,
}
