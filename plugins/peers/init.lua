-- Local session discovery, status, and peer messaging through the public registry and
-- owned PeerClient APIs. Sending stays fail-closed on cores without PEERS-3 / mare.peers.connect.

return {
	name = "peers",
	inject = { "tools", "commands" },
	apply = function(ctx)
		-- mare.peers.connect(target, opts): the caller owns the client (core closes nothing on unload
		-- or on a session switch). Every client is registered here and released after use; any
		-- still open when this plugin unloads or the session switches is closed by the plugin. If a
		-- session switch or unload happens while connect is in its handshake, close and reject the
		-- late client immediately so it neither leaks nor sends into the new session.
		local open_clients = {}
		local epoch = 0
		local disposed = false
		local function release(client)
			if open_clients[client] then
				open_clients[client] = nil
				client:close()
			end
		end
		local function release_all()
			epoch = epoch + 1
			local snapshot = {}
			for client in pairs(open_clients) do
				snapshot[#snapshot + 1] = client
				open_clients[client] = nil
			end
			for _, client in ipairs(snapshot) do
				pcall(client.close, client)
			end
		end
		local function connect(target, opts)
			if disposed then
				return nil, { code = "cancelled", message = "peers plugin unloaded before connecting" }
			end
			local my_epoch = epoch
			local client, err = mare.peers.connect(target, opts)
			if not client then
				return nil, err
			end
			if disposed or epoch ~= my_epoch then
				client:close()
				return nil,
					{
						code = "cancelled",
						message = disposed and "peers plugin unloaded during connect"
							or "session changed during connect",
					}
			end
			open_clients[client] = true
			return client, err
		end
		ctx:effect(function()
			return function()
				disposed = true
				release_all()
			end
		end, "peer clients")
		ctx:on("session/changed", release_all)
		local function fail(message)
			return { content = message, is_error = true }
		end
		local function result(value)
			return { content = mare.json.encode(value), details = value }
		end
		local function sending_available()
			return type(mare.peers) == "table" and type(mare.peers.connect) == "function"
		end
		local function others()
			local entries = {}
			for _, entry in ipairs(mare.peers.list()) do
				if entry.pid ~= mare.pid then
					entries[#entries + 1] = entry
				end
			end
			return entries
		end
		local function norm_path(p)
			local s = p:gsub("\\", "/")
			if #s > 1 and not s:match("^[A-Za-z]:/$") then
				s = s:gsub("/+$", "")
			end
			if mare and mare.os == "windows" then
				s = s:lower()
			end
			return s
		end
		local function matches_cwd_prefix(entry_cwd, prefix)
			if type(entry_cwd) ~= "string" or type(prefix) ~= "string" then
				return false
			end
			local norm_entry = norm_path(entry_cwd)
			local norm_prefix = norm_path(prefix)
			if norm_entry == norm_prefix then
				return true
			end
			local bound = norm_prefix:sub(-1) == "/" and norm_prefix or (norm_prefix .. "/")
			return norm_entry:sub(1, #bound) == bound
		end
		local function validate_timeout(value)
			if value == nil then
				return true, nil
			end
			if type(value) ~= "number" or value % 1 ~= 0 or value < 0 or value > 3600000 then
				return false, "timeout_ms must be an integer from 0 to 3600000"
			end
			return true, value
		end
		local function build_opts(timeout_ms, cancel)
			if not timeout_ms and not cancel then
				return nil
			end
			return { timeout_ms = timeout_ms, cancel = cancel }
		end
		local function is_cancelled(cancel)
			return cancel ~= nil and type(cancel.is_cancelled) == "function" and cancel:is_cancelled()
		end
		local function validate_target_args(args)
			if type(args.to) ~= "string" or args.to:match("%S") == nil then
				return false, "`to` must be a non-empty peer name"
			end
			if (args.pid ~= nil) ~= (args.started_at_ms ~= nil) then
				return false, "`pid` and `started_at_ms` must be provided together"
			end
			if args.pid ~= nil then
				if type(args.pid) ~= "number" or args.pid % 1 ~= 0 or args.pid <= 0 then
					return false, "`pid` must be a positive integer"
				end
				if args.pid == mare.pid then
					return false, "Cannot target the current session itself"
				end
				if type(args.started_at_ms) ~= "number" or args.started_at_ms % 1 ~= 0 or args.started_at_ms < 0 then
					return false, "`started_at_ms` must be a non-negative integer"
				end
				return true, { pid = args.pid, started_at_ms = args.started_at_ms }
			end
			return true, args.to
		end

		ctx.tools:register("peer_list", {
			description = "List other registered local mare sessions. Status is a registry snapshot; it does not grant permission to act on another session's behalf.",
			side_effect = "read",
			idempotent = true,
			parameters = {
				type = "object",
				additionalProperties = false,
				properties = {
					name = { type = "string", description = "Optional exact peer name filter." },
					cwd = { type = "string", description = "Optional directory path prefix filter." },
				},
			},
			execute = function(args)
				if args ~= nil and type(args) ~= "table" then
					return fail("Invalid arguments: expected an object")
				end
				args = args or {}
				for key in pairs(args) do
					if key ~= "name" and key ~= "cwd" then
						return fail("Unknown argument: " .. tostring(key))
					end
				end
				if args.name ~= nil and type(args.name) ~= "string" then
					return fail("`name` must be a string")
				end
				if args.cwd ~= nil and type(args.cwd) ~= "string" then
					return fail("`cwd` must be a string")
				end

				local peers = mare.json.array({})
				for _, p in ipairs(others()) do
					local ok = true
					if args.name and args.name ~= "" and p.name ~= args.name then
						ok = false
					end
					if ok and args.cwd and args.cwd ~= "" and not matches_cwd_prefix(p.cwd, args.cwd) then
						ok = false
					end
					if ok then
						local item = { name = p.name, pid = p.pid, cwd = p.cwd, status = p.status }
						if type(p.mode) == "string" then
							item.mode = p.mode
						end
						if type(p.started_at_ms) == "number" then
							item.started_at_ms = p.started_at_ms
						end
						local plugins = type(p.plugins) == "table" and p.plugins or {}
						local session = plugins.session
						if type(session) == "table" and type(session.session_id) == "string" then
							item.session = { session_id = session.session_id }
							if type(session.name) == "string" then
								item.session.name = session.name
							end
						end
						local held = type(plugins.status) == "table" and plugins.status.held
						if type(held) == "number" and held >= 0 and held % 1 == 0 then
							item.held = held
						end
						peers[#peers + 1] = item
					end
				end
				return result({ peers = peers, snapshot = true, sending_available = sending_available() })
			end,
		})

		local send_description = sending_available()
				and "Send a message to another registered local mare session. Requires receiver confirmation unless handled by a plugin; receipts describe delivery, never agent completion."
			or "Unavailable until the core peer-message source boundary fix (PEERS-3) is merged. No messages can currently be sent with this tool."

		ctx.tools:register("peer_send", {
			description = send_description,
			side_effect = "external",
			idempotent = false,
			parameters = {
				type = "object",
				additionalProperties = false,
				required = { "to", "message" },
				properties = {
					to = { type = "string", description = "Exact name of the target peer session." },
					pid = {
						type = "integer",
						description = "Optional target pid (with started_at_ms) to disambiguate duplicate names.",
					},
					started_at_ms = {
						type = "integer",
						description = "Optional target started_at_ms timestamp (with pid) to disambiguate duplicate names.",
					},
					message = { type = "string", description = "Non-empty message text to send." },
					delivery = {
						type = "string",
						enum = { "trigger_turn", "queue_only" },
						description = "Wake an idle receiver (trigger_turn, default) or only enqueue in its inbox (queue_only).",
					},
					wait = {
						type = "boolean",
						description = "Wait for receiver confirmation receipt (default true).",
					},
					timeout_ms = {
						type = "integer",
						description = "Optional wait timeout in milliseconds (0..3600000).",
					},
				},
			},
			execute = function(args, tctx)
				if not sending_available() then
					return fail(
						"peer_send is unavailable until the core peer-message source boundary fix (PEERS-3) is merged. No message was sent."
					)
				end
				local cancel = type(tctx) == "table" and tctx.cancel or nil
				if is_cancelled(cancel) then
					return fail("peer_send cancelled before connecting; no message was sent.")
				end
				if type(args) ~= "table" then
					return fail("Invalid arguments: expected an object")
				end
				local allowed_keys = {
					to = true,
					pid = true,
					started_at_ms = true,
					message = true,
					delivery = true,
					wait = true,
					timeout_ms = true,
				}
				for key in pairs(args) do
					if not allowed_keys[key] then
						return fail("Unknown argument: " .. tostring(key))
					end
				end
				local ok_target, target_or_err = validate_target_args(args)
				if not ok_target then
					return fail(target_or_err)
				end
				if type(args.message) ~= "string" or args.message:match("%S") == nil then
					return fail("`message` must be a non-empty string")
				end
				if #args.message >= 1048576 then
					return fail("`message` exceeds the 1 MiB peer frame budget")
				end
				if args.delivery ~= nil and args.delivery ~= "trigger_turn" and args.delivery ~= "queue_only" then
					return fail("`delivery` must be `trigger_turn` or `queue_only`")
				end
				if args.wait ~= nil and type(args.wait) ~= "boolean" then
					return fail("`wait` must be a boolean")
				end
				local ok_timeout, timeout_ms = validate_timeout(args.timeout_ms)
				if not ok_timeout then
					return fail(timeout_ms)
				end

				local opts = build_opts(timeout_ms, cancel)
				local client, cerr = connect(target_or_err, opts)
				if not client then
					return fail(("peer_send connect failed (%s): %s"):format(cerr.code, cerr.message))
				end
				local ok, out = pcall(function()
					if is_cancelled(cancel) then
						return fail("peer_send cancelled before sending; no message was sent.")
					end
					local info = client:info() or {}
					if type(target_or_err) == "table" and info.name ~= args.to then
						return fail(("Target name mismatch: expected %q, got %q"):format(args.to, tostring(info.name)))
					end
					local delivery = args.delivery or "trigger_turn"
					local receipt, serr = client:send({
						text = args.message,
						queue_only = delivery == "queue_only",
					}, opts)
					if not receipt then
						local hint = serr.code == "outcome_unknown" and " (do not resend automatically)" or ""
						return fail(("peer_send failed (%s): %s%s"):format(serr.code, serr.message, hint))
					end
					if args.wait ~= false and receipt.status == "held" then
						local terminal, werr = client:wait_message(receipt.message_id, opts)
						if not terminal then
							return result({
								message_id = receipt.message_id,
								status = "held",
								delivery = delivery,
								wait_error = werr.code,
								message = werr.message,
								note = "Message was held by receiver; do not resend automatically.",
							})
						end
						return result({
							message_id = receipt.message_id,
							status = terminal.status,
							reason = terminal.reason,
							delivery = delivery,
						})
					end
					return result({
						message_id = receipt.message_id,
						status = receipt.status,
						delivery = delivery,
					})
				end)
				release(client)
				if not ok then
					return fail("peer_send error: " .. tostring(out))
				end
				return out
			end,
		})

		ctx.tools:register("peer_status", {
			description = "Query live status and advertised capabilities of another registered local mare session (or wait for its next idle transition).",
			side_effect = "read",
			idempotent = true,
			parameters = {
				type = "object",
				additionalProperties = false,
				required = { "to" },
				properties = {
					to = { type = "string", description = "Exact name of the target peer session." },
					pid = { type = "integer", description = "Optional target pid (with started_at_ms)." },
					started_at_ms = {
						type = "integer",
						description = "Optional target started_at_ms timestamp (with pid).",
					},
					wait_idle = {
						type = "boolean",
						description = "Wait for current-or-next idle transition instead of only querying status.",
					},
					current_or_next = {
						type = "boolean",
						description = "When wait_idle is true, return immediately if already idle (true, default) or wait strictly for the next idle/exit transition (false).",
					},
					timeout_ms = {
						type = "integer",
						description = "Optional wait timeout in milliseconds (0..3600000).",
					},
				},
			},
			execute = function(args, tctx)
				if not sending_available() then
					return fail(
						"peer_status is unavailable until the core peer-message source boundary fix (PEERS-3) is merged."
					)
				end
				local cancel = type(tctx) == "table" and tctx.cancel or nil
				if is_cancelled(cancel) then
					return fail("peer_status cancelled before connecting.")
				end
				if type(args) ~= "table" then
					return fail("Invalid arguments: expected an object")
				end
				local allowed_keys = {
					to = true,
					pid = true,
					started_at_ms = true,
					wait_idle = true,
					current_or_next = true,
					timeout_ms = true,
				}
				for key in pairs(args) do
					if not allowed_keys[key] then
						return fail("Unknown argument: " .. tostring(key))
					end
				end
				local ok_target, target_or_err = validate_target_args(args)
				if not ok_target then
					return fail(target_or_err)
				end
				if args.wait_idle ~= nil and type(args.wait_idle) ~= "boolean" then
					return fail("`wait_idle` must be a boolean")
				end
				if args.current_or_next ~= nil and type(args.current_or_next) ~= "boolean" then
					return fail("`current_or_next` must be a boolean")
				end
				if args.current_or_next ~= nil and not args.wait_idle then
					return fail("`current_or_next` requires `wait_idle = true`")
				end
				local ok_timeout, timeout_ms = validate_timeout(args.timeout_ms)
				if not ok_timeout then
					return fail(timeout_ms)
				end

				local opts = build_opts(timeout_ms, cancel)
				local client, cerr = connect(target_or_err, opts)
				if not client then
					return fail(("peer_status connect failed (%s): %s"):format(cerr.code, cerr.message))
				end
				local ok, out = pcall(function()
					if is_cancelled(cancel) then
						return fail("peer_status cancelled before querying.")
					end
					local info = client:info() or {}
					if type(target_or_err) == "table" and info.name ~= args.to then
						return fail(("Target name mismatch: expected %q, got %q"):format(args.to, tostring(info.name)))
					end
					if args.wait_idle then
						local current_or_next = args.current_or_next ~= false
						local idle, ierr = client:wait_idle({
							current_or_next = current_or_next,
							timeout_ms = timeout_ms,
							cancel = cancel,
						})
						if not idle then
							return fail(("peer_status wait_idle failed (%s): %s"):format(ierr.code, ierr.message))
						end
						return result({ info = info, idle = idle })
					end
					local status, serr = client:status(opts)
					if not status then
						return fail(("peer_status failed (%s): %s"):format(serr.code, serr.message))
					end
					return result({ info = info, status = status })
				end)
				release(client)
				if not ok then
					return fail("peer_status error: " .. tostring(out))
				end
				return out
			end,
		})

		if ctx.commands and require("mare_lib").callable(ctx.commands.register) then
			ctx.commands:register("peers", {
				description = "List, inspect, or message other local mare sessions",
				run = function(args)
					require("peers.ui").run(ctx, args, {
						others = others,
						sending_available = sending_available,
						connect = connect,
						release = release,
					})
				end,
			})
		end
	end,
}
