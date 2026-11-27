return {
	name = "goal-probe",
	contracts = {
		["goal-probe"] = {
			owner = "goal-probe",
			doc = "Goal probe test events.",
			events = {
				applied = {
					doc = "Emitted when goal-probe applies during test setup.",
					mode = "emit",
					expose = "both",
					delivery = "required",
					ignorable = false,
					data = { type = "object", additionalProperties = true },
					example = { instance = "0123456789abcdef" },
				},
			},
		},
	},
	inject = { "tools", "commands", "session", "context", "agent", "goals", "policy" },
	apply = function(ctx)
		ctx:emit("goal-probe/applied", { instance = mare.crypto.random_hex(8) })
		local report = mare.env("GOAL_REPORT")
		ctx.commands:register("goal-probe-enqueue", {
			description = "Forward enqueue to agent service",
			run = function(args)
				local req = mare.json.decode(args)
				local info = ctx.session:info()
				local owner = req.expected
					or req.owner
					or { session_id = info.session_id, session_epoch = info.session_epoch }
				if owner.session_epoch == nil then
					owner.session_epoch = owner.generation or info.session_epoch
				end
				owner.generation = nil
				return ctx.agent:enqueue(req.content or req.text, owner, {
					source = req.source,
					input_context = req.inputContext,
					delivery = req.delivery,
				})
			end,
		})
		ctx.commands:register("goal-probe-resume", {
			description = "Forward resume_input to agent service",
			run = function(args)
				local req = mare.json.decode(args)
				local info = ctx.session:info()
				local owner = req.expected
					or req.owner
					or { session_id = info.session_id, session_epoch = info.session_epoch }
				if owner.session_epoch == nil then
					owner.session_epoch = owner.generation or info.session_epoch
				end
				owner.generation = nil
				return ctx.agent:resume_input(owner, req.opts)
			end,
		})
		ctx.policy:rewriter("tool/rewrite", function(call)
			if call.name == "update_goal" and call.arguments.goal_id == "__goal__" then
				local value = ctx.goals:get().goal
				if value then
					local args = call.arguments
					args.goal_id = value.id
					if args.revision ~= 0 then
						args.revision = value.revision
					end
					return args
				end
			end
		end)
		ctx:on("request/build", function(req, ev)
			local path = mare.env("GOAL_CAPTURE")
			if path then
				assert(
					mare.fs.write(
						path,
						(mare.fs.read(path) or "")
							.. mare.json.encode({ system = req.system, messages = req.messages, tools = req.tools })
							.. "\n"
					)
				)
			end
			return ev.next(req)
		end)
		ctx:on("app/ready", function()
			if not report then
				return
			end
			local ok, err = pcall(function()
				local function call(name, args)
					args = args or {}
					if name == "get_goal" then
						return assert(ctx.tools:get(name)).execute(args)
					end
					local call_ok, value
					if name == "create_goal" then
						call_ok, value =
							pcall(ctx.goals.create, ctx.goals, args.objective, args.token_budget, args.max_goal_rounds)
					elseif args.status == "blocked" then
						-- Out-of-driver mutation is itself rejected; actual blocked
						-- thresholds are exercised by faux tool pipelines below.
						return assert(ctx.tools:get(name)).execute(args)
					else
						local current = ctx.goals:get().goal
						local ref = current and current.ref or {}
						ref.goal_id = args.goal_id or ref.goal_id
						ref.revision = args.revision or ref.revision
						if args.status == "paused" then
							call_ok, value = pcall(ctx.goals.pause, ctx.goals, ref)
						elseif args.status == "complete" then
							call_ok, value = pcall(ctx.goals.complete, ctx.goals, ref)
						end
					end
					if not call_ok then
						local msg = type(value) == "table" and value.message or tostring(value)
						return { content = msg, is_error = true }
					end
					return { content = mare.json.encode(value), details = value }
				end
				local function view()
					local value = call("get_goal").details
					if value.goal == mare.json.null then
						value.goal = nil
					end
					return value
				end
				local mode = mare.env("GOAL_PROBE")
				if mode == "contracts" or mode == "round-limit" then
					ctx.commands:run("/plan on")
				end
				if mode == "readonly" then
					assert(call("create_goal", { objective = "refuse", token_budget = 9 }).is_error)
					assert(not view().goal)
				elseif mode == "empty" then
					assert(view().goal.status == "blocked" and view().goal.blocker.code == "empty-response")
					assert(view().goal.empty_rounds == 3 and view().goal.rounds_started == 3)
					assert(view().goal.last_finished_round_id == view().goal.last_round_id)
				elseif mode == "round-limit" then
					assert(view().goal.status == "blocked" and view().goal.blocker.code == "round-limit")
					assert(view().goal.rounds_started == 2 and view().goal.max_goal_rounds == 2)
					local ok_res, res_err = pcall(ctx.goals.resume, ctx.goals, view().goal.ref)
					assert(not ok_res and res_err and res_err.code == "goals.goal_unavailable")
					assert(view().goal.status == "blocked")
					ctx.commands:run("/goal rounds 3")
					assert(view().goal.max_goal_rounds == 3)
					assert(ctx.goals:resume(view().goal.ref))
					assert(view().goal.audit_rounds == 0)
					assert(ctx.goals:pause(view().goal.ref))
				elseif mode == "limited" then
					assert(view().goal.status == "usage_limited")
					assert(call("create_goal", { objective = "must not replace limited goal" }).is_error)
				elseif mode == "error" then
					assert(view().goal.status == "blocked" and view().goal.blocker.code == "turn-error")
				elseif mode == "resume" then
					assert(view().goal.status == "paused" and view().goal.objective == "persistent objective")
					assert(call("create_goal", { objective = "replacement" }).is_error)
				else
					assert(ctx.tools:get("create_goal").execute({ objective = "outside model pipeline" }).is_error)
					assert(not call("create_goal", { objective = "persistent objective", token_budget = 100 }).is_error)
					assert(view().goal.status == "active")
					assert(call("update_goal", { status = "complete", goal_id = "wrong", revision = 1 }).is_error)
					assert(
						call("update_goal", { status = "complete", goal_id = view().goal.id, revision = 0 }).is_error
					)
					local detached = ctx.goals:get()
					local stale = detached.goal.ref
					stale.revision = stale.revision - 1
					local ok_pause, pause_err = pcall(ctx.goals.pause, ctx.goals, stale)
					assert(not ok_pause and pause_err and pause_err.code == "goals.stale_ref")
					detached.goal.objective = "must not mutate goal"
					assert(view().goal.objective == "persistent objective")
					assert(
						ctx.goals:block(
							view().goal.ref,
							{ code = "operator-check", message = "explicit operator blocker" }
						)
					)
					assert(view().goal.blocker.code == "operator-check")
					assert(ctx.goals:resume(view().goal.ref))
					assert(call("create_goal", { objective = "replacement" }).is_error)
					assert(call("update_goal", { status = "blocked" }).is_error)
					assert(not call("update_goal", { status = "paused" }).is_error)
					assert(view().goal.status == "paused")
					ctx.commands:run("/goal resume")
					assert(view().goal.status == "active" and view().goal.audit_rounds == 0)
					assert(call("update_goal", { status = "blocked" }).is_error)
					ctx.commands:run("/goal resume")
					assert(call("update_goal", { status = "blocked" }).is_error)
					assert(not call("update_goal", { status = "paused" }).is_error)
					ctx.commands:run("/goal clear")
					assert(not view().goal)
					assert(not call("create_goal", { objective = "persistent objective" }).is_error)
					assert(not call("update_goal", { status = "complete" }).is_error)
					ctx.commands:run("/goal edit persistent objective")
					assert(view().goal.status == "active")
					assert(not call("update_goal", { status = "paused" }).is_error)
					assert(ctx.context:system_prompt():find("persistent objective", 1, true))
					ctx.commands:run("/plan off")
				end
			end)
			assert(mare.fs.write(report, mare.json.encode({ ok = ok, detail = tostring(err or "passed") })))
			assert(ok, err)
		end)
	end,
}
