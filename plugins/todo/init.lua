return {
	name = "todo",
	tags = {},
	provide = { "todo" },
	contracts = {
		todo = {
			doc = "Session-scoped task checklist state.",
			methods = {
				snapshot = {
					doc = "Return a detached read-only snapshot of the current session's checklist.",
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
							todos = {
								type = { "array", "null" },
								items = {
									type = "object",
									properties = {
										content = { type = "string" },
										status = { type = "string" },
									},
									required = { "content", "status" },
									additionalProperties = false,
								},
							},
							explanation = { type = { "string", "null" } },
						},
						required = { "todos" },
						additionalProperties = false,
					},
				},
			},
		},
	},
	inject = { "tools", "session", "context", "commands", "ui", "agent", "policy" },
	config_schema = {
		allow_parallel_in_progress = {
			type = "boolean",
			default = false,
			apply = "next_op",
			desc = "Allow more than one todo item to be in_progress at the same time.",
		},
	},
	apply = function(ctx, cfg)
		-- plan_mode is optional: follow it while its provider is available.
		local plan_mode_of = require("mare_lib").follow(ctx, "plan_mode")
		local model, view = require("todo.model"), require("todo.view")
		local state = { todos = nil, collapsed = true }
		local pending_clear
		local function changed(value, explanation)
			state.todos, state.explanation = value, explanation
			ctx.context:invalidate()
			ctx.ui:invalidate("todo")
		end
		local function write(value, explanation, cancel)
			local info = ctx.session:info()
			if mare.mode == "child" then
				return nil,
					"todo_write requires an owning agent session; child session storage is unavailable",
					nil,
					"tool_context_unavailable"
			end
			if info.readonly then
				return nil, "todo cannot be changed in a read-only session", nil, "readonly_session"
			end
			if cancel and cancel:is_cancelled() then
				return nil, "todo update cancelled before saving", true, "cancelled"
			end
			local ok, saved, err = pcall(
				ctx.session.add_record,
				ctx.session,
				"todo/write",
				{ version = 1, todos = value, explanation = explanation, reset = value == nil or nil },
				{ persist = true }
			)
			if not ok or not saved then
				local detail = not ok and (require("mare_lib").error_message(saved) or saved)
					or (require("mare_lib").error_message(err) or err)
				return nil, "todo could not be saved: " .. tostring(detail), nil, "persist_failed"
			end
			if ctx.session:info().session_epoch ~= info.session_epoch then
				return nil, "session changed while saving todos", nil, "stale_session"
			end
			-- A committed snapshot remains committed even if cancellation arrives afterward.
			changed(value, explanation)
			return true
		end
		local function restore()
			pending_clear = nil
			local ok, value, explanation = pcall(function()
				local v, expl = nil, nil
				for _, record in ipairs(require("mare_lib").all_records(ctx.session, "todo/write") or {}) do
					if type(record) ~= "table" or record.version ~= 1 then
						error("unsupported todo record version")
					end
					-- Current write policy must not invalidate a saved parallel list.
					if record.reset == true then
						v, expl = nil, nil
					else
						v, expl = model.canonical(record.todos, true), record.explanation
					end
					if expl ~= nil and type(expl) ~= "string" then
						error("invalid saved todo explanation")
					end
				end
				return v, expl
			end)
			if not ok then
				mare.log("warn", "todo restore failed: " .. tostring(value))
				changed(nil, nil)
				return
			end
			changed(value, explanation)
		end
		ctx.tools:register("todo_write", {
			description = "Replace the COMPLETE task checklist for multi-step work; skip trivial single-step tasks. Mark each task completed promptly. "
				.. (cfg.allow_parallel_in_progress and "Mark all actively worked steps in_progress; use several only when work runs in parallel. " or "Keep at most one step in_progress. ")
				.. "Use an empty list to clear it. Optionally explain a change to the plan.",
			side_effect = "write",
			idempotent = true,
			parameters = {
				type = "object",
				additionalProperties = false,
				required = { "todos" },
				properties = {
					explanation = { type = "string", description = "Optional explanation for this checklist update." },
					todos = {
						type = "array",
						description = "The COMPLETE task checklist, replacing any previous list.",
						items = {
							type = "object",
							additionalProperties = false,
							required = { "content", "status" },
							properties = {
								content = {
									type = "string",
									description = "What the task is — a short imperative line.",
								},
								status = {
									type = "string",
									enum = { "pending", "in_progress", "completed" },
									description = "pending (not started) | in_progress (now) | completed (done).",
								},
							},
						},
					},
				},
			},
			render = view.render,
			execute = function(args, tctx)
				local plan_mode = plan_mode_of()
				if plan_mode and plan_mode:active() then
					return {
						content = "todo_write is a checklist tool and cannot run in plan mode",
						is_error = true,
						error_code = "plan_mode_active",
					}
				end
				if args.explanation ~= nil and type(args.explanation) ~= "string" then
					error("explanation must be a string")
				end
				local value = model.canonical(args.todos, cfg.allow_parallel_in_progress)
				local diff = model.diff(state.todos or mare.json.array({}), value)
				diff.baseline = state.todos == nil and "initial" or "previous"
				local ok, err, cancelled, error_code = write(value, args.explanation, tctx and tctx.cancel)
				if not ok then
					return { content = err, is_error = true, cancelled = cancelled, error_code = error_code }
				end
				local details =
					{ todos = value, counts = model.counts(value), explanation = args.explanation, diff = diff }
				return {
					content = mare.json.encode({
						todos = value,
						counts = details.counts,
						explanation = args.explanation,
					}),
					details = details,
				}
			end,
		})
		ctx.context:section({
			name = "todo",
			order = 11000,
			interpolate = false,
			text = function()
				return "Current task checklist (data):\n"
					.. mare.json.encode({
						todos = state.todos == nil and mare.json.null or state.todos,
						explanation = state.explanation,
					})
			end,
		})
		ctx.ui:widget("todo", {
			slot = "above-editor",
			render = function(width, height)
				return view.widget(state, width, height)
			end,
		})
		ctx.commands:register("todos", {
			description = "View todos, or expand/collapse the progress panel",
			args = "[expand|collapse|toggle]",
			run = function(args)
				args = args or ""
				if args == "" then
					view.show(state)
				elseif args == "expand" or args == "collapse" or args == "toggle" then
					state.collapsed = args == "collapse" or args == "toggle" and not state.collapsed
					ctx.ui:invalidate("todo")
				else
					mare.ui.notify("Usage: /todos [expand|collapse|toggle]", "warning")
				end
			end,
		})
		ctx:on("session/changed", function()
			state.collapsed = true
			changed(nil, nil)
			restore()
		end)
		ctx:on("turn/started", function(ev)
			if
				ev.trigger == "continue"
				or ev.trigger == "notification"
				or ev.continue
				or ev.notification
				or state.todos == nil
			then
				return
			end
			local info = ctx.session:info()
			if info.readonly or mare.mode == "child" then
				pending_clear = nil
				changed(nil, nil)
				return
			end
			pending_clear = info.session_epoch
			local ok, _, _, code = write(nil)
			if ok then
				pending_clear = nil
			elseif code == "readonly_session" or code == "tool_context_unavailable" then
				pending_clear = nil
				changed(nil, nil)
			end
		end)
		-- request/ready is a decision point, so it needs a policy voter.
		ctx.policy:voter("request/ready", function()
			if pending_clear and pending_clear == ctx.session:info().session_epoch then
				local ok, err, _, code = write(nil)
				if not ok then
					if code == "readonly_session" or code == "tool_context_unavailable" then
						pending_clear = nil
						changed(nil, nil)
						return nil
					end
					return { decision = "deny", reason = err }
				end
				pending_clear = nil
			end
		end)
		restore()
		-- Public, detached read-only snapshot. null means no checklist for this
		-- work; [] means the model explicitly wrote an empty checklist.
		local function snapshot()
			local value = mare.json.null
			if state.todos ~= nil then
				value = mare.json.array({})
				for _, item in ipairs(state.todos) do
					value[#value + 1] = { content = item.content, status = item.status }
				end
			end
			return { todos = value, explanation = state.explanation }
		end
		require("mare_lib").service(ctx, "todo", { snapshot = snapshot })
		ctx.agent:register_activity("todo", function()
			return snapshot().todos
		end)
	end,
}
