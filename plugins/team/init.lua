local function fail_result(msg, code)
	return { content = tostring(msg), is_error = true, error_code = code }
end

local function ok_result(val)
	return { content = mare.json.encode(val, { pretty = true }), details = val }
end

local COUNTS_SCHEMA = {
	type = "object",
	additionalProperties = false,
	required = { "total", "pending", "ready", "blocked", "in_progress", "completed", "cancelled" },
	properties = {
		total = { type = "integer" },
		pending = { type = "integer" },
		ready = { type = "integer" },
		blocked = { type = "integer" },
		in_progress = { type = "integer" },
		completed = { type = "integer" },
		cancelled = { type = "integer" },
	},
}

local TASK_VIEW_SCHEMA = {
	type = "object",
	additionalProperties = false,
	required = {
		"id",
		"seq",
		"title",
		"status",
		"priority",
		"blocked_by",
		"blocks",
		"unresolved_blockers",
		"ready",
		"blocked",
		"lease_active",
		"lease_stale",
		"revision",
		"notes",
		"created_at_ms",
		"updated_at_ms",
	},
	properties = {
		id = { type = "string" },
		seq = { type = "integer" },
		title = { type = "string" },
		description = { type = { "string", "null" } },
		status = { type = "string", enum = { "pending", "in_progress", "completed", "cancelled" } },
		priority = { type = "string", enum = { "low", "medium", "high" } },
		blocked_by = { type = "array", items = { type = "string" } },
		blocks = { type = "array", items = { type = "string" } },
		unresolved_blockers = { type = "array", items = { type = "string" } },
		ready = { type = "boolean" },
		blocked = { type = "boolean" },
		owner = { type = { "string", "null" } },
		lease_token = { type = { "string", "null" } },
		lease_expires_at_ms = { type = { "integer", "null" } },
		lease_active = { type = "boolean" },
		lease_stale = { type = "boolean" },
		revision = { type = "integer" },
		notes = { type = "array", items = { type = "object" } },
		result = { type = { "string", "null" } },
		created_at_ms = { type = "integer" },
		updated_at_ms = { type = "integer" },
		completed_at_ms = { type = { "integer", "null" } },
	},
}

local LIST_RESULT_SCHEMA = {
	type = "object",
	additionalProperties = false,
	required = { "tasks", "counts" },
	properties = {
		tasks = { type = "array", items = TASK_VIEW_SCHEMA },
		counts = COUNTS_SCHEMA,
	},
}

local COMPLETE_RESULT_SCHEMA = {
	type = "object",
	additionalProperties = false,
	required = { "task", "unblocked" },
	properties = {
		task = TASK_VIEW_SCHEMA,
		unblocked = { type = "array", items = { type = "string" } },
	},
}

local CLEAR_RESULT_SCHEMA = {
	type = "object",
	additionalProperties = false,
	required = { "cleared" },
	properties = {
		cleared = { type = "integer" },
	},
}

local CREATE_ARGS_SCHEMA = {
	type = "object",
	additionalProperties = false,
	required = { "title" },
	properties = {
		title = { type = "string", description = "Short imperative task title." },
		description = { type = "string", description = "Detailed instructions or acceptance criteria." },
		priority = { type = "string", enum = { "low", "medium", "high" } },
		blocked_by = {
			type = "array",
			items = { type = "string" },
			description = "Task IDs that must complete before this task becomes ready.",
		},
		owner = { type = "string", description = "Optional initial owner (starts in_progress)." },
		lease_ms = { type = "integer", description = "Optional lease duration in ms when assigned." },
	},
}

local LIST_ARGS_SCHEMA = {
	type = "object",
	additionalProperties = false,
	properties = {
		status = { type = "string", enum = { "pending", "in_progress", "completed", "cancelled" } },
		owner = { type = "string" },
		ready_only = { type = "boolean" },
		include_completed = { type = "boolean" },
	},
}

local CLAIM_ARGS_SCHEMA = {
	type = "object",
	additionalProperties = false,
	properties = {
		id = { type = "string", description = "Task ID (optional; omits to claim next ready task)." },
		owner = { type = "string", description = "Owner identifier (defaults to agent id or main)." },
		lease_ms = { type = "integer", description = "Lease duration in milliseconds." },
		force = { type = "boolean", description = "Force claim even if another active lease exists." },
	},
}

local UPDATE_ARGS_SCHEMA = {
	type = "object",
	additionalProperties = false,
	required = { "id" },
	properties = {
		id = { type = "string" },
		title = { type = "string" },
		description = { type = "string" },
		status = { type = "string", enum = { "pending", "in_progress", "completed", "cancelled" } },
		priority = { type = "string", enum = { "low", "medium", "high" } },
		owner = { type = "string", description = "Caller owner identity for stale-owner verification." },
		add_blocked_by = { type = "array", items = { type = "string" } },
		remove_blocked_by = { type = "array", items = { type = "string" } },
		note = { type = "string" },
		renew_lease = { type = "boolean" },
		lease_ms = { type = "integer" },
		expected_revision = { type = "integer" },
		lease_token = { type = "string" },
		force = { type = "boolean" },
	},
}

local COMPLETE_ARGS_SCHEMA = {
	type = "object",
	additionalProperties = false,
	required = { "id" },
	properties = {
		id = { type = "string" },
		owner = { type = "string" },
		result = { type = "string" },
		note = { type = "string" },
		expected_revision = { type = "integer" },
		lease_token = { type = "string" },
		force = { type = "boolean" },
	},
}

return {
	name = "team",
	tags = {},
	provide = { "team" },
	inject = { "tools", "task", "bus" },
	contracts = {
		team = {
			doc = "Shared multi-agent task board with dependencies, leases, and session persistence.",
			errors = {
				unknown_task = { doc = "no task exists with the given id" },
				invalid_task = { doc = "invalid task title, priority, status, or lease duration" },
				invalid_dependency = { doc = "cyclic or malformed task dependency" },
				task_blocked = { doc = "task cannot be claimed or completed while blockers remain incomplete" },
				lease_conflict = { doc = "task is currently leased by another active owner" },
				stale_owner = { doc = "caller does not own the active task lease" },
				stale_lease = { doc = "supplied lease_token does not match the current lease" },
				conflict = { doc = "supplied expected_revision does not match the current task revision" },
				no_ready_task = { doc = "no ready unclaimed task is available" },
				invalid_state = { doc = "task state does not permit this operation" },
			},
			events = {
				["task-created"] = {
					doc = "A team task was created.",
					mode = "emit",
					expose = "lua",
					data = {
						type = "object",
						properties = {
							task_id = { type = "string" },
							title = { type = "string" },
							status = { type = "string" },
						},
						required = { "task_id", "title", "status" },
					},
				},
				["task-claimed"] = {
					doc = "A team task was claimed with an owner lease.",
					mode = "emit",
					expose = "lua",
					data = {
						type = "object",
						properties = {
							task_id = { type = "string" },
							owner = { type = "string" },
							revision = { type = "integer" },
						},
						required = { "task_id", "owner", "revision" },
					},
				},
				["task-updated"] = {
					doc = "A team task was updated.",
					mode = "emit",
					expose = "lua",
					data = {
						type = "object",
						properties = {
							task_id = { type = "string" },
							status = { type = "string" },
							revision = { type = "integer" },
						},
						required = { "task_id", "status", "revision" },
					},
				},
				["task-completed"] = {
					doc = "A team task completed and may have unblocked downstream tasks.",
					mode = "emit",
					expose = "lua",
					data = {
						type = "object",
						properties = {
							task_id = { type = "string" },
							owner = { type = "string" },
							unblocked_count = { type = "integer" },
						},
						required = { "task_id", "unblocked_count" },
					},
				},
				["board-cleared"] = {
					doc = "All tasks were cleared from the team board.",
					mode = "emit",
					expose = "lua",
					data = {
						type = "object",
						properties = { cleared = { type = "integer" } },
						required = { "cleared" },
					},
				},
			},
			methods = {
				create = {
					doc = "Create a new task on the shared team board.",
					expose = "lua",
					scope = "session",
					params = {
						type = "object",
						properties = { args = CREATE_ARGS_SCHEMA },
						required = { "args" },
						additionalProperties = false,
					},
					lua = { options = "{ cancel?: mare.Token }?" },
					order = { "args", "options" },
					result = TASK_VIEW_SCHEMA,
					errors = { "invalid_task", "invalid_dependency", "unknown_task", "task_blocked" },
				},
				list = {
					doc = "List tasks and summary counts on the shared team board.",
					expose = "lua",
					scope = "session",
					params = {
						type = "object",
						properties = {
							opts = {
								oneOf = { LIST_ARGS_SCHEMA, { type = "null" } },
							},
						},
						additionalProperties = false,
					},
					order = { "opts" },
					result = LIST_RESULT_SCHEMA,
					errors = {},
				},
				claim = {
					doc = "Claim a specific or next ready task with an exclusive lease.",
					expose = "lua",
					scope = "session",
					params = {
						type = "object",
						properties = {
							args = {
								oneOf = { CLAIM_ARGS_SCHEMA, { type = "null" } },
							},
						},
						additionalProperties = false,
					},
					lua = { options = "{ cancel?: mare.Token }?" },
					order = { "args", "options" },
					result = TASK_VIEW_SCHEMA,
					errors = {
						"invalid_task",
						"unknown_task",
						"no_ready_task",
						"invalid_state",
						"task_blocked",
						"lease_conflict",
					},
				},
				update = {
					doc = "Update fields, dependencies, notes, or lease on an existing task.",
					expose = "lua",
					scope = "session",
					params = {
						type = "object",
						properties = { args = UPDATE_ARGS_SCHEMA },
						required = { "args" },
						additionalProperties = false,
					},
					lua = { options = "{ cancel?: mare.Token }?" },
					order = { "args", "options" },
					result = TASK_VIEW_SCHEMA,
					errors = {
						"unknown_task",
						"invalid_state",
						"conflict",
						"stale_lease",
						"stale_owner",
						"invalid_task",
						"invalid_dependency",
						"task_blocked",
					},
				},
				complete = {
					doc = "Complete a task and automatically unblock dependent tasks.",
					expose = "lua",
					scope = "session",
					params = {
						type = "object",
						properties = { args = COMPLETE_ARGS_SCHEMA },
						required = { "args" },
						additionalProperties = false,
					},
					lua = { options = "{ cancel?: mare.Token }?" },
					order = { "args", "options" },
					result = COMPLETE_RESULT_SCHEMA,
					errors = {
						"unknown_task",
						"invalid_state",
						"task_blocked",
						"conflict",
						"stale_lease",
						"stale_owner",
					},
				},
				clear = {
					doc = "Clear all tasks from the current session's team board.",
					expose = "lua",
					scope = "session",
					params = {
						type = "object",
						properties = {},
						additionalProperties = false,
					},
					lua = { options = "{ cancel?: mare.Token }?" },
					order = { "options" },
					result = CLEAR_RESULT_SCHEMA,
					errors = {},
				},
			},
		},
	},
	config_schema = {
		default_lease_ms = {
			type = "integer",
			default = 300000,
			min = 1000,
			unit = "ms",
			apply = "next_op",
			desc = "Default lease duration in milliseconds when claiming a task.",
		},
		release_on_agent_end = {
			type = "boolean",
			default = true,
			apply = "live",
			desc = "Automatically release active task leases held by a subagent when it finishes.",
		},
		widget = {
			type = "boolean",
			default = true,
			apply = "live",
			desc = "Show a compact summary widget above the editor when tasks exist.",
		},
		shared_file = {
			type = "boolean",
			default = true,
			apply = "next_op",
			desc = "Mirror team board state to a lock-guarded session file under state dir.",
		},
		session_id = {
			type = "string",
			desc = "Optional shared parent session identifier passed to child agents.",
		},
	},
	apply = function(ctx, cfg)
		local store_mod = require("team.store")
		local view_mod = require("team.view")
		local lib = require("mare_lib")
		local svc = lib.followers(ctx, { "session", "context", "ui", "commands" })
		local show_widget = cfg.widget ~= false

		local function on_change()
			if svc.context and type(svc.context.invalidate) == "function" then
				pcall(svc.context.invalidate, svc.context)
			end
			if svc.ui and type(svc.ui.invalidate) == "function" then
				pcall(svc.ui.invalidate, svc.ui, "team")
			end
		end

		local store = store_mod.create(ctx, cfg, svc, on_change)

		local function unwrap_or_fail(res, err, code)
			if not res then
				lib.fail(code or "team.invalid_task", tostring(err))
			end
			return res
		end

		lib.service(ctx, "team", {
			create = function(_, _, args, options)
				return unwrap_or_fail(store.create(args, options and options.cancel))
			end,
			list = function(_, _, opts)
				return store.list(opts)
			end,
			claim = function(_, _, args, options)
				return unwrap_or_fail(store.claim(args, options and options.cancel))
			end,
			update = function(_, _, args, options)
				return unwrap_or_fail(store.update(args, options and options.cancel))
			end,
			complete = function(_, _, args, options)
				return unwrap_or_fail(store.complete(args, options and options.cancel))
			end,
			clear = function(_, _, options)
				return unwrap_or_fail(store.clear(options and options.cancel))
			end,
		})

		local function run_tool(fn, args, tctx)
			local res, err, code = fn(args, tctx and tctx.cancel)
			if not res then
				return fail_result(err, code)
			end
			return ok_result(res)
		end

		ctx.tools:register("team_create", {
			snippet = "Create a task on the shared multi-agent team board",
			description = "Create a task with optional description, priority, blocked_by dependencies, and owner.",
			side_effect = "write",
			idempotent = false,
			parameters = CREATE_ARGS_SCHEMA,
			summary = function(a)
				return ("TeamCreate(%s)"):format(tostring(a and a.title or "?"))
			end,
			execute = function(args, tctx)
				return run_tool(store.create, args, tctx)
			end,
		})

		ctx.tools:register("team_list", {
			snippet = "List tasks on the shared team board",
			description = "List tasks, readiness, blockers, owners, and summary counts.",
			side_effect = "read",
			idempotent = true,
			parameters = LIST_ARGS_SCHEMA,
			summary = function()
				return "TeamList"
			end,
			execute = function(args)
				return ok_result(store.list(args))
			end,
		})

		ctx.tools:register("team_claim", {
			snippet = "Claim a ready task on the shared team board",
			description = "Claim a task by id (or omit id to claim the highest-priority ready unassigned task) with a lease.",
			side_effect = "write",
			idempotent = false,
			parameters = CLAIM_ARGS_SCHEMA,
			summary = function(a)
				return ("TeamClaim(%s)"):format(tostring(a and a.id or "next"))
			end,
			execute = function(args, tctx)
				return run_tool(store.claim, args, tctx)
			end,
		})

		ctx.tools:register("team_update", {
			snippet = "Update a task on the shared team board",
			description = "Update task fields, dependencies, notes, or renew its lease.",
			side_effect = "write",
			idempotent = false,
			parameters = UPDATE_ARGS_SCHEMA,
			summary = function(a)
				return ("TeamUpdate(%s)"):format(tostring(a and a.id or "?"))
			end,
			execute = function(args, tctx)
				return run_tool(store.update, args, tctx)
			end,
		})

		ctx.tools:register("team_complete", {
			snippet = "Complete a task and unblock downstream tasks",
			description = "Mark a task completed and automatically unblock dependent tasks.",
			side_effect = "write",
			idempotent = false,
			parameters = COMPLETE_ARGS_SCHEMA,
			summary = function(a)
				return ("TeamComplete(%s)"):format(tostring(a and a.id or "?"))
			end,
			execute = function(args, tctx)
				return run_tool(store.complete, args, tctx)
			end,
		})

		ctx:inject({ "context" }, function(sub)
			sub.context:section({
				name = "team:board",
				order = 11050,
				interpolate = false,
				text = function()
					return view_mod.context_text(store)
				end,
			})
		end)

		ctx:inject({ "ui" }, function(sub)
			sub.ui:widget("team", {
				slot = "above-editor",
				order = -15,
				render = function(width)
					return view_mod.widget_node(store, width, show_widget)
				end,
			})
		end)

		ctx:inject({ "commands" }, function(sub)
			sub.commands:register("team", {
				description = "Inspect the shared team task board (/team [status|clear|widget on|off])",
				args = "[status|clear|widget on|off]",
				complete = function()
					return { "status", "clear", "widget on", "widget off" }
				end,
				run = function(arg)
					local trimmed = tostring(arg or ""):match("^%s*(.-)%s*$"):lower()
					if trimmed == "" then
						local snap = store.list()
						if snap.counts.total == 0 then
							if mare and mare.ui and mare.ui.notify then
								pcall(mare.ui.notify, "Team board is empty.", "info")
							end
							return
						end
						ctx:spawn(function()
							view_mod.open_inspector(store)
						end)
					elseif trimmed == "status" then
						local c = store.list().counts
						local msg = ("Team: %d total (%d active, %d ready, %d blocked, %d completed)"):format(
							c.total,
							c.in_progress,
							c.ready,
							c.blocked,
							c.completed
						)
						if mare and mare.ui and mare.ui.notify then
							pcall(mare.ui.notify, msg, "info")
						end
					elseif trimmed == "clear" then
						ctx:spawn(function()
							local res, err = store.clear()
							if mare and mare.ui and mare.ui.notify then
								if res then
									pcall(mare.ui.notify, ("Cleared %d team tasks."):format(res.cleared), "info")
								else
									pcall(mare.ui.notify, "Failed to clear team board: " .. tostring(err), "error")
								end
							end
						end)
					elseif trimmed == "widget on" or trimmed == "widget off" then
						show_widget = trimmed == "widget on"
						on_change()
					else
						if mare and mare.ui and mare.ui.notify then
							pcall(mare.ui.notify, "Usage: /team [status|clear|widget on|off]", "warning")
						end
					end
				end,
			})
		end)

		ctx:on("session/loaded", function()
			store.restore()
		end)
		ctx:on("session/changed", function()
			store.restore()
		end)
		ctx:on("option/changed", function(ev)
			if type(ev) == "table" and ev.name == "plugins.team.widget" then
				show_widget = ev.value ~= false
				on_change()
			end
		end)
		ctx:on("subagent/completed", function(ev)
			if not cfg.release_on_agent_end or type(ev) ~= "table" then
				return
			end
			local seen = {}
			local owners = {}
			for _, key in ipairs({ "subagent_id", "child_session_id", "agent_id" }) do
				local id = ev[key]
				if type(id) == "string" and id ~= "" and not seen[id] then
					seen[id] = true
					owners[#owners + 1] = id
				end
			end
			if #owners == 0 then
				return
			end
			local expected_parent = {
				session_id = ev.parent_session_id,
				session_epoch = ev.parent_session_epoch,
			}
			store.release_owners(owners, "released when subagent " .. owners[1] .. " ended", expected_parent)
		end)

		store.restore()
	end,
}
