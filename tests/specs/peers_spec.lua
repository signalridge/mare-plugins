local support = assert(load(mare.fs.read("tests/specs/support.lua"), "@tests/specs/support.lua"))()

local describe = mare.test.describe
local it = mare.test.it
local before_each = mare.test.before_each
local after_each = mare.test.after_each
local expect = mare.test.expect

local plugin = support.load_plugin("peers", { "peers.ui" })

describe("peers", function()
	local tools, commands, entries
	local orig_peers, orig_peers_list, orig_peers_connect
	local orig_notify, orig_select, orig_input

	local cleanups, listeners
	local function mount()
		tools, commands, cleanups, listeners = {}, {}, {}, {}
		plugin.apply({
			-- the client registry's cleanup (unload) and its session/changed listener
			effect = function(_, setup)
				cleanups[#cleanups + 1] = setup()
			end,
			on = function(_, event, fn)
				listeners[event] = fn
			end,
			tools = {
				register = function(_, name, def)
					tools[name] = def
				end,
			},
			commands = {
				register = function(_, name, def)
					commands[name] = def
				end,
			},
		})
	end

	before_each(function()
		entries = {}
		orig_peers = mare.peers
		orig_peers_list = orig_peers and orig_peers.list or nil
		orig_peers_connect = orig_peers and orig_peers.connect or nil
		if type(mare.peers) ~= "table" then
			mare.peers = {}
		end
		mare.peers.list = function()
			return entries
		end
		mare.peers.connect = nil

		orig_notify = mare.ui.notify
		orig_select = mare.ui.select
		orig_input = mare.ui.input
	end)

	after_each(function()
		if orig_peers == nil then
			mare.peers = nil
		else
			mare.peers = orig_peers
			mare.peers.list = orig_peers_list
			mare.peers.connect = orig_peers_connect
		end
		mare.ui.notify = orig_notify
		mare.ui.select = orig_select
		mare.ui.input = orig_input
	end)

	it("fails closed when mare.peers.connect is absent", function()
		mount()
		expect.eq(tools.peer_list.side_effect, "read")
		expect.truthy(tools.peer_list.idempotent)
		expect.eq(tools.peer_send.side_effect, "external")
		expect.eq(tools.peer_send.idempotent, false)
		expect.eq(tools.peer_send.parameters.additionalProperties, false)
		expect.eq(tools.peer_status.side_effect, "read")
		expect.truthy(tools.peer_status.idempotent)
		expect.truthy(commands.peers)

		expect.eq(#tools.peer_list.execute().details.peers, 0)
		entries = {
			{ name = "self", pid = mare.pid, cwd = "/work/self" },
			{
				name = "other",
				pid = mare.pid + 1,
				cwd = "/work/other",
				started_at_ms = 100,
				status = { state = "idle" },
			},
			{
				name = "third",
				pid = mare.pid + 2,
				cwd = "/other/proj",
				started_at_ms = 200,
				status = { state = "working" },
			},
		}
		local listed = tools.peer_list.execute().details
		expect.truthy(listed.snapshot)
		expect.eq(listed.sending_available, false)
		expect.eq(#listed.peers, 2)
		expect.eq(listed.peers[1].name, "other")
		expect.eq(listed.peers[1].started_at_ms, 100)
		expect.eq(#tools.peer_list.execute({ name = "third" }).details.peers, 1)
		expect.eq(#tools.peer_list.execute({ cwd = "/work" }).details.peers, 1)
		expect.eq(#tools.peer_list.execute({ cwd = "/wor" }).details.peers, 0)

		entries[2].plugins = { session = { session_id = "s", name = "title" }, status = { held = 3 } }
		listed = tools.peer_list.execute({ name = "other" }).details
		expect.eq(listed.peers[1].held, 3)
		expect.eq(listed.peers[1].session.name, "title")

		entries[2].plugins = { session = { session_id = false }, status = { held = -1 } }
		listed = tools.peer_list.execute({ name = "other" }).details
		expect.eq(listed.peers[1].held, nil)
		expect.eq(listed.peers[1].session, nil)

		for _, args in ipairs({ {}, { to = "other", message = "hello" }, { to = "self", message = "hello" } }) do
			local result = tools.peer_send.execute(args)
			expect.truthy(result.is_error)
			expect.match(result.content, "unavailable")
			expect.match(result.content, "PEERS%-3")
			expect.match(result.content, "No message was sent")
		end

		local gated_status = tools.peer_status.execute({ to = "other" })
		expect.truthy(gated_status.is_error)
		expect.match(gated_status.content, "PEERS%-3")

		local gated_notices = {}
		mare.ui.notify = function(msg, level)
			gated_notices[#gated_notices + 1] = { msg = msg, level = level }
		end
		mare.ui.select = function()
			return 1
		end
		commands.peers.run("")
		expect.eq(#gated_notices, 1)
		expect.match(gated_notices[1].msg, "PEERS%-3")
	end)

	it(
		"validates, sends, checks status, handles /peers UI, and respects cancellation when connect is present",
		function()
			entries = {
				{ name = "self", pid = mare.pid, cwd = "/work/self" },
				{
					name = "other",
					pid = mare.pid + 1,
					cwd = "/work/other",
					started_at_ms = 100,
					status = { state = "idle" },
				},
				{
					name = "third",
					pid = mare.pid + 2,
					cwd = "/other/proj",
					started_at_ms = 200,
					status = { state = "working" },
				},
			}

			local calls = {}
			local mock_client = {
				closed = false,
				info = function()
					return {
						name = "other",
						pid = mare.pid + 1,
						allowed = {
							"peer.info",
							"status.get",
							"peer.message",
							"events.subscribe",
						},
						delivery_modes = { "trigger_turn", "queue_only" },
					}
				end,
				status = function()
					return { state = "idle" }
				end,
				send = function(_, msg)
					calls.last_send = msg
					if msg.text == "unknown_err" then
						return nil, { code = "outcome_unknown", message = "lost after write" }
					end
					return { message_id = "msg-1", status = "held" }
				end,
				wait_message = function(_, id)
					calls.last_wait = id
					return {
						message_id = id,
						status = "delivered",
					}
				end,
				wait_idle = function(_, opts)
					calls.last_idle = opts
					return { state = "idle" }
				end,
				close = function(self)
					self.closed = true
				end,
			}

			mare.peers.connect = function(target, opts) -- the caller owns the client (no ctx argument)
				calls.last_target = target
				calls.last_connect_opts = opts
				mock_client.closed = false
				return mock_client
			end

			mount()
			expect.eq(tools.peer_list.execute().details.sending_available, true)

			-- Validation checks fail before connect
			expect.truthy(tools.peer_send.execute({ to = "other", message = "   " }).is_error)
			expect.truthy(tools.peer_send.execute({ to = "other", message = "hi", extra = 1 }).is_error)
			expect.truthy(tools.peer_send.execute({ to = "other", message = "hi", pid = mare.pid + 1 }).is_error)
			expect.truthy(
				tools.peer_send.execute({ to = "self", message = "hi", pid = mare.pid, started_at_ms = 10 }).is_error
			)
			expect.truthy(tools.peer_send.execute({ to = "other", message = string.rep("a", 1048576) }).is_error)
			expect.truthy(tools.peer_send.execute({ to = "other", message = "hi", delivery = "bad" }).is_error)
			expect.truthy(tools.peer_status.execute({ to = "other", current_or_next = false }).is_error)
			expect.truthy(tools.peer_status.execute({ to = "other", wait_idle = true, timeout_ms = -1 }).is_error)
			expect.truthy(tools.peer_status.execute({ to = "other", wait_idle = true, timeout_ms = 3600001 }).is_error)
			expect.truthy(tools.peer_send.execute({ to = "other", message = "hi", notify_when_idle = true }).is_error)
			expect.eq(calls.last_target, nil)

			-- queue_only + wait=true
			local sent = tools.peer_send.execute({
				to = "other",
				pid = mare.pid + 1,
				started_at_ms = 100,
				message = "queued hello",
				delivery = "queue_only",
			})
			expect.falsy(sent.is_error)
			expect.eq(calls.last_target.pid, mare.pid + 1)
			expect.eq(calls.last_target.started_at_ms, 100)
			expect.eq(calls.last_send.queue_only, true)
			expect.eq(calls.last_send.notify_when_idle, nil)
			expect.eq(calls.last_wait, "msg-1")
			expect.eq(sent.details.status, "delivered")
			expect.eq(sent.details.delivery, "queue_only")
			expect.eq(sent.details.input_receipt, nil)
			expect.eq(mock_client.closed, true)

			-- wait=false
			calls.last_wait = nil
			local held = tools.peer_send.execute({ to = "other", message = "async hello", wait = false })
			expect.falsy(held.is_error)
			expect.eq(held.details.status, "held")
			expect.eq(calls.last_wait, nil)
			expect.eq(mock_client.closed, true)

			-- outcome_unknown warns not to resend
			local unknown = tools.peer_send.execute({ to = "other", message = "unknown_err" })
			expect.truthy(unknown.is_error)
			expect.match(unknown.content, "do not resend automatically")
			expect.eq(mock_client.closed, true)

			-- peer_status & wait_idle (current_or_next true and false)
			local st = tools.peer_status.execute({ to = "other", timeout_ms = 0 })
			expect.falsy(st.is_error)
			expect.eq(st.details.status.state, "idle")
			expect.eq(mock_client.closed, true)
			expect.truthy(calls.last_connect_opts == nil or calls.last_connect_opts.timeout_ms == 0)

			local wi = tools.peer_status.execute({ to = "other", wait_idle = true })
			expect.falsy(wi.is_error)
			expect.eq(wi.details.idle.state, "idle")
			expect.eq(calls.last_idle.current_or_next, true)
			expect.eq(mock_client.closed, true)

			local wi_next = tools.peer_status.execute({ to = "other", wait_idle = true, current_or_next = false })
			expect.falsy(wi_next.is_error)
			expect.eq(calls.last_idle.current_or_next, false)
			expect.eq(mock_client.closed, true)

			-- wait_message failure while held returns non-error held receipt with do-not-resend note
			local orig_wait_message = mock_client.wait_message
			mock_client.wait_message = function()
				return nil, { code = "timeout", message = "timed out waiting for decision" }
			end
			local held_timeout = tools.peer_send.execute({ to = "other", message = "wait times out" })
			expect.falsy(held_timeout.is_error)
			expect.eq(held_timeout.details.status, "held")
			expect.eq(held_timeout.details.wait_error, "timeout")
			expect.match(held_timeout.details.note, "do not resend automatically")
			expect.eq(mock_client.closed, true)
			mock_client.wait_message = orig_wait_message

			-- Target name mismatch on pid+started disambiguation fails safely
			local mismatch =
				tools.peer_send.execute({ to = "wrong-name", pid = mare.pid + 1, started_at_ms = 100, message = "hi" })
			expect.truthy(mismatch.is_error)
			expect.match(mismatch.content, "Target name mismatch")
			expect.eq(mock_client.closed, true)

			-- /peers UI: picker + queue_only send + handoff (/peers other)
			local notices = {}
			local select_queue = {}
			mare.ui.notify = function(msg, level)
				notices[#notices + 1] = { msg = msg, level = level }
			end
			mare.ui.select = function(opts)
				calls.last_select_opts = opts
				return table.remove(select_queue, 1)
			end
			mare.ui.input = function()
				return "ui message"
			end

			select_queue = { 1, 2 }
			commands.peers.run("")
			expect.eq(calls.last_send.text, "ui message")
			expect.eq(calls.last_send.queue_only, true)
			expect.eq(mock_client.closed, true)
			expect.eq(notices[#notices].msg, "Message msg-1: delivered")
			expect.match(calls.last_select_opts.title, "allowed %(self%-reported%):")
			expect.match(calls.last_select_opts.title, "peer%.message")
			expect.match(calls.last_select_opts.title, "delivery modes: trigger_turn, queue_only")

			-- /peers other handoff skips peer picker
			select_queue = { 3 }
			calls.last_idle = nil
			commands.peers.run("other")
			expect.truthy(calls.last_idle)
			expect.eq(calls.last_idle.current_or_next, true)
			expect.eq(mock_client.closed, true)
			expect.match(notices[#notices].msg, "idle")

			-- /peers Refresh status loops then Wait for next idle (action 4)
			select_queue = { 5, 4 }
			calls.last_idle = nil
			commands.peers.run("other")
			expect.truthy(calls.last_idle)
			expect.eq(calls.last_idle.current_or_next, false)
			expect.eq(mock_client.closed, true)

			-- /peers duplicate-name disambiguation prompts before action menu
			entries[2].mode = "rpc"
			entries[2].plugins = { session = { session_id = "s", name = "alpha" }, status = { held = 3 } }
			entries[3] = {
				name = "other",
				pid = mare.pid + 2,
				cwd = "/other/proj",
				started_at_ms = 200,
				status = { state = "working" },
			}
			select_queue = { 2, 3 }
			local orig_info = mock_client.info
			mock_client.info = function()
				return {
					name = "other",
					pid = mare.pid + 2,
					allowed = {
						"peer.info",
						"status.get",
						"peer.message",
						"events.subscribe",
					},
					delivery_modes = { "trigger_turn", "queue_only" },
				}
			end
			commands.peers.run("other")
			expect.eq(calls.last_target.pid, mare.pid + 2)
			expect.eq(calls.last_target.started_at_ms, 200)
			mock_client.info = orig_info
			entries[3] = {
				name = "third",
				pid = mare.pid + 2,
				cwd = "/other/proj",
				started_at_ms = 200,
				status = { state = "working" },
			}

			-- Queued caller cancellation / invalidation must not deliver
			calls.last_send = nil
			calls.last_target = nil
			local pre_tok = mare.task.token()
			pre_tok:cancel()
			local pre_cancelled = tools.peer_send.execute(
				{ to = "other", message = "must not connect" },
				{ cancel = pre_tok }
			)
			expect.truthy(pre_cancelled.is_error)
			expect.match(pre_cancelled.content, "cancelled")
			expect.eq(calls.last_target, nil)
			expect.eq(calls.last_send, nil)

			local mid_tok = mare.task.token()
			mare.peers.connect = function(target, opts) -- the caller owns the client (no ctx argument)
				calls.last_target = target
				calls.last_connect_opts = opts
				mid_tok:cancel()
				mock_client.closed = false
				return mock_client
			end
			local mid_cancelled = tools.peer_send.execute(
				{ to = "other", message = "must not send" },
				{ cancel = mid_tok }
			)
			expect.truthy(mid_cancelled.is_error)
			expect.match(mid_cancelled.content, "cancelled")
			expect.eq(calls.last_send, nil)
			expect.eq(mock_client.closed, true)

			-- peer_status also respects pre-connect and mid-connect cancellation
			local pre_status_tok = mare.task.token()
			pre_status_tok:cancel()
			local pre_status_cancel = tools.peer_status.execute({ to = "other" }, { cancel = pre_status_tok })
			expect.truthy(pre_status_cancel.is_error)
			expect.match(pre_status_cancel.content, "cancelled")

			local mid_status_tok = mare.task.token()
			mare.peers.connect = function(target, opts) -- the caller owns the client (no ctx argument)
				calls.last_target = target
				calls.last_connect_opts = opts
				mid_status_tok:cancel()
				mock_client.closed = false
				return mock_client
			end
			local mid_status_cancel = tools.peer_status.execute({ to = "other" }, { cancel = mid_status_tok })
			expect.truthy(mid_status_cancel.is_error)
			expect.match(mid_status_cancel.content, "cancelled")
			expect.eq(mock_client.closed, true)
		end
	)
	it("owns its clients: a session switch or an unload closes an open client once", function()
		entries = {
			{
				name = "other",
				pid = mare.pid + 1,
				cwd = "/work/other",
				started_at_ms = 100,
				status = { state = "idle" },
			},
		}
		local closes, during
		local client = {
			info = function()
				return { name = "other", pid = mare.pid + 1, delivery_modes = { "trigger_turn" } }
			end,
			send = function()
				during() -- the switch / unload happens while this call holds the client
				return { message_id = "msg-1", status = "delivered" }
			end,
			close = function()
				closes = closes + 1
			end,
		}
		mare.peers.connect = function()
			return client
		end
		mount()
		expect.eq(type(listeners["session/changed"]), "function", "peers closes its clients on session/changed")
		expect.eq(#cleanups, 1, "peers registers one cleanup for its clients")
		for _, case in ipairs({
			{
				"session/changed",
				function()
					listeners["session/changed"]({ reason = "new" })
				end,
			},
			{
				"unload",
				function()
					for _, cleanup in ipairs(cleanups) do
						cleanup()
					end
				end,
			},
		}) do
			closes = 0
			local checked = false
			during = function()
				case[2]()
				expect.eq(closes, 1, case[1] .. " closes the open client")
				checked = true
			end
			local result = tools.peer_send.execute(
				{ to = "other", message = "hi", wait = false },
				{ cancel = mare.task.token() }
			)
			expect.truthy(checked, case[1] .. ": the in-call check ran")
			expect.falsy(result.is_error, case[1] .. ": " .. tostring(result.content))
			expect.eq(closes, 1, case[1] .. ": the finished call does not close it again")
		end
	end)

	it("closes and aborts when a session switch or unload happens during the connect handshake", function()
		entries = {
			{
				name = "other",
				pid = mare.pid + 1,
				cwd = "/work/other",
				started_at_ms = 100,
				status = { state = "idle" },
			},
		}
		local closes, sends, statuses, during
		local client = {
			info = function()
				return { name = "other", pid = mare.pid + 1, delivery_modes = { "trigger_turn" } }
			end,
			send = function()
				sends = sends + 1
				return { message_id = "msg-1", status = "delivered" }
			end,
			status = function()
				statuses = statuses + 1
				return { state = "idle" }
			end,
			close = function()
				closes = closes + 1
			end,
		}
		mare.peers.connect = function()
			if during then
				during() -- barrier: switch / unload fires while connect is in flight
			end
			return client
		end
		for _, case in ipairs({
			{
				name = "session/changed",
				trigger = function()
					listeners["session/changed"]({ reason = "new" })
				end,
				still_usable = true,
			},
			{
				name = "unload",
				trigger = function()
					for _, cleanup in ipairs(cleanups) do
						cleanup()
					end
				end,
				still_usable = false,
			},
		}) do
			mount()
			closes, sends, statuses = 0, 0, 0
			local triggered = false
			during = function()
				case.trigger()
				triggered = true
			end
			local send_res = tools.peer_send.execute(
				{ to = "other", message = "must not send", wait = false },
				{ cancel = mare.task.token() }
			)
			expect.truthy(triggered, case.name .. ": handshake barrier ran")
			expect.truthy(send_res.is_error, case.name .. ": peer_send must fail when handshake is invalidated")
			expect.eq(sends, 0, case.name .. ": must not send after " .. case.name .. " during handshake")
			expect.eq(closes, 1, case.name .. ": client returned after " .. case.name .. " must be closed once")
			-- Re-firing cleanup must not see a leaked client
			case.trigger()
			expect.eq(closes, 1, case.name .. ": no leaked client remains in open_clients")

			-- Also check peer_status under handshake invalidation
			if case.still_usable then
				triggered = false
				local status_res = tools.peer_status.execute({ to = "other" }, { cancel = mare.task.token() })
				expect.truthy(triggered, case.name .. ": peer_status handshake barrier ran")
				expect.truthy(status_res.is_error, case.name .. ": peer_status must fail when handshake is invalidated")
				expect.eq(statuses, 0, case.name .. ": must not query status after " .. case.name)
				expect.eq(closes, 2, case.name .. ": peer_status closes its invalidated handshake client once")

				-- Subsequent calls in the new session succeed once no switch happens mid-handshake
				during = nil
				local ok_res = tools.peer_send.execute(
					{ to = "other", message = "after switch", wait = false },
					{ cancel = mare.task.token() }
				)
				expect.falsy(ok_res.is_error, "new session can still send: " .. tostring(ok_res.content))
				expect.eq(sends, 1, "new session sends once")
				expect.eq(closes, 3, "new session closes its client normally")
			end
		end
	end)

	it(
		"truncates CJK text on UTF-8 boundaries, snapshots open_clients in release_all, and normalizes Windows cwd prefixes",
		function()
			mount()

			-- UTF-8 safe truncation in UI via /peers picker
			local long_cjk = string.rep("日本語テスト", 20)
			entries = {
				{
					name = "cjk-peer",
					pid = mare.pid + 1,
					cwd = "/repo",
					started_at_ms = 100,
					plugins = { session = { session_id = "s-cjk", name = long_cjk } },
					status = { state = "working", message = long_cjk },
				},
			}
			local picked_opts
			mare.ui.select = function(opts)
				picked_opts = opts
				return nil
			end
			commands.peers.run("")
			expect.truthy(picked_opts and #picked_opts.items == 1)
			expect.truthy(utf8.len(picked_opts.items[1]) ~= nil)
			expect.truthy(picked_opts.items[1]:find("...", 1, true))

			-- release_all snapshots open_clients even if close() yields/mutates or new client opens
			local closed_order = {}
			local late_client_closed = false
			mare.peers.connect = function()
				return {
					info = function()
						return { name = "other", pid = mare.pid + 1, delivery_modes = { "trigger_turn" } }
					end,
					send = function()
						listeners["session/changed"]({ reason = "new" })
						return { message_id = "m1", status = "delivered" }
					end,
					close = function(self)
						closed_order[#closed_order + 1] = self
						if #closed_order == 1 then
							-- Simulate closing yielding while another call opens/closes
							late_client_closed = true
						end
					end,
				}
			end
			entries = {
				{ name = "other", pid = mare.pid + 1, cwd = "/repo", started_at_ms = 100, status = { state = "idle" } },
			}
			local s_res = tools.peer_send.execute(
				{ to = "other", message = "hi", wait = false },
				{ cancel = mare.task.token() }
			)
			expect.falsy(s_res.is_error)
			expect.truthy(late_client_closed)
			expect.eq(#closed_order, 1)

			-- matches_cwd_prefix handles Windows backslashes & slashes uniformly
			local orig_os = mare.os
			mare.os = "windows"
			entries = {
				{
					name = "win-a",
					pid = mare.pid + 10,
					cwd = "C:\\Repo\\sub",
					started_at_ms = 100,
					status = { state = "idle" },
				},
				{
					name = "win-b",
					pid = mare.pid + 11,
					cwd = "C:/Repo/other",
					started_at_ms = 100,
					status = { state = "idle" },
				},
				{
					name = "win-c",
					pid = mare.pid + 12,
					cwd = "D:\\Other",
					started_at_ms = 100,
					status = { state = "idle" },
				},
			}
			local listed = tools.peer_list.execute({ cwd = "c:/repo\\" })
			mare.os = orig_os
			expect.falsy(listed.is_error)
			expect.eq(#listed.details.peers, 2)
		end
	)
end)
