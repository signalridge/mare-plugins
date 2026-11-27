local support = assert(load(mare.fs.read("tests/specs/support.lua"), "@tests/specs/support.lua"))()

local describe = mare.test.describe
local it = mare.test.it
local before_each = mare.test.before_each
local after_each = mare.test.after_each
local expect = mare.test.expect

local plugin = support.load_plugin("session-title", {
	"session_title.llm",
	"session_title.runtime",
	"session_title.text",
})
local text_mod = require("session_title.text")

local function clone(t)
	local out = {}
	for k, v in pairs(t) do
		out[k] = v
	end
	return out
end

describe("session-title", function()
	local real_log = mare.log
	mare.test.after_each(function()
		mare.log = real_log
	end)
	local events, tasks, disposers, entries, records_store, changed_events, notices
	local service, cmd, state
	local calls, stream_hook, captured, response
	local orig_notify, orig_agent_id, orig_mode
	local ctx

	local function reset_records(tbl)
		records_store = {}
		state = tbl or { id = "a", generation = "1", revision = "0" }
	end

	local function drain()
		while #tasks > 0 do
			local t = table.remove(tasks, 1)
			if not t.finished then
				t.finished = true
				t.run()
			end
		end
	end

	local function input(text, source)
		local msg = {
			role = "user",
			input_source = source or "user",
			content = { { type = "text", text = text } },
		}
		entries[#entries + 1] = { entry_id = tostring(#entries + 1), message = msg }
		events["item/completed"]({ item = { type = "user_message", message = msg } })
		events["request/build"]({ model = ctx.llm:current() })
	end

	before_each(function()
		events, tasks, disposers, entries, changed_events, notices = {}, {}, {}, {}, {}, {}
		service, cmd = nil, nil
		reset_records({ id = "a", generation = "1", revision = "0" })
		calls, stream_hook, captured = 0, nil, nil
		response = { stop_reason = "stop", content = { { type = "text", text = "Generated title" } } }

		orig_notify = mare.ui.notify
		orig_agent_id = mare.agent_id
		orig_mode = mare.mode
		mare.ui.notify = function(msg, level)
			notices[#notices + 1] = { msg = msg, level = level }
		end

		ctx = {
			commands = {
				register = function(_, name, def)
					expect.eq(name, "title")
					cmd = def
				end,
			},
			session = {
				info = function()
					return {
						session_id = state.id,
						session_epoch = state.generation,
						name = state.name,
						revision = state.revision,
						readonly = state.readonly,
						ephemeral = state.ephemeral,
					}
				end,
				available = function()
					return true
				end,
				get = function(_, sid)
					if sid ~= state.id then
						return nil
					end
					return {
						session_id = state.id,
						session_epoch = state.generation,
						name = state.name,
						name_revision = tonumber(state.revision) or 0,
					}
				end,
				path_to = function()
					return entries
				end,
				add_record = function(_, kind, data)
					records_store[#records_store + 1] = { session_id = state.id, kind = kind, data = clone(data) }
					return { durable = true }
				end,
				list_records = function(_, kind)
					local out = {}
					for _, r in ipairs(records_store) do
						if r.session_id == state.id and r.kind == kind then
							out[#out + 1] = clone(r.data)
						end
					end
					return { data = out }
				end,
				update = function(_, name, opts)
					local cur_rev = tonumber(state.revision) or 0
					if opts and opts.expected_revision ~= nil and opts.expected_revision ~= cur_rev then
						error({ code = "session.revision_conflict", message = "conflict" })
					end
					local next_rev = cur_rev + 1
					state.name = name
					state.revision = tostring(next_rev)
					if events["session/named"] then
						events["session/named"]({ name = name })
					end
					return {
						session_id = state.id,
						session_epoch = state.generation,
						name = state.name,
						name_revision = next_rev,
					}
				end,
			},
			llm = {
				current = function()
					return { ref = "faux/test", efforts = { "low" } }
				end,
				resolve = function()
					return { ref = "faux/test", efforts = { "low" } }
				end,
				stream = function(_, req)
					calls = calls + 1
					captured = req
					expect.eq(req.purpose, "title")
					expect.truthy(req.no_fallback)
					expect.eq(#req.tools, 0)
					if stream_hook then
						stream_hook()
					end
					return response
				end,
			},
			on = function(_, ev, fn)
				events[ev] = fn
			end,
			effect = function(_, setup)
				local fn = setup()
				disposers[#disposers + 1] = fn
			end,
			emit = function(_, ev, value)
				if ev == "session-title/changed" then
					changed_events[#changed_events + 1] = value
				end
				if events[ev] then
					events[ev](value)
				end
			end,
			provide = function(_, _, value)
				service = value
			end,
			log = function() end,
			spawn = function(_, fn)
				local t = { run = fn }
				function t:wait()
					if not self.finished then
						self.finished = true
						self.run()
					end
				end
				tasks[#tasks + 1] = t
				return t
			end,
		}
		ctx.after = function(self, _, fn)
			return self:spawn(fn)
		end

		local cfg = support.default_config(plugin)
		cfg.automatic = "all-prompts"
		plugin.apply(ctx, cfg)
	end)

	after_each(function()
		mare.ui.notify = orig_notify
		mare.agent_id = orig_agent_id
		mare.mode = orig_mode
	end)

	it("handles public service, anchor, pin, late completion, and disposer lifecycle", function()
		-- Provider-lowered file bodies are not human title prompts.
		local attached = {
			role = "user",
			input_source = "user",
			input_content = { { type = "file", path = "x", text = "file body" } },
			content = { { type = "text", text = "<file>file body</file>" } },
		}
		entries[#entries + 1] = { entry_id = "attachment", message = attached }
		events["item/completed"]({ item = { type = "user_message", message = attached } })
		expect.eq(state.name, nil)
		expect.eq(#tasks, 0)

		input("design this change")
		drain()
		expect.eq(state.name, "Generated title")
		expect.eq(service.get().metadata.source, "provider")
		expect.eq(calls, 1)

		input("continue implementation")
		drain()
		expect.eq(calls, 2)
		expect.match(captured.messages[1].content[1].text, "Generated title")
		expect.match(captured.system, "exactly, unchanged")

		input("peer payload", "peer")
		drain()
		expect.eq(calls, 2)

		expect.truthy(service.rename(nil, nil, "Manual title"))
		input("human follow up")
		drain()
		expect.eq(state.name, "Manual title")
		expect.eq(calls, 2)

		service.refresh()
		drain()
		expect.eq(calls, 3)
		expect.eq(service.get().metadata.source, "provider")

		stream_hook = function()
			expect.truthy(service.rename(nil, nil, "During generation"))
		end
		service.refresh()
		drain()
		expect.eq(state.name, "During generation")

		-- External session:update (simulating /name or RPC session.update) cancels in-flight title work
		-- and treats the external title as manual user rename.
		stream_hook = function()
			ctx.session:update("External Rename")
		end
		service.refresh()
		drain()
		expect.eq(state.name, "External Rename")
		expect.falsy(service.get().metadata)
		input("follow up after external rename")
		drain()
		expect.eq(state.name, "External Rename")
		expect.eq(calls, 5)

		stream_hook = function()
			state.id = "b"
			state.generation = "2"
			events["session/changed"]()
		end
		service.refresh()
		drain()
		expect.falsy(state.name == "Generated title")
		stream_hook = nil

		-- Release built-in provider, register a custom provider, then dispose with a pending task.
		local done = false
		disposers[1]()
		local remove = service.register(nil, ctx, {
			id = "custom",
			automatic = "all-prompts",
			generate = function(work)
				expect.truthy(work.cancel:is_cancelled())
				done = true
				return { title = "Late" }
			end,
		})
		service.refresh()
		remove()
		expect.truthy(done)
		drain()
		expect.falsy(state.name == "Late")

		-- With no provider, refresh still writes the immediate fallback and unpins manual names.
		expect.truthy(service.rename(nil, nil, "Pinned"))
		expect.truthy(service.refresh())
		expect.eq(service.get().metadata.source, "fallback")
		expect.eq(state.name, "design this change")

		-- Provider errors preserve the fallback.
		local remove_error = service.register(nil, ctx, {
			id = "errors",
			automatic = "all-prompts",
			generate = function()
				error("failed")
			end,
		})
		service.refresh()
		drain()
		expect.eq(service.get().metadata.source, "fallback")
		remove_error()
	end)

	it("validates llm responses, plugin config, session flags, and routing", function()
		local cfg = support.default_config(plugin)
		cfg.automatic = "all-prompts"
		local generate = require("session_title.llm")(ctx, cfg, text_mod)
		for _, bad_response in ipairs({
			{ stop_reason = "length", content = { { type = "text", text = "truncated" } } },
			{
				stop_reason = "stop",
				content = { { type = "tool_use", name = "bad" }, { type = "text", text = "bad" } },
			},
			{ stop_reason = "stop", content = {} },
		}) do
			response = bad_response
			expect.error(function()
				generate.generate({
					messages = { { id = "1", text = "hello" } },
					model = ctx.llm:current(),
					cancel = mare.task.token(),
				})
			end)
		end

		for _, bad in ipairs({
			{ model = "m" },
			{ provider = "p" },
			{ provider = "", model = "m" },
			{ provider = "p", model = " " },
		}) do
			local c = clone(cfg)
			for k, v in pairs(bad) do
				c[k] = v
			end
			expect.error(function()
				plugin.apply(ctx, c)
			end)
		end

		local oversized = clone(cfg)
		oversized.max_input_bytes = 1
		local bounded = require("session_title.llm")(ctx, oversized, text_mod)
		expect.error(function()
			bounded.generate({ messages = { { id = "1", text = "long input" } }, model = ctx.llm:current() })
		end)

		expect.eq(plugin.config_schema.timeout_ms.max, 2147483647)

		for _, flag in ipairs({ "readonly", "ephemeral", "unstable" }) do
			state[flag] = true
			local ok_ref, err_ref = pcall(service.refresh)
			expect.falsy(ok_ref)
			expect.eq(err_ref and err_ref.code, "session_title.title_unavailable")
			notices = {}
			cmd.run("refresh")
			expect.truthy(notices[#notices] and notices[#notices].level == "warning")
			state[flag] = nil
		end

		local saved_entries = entries
		entries = {}
		local ok_empty, err_empty = pcall(service.refresh)
		expect.falsy(ok_empty)
		expect.eq(err_empty and err_empty.code, "session_title.title_unavailable")
		entries = saved_entries

		mare.agent_id = "child"
		expect.falsy((pcall(service.refresh)))
		mare.agent_id = nil

		-- Explicit provider/model route resolves via ctx.llm:resolve and missing model errors.
		local resolved_spec
		local route_cfg = clone(cfg)
		route_cfg.provider, route_cfg.model = "anthropic", "claude-haiku"
		local old_resolve = ctx.llm.resolve
		ctx.llm.resolve = function(_, spec)
			resolved_spec = spec
			return { ref = spec, efforts = { "low" } }
		end
		response = { stop_reason = "stop", content = { { type = "text", text = "Routed Title" } } }
		local routed = require("session_title.llm")(ctx, route_cfg, text_mod).generate({
			id = "s1",
			messages = { { id = "1", text = "hello" } },
			cancel = mare.task.token(),
		})
		expect.eq(resolved_spec, "anthropic/claude-haiku")
		expect.eq(routed.model, "anthropic/claude-haiku")
		expect.eq(routed.title, "Routed Title")
		ctx.llm.resolve = old_resolve

		expect.error(function()
			require("session_title.llm")(ctx, cfg, text_mod).generate({
				id = "s1",
				messages = { { id = "1", text = "hello" } },
				cancel = mare.task.token(),
			})
		end)
	end)

	it("handles rename validation, /title command routing, and coalesced refresh", function()
		expect.falsy((pcall(service.rename, nil, nil, nil)))
		expect.falsy((pcall(service.rename, nil, nil, "   \n\t  ")))
		state.readonly = true
		expect.falsy((pcall(service.rename, nil, nil, "Blocked")))
		state.readonly = nil

		expect.truthy(service.rename(nil, nil, "Initial Title"))
		notices = {}
		cmd.run("")
		expect.eq(notices[#notices].msg, "Initial Title")
		expect.eq(notices[#notices].level, "info")

		cmd.run("unknown")
		expect.match(notices[#notices].msg, "Usage:")
		expect.eq(notices[#notices].level, "warning")

		cmd.run("rename   ")
		expect.eq(notices[#notices].level, "warning")

		cmd.run("rename Via Command")
		expect.eq(state.name, "Via Command")
		cmd.run("cancel")

		-- Re-register a provider to verify coalesced refresh vs force=true and session/loaded.
		disposers[1]()
		input("anchor prompt")
		drain()

		local gen_calls = 0
		local remove_coalesce = service.register(nil, ctx, {
			id = "coalesce",
			automatic = "all-prompts",
			generate = function()
				gen_calls = gen_calls + 1
				return { title = "Title " .. gen_calls }
			end,
		})
		service.refresh()
		service.refresh()
		expect.eq(service.get().metadata.source, "fallback")
		service.refresh(nil, nil, { force = true })
		drain()
		expect.eq(gen_calls, 2)
		expect.eq(state.name, "Title 2")

		-- Re-applying on the same session recovers recorded metadata from session:records
		local rec_cfg = support.default_config(plugin)
		rec_cfg.automatic = "all-prompts"
		plugin.apply(ctx, rec_cfg)
		expect.eq(service.get().metadata.source, "provider")

		events["session/loaded"]()
		expect.eq(changed_events[#changed_events].reason, "provider")
		remove_coalesce()
	end)

	it("normalizes text, slices fallback titles, and parses llm responses", function()
		local cleaned =
			text_mod.normalize("a\x1b[2m\226\128\174\226\129\166\226\128\139\239\187\191\194\133\194\173  b\nc\t", 20)
		expect.falsy(cleaned:find("\226\128\174", 1, true))
		expect.falsy(cleaned:find("\226\129\166", 1, true))
		expect.falsy(cleaned:find("\226\128\139", 1, true))
		expect.falsy(cleaned:find("\239\187\191", 1, true))
		expect.falsy(cleaned:find("\194\133", 1, true))
		expect.falsy(cleaned:find("\194\173", 1, true))
		expect.falsy(cleaned:find("\x1b", 1, true))

		expect.eq(text_mod.fallback("one two three four", 2, 100), "one two")
		expect.eq(
			text_mod.fallback("Fix the **login**\n[timeout](https://example.test/issue)", 8, 80),
			"Fix the login timeout"
		)
		expect.eq(text_mod.fallback("# Fix `auth.rs`", 8, 80), "Fix auth.rs")
		expect.eq(text_mod.fallback("a * b * c and foo_bar_baz", 8, 80), "a * b * c and foo_bar_baz")
		expect.eq(text_mod.fallback(string.rep(" ", 5000) .. "late first word", 8, 80), "late first word")

		expect.eq(
			text_mod.response(
				{ stop_reason = "stop", content = { { type = "text", text = "\n  **Bold Title**  \nsecond line" } } },
				100
			),
			"Bold Title"
		)
		expect.eq(
			text_mod.response({ stop_reason = "stop", content = { { type = "text", text = "'Quoted Title'" } } }, 100),
			"Quoted Title"
		)

		for _, pair in ipairs({
			{ '"Fix login errors!"', "Fix login errors" },
			{ "'Fix login errors?'", "Fix login errors" },
			{ "`Fix login errors.`", "Fix login errors" },
			{ "\226\128\156Fix login errors!\226\128\157", "Fix login errors" },
			{ "\226\128\152Fix login errors?\226\128\153", "Fix login errors" },
			{ "*Single Emphasis*", "Single Emphasis" },
			{ "***Triple Emphasis***", "Triple Emphasis" },
			{ "**A** and **B**", "**A** and **B**" },
			{ ".NET migration.", ".NET migration" },
			{ "!important styling!", "!important styling" },
		}) do
			expect.eq(
				text_mod.response({ stop_reason = "stop", content = { { type = "text", text = pair[1] } } }, 100),
				pair[2]
			)
		end

		for _, blank in ipairs({ "...", '""', "\226\128\139" }) do
			expect.falsy(
				text_mod.response({ stop_reason = "stop", content = { { type = "text", text = blank } } }, 100)
			)
		end

		expect.falsy(text_mod.response({
			stop_reason = "stop",
			content = { { type = "tool_call", name = "x" }, { type = "text", text = "bad" } },
		}, 100))
	end)

	it("enforces first-prompt strategy, invisible/attachment skips, and cancel before launch", function()
		state = { id = "fp", generation = "1", revision = "0" }
		entries, tasks, calls, captured = {}, {}, 0, nil
		local fp_cfg = support.default_config(plugin)
		fp_cfg.automatic = "first-prompt"
		plugin.apply(ctx, fp_cfg)

		input("first prompt text")
		drain()
		expect.eq(calls, 1)
		expect.eq(state.name, "Generated title")
		expect.falsy(captured.system:find("exactly, unchanged", 1, true))

		input("second prompt text")
		drain()
		expect.eq(calls, 1)

		state = { id = "skip", generation = "1", revision = "0" }
		entries, tasks, calls, captured = {}, {}, 0, nil
		local all_cfg = support.default_config(plugin)
		all_cfg.automatic = "all-prompts"
		plugin.apply(ctx, all_cfg)

		local invisible_msg = {
			role = "user",
			input_source = "user",
			content = { { type = "text", text = "\226\128\139\226\128\174  " } },
		}
		entries[#entries + 1] = { entry_id = "invis", message = invisible_msg }
		events["item/completed"]({ item = { type = "user_message", message = invisible_msg } })
		drain()
		expect.eq(state.name, nil)
		expect.eq(calls, 0)

		input("real topic")
		drain()
		expect.eq(calls, 1)
		expect.eq(state.name, "Generated title")

		local attach_only = {
			role = "user",
			input_source = "user",
			input_content = { { type = "file", path = "a.txt", text = "body" } },
			content = { { type = "text", text = "<file>body</file>" } },
		}
		entries[#entries + 1] = { entry_id = "attach2", message = attach_only }
		events["item/completed"]({ item = { type = "user_message", message = attach_only } })
		events["request/build"]({ model = ctx.llm:current() })
		drain()
		expect.eq(calls, 1)

		local msg3 = { role = "user", input_source = "user", content = { { type = "text", text = "pending build" } } }
		entries[#entries + 1] = { entry_id = "m3", message = msg3 }
		events["item/completed"]({ item = { type = "user_message", message = msg3 } })
		events["request/build"]({ model = ctx.llm:current() })
		service.cancel()
		drain()
		expect.eq(calls, 1)
	end)

	it("degrades gracefully when core session.get and update are unavailable", function()
		local logs = {}
		local provided = {}
		local d_commands = {}
		local d_events = {}
		mare.log = function(level, msg)
			logs[#logs + 1] = { level = level, msg = msg }
		end
		local d_ctx = {
			session = {
				info = function()
					return { session_id = "s-degraded", session_epoch = "1" }
				end,
				path_to = function()
					return {}
				end,
			},
			llm = ctx.llm,
			commands = {
				register = function(_, name, def)
					d_commands[name] = def
				end,
			},
			provide = function(_, name, svc)
				provided[name] = svc
			end,
			on = function(_, name, fn)
				d_events[name] = fn
			end,
			effect = function(_, setup)
				setup()
			end,
		}

		plugin.apply(d_ctx, support.default_config(plugin))
		expect.eq(#logs, 1)
		expect.eq(logs[1].level, "warn")

		local svc = provided.session_title
		expect.truthy(svc)
		expect.eq(svc.get(), nil)

		local ok_ref, err_ref = pcall(svc.refresh)
		expect.falsy(ok_ref)
		expect.truthy(err_ref)

		local ok_ren, err_ren = pcall(svc.rename, nil, nil, "x")
		expect.falsy(ok_ren)
		expect.truthy(err_ren)

		local unreg = svc.register(function() end)
		expect.eq(type(unreg), "function")
		unreg()

		expect.eq(svc.cancel(), false)
		expect.eq(d_commands.title, nil)
		expect.eq(d_events["session/named"], nil)

		-- Second apply in the same process should not repeat the one-time notice.
		plugin.apply(d_ctx, support.default_config(plugin))
		expect.eq(#logs, 1)
	end)

	it("skips path_to when user-pinned or first-prompt already provider-titled and short-circuits scan", function()
		state = { id = "pin-perf", generation = "1", revision = "0" }
		entries, tasks, calls, captured = {}, {}, 0, nil
		local path_to_calls = 0
		local orig_path_to = ctx.session.path_to
		ctx.session.path_to = function(...)
			path_to_calls = path_to_calls + 1
			return orig_path_to(...)
		end

		local fp_cfg = support.default_config(plugin)
		fp_cfg.automatic = "first-prompt"
		plugin.apply(ctx, fp_cfg)

		-- Pin title by user on message 1.
		service.rename(nil, nil, "Pinned Title")
		path_to_calls = 0

		for i = 1, 100 do
			input("user message " .. i)
		end
		drain()
		expect.eq(path_to_calls, 0)
		expect.eq(calls, 0)
		expect.eq(state.name, "Pinned Title")

		-- Provider-titled session under first-prompt also skips path_to on subsequent messages.
		state = { id = "prov-perf", generation = "1", revision = "0" }
		entries, tasks, calls, captured = {}, {}, 0, nil
		plugin.apply(ctx, fp_cfg)
		input("first prompt")
		drain()
		expect.eq(calls, 1)
		expect.eq(service.get().metadata.source, "provider")
		path_to_calls = 0
		for i = 1, 20 do
			input("follow up " .. i)
		end
		drain()
		expect.eq(path_to_calls, 0)
		expect.eq(calls, 1)

		-- Fallback-only session stops scanning path_to on the 2nd qualifying user input.
		state = { id = "fb-stop", generation = "1", revision = "0" }
		entries, tasks, calls, captured = {}, {}, 0, nil
		local fb_cfg = support.default_config(plugin)
		fb_cfg.automatic = "first-prompt"
		fb_cfg.llm = false
		plugin.apply(ctx, fb_cfg)
		input("first fallback prompt")
		drain()
		expect.truthy(state.name)
		-- Register a first-prompt custom provider after fallback set the title.
		local unreg = service.register(nil, ctx, {
			id = "custom-fp",
			automatic = "first-prompt",
			generate = function()
				return { title = "Should not run" }
			end,
		})
		local inspected = 0
		local backing = {
			{
				entry_id = "1",
				message = { role = "user", input_source = "user", content = { { type = "text", text = "one" } } },
			},
			{
				entry_id = "2",
				message = { role = "user", input_source = "user", content = { { type = "text", text = "two" } } },
			},
		}
		for i = 3, 100 do
			backing[i] = {
				entry_id = tostring(i),
				message = { role = "user", input_source = "user", content = { { type = "text", text = "m" .. i } } },
			}
		end
		-- Wrap ipairs iteration via custom array proxy? Use a metatable with __len/__index on entries?
		-- Lua 5.4 ipairs honors __index, so count reads on indices >= 3.
		local proxy = setmetatable({}, {
			__index = function(_, k)
				if type(k) == "number" and k >= 3 and backing[k] then
					inspected = inspected + 1
				end
				return backing[k]
			end,
		})
		ctx.session.path_to = function()
			path_to_calls = path_to_calls + 1
			return proxy
		end
		path_to_calls = 0
		events["item/completed"]({ item = { type = "user_message", message = backing[2].message } })
		drain()
		expect.eq(path_to_calls, 1)
		expect.eq(inspected, 0)
		unreg()
		ctx.session.path_to = orig_path_to

		-- all-prompts must pass all 3+ eligible messages (never truncate to 2 via `nil or 2`).
		state = { id = "all-3plus", generation = "1", revision = "0" }
		entries, tasks, calls, captured = {}, {}, 0, nil
		local seen_ids = {}
		local all_cfg = support.default_config(plugin)
		all_cfg.automatic = "all-prompts"
		all_cfg.llm = false
		plugin.apply(ctx, all_cfg)
		local unreg_all = service.register(nil, ctx, {
			id = "custom-all",
			automatic = "all-prompts",
			generate = function(work)
				seen_ids = {}
				for _, m in ipairs(work.messages) do
					seen_ids[#seen_ids + 1] = m.id
				end
				return { title = "Title " .. tostring(#work.messages), message_ids = seen_ids }
			end,
		})
		input("first prompt")
		drain()
		input("second prompt")
		drain()
		input("third prompt")
		drain()
		expect.eq(#seen_ids, 3)
		expect.eq(seen_ids[1], "1")
		expect.eq(seen_ids[2], "2")
		expect.eq(seen_ids[3], "3")
		expect.eq(state.name, "Title 3")
		unreg_all()
	end)

	it(
		"projects secrets before truncation, passes current=true for records, fences cross-session commits, and skips meta cache on record failure",
		function()
			-- Secret value overlapping truncation boundary must be projected BEFORE slicing
			local orig_proj = mare.projection
			local secret = "SECRET_TOKEN_XYZ_123456"
			mare.projection = {
				project = function(s)
					return (s:gsub(secret, "[REDACTED]"))
				end,
			}
			local raw_prompt = string.rep("a", 20) .. secret .. " tail"
			local norm = text_mod.normalize(raw_prompt, 32)
			mare.projection = orig_proj
			expect.falsy(norm:find("SECRET_TOKEN", 1, true))
			expect.truthy(norm:find("[REDACTED", 1, true))

			-- { branch = "current" } passed to ctx.session.list_records; add_record failure does not poison recorded_meta; session fence stops stale commit
			local records_opts = {}
			local allow_record = false
			local orig_records = ctx.session.list_records
			local orig_record = ctx.session.add_record
			ctx.session.list_records = function(self, kind, opts)
				records_opts[#records_opts + 1] = { kind = kind, opts = opts }
				return orig_records(self, kind, opts)
			end
			ctx.session.add_record = function(self, kind, data, opts)
				if kind == "session-title/state" and not allow_record then
					error("readonly", 0)
				end
				return orig_record(self, kind, data, opts)
			end

			state = { id = "s-cur", generation = "1", revision = "1", name = "Resumed Title" }
			entries, tasks, calls, captured = {}, {}, 0, nil
			local cfg = support.default_config(plugin)
			cfg.automatic = "first-prompt"
			plugin.apply(ctx, cfg)
			service.get(nil, ctx)
			expect.truthy(
				#records_opts >= 1
					and records_opts[#records_opts].opts
					and records_opts[#records_opts].opts.branch == "current"
			)

			-- When record fails, rename reports persistence failure and recorded_meta is NOT updated
			expect.error(function()
				service.rename(nil, ctx, "First Title")
			end, "failed to persist title metadata")
			local meta_count = 0
			for _, r in ipairs(records_store) do
				if r.kind == "session-title/state" then
					meta_count = meta_count + 1
				end
			end
			expect.eq(meta_count, 0)

			allow_record = true
			expect.eq(service.rename(nil, ctx, "Second Title"), true)
			for _, r in ipairs(records_store) do
				if r.kind == "session-title/state" then
					meta_count = meta_count + 1
				end
			end
			expect.eq(meta_count, 1)

			-- Cross-session fence: changing session mid-stream drops stale commit; fallback_task respects cancel()
			state = { id = "s-fence-1", generation = "1", revision = "0" }
			entries, tasks, calls = {}, {}, 0
			plugin.apply(ctx, cfg)
			stream_hook = function()
				state = { id = "s-fence-2", generation = "1", revision = "0" }
				events["session/changed"]({})
			end
			input("fence test prompt")
			drain()
			stream_hook = nil
			expect.eq(state.name, nil)

			-- fallback_task cancelled before running does not write fallback title
			state = { id = "s-fb-cancel", generation = "1", revision = "0" }
			entries, tasks, calls = {}, {}, 0
			local fb_cfg = support.default_config(plugin)
			fb_cfg.llm = false
			plugin.apply(ctx, fb_cfg)
			local msg =
				{ role = "user", input_source = "user", content = { { type = "text", text = "fallback cancel" } } }
			entries[#entries + 1] = { entry_id = "fb1", message = msg }
			events["item/completed"]({ item = { type = "user_message", message = msg } })
			service.cancel()
			drain()
			expect.eq(state.name, nil)

			ctx.session.list_records = orig_records
			ctx.session.add_record = orig_record
		end
	)
end)
