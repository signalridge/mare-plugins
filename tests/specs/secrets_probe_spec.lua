local support = assert(load(mare.fs.read("tests/specs/support.lua"), "@tests/specs/support.lua"))()

local describe = mare.test.describe
local it = mare.test.it
local before_each = mare.test.before_each
local after_each = mare.test.after_each
local expect = mare.test.expect

local probe = support.load_lua("tests/secrets/probe/init.lua")

describe("secrets-probe", function()
	local orig_env, capture_path, tools, listeners

	before_each(function()
		orig_env = mare.env
		capture_path = mare.paths.state .. "/secrets-probe-capture.jsonl"
		assert(mare.fs.write(capture_path, ""))
		mare.env = function(name)
			if name == "SECRETS_CAPTURE" then
				return capture_path
			elseif name == "SECRETS_MODE" then
				return "tui-progress"
			elseif name == "SECRETS_TUI_ABORT" then
				return "1"
			elseif name == "SECRETS_VALUE" then
				return "FAKE_registered_secret_83ef"
			end
			return orig_env(name)
		end

		tools, listeners = {}, {}
		probe.apply({
			on = function(_, event, fn)
				listeners[event] = fn
			end,
			tools = {
				register = function(_, name, def)
					tools[name] = def
				end,
			},
			llm = {
				register_provider = function() end,
			},
		})
	end)

	after_each(function()
		mare.env = orig_env
	end)

	it("preserves concurrent tool-cancelled and queue/changed records without read-modify-write loss", function()
		for round = 1, 5 do
			assert(mare.fs.write(capture_path, ""))
			local token = mare.task.token()
			local tool_tx, tool_rx = mare.task.channel()
			local queue_tx, queue_rx = mare.task.channel()
			mare.task.spawn(function()
				tools.secret_echo.execute({ value = "FAKE_registered_secret_83ef" }, {
					cancel = token,
					update = function() end,
				})
				tool_tx:send(true)
			end)
			local deadline = mare.task.clock() + 2000
			while mare.task.clock() < deadline do
				local raw = mare.fs.read(capture_path) or ""
				if raw:find("tool%-hold") then
					break
				end
				mare.task.sleep(5)
			end
			mare.task.spawn(function()
				listeners["queue/changed"]({ action = "steer", items = { { lane = "steer", text = "stop-" .. round } } })
				queue_tx:send(true)
			end)
			token:cancel()
			expect.truthy(tool_rx:recv())
			expect.truthy(queue_rx:recv())

			local raw = assert(mare.fs.read(capture_path))
			local kinds = {}
			for line in raw:gmatch("[^\r\n]+") do
				local entry = mare.json.decode(line)
				kinds[entry.kind] = (kinds[entry.kind] or 0) + 1
			end
			expect.eq(kinds["tool-hold"], 1)
			expect.eq(kinds["tool-cancelled"], 1)
			expect.eq(kinds["queue/changed"], 1)
		end
	end)

	it("reports secrets.unavailable cleanly when llm.auth_keys is missing", function()
		local secrets_plugin = support.load_plugin("secrets", { "secrets.storage" })
		local provided, commands, notices = {}, {}, {}
		local orig_notify = mare.ui.notify
		mare.ui.notify = function(msg, level)
			notices[#notices + 1] = { msg = msg, level = level }
		end
		secrets_plugin.apply({
			session = {
				info = function()
					return { session_id = "s1", session_epoch = "g1" }
				end,
				available = function()
					return true
				end,
				path_to = function()
					return {}
				end,
			},
			agent = {
				list_messages = function()
					return { data = {} }
				end,
			},
			context = {
				invalidate = function() end,
				section = function()
					return { replace = function() end }
				end,
			},
			llm = {
				auth_get = function()
					return nil
				end,
			},
			commands = {
				register = function(_, name, def)
					commands[name] = def
				end,
			},
			provide = function(_, name, svc)
				provided[name] = svc
			end,
			on = function() end,
			effect = function(_, fn)
				return fn()
			end,
		})
		mare.ui.notify = orig_notify
		expect.truthy(provided.secrets)
		local ok, err = pcall(provided.secrets.stored)
		expect.falsy(ok)
		expect.eq(err.code, "secrets.unavailable")
		local orig_notify2 = mare.ui.notify
		mare.ui.notify = function(msg, level)
			notices[#notices + 1] = { msg = msg, level = level }
		end
		commands.secrets.run("stored")
		mare.ui.notify = orig_notify2
		expect.truthy(#notices >= 1)
		expect.eq(notices[#notices].level, "warning")
		expect.truthy(notices[#notices].msg:find("auth_keys", 1, true))
	end)

	it(
		"bounds mask_credential, enforces minimum/reserved-key guards, fences session IDs, and cancels UI on dispose",
		function()
			local secrets_plugin = support.load_plugin("secrets", { "secrets.storage" })
			local info = { session_id = "sess-a", session_epoch = "gen-a" }
			local auth_store = {}
			local events, disposers, commands, provided = {}, {}, {}, {}
			local on_auth_get, on_auth_set
			local orig_input = mare.ui.input
			local orig_notify = mare.ui.notify
			mare.ui.notify = function() end

			secrets_plugin.apply({
				session = {
					info = function()
						return info
					end,
				},
				context = {
					invalidate = function() end,
					section = function() end,
				},
				llm = {
					auth_get = function(_, k)
						if on_auth_get then
							on_auth_get(k)
						end
						return auth_store[k]
					end,
					auth_set = function(_, k, v)
						if on_auth_set then
							on_auth_set(k, v)
						end
						auth_store[k] = v
					end,
					auth_keys = function()
						local out = {}
						for k in pairs(auth_store) do
							out[#out + 1] = k
						end
						return out
					end,
				},
				commands = {
					register = function(_, name, def)
						commands[name] = def
					end,
				},
				provide = function(_, name, svc)
					provided[name] = svc
				end,
				on = function(_, ev, fn)
					events[ev] = fn
				end,
				effect = function(_, setup)
					disposers[#disposers + 1] = setup()
				end,
			})

			-- Bound prefix reveal when '-' or '_' appears late (e.g. URL password).
			local url_secret = "postgres://admin:RealPassword123@db.internal-prod.example.com/app"
			local desc = provided.secrets.save(nil, nil, "DB_URL", url_secret)
			expect.falsy(desc.masked:find("RealPassword123", 1, true))
			expect.falsy(desc.masked:find("admin", 1, true))
			expect.eq(desc.masked:sub(1, 5), "postg")
			expect.eq(desc.masked:sub(-4), "/app")

			-- Reject short and reserved protocol keys before mare.projection.register.
			for _, bad_val in ipairs({
				"t",
				"id",
				"name",
				"text",
				"type",
				"role",
				"status",
				"error",
				"message",
				"[[mare",
			}) do
				expect.error(function()
					provided.secrets.register(nil, nil, "BAD_VAL", bad_val)
				end)
				expect.error(function()
					provided.secrets.save(nil, nil, "BAD_VAL", bad_val)
				end)
			end

			-- Session switch during load/delete I/O does not touch the new session's leases.
			provided.secrets.save(nil, nil, "SHARED_KEY", "SecretValueA_123456")
			local b_ref = provided.secrets.register(nil, nil, "OTHER_KEY", "SecretValueB_123456")
			expect.truthy(b_ref)
			on_auth_get = function()
				info = { session_id = "sess-b", session_epoch = "gen-b" }
			end
			expect.error(function()
				provided.secrets.load(nil, nil, "SHARED_KEY")
			end, "Session changed")
			on_auth_get = nil
			expect.eq(#provided.secrets.list(), 0)

			local b_shared_ref = provided.secrets.register(nil, nil, "SHARED_KEY", "SecretValueB_999999")
			on_auth_set = function()
				info = { session_id = "sess-c", session_epoch = "gen-c" }
			end
			provided.secrets.delete(nil, nil, "SHARED_KEY")
			on_auth_set = nil
			expect.truthy(b_shared_ref)

			-- /secrets add passes cancel token and aborts cleanly when disposed mid-input.
			local saw_cancel_token = nil
			mare.ui.input = function(opts)
				saw_cancel_token = opts.cancel
				for _, d in ipairs(disposers) do
					d()
				end
				return "LateInputSecret_123456"
			end
			commands.secrets.run("add LATE_SECRET")
			mare.ui.input = orig_input
			mare.ui.notify = orig_notify
			expect.truthy(saw_cancel_token)
			expect.truthy(saw_cancel_token:is_cancelled())
			expect.eq(#provided.secrets.list(), 0)
		end
	)
end)
