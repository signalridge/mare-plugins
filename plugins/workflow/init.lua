local PROMPT_GUIDANCE =
	"Use workflow only when the user explicitly requests workflow or large-scale multi-agent orchestration; use ordinary subagents for one or two delegations."

return {
	name = "workflow",
	tags = {},
	inject = { "tools", "task", "bus" },
	config_schema = {
		tool_enabled = {
			type = "boolean",
			default = false,
			apply = "live",
			desc = "Initial activation state of the workflow tool when state.json has no workflow_enabled toggle (/workflow on|off).",
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
	},
	apply = function(ctx, raw_cfg)
		local config = require("workflow.config")
		local events = require("workflow.events")
		local panel_mod = require("workflow.panel")
		local summary_mod = require("workflow.summary")
		local engine_mod = require("workflow.engine")
		local lib = require("mare_lib")
		local svc = lib.followers(ctx, { "session", "context", "jobs", "commands", "ui", "subagent" })
		local cfg = config.normalize(raw_cfg)
		local enabled = config.load_enabled(cfg)

		local function get_cfg()
			return cfg
		end

		local function apply_live_leaf(root, path, val)
			local target = root
			local parts = {}
			for seg in path:gmatch("[^.]+") do
				parts[#parts + 1] = seg
			end
			for i = 1, #parts - 1 do
				local k = parts[i]
				if type(target[k]) ~= "table" then
					target[k] = {}
				end
				target = target[k]
			end
			if #parts >= 1 then
				target[parts[#parts]] = val
			end
		end

		local panel = panel_mod.create(ctx, get_cfg)
		local summary = summary_mod.create(ctx, svc)
		local engine = engine_mod.new({
			ctx = ctx,
			get_cfg = get_cfg,
			svc = svc,
			panel = panel,
			summary = summary,
		})

		local function publish_enabled(notify_msg)
			events.emit(ctx, "workflow/changed", { enabled = enabled })
			if svc.context and type(svc.context.invalidate) == "function" then
				pcall(svc.context.invalidate, svc.context)
			end
			if ctx.tools and type(ctx.tools.touch) == "function" then
				pcall(ctx.tools.touch, ctx.tools)
			end
			if notify_msg and mare and mare.ui and type(mare.ui.notify) == "function" then
				pcall(mare.ui.notify, notify_msg, "info")
			end
		end

		local function set_enabled(next_val)
			local target = next_val == true
			local ok, err = config.save_enabled(target)
			if not ok then
				if mare and mare.ui and type(mare.ui.notify) == "function" then
					pcall(mare.ui.notify, "Failed to save workflow state: " .. tostring(err), "error")
				end
				return false, err
			end
			enabled = target
			publish_enabled("Workflow " .. (enabled and "enabled" or "disabled") .. ".")
			return true
		end

		ctx.tools:register(cfg.tool_name, {
			snippet = "Run a deterministic Lua multi-agent orchestration script",
			description = "Execute a Lua orchestration script that fans out work to child subagents via agent(prompt, opts), pipeline(items, ...), parallel(fns), phase(title), log(msg), and args. End the script with `return <json-value>`.",
			allow_nested = false,
			side_effect = "external",
			idempotent = false,
			timeout_ms = false,
			enabled = function()
				return enabled
			end,
			summary = function(args)
				local name = type(args) == "table" and type(args.meta) == "table" and args.meta.name or "run"
				return ("Workflow(%s)"):format(tostring(name))
			end,
			render = summary.render_tool,
			parameters = {
				type = "object",
				additionalProperties = false,
				required = { "script", "meta" },
				properties = {
					script = {
						type = "string",
						description = "Lua orchestration script ending with `return <value>`.",
					},
					meta = {
						type = "object",
						description = "Workflow metadata (name, description, optional when_to_use and phases).",
						additionalProperties = false,
						required = { "name", "description" },
						properties = {
							name = { type = "string", description = "Short kebab-case workflow identifier." },
							description = { type = "string", description = "One-line description." },
							when_to_use = { type = "string" },
							phases = {
								type = "array",
								items = {
									type = "object",
									additionalProperties = false,
									required = { "title" },
									properties = {
										title = { type = "string" },
										detail = { type = "string" },
										provider = { type = "string" },
										model = { type = "string" },
									},
								},
							},
						},
					},
					args = {
						type = "object",
						description = "Optional JSON object exposed as `args` inside the script.",
					},
					run_in_background = {
						type = "boolean",
						description = "Run in background and return a job ID immediately.",
					},
				},
			},
			execute = function(args, tctx)
				return engine.run(args, tctx)
			end,
		})

		ctx:inject({ "context" }, function(sub)
			sub.context:section({
				name = "workflow:guidance",
				order = 860,
				interpolate = false,
				text = function()
					if not enabled then
						return nil
					end
					return PROMPT_GUIDANCE
				end,
			})
		end)

		ctx:inject({ "commands" }, function(sub)
			sub.commands:register("workflow", {
				description = "Toggle or inspect multi-agent workflow orchestration (/workflow on|off|status)",
				args = "[on|off|status]",
				complete = function()
					return { "on", "off", "status" }
				end,
				run = function(arg)
					local trimmed = tostring(arg or ""):match("^%s*(.-)%s*$"):lower()
					if trimmed == "on" then
						set_enabled(true)
					elseif trimmed == "off" then
						set_enabled(false)
					elseif trimmed == "" or trimmed == "status" then
						local runs = summary.list()
						local msg = ("Workflow is %s (recorded runs in session: %d). Usage: /workflow on|off"):format(
							enabled and "on" or "off",
							#runs
						)
						if mare and mare.ui and type(mare.ui.notify) == "function" then
							pcall(mare.ui.notify, msg, "info")
						end
					else
						if mare and mare.ui and type(mare.ui.notify) == "function" then
							pcall(mare.ui.notify, "Usage: /workflow on|off|status", "warning")
						end
					end
				end,
			})
		end)

		ctx:on("session/loaded", function()
			engine.on_session_changed()
			summary.rebuild()
		end)
		ctx:on("session/changed", function()
			engine.on_session_changed()
			summary.rebuild()
		end)
		ctx:on("option/changed", function(ev)
			if type(ev) ~= "table" or type(ev.name) ~= "string" then
				return
			end
			local prefix = "plugins.workflow."
			if ev.name:sub(1, #prefix) ~= prefix then
				return
			end
			local rel = ev.name:sub(#prefix + 1)
			if type(raw_cfg) == "table" and rel ~= "" then
				apply_live_leaf(raw_cfg, rel, ev.value)
			end
			cfg = config.normalize(raw_cfg)
			if rel == "tool_enabled" or rel == "enabled" then
				local next_enabled = config.load_enabled(cfg)
				if next_enabled ~= enabled then
					enabled = next_enabled
					publish_enabled(nil)
				end
			end
			if panel and type(panel.invalidate) == "function" then
				pcall(panel.invalidate)
			end
		end)

		summary.rebuild()
		publish_enabled(nil)
	end,
}
