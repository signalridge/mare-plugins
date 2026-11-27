local H = assert(load(mare.fs.read("tests/specs/hooks_support.lua"), "@tests/specs/hooks_support.lua"))()

local describe = mare.test.describe
local it = mare.test.it
local before_each = mare.test.before_each
local after_each = mare.test.after_each
local expect = mare.test.expect

local S, ctx, plugin, call, setup, vote = H.S, H.ctx, H.plugin, H.call, H.setup, H.vote

describe("hooks", function()
	local real_log = mare.log
	mare.test.after_each(function()
		mare.log = real_log
	end)
	before_each(function()
		H.reset()
	end)

	after_each(function()
		H.teardown()
	end)

	it("enforces PreToolUse policy voting, cancellation, and codex metadata", function()
		setup()
		expect.falsy(plugin.provide)
		expect.truthy(plugin.required)
		-- native: tool/before is a policy voter with no voter timeout (0 = none): each hook command
		-- is bounded by its own timeout, not by the core's default policy timeout.
		expect.truthy(S.events["tool/before"])
		expect.eq(S.registered["tool/before"].timeout_ms, 0)
		expect.falsy(S.events["tool/after"])
		expect.falsy(S.events["agent/turn-stopping"])
		expect.falsy(S.events["status/changed"])

		expect.eq(vote().decision, "allow")
		expect.truthy(S.captured.tool_input.other)

		local cancel = mare.task.token()
		expect.eq(S.events["tool/before"](call, {}, { cancel = cancel }).decision, "allow")
		expect.eq(S.proc_opts.cancel, cancel)
		expect.eq(vote().decision, "allow")
		expect.eq(S.runs, 3)

		call.name = "different"
		expect.eq(vote().decision, "allow")
		expect.eq(S.runs, 3)

		call.name = "probe"
		for _, r in ipairs({
			{ code = 2, stdout = "", stderr = "", dropped = 0 },
			{ code = 1, stdout = "", stderr = "", dropped = 0 },
			{ code = 0, stdout = "", stderr = "", dropped = 1 },
			{ code = 0, stdout = "", stderr = "", dropped = 0, timed_out = true },
			{ code = 0, stdout = "", stderr = "", dropped = 0, cancelled = true },
			{ code = 0, stdout = "", stderr = "", dropped = 0, sandbox_failed = "failed" },
		}) do
			S.result = r
			expect.eq(vote().decision, "deny")
		end

		for _, json_out in ipairs({
			'{"decision":"deny"}',
			'{"unknown":true}',
			'{"hookSpecificOutput":{"hookEventName":"Stop"}}',
			'{"hookSpecificOutput":{"hookEventName":"PreToolUse","updatedInput":{}}}',
			'{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"maybe"}}',
			'{"reason":2}',
		}) do
			S.result = { code = 0, stdout = json_out, stderr = "", dropped = 0 }
			expect.eq(vote().decision, "deny")
		end

		for _, d in ipairs({ "allow", "deny", "ask" }) do
			H.set_json({ hookSpecificOutput = { hookEventName = "PreToolUse", permissionDecision = d } })
			expect.eq(vote().decision, d)
		end

		H.set_json({ ["continue"] = false, stopReason = "stop" })
		expect.truthy(vote().abort)

		setup("codex")
		S.events["turn/started"]({ turn_id = "turn" })
		expect.eq(vote().decision, "allow")
		expect.eq(S.captured.model, "faux/echo")
		expect.eq(S.captured.turn_id, "turn")
	end)

	it("fails startup on invalid configuration", function()
		for _, mutate in ipairs({
			function(c)
				c.sandbox = false
			end,
			function(c)
				c.sources[1].hooks.UnsupportedEvent = {}
			end,
			function(c)
				c.sources[1].hooks.PreToolUse = { bad = true }
			end,
			function(c)
				c.sources[1].hooks.PreToolUse[1].hooks[1].async = "yes"
			end,
			function(c)
				c.sources[1].hooks.PreToolUse[1].matcher = "["
			end,
			function(c)
				c.sources[1].hooks.PreToolUse[1].hooks[1].timeout = 0
			end,
		}) do
			setup()
			mutate(S.config)
			expect.falsy(pcall(plugin.apply, ctx, S.config))
		end
	end)

	it("applies timeout aliases, defaultTimeoutMs, and UTF-8 stderr truncation", function()
		setup("codex")
		local hook = S.config.sources[1].hooks.PreToolUse[1].hooks[1]
		hook.type, hook.timeout = nil, nil
		hook.timeoutSec, hook.description = 0.25, "alias"
		S.config.defaultTimeoutMs, S.config.stderrSummaryMaxChars = 1200, 3
		plugin.apply(ctx, S.config)
		expect.eq(vote().decision, "allow")
		expect.eq(S.proc_opts.timeout_ms, 250)

		hook.timeout = 0.5
		plugin.apply(ctx, S.config)
		expect.eq(vote().decision, "allow")
		expect.eq(S.proc_opts.timeout_ms, 500)

		hook.timeout, hook.timeoutSec = nil, nil
		plugin.apply(ctx, S.config)
		expect.eq(vote().decision, "allow")
		expect.eq(S.proc_opts.timeout_ms, 1200)

		-- defaultTimeoutMs applies to the next hook command (no listener budget to re-register)
		S.config.defaultTimeoutMs = 2500
		expect.eq(vote().decision, "allow")
		expect.eq(S.proc_opts.timeout_ms, 2500)

		S.result = { code = 2, stdout = "", stderr = "αβγδ", dropped = 0 }
		expect.match(vote().reason, "αβγ$")
	end)

	it("handles PostToolUse result pipeline, once-only execution, and abort", function()
		setup()
		S.config.sources[1].hooks =
			{ PostToolUse = { { matcher = "probe", hooks = { { command = "check", timeout = 1 } } } } }
		plugin.apply(ctx, S.config)

		local operation = { execution_id = "execution", cancel = mare.task.token() }
		H.set_json({ hookSpecificOutput = { hookEventName = "PostToolUse", additionalContext = "POST CONTEXT" } })
		local canonical = { content = "actual tool response", value = { answer = 42 } }
		local settled = S.events["tool/program-result"](canonical, call, operation)
		expect.eq(settled.value.answer, 42)
		expect.eq(S.captured.tool_response.content, "actual tool response")
		expect.eq(S.captured.hook_event_name, "PostToolUse")
		expect.eq(S.proc_opts.cancel, operation.cancel)

		local count = S.runs
		local display = S.events["tool/after"]({ content = "later generic replacement" }, call, operation)
		expect.truthy(display.content:find("later generic replacement", 1, true))
		expect.truthy(display.content:find("POST CONTEXT", 1, true))
		expect.eq(S.runs, count)
		expect.eq(canonical.content, "actual tool response")
		expect.eq(S.events["tool/after"]({ content = "next" }, call, operation).content, "next")

		S.result = { code = 2, stdout = "", stderr = "POST DENIED", dropped = 0 }
		settled = S.events["tool/program-result"]({ content = "executed" }, call, operation)
		expect.truthy(settled.is_error)
		display = S.events["tool/after"]({ content = "executed" }, call, operation)
		expect.truthy(display.is_error)
		expect.truthy(display.content:find("POST DENIED", 1, true))
		expect.truthy(S.events["tool/program-result"]({ content = "executed" }, call, nil).is_error)

		local aborted = false
		operation.run_cancel = {
			cancel = function()
				aborted = true
			end,
		}
		H.set_json({ ["continue"] = false, stopReason = "STOP NOW" })
		expect.truthy(
			S.events["tool/program-result"]({ content = "executed", value = { answer = 42 } }, call, operation).is_error
		)
		expect.truthy(aborted)
		expect.truthy(
			S.events["tool/after"]({ content = "executed" }, call, operation).content:find("STOP NOW", 1, true)
		)

		S.result = { code = 0, stdout = "{}", stderr = "", dropped = 0, cancelled = true }
		expect.truthy(S.events["tool/program-result"]({ content = "executed" }, call, operation).is_error)
	end)

	it("decodes plain stdout context only for SessionStart and UserPromptSubmit", function()
		local decode = require("hooks.output")
		expect.eq(decode("ordinary stdout", "PreToolUse").context, nil)
		expect.eq(decode("ordinary stdout", "PostToolUse").context, nil)
		expect.eq(decode("ordinary stdout", "SessionStart").context, "ordinary stdout")
		expect.eq(decode("ordinary stdout", "UserPromptSubmit").context, "ordinary stdout")
		expect.eq(decode("  [status] context \n", "SessionStart").context, "[status] context")
		expect.eq(decode("[]", "SessionStart").context, "[]")
	end)

	it("stages SessionStart disclosures idempotently and reruns on session/changed", function()
		setup("codex")
		S.config.sources[1].hooks =
			{ SessionStart = { { matcher = "*", hooks = { { command = "check", timeout = 1 } } } } }
		plugin.apply(ctx, S.config)
		S.result.stdout = "PLAIN START CONTEXT"
		S.events["session/started"]({ resumed = false })
		expect.eq(S.runs, 1)
		expect.eq(S.captured.hook_event_name, "SessionStart")
		expect.eq(S.captured.source, "startup")
		expect.eq(S.captured.turn_id, nil)

		local prepare = S.participants["hooks.lifecycle"]
		local staged = prepare(nil)
		expect.eq(staged.disclosures[1].text, "PLAIN START CONTEXT")
		expect.eq(prepare(nil).state.last_id, staged.state.last_id)
		expect.eq(S.runs, 1)

		S.committed["hooks.lifecycle"] = staged.state
		S.events["agent/step-committed"]({})
		expect.eq(prepare(staged.state), nil)
		S.events["session/started"]({ resumed = false })
		expect.eq(S.runs, 1)

		S.session_info.session_epoch = "next-generation"
		S.events["session/changed"]({ reason = "fork" })
		expect.eq(S.captured.source, "startup")
		expect.eq(S.runs, 2)
	end)

	it("tracks Stop continuation, stop_hook_active, and abort", function()
		setup()
		S.config.sources[1].hooks = { Stop = { { matcher = "[", hooks = { { command = "check", timeout = 1 } } } } }
		plugin.apply(ctx, S.config)
		H.set_json({ decision = "block", reason = "CONTINUE" })
		local stop = {
			turn_id = "run-one",
			cancel = mare.task.token(),
			message = {
				content = { { type = "text", text = "LAST ASSISTANT" } },
			},
		}
		local continuation = S.events["agent/turn-stopping"](stop)
		expect.eq(continuation.source, "hooks")
		expect.truthy(continuation.message:find("CONTINUE", 1, true))
		expect.eq(S.captured.stop_hook_active, false)
		expect.eq(S.captured.last_assistant_message, "LAST ASSISTANT")

		S.result.stdout = "{}"
		expect.eq(S.events["agent/turn-stopping"](stop), nil)
		expect.eq(S.captured.stop_hook_active, true)

		stop.turn_id = "run-two"
		S.events["agent/turn-stopping"](stop)
		expect.eq(S.captured.stop_hook_active, false)

		H.set_json({ ["continue"] = false, stopReason = "HALT" })
		S.events["agent/turn-stopping"](stop)
		expect.eq(S.agent_aborted.reason, "hook")

		-- a core event without turn identity / cancellation must not keep the loop going
		-- (it used to return a message every turn -> max turns); one warning, no hook run
		S.captured.last_assistant_message = "UNCHANGED"
		local before = #S.diagnostics
		expect.eq(S.events["agent/turn-stopping"]({ message = stop.message, turn = 3 }), nil)
		expect.eq(S.events["agent/turn-stopping"]({ message = stop.message, turn = 4 }), nil)
		expect.eq(#S.diagnostics, before + 1)
		expect.truthy(S.diagnostics[#S.diagnostics]:find("turn_id/cancel", 1, true))
		expect.eq(S.captured.last_assistant_message, "UNCHANGED")
	end)

	it("degrades PostToolUse cleanly when tools result_pipeline capability is unavailable", function()
		setup()
		S.config.sources[1].hooks = {
			PreToolUse = { { matcher = "probe", hooks = { { command = "check", timeout = 1 } } } },
			PostToolUse = { { hooks = { { command = "check" } } } },
		}
		ctx.tools.capabilities = nil
		expect.truthy(pcall(plugin.apply, ctx, S.config))
		expect.truthy(#S.diagnostics >= 1)
		expect.truthy(S.diagnostics[#S.diagnostics]:find("PostToolUse", 1, true))
		expect.truthy(#S.notifications >= 1)
		H.set_json({
			hookSpecificOutput = {
				hookEventName = "PreToolUse",
				permissionDecision = "deny",
				permissionDecisionReason = "STILL-ACTIVE",
			},
		})
		expect.eq(vote().decision, "deny")

		setup()
		S.config.sources[1].hooks = { PostToolUse = { { hooks = { { command = "check" } } } } }
		ctx.tools.capabilities = function()
			return { result_pipeline = 0 }
		end
		expect.truthy(pcall(plugin.apply, ctx, S.config))
		expect.truthy(#S.diagnostics >= 1)
	end)

	it("treats Stop and SessionStart faults as non-fatal diagnostics", function()
		for _, event in ipairs({ "Stop", "SessionStart" }) do
			for _, fault in ipairs({ "failure", "timeout", "invalid", "exit2-empty" }) do
				setup()
				S.config.sources[1].hooks = { [event] = { { hooks = { { command = "check", timeout = 1 } } } } }
				plugin.apply(ctx, S.config)
				S.result = {
					code = fault == "failure" and 1 or fault == "exit2-empty" and 2 or 0,
					stdout = fault == "invalid" and '{"unknown":true}' or "UNSAFE OUTPUT",
					stderr = "",
					dropped = 0,
					timed_out = fault == "timeout",
				}
				if event == "Stop" then
					expect.eq(
						S.events["agent/turn-stopping"]({
							turn_id = "fault",
							cancel = mare.task.token(),
							message = { content = {} },
						}),
						nil
					)
				else
					S.events["session/started"]({ resumed = false })
					expect.eq(S.events["agent/step-ready"]({}), nil)
					expect.eq(S.participants["hooks.lifecycle"](nil), nil)
				end
				expect.eq(#S.diagnostics, 1)
				expect.eq(S.agent_aborted, nil)
			end
		end
	end)

	it("admits UserPromptSubmit inputs, stages disclosures, and requires input_admission", function()
		setup("codex")
		S.config.sources[1].hooks =
			{ UserPromptSubmit = { { matcher = "[", hooks = { { command = "check", timeout = 1 } } } } }
		plugin.apply(ctx, S.config)
		S.result.stdout = "USER CONTEXT"
		local input_token = mare.task.token()
		local input = {
			input_id = "input-one",
			attempt_id = "attempt-one",
			revision = 0,
			turn_id = "owned-run",
			source = "peer",
			content = { { type = "text", text = "FINAL PROMPT" } },
			session = { session_id = "session", session_epoch = "epoch-1" },
			cancel = input_token,
		}
		expect.eq(S.events["agent/input-ready"](input).decision, "allow")
		expect.eq(S.captured.prompt, "FINAL PROMPT")
		expect.eq(S.captured.turn_id, "owned-run")
		expect.eq(S.proc_opts.cancel, input_token)

		local prepare_input = S.participants["hooks.prompts"]
		expect.eq(prepare_input(nil, { turn_id = "owned-run", messages = {} }), nil)

		local admitted = { input_id = "input-one", input_attempt_id = "attempt-one" }
		local step = { turn_id = "owned-run", messages = { admitted } }
		local proposal = prepare_input(nil, step)
		expect.eq(proposal.disclosures[1].text, "USER CONTEXT")
		expect.eq(proposal.disclosures[1].metadata.inputs[1].attempt_id, "attempt-one")

		local invocations = S.runs
		expect.eq(prepare_input(nil, step).state.attempts[1], "attempt-one")
		expect.eq(S.runs, invocations)
		expect.eq(prepare_input(proposal.state, step), nil)

		S.committed["hooks.prompts"] = proposal.state
		S.events["agent/step-committed"]({})
		expect.eq(prepare_input(nil, step), nil)

		H.set_json({ decision = "block", reason = "INPUT DENIED" })
		input.attempt_id = "attempt-two"
		expect.eq(S.events["agent/input-ready"](input).decision, "deny")
		expect.eq(
			prepare_input(
				nil,
				{ turn_id = "owned-run", messages = { { input_id = "input-one", input_attempt_id = "attempt-two" } } }
			),
			nil
		)

		setup("claude-code")
		S.config.sources[1].hooks = {
			PreToolUse = { { matcher = "probe", hooks = { { command = "check", timeout = 1 } } } },
			UserPromptSubmit = { { hooks = { { command = "check", timeout = 1 } } } },
		}
		ctx.agent.capabilities = nil
		expect.truthy(pcall(plugin.apply, ctx, S.config))
		expect.truthy(#S.diagnostics >= 1)
		expect.truthy(S.diagnostics[#S.diagnostics]:find("UserPromptSubmit", 1, true))
		H.set_json({
			hookSpecificOutput = {
				hookEventName = "PreToolUse",
				permissionDecision = "deny",
				permissionDecisionReason = "PRE-STILL-ACTIVE",
			},
		})
		expect.eq(vote().decision, "deny")

		setup("claude-code")
		S.config.sources[1].hooks = {
			UserPromptSubmit = { { hooks = { { command = "check", timeout = 1 } } } },
		}
		ctx.agent.capabilities = function()
			return { input_admission = 0 }
		end
		expect.truthy(pcall(plugin.apply, ctx, S.config))
		expect.truthy(#S.diagnostics >= 1)

		-- SessionEnd degrades cleanly when session/closed cannot be subscribed
		setup("claude-code")
		S.config.sources[1].hooks = {
			PreToolUse = { { matcher = "probe", hooks = { { command = "check", timeout = 1 } } } },
			SessionEnd = { { hooks = { { command = "check", timeout = 1 } } } },
		}
		local orig_on = ctx.on
		ctx.on = function(self, name, fn)
			if name == "session/closed" then
				error("unknown event session/closed")
			end
			return orig_on(self, name, fn)
		end
		expect.truthy(pcall(plugin.apply, ctx, S.config))
		expect.truthy(#S.diagnostics >= 1)
		expect.truthy(S.diagnostics[#S.diagnostics]:find("SessionEnd", 1, true))
		H.set_json({
			hookSpecificOutput = {
				hookEventName = "PreToolUse",
				permissionDecision = "deny",
				permissionDecisionReason = "SESSION-END-STILL-ACTIVE",
			},
		})
		expect.eq(vote().decision, "deny")
	end)

	it("fails closed on unsupported hook types on decision events and notifies UI", function()
		for _, hook_spec in ipairs({
			{ type = "prompt", prompt = "ok?" },
			{ type = "agent", prompt = "check" },
			{ type = "http", url = "https://example.invalid", async = true },
		}) do
			setup()
			S.config.sources[1].path = "/tmp/policy.claude.json"
			S.config.sources[1].hooks = nil
			local orig_fs = mare.fs
			mare.fs = {
				read = function(p)
					if p == "/tmp/policy.claude.json" then
						return mare.json.encode_strict({
							hooks = { PreToolUse = { { matcher = "probe", hooks = { hook_spec } } } },
						})
					end
					return orig_fs.read(p)
				end,
				realpath = function(p)
					return p
				end,
			}
			plugin.apply(ctx, S.config)
			mare.fs = orig_fs
			expect.eq(#S.diagnostics, 1)
			expect.eq(#S.notifications, 1)
			expect.eq(S.notifications[1].level, "warning")
			expect.truthy(S.notifications[1].text:find(hook_spec.type, 1, true))
			expect.truthy(S.notifications[1].text:find("/tmp/policy.claude.json", 1, true))

			local v = vote()
			expect.eq(v.decision, "deny")
			expect.truthy(v.reason:find("PreToolUse", 1, true))
			expect.truthy(v.reason:find(hook_spec.type, 1, true))
			expect.truthy(v.reason:find("/tmp/policy.claude.json", 1, true))
			expect.eq(S.runs, 0)

			local non_matching = S.events["tool/before"]({ id = "c2", name = "other", arguments = {} })
			expect.eq(non_matching.decision, "allow")

			local status_res = S.commands_reg.hooks.run("status")
			expect.eq(status_res.status, "completed")
			expect.truthy(status_res.summary:find("[INACTIVE]", 1, true))
			S.select_fn = function(opts)
				expect.truthy(opts.items[1].label:find("[INACTIVE]", 1, true))
				return 1
			end
			expect.eq(S.commands_reg.hooks.run("").status, "rejected")
			S.select_fn = nil
			expect.eq(S.commands_reg.hooks.run("enable 1").status, "rejected")
			expect.eq(S.commands_reg.hooks.run("toggle 1").status, "rejected")
			expect.eq(S.commands_reg.hooks.run("trust 1").status, "rejected")
		end

		-- PermissionRequest and UserPromptSubmit also fail closed on unsupported types.
		setup("claude-code")
		S.config.sources[1].hooks = {
			PermissionRequest = {
				{ matcher = "probe", hooks = { { type = "http", url = "https://policy.example.invalid/check" } } },
			},
			UserPromptSubmit = {
				{ hooks = { { type = "prompt", prompt = "allow prompt?" } } },
			},
		}
		plugin.apply(ctx, S.config)
		expect.eq(#S.notifications, 2)
		local pr_vote = S.events["tool/approval"](call, {}, {}, mare.task.token())
		expect.eq(pr_vote.decision, "deny")
		expect.truthy(pr_vote.reason:find("PermissionRequest", 1, true))
		expect.truthy(pr_vote.reason:find("http", 1, true))
		expect.truthy(pr_vote.reason:find("inline source #1", 1, true))

		local input_vote = S.events["agent/input-ready"]({
			input_id = "in-1",
			attempt_id = "att-1",
			revision = 0,
			turn_id = "t-unsupported",
			content = { { type = "text", text = "hello" } },
			session = { session_id = "session", session_epoch = "epoch-1" },
			cancel = mare.task.token(),
		})
		expect.eq(input_vote.decision, "deny")
		expect.truthy(input_vote.reason:find("UserPromptSubmit", 1, true))
		expect.truthy(input_vote.reason:find("prompt", 1, true))
		expect.truthy(input_vote.reason:find("inline source #1", 1, true))
	end)

	it("fails closed when mixing supported command and unsupported hooks in the same matcher group", function()
		for _, reversed in ipairs({ false, true }) do
			setup("claude-code")
			local cmd_hook = { type = "command", command = "check", timeout = 1 }
			local http_hook = { type = "http", url = "https://policy.example.invalid/check" }
			S.config.sources[1].hooks = {
				PreToolUse = {
					{
						matcher = "probe",
						hooks = reversed and { http_hook, cmd_hook } or { cmd_hook, http_hook },
					},
				},
			}
			plugin.apply(ctx, S.config)
			H.set_json({ hookSpecificOutput = { hookEventName = "PreToolUse", permissionDecision = "allow" } })
			local v = vote()
			expect.eq(v.decision, "deny")
			expect.truthy(v.reason:find("http", 1, true))
			expect.truthy(v.reason:find("inline source #1", 1, true))
			expect.eq(S.runs, 1)

			local status_res = S.commands_reg.hooks.run("status")
			expect.truthy(status_res.summary:find("[ON]", 1, true))
			expect.truthy(status_res.summary:find("[INACTIVE]", 1, true))
		end
	end)

	it("skips unsupported hook types on non-gating events, notifies UI once, and lists inactive in /hooks", function()
		setup("claude-code")
		S.config.sources[1].hooks = {
			SessionStart = { { hooks = { { type = "prompt", prompt = "warmup?" } } } },
			PostToolUse = {
				{
					matcher = "probe",
					hooks = {
						{ type = "command", command = "check", timeout = 1 },
						{ type = "agent", prompt = "audit?" },
					},
				},
			},
		}
		plugin.apply(ctx, S.config)
		expect.eq(#S.diagnostics, 2)
		expect.eq(#S.notifications, 2)
		local joined_notifications = S.notifications[1].text .. "\n" .. S.notifications[2].text
		expect.truthy(joined_notifications:find("prompt", 1, true))
		expect.truthy(joined_notifications:find("agent", 1, true))

		-- Reloading on trust/changed without new warnings does not duplicate UI notifications.
		S.events["trust/changed"]({ trusted = mare.trusted == true })
		expect.eq(#S.notifications, 2)

		-- Non-gating unsupported hooks are skipped at runtime without failing PostToolUse.
		expect.eq(S.events["session/started"], nil)
		H.set_json({ hookSpecificOutput = { hookEventName = "PostToolUse", additionalContext = "POST OK" } })
		local settled = S.events["tool/program-result"]({ content = "actual" }, call, { execution_id = "ex-1" })
		expect.falsy(settled.is_error)
		expect.eq(S.runs, 1)

		local status_res = S.commands_reg.hooks.run("status")
		expect.truthy(status_res.summary:find("[INACTIVE]", 1, true))
		expect.truthy(status_res.summary:find("[ON]", 1, true))
	end)

	it("selects commandWindows/command_windows via mare.os and supports >600s timeouts", function()
		setup("codex")
		S.config.defaultTimeoutMs = 700000
		S.config.sources[1].hooks = {
			PreToolUse = {
				{
					matcher = "*",
					hooks = {
						{ command = "check", commandWindows = "check-win", timeout = 650 },
					},
				},
			},
		}
		mare.os = "windows"
		S.expected_cmd = "check-win"
		plugin.apply(ctx, S.config)
		expect.eq(vote().decision, "allow")
		expect.eq(S.proc_opts.timeout_ms, 650000)
		expect.eq(S.runs, 1)

		mare.os = "linux"
		S.expected_cmd = "check"
		S.config.sources[1].hooks.PreToolUse[1].hooks[1].commandWindows = nil
		S.config.sources[1].hooks.PreToolUse[1].hooks[1].command_windows = "check-win2"
		mare.os = "windows"
		S.expected_cmd = "check-win2"
		plugin.apply(ctx, S.config)
		expect.eq(vote().decision, "allow")
		expect.eq(S.runs, 2)
	end)

	it("expands CLAUDE_PLUGIN_ROOT and CLAUDE_PROJECT_DIR for claude-code only", function()
		setup("claude-code")
		S.config.sources[1].plugin_root = "/plugin/root"
		S.config.sources[1].hooks = {
			PreToolUse = { { hooks = { { command = "'${CLAUDE_PLUGIN_ROOT}/bin' '${CLAUDE_PROJECT_DIR}'" } } } },
		}
		S.expected_cmd = "'/plugin/root/bin' '" .. mare.cwd .. "'"
		plugin.apply(ctx, S.config)
		expect.eq(vote().decision, "allow")
		expect.eq(S.runs, 1)

		setup("codex")
		S.config.sources[1].plugin_root = "/plugin/root"
		S.config.sources[1].hooks = {
			PreToolUse = { { hooks = { { command = "'${CLAUDE_PLUGIN_ROOT}/bin'" } } } },
		}
		S.expected_cmd = "'${CLAUDE_PLUGIN_ROOT}/bin'"
		plugin.apply(ctx, S.config)
		expect.eq(vote().decision, "allow")
		expect.eq(S.runs, 1)
	end)

	it("emits systemMessage via ui.notify unless suppressOutput is true", function()
		setup()
		plugin.apply(ctx, S.config)
		H.set_json({ systemMessage = "Heads up from hook" })
		expect.eq(vote().decision, "allow")
		expect.eq(#S.notifications, 1)
		expect.eq(S.notifications[1].text, "Heads up from hook")

		H.set_json({ systemMessage = "Suppressed notice", suppressOutput = true })
		expect.eq(vote().decision, "allow")
		expect.eq(#S.notifications, 1)
	end)

	it("runs SessionEnd synchronously with 3s clamp and session/closed snapshot", function()
		setup("codex")
		S.config.sources[1].hooks = {
			SessionEnd = {
				{
					matcher = "*",
					hooks = { { command = "check" }, { command = "check", timeout = 10, async = true } },
				},
			},
		}
		plugin.apply(ctx, S.config)
		expect.eq(#S.diagnostics, 2)
		expect.falsy(S.events["session/changed"])
		expect.falsy(S.events["app/shutdown"])

		S.session_info = { session_id = "new-session", session_epoch = "new-epoch", path = "/new.jsonl" }
		S.events["session/closed"]({
			session_id = "old-session",
			session_epoch = "old-epoch",
			path = "/old.jsonl",
			cwd = mare.cwd,
			reason = "new",
		})
		expect.eq(S.runs, 2)
		expect.eq(S.captured.hook_event_name, "SessionEnd")
		expect.eq(S.captured.session_id, "old-session")
		expect.eq(S.captured.transcript_path, "/old.jsonl")
		expect.eq(S.captured.cwd, mare.cwd)
		expect.eq(S.captured.reason, "clear")
		expect.eq(S.captured.turn_id, nil)
		expect.eq(S.proc_opts.timeout_ms, 3000)

		S.result = { code = 1, stdout = "", stderr = "end failed", dropped = 0 }
		S.events["session/closed"]({
			session_id = "old-2",
			session_epoch = "old-epoch-2",
			cwd = mare.cwd,
			reason = "exit",
		})
		expect.eq(S.runs, 4)
		expect.eq(#S.diagnostics, 4)
		expect.eq(S.captured.reason, "other")
		expect.eq(S.captured.transcript_path, mare.json.null)
	end)

	it("enforces PreCompact and PostCompact contracts", function()
		setup("codex")
		S.config.sources[1].hooks = {
			PreCompact = { { matcher = "*", hooks = { { command = "check", timeout = 1 } } } },
			PostCompact = { { matcher = "*", hooks = { { command = "check", timeout = 1 } } } },
		}
		plugin.apply(ctx, S.config)
		S.result = { code = 0, stdout = "", stderr = "", dropped = 0 }
		expect.eq(S.events["compact/before"]({ reason = "manual", tokens = 100, threshold = 80 }), nil)
		expect.eq(S.runs, 1)
		expect.eq(S.captured.hook_event_name, "PreCompact")
		expect.eq(S.captured.trigger, "manual")

		S.result = { code = 2, stdout = "", stderr = "COMPACT VETO", dropped = 0 }
		expect.eq(S.events["compact/before"]({ reason = "manual", tokens = 100, threshold = 80 }), nil)
		expect.eq(S.runs, 2)
		expect.eq(#S.diagnostics, 1)
		expect.truthy(S.diagnostics[1]:find("COMPACT VETO", 1, true))

		H.set_json({ decision = "block", reason = "PRE BLOCK" })
		expect.eq(S.events["compact/before"]({ reason = "auto", tokens = 100, threshold = 80 }), nil)
		expect.eq(S.runs, 3)
		expect.eq(#S.diagnostics, 2)
		expect.truthy(S.diagnostics[2]:find("PRE BLOCK", 1, true))

		S.result = { code = 1, stdout = "", stderr = "pre fail", dropped = 0 }
		expect.eq(S.events["compact/before"]({ reason = "auto", tokens = 100, threshold = 80 }), nil)
		expect.eq(S.runs, 4)
		expect.eq(#S.diagnostics, 3)

		H.set_json({ ["continue"] = false, stopReason = "PRE STOP" })
		expect.eq(S.events["compact/before"]({ reason = "manual", tokens = 100, threshold = 80 }), false)
		expect.eq(S.runs, 5)
		expect.eq(#S.diagnostics, 4)
		expect.truthy(S.diagnostics[4]:find("PRE STOP", 1, true))

		S.events["compact/completed"]({
			reason = "manual",
			status = "failed",
			error = "boom",
			tokens_before = 100,
			tokens_after = 100,
		})
		S.events["compact/completed"]({
			reason = "manual",
			status = "cancelled",
			cancelled = true,
			tokens_before = 100,
			tokens_after = 100,
		})
		expect.eq(S.runs, 5)

		S.result = { code = 1, stdout = "", stderr = "post compact fail", dropped = 0 }
		local post_ev = { reason = "manual", status = "completed", tokens_before = 100, tokens_after = 50 }
		S.events["compact/completed"](post_ev)
		expect.eq(S.runs, 6)
		expect.eq(S.captured.hook_event_name, "PostCompact")
		expect.eq(#S.diagnostics, 5)
		expect.falsy(post_ev.stop)

		H.set_json({ ["continue"] = false, stopReason = "POST STOP" })
		local post_stop_ev = { reason = "auto", status = "completed", tokens_before = 100, tokens_after = 50 }
		S.events["compact/completed"](post_stop_ev)
		expect.eq(S.runs, 7)
		expect.falsy(post_stop_ev.stop)
		expect.truthy(S.diagnostics[#S.diagnostics]:find("POST STOP", 1, true))
	end)

	it("enforces PermissionRequest (tool/approval) contract", function()
		setup("claude-code")
		S.config.sources[1].hooks = {
			PermissionRequest = {
				{
					matcher = "probe",
					hooks = {
						{ command = "check", timeout = 1 },
						{ command = "check", timeout = 1 },
					},
				},
			},
		}
		plugin.apply(ctx, S.config)
		H.set_json({ hookSpecificOutput = { hookEventName = "PermissionRequest", decision = { behavior = "allow" } } })
		local allow_vote = S.events["tool/approval"](call, {}, {}, mare.task.token())
		expect.eq(allow_vote.decision, "allow")
		expect.eq(allow_vote.source, "hook")
		expect.eq(S.runs, 2)

		local orig_run = mare.proc.run
		local seq = 0
		mare.proc.run = function(opts)
			seq = seq + 1
			if seq == 1 then
				H.set_json({
					hookSpecificOutput = { hookEventName = "PermissionRequest", decision = { behavior = "allow" } },
				})
			else
				H.set_json({
					hookSpecificOutput = {
						hookEventName = "PermissionRequest",
						decision = { behavior = "deny", message = "DENIED BY SECOND" },
					},
				})
			end
			return orig_run(opts)
		end
		local pr_vote = S.events["tool/approval"](call, {}, {}, mare.task.token())
		mare.proc.run = orig_run
		expect.eq(pr_vote.decision, "deny")
		expect.truthy(pr_vote.reason:find("DENIED BY SECOND", 1, true))

		S.result = { code = 0, stdout = "{}", stderr = "", dropped = 0 }
		expect.eq(S.events["tool/approval"](call, {}, {}, mare.task.token()), nil)
		expect.eq(
			S.events["tool/approval"]({ id = "c2", name = "other", arguments = {} }, {}, {}, mare.task.token()),
			nil
		)

		for _, bad_json in ipairs({
			'{"continue":false}',
			'{"stopReason":"no"}',
			'{"suppressOutput":true}',
			'{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","updatedInput":{}}}}',
			'{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","updatedPermissions":{}}}}',
			'{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","interrupt":true}}}',
		}) do
			S.result = { code = 0, stdout = bad_json, stderr = "", dropped = 0 }
			expect.eq(S.events["tool/approval"](call, {}, {}, mare.task.token()).decision, "deny")
		end
	end)

	it("manages handler trust confirmation, enable/disable, and /hooks command", function()
		setup("codex")
		S.config.requireTrust = true
		S.config.sources[1].hooks = {
			PreToolUse = {
				{ matcher = "*", hooks = { { command = "check", timeout = 1 } } },
			},
		}
		plugin.apply(ctx, S.config)
		expect.truthy(S.commands_reg.hooks)
		expect.eq(type(S.commands_reg.hooks.run), "function")
		expect.eq(vote().decision, "deny")
		expect.eq(S.runs, 0)

		local trust_prompts = 0
		S.select_fn = function(opts)
			trust_prompts = trust_prompts + 1
			expect.eq(opts.title, "Trust hook handler?")
			return 2
		end
		expect.eq(vote().decision, "allow")
		expect.eq(S.runs, 1)
		expect.eq(trust_prompts, 1)
		expect.eq(vote().decision, "allow")
		expect.eq(S.runs, 2)
		expect.eq(trust_prompts, 1)

		S.select_fn = nil
		S.config.sources[1].hooks.PreToolUse[1].hooks[1].command = "check-v2"
		S.expected_cmd = "check-v2"
		plugin.apply(ctx, S.config)
		expect.eq(vote().decision, "deny")
		expect.eq(S.runs, 2)

		S.select_fn = function()
			trust_prompts = trust_prompts + 1
			return 1
		end
		expect.eq(vote().decision, "allow")
		expect.eq(S.runs, 3)
		expect.eq(trust_prompts, 2)

		S.select_fn = nil
		plugin.apply(ctx, S.config)
		expect.eq(vote().decision, "allow")
		expect.eq(S.runs, 4)

		local status_res = S.commands_reg.hooks.run("status")
		expect.eq(status_res.status, "completed")
		expect.truthy(status_res.summary:find("%[ON%]"))

		S.select_fn = function(opts)
			expect.truthy(opts.title:find("Hooks", 1, true))
			expect.eq(#opts.items, 1)
			return 1
		end
		expect.eq(S.commands_reg.hooks.run("").status, "completed")
		expect.eq(vote().decision, "allow")
		expect.eq(S.runs, 4)
		expect.eq(S.commands_reg.hooks.run("enable 1").status, "completed")
		expect.eq(vote().decision, "allow")
		expect.eq(S.runs, 5)
		expect.eq(S.commands_reg.hooks.run("disable 1").status, "completed")
		expect.eq(vote().decision, "allow")
		expect.eq(S.runs, 5)
	end)

	it("supports legacy notify argv adapter with JSON as last arg and nil stdin", function()
		setup("codex")
		S.skip_proc_assert = true
		S.config.sources[1] = {
			dialect = "codex",
			notify = { "python3", "notify.py" },
		}
		plugin.apply(ctx, S.config)
		S.result = { code = 0, stdout = "", stderr = "", dropped = 0 }
		S.events["agent/turn-stopping"]({
			turn_id = "t1",
			cancel = mare.task.token(),
			message = { content = { { type = "text", text = "done" } } },
		})
		expect.eq(S.runs, 1)
		expect.eq(S.proc_opts.cmd, "python3")
		expect.eq(S.proc_opts.input, nil)
		expect.eq(S.proc_opts.args[1], "notify.py")
		local payload = mare.json.decode(S.proc_opts.args[2])
		expect.eq(payload.hook_event_name, "Stop")
		expect.eq(payload.turn_id, "t1")
	end)

	it("deduplicates identical handlers across compatible tool aliases", function()
		setup("claude-code")
		S.config.sources[1].hooks = {
			PreToolUse = {
				{ matcher = "Bash", hooks = { { command = "check", timeout = 1 } } },
				{ matcher = "bash", hooks = { { command = "check", timeout = 1 } } },
				{ matcher = "shell", hooks = { { command = "check", timeout = 1 } } },
			},
		}
		plugin.apply(ctx, S.config)
		local bash_call = { id = "c-bash", name = "bash", arguments = {}, cwd = "/actual" }
		expect.eq(S.events["tool/before"](bash_call, {}, mare.task.token()).decision, "allow")
		expect.eq(S.runs, 1)
	end)

	it("executes matched handlers concurrently via mare.task.spawn and merges in order", function()
		setup("claude-code")
		S.config.sources[1].hooks = {
			PreToolUse = {
				{
					matcher = "probe",
					hooks = {
						{ command = "check", timeout = 1 },
						{ command = "check", timeout = 1 },
					},
				},
			},
		}
		plugin.apply(ctx, S.config)
		local spawned, waited = 0, 0
		mare.task.spawn = function(fn)
			spawned = spawned + 1
			local idx = spawned
			return {
				wait = function()
					waited = waited + 1
					expect.eq(spawned, 2)
					H.set_json(
						idx == 1 and { decision = "block", reason = "FIRST-DENY" }
							or { decision = "block", reason = "SECOND-DENY" }
					)
					return fn()
				end,
			}
		end
		local concurrent_vote = vote()
		expect.eq(spawned, 2)
		expect.eq(waited, 2)
		expect.eq(concurrent_vote.decision, "deny")
		expect.truthy(concurrent_vote.reason:find("FIRST-DENY", 1, true))
	end)

	it("fails startup on an unsupported matcher and on missing required public APIs", function()
		-- matchers are Rust regex (mare.text.regex): lookaround is not supported, and such
		-- a matcher fails configuration with a message naming it
		setup("codex")
		S.config.sources[1].hooks =
			{ PreToolUse = { { matcher = "(?=probe)probe", hooks = { { command = "check", timeout = 1 } } } } }
		local ok_matcher, err_matcher = pcall(plugin.apply, ctx, S.config)
		expect.falsy(ok_matcher)
		expect.truthy(tostring(err_matcher):find("is not a supported regex", 1, true), tostring(err_matcher))
		expect.truthy(tostring(err_matcher):find("(?=probe)probe", 1, true), tostring(err_matcher))

		setup("claude-code")
		S.config.sources[1].hooks =
			{ SessionStart = { { matcher = "startup", hooks = { { command = "check", timeout = 1 } } } } }
		ctx.agent.step_participant = nil
		local ok_step, err_step = pcall(plugin.apply, ctx, S.config)
		expect.falsy(ok_step)
		expect.truthy(tostring(err_step):find("agent:step_participant", 1, true))
	end)

	it("truncates multi-byte UTF-8 boundaries safely in hooks.spill.preview", function()
		local spill = require("hooks.spill")
		local multibyte = string.rep("界", 120) .. "é" .. string.rep("🚀", 80)
		local preview = spill.preview(multibyte, "/state/spill/utf8.log", 256)
		expect.truthy(#preview <= 256)
		expect.ne(utf8.len(preview), nil)
		expect.truthy(preview:find("... [truncated] ...", 1, true))
	end)

	it(
		"reacts to trust/changed, normalizes Claude tool_name (with Anthropic validator), aggregates votes, and fences sessions",
		function()
			-- trust/changed revokes and loads project hooks dynamically.
			H.reset()
			local files = {
				["/proj/.mare/hooks.json"] = mare.json.encode_strict({
					dialect = "claude-code",
					hooks = {
						PreToolUse = { { matcher = "Bash", hooks = { { command = "check", timeout = 1 } } } },
						PostToolUse = { { matcher = "Bash", hooks = { { command = "check", timeout = 1 } } } },
					},
				}),
			}
			mare.workspace = {
				dirs = function()
					return { "/proj" }
				end,
			}
			mare.fs = {
				exists = function(p)
					return files[p] ~= nil
				end,
				realpath = function(p)
					return p
				end,
				read = function(p)
					return assert(files[p])
				end,
			}
			mare.trusted = false
			S.skip_proc_assert = true
			S.config = { discover = { mare = true, user = false, project = true } }
			plugin.apply(ctx, S.config)
			expect.falsy(S.events["tool/program-result"])
			expect.eq(
				S.events["tool/before"]({ id = "b1", name = "bash", cwd = "/actual", arguments = { command = "ls" } }).decision,
				"allow"
			)
			expect.eq(S.runs, 0)

			-- "Trust and load" immediately discovers project hooks and mounts newly needed adapters.
			mare.trusted = true
			S.events["trust/changed"]({ trusted = true })
			expect.truthy(S.events["tool/program-result"])
			expect.eq(
				S.events["tool/before"]({ id = "b2", name = "bash", cwd = "/actual", arguments = { command = "ls" } }).decision,
				"allow"
			)
			expect.eq(S.runs, 1)
			-- Claude-dialect payload.tool_name is normalized to "Bash".
			expect.eq(S.captured.tool_name, "Bash")

			-- Revoking session-only trust immediately drops project hooks.
			mare.trusted = false
			S.events["trust/changed"]({ trusted = false })
			expect.eq(
				S.events["tool/before"]({ id = "b3", name = "bash", cwd = "/actual", arguments = { command = "ls" } }).decision,
				"allow"
			)
			expect.eq(S.runs, 1)

			-- Compatibility fixture: shell command validator hook script.
			local validator = mare.cwd .. "/tests/fixtures/hooks-validator/bash_command_validator.py"
			expect.truthy(H.orig.fs.exists(validator))
			H.reset()
			mare.proc.run = H.orig.proc_run
			mare.proc.shell = H.orig.proc_shell
			S.config = {
				sources = {
					{
						dialect = "claude-code",
						hooks = {
							PreToolUse = {
								{
									matcher = "Bash",
									hooks = {
										{
											command = "python3",
											args = { validator },
											timeout = 5,
										},
									},
								},
							},
						},
					},
				},
			}
			plugin.apply(ctx, S.config)
			local blocked = S.events["tool/before"]({
				id = "v-bad",
				name = "bash",
				cwd = mare.cwd,
				arguments = { command = "grep -rn foo ." },
			})
			expect.eq(blocked.decision, "deny")
			expect.truthy(blocked.reason:find("rg", 1, true))
			local allowed = S.events["tool/before"]({
				id = "v-ok",
				name = "bash",
				cwd = mare.cwd,
				arguments = { command = "rg foo ." },
			})
			expect.eq(allowed.decision, "allow")

			-- First deny does not break before aggregating continue:false, systemMessage, and additionalContext.
			setup("claude-code")
			S.config.sources[1].hooks = {
				PreToolUse = {
					{
						matcher = "probe",
						hooks = {
							{ command = "check", timeout = 1 },
							{ command = "check", timeout = 1 },
						},
					},
				},
			}
			plugin.apply(ctx, S.config)
			local run_idx = 0
			mare.task.spawn = function(fn)
				run_idx = run_idx + 1
				local my_idx = run_idx
				return {
					wait = function()
						H.set_json(my_idx == 1 and { decision = "block", reason = "FIRST-DENY" } or {
							["continue"] = false,
							stopReason = "SECOND-ABORT",
							systemMessage = "SYS-MSG-2",
						})
						return fn()
					end,
				}
			end
			local agg = vote()
			expect.eq(agg.decision, "deny")
			expect.truthy(agg.abort)
			expect.truthy(agg.reason:find("FIRST-DENY", 1, true))
			expect.eq(S.notifications[#S.notifications].text, "SYS-MSG-2")

			-- pre_tool fences items per session and does not queue context on denied calls.
			setup("claude-code")
			S.session_info = { session_id = "sess-a", session_epoch = "gen-a" }
			H.set_json({
				hookSpecificOutput = {
					hookEventName = "PreToolUse",
					permissionDecision = "deny",
					permissionDecisionReason = "nope",
					additionalContext = "SHOULD_NOT_QUEUE",
				},
			})
			expect.eq(vote().decision, "deny")
			expect.eq(S.participants["hooks.pre_tool"](nil, { turn_id = "" }), nil)

			H.set_json({
				hookSpecificOutput = {
					hookEventName = "PreToolUse",
					permissionDecision = "allow",
					additionalContext = "SESS-A-CTX",
				},
			})
			expect.eq(vote().decision, "allow")
			S.session_info = { session_id = "sess-b", session_epoch = "gen-b" }
			expect.eq(S.participants["hooks.pre_tool"](nil, { turn_id = "" }), nil)

			-- Lifecycle SessionStart ignores cancelled failure from previous session.
			setup("claude-code")
			S.config.sources[1].hooks = {
				SessionStart = { { matcher = "*", hooks = { { command = "check", timeout = 1 } } } },
			}
			plugin.apply(ctx, S.config)
			local saved_run = mare.proc.run
			local switched = false
			mare.proc.run = function(opts)
				if not switched then
					switched = true
					S.session_info = { session_id = "sess-2", session_epoch = "gen-2" }
					S.events["session/changed"]({ reason = "new" })
					return { code = 1, stdout = "", stderr = "aborted", dropped = 0 }
				end
				return { code = 0, stdout = "", stderr = "", dropped = 0 }
			end
			S.session_info = { session_id = "sess-1", session_epoch = "gen-1" }
			S.events["session/started"]({ resumed = false })
			mare.proc.run = saved_run
			expect.eq(S.events["agent/step-ready"](), nil)
		end
	)

	it("handles PowerShell backtick escapes during variable substitution and skips call_tool dispatcher", function()
		setup("claude-code")
		S.config.sources[1].hooks = {
			PreToolUse = {
				{
					matcher = "*",
					hooks = {
						{ command = 'pwsh -Command "echo `"${CLAUDE_PROJECT_DIR}`""', timeout = 5 },
					},
				},
			},
		}
		local orig_cwd = mare.cwd
		mare.cwd = "/tmp/dir$(evil)"
		local cfg = require("hooks.config")(S.config)
		mare.cwd = orig_cwd
		expect.eq(#cfg, 1)
		expect.truthy(cfg[1].powershell_command:find('dir`$(evil)`"', 1, true))
		expect.falsy(cfg[1].powershell_command:find("'/tmp/dir$(evil)'", 1, true))

		setup("claude-code")
		S.config.sources[1].hooks = {
			PreToolUse = { { matcher = "*", hooks = { { command = "check", timeout = 5 } } } },
			PostToolUse = { { matcher = "*", hooks = { { command = "check", timeout = 5 } } } },
			PermissionRequest = { { matcher = "*", hooks = { { command = "check", timeout = 5 } } } },
		}
		plugin.apply(ctx, S.config)
		S.runs = 0
		local dispatcher_call = { id = "c-wrap", name = "call_tool", arguments = { name = "probe", arguments = {} } }
		expect.eq(S.events["tool/before"](dispatcher_call, {}, {}), nil)
		expect.eq(S.events["tool/approval"](dispatcher_call, {}, {}), nil)
		local post_res = { content = "ok" }
		expect.eq(
			S.events["tool/program-result"]({
				result = post_res,
				call = dispatcher_call,
				operation = { execution_id = "ex-1" },
			}).result,
			post_res
		)
		expect.eq(S.runs, 0)

		-- Real inner tool still runs hooks once.
		expect.eq(vote().decision, "allow")
		expect.eq(S.runs, 1)
	end)
end)
