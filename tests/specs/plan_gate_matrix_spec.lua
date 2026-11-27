local support = assert(load(mare.fs.read("tests/specs/support.lua"), "@tests/specs/support.lua"))()

local describe = mare.test.describe
local it = mare.test.it
local before_each = mare.test.before_each
local after_each = mare.test.after_each
local expect = mare.test.expect

local make_gate = support.load_lua("plugins/plan-mode/lua/plan_mode/gate.lua")

describe("plan-mode tool policy acceptance matrix", function()
	local orig_sandbox

	before_each(function()
		orig_sandbox = mare.proc.sandbox
	end)

	after_each(function()
		mare.proc.sandbox = orig_sandbox
	end)

	local profiles = {
		{ name = "read-only", base = { level = "read-only" } },
		{ name = "auto", base = { level = "workspace-write", writable = { mare.cwd } } },
		{ name = "full-access", base = nil },
	}
	local networks = {
		{ name = "net-open", network = true },
		{ name = "net-closed", network = false },
		{
			name = "net-filtered",
			network = { allow = { "127.0.0.1" }, allow_local = true },
			unix_sockets = { "/tmp/plan-gate.sock" },
		},
	}
	local partials = {
		{ name = "no-partial", accept_partial = nil },
		{ name = "with-partial", accept_partial = { "fs_read", "network" } },
	}

	local function active_policy_for(prof, net, part)
		if prof.base == nil then
			return nil
		end
		return {
			level = prof.base.level,
			writable = prof.base.writable,
			network = net.network,
			unix_sockets = net.unix_sockets,
			accept_partial = part.accept_partial,
		}
	end

	local function install_current(policy)
		mare.proc.sandbox = setmetatable({
			current = function()
				return policy
			end,
		}, { __index = orig_sandbox })
	end

	local function plan_gate()
		return make_gate({ enforce = true, allow_tools = {} }, {
			current = function()
				return { active = true }
			end,
		})
	end

	for _, prof in ipairs(profiles) do
		for _, net in ipairs(networks) do
			for _, part in ipairs(partials) do
				-- full-access enters plan mode with no current policy, so only one combination exists.
				if not (prof.base == nil and (net.name ~= "net-open" or part.name ~= "no-partial")) then
					local label = ("%s × %s × %s"):format(prof.name, net.name, part.name)

					-- Constraint construction is tested directly without starting a process.
					it("builds the plan constraint under " .. label, function()
						local active = active_policy_for(prof, net, part)
						install_current(active)
						local gate = plan_gate()
						for _, tool_name in ipairs({ "write", "edit", "apply_patch" }) do
							expect.eq(
								gate.vote({ name = tool_name, arguments = {} }, { side_effect = "write" }).decision,
								"deny"
							)
						end
						local sv = gate.vote(
							{ name = "bash", arguments = { command = "echo hi" } },
							{ side_effect = "external" }
						)
						expect.eq(sv.decision, "allow")
						expect.eq(sv.sandbox.level, "read-only")
						expect.eq(sv.sandbox.writable, nil)
						expect.eq(sv.sandbox.network, true)
						expect.eq(sv.sandbox.accept_partial, part.accept_partial)
						expect.eq(sv.sandbox.unix_sockets, active and net.unix_sockets or nil)
						expect.eq(sv.sandbox.readable, nil)
						expect.eq(sv.sandbox.deny_read, nil)
						expect.eq(sv.sandbox.restrict_read, nil)
						-- Writes narrowed, network left to the session policy (plan does not change it).
						local effective = active and orig_sandbox.intersect(active, sv.sandbox, mare.cwd) or sv.sandbox
						expect.falsy(
							orig_sandbox.check("write", mare.cwd .. "/plan-gate-probe.txt", effective, mare.cwd)
						)
						if active then
							for _, host in ipairs({ "example.com", "127.0.0.1", "127.0.0.2" }) do
								expect.eq(
									orig_sandbox.check("network", host, effective, mare.cwd),
									orig_sandbox.check("network", host, active, mare.cwd)
								)
							end
						end
						-- Escalation, subagents, terminal and unconfined tools (rules 2-5).
						expect.eq(
							gate.vote(
								{ name = "bash", arguments = { command = "x", sandbox_permissions = "write:/tmp" } },
								{ side_effect = "external" }
							).decision,
							"deny"
						)
						expect.eq(
							gate.vote(
								{ name = "x", arguments = { additional_permissions = { write = { "/tmp" } } } },
								{ side_effect = "external", unconfined = true }
							).decision,
							"deny"
						)
						expect.eq(
							gate.vote(
								{ name = "request_permissions", arguments = {} },
								{ side_effect = "external", permission_request = true }
							).decision,
							"deny"
						)
						for _, sub_tool in ipairs({ "subagent", "subagent_steer", "workflow" }) do
							expect.eq(
								gate.vote({ name = sub_tool, arguments = {} }, { side_effect = "external" }).reason,
								"Subagents cannot be spawned or steered in plan mode"
							)
						end
						for _, term_tool in ipairs({
							"terminal_open",
							"terminal_send",
							"terminal_read",
							"terminal_list",
							"terminal_signal",
							"terminal_close",
						}) do
							expect.eq(
								gate.vote({ name = term_tool, arguments = {} }, { side_effect = "external" }).reason,
								"terminal is unavailable in plan mode"
							)
						end
						for _, job_tool in ipairs({ "job_write", "job_kill" }) do
							expect.eq(
								gate.vote({ name = job_tool, arguments = {} }, { side_effect = "external" }).decision,
								"deny"
							)
						end
						expect.eq(
							gate.vote({
								name = "peer_send",
								arguments = { to = "other", message = "hi", delivery = "trigger_turn" },
							}, { side_effect = "external" }).decision,
							"ask"
						)
						expect.eq(
							gate.vote({
								name = "peer_send",
								arguments = { to = "other", message = "hi", delivery = "queue_only" },
							}, { side_effect = "external" }).decision,
							"ask"
						)
						local mcp_ro = gate.vote(
							{ name = "mcp_read", arguments = {} },
							{ side_effect = "read", unconfined = true }
						)
						expect.eq(mcp_ro.decision, "ask")
						expect.eq(mcp_ro.amendment, nil)
						local mcp_write = gate.vote(
							{ name = "mcp_write", arguments = {} },
							{ side_effect = "write", unconfined = true }
						)
						expect.eq(mcp_write.decision, "ask")
						mare.proc.sandbox = orig_sandbox
					end)
				end
			end
		end
	end

	it("preserves prior session sandbox_grant network authorization when narrowing writes", function()
		mare.proc.sandbox = {
			current = function()
				return { level = "workspace-write", writable = { mare.cwd }, network = false }
			end,
			check = orig_sandbox.check,
			policy = orig_sandbox.policy,
		}
		local gate = make_gate({ enforce = true, allow_tools = {} }, {
			current = function()
				return { active = true }
			end,
		})
		local sv = gate.vote({ name = "bash", arguments = { command = "curl https://api.example.com" } }, {
			side_effect = "external",
		})
		expect.eq(sv.decision, "allow")
		local session_grant = {
			level = "workspace-write",
			writable = { mare.cwd },
			network = { allow = { "api.example.com" } },
		}
		local combined = orig_sandbox.intersect(session_grant, sv.sandbox, mare.cwd)
		expect.truthy(orig_sandbox.check("network", "api.example.com", combined, mare.cwd))
		expect.falsy(orig_sandbox.check("write", mare.cwd .. "/probe.txt", combined, mare.cwd))
	end)

	it("preserves workspace readability under restrict_read when narrowing writes", function()
		mare.proc.sandbox = {
			current = function()
				return {
					level = "workspace-write",
					writable = { mare.cwd },
					restrict_read = true,
					readable = {},
					deny_read = { mare.cwd .. "/plugins/plan-mode/README.md" },
					network = true,
				}
			end,
			check = orig_sandbox.check,
			policy = orig_sandbox.policy,
		}
		local gate = make_gate({ enforce = true, allow_tools = {} }, {
			current = function()
				return { active = true }
			end,
		})
		local sv = gate.vote({ name = "bash", arguments = { command = "ls" } }, { side_effect = "external" })
		expect.eq(sv.decision, "allow")
		local base = {
			level = "workspace-write",
			writable = { mare.cwd },
			restrict_read = true,
			readable = {},
			deny_read = { mare.cwd .. "/plugins/plan-mode/README.md" },
			network = true,
		}
		local combined = orig_sandbox.intersect(base, sv.sandbox, mare.cwd)
		expect.truthy(orig_sandbox.check("read", mare.cwd .. "/plugins/plan-mode/init.lua", combined, mare.cwd))
		expect.falsy(orig_sandbox.check("read", mare.cwd .. "/plugins/plan-mode/README.md", combined, mare.cwd))
		expect.falsy(orig_sandbox.check("write", mare.cwd .. "/probe.txt", combined, mare.cwd))
	end)

	it("respects exit_plan_mode and allow_tools exemptions", function()
		local gate = make_gate({ enforce = true, allow_tools = { "custom_write", "custom_mcp" } }, {
			current = function()
				return { active = true }
			end,
		})
		expect.eq(gate.vote({ name = "exit_plan_mode", arguments = {} }, { side_effect = "write" }), nil)
		expect.eq(gate.vote({ name = "custom_write", arguments = {} }, { side_effect = "write" }), nil)
		expect.eq(gate.vote({ name = "custom_mcp", arguments = {} }, { side_effect = "read", unconfined = true }), nil)
	end)

	it("abstains on every tool category once plan mode is inactive", function()
		local gate = make_gate({ enforce = true, allow_tools = {} }, {
			current = function()
				return { active = false }
			end,
		})
		expect.eq(gate.vote({ name = "write", arguments = {} }, { side_effect = "write" }), nil)
		-- Once plan mode has exited, the gate abstains (returns nil) on all tool categories.
		expect.eq(gate.vote({ name = "edit", arguments = {} }, { side_effect = "write" }), nil)
		expect.eq(gate.vote({ name = "apply_patch", arguments = {} }, { side_effect = "write" }), nil)
		expect.eq(gate.vote({ name = "bash", arguments = { command = "ls" } }, { side_effect = "external" }), nil)
		expect.eq(
			gate.vote(
				{ name = "bash", arguments = { sandbox_permissions = "write:/tmp" } },
				{ side_effect = "external" }
			),
			nil
		)
		expect.eq(gate.vote({ name = "subagent", arguments = {} }, { side_effect = "external" }), nil)
		expect.eq(gate.vote({ name = "subagent_steer", arguments = {} }, { side_effect = "external" }), nil)
		expect.eq(gate.vote({ name = "terminal_open", arguments = {} }, { side_effect = "external" }), nil)
		expect.eq(gate.vote({ name = "mcp_probe", arguments = {} }, { side_effect = "read", unconfined = true }), nil)
		expect.eq(
			gate.vote(
				{ name = "request_permissions", arguments = {} },
				{ side_effect = "external", permission_request = true }
			),
			nil
		)
	end)
end)
