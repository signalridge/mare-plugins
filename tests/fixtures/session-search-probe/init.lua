return {
	name = "session-search-probe",
	inject = { "tools", "session", "commands", "query", "agent", "kernel" },
	apply = function(ctx)
		local state_path = mare.env("HISTORY_UI_STATE")
		if state_path then
			for _, event in ipairs({
				"ui/wait-started",
				"ui/wait-completed",
				"kernel/error",
				"input/submit",
				"session/changed",
			}) do
				ctx:on(event, function(value)
					local old = mare.fs.read(state_path .. ".events") or ""
					pcall(
						mare.fs.write,
						state_path .. ".events",
						old .. mare.json.encode({ event = event, value = value }) .. "\n"
					)
				end)
			end
		end

		local slow_started = false
		local remove = ctx.query:register("contract-provider", {
			priority = 20,
			source = { capability = "in_process" },
			operations = {
				["contract.echo"] = function(args)
					return { value = args.value, next_cursor = args.first and "next" or nil }
				end,
				["contract.slow"] = function(_, opts)
					slow_started = true
					mare.task.sleep(60000, opts.cancel)
					return {}
				end,
				["contract.status"] = function()
					return { started = slow_started }
				end,
			},
		})
		local opaque_called = false
		ctx.query:register("contract-opaque", {
			source = { capability = "opaque" },
			operations = {
				["contract.opaque"] = function()
					opaque_called = true
					return {}
				end,
			},
		})
		ctx.query:register("contract-local", {
			source = { capability = "in_process" },
			operations = {
				["contract.opaque-status"] = function()
					return { called = opaque_called }
				end,
				["contract.unregister"] = function()
					remove()
					return {}
				end,
				["contract.write"] = function(args)
					return { value = mare.fs.write(args.path, "forbidden") }
				end,
				["contract.process"] = function(args)
					return mare.proc.run({
						cmd = "sh",
						args = { "-c", 'printf forbidden > "$1"', "inspection", args.path },
					})
				end,
				["contract.network"] = function(args)
					return mare.http.request({ url = args.url })
				end,
			},
		})
		local capture = assert(mare.env("HISTORY_CAPTURE"))
		ctx:on("request/build", function(req, ev)
			local old = mare.fs.read(capture) or ""
			assert(mare.fs.write(capture, old .. mare.json.encode({
				system = req.system,
				tools = req.tools,
				messages = req.messages,
				mode = mare.mode,
				caller_id = ctx.agent:activity().session_id,
				session = ctx.session:info(),
			}) .. "\n"))
			return ev.next(req)
		end)
		ctx.commands:register("history-state", {
			run = function()
				local available, why = ctx.session:available()
				assert(mare.fs.write(
					assert(mare.env("HISTORY_UI_STATE")),
					mare.json.encode({
						mode = mare.mode,
						session = ctx.session:info(),
						available = available,
						why = why,
						busy = (ctx.agent:get() or {}).busy == true,
						ui_connected = mare.ui.connected(),
						restore_short = mare.env("HISTORY_RESTORE_ID") and ctx.session:short_id(
							mare.env("HISTORY_RESTORE_ID")
						) or nil,
						problems = ctx.kernel:problems(),
					})
				))
			end,
		})
		ctx.commands:register("query-unregister", {
			run = function()
				remove()
			end,
		})
		local ok_echo, echo_res = pcall(ctx.query.call, ctx.query, "contract.echo", { value = "host" })
		assert(
			ok_echo and echo_res and echo_res.value == "host",
			"query.call should enter its own read-only sandbox from host context"
		)
		local allowed_mut, mut_err = pcall(ctx.query.call, ctx.query, "contract.unregister", {})
		assert(
			not allowed_mut and tostring(mut_err):find("ephemeral-read-only", 1, true),
			"query borrowed unrestricted host context"
		)
		ctx.commands:register("history-child", {
			run = function()
				local child = mare.subagent.start({
					prompt = "Inspect historical evidence",
					model = "faux/echo",
					tools = { "session_event_search" },
					run_id = "query-caller",
					label = "history-caller",
					child_session_id = "forged-child",
					parent_session_id = "forged-parent",
					parent_session_epoch = "forged-epoch",
				})
				-- what the parent itself observes of the child: the host-issued transcript identity
				local info = assert(mare.subagent.get(child:subagent_id()), "spawned child not listed")
				local result = child:wait()
				result.parent_observed = {
					child_session_id = info.subagent_id,
					binding = mare.subagent.identity(info.subagent_id),
				}
				assert(mare.fs.write(assert(mare.env("HISTORY_CHILD_REPORT")), mare.json.encode(result)))
			end,
		})
		ctx.commands:register("history-deny-file", {
			run = function()
				ctx.session:set_sandbox_mode({
					level = "read-only",
					network = true,
					deny_read = { assert(mare.env("HISTORY_SEED_PATH")) },
					accept_partial = { "fs_deny_read" },
				})
			end,
		})
		ctx.commands:register("history-deny-children", {
			run = function()
				ctx.session:set_sandbox_mode({
					level = "read-only",
					network = true,
					deny_read = { ctx.session:info().children_dir .. "/agents" },
					accept_partial = { "fs_deny_read" },
				})
			end,
		})
		ctx.commands:register("history-deny-current", {
			run = function()
				ctx.session:set_sandbox_mode({
					level = "read-only",
					network = true,
					deny_read = { assert(ctx.session:info().path) },
					accept_partial = { "fs_deny_read" },
				})
			end,
		})
		ctx.commands:register("history-full", {
			run = function()
				ctx.session:set_sandbox_mode({ level = "danger-full-access", network = true })
			end,
		})
		ctx.commands:register("history-deny", {
			description = "Test history RPC policy",
			run = function()
				ctx.session:set_sandbox_mode({
					level = "read-only",
					network = true,
					deny_read = { mare.store.root },
					accept_partial = { "fs_deny_read" },
				})
			end,
		})
		ctx.tools:register("history_probe", {
			description = "Verify public generation-bound history",
			side_effect = "read",
			idempotent = true,
			parameters = { type = "object", properties = {} },
			execute = function()
				local args = {
					query = "secret needle",
					filters = { exclude_session_id = ctx.session:info().session_id, archived = false },
				}
				local q = mare.store.search_sessions(args)
				assert(#q.data == 1 and q.data[1].session_id == "history-one", mare.json.encode(q))
				local r = mare.store.read_event({ event_id = q.data[1].event_id, before = 1, after = 1 })
				assert(r.event.message.content[1].text == "secret needle 世界")
				local events = mare.store.search_events({ session_id = "history-one", query = "secret needle" })
				assert(#events.data == 20 and events.next_cursor)
				local next_page = mare.store.search_events({
					session_id = "history-one",
					query = "secret needle",
					cursor = events.next_cursor,
				})
				assert(#next_page.data == 20 and next_page.next_cursor)
				assert(q.data[1].position.seq == 125 and q.data[1].position.text_offset == 0)
				local ok, err = pcall(mare.store.search_events, { session_id = "hidden", query = "needle" })
				assert(not ok and tostring(err):find("session unavailable in this workspace", 1, true))
				local keys = mare.store.search_sessions({ query = "tool_only_needle" })
				assert(#keys.data == 0)
				local denied = mare.exec.run({
					cwd = mare.cwd,
					sandbox = {
						level = "read-only",
						network = true,
						deny_read = { mare.store.root },
						accept_partial = { "fs_deny_read" },
					},
				}, function()
					local allowed, why = pcall(mare.store.search_sessions, { query = "secret needle" })
					return not allowed and tostring(why):find("sandbox", 1, true) ~= nil
				end)
				assert(denied, "history directory policy bypassed")
				local file_denied = mare.exec.run({
					cwd = mare.cwd,
					sandbox = {
						level = "read-only",
						network = true,
						deny_read = { assert(os.getenv("HISTORY_SEED_PATH")) },
						accept_partial = { "fs_deny_read" },
					},
				}, function()
					local result =
						mare.store.search_sessions({ query = "secret needle", filters = { archived = false } })
					local readable = pcall(mare.store.search_events, { session_id = "history-one", query = "needle" })
					return #result.data == 0 and not readable
				end)
				assert(file_denied, "per-file denied metadata escaped")
				return { content = "history-probe-passed EVENT:" .. q.data[1].event_id }
			end,
		})
	end,
}
