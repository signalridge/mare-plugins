-- Goal-owned data registered through the shared lifecycle activity contract.
-- The core does not know this namespace or these goal status fields.
return function(ctx, runtime)
	ctx.agent:register_activity("goal", function()
		local view = runtime.view()
		local g = view.goal
		if not g then
			return nil
		end
		return {
			ref = g.ref,
			status = g.status,
			activation = g.activation,
			objective_preview = mare.text.cut(g.objective, 200, { unit = "chars" }),
			rounds_started = g.rounds_started,
			max_goal_rounds = g.max_goal_rounds,
			audit_rounds = g.audit_rounds,
			tokens_used = g.tokens_used,
			token_budget = g.token_budget,
			time_used_seconds = g.time_used_seconds,
			usage_complete = g.usage_complete,
			blocker = g.blocker
				and { code = g.blocker.code, message = mare.text.cut(g.blocker.message, 200, { unit = "chars" }) },
		}
	end)
end
