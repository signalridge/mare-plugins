local support = assert(load(mare.fs.read("tests/specs/support.lua"), "@tests/specs/support.lua"))()

local describe = mare.test.describe
local it = mare.test.it
local before_each = mare.test.before_each
local after_each = mare.test.after_each
local expect = mare.test.expect

local secrets_plugin = support.load_plugin("secrets", { "secrets.storage" })

describe("secrets plugin", function()
	local orig_input, orig_notify
	local notices, input_fn
	local info, agent_busy, auth_store, invalidations, sections, commands, events, disposers, svc

	before_each(function()
		orig_input = mare.ui.input
		orig_notify = mare.ui.notify
		notices = {}
		input_fn = nil
		info = { session_id = "sess-1", session_epoch = "gen-1" }
		agent_busy = false
		auth_store = {}
		invalidations = 0
		sections = {}
		commands = {}
		events = {}
		disposers = {}
		svc = nil

		mare.ui.notify = function(msg, level)
			notices[#notices + 1] = { msg = msg, level = level }
		end
		mare.ui.input = function(opts)
			if input_fn then
				return input_fn(opts)
			end
			return nil
		end

		secrets_plugin.apply({
			session = {
				info = function()
					return info
				end,
			},
			agent = {
				get = function()
					return { busy = agent_busy }
				end,
			},
			context = {
				invalidate = function()
					invalidations = invalidations + 1
				end,
				section = function(_, def)
					sections[def.name] = def
					return { replace = function() end }
				end,
			},
			llm = {
				auth_get = function(_, k)
					return auth_store[k]
				end,
				auth_set = function(_, k, v)
					auth_store[k] = v
				end,
				auth_keys = function()
					local out = {}
					for k in pairs(auth_store) do
						out[#out + 1] = k
					end
					table.sort(out)
					return out
				end,
			},
			commands = {
				register = function(_, name, def)
					commands[name] = def
				end,
			},
			provide = function(_, name, impl)
				expect.eq(name, "secrets")
				svc = impl
			end,
			on = function(_, ev, fn)
				events[ev] = fn
			end,
			effect = function(_, setup)
				disposers[#disposers + 1] = setup()
			end,
		})
	end)

	after_each(function()
		for _, dispose in ipairs(disposers) do
			if type(dispose) == "function" then
				dispose()
			end
		end
		mare.ui.input = orig_input
		mare.ui.notify = orig_notify
	end)

	it("registers, lists, projects context references, removes, and clears leases on session switch", function()
		expect.truthy(svc)
		expect.truthy(sections["secrets:references"])
		expect.eq(sections["secrets:references"].text(), nil)

		local ref_b = svc.register(svc, nil, "BETA_TOKEN", "BetaSecretValue_98765")
		local ref_a = svc.register(svc, nil, "ALPHA_TOKEN", "AlphaSecretValue_12345")
		expect.truthy(ref_a:find("[[mare-value:", 1, true))
		expect.truthy(ref_b:find("[[mare-value:", 1, true))
		expect.truthy(invalidations >= 2)

		local listed = svc.list()
		expect.eq(#listed, 2)
		expect.eq(listed[1].name, "ALPHA_TOKEN")
		expect.eq(listed[1].reference, ref_a)
		expect.eq(listed[2].name, "BETA_TOKEN")
		expect.eq(listed[2].reference, ref_b)

		local ctx_text = sections["secrets:references"].text()
		expect.truthy(ctx_text:find("ALPHA_TOKEN: " .. ref_a, 1, true))
		expect.truthy(ctx_text:find("BETA_TOKEN: " .. ref_b, 1, true))
		expect.falsy(ctx_text:find("AlphaSecretValue_12345", 1, true))

		-- Duplicate name and invalid names are rejected.
		expect.error(function()
			svc.register(svc, nil, "ALPHA_TOKEN", "AnotherSecretValue_123")
		end, "already registered")
		expect.error(function()
			svc.register(svc, nil, "bad-name", "ValidSecretValue_12345")
		end, "Invalid secret name")
		expect.error(function()
			svc.register(svc, nil, "EMBEDDED_TOKEN_VAL", "TOKEN_VAL")
		end, "must not contain registered values")

		expect.eq(svc.remove(svc, nil, "ALPHA_TOKEN"), true)
		expect.eq(svc.remove(svc, nil, "ALPHA_TOKEN"), false)
		expect.eq(#svc.list(), 1)

		-- Session switch revokes remaining session leases and invalidates context.
		local inv_before = invalidations
		info = { session_id = "sess-2", session_epoch = "gen-2" }
		events["session/changed"]()
		expect.eq(#svc.list(), 0)
		expect.eq(sections["secrets:references"].text(), nil)
		expect.truthy(invalidations > inv_before)
	end)

	it("persists, describes, loads, resolves, enumerates, and deletes profile credentials", function()
		local missing = svc.describe(svc, nil, "API_KEY")
		expect.eq(missing.name, "API_KEY")
		expect.eq(missing.configured, false)
		expect.eq(missing.masked, nil)

		local ok_missing, err_missing = pcall(svc.load, svc, nil, "API_KEY")
		expect.falsy(ok_missing)
		expect.eq(err_missing.code, "secrets.not_configured")

		local saved = svc.save(svc, nil, "API_KEY", "sk-live-SecretBodyValue9999")
		expect.eq(saved.name, "API_KEY")
		expect.eq(saved.configured, true)
		expect.eq(saved.source, "auth")
		expect.eq(saved.scope, "profile")
		expect.eq(saved.writable, true)
		expect.truthy(saved.masked)
		expect.falsy(saved.masked:find("SecretBodyValue", 1, true))

		local resolved = svc.resolve(svc, nil, "API_KEY")
		expect.eq(resolved.source, "auth")
		expect.eq(resolved.scope, "profile")
		expect.truthy(resolved.reference:find("[[mare-value:", 1, true))
		expect.eq(#svc.list(), 1)

		-- stored() includes only mare-plugin/secrets/* entries and marks corrupt records invalid.
		auth_store["openai"] = { api_key = "ignored-provider-key" }
		auth_store["mare-plugin/secrets/CORRUPT_KEY"] = { version = 99, kind = "bad" }
		local stored = svc.stored()
		expect.eq(#stored, 2)
		expect.eq(stored[1].name, "API_KEY")
		expect.eq(stored[1].configured, true)
		expect.eq(stored[2].name, "CORRUPT_KEY")
		expect.eq(stored[2].invalid, true)

		-- Loading a corrupt/missing key fails closed and revokes any existing local lease.
		auth_store["mare-plugin/secrets/API_KEY"] = nil
		local ok_fail, err_fail = pcall(svc.load, svc, nil, "API_KEY")
		expect.falsy(ok_fail)
		expect.eq(err_fail.code, "secrets.not_configured")
		expect.eq(#svc.list(), 0)

		-- Re-save, load, then delete revokes both stored record and session lease.
		svc.save(svc, nil, "API_KEY", "sk-live-ReplacementValue8888")
		svc.load(svc, nil, "API_KEY")
		expect.eq(#svc.list(), 1)
		local deleted = svc.delete(svc, nil, "API_KEY")
		expect.eq(deleted.configured, false)
		expect.eq(#svc.list(), 0)
	end)

	it("handles /secrets slash command actions and guards session/busy races during masked input", function()
		expect.truthy(commands.secrets)
		expect.eq(commands.secrets.availability, "idle")

		-- /secrets add via masked UI input.
		input_fn = function(opts)
			expect.eq(opts.secret, true)
			return "SlashAddedSecret_54321"
		end
		commands.secrets.run("add CMD_SECRET")
		expect.eq(#svc.list(), 1)
		expect.eq(notices[#notices].level, "info")
		expect.truthy(notices[#notices].msg:find("Registered CMD_SECRET:", 1, true))
		expect.falsy(notices[#notices].msg:find("SlashAddedSecret_54321", 1, true))

		-- /secrets save -> /secrets describe -> /secrets load -> /secrets stored -> /secrets delete.
		input_fn = function()
			return "SlashSavedSecret_67890"
		end
		commands.secrets.run("save SAVED_SECRET")
		expect.truthy(notices[#notices].msg:find("Saved SAVED_SECRET", 1, true))

		commands.secrets.run("describe SAVED_SECRET")
		expect.truthy(notices[#notices].msg:find("SAVED_SECRET: configured", 1, true))

		commands.secrets.run("load SAVED_SECRET")
		expect.eq(#svc.list(), 2)

		commands.secrets.run("stored")
		expect.truthy(notices[#notices].msg:find("SAVED_SECRET: configured", 1, true))

		commands.secrets.run("list")
		expect.truthy(notices[#notices].msg:find("CMD_SECRET:", 1, true))
		expect.truthy(notices[#notices].msg:find("SAVED_SECRET:", 1, true))

		commands.secrets.run("remove CMD_SECRET")
		expect.eq(notices[#notices].msg, "Registration revoked")
		expect.eq(#svc.list(), 1)

		commands.secrets.run("delete SAVED_SECRET")
		expect.truthy(notices[#notices].msg:find("SAVED_SECRET: not configured", 1, true))
		expect.eq(#svc.list(), 0)

		-- Cancelled input reports info and does not register.
		input_fn = function()
			return nil
		end
		commands.secrets.run("add CANCELLED_SECRET")
		expect.eq(notices[#notices].level, "info")
		expect.eq(#svc.list(), 0)

		-- Agent turning busy while entering input rejects registration.
		input_fn = function()
			agent_busy = true
			return "BusyRaceSecret_123456"
		end
		commands.secrets.run("add BUSY_SECRET")
		expect.eq(notices[#notices].level, "error")
		expect.truthy(notices[#notices].msg:find("Session changed", 1, true))
		expect.eq(#svc.list(), 0)
		agent_busy = false

		-- Clear and invalid usage.
		svc.register(svc, nil, "CLEAR_ME", "ClearMeSecret_123456")
		commands.secrets.run("clear")
		expect.eq(#svc.list(), 0)

		commands.secrets.run("bogus_action")
		expect.eq(notices[#notices].level, "error")
		expect.truthy(notices[#notices].msg:find("Usage: /secrets", 1, true))
	end)
end)
