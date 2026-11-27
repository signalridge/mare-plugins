return {
	name = "terminal-probe",
	inject = { "tools", "context", "kernel", "task" }, -- session is optional: read with ctx:get("session")
	apply = function(ctx)
		local reload_with_retry = require("terminal_probe.reload")
		local gate_tx, gate_rx = mare.task.channel()
		-- terminals is not a dependency of this fiber: the self-test below reloads "terminals",
		-- which restarts the provider's dependents. Only this
		-- follower depends on it, so the reload re-registers the backends and the test keeps running.
		local terms
		ctx:inject({ "terminals" }, function(sub)
			terms = sub.terminals
			sub.terminals:register("gated", {
				open = function(_, cancel)
					gate_tx:send("entered")
					cancel:wait()
					error("gated backend cancelled", 0)
				end,
			})
			sub.terminals:register("test-backend", {
				open = function(opts)
					opts.cmd = assert(mare.proc.which("bash"))
					opts.args = { "--noprofile", "--norc", "-i" }
					return mare.pty.spawn(opts)
				end,
			})
			sub.terminals:register("delayed", {
				open = function(opts)
					mare.task.sleep(150)
					opts.cmd = assert(mare.proc.which("bash"))
					opts.args = { "--noprofile", "--norc", "-i" }
					return mare.pty.spawn(opts)
				end,
			})
			sub.terminals:register("exits", {
				open = function(opts)
					opts.cmd = assert(mare.proc.which("bash"))
					opts.args = { "--noprofile", "--norc", "-c", "exit 7" }
					return mare.pty.spawn(opts)
				end,
			})
		end)
		ctx:on("app/ready", function()
			local report = mare.env("TERMINAL_PROBE_REPORT")
			if not report or (mare.env("TERMINAL_PROBE_SAVED") == "1" and mare.mode ~= "child") then
				return
			end
			if mare.mode == "child" then
				local child_ok, child_err = pcall(function()
					local opened = ctx.tools:execute({
						id = "child-open-1",
						name = "terminal_open",
						arguments = { name = "shared-name" },
					}, {
						on_state = function()
							return true
						end,
					})
					assert(not opened.is_error, mare.json.encode(opened))
					local sent = ctx.tools:execute({
						id = "child-send-1",
						name = "terminal_send",
						arguments = {
							session_id = opened.details.session_id,
							text = "printf CHILD-OK",
							wait_ms = 500,
						},
					}, {
						on_state = function()
							return true
						end,
					})
					assert(not sent.is_error and sent.details.output:find("CHILD-OK", 1, true), mare.json.encode(sent))
					local closed = ctx.tools:execute({
						id = "child-close-1",
						name = "terminal_close",
						arguments = { session_id = opened.details.session_id },
					}, {
						on_state = function()
							return true
						end,
					})
					assert(not closed.is_error, mare.json.encode(closed))
				end)
				mare.fs.write(
					report .. ".child",
					mare.json.encode({ ok = child_ok, error = not child_ok and tostring(child_err) or nil })
				)
				return
			end
			local ok, err = pcall(function()
				local seq = 0
				local function call(name, args)
					seq = seq + 1
					return ctx.tools:execute({ id = "terminal-probe-" .. seq, name = name, arguments = args }, {
						on_state = function()
							return true
						end,
					})
				end
				local function good(name, args)
					local r = call(name, args)
					assert(not r.is_error, name .. "#" .. seq .. ": " .. mare.json.encode(r))
					return r.details
				end
				assert(ctx.tools:get("terminal_signal"))
				local cached_list, cached_register = terms.list, terms.register
				mare.exec.run(
					{ tool = "inspect", lifetime = "ephemeral-read-only", sandbox = { level = "read-only" } },
					function()
						assert(#cached_list(terms) == 7)
						assert(not pcall(cached_register, terms, "forbidden", {}))
					end
				)
				local prompt = ctx.context:system_prompt()
				assert(prompt:find("A wait timeout returns control", 1, true), prompt)
				if mare.env("TERMINAL_PROBE_POLICY") == "read-only" then
					local opened = call("terminal_open", {})
					if opened.is_error then
						assert(#good("terminal_list", {}).sessions == 0)
					else
						local id = opened.details.session_id
						if mare.os == "windows" then
							good("terminal_send", {
								session_id = id,
								text = "Set-Content -Path terminal-forbidden -Value forbidden",
								wait_ms = 2000,
							})
							assert(not mare.fs.stat(mare.cwd .. "/terminal-forbidden"), "read-only PTY wrote a file")
						else
							good("terminal_send", {
								session_id = id,
								text = "printf forbidden > terminal-forbidden; printf 'WRITE-CODE=%s\\n' \"$?\"",
								wait_ms = 200,
							})
							local page = good("terminal_read", { session_id = id })
							assert(not page.text:find("WRITE-CODE=0", 1, true), page.text)
							assert(not mare.fs.stat(mare.cwd .. "/terminal-forbidden"), "read-only PTY wrote a file")
						end
						good("terminal_close", { session_id = id })
					end
					return
				end
				if mare.os == "windows" and mare.env("TERMINAL_PROBE_POLICY") == "auto" then
					local opened = good("terminal_open", {})
					local id = opened.session_id
					good("terminal_send", {
						session_id = id,
						text = "Set-Content -NoNewline -Path terminal-auto-ok -Value AUTO-OK",
						wait_ms = 2000,
					})
					assert(mare.fs.read(mare.cwd .. "/terminal-auto-ok") == "AUTO-OK")
					mare.fs.remove(mare.cwd .. "/terminal-auto-ok")
					assert(good("terminal_close", { session_id = id }).stopped)
					assert(#good("terminal_list", {}).sessions == 0)
					return
				end
				assert(#terms:list() == 7)
				local retiring = good("terminal_open", { name = "backend-owner", type = "reloadable" })
				good("terminal_send", { session_id = retiring.session_id, text = "sleep 30", run_in_background = true })
				reload_with_retry(ctx.kernel, "terminal-backend-owner")
				local cleanup_deadline = mare.task.clock() + 3000
				while #good("terminal_list", {}).sessions > 0 and mare.task.clock() < cleanup_deadline do
					mare.task.sleep(25)
				end
				assert(
					#good("terminal_list", {}).sessions == 0,
					"backend owner reload failed to stop and remove its terminal"
				)
				assert(call("terminal_send", { session_id = retiring.session_id, text = "echo stale" }).is_error)
				local pending_result
				local pending_open = ctx:spawn(function()
					pending_result = ctx.tools:get("terminal_open").execute(
						{ name = "pending-reload", type = "reloadable" },
						{ cwd = mare.cwd, cancel = mare.task.token() }
					)
				end)
				mare.task.sleep(25)
				reload_with_retry(ctx.kernel, "terminal-backend-owner")
				pending_open:wait()
				assert(
					pending_result.is_error and pending_result.content:find("removed", 1, true),
					mare.json.encode(pending_result)
				)
				assert(#good("terminal_list", {}).sessions == 0, "removed startup backend published a transport")
				local replacement = good("terminal_open", { name = "backend-owner", type = "reloadable" })
				good("terminal_close", { session_id = replacement.session_id })
				local startup_token, startup_result = mare.task.token(), nil
				local startup_task = ctx:spawn(function()
					startup_result = ctx.tools:get("terminal_open").execute(
						{ name = "cancel-startup", type = "delayed" },
						{ cwd = mare.cwd, cancel = startup_token }
					)
				end)
				mare.task.sleep(25)
				startup_token:cancel()
				startup_task:wait()
				assert(
					startup_result.is_error and startup_result.content:find("cancelled", 1, true),
					mare.json.encode(startup_result)
				)
				assert(#good("terminal_list", {}).sessions == 0)
				local after_startup_cancel = good("terminal_open", { name = "cancel-startup" })
				good("terminal_close", { session_id = after_startup_cancel.session_id })
				local opening_result
				local opening = ctx:spawn(function()
					opening_result = ctx.tools:get("terminal_open").execute(
						{ name = "race", type = "delayed" },
						{ cwd = mare.cwd, cancel = mare.task.token() }
					)
				end)
				mare.task.sleep(50)
				local duplicate = ctx.tools
					:get("terminal_open")
					.execute({ name = "race", type = "delayed" }, { cwd = mare.cwd, cancel = mare.task.token() })
				assert(duplicate.is_error, "concurrent name reservation was bypassed")
				opening:wait()
				assert(not opening_result.is_error, mare.json.encode(opening_result))
				good("terminal_close", { session_id = opening_result.details.session_id })
				assert(call("terminal_open", { name = "startup", type = "exits" }).is_error)
				assert(#good("terminal_list", {}).sessions == 0, "startup failure left a published terminal")
				local retry = good("terminal_open", { name = "startup" })
				good("terminal_close", { session_id = retry.session_id })
				assert(call("terminal_open", { type = "unknown-backend" }).is_error)
				local opened = good("terminal_open", { name = "interactive", type = "test-backend" })
				assert(opened.type == "test-backend")
				local id = assert(opened.session_id)
				assert(opened.wait_reason == "prompt" and opened.status == "running")
				local denied = call("terminal_open", { name = "interactive" })
				assert(denied.is_error, "duplicate name accepted")
				local r = good("terminal_send", {
					session_id = id,
					text = "test -t 0 && printf 'TTY-OK\\n'; read -r answer; printf 'answer=%s\\n' \"$answer\"",
					wait_ms = 150,
				})
				assert(
					(r.wait_reason == "wait_elapsed" or r.wait_reason == "stdin_read") and r.status == "running",
					mare.json.encode(r)
				)
				r = good("terminal_send", { session_id = id, text = "hello-world", wait_ms = 200 })
				local page = good("terminal_read", { session_id = id, count = 200 })
				assert(page.text:find("TTY-OK", 1, true) and page.text:find("answer=hello-world", 1, true), page.text)
				good(
					"terminal_send",
					{ session_id = id, text = "printf 'safe\\033]52;c;secret\\007tail\\n'", wait_ms = 100 }
				)
				page = good("terminal_read", { session_id = id })
				assert(page.text:find("safetail", 1, true) and not page.text:find("\27", 1, true), page.text)
				local full = call("terminal_send", { session_id = id, text = string.rep("x", 16385), wait_ms = 0 })
				assert(full.is_error, "oversized input accepted")
				local listed = good("terminal_list", {})
				assert(#listed.sessions == 1)
				assert(call("terminal_read", { session_id = "foreign" }).is_error)
				assert(call("terminal_signal", { session_id = "foreign", signal = "SIGINT" }).is_error)
				assert(call("terminal_signal", { session_id = id, signal = "SIGUSR1" }).is_error)
				assert(
					call("terminal_signal", { session_id = id, signal = "SIGKILL" }).is_error,
					"shell SIGKILL accepted"
				)
				local function send_after_signal(session_id, text, wait_ms)
					local deadline = mare.task.clock() + 3000
					while true do
						local res = call("terminal_send", { session_id = session_id, text = text, wait_ms = wait_ms })
						if not res.is_error then
							return res.details
						end
						assert(
							res.content:find("Terminal busy, closing or exited", 1, true)
								and mare.task.clock() < deadline,
							"terminal_send#" .. seq .. ": " .. mare.json.encode(res)
						)
						mare.task.sleep(25)
					end
				end
				if
					mare.env("TERMINAL_PROBE_POLICY") == "auto"
					and opened.screen
					and opened.screen:find("no job control", 1, true)
				then
					good(
						"terminal_send",
						{ session_id = id, text = "printf AUTO-OK > terminal-auto-ok", wait_ms = 200 }
					)
					assert(mare.fs.read(mare.cwd .. "/terminal-auto-ok") == "AUTO-OK")
					mare.fs.remove(mare.cwd .. "/terminal-auto-ok")
					assert(good("terminal_close", { session_id = id }).stopped)
					assert(#good("terminal_list", {}).sessions == 0)
					return
				end
				local caps = mare.pty and mare.pty.capabilities and mare.pty.capabilities() or {}
				if caps.foreground_signals then
					good("terminal_send", { session_id = id, text = "sleep 30", wait_ms = 100 })
					local delivered = good("terminal_signal", { session_id = id, signal = "SIGINT" })
					assert(delivered.delivered and delivered.target_pgid > 0)
					send_after_signal(id, "printf signal-recovered", 100)
					assert(good("terminal_read", { session_id = id }).text:find("signal-recovered", 1, true))
					local signal_token = mare.task.token()
					signal_token:cancel()
					local cancelled_signal = ctx.tools
						:get("terminal_signal")
						.execute({ session_id = id, signal = "SIGINT" }, { cancel = signal_token })
					assert(cancelled_signal.is_error and cancelled_signal.content:find("cancelled", 1, true))
				else
					local unsupported = call("terminal_signal", { session_id = id, signal = "SIGINT" })
					assert(
						unsupported.is_error and unsupported.content:find("PTY_SIGNAL_UNSUPPORTED", 1, true),
						mare.json.encode(unsupported)
					)
				end
				local closed = good("terminal_close", { session_id = id })
				assert(closed.stopped and not closed.stop_unconfirmed)
				assert(good("terminal_close", { session_id = id }).already_closed)
				assert(#good("terminal_list", {}).sessions == 0)
				if caps.foreground_signals then
					for _, signal in ipairs({ "SIGTERM", "SIGKILL", "SIGTSTP", "SIGHUP" }) do
						local target = good("terminal_open", { name = "foreground-" .. signal })
						local sent_fg = good(
							"terminal_send",
							{ session_id = target.session_id, text = "printf 'FG_READY\\n'; sleep 30", wait_ms = 200 }
						)
						local fg_deadline = mare.task.clock() + 2000
						local fg_out = sent_fg.output or ""
						while not fg_out:find("FG_READY", 1, true) and mare.task.clock() < fg_deadline do
							mare.task.sleep(50)
							fg_out = good("terminal_read", { session_id = target.session_id }).text or ""
						end
						assert(fg_out:find("FG_READY", 1, true), "foreground sleep command did not start: " .. fg_out)
						mare.task.sleep(50)
						local sent = good("terminal_signal", { session_id = target.session_id, signal = signal })
						assert(sent.delivered and sent.target_pgid > 0)
						local usable = send_after_signal(target.session_id, "printf SIGNAL-SHELL-ALIVE", 300)
						assert(usable.output:find("SIGNAL-SHELL-ALIVE", 1, true), mare.json.encode(usable))
						assert(good("terminal_close", { session_id = target.session_id }).stopped)
					end
				end
				if mare.fs.stat(mare.cwd .. "/ignore-started") then
					mare.fs.remove(mare.cwd .. "/ignore-started")
				end
				local ignored = good("terminal_open", { name = "ignore-int" })
				local ignore_token, ignore_result = mare.task.token(), nil
				local ignoring = ctx:spawn(function()
					ignore_result = ctx.tools:get("terminal_send").execute({
						session_id = ignored.session_id,
						text = [[bash -c 'trap "" INT; printf ready > ignore-started; sleep 30']],
						wait_ms = 600,
					}, { cancel = ignore_token })
				end)
				local ready_deadline = mare.task.clock() + 1000
				while not mare.fs.stat(mare.cwd .. "/ignore-started") and mare.task.clock() < ready_deadline do
					mare.task.sleep(10)
				end
				assert(mare.fs.stat(mare.cwd .. "/ignore-started"), "ignoring child did not start")
				ignore_token:cancel()
				ignoring:wait()
				assert(
					ignore_result.is_error and ignore_result.content:find("draining", 1, true),
					mare.json.encode(ignore_result)
				)
				assert(call("terminal_send", { session_id = ignored.session_id, text = "echo busy" }).is_error)
				assert(good("terminal_close", { session_id = ignored.session_id }).stopped)
				local cancelled = good("terminal_open", { name = "cancelled" })
				local token = mare.task.token()
				token:cancel()
				local cancellation = ctx.tools:get("terminal_send").execute(
					{ session_id = cancelled.session_id, text = "echo forbidden" },
					{ cancel = token }
				)
				assert(cancellation.is_error and cancellation.content:find("cancelled", 1, true))
				assert(#good("terminal_list", {}).sessions == 1)
				good("terminal_close", { session_id = cancelled.session_id })
				local active = good("terminal_open", { name = "active-cancel" })
				local active_token = mare.task.token()
				local interrupted
				local sending = ctx:spawn(function()
					interrupted = ctx.tools:get("terminal_send").execute(
						{ session_id = active.session_id, text = "sleep 30", wait_ms = 5000 },
						{ cancel = active_token }
					)
				end)
				mare.task.sleep(200)
				active_token:cancel()
				sending:wait()
				assert(
					interrupted.is_error and interrupted.content:find("cancelled", 1, true),
					mare.json.encode(interrupted)
				)
				local recovered = good(
					"terminal_send",
					{ session_id = active.session_id, text = "printf CANCEL-RECOVERED", wait_ms = 300 }
				)
				assert(recovered.output:find("CANCEL-RECOVERED", 1, true))
				good("terminal_close", { session_id = active.session_id })
				local next = good("terminal_open", { name = "next" })
				local background = good(
					"terminal_send",
					{ session_id = next.session_id, text = "sleep .2; printf BG-DONE", run_in_background = true }
				)
				assert(background.job_id, "terminal send must create a job")
				local output = call("job_output", { job_id = background.job_id, wait = true, timeout_ms = 2000 })
				assert(not output.is_error and output.content:find("BG-DONE", 1, true), mare.json.encode(output))
				assert(
					not output.content:find("status: running", 1, true),
					"send job incorrectly follows shell lifetime"
				)
				local killed =
					good("terminal_send", { session_id = next.session_id, text = "sleep 30", run_in_background = true })
				mare.task.sleep(100)
				assert(not call("job_kill", { job_id = killed.job_id }).is_error)
				local stopped = call("job_output", { job_id = killed.job_id, wait = true, timeout_ms = 2000 })
				assert(
					not stopped.is_error and not stopped.content:find("status: running", 1, true),
					mare.json.encode(stopped)
				)
				good("terminal_send", { session_id = next.session_id, text = "printf JOB-RECOVERED", wait_ms = 300 })
				good("terminal_close", { session_id = next.session_id })

				-- Real ctx.tools:execute pipeline cancellation & recovery (open, normal send, ignoring-SIGINT send)
				do
					local open_tok = mare.task.token()
					local open_res
					local open_task = ctx:spawn(function()
						open_res = ctx.tools:execute({
							id = "pipe-open-1",
							name = "terminal_open",
							arguments = { name = "pipe-open", type = "gated" },
						}, {
							cancel = open_tok,
							on_state = function()
								return true
							end,
						})
					end)
					assert(gate_rx:recv() == "entered")
					open_tok:cancel()
					open_task:wait()
					assert(open_res.is_error and open_res.cancelled, mare.json.encode(open_res))
					assert(#good("terminal_list", {}).sessions == 0)

					local pipe_term = good("terminal_open", { name = "pipe-cancel" })
					local ready_tx, ready_rx = mare.task.channel()
					local ready_sent = false
					local send_tok = mare.task.token()
					local send_res
					local send_task = ctx:spawn(function()
						send_res = ctx.tools:execute({
							id = "pipe-send-1",
							name = "terminal_send",
							arguments = {
								session_id = pipe_term.session_id,
								text = "printf 'PIPE-%s\\n' 'READY'; cat",
								wait_ms = 5000,
							},
						}, {
							cancel = send_tok,
							on_state = function()
								return true
							end,
							on_update = function(partial)
								if
									not ready_sent
									and partial.details
									and partial.details.output
									and partial.details.output:find("PIPE-READY", 1, true)
								then
									ready_sent = true
									ready_tx:send(true)
								end
							end,
						})
					end)
					assert(ready_rx:recv())
					send_tok:cancel()
					send_task:wait()
					assert(send_res.is_error and send_res.cancelled, mare.json.encode(send_res))
					local after_pipe = good(
						"terminal_send",
						{ session_id = pipe_term.session_id, text = "printf PIPE-RECOVERED", wait_ms = 500 }
					)
					assert(after_pipe.output:find("PIPE-RECOVERED", 1, true), mare.json.encode(after_pipe))
					good("terminal_close", { session_id = pipe_term.session_id })

					local ign_term = good("terminal_open", { name = "pipe-ignore" })
					local ign_tx, ign_rx = mare.task.channel()
					local ign_sent = false
					local ign_tok = mare.task.token()
					local ign_res
					local ign_task = ctx:spawn(function()
						ign_res = ctx.tools:execute({
							id = "pipe-ign-1",
							name = "terminal_send",
							arguments = {
								session_id = ign_term.session_id,
								text = [[bash -c 'trap "" INT; printf "IGN-%s\n" "READY"; read -r _unused']],
								wait_ms = 5000,
							},
						}, {
							cancel = ign_tok,
							on_state = function()
								return true
							end,
							on_update = function(partial)
								if
									not ign_sent
									and partial.details
									and partial.details.output
									and partial.details.output:find("IGN-READY", 1, true)
								then
									ign_sent = true
									ign_tx:send(true)
								end
							end,
						})
					end)
					assert(ign_rx:recv())
					ign_tok:cancel()
					ign_task:wait()
					assert(ign_res.is_error and ign_res.cancelled, mare.json.encode(ign_res))
					assert(call("terminal_send", { session_id = ign_term.session_id, text = "echo busy" }).is_error)
					assert(good("terminal_close", { session_id = ign_term.session_id }).stopped)
				end

				-- Empty-input poll after wait_elapsed + handoff/fragmented prompt race
				do
					local poll_term = good("terminal_open", { name = "empty-poll" })
					local first = good("terminal_send", {
						session_id = poll_term.session_id,
						text = "sleep 0.25; printf 'POLL-DONE\\n'",
						wait_ms = 50,
					})
					assert(first.wait_reason == "wait_elapsed", mare.json.encode(first))
					local polled = good(
						"terminal_send",
						{ session_id = poll_term.session_id, text = "", submit = false, wait_ms = 3000 }
					)
					assert(
						polled.wait_reason == "prompt" and polled.output:find("POLL-DONE", 1, true),
						mare.json.encode(polled)
					)

					-- Child prints forged OSC 133;D + mare> while still holding foreground; must not settle prematurely.
					-- Requires foreground pgid inspection (caps.foreground); ConPTY cannot distinguish a forged prompt from the shell.
					if caps.foreground then
						local handoff = good("terminal_send", {
							session_id = poll_term.session_id,
							text = [[bash -c 'printf "\033]133;D;0\007mare> "; sleep 0.25; printf "HANDOFF-%s\n" "OK"']],
							wait_ms = 3000,
						})
						-- the child waits on stdin, so stdin_read is a valid settle; the forged prompt must never settle it as "prompt" early
						assert(
							handoff.wait_reason ~= "prompt" or handoff.output:find("HANDOFF-OK", 1, true),
							mare.json.encode(handoff)
						)
						local handoff_out = handoff.output
						if handoff.wait_reason ~= "prompt" then
							local rest = good(
								"terminal_send",
								{ session_id = poll_term.session_id, text = "", submit = false, wait_ms = 3000 }
							)
							assert(rest.wait_reason == "prompt", mare.json.encode(rest))
							handoff_out = handoff_out .. rest.output
						end
						assert(handoff_out:find("HANDOFF-OK", 1, true), handoff_out)
					end

					-- Fragmented OSC 133 + split "ma" / "re> " prompt tail
					local frag = good("terminal_send", {
						session_id = poll_term.session_id,
						text = [[bash -c 'printf "\033]133;"; sleep 0.05; printf "D;0\007ma"; sleep 0.05; printf "re> "; printf "FRAG-OK\n"']],
						wait_ms = 3000,
					})
					assert(
						frag.wait_reason == "prompt" and frag.output:find("FRAG-OK", 1, true),
						mare.json.encode(frag)
					)
					good("terminal_close", { session_id = poll_term.session_id })
				end

				-- Python3 interactive REPL matrix (when python3 is present)
				if mare.proc.which("python3") then
					local py = good("terminal_open", { name = "python-repl" })
					local py_start = good("terminal_send", {
						session_id = py.session_id,
						text = "python3 -i -q -c 'print(\"PY-UP\")'",
						wait_ms = 2000,
					})
					assert(py_start.output:find("PY-UP", 1, true), mare.json.encode(py_start))
					local py_expr = good("terminal_send", {
						session_id = py.session_id,
						text = "print(6 * 7)",
						wait_ms = 1000,
					})
					assert(py_expr.output:find("42", 1, true), mare.json.encode(py_expr))
					local py_exit = good("terminal_send", {
						session_id = py.session_id,
						text = "raise SystemExit(0)",
						wait_ms = 2000,
					})
					assert(py_exit.wait_reason == "prompt", mare.json.encode(py_exit))
					good("terminal_close", { session_id = py.session_id })
				end

				-- PTY_POLICY_BUSY fence and terminal self-reload (ctx.kernel:reload("terminals"))
				do
					local fence_term = good("terminal_open", { name = "fence-check" })
					if ctx:get("session") and ctx:get("session").set_sandbox_mode then
						local sw_ok, sw_err =
							pcall(ctx:get("session").set_sandbox_mode, ctx:get("session"), { level = "read-only" })
						assert(not sw_ok and tostring(sw_err):find("PTY_POLICY_BUSY", 1, true), tostring(sw_err))
					end
					good(
						"terminal_send",
						{ session_id = fence_term.session_id, text = "sleep 30", run_in_background = true }
					)
					reload_with_retry(ctx.kernel, "terminals")
					assert(#good("terminal_list", {}).sessions == 0, "terminal reload left stale sessions")
					assert(call("terminal_send", { session_id = fence_term.session_id, text = "echo stale" }).is_error)
					local post_reload = good("terminal_open", { name = "post-reload" })
					local post_send = good(
						"terminal_send",
						{ session_id = post_reload.session_id, text = "printf RELOAD-OK", wait_ms = 500 }
					)
					assert(post_send.output:find("RELOAD-OK", 1, true))
					good("terminal_close", { session_id = post_reload.session_id })
				end
			end)
			mare.fs.write(report, mare.json.encode({ ok = ok, error = not ok and tostring(err) or nil }))
		end)
		if mare.env("TERMINAL_PROBE_SAVED") == "1" and mare.mode ~= "child" and ctx:get("session") then
			local ran_saved = false
			ctx:on("agent/settled", function(ev)
				if ran_saved or (ev and ev.busy) then
					return
				end
				ran_saved = true
				local report = mare.env("TERMINAL_PROBE_REPORT")
				if not report then
					return
				end
				local ok, err = pcall(function()
					local seq = 0
					local function persist_state(c, state, info)
						local sess = ctx:get("session")
						if sess and sess.record_tool_state then
							return sess:record_tool_state({
								tool_call_id = c.id,
								name = c.name,
								state = state,
								side_effect = info and info.side_effect or nil,
								idempotent = info and info.idempotent or nil,
							})
						end
						return true
					end
					local function call(name, args)
						seq = seq + 1
						return ctx.tools:execute({ id = "terminal-saved-" .. seq, name = name, arguments = args }, {
							on_state = persist_state,
						})
					end
					local function good(name, args)
						local r = call(name, args)
						assert(not r.is_error, name .. "#" .. seq .. ": " .. mare.json.encode(r))
						return r.details
					end

					-- Real child subagent VM isolation & cleanup
					local parent_term = good("terminal_open", { name = "shared-name" })
					local child = mare.subagent.start({
						prompt = "Run terminal probe child",
					})
					local child_res = child:wait()
					assert(not child_res.error, tostring(child_res.error))
					local child_report = mare.json.decode(assert(mare.fs.read(report .. ".child")))
					assert(child_report.ok, tostring(child_report.error))
					-- Parent's same-named session is untouched; child's session is isolated/cleaned up
					local parent_list = good("terminal_list", {})
					assert(#parent_list.sessions == 1 and parent_list.sessions[1].session_id == parent_term.session_id)
					local parent_ok = good(
						"terminal_send",
						{ session_id = parent_term.session_id, text = "printf PARENT-INTACT", wait_ms = 500 }
					)
					assert(parent_ok.output:find("PARENT-INTACT", 1, true))

					-- session:fork() triggers session/changed and closes parent_term
					local sess = ctx:get("session")
					sess:fork({ session_id = sess:info().session_id })
					assert(#good("terminal_list", {}).sessions == 0, "session:fork did not clean up terminals")
					assert(call("terminal_send", { session_id = parent_term.session_id, text = "echo stale" }).is_error)

					-- session:create() triggers session/changed and closes pre_new
					local pre_new = good("terminal_open", { name = "pre-session-new" })
					assert(pre_new.pid and pre_new.pid > 0)
					sess:create({})
					assert(#good("terminal_list", {}).sessions == 0, "session:new did not clean up terminals")
					assert(call("terminal_send", { session_id = pre_new.session_id, text = "echo stale" }).is_error)

					-- session:load() to a session with a different sandbox drains open PTYs before
					-- applying the target session's sandbox policy (no spurious PTY_POLICY_BUSY).
					if sess.set_sandbox_mode and sess.load then
						local ro_id = sess:info().session_id
						sess:set_sandbox_mode({ level = "read-only" })
						sess:create({})
						local pre_switch = good("terminal_open", { name = "pre-sandbox-switch" })
						assert(pre_switch.pid and pre_switch.pid > 0)
						sess:load({ session_id = ro_id })
						assert(#good("terminal_list", {}).sessions == 0, "session:load did not drain terminals")
						assert(
							call("terminal_send", { session_id = pre_switch.session_id, text = "echo stale" }).is_error
						)
					end
				end)
				mare.fs.write(report, mare.json.encode({ ok = ok, error = not ok and tostring(err) or nil }))
			end)
		end
	end,
}
