-- Session-scoped durable goal lifecycle management using public mare services only.
return {
	name = "goal",
	tags = {},
	provide = { "goals" },
	contracts = {
		goals = {
			doc = "Session-scoped durable goal lifecycle management.",
			errors = {
				stale_ref = { doc = "goal reference does not match the active session goal or revision" },
				invalid_goal = { doc = "invalid goal objective, budget, max_rounds, or blocker reason" },
				goal_fault = { doc = "goal journal fault or persistence failure" },
				goal_unavailable = { doc = "goal operation failed or goal is unavailable in this state" },
			},
			methods = {
				get = {
					doc = "Return a detached view of the current session's goal state.",
					expose = "lua",
					scope = "session",
					params = {
						type = "object",
						properties = {},
						additionalProperties = false,
					},
					order = {},
					result = { type = { "object", "null" } },
				},
				create = {
					doc = "Create a new durable goal in the current session.",
					expose = "lua",
					scope = "session",
					params = {
						type = "object",
						properties = {
							objective = { type = "string" },
							token_budget = { type = { "integer", "null" } },
							max_goal_rounds = { type = { "integer", "null" } },
						},
						required = { "objective" },
						additionalProperties = false,
					},
					order = { "objective", "token_budget", "max_goal_rounds" },
					result = { type = "object" },
					errors = { "invalid_goal", "goal_fault", "goal_unavailable" },
				},
				replace = {
					doc = "Replace the current goal referenced by ref with a new objective.",
					expose = "lua",
					scope = "session",
					params = {
						type = "object",
						properties = {
							ref = { type = "object" },
							objective = { type = "string" },
							token_budget = { type = { "integer", "null" } },
							max_goal_rounds = { type = { "integer", "null" } },
						},
						required = { "ref", "objective" },
						additionalProperties = false,
					},
					order = { "ref", "objective", "token_budget", "max_goal_rounds" },
					result = { type = "object" },
					errors = { "stale_ref", "invalid_goal", "goal_fault", "goal_unavailable" },
				},
				edit = {
					doc = "Edit the objective, budget, or max_rounds of the referenced goal.",
					expose = "lua",
					scope = "session",
					params = {
						type = "object",
						properties = {
							ref = { type = "object" },
							objective = { type = { "string", "null" } },
							token_budget = { type = { "integer", "null" } },
							max_goal_rounds = { type = { "integer", "null" } },
						},
						required = { "ref" },
						additionalProperties = false,
					},
					order = { "ref", "objective", "token_budget", "max_goal_rounds" },
					result = { type = "object" },
					errors = { "stale_ref", "invalid_goal", "goal_fault", "goal_unavailable" },
				},
				pause = {
					doc = "Pause the referenced active goal.",
					expose = "lua",
					scope = "session",
					params = {
						type = "object",
						properties = { ref = { type = "object" } },
						required = { "ref" },
						additionalProperties = false,
					},
					order = { "ref" },
					result = { type = "object" },
					errors = { "stale_ref", "goal_fault", "goal_unavailable" },
				},
				resume = {
					doc = "Resume the referenced paused goal.",
					expose = "lua",
					scope = "session",
					params = {
						type = "object",
						properties = { ref = { type = "object" } },
						required = { "ref" },
						additionalProperties = false,
					},
					order = { "ref" },
					result = { type = "object" },
					errors = { "stale_ref", "goal_fault", "goal_unavailable" },
				},
				complete = {
					doc = "Mark the referenced goal as complete.",
					expose = "lua",
					scope = "session",
					params = {
						type = "object",
						properties = { ref = { type = "object" } },
						required = { "ref" },
						additionalProperties = false,
					},
					order = { "ref" },
					result = { type = "object" },
					errors = { "stale_ref", "goal_fault", "goal_unavailable" },
				},
				block = {
					doc = "Mark the referenced goal as blocked with a structured reason.",
					expose = "lua",
					scope = "session",
					params = {
						type = "object",
						properties = {
							ref = { type = "object" },
							reason = { type = "object" },
						},
						required = { "ref", "reason" },
						additionalProperties = false,
					},
					order = { "ref", "reason" },
					result = { type = "object" },
					errors = { "stale_ref", "invalid_goal", "goal_fault", "goal_unavailable" },
				},
				clear = {
					doc = "Clear the referenced goal from the session.",
					expose = "lua",
					scope = "session",
					params = {
						type = "object",
						properties = { ref = { type = "object" } },
						required = { "ref" },
						additionalProperties = false,
					},
					order = { "ref" },
					result = { type = "object" },
					errors = { "stale_ref", "goal_fault", "goal_unavailable" },
				},
			},
		},
		goal = {
			owner = "goal",
			doc = "Session goal lifecycle events.",
			events = {
				changed = {
					doc = "Session goal state changed (sets cleared = true when the goal is cleared).",
					mode = "emit",
					expose = "lua",
					retain = "last",
					data = {
						type = "object",
						properties = {
							revision = { type = "integer" },
							cleared = { type = "boolean" },
						},
						required = { "revision", "cleared" },
						additionalProperties = true,
					},
				},
			},
		},
	},
	inject = { "session", "agent", "tools", "context", "commands", "bus", "policy", "task" },
	config_schema = {
		default_max_rounds = {
			type = "integer",
			default = 256,
			min = 1,
			desc = "Default maximum number of automatic rounds for a newly created goal.",
			apply = "next_op",
		},
		blocked_after_consecutive_rounds = {
			type = "integer",
			default = 3,
			min = 1,
			desc = "Consecutive automatic goal rounds required before the model may mark a goal blocked.",
			apply = "next_op",
		},
		max_token_budget = {
			type = "integer",
			default = nil,
			nullable = true,
			min = 1,
			unit = "tokens",
			desc = "Optional ceiling (and default when set) for goal token budgets.",
			apply = "next_op",
		},
	},
	apply = function(ctx, cfg)
		local policy = require("goal.policy").render(cfg.blocked_after_consecutive_rounds)
		local store = require("goal.state")(ctx)
		local serial = require("goal.queue")(function(owner)
			if owner and store.same(owner, store.owner()) then
				store.fault =
					"A goal transaction was interrupted before acknowledgement; reload the session to verify its durable state."
			end
		end)
		local runtime = require("goal.runtime")(ctx, store, serial, policy, cfg)
		require("goal.interface")(ctx, store, runtime, policy)
		runtime.restore()
		require("goal.service")(ctx, store, runtime)
		require("goal.activity")(ctx, runtime)
	end,
}
