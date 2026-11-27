local support = assert(load(mare.fs.read("tests/specs/support.lua"), "@tests/specs/support.lua"))()

local describe = mare.test.describe
local it = mare.test.it
local before_each = mare.test.before_each
local after_each = mare.test.after_each
local expect = mare.test.expect

local plugin = support.load_plugin("terminals", {
	"terminal.config",
	"terminal.view",
	"terminal.backends",
	"terminal.buffer",
	"terminal.registry",
	"terminal.operation",
	"terminal.jobs",
})
local Config = require("terminal.config")
local View = require("terminal.view")
local Backends = require("terminal.backends")
local Buffer = require("terminal.buffer")
local Registry = require("terminal.registry")
local Operation = require("terminal.operation")

describe("terminal", function()
	local orig_os, orig_which, orig_shell, orig_stat, orig_env, orig_agent_id, orig_pty_caps

	local function copy_cfg()
		local c = support.default_config(plugin)
		c.shell_args = {}
		return c
	end

	local function ui_json(node)
		return mare.json.decode(mare.json.encode(node))
	end

	before_each(function()
		orig_os = mare.os
		orig_which = mare.proc.which
		orig_shell = mare.proc.shell
		orig_stat = mare.fs.stat
		orig_env = mare.env
		orig_agent_id = mare.agent_id
		orig_pty_caps = mare.pty and mare.pty.capabilities
	end)

	after_each(function()
		mare.os = orig_os
		mare.proc.which = orig_which
		mare.proc.shell = orig_shell
		mare.fs.stat = orig_stat
		mare.env = orig_env
		mare.agent_id = orig_agent_id
		if mare.pty then
			mare.pty.capabilities = orig_pty_caps
		end
	end)

	it("detects shells cross-platform and validates budgets and grace intervals", function()
		-- Bare cfg.shell resolves via mare.proc.which
		mare.proc.which = function(name)
			if name == "custom-bash" then
				return "/opt/bin/custom-bash"
			end
			return nil
		end
		local cfg = copy_cfg()
		cfg.shell = "custom-bash"
		local path, args = Config.shell(cfg)
		expect.eq(path, "/opt/bin/custom-bash")
		expect.eq(args[1], "--noprofile")

		-- Windows pwsh -> powershell.exe fallback
		mare.os = "windows"
		mare.proc.which = function(name)
			if name == "powershell.exe" then
				return "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"
			end
			return nil
		end
		cfg = copy_cfg()
		cfg.shell_dialect = "pwsh"
		path, args = Config.shell(cfg)
		expect.eq(path, "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe")
		expect.eq(args[1], "-NoLogo")
		expect.eq(args[2], "-NoProfile")

		-- Windows bash -> mare.proc.shell() fallback
		mare.proc.which = function()
			return nil
		end
		mare.proc.shell = function()
			return { kind = "bash", path = "C:\\Program Files\\Git\\bin\\bash.exe" }
		end
		cfg = copy_cfg()
		path = Config.shell(cfg)
		expect.eq(path, "C:\\Program Files\\Git\\bin\\bash.exe")

		-- Windows bash -> ProgramFiles mare.fs.stat fallback
		local git_bash = "C:\\Program Files (x86)\\Git\\bin\\bash.exe"
		mare.proc.shell = nil
		mare.env = function(name)
			if name == "ProgramFiles(x86)" then
				return "C:\\Program Files (x86)"
			end
			return nil
		end
		mare.fs.stat = function(p)
			if p == git_bash then
				return { kind = "file" }
			end
			return nil
		end
		cfg = copy_cfg()
		path = Config.shell(cfg)
		expect.eq(path, git_bash)

		-- Budget validation: viewport cells > 200000 rejected, == 200000 accepted
		cfg = copy_cfg()
		cfg.rows = 200
		cfg.cols = 1000
		Config.validate(cfg)
		cfg.rows = 500
		cfg.cols = 500
		expect.error(function()
			Config.validate(cfg)
		end)

		-- Grace composition: must be 0 or >= poll_interval_ms
		cfg = copy_cfg()
		cfg.poll_interval_ms = 50
		cfg.handoff_grace_ms = 25
		expect.error(function()
			Config.validate(cfg)
		end)
		cfg.handoff_grace_ms = 0
		Config.validate(cfg)
		cfg.prompt_tail_grace_ms = 25
		expect.error(function()
			Config.validate(cfg)
		end)
		cfg.prompt_tail_grace_ms = 50
		Config.validate(cfg)
	end)

	it("renders view folding, CJK/wide output, alternate screen, and session lists", function()
		-- Spinner with nil args
		local spinner = ui_json(View("terminal_open", nil, nil, false))
		expect.eq(spinner.type, "spinner")
		expect.match(mare.json.encode(spinner), "terminal_open · opening")

		-- Error folding: compact clips, expanded does not
		local err_res = { is_error = true, content = "line1\nline2\nline3\nline4\nline5\n" }
		local err_compact = ui_json(View("terminal_send", {}, err_res, false))
		local err_expanded = ui_json(View("terminal_send", {}, err_res, true))
		expect.eq(err_compact.type, "clip")
		expect.eq(err_compact.max, 4)
		expect.eq(err_expanded.type, "paragraph")

		-- Output folding with CJK & emoji
		local lines = {}
		for i = 1, 20 do
			lines[i] = ("第%d行 中文宽字符 🌊"):format(i)
		end
		local long_out = table.concat(lines, "\n") .. "\n"
		local send_res = {
			details = {
				name = "dev",
				wait_reason = "prompt",
				command_exit_code = 0,
				output = long_out,
				truncated = true,
				dropped_lines = 12,
			},
		}
		local compact = ui_json(View("terminal_send", {}, send_res, false))
		expect.eq(compact.type, "lines")
		expect.match(mare.json.encode(compact.items[1]), "cmd 0")
		expect.eq(compact.items[2].type, "clip")
		expect.eq(compact.items[2].max, 8)
		expect.eq(compact.items[2].tail, true)
		expect.eq(compact.items[2].child.type, "code")
		expect.falsy(compact.items[2].child.code:find("\n$"))
		expect.eq(compact.items[3].type, "paragraph")
		expect.eq(compact.items[3].style, "muted")

		local expanded = ui_json(View("terminal_send", {}, send_res, true))
		expect.eq(expanded.items[2].type, "code")

		-- Alternate screen in expanded mode
		local alt_res = {
			details = {
				session_id = "abc",
				status = "running",
				alternate_screen = true,
				text = "history line",
				screen = "alt screen content",
			},
		}
		local alt_view = ui_json(View("terminal_read", {}, alt_res, true))
		expect.match(mare.json.encode(alt_view.items[1]), "alt%-screen")
		expect.eq(alt_view.items[3].type, "paragraph")
		expect.eq(alt_view.items[3].style, "muted")
		expect.eq(alt_view.items[4].code, "alt screen content")

		-- Sessions list folding & empty state
		local empty_list = ui_json(View("terminal_list", {}, { details = { sessions = {} } }, false))
		expect.eq(empty_list.items[2].type, "paragraph")
		expect.eq(empty_list.items[2].style, "muted")

		local sessions = {}
		for i = 1, 12 do
			sessions[i] = { session_id = "s" .. i, name = "term-" .. i, status = "running", type = "bash" }
		end
		local list_compact = ui_json(View("terminal_list", {}, { details = { sessions = sessions } }, false))
		local list_expanded = ui_json(View("terminal_list", {}, { details = { sessions = sessions } }, true))
		expect.eq(list_compact.items[2].type, "clip")
		expect.eq(list_compact.items[2].max, 8)
		expect.eq(list_expanded.items[2].type, "lines")
		expect.eq(#list_expanded.items[2].items, 12)
	end)

	it("configures pwsh bootstrap and manages backend service lifecycle", function()
		mare.proc.which = function(name)
			if name == "bash" then
				return "/bin/bash"
			elseif name == "pwsh" then
				return "/usr/bin/pwsh"
			end
			return nil
		end
		local provided = {}
		local dispose_cbs = {}
		local ctx = {
			effect = function(_, setup)
				local fn = setup()
				dispose_cbs[#dispose_cbs + 1] = fn
			end,
			provide = function(_, name, svc)
				provided[name] = svc
			end,
		}
		local mgr = Backends(ctx, copy_cfg())
		local listed = provided.terminals:list()
		expect.eq(#listed, 2)
		expect.eq(listed[1], "bash")
		expect.eq(listed[2], "pwsh")
		local pwsh = mgr.get("pwsh")
		expect.truthy(pwsh.bootstrap:find("InputEncoding", 1, true))
		expect.truthy(pwsh.bootstrap:find("OutputEncoding", 1, true))
		expect.truthy(pwsh.bootstrap:find("$LASTEXITCODE", 1, true))
		expect.truthy(pwsh.bootstrap:find("$?", 1, true))

		local removed_name
		mgr.on_remove(function(entry)
			removed_name = entry.name
		end)
		local custom_disposes = {}
		local custom_caller = {
			effect = function(_, setup)
				local fn = setup()
				custom_disposes[#custom_disposes + 1] = fn
			end,
		}
		provided.terminals:register(custom_caller, "custom", {
			open = function() end,
		})
		expect.eq(#provided.terminals:list(), 3)
		custom_disposes[1]()
		expect.eq(removed_name, "custom")
		expect.eq(#provided.terminals:list(), 2)

		-- Disposing service rejects late backend registration
		for _, fn in ipairs(dispose_cbs) do
			fn()
		end
		expect.error(function()
			provided.terminals:register(custom_caller, "late", {
				open = function() end,
			})
		end, "disposing")
	end)

	it("preserves UTF-8 boundaries when buffer drops CJK lines", function()
		local b = Buffer.new(128, 3)
		b:append("一二三\n四五六\n七八九\n十\n")
		expect.truthy(utf8.len(b.text))
		expect.truthy(b.dropped)
	end)

	it("isolates registry sessions per agent and bumps generation on cleanup", function()
		mare.agent_id = "agent-a"
		local stop_result = { stopped = true, stop_unconfirmed = false }
		local fake_pty = {
			pid = function()
				return 4242
			end,
			exit_status = function()
				return nil
			end,
			view = function()
				return { screen = "", view_truncated = false, alternate_screen = false, prompt_generation = 1 }
			end,
			read_text = function()
				return nil
			end,
			try_wait = function()
				return nil
			end,
			stop = function()
				return stop_result
			end,
			kill = function() end,
		}
		local listeners = {}
		local rctx = {
			spawn = function(_, fn)
				return {
					abort = function() end,
					_fn = fn,
				}
			end,
			on = function(_, ev, fn)
				listeners[ev] = fn
			end,
			on = function() end,
			effect = function(_, setup)
				setup()
			end,
		}
		local rcfg = copy_cfg()
		local reg = Registry(rctx, rcfg, {
			get = function()
				return {
					name = "bash",
					active = true,
					removed = mare.task.token(),
					open = function()
						return fake_pty
					end,
				}
			end,
			on_remove = function() end,
		})
		local rec_a = reg:open("shared-name", "/tmp", { cancel = mare.task.token() }, "bash")
		expect.eq(reg:snapshot(rec_a).pid, 4242)
		expect.eq(#reg:list(), 1)

		-- Different agent owner has isolated namespace & cannot see or steal agent-a's session
		mare.agent_id = "agent-b"
		expect.eq(#reg:list(), 0)
		expect.error(function()
			reg:get(rec_a.id)
		end)
		local rec_b = reg:open("shared-name", "/tmp", { cancel = mare.task.token() }, "bash")
		expect.ne(rec_b.id, rec_a.id)
		expect.eq(#reg:list(), 1)

		-- cleanup() increments generation even when stop_unconfirmed occurs
		stop_result = { stopped = false, stop_unconfirmed = true }
		expect.error(function()
			reg:cleanup()
		end, "stop unconfirmed")
		expect.error(function()
			reg:get(rec_b.id)
		end)
		mare.agent_id = "agent-a"
		expect.error(function()
			reg:get(rec_a.id)
		end)
	end)

	it("falls back to Ctrl+C write and rejects terminal_signal when foreground_signals is false", function()
		mare.pty.capabilities = function()
			return {
				streaming_text = true,
				terminal_view = true,
				policy_fence = true,
				max_write_bytes = 16384,
				foreground = false,
				foreground_signals = false,
			}
		end

		local writes = {}
		local spawned = {}
		local op_ctx = {
			spawn = function(_, fn)
				spawned[#spawned + 1] = fn
				return {}
			end,
		}
		local ocfg = copy_cfg()
		local ops = Operation(op_ctx, ocfg, {}, { foreground = false, foreground_signals = false })
		local fake_rec = {
			busy = false,
			closing = false,
			eof = false,
			last_output = mare.task.clock(),
			buffer = Buffer.new(1024, 10),
			pty = {
				view = function()
					return { prompt_generation = 1, tail = "" }
				end,
				foreground = function()
					return nil
				end,
				write = function(_, data)
					writes[#writes + 1] = data
				end,
				signal = function()
					error("signal must not be called when foreground_signals is false")
				end,
			},
		}
		local tok = mare.task.token()
		local op = ops:start(fake_rec, "sleep 30\r", 1000, tok)
		tok:cancel()
		fake_rec.closing = true
		spawned[1]()
		expect.truthy(op.interrupted)
		expect.eq(writes[2], "\3")

		-- terminal_signal tool refuses when foreground_signals = false
		local registered = {}
		local pctx = {
			tools = {
				register = function(_, name, def)
					registered[name] = def
				end,
			},
			context = { section = function() end },
			on = function() end,
			on = function() end,
			effect = function(_, setup)
				setup()
			end,
			provide = function() end,
		}
		plugin.apply(pctx, copy_cfg())
		local sig_res = registered.terminal_signal.execute(
			{ session_id = "missing", signal = "SIGINT" },
			{ cancel = mare.task.token() }
		)
		expect.truthy(sig_res.is_error)

		-- Combined viewport budget is re-validated on runtime writes before opening a PTY
		local bad_cfg = copy_cfg()
		local bad_reg = Registry(
			{
				agent = {
					id = function()
						return "agent-bad"
					end,
				},
				on = function() end,
				effect = function(_, setup)
					setup()
				end,
			},
			bad_cfg,
			{
				open = function()
					return {}
				end,
				on_remove = function() end,
			}
		)
		bad_cfg.rows = 1000
		bad_cfg.cols = 300
		expect.error(function()
			bad_reg:open("oversized", "/tmp", { cancel = mare.task.token() })
		end, "Terminal viewport exceeds cell budget")

		-- op:tail aligns to valid UTF-8 boundaries even when avail == max_bytes.
		local tail_rec = {
			busy = false,
			closing = false,
			eof = false,
			buffer = Buffer.new(1024, 100),
			pty = {
				view = function()
					return { prompt_generation = 1, tail = "" }
				end,
				write = function() end,
			},
		}
		local tail_op = Operation({
			spawn = function()
				return {}
			end,
		}, copy_cfg(), {}, { foreground = false, foreground_signals = false }):start(
			tail_rec,
			"echo hi\r",
			1000,
			mare.task.token()
		)
		tail_op.buffer:append("A界")
		local t2, f2, tr2 = tail_op:tail(2)
		expect.truthy(utf8.len(t2) ~= nil)
		expect.eq(t2, "")
		expect.eq(f2, 4)
		expect.eq(tr2, true)
		local t3, f3, tr3 = tail_op:tail(3)
		expect.truthy(utf8.len(t3) ~= nil)
		expect.eq(t3, "界")
		expect.eq(f3, 4)
		expect.eq(tr3, true)
		local t4, f4, tr4 = tail_op:tail(4)
		expect.truthy(utf8.len(t4) ~= nil)
		expect.eq(t4, "A界")
		expect.eq(f4, 4)
		expect.eq(tr4, false)
	end)

	it(
		"sets command_tool/command/resolve_cwd, decouples background cancel, supports read_at, enforces over_limit before write, and keeps stop_unconfirmed closeable",
		function()
			mare.pty.capabilities = function()
				return {
					streaming_text = true,
					terminal_view = true,
					policy_fence = true,
					max_write_bytes = 16384,
					foreground = false,
					foreground_signals = false,
				}
			end

			-- op:read_at and status().bytes
			local buf_op = Operation({
				spawn = function()
					return {}
				end,
			}, copy_cfg(), {}, { foreground = false, foreground_signals = false }):start({
				busy = false,
				closing = false,
				eof = false,
				buffer = Buffer.new(1024, 100),
				pty = {
					view = function()
						return { prompt_generation = 1, tail = "" }
					end,
					write = function() end,
				},
			}, "echo ok\r", 1000, mare.task.token())
			buf_op.buffer:append("AB界CD")
			local st = buf_op:status()
			expect.eq(st.bytes, 7)
			local r1 = buf_op:read_at(0, { max_bytes = 3 })
			expect.eq(r1.text, "AB")
			expect.eq(r1.next, 2)
			local r2 = buf_op:read_at(r1.next, { max_bytes = 10 })
			expect.eq(r2.text, "界CD")
			expect.eq(r2.next, 7)

			-- stop_unconfirmed retired PTY does not strand max_sessions/names and stays closeable
			local stop_calls = 0
			local retired_backend = {
				open = function()
					return {
						write = function() end,
						page = function()
							return { lines = {}, total = 0 }
						end,
						view = function()
							return { prompt_generation = 1, tail = "mare> " }
						end,
						foreground = function()
							return nil
						end,
						exit_status = function()
							return nil
						end,
						kill = function() end,
						try_wait = function()
							return nil
						end,
						read_text = function()
							return nil
						end,
						stop = function()
							stop_calls = stop_calls + 1
							if stop_calls <= 3 then
								return { stopped = false, stop_unconfirmed = true }
							end
							return { stopped = true }
						end,
					}
				end,
				on_remove = function() end,
			}
			local cfg1 = copy_cfg()
			cfg1.max_sessions = 1
			local r_reg = Registry(
				{
					agent = {
						id = function()
							return "agent-retire"
						end,
					},
					spawn = function()
						return { abort = function() end }
					end,
					on = function() end,
					effect = function(_, setup)
						setup()
					end,
				},
				cfg1,
				{
					get = function()
						return {
							name = "bash",
							active = true,
							removed = mare.task.token(),
							open = retired_backend.open,
						}
					end,
					on_remove = retired_backend.on_remove,
				}
			)
			mare.agent_id = "agent-retire"
			local first = r_reg:open("work", "/tmp", { cancel = mare.task.token() })
			expect.error(function()
				r_reg:cleanup()
			end, "Terminal stop unconfirmed")
			expect.eq(#r_reg:list(), 1)
			expect.eq(r_reg:list()[1].status, "closing")
			expect.eq(r_reg:list()[1].stop_unconfirmed, true)
			expect.eq(r_reg:list()[1].retired, true)
			expect.error(function()
				r_reg:get(first.id)
			end)
			local close_only = r_reg:get_for_close(first.id)
			expect.eq(close_only.id, first.id)
			-- Duplicate name and max_sessions=1 must both allow opening a new live session
			local second = r_reg:open("work", "/tmp", { cancel = mare.task.token() })
			expect.ne(second.id, first.id)
			expect.eq(r_reg:close(close_only).stopped, true)

			-- command_tool metadata, background cancel decoupling, over_limit before PTY write
			local tools = {}
			local spawned = {}
			local pty_writes = {}
			local over_limit_flag = false
			local cancelled_jobs = {}
			local tracked_handles = {}
			local orig_spawn = mare.pty and mare.pty.spawn
			local orig_which_local = mare.proc.which
			local orig_stat_local = mare.fs.stat
			mare.proc.which = function(n)
				if n == "bash" then
					return "/bin/bash"
				end
				return nil
			end
			mare.fs.stat = function(p)
				return { kind = "dir" }
			end
			mare.pty.spawn = function()
				return {
					write = function(_, d)
						pty_writes[#pty_writes + 1] = d
					end,
					page = function()
						return { lines = {}, total = 0 }
					end,
					view = function()
						return { prompt_generation = 1, tail = "mare> " }
					end,
					foreground = function()
						return nil
					end,
					exit_status = function()
						return nil
					end,
					try_wait = function()
						return nil
					end,
					read_text = function()
						return nil
					end,
					kill = function() end,
					stop = function()
						return { stopped = true }
					end,
				}
			end
			local jobs_svc = {
				track = function(_, spec)
					tracked_handles[#tracked_handles + 1] = spec.handle
					return { job_id = "job-1", over_limit = over_limit_flag }
				end,
				cancel = function(_, id)
					cancelled_jobs[#cancelled_jobs + 1] = id
				end,
			}
			local svc_ctx = {
				tools = {
					register = function(_, name, def)
						tools[name] = def
					end,
				},
				context = { section = function() end },
				on = function() end,
				effect = function(_, setup)
					setup()
				end,
				provide = function() end,
				spawn = function(_, fn)
					spawned[#spawned + 1] = fn
					return { abort = function() end }
				end,
				jobs = jobs_svc,
				get = function(_, name)
					if name == "jobs" then
						return jobs_svc
					end
					return nil
				end,
			}
			local pcfg = copy_cfg()
			pcfg.poll_interval_ms = 10
			pcfg.handoff_grace_ms = 10
			pcfg.prompt_tail_grace_ms = 10
			plugin.apply(svc_ctx, pcfg)

			-- command_tool metadata assertions
			expect.eq(tools.terminal_open.command_tool, true)
			expect.eq(tools.terminal_open.command.argv[1], "bash")
			expect.eq(tools.terminal_send.command_tool, true)
			expect.eq(tools.terminal_send.command.shell, "bash")
			expect.eq(tools.terminal_send.command.arg, "text")

			local open_res = tools.terminal_open.execute({ name = "bg", cwd = "/tmp" }, { cancel = mare.task.token() })
			expect.falsy(open_res.is_error, tostring(open_res.content))
			local sid = open_res.details.session_id

			-- over_limit rejects BEFORE writing to PTY
			pty_writes = {}
			over_limit_flag = true
			local ol_res = tools.terminal_send.execute(
				{ session_id = sid, text = "echo blocked", run_in_background = true },
				{ cancel = mare.task.token() }
			)
			expect.eq(ol_res.is_error, true)
			expect.eq(ol_res.content, "Background job limit reached")
			expect.eq(#pty_writes, 0)
			expect.eq(cancelled_jobs[1], "job-1")

			-- Cancelling tool.cancel after background return does NOT kill operation
			over_limit_flag = false
			pty_writes = {}
			local call_tok = mare.task.token()
			local bg_res = tools.terminal_send.execute(
				{ session_id = sid, text = "sleep 5", run_in_background = true },
				{ cancel = call_tok }
			)
			expect.falsy(bg_res.is_error)
			expect.eq(bg_res.details.wait_reason, "background")
			expect.eq(#pty_writes, 1)
			call_tok:cancel()
			expect.falsy(tracked_handles[#tracked_handles].cancelled)
			expect.eq(tracked_handles[#tracked_handles].op_cancel:is_cancelled(), false)

			mare.pty.spawn = orig_spawn
			mare.proc.which = orig_which_local
			mare.fs.stat = orig_stat_local
		end
	)

	it("registers session:on_drain cleanup before session/changed and propagates stop_unconfirmed", function()
		mare.agent_id = "agent-drain"
		local drain_hooks = {}
		local stop_calls = 0
		local stop_res = { stopped = true }
		local drain_ctx = {
			spawn = function()
				return { abort = function() end }
			end,
			on = function() end,
			effect = function(_, setup)
				setup()
			end,
			inject = function(_, deps, fn)
				if deps[1] == "session" then
					fn({
						session = {
							on_drain = function(_, cb)
								drain_hooks[#drain_hooks + 1] = cb
							end,
						},
					})
				end
			end,
		}
		local drain_reg = Registry(drain_ctx, copy_cfg(), {
			get = function()
				return {
					name = "bash",
					active = true,
					removed = mare.task.token(),
					open = function()
						return {
							pid = function()
								return 5150
							end,
							exit_status = function()
								return nil
							end,
							view = function()
								return {
									screen = "",
									view_truncated = false,
									alternate_screen = false,
									prompt_generation = 1,
								}
							end,
							read_text = function()
								return nil
							end,
							try_wait = function()
								return nil
							end,
							stop = function()
								stop_calls = stop_calls + 1
								return stop_res
							end,
							kill = function() end,
						}
					end,
				}
			end,
			on_remove = function() end,
		})
		expect.eq(#drain_hooks, 1)

		local rec = drain_reg:open("pre-switch", "/tmp", { cancel = mare.task.token() }, "bash")
		expect.eq(#drain_reg:list(), 1)
		drain_hooks[1]()
		expect.eq(stop_calls, 1)
		expect.eq(#drain_reg:list(), 0)
		expect.error(function()
			drain_reg:get(rec.id)
		end)

		-- When stop_unconfirmed occurs during session drain, the error propagates to abort the switch.
		stop_res = { stopped = false, stop_unconfirmed = true }
		drain_reg:open("stubborn", "/tmp", { cancel = mare.task.token() }, "bash")
		expect.error(function()
			drain_hooks[1]()
		end, "Terminal stop unconfirmed")
	end)
end)
