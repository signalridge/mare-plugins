return {
	name = "plan-mode",
	tags = {},
	provide = { "plan_mode" },
	contracts = {
		plan_mode = {
			doc = "Session-scoped plan mode state and scoped reasoning effort.",
			methods = {
				active = {
					doc = "Return whether plan mode is currently active in the session.",
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
				state = {
					doc = "Return a detached view of the current plan mode state.",
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
				effort = {
					doc = "Return the scoped reasoning effort override state for plan mode.",
					expose = "lua",
					scope = "session",
					optional = true,
					params = {
						type = "object",
						properties = {},
						additionalProperties = false,
					},
					order = {},
					result = { type = "object" },
				},
			},
		},
		["plan-mode"] = {
			owner = "plan-mode",
			doc = "Plan mode state change events.",
			events = {
				changed = {
					doc = "Plan mode active state or revision changed.",
					mode = "emit",
					expose = "lua",
					retain = "last",
					data = {
						type = "object",
						properties = {
							active = { type = "boolean" },
							revision = { type = "integer" },
						},
						required = { "active", "revision" },
						additionalProperties = true,
					},
				},
			},
		},
	},
	-- usage is optional (a user can turn it off; then the context-usage label is omitted): a
	-- follower below, so its absence does not prevent the plugin from starting.
	inject = { "session", "context", "commands", "ui", "agent", "tools", "bus", "policy", "task", "llm" },
	config_schema = {
		section = {
			type = "string",
			default = "Plan mode (soft guidance) is active. Investigate existing facts, requirements and constraints, then propose a concrete implementation plan and validation. Do not implement while this mode is active; an execution request does not itself leave it. Present the complete plan with exit_plan_mode for explicit user review. A task checklist is separate from plan mode. Tool permissions and sandbox policy apply independently.",
			desc = "System prompt policy section injected while plan mode is active.",
			apply = "next_op",
		},
		plan_effort = {
			type = "string",
			default = nil,
			nullable = true,
			desc = "Optional reasoning effort level applied while plan mode is active.",
			apply = "live",
		},
		effort_scope = {
			type = "enum",
			choices = { "plan", "global" },
			default = "plan",
			desc = "Whether reasoning effort changes are scoped to plan mode or applied globally.",
			apply = "live",
		},
		enforce = {
			type = "boolean",
			default = true,
			desc = "Enforce plan mode tool restrictions.",
			apply = "live",
		},
		allow_tools = {
			type = "list",
			items = { type = "string" },
			default = {},
			desc = "Additional tools allowed while plan mode is active.",
			apply = "live",
		},
	},
	apply = function(ctx, cfg)
		if not cfg.section:find("%S") then
			error("plan-mode section must be non-empty text")
		end
		if cfg.plan_effort ~= nil and cfg.plan_effort ~= false and not cfg.plan_effort:find("%S") then
			error("plan-mode plan_effort must be a non-empty string or nil")
		end
		if cfg.enforce ~= nil and type(cfg.enforce) ~= "boolean" then
			error("plan-mode enforce must be a boolean")
		end
		if cfg.allow_tools ~= nil then
			if type(cfg.allow_tools) ~= "table" then
				error("plan-mode allow_tools must be a list of tool names")
			end
			for i, name in pairs(cfg.allow_tools) do
				if
					math.type(i) ~= "integer"
					or i < 1
					or i > #cfg.allow_tools
					or type(name) ~= "string"
					or name == ""
				then
					error("plan-mode allow_tools must be a list of non-empty strings")
				end
			end
		end
		local state
		local effort = require("plan_mode.effort")(ctx, cfg, function()
			return state and state.current().active or false
		end, function()
			return state and state.view() or nil
		end)
		local function changed(reason)
			if reason == "waiting" then
				return -- a caller started waiting; no state changed
			end
			ctx.ui:invalidate("plan-mode")
			local view = state.view()
			view.reason = reason
			effort.sync(view.active)
			ctx.bus:emit("plan-mode/changed", view)
		end
		ctx:effect(function()
			return effort.dispose
		end)
		state = require("plan_mode.state")(ctx, changed)
		local options_of = require("mare_lib").follow(ctx, "options")
		local gate = require("plan_mode.gate")(cfg, state, options_of, ctx)
		ctx.policy:voter("tool/before", gate.vote) -- tool/before requires a policy decision.
		-- usage is optional: follow it while it is up; without it the
		-- review dialog omits the context-usage label and plan-mode still restores and gates
		local usage_of = require("mare_lib").follow(ctx, "usage")
		local review = require("plan_mode.review")(ctx, state, usage_of)
		local function mode_tag()
			return cfg.enforce == false and "soft guidance" or "local writes blocked"
		end
		ctx.context:section({
			name = "plan-mode:policy",
			order = 1500,
			interpolate = false,
			text = function(_, info)
				return state.request_active(info.step_id) and cfg.section or nil
			end,
		})
		ctx.ui:widget("plan-mode", {
			slot = "above-editor",
			render = function(_, height)
				local view = state.view()
				return mare.ui.Lines(height > 0 and (view.active or view.pending ~= nil) and {
					mare.ui.Line(
						"PLAN — "
							.. mode_tag()
							.. (view.unconfirmed and "; save pending" or view.pending ~= nil and "; change queued" or "")
							.. "; /plan off to leave"
					),
				} or {})
			end,
		})
		ctx.tools:register("exit_plan_mode", {
			description = "Present a complete Markdown plan for review. Approval leaves plan mode from the next step; otherwise revise using the user's feedback.",
			side_effect = "write",
			idempotent = false,
			timeout_ms = false,
			admit = function(info)
				return state.request_active(info and info.step_id) or state.current().entered
			end,
			parameters = {
				type = "object",
				additionalProperties = false,
				required = { "plan" },
				properties = { plan = { type = "string" } },
			},
			execute = function(args, tctx)
				return review(args.plan, tctx.cancel, tctx.tool_call_id)
			end,
		})
		local function has_attachments(content)
			if type(content) ~= "table" then
				return false
			end
			for _, block in ipairs(content) do
				if type(block) == "table" and block.type ~= "text" then
					return true
				end
			end
			return #content > 1
		end
		local function format_mode_notice(entering, outcome)
			local ephemeral = ctx.session:info().ephemeral and " This run only (not saved)." or ""
			if outcome == "superseded" then
				return "A later /plan choice replaced this one."
			end
			if not entering then
				if outcome == "queued" then
					return "Leaving plan mode (applies from the next step)."
				end
				if outcome == "cancelled" then
					return "Plan mode entry cancelled."
				end
				if outcome == "noop" then
					return "Plan mode is already inactive."
				end
				return ("Plan mode off (%s). Tool permissions apply independently."):format(mode_tag()) .. ephemeral
			end
			if outcome == "queued" then
				return "Entering plan mode (applies from the next step). Use /plan off to leave."
			end
			if outcome == "cancelled" then
				return "Plan mode exit cancelled."
			end
			if outcome == "noop" then
				return ("Plan mode is already active (%s). Use /plan off to leave."):format(mode_tag())
			end
			return ("Plan mode on (%s). Tool permissions apply independently."):format(mode_tag()) .. ephemeral
		end
		ctx.commands:register("plan", {
			description = "Enter plan mode, manage plan effort, plan a message, or leave with off",
			args = "[off|status|effort|message]",
			complete = function(prefix)
				local items = {}
				for _, sub in ipairs({ "off", "on", "status", "effort" }) do
					if sub:sub(1, #prefix) == prefix then
						items[#items + 1] = { label = sub, insert = sub }
					end
				end
				return items
			end,
			run = function(args, input)
				local content = input and input.content or mare.json.array({ { type = "text", text = args } })
				local attached = has_attachments(content)
				if args == "status" then
					if attached then
						return { status = "rejected", reason = "Attachments cannot accompany /plan status" }
					end
					local view = state.view()
					local summary = effort.summary()
					mare.ui.notify(
						"Plan mode "
							.. (view.active and "on" or "off")
							.. (" (%s)"):format(mode_tag())
							.. (view.unconfirmed and "; save pending" or view.pending ~= nil and "; change queued" or "")
							.. (summary and ("; " .. summary) or "")
					)
					return
				end
				if args == "effort" or args:match("^effort%s+") then
					if attached then
						return { status = "rejected", reason = "Attachments cannot accompany /plan effort" }
					end
					return effort.command(args:match("^effort%s*(.*)$") or "")
				end
				if args == "off" and attached then
					return { status = "rejected", reason = "Attachments cannot accompany /plan off" }
				end
				local entering = args ~= "off"
				local ok, outcome_or_err = state.select(entering, true)
				if not ok then
					return { status = "rejected", reason = outcome_or_err }
				end
				if entering and outcome_or_err ~= "superseded" and ((args ~= "" and args ~= "on") or attached) then
					if args == "on" and content[1] and content[1].type == "text" then
						content[1].text = ""
					end
					local busy = (ctx.agent:get() or {}).busy == true
					local delivery = input and input.delivery or (busy and "steer" or "auto")
					if delivery == "auto" and busy then
						delivery = "steer"
					end
					local text = (content[1] and content[1].type == "text" and content[1].text) or ""
					if delivery == "steer" then
						ctx.agent:steer(text, { content = content })
					elseif delivery == "follow_up" then
						ctx.agent:prompt(text, { content = content, source = "user", when_busy = "queue" })
					else
						local result = ctx.agent:prompt(text, { content = content, source = "user" })
						if
							result
							and result.status == "started"
							and result.turn_id
							and type(ctx.agent.wait) == "function"
						then
							result = ctx.agent:wait(result.turn_id)
						end
						if result and result.error then
							local msg = require("mare_lib").error_message(result.error)
							return {
								status = "rejected",
								reason = (type(msg) == "string" and msg ~= "") and msg or "prompt failed",
							}
						end
					end
				end
				mare.ui.notify(format_mode_notice(entering, outcome_or_err))
			end,
		})
		require("mare_lib").service(ctx, "plan_mode", {
			active = function()
				return state.current().active
			end,
			state = function()
				return state.view()
			end,
			effort = function()
				return effort.state()
			end,
		})
		ctx.agent:register_activity("plan_mode", function()
			return state.view()
		end)
		state.restore()
	end,
}
