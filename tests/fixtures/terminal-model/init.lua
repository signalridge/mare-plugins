-- Deterministic faux provider: each call reads the real prior model-visible tool output.
return {
	name = "terminal-model",
	inject = { "llm" },
	tags = { "provider" },
	apply = function(ctx)
		local turn, id = 0, nil
		local function prior(req, name)
			for i = #req.messages, 1, -1 do
				local m = req.messages[i]
				if m.role == "tool_result" and m.tool_name == name then
					local raw = ""
					for _, block in ipairs(m.content or {}) do
						if block.type == "text" then
							raw = raw .. block.text
						end
					end
					return m, mare.json.decode(raw), raw
				end
			end
		end
		ctx.llm:register_provider({
			provider = "terminal-faux",
			default_model = "flow",
			is_configured = function()
				return true
			end,
			models = { { model_id = "flow", name = "Terminal flow", context_window = 100000, max_output = 4096 } },
			stream = function(req, sink)
				turn = turn + 1
				local name, args
				if turn == 1 then
					name, args = "terminal_open", { name = "model-flow" }
				elseif turn == 2 then
					local m, value = prior(req, "terminal_open")
					assert(m and not m.is_error and value.wait_reason == "prompt")
					id = assert(value.session_id)
					name, args =
						"terminal_send", {
							session_id = id,
							text = "answer=; read -r answer; printf 'REPLY=%s\\n' \"$answer\"",
							wait_ms = 300,
						}
				elseif turn == 3 then
					local m, value, raw = prior(req, "terminal_send")
					if mare.os == "linux" then
						assert(not m.is_error and value.wait_reason == "stdin_read", raw)
					else
						assert(
							not m.is_error
								and (
									value.wait_reason == "stdin_read"
									or value.wait_reason == "wait_elapsed"
									or value.wait_reason == "inferred_idle"
								),
							raw
						)
					end
					name, args = "terminal_send", { session_id = id, text = "from-model", wait_ms = 300 }
				elseif turn == 4 then
					local _, value = prior(req, "terminal_send")
					assert(value.output:find("REPLY=from-model", 1, true))
					name, args =
						"terminal_send", { session_id = id, text = "printf PARTIAL", submit = false, wait_ms = 1500 }
				elseif turn == 5 then
					name, args = "terminal_send", { session_id = id, text = "", wait_ms = 300 }
				elseif turn == 6 then
					local _, value = prior(req, "terminal_send")
					assert(value.output:find("PARTIAL", 1, true))
					name, args = "terminal_send", { session_id = id, text = "sleep 30", run_in_background = true }
				elseif turn == 7 then
					local _, value = prior(req, "terminal_send")
					assert(value.job_id and value.wait_reason == "background")
					mare.task.sleep(100)
					local caps = mare.pty and mare.pty.capabilities and mare.pty.capabilities() or {}
					if caps.foreground_signals then
						name, args = "terminal_signal", { session_id = id, signal = "SIGINT" }
					else
						name, args = "job_kill", { job_id = value.job_id }
					end
				elseif turn == 8 then
					local caps = mare.pty and mare.pty.capabilities and mare.pty.capabilities() or {}
					if caps.foreground_signals then
						local _, value = prior(req, "terminal_signal")
						assert(value.delivered)
					else
						local m = prior(req, "job_kill")
						assert(m and not m.is_error)
					end
					mare.task.sleep(200)
					name, args = "terminal_send", { session_id = id, text = "printf RECOVERED", wait_ms = 300 }
				elseif turn == 9 then
					local m, value = prior(req, "terminal_send")
					assert(not m.is_error and value.output:find("RECOVERED", 1, true))
					name, args = "terminal_read", { session_id = id, offset = 0, count = 500 }
				elseif turn == 10 then
					local _, value = prior(req, "terminal_read")
					assert(value.text:find("REPLY=from-model", 1, true))
					name, args = "terminal_signal", { session_id = "foreign", signal = "SIGINT" }
				elseif turn == 11 then
					local m = prior(req, "terminal_signal")
					assert(m.is_error)
					name, args = "terminal_close", { session_id = id }
				elseif turn == 12 then
					local _, value = prior(req, "terminal_close")
					assert(value.stopped)
					name, args = "terminal_list", {}
				else
					local _, value = prior(req, "terminal_list")
					assert(#value.sessions == 0)
					local report = mare.env("TERMINAL_MODEL_REPORT")
					if report then
						mare.fs.write(report, mare.json.encode({ ok = true, turns = turn }))
					end
					sink({ type = "text_delta", delta = "terminal model flow complete" })
					return {
						role = "assistant",
						content = { { type = "text", text = "terminal model flow complete" } },
						stop_reason = "stop",
					}
				end
				local call_id = "terminal-flow-" .. turn
				sink({ type = "tool_call_start", tool_call_id = call_id, name = name })
				return {
					role = "assistant",
					content = { { type = "tool_call", id = call_id, name = name, arguments = args } },
					stop_reason = "tool_use",
				}
			end,
		})
	end,
}
