-- Independent implementation of log-backed session title state and provider registration.
return {
	name = "session-title",
	tags = {},
	inject = { "session", "llm", "commands", "bus", "task" },
	provide = { "session_title" },
	contracts = {
		session_title = {
			doc = "Session title state, automatic title generation, and provider registration.",
			errors = {
				invalid_title = { doc = "session title must be a non-empty string" },
				title_unavailable = { doc = "session title state or session get/update API is unavailable here" },
			},
			methods = {
				get = {
					doc = "Return the current session title snapshot.",
					expose = "lua",
					scope = "session",
					params = {
						type = "object",
						properties = {},
						additionalProperties = false,
					},
					order = {},
					result = { type = "object" },
				},
				refresh = {
					doc = "Trigger session title generation using the registered provider.",
					expose = "lua",
					scope = "session",
					params = {
						type = "object",
						properties = {
							opts = { type = { "object", "null" } },
						},
						additionalProperties = false,
					},
					order = { "opts" },
					result = { type = { "object", "boolean" } },
					errors = { "title_unavailable" },
				},
				rename = {
					doc = "Set the current session title explicitly.",
					expose = "lua",
					scope = "session",
					params = {
						type = "object",
						properties = {
							name = { type = "string" },
						},
						required = { "name" },
						additionalProperties = false,
					},
					order = { "name" },
					result = { type = "boolean" },
					errors = { "invalid_title", "title_unavailable" },
				},
				register = {
					doc = "Register a session title generator provider for the caller's lifetime.",
					expose = "lua",
					scope = "host",
					registration = true,
					params = {
						type = "object",
						properties = {
							id = { type = "string", description = "Unique title provider identifier." },
							automatic = {
								type = "string",
								enum = { "first-prompt", "all-prompts" },
								description = "Automatic title generation cadence.",
							},
						},
						required = { "id", "automatic" },
						additionalProperties = false,
					},
					order = { "..." },
					callbacks = {
						generate = "fun(work: table): table?",
					},
				},
				cancel = {
					doc = "Cancel any in-flight session title generation work.",
					expose = "lua",
					scope = "session",
					params = {
						type = "object",
						properties = {},
						additionalProperties = false,
					},
					order = {},
					result = { type = "boolean" },
				},
			},
		},
		["session-title"] = {
			owner = "session-title",
			doc = "Session title state change events.",
			events = {
				changed = {
					doc = "Session title state changed.",
					mode = "emit",
					expose = "lua",
					retain = "last",
					data = {
						type = "object",
						properties = {
							state = { type = "object" },
							reason = { type = "string" },
						},
						required = { "state", "reason" },
						additionalProperties = true,
					},
				},
			},
		},
	},
	config_schema = {
		automatic = {
			type = "enum",
			choices = { "first-prompt", "all-prompts" },
			default = "first-prompt",
			desc = "When to automatically generate session titles.",
			apply = "live",
		},
		llm = {
			type = "boolean",
			default = true,
			desc = "Use an LLM to generate session titles; falls back to prompt excerpt when false.",
			apply = "live",
		},
		provider = {
			type = "string",
			default = nil,
			nullable = true,
			desc = "Optional provider override for title generation (must be paired with model).",
			apply = "next_op",
		},
		model = {
			type = "string",
			default = nil,
			nullable = true,
			desc = "Optional model override for title generation (must be paired with provider).",
			apply = "next_op",
		},
		max_input_bytes = {
			type = "integer",
			default = 8192,
			min = 1,
			unit = "bytes",
			desc = "Maximum input bytes sent to the title generator.",
			apply = "next_op",
		},
		max_tokens = {
			type = "integer",
			default = 128,
			min = 1,
			unit = "tokens",
			desc = "Maximum output tokens requested for title generation.",
			apply = "next_op",
		},
		timeout_ms = {
			type = "integer",
			default = 15000,
			min = 1,
			max = 2147483647,
			unit = "ms",
			desc = "Timeout in milliseconds for title generation requests.",
			apply = "next_op",
		},
		max_title_bytes = {
			type = "integer",
			default = 320,
			min = 1,
			unit = "bytes",
			desc = "Maximum byte length of generated session titles.",
			apply = "next_op",
		},
		fallback_max_bytes = {
			type = "integer",
			default = 80,
			min = 1,
			unit = "bytes",
			desc = "Maximum byte length of fallback excerpt titles.",
			apply = "next_op",
		},
		fallback_max_words = {
			type = "integer",
			default = 8,
			min = 1,
			desc = "Maximum word count of fallback excerpt titles.",
			apply = "next_op",
		},
		target_words = {
			type = "integer",
			default = 6,
			min = 1,
			desc = "Target word count for non-CJK generated titles.",
			apply = "next_op",
		},
		target_cjk_characters = {
			type = "integer",
			default = 16,
			min = 1,
			desc = "Target character count for CJK generated titles.",
			apply = "next_op",
		},
	},
	apply = function(ctx, cfg)
		assert(cfg.fallback_max_bytes <= cfg.max_title_bytes, "fallback_max_bytes exceeds max_title_bytes")
		assert(
			(cfg.provider == nil and cfg.model == nil)
				or (
					type(cfg.provider) == "string"
					and cfg.provider:find("%S")
					and type(cfg.model) == "string"
					and cfg.model:find("%S")
				),
			"provider and model must both be nonempty or both omitted"
		)
		require("session_title.runtime")(ctx, cfg)
	end,
}
