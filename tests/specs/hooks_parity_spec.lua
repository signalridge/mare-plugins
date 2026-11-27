local H = assert(load(mare.fs.read("tests/specs/hooks_support.lua"), "@tests/specs/hooks_support.lua"))()

local describe = mare.test.describe
local it = mare.test.it
local before_each = mare.test.before_each
local after_each = mare.test.after_each
local expect = mare.test.expect

local S, ctx, plugin, call, setup, vote = H.S, H.ctx, H.plugin, H.call, H.setup, H.vote

describe("hooks parity", function()
	before_each(function()
		H.reset()
	end)

	after_each(function()
		H.teardown()
	end)

	it("preserves env var expansion quoting and argv verbatim fidelity", function()
		mare.cwd = "/tmp/proj's $dir"
		local cfg = {
			sources = {
				{
					dialect = "claude-code",
					plugin_root = '/tmp/plug\'s "root" $v',
					hooks = {
						PreToolUse = {
							{
								matcher = "probe",
								hooks = {
									{ command = "'${CLAUDE_PLUGIN_ROOT}/bin/a' '${CLAUDE_PROJECT_DIR}'" },
									{ command = '"${CLAUDE_PLUGIN_ROOT}/bin/b" "${CLAUDE_PROJECT_DIR}"' },
									{ command = "${CLAUDE_PLUGIN_ROOT}/bin/c ${CLAUDE_PROJECT_DIR}" },
									{
										command = "${CLAUDE_PLUGIN_ROOT}/bin/d",
										args = { "${CLAUDE_PROJECT_DIR}" },
									},
								},
							},
						},
					},
				},
			},
		}
		local cmds = require("hooks.config")(cfg)
		expect.eq(#cmds, 4)
		expect.eq(cmds[1].command, "'/tmp/plug'\\''s \"root\" $v/bin/a' '/tmp/proj'\\''s $dir'")
		expect.eq(cmds[2].command, '"/tmp/plug\'s \\"root\\" \\$v/bin/b" "/tmp/proj\'s \\$dir"')
		expect.eq(cmds[3].command, "'/tmp/plug'\\''s \"root\" $v'/bin/c '/tmp/proj'\\''s $dir'")
		expect.eq(cmds[4].argv[1], '/tmp/plug\'s "root" $v/bin/d')
		expect.eq(cmds[4].argv[2], "/tmp/proj's $dir")
	end)

	it("prepares powershell-safe variable expansion without doubling backslashes", function()
		mare.cwd = [[C:\Users\dev\proj's $dir]]
		local cfg = {
			sources = {
				{
					dialect = "claude-code",
					plugin_root = [[C:\Users\dev\plug's "root" $v]],
					hooks = {
						PreToolUse = {
							{
								matcher = "probe",
								hooks = {
									{ command = [[python3 '${CLAUDE_PLUGIN_ROOT}/bin/a.py' "${CLAUDE_PROJECT_DIR}"]] },
								},
							},
						},
					},
				},
			},
		}
		local cmds = require("hooks.config")(cfg)
		expect.eq(#cmds, 1)
		expect.eq(
			cmds[1].powershell_command,
			[[python3 'C:\Users\dev\plug''s "root" $v/bin/a.py' "C:\Users\dev\proj's `$dir"]]
		)

		local shell_opts, run_opts
		mare.proc.shell = function(opts)
			shell_opts = opts
			return {
				path = "powershell.exe",
				args = { "-NoProfile", "-Command" },
				transport = "argv",
				kind = "powershell",
			}
		end
		mare.proc.run = function(opts)
			run_opts = opts
			return { code = 2, stdout = "", stderr = "ps denied", dropped = 0 }
		end
		local res = require("hooks.run")(cmds[1], { cwd = mare.cwd, hook_event_name = "PreToolUse" }, {})
		expect.eq(shell_opts and shell_opts.model, true)
		expect.eq(run_opts.cmd, "powershell.exe")
		expect.eq(run_opts.args[1], "-NoProfile")
		expect.eq(run_opts.args[2], "-Command")
		expect.truthy(run_opts.args[3]:find(cmds[1].powershell_command, 1, true))
		expect.truthy(run_opts.args[3]:find("$LASTEXITCODE", 1, true))
		expect.eq(res.decision, "deny")
		expect.eq(res.exit_code, 2)
		expect.eq(res.reason, "ps denied")
	end)

	it("classifies matchers uniformly across dialects", function()
		local function group(matcher, command)
			return { matcher = matcher, hooks = { { command = command } } }
		end
		local cmds = require("hooks.config")({
			sources = {
				{
					dialect = "codex",
					hooks = {
						PreToolUse = {
							group("Read|Write", "exact"),
							group("", "all-empty"),
							group("*", "all-star"),
							group("Bash.*", "regex"),
						},
					},
				},
				{ dialect = "claude-code", hooks = { PreToolUse = { group("Edit|Write", "exact-claude") } } },
			},
		})
		local by = {}
		for _, c in ipairs(cmds) do
			by[c.command] = c
		end
		-- word/pipe-only: exact alternatives in either dialect, never compiled
		expect.eq(by["exact"].literal, "Read|Write")
		expect.eq(by["exact"].regex, nil)
		expect.eq(by["exact-claude"].literal, "Edit|Write")
		-- empty and "*" match everything: neither literal nor regex
		expect.eq(by["all-empty"].regex, nil)
		expect.eq(by["all-star"].regex, nil)
		-- anything else is a Rust regex, matched unanchored
		local re = assert(by["regex"].regex, "Bash.* must compile to a regex")
		expect.truthy(re:is_match("Bash"))
		expect.truthy(re:is_match("xBashy"))
		expect.falsy(re:is_match("bash"))
		-- lookbehind is not supported: the matcher fails configuration
		local ok, err = pcall(require("hooks.config"), {
			sources = { { dialect = "codex", hooks = { PreToolUse = { group("(?<=x)Read", "bad") } } } },
		})
		expect.falsy(ok)
		expect.truthy(tostring(err):find("is not a supported regex", 1, true), tostring(err))
	end)

	it("discovers config/workspace/package/Claude/Codex hooks with trust enforcement and dedup", function()
		local files = {
			["/cfg/hooks.json"] = mare.json.encode_strict({
				hooks = { PreToolUse = { { matcher = "a", hooks = { { command = "cfg-mare" } } } } },
			}),
			["/work/.mare/hooks.json"] = mare.json.encode_strict({
				dialect = "claude-code",
				hooks = { PreToolUse = { { matcher = "b", hooks = { { command = "ws-mare" } } } } },
			}),
			["/plugin/one/hooks/hooks.json"] = mare.json.encode_strict({
				hooks = {
					PreToolUse = { { matcher = "c", hooks = { { command = "${CLAUDE_PLUGIN_ROOT}/plugin.sh" } } } },
					SubagentStart = { { hooks = { { command = "ignored-subagent" } } } },
				},
			}),
			["/home/.claude/settings.json"] = mare.json.encode_strict({ model = "x" }),
			["/home/.claude/settings.local.json"] = mare.json.encode_strict({
				hooks = { Stop = { { hooks = { { command = "home-claude" } } } } },
			}),
			["/work/.claude/settings.json"] = mare.json.encode_strict({
				hooks = { PreToolUse = { { matcher = "d", hooks = { { command = "ws-claude" } } } } },
			}),
			["/home/.codex/hooks.json"] = mare.json.encode_strict({
				hooks = { SessionEnd = { { hooks = { { command = "home-codex" } } } } },
			}),
			["/work/.codex/hooks.json"] = mare.json.encode_strict({
				hooks = { PostToolUse = { { matcher = "e", hooks = { { command = "ws-codex" } } } } },
			}),
		}

		mare.paths = { config = "/cfg", state = "/state" }
		mare.env = { home = "/home" }
		mare.no_user_plugins = false
		mare.workspace = {
			dirs = function()
				return { "/work", "/work-alias" }
			end,
		}
		mare.plugins = {
			dirs = function(kind)
				expect.eq(kind, nil)
				return { { name = "one/plugin", dir = "/plugin/one" } }
			end,
		}
		mare.fs = {
			exists = function(p)
				local canonical = p:gsub("^/work%-alias", "/work")
				return files[canonical] ~= nil
			end,
			realpath = function(p)
				return (p:gsub("^/work%-alias", "/work"))
			end,
			read = function(p)
				local canonical = p:gsub("^/work%-alias", "/work")
				return assert(files[canonical])
			end,
		}

		mare.trusted = false
		local untrusted_cmds, untrusted_warns = require("hooks.config")({ discover = true })
		expect.eq(#untrusted_cmds, 4)
		expect.truthy(#untrusted_warns >= 4)

		mare.trusted = true
		local trusted_cmds, trusted_warns = require("hooks.config")({ discover = true })
		expect.eq(#trusted_cmds, 7)
		expect.eq(#trusted_warns, 1)

		local claude_only = require("hooks.config")({ discover = { claude = true, user = false } })
		expect.eq(#claude_only, 1)
		expect.eq(claude_only[1].command, "ws-claude")
	end)

	it("delivers PreToolUse additionalContext, activity, spill-to-file, audit, and session/loaded replay", function()
		local working_calls, activity_fn, recorded, stored_records, spilled = {}, nil, {}, {}, {}
		local now_tick = 1000

		mare.paths = { state = "/state" }
		mare.task.now = function()
			now_tick = now_tick + 5
			return now_tick
		end
		mare.ui.connected = function()
			return true
		end
		mare.ui.working = function(msg)
			working_calls[#working_calls + 1] = msg == nil and "CLEAR" or msg
		end
		mare.proc.spill_write = function(prefix, path, text)
			expect.eq(prefix, "hooks")
			spilled[path] = text
			return true
		end
		mare.proc.spill_remove = function(prefix, path)
			expect.eq(prefix, "hooks")
			spilled[path] = nil
		end
		mare.fs = {
			read = function(path)
				return spilled[path]
			end,
		}
		ctx.agent.register_activity = function(_, ns, fn)
			expect.eq(ns, "hooks")
			activity_fn = fn
			return function() end
		end
		ctx.session.add_record = function(_, kind, data)
			expect.eq(kind, "hooks/audit")
			recorded[#recorded + 1] = data
			stored_records[#stored_records + 1] = data
			return { durable = true }
		end
		ctx.session.list_records = function(_, kind)
			expect.eq(kind, "hooks/audit")
			return { data = stored_records }
		end

		S.config = {
			sources = {
				{
					dialect = "claude-code",
					hooks = {
						PreToolUse = {
							{
								matcher = "probe",
								hooks = {
									{ command = "check", statusMessage = "Linting probe..." },
								},
							},
						},
						SessionStart = {
							{
								matcher = "startup",
								hooks = {
									{ command = "check", statusMessage = "Warming context..." },
								},
							},
						},
					},
				},
			},
		}
		plugin.apply(ctx, S.config)
		expect.eq(type(activity_fn), "function")
		expect.eq(activity_fn(), nil)

		call.name = "probe"
		H.set_json({
			hookSpecificOutput = {
				hookEventName = "PreToolUse",
				permissionDecision = "allow",
				additionalContext = "PRE TOOL HINT",
			},
		})
		local pre_vote = vote()
		expect.eq(pre_vote.decision, "allow")
		expect.eq(#working_calls, 2)
		expect.eq(working_calls[1], "Linting probe...")
		expect.eq(working_calls[2], "CLEAR")

		local act = activity_fn()
		expect.eq(#act.active, 0)
		expect.eq(#act.recent, 1)
		expect.eq(act.recent[1].status, "completed")
		expect.eq(act.recent[1].status_message, "Linting probe...")
		expect.eq(#recorded, 1)
		expect.eq(recorded[1].event, "PreToolUse")
		expect.eq(recorded[1].status, "completed")

		local tx = S.participants["hooks.pre_tool"](nil, { turn_id = "" })
		expect.truthy(tx)
		expect.eq(#tx.disclosures, 1)
		expect.eq(tx.disclosures[1].source, "hooks")
		expect.eq(tx.disclosures[1].text, "PRE TOOL HINT")
		S.committed["hooks.pre_tool"] = tx.state
		S.events["agent/step-committed"]()
		expect.eq(S.participants["hooks.pre_tool"](tx.state, { turn_id = "" }), nil)

		S.result = { code = 0, stdout = string.rep("A", 70000), stderr = "", dropped = 0 }
		S.events["session/started"]({ resumed = false })
		local ltx = S.participants["hooks.lifecycle"](nil)
		expect.truthy(ltx)
		expect.eq(#ltx.disclosures, 1)
		expect.truthy(#ltx.disclosures[1].text <= 8192)
		expect.truthy(ltx.disclosures[1].text:find("saved to /state/spill/hooks-", 1, true))
		local spill_key, spill_val = next(spilled)
		expect.truthy(spill_key)
		expect.eq(#spill_val, 70000)

		spilled = {}
		local runs_before_replay = S.runs
		local saved_run = mare.proc.run
		mare.proc.run = function(opts)
			S.runs = S.runs + 1
			S.proc_opts = opts
			expect.eq(opts.spill_prefix, "hooks")
			spilled[opts.spill] = string.rep("B", 1048600)
			return { code = 0, stdout = "", stderr = "", dropped = 100 }
		end
		call.name = "probe"
		local oversized_pre = vote()
		expect.eq(oversized_pre.decision, "deny")
		expect.truthy(oversized_pre.reason:find("saved to /state/spill/hooks-", 1, true))
		expect.eq(#recorded, 3)
		expect.eq(recorded[3].status, "failed")
		mare.proc.run = saved_run

		local runs_before_load = S.runs
		S.notifications = {}
		S.events["session/loaded"]({})
		expect.eq(S.runs, runs_before_load)
		local replayed_act = activity_fn()
		expect.eq(#replayed_act.replayed, 3)
		expect.eq(#S.notifications, 1)
		expect.truthy(S.notifications[1].text:find("Replayed 3 hook audit", 1, true))
		expect.truthy(S.runs > runs_before_replay)
	end)

	it("enforces N6 trust hash, plugin content fingerprinting, and N7 enabled persistence", function()
		local tree = {
			["/root-a/run.py"] = "print('a')",
			["/root-b/run.py"] = "print('b')",
			["/plugin-fp/hooks.json"] = '{"hooks":{}}',
			["/plugin-fp/script.py"] = "print('v1')",
		}
		mare.fs = H.make_fs_tree(tree)
		local base = {
			requireTrust = true,
			sources = {
				{
					dialect = "claude-code",
					plugin_root = "/root-a",
					hooks = {
						PreToolUse = {
							{
								matcher = "Read",
								hooks = { { command = "check", args = { "--safe" }, timeout = 5 } },
							},
						},
					},
				},
			},
		}
		local c0 = require("hooks.config")(base)
		local st = require("hooks.state").new()
		expect.truthy(st.trust(c0[1], true))
		expect.truthy(st.is_trusted(c0[1]))

		local variants = {
			function(c)
				c.sources[1].hooks.PreToolUse[1].matcher = "*"
			end,
			function(c)
				c.sources[1].hooks.PreToolUse[1].hooks[1].timeout = 10
			end,
			function(c)
				c.sources[1].hooks.PreToolUse[1].hooks[1].args = { "--unsafe" }
			end,
			function(c)
				c.sources[1].plugin_root = "/root-b"
			end,
		}
		for _, mutate in ipairs(variants) do
			local copy = {
				requireTrust = true,
				sources = {
					{
						dialect = base.sources[1].dialect,
						plugin_root = base.sources[1].plugin_root,
						hooks = {
							PreToolUse = {
								{
									matcher = "Read",
									hooks = {
										{ command = "check", args = { "--safe" }, timeout = 5 },
									},
								},
							},
						},
					},
				},
			}
			mutate(copy)
			local ci = require("hooks.config")(copy)
			local reloaded_state = require("hooks.state").new()
			expect.falsy(reloaded_state.is_trusted(ci[1]))
		end

		-- (a) Unchanged manifest + in-place modified script invalidates trust at execution time & forces re-approval.
		setup("claude-code")
		mare.fs = H.make_fs_tree(tree)
		S.config = {
			requireTrust = true,
			sources = {
				{
					dialect = "claude-code",
					plugin_root = "/plugin-fp",
					hooks = {
						PreToolUse = {
							{ matcher = "probe", hooks = { { command = "check", timeout = 5 } } },
						},
					},
				},
			},
		}
		plugin.apply(ctx, S.config)
		local select_calls = 0
		S.select_fn = function(opts)
			select_calls = select_calls + 1
			expect.eq(opts.title, "Trust hook handler?")
			return 1
		end
		call.name = "probe"
		expect.eq(vote().decision, "allow")
		expect.eq(S.runs, 1)
		expect.eq(select_calls, 1)
		expect.eq(vote().decision, "allow")
		expect.eq(S.runs, 2)
		expect.eq(select_calls, 1)

		-- Ignored runtime artifacts do not invalidate approved plugin trust.
		tree["/plugin-fp/__pycache__/script.cpython-312.pyc"] = "bytecode"
		tree["/plugin-fp/.venv/pyvenv.cfg"] = "home = /usr/bin"
		expect.eq(vote().decision, "allow")
		expect.eq(S.runs, 3)
		expect.eq(select_calls, 1)

		-- Modifying an in-bundle script with unchanged manifest/config forces re-approval immediately.
		tree["/plugin-fp/script.py"] = "print('v2-tampered')"
		S.select_fn = nil
		expect.eq(vote().decision, "deny")
		expect.eq(S.runs, 3)

		S.select_fn = function()
			select_calls = select_calls + 1
			return 1
		end
		expect.eq(vote().decision, "allow")
		expect.eq(S.runs, 4)
		expect.eq(select_calls, 2)

		-- (b) Fingerprint read failure fails closed without prompting ui.select or executing hook.
		tree["/plugin-fp/script.py"] = false
		local denied_vote = vote()
		expect.eq(denied_vote.decision, "deny")
		expect.eq(S.runs, 4)
		expect.eq(select_calls, 2)
		expect.truthy(denied_vote.reason:find("plugin content verification failed", 1, true))
		local trust_cmd_res = S.commands_reg.hooks.run("trust 1")
		expect.eq(trust_cmd_res.status, "rejected")

		-- Missing plugin root also fails closed.
		tree["/plugin-fp/hooks.json"] = nil
		tree["/plugin-fp/script.py"] = nil
		tree["/plugin-fp/__pycache__/script.cpython-312.pyc"] = nil
		tree["/plugin-fp/.venv/pyvenv.cfg"] = nil
		local missing_vote = vote()
		expect.eq(missing_vote.decision, "deny")
		expect.eq(S.runs, 4)
		expect.eq(select_calls, 2)

		-- POSIX execute-only 0111 directories fail closed, on any test host.
		local original_os = mare.os
		mare.os = "linux"
		local fp_mod = require("hooks.fingerprint")
		local base_fs = H.make_fs_tree({
			["/plugin-enum/hooks.json"] = '{"hooks":{}}',
			["/plugin-enum/sub/run.py"] = "print('ok')",
		})
		mare.fs = {
			stat = function(path)
				if path == "/plugin-enum/sub" then
					return { kind = "dir", mode = 73 }
				end
				return base_fs.stat(path)
			end,
			list = base_fs.list,
			read = base_fs.read,
		}
		local h_0111, err_0111 = fp_mod.plugin_content_hash("/plugin-enum")
		expect.falsy(h_0111)
		expect.truthy(err_0111:find("unreadable plugin directory", 1, true))

		mare.fs = {
			stat = function(path)
				if path == "/plugin-enum" then
					return { kind = "dir", mode = 73 }
				end
				return base_fs.stat(path)
			end,
			list = base_fs.list,
			read = base_fs.read,
		}
		local h_root_0111, err_root_0111 = fp_mod.plugin_content_hash("/plugin-enum")
		expect.falsy(h_root_0111)
		expect.truthy(err_root_0111:find("unreadable plugin directory", 1, true))
		mare.os = original_os

		-- Directory enumeration failures fail closed.
		mare.fs = {
			stat = base_fs.stat,
			list = function(path)
				if path == "/plugin-enum/sub" then
					return nil, "permission denied"
				end
				return base_fs.list(path)
			end,
			read = base_fs.read,
		}
		local h_nil, err_nil = fp_mod.plugin_content_hash("/plugin-enum")
		expect.falsy(h_nil)
		expect.truthy(err_nil:find("failed to list plugin directory", 1, true))

		mare.fs = {
			stat = base_fs.stat,
			list = function(path)
				if path == "/plugin-enum/sub" then
					error("EACCES")
				end
				return base_fs.list(path)
			end,
			read = base_fs.read,
		}
		local h_err, err_throw = fp_mod.plugin_content_hash("/plugin-enum")
		expect.falsy(h_err)
		expect.truthy(err_throw:find("failed to list plugin directory", 1, true))

		-- fingerprint.lua must pass { strict = true } to mare.fs.list and fail closed on strict error.
		local saw_strict = false
		mare.fs = {
			stat = base_fs.stat,
			list = function(path, opts)
				if type(opts) == "table" and opts.strict == true then
					saw_strict = true
				end
				if path == "/plugin-enum/sub" then
					if type(opts) == "table" and opts.strict == true then
						return nil, "policy-blocked entry"
					end
					return {}
				end
				return base_fs.list(path)
			end,
			read = base_fs.read,
		}
		local h_strict, err_strict = fp_mod.plugin_content_hash("/plugin-enum")
		expect.truthy(saw_strict)
		expect.falsy(h_strict)
		expect.truthy(err_strict:find("failed to list plugin directory", 1, true))

		-- N7: enabled = false -> enable -> fresh state reload preserves enabled = true.
		local disabled_cfg = {
			sources = {
				{
					dialect = "codex",
					hooks = {
						PreToolUse = {
							{ matcher = "*", hooks = { { command = "opt-in", enabled = false, timeout = 1 } } },
						},
					},
				},
			},
		}
		local dc = require("hooks.config")(disabled_cfg)
		local st1 = require("hooks.state").new()
		expect.falsy(st1.is_enabled(dc[1]))
		st1.set_enabled(dc[1], true)
		expect.truthy(st1.is_enabled(dc[1]))
		local st2 = require("hooks.state").new()
		expect.truthy(st2.is_enabled(dc[1]))
		expect.eq(mare.state.read().hooks.disabled[dc[1].id], false)
		st2.set_enabled(dc[1], false)
		local st3 = require("hooks.state").new()
		expect.falsy(st3.is_enabled(dc[1]))
	end)

	it("ignores POSIX directory modes on Windows but fails closed on enumeration errors", function()
		local original_os = mare.os
		mare.os = "windows"
		local fp_mod = require("hooks.fingerprint")
		local base_fs = H.make_fs_tree({
			["/plugin-enum/hooks.json"] = '{"hooks":{}}',
			["/plugin-enum/sub/run.py"] = "print('ok')",
		})
		mare.fs = base_fs
		local expected = assert(fp_mod.plugin_content_hash("/plugin-enum"))
		mare.fs = {
			stat = function(path)
				if path == "/plugin-enum" or path == "/plugin-enum/sub" then
					return { kind = "dir", mode = 73 }
				end
				return base_fs.stat(path)
			end,
			list = base_fs.list,
			read = base_fs.read,
		}
		expect.eq(fp_mod.plugin_content_hash("/plugin-enum"), expected)

		mare.fs.list = function(path)
			if path == "/plugin-enum/sub" then
				return nil, "permission denied"
			end
			return base_fs.list(path)
		end
		local hash, err = fp_mod.plugin_content_hash("/plugin-enum")
		expect.falsy(hash)
		expect.eq(err, "failed to list plugin directory: /plugin-enum/sub (permission denied)")

		mare.fs.list = function(path)
			if path == "/plugin-enum/sub" then
				error("EACCES")
			end
			return base_fs.list(path)
		end
		hash, err = fp_mod.plugin_content_hash("/plugin-enum")
		expect.falsy(hash)
		expect.truthy(err:find("failed to list plugin directory: /plugin-enum/sub", 1, true))
		mare.os = original_os
	end)

	it(
		"scopes command IDs per workspace, fails closed on symlinks, bounds spill reads, and serializes trust prompts",
		function()
			local cfg_mod = require("hooks.config")
			local fp_mod = require("hooks.fingerprint")
			local run_mod = require("hooks.run")
			local state_mod = require("hooks.state")

			-- Canonical workspace/source-scoped content-hashed IDs + unique cmd.label
			local settings_json =
				'{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo hi"},{"type":"command","command":"echo bye"}]}]}}'
			local function load_for_workspace(ws_dir)
				local original_fs = mare.fs
				local original_workspace = mare.workspace
				local original_cwd = mare.cwd
				local original_os = mare.os
				mare.workspace = {
					dirs = function()
						return { ws_dir }
					end,
				}
				mare.cwd = ws_dir
				mare.os = {
					env = function()
						return nil
					end,
				}
				mare.fs = {
					realpath = function(p)
						return p
					end,
					exists = function(p)
						return p == ws_dir .. "/.mare/hooks.json"
					end,
					read = function(p)
						if p == ws_dir .. "/.mare/hooks.json" then
							return settings_json
						end
						return nil, "ENOENT"
					end,
					list = function()
						return {}
					end,
				}
				local ok, res = pcall(
					cfg_mod,
					{ discover = { mare = true, user = false, project = true } },
					{ trusted = true }
				)
				mare.fs = original_fs
				mare.workspace = original_workspace
				mare.cwd = original_cwd
				mare.os = original_os
				assert(ok, res)
				return res
			end
			local cmds_a = load_for_workspace("/ws-alpha")
			local cmds_b = load_for_workspace("/ws-beta")
			expect.eq(#cmds_a, 2)
			expect.eq(#cmds_b, 2)
			expect.truthy(cmds_a[1].id ~= cmds_b[1].id)
			expect.truthy(cmds_a[1].label ~= cmds_a[2].label)

			-- Fingerprint passes no_follow = true and rejects symlinks
			local original_fs = mare.fs
			local seen_no_follow = false
			mare.fs = {
				stat = function()
					return { kind = "dir" }
				end,
				lstat = function()
					return { kind = "dir" }
				end,
				list = function(_path, opts)
					if opts and opts.no_follow then
						seen_no_follow = true
					end
					return { { name = "hook.sh", kind = "symlink" } }
				end,
				read = function()
					return "echo hi"
				end,
			}
			local fp_hash, fp_err = fp_mod.plugin_content_hash("/plugin-symlink")
			mare.fs = original_fs
			expect.truthy(seen_no_follow)
			expect.falsy(fp_hash)
			expect.truthy(fp_err)

			-- Spill read honors max_bytes, unlinks >1 MiB valid JSON spill, ignores >1 MiB stderr when stdout is small
			local big_json = '{"ok":"' .. string.rep("x", 1024 * 1024 + 32) .. '"}'
			local spill_store = {}
			local unlinked = {}
			local read_max_bytes
			local orig_fs, orig_proc, orig_paths = mare.fs, mare.proc, mare.paths
			local ok_p18, err_p18 = pcall(function()
				mare.paths = { state = "/tmp/state-spill" }
				mare.fs = {
					read = function(p, opts)
						read_max_bytes = opts and opts.max_bytes
						return spill_store[p], spill_store[p] and nil or "ENOENT"
					end,
				}
				mare.proc = {
					spill_write = function()
						return true
					end,
					spill_remove = function(_prefix, p)
						unlinked[p] = true
						spill_store[p] = nil
						return true
					end,
					run = function(opts)
						spill_store[opts.spill] = big_json
						return {
							ok = true,
							code = 0,
							stdout = "",
							stderr = "small err",
							dropped = 32,
						}
					end,
				}
				local out_big = run_mod({
					id = "cmd:big",
					command = "echo big",
					argv = { "/bin/true" },
					source = { dialect = "claude-code" },
					event = "PreToolUse",
					stderr_limit = 500,
					timeout = 1000,
				}, { cwd = "/ws" }, {})
				expect.truthy(read_max_bytes and read_max_bytes > 1024 * 1024)
				local any_unlinked = false
				for _ in pairs(unlinked) do
					any_unlinked = true
				end
				expect.truthy(any_unlinked)
				expect.eq(out_big.stdout, big_json)
				expect.eq(out_big.spill_path, nil)

				mare.proc.run = function(opts)
					spill_store[opts.spill] = '{"continue":true}'
					return {
						ok = true,
						code = 0,
						stdout = '{"continue":true}',
						stderr = string.rep("e", 600 * 1024),
						dropped = 512,
					}
				end
				local out_stderr = run_mod({
					id = "cmd:stderr",
					command = "echo stderr",
					argv = { "/bin/true" },
					source = { dialect = "claude-code" },
					event = "PreToolUse",
					stderr_limit = 500,
					timeout = 1000,
				}, { cwd = "/ws" }, {})
				expect.eq(out_stderr.stdout, '{"continue":true}')
				expect.eq(out_stderr.exit_code, 0)
			end)
			mare.fs, mare.proc, mare.paths = orig_fs, orig_proc, orig_paths
			assert(ok_p18, err_p18)

			-- ensure_trusted serializes concurrent modals
			local orig_ui, orig_state = mare.ui, mare.state
			local active_modals = 0
			local max_active_modals = 0
			local modal_calls = 0
			local persisted = { hooks = { disabled = {}, trusted = {} } }
			local ok_p130, err_p130 = pcall(function()
				local entered_tx, entered_rx = mare.task.channel()
				local gate_tx, gate_rx = mare.task.channel()
				mare.state = {
					read = function()
						return persisted
					end,
					update = function(fn)
						persisted = fn(persisted)
					end,
				}
				mare.ui = {
					select = function()
						modal_calls = modal_calls + 1
						active_modals = active_modals + 1
						if active_modals > max_active_modals then
							max_active_modals = active_modals
						end
						entered_tx:send(true)
						gate_rx:recv()
						active_modals = active_modals - 1
						return 1
					end,
				}
				local st = state_mod.new()
				local cmd_trust = {
					id = "cmd:trust-serial",
					command = "echo trust",
					label = "trust-serial",
					event = "PreToolUse",
					require_trust = true,
					hash = "fp-serial",
					declaration_hash = "fp-serial",
				}
				local t1 = mare.task.spawn(function()
					return st.ensure_trusted(cmd_trust)
				end)
				entered_rx:recv()
				local t2 = mare.task.spawn(function()
					return st.ensure_trusted(cmd_trust)
				end)
				if type(mare.task.sleep) == "function" then
					mare.task.sleep(20)
				end
				gate_tx:send(true)
				local r1 = t1:wait()
				local r2 = t2:wait()
				expect.eq(max_active_modals, 1)
				expect.eq(modal_calls, 1)
				expect.truthy(r1 and r2)
			end)
			mare.ui, mare.state = orig_ui, orig_state
			assert(ok_p130, err_p130)
		end
	)

	it("gates PowerShell wrapper $LASTEXITCODE on $? in normal and legacy_notify modes", function()
		local captured = {}
		local real_run = H.orig.proc_run
		local real_which = mare.proc.which
		mare.proc.shell = function()
			return {
				path = "powershell.exe",
				args = { "-NoProfile", "-Command" },
				transport = "argv",
				kind = "powershell",
			}
		end
		mare.proc.run = function(opts)
			captured[#captured + 1] = opts
			return { code = 0, stdout = "", stderr = "", dropped = 0 }
		end

		local run_mod = require("hooks.run")
		run_mod({
			id = "ps-normal",
			command = "cmd /c exit 2; Write-Output ok",
			powershell_command = "cmd /c exit 2; Write-Output ok",
			event = "PreToolUse",
			source = { dialect = "claude-code" },
			stderr_limit = 500,
			timeout = 1000,
		}, { cwd = "C:\\work", hook_event_name = "PreToolUse" }, {})
		run_mod({
			id = "ps-legacy",
			command = "notify.ps1",
			powershell_command = "notify.ps1",
			legacy_notify = true,
			event = "Stop",
			source = { dialect = "codex" },
			stderr_limit = 500,
			timeout = 1000,
		}, { cwd = "C:\\work", hook_event_name = "Stop" }, {})

		expect.eq(#captured, 2)
		local expected_tail =
			"; $__mare_ok = $?; if (-not $__mare_ok) { if ($LASTEXITCODE) { exit $LASTEXITCODE } else { exit 1 } } else { exit 0 }"
		for _, opts in ipairs(captured) do
			local script = opts.args[#opts.args]
			expect.truthy(script:sub(-#expected_tail) == expected_tail, script)
		end

		-- If a real PowerShell binary is available on this host, execute the exact wrapper semantics.
		local ps_bin = real_which and (real_which("pwsh") or real_which("powershell.exe"))
		if ps_bin and real_run then
			local probe_native_then_ok = mare.os == "windows" and "cmd /c exit 2; Write-Output ok"
				or "sh -c 'exit 2'; Write-Output ok"
			local r_ok = real_run({
				cmd = ps_bin,
				args = { "-NoProfile", "-Command", probe_native_then_ok .. expected_tail },
			})
			expect.eq(r_ok.code, 0)
			local probe_native_fail = mare.os == "windows" and "cmd /c exit 2" or "sh -c 'exit 2'"
			local r_fail = real_run({
				cmd = ps_bin,
				args = { "-NoProfile", "-Command", probe_native_fail .. expected_tail },
			})
			expect.eq(r_fail.code, 2)
		end
	end)

	it("doubles all five PowerShell single-quote delimiters in legacy_notify payloads", function()
		local captured = nil
		local real_run = H.orig.proc_run
		local real_which = mare.proc.which
		mare.proc.shell = function()
			return {
				path = "powershell.exe",
				args = { "-NoProfile", "-Command" },
				transport = "argv",
				kind = "powershell",
			}
		end
		mare.proc.run = function(opts)
			captured = opts
			return { code = 0, stdout = "", stderr = "", dropped = 0 }
		end

		local tricky = "a'b\u{2018}c\u{2019}; Write-Output INJECTED; \u{201A}d\u{201B}e"
		local payload = {
			cwd = "C:\\work",
			hook_event_name = "Stop",
			last_assistant_message = tricky,
		}
		require("hooks.run")({
			id = "ps-legacy-quotes",
			command = "notify.ps1",
			powershell_command = "notify.ps1",
			legacy_notify = true,
			event = "Stop",
			source = { dialect = "codex" },
			stderr_limit = 500,
			timeout = 1000,
		}, payload, {})

		expect.truthy(captured ~= nil)
		local script = captured.args[#captured.args]
		local prefix = "$global:LASTEXITCODE = 0; notify.ps1 '"
		local suffix =
			"'; $__mare_ok = $?; if (-not $__mare_ok) { if ($LASTEXITCODE) { exit $LASTEXITCODE } else { exit 1 } } else { exit 0 }"
		expect.eq(script:sub(1, #prefix), prefix)
		expect.eq(script:sub(-#suffix), suffix)
		local literal = script:sub(#prefix + 1, #script - #suffix)
		for _, q in ipairs({ "'", "\u{2018}", "\u{2019}", "\u{201A}", "\u{201B}" }) do
			expect.truthy(literal:find(q .. q, 1, true), "expected doubled quote delimiter in literal: " .. literal)
			local stripped = literal:gsub(q .. q, "")
			expect.falsy(stripped:find(q, 1, true), "found unpaired quote delimiter in literal: " .. literal)
		end

		-- When PowerShell is installed on this host, execute the exact escaped literal to confirm
		-- the payload round-trips verbatim and the injected command never executes.
		local ps_bin = real_which and (real_which("pwsh") or real_which("powershell.exe"))
		if ps_bin and real_run then
			local check_script = "[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; $global:LASTEXITCODE = 0; & { param($p) Write-Output $p } '"
				.. literal
				.. suffix
			local r = real_run({
				cmd = ps_bin,
				args = { "-NoProfile", "-Command", check_script },
			})
			expect.eq(r.code, 0)
			expect.falsy(r.stdout:find("^INJECTED", 1), r.stdout)
			local decoded = mare.json.decode(r.stdout)
			expect.eq(decoded.last_assistant_message, tricky)
		end
	end)
end)
