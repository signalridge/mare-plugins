-- Original dialect adapters; input updatedInput remains explicitly unsupported.
return {
	name = "hooks",
	tags = {},
	required = true,
	inject = { "session", "llm", "tools", "agent", "commands", "policy" },
	config_schema = {
		sources = {
			type = "list",
			default = {},
			items = { type = "object" },
			desc = "Explicit hook source definitions.",
			apply = "reload",
		},
		discover = {
			type = "union",
			variants = { { type = "boolean" }, { type = "object" } },
			default = nil,
			nullable = true,
			desc = "Auto-discover Claude Code, Codex, or user hook files.",
			apply = "reload",
		},
		defaultTimeoutMs = {
			type = "integer",
			default = 600000,
			min = 1,
			unit = "ms",
			desc = "Default hook execution timeout in milliseconds.",
			apply = "next_op",
		},
		stderrSummaryMaxChars = {
			type = "integer",
			default = 500,
			min = 1,
			unit = "chars",
			desc = "Maximum characters included in hook stderr summaries.",
			apply = "next_op",
		},
		requireTrust = {
			type = "boolean",
			default = false,
			desc = "Require repository trust before executing hooks.",
			apply = "next_op",
		},
	},
	apply = function(ctx, cfg)
		local load_config = require("hooks.config")
		local commands, warnings, ui_warnings = load_config(cfg)
		local seen_warnings, pending_ui_warnings = {}, {}
		local function ui_connected()
			return mare.ui and type(mare.ui.connected) == "function" and mare.ui.connected()
		end
		local function report_warnings(list, notify_set)
			for _, warning in ipairs(list) do
				if not seen_warnings[warning] then
					seen_warnings[warning] = true
					mare.log("warn", warning)
					if notify_set and notify_set[warning] then
						if mare.mode == "rpc" and not ui_connected() then
							pending_ui_warnings[#pending_ui_warnings + 1] = warning
						elseif mare.ui and type(mare.ui.notify) == "function" then
							pcall(mare.ui.notify, warning, "warning")
						end
					end
				end
			end
		end
		report_warnings(warnings, ui_warnings)
		ctx:on("app/ready", function()
			if ui_connected() and #pending_ui_warnings > 0 then
				for _, warning in ipairs(pending_ui_warnings) do
					pcall(mare.ui.notify, warning, "warning")
				end
				pending_ui_warnings = {}
			end
		end)
		-- One registrar for every hook event: a decision point registers a policy voter;
		-- a core waterfall gets the around form (fn(value, ..., next)) and passes its result on; any
		-- other event is a plain listener. Listener-level timeout_ms is gone natively (the emitter
		-- bounds the wait); each hook command keeps its own timeout (run.lua).
		local POINTS = {
			["tool/approval"] = true,
			["tool/before"] = true,
			["agent/input-ready"] = true,
			["agent/step-ready"] = true,
			["request/ready"] = true,
		}
		local RUNS_COMMANDS = { ["tool/before"] = true, ["tool/approval"] = true, ["agent/input-ready"] = true }
		local WATERFALLS = { ["tool/after"] = true, ["tool/program-result"] = true }
		local function around(fn)
			return function(data, ev)
				local r = fn(data.result, data.call, data.operation)
				if r ~= nil then
					data.result = r
				end
				return ev.next(data)
			end
		end
		local function on_budget(event, fn)
			if POINTS[event] then
				-- the voters that run hook commands (tool/before, tool/approval) take no voter
				-- timeout (0 = none): each command is bounded by its own configured timeout
				-- (mare.proc.run, default 600 s), not by the core's default policy timeout (30 s)
				return ctx.policy:voter(event, fn, RUNS_COMMANDS[event] and { timeout_ms = 0 } or nil)
			end
			if WATERFALLS[event] then
				return ctx:on(event, around(fn))
			end
			return ctx:on(event, fn)
		end
		local turn_id = ""
		ctx:on("turn/started", function(event)
			turn_id = event.turn_id or ""
		end)
		local state = require("hooks.state").new()
		local turn = function()
			if ctx.agent and require("mare_lib").callable(ctx.agent.get) then
				return (ctx.agent:get() or {}).turn_id or ""
			end
			return turn_id
		end
		local run, sync_runtime = require("hooks.runtime")(ctx, commands, turn, state)
		require("hooks.commands")(ctx, commands, state)
		require("hooks.pre_tool")(ctx, run, on_budget, turn)
		local mounted = {}
		local function sync_adapters()
			local needed = {}
			for _, command in ipairs(commands) do
				if not command.unsupported_type or command.decision_event then
					needed[command.event] = true
				end
			end
			if needed.SessionEnd and not mounted.SessionEnd then
				mounted.SessionEnd = true
				require("hooks.session_end")(ctx, run)
			end
			if needed.SessionStart and not mounted.SessionStart then
				mounted.SessionStart = true
				require("hooks.lifecycle")(ctx, run, on_budget)
			end
			if needed.Stop and not mounted.Stop then
				mounted.Stop = true
				require("hooks.stop")(ctx, run, on_budget)
			end
			if needed.UserPromptSubmit and not mounted.UserPromptSubmit then
				mounted.UserPromptSubmit = true
				require("hooks.input")(ctx, run, on_budget)
			end
			if needed.PostToolUse and not mounted.PostToolUse then
				mounted.PostToolUse = true
				require("hooks.post")(ctx, run, on_budget)
			end
			local need_pre = needed.PreCompact == true and not mounted.PreCompact
			local need_post = needed.PostCompact == true and not mounted.PostCompact
			if need_pre or need_post then
				mounted.PreCompact = mounted.PreCompact or need_pre
				mounted.PostCompact = mounted.PostCompact or need_post
				require("hooks.compact")(ctx, run, on_budget, need_pre, need_post)
			end
			if needed.PermissionRequest and not mounted.PermissionRequest then
				mounted.PermissionRequest = true
				require("hooks.permission")(ctx, run, on_budget)
			end
		end
		sync_adapters()
		ctx:on("trust/changed", function(ev)
			local trusted = mare.trusted == true
			if type(ev) == "table" and ev.trusted ~= nil then
				trusted = ev.trusted == true and mare.trusted == true
			end
			local ok, next_commands, next_warnings, next_ui_warnings = pcall(load_config, cfg, { trusted = trusted })
			if not ok then
				mare.log("warn", "hooks reload after trust change failed: " .. tostring(next_commands))
				return
			end
			report_warnings(next_warnings, next_ui_warnings)
			for i = #commands, 1, -1 do
				commands[i] = nil
			end
			for i, cmd in ipairs(next_commands) do
				commands[i] = cmd
			end
			if sync_runtime then
				sync_runtime()
			end
			sync_adapters()
		end)
	end,
}
