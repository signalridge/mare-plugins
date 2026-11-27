local support = assert(load(mare.fs.read("tests/specs/support.lua"), "@tests/specs/support.lua"))()
local H = support.load_lua("tests/specs/presets_support.lua")

local describe = mare.test.describe
local it = mare.test.it
local before_each = mare.test.before_each
local after_each = mare.test.after_each
local expect = mare.test.expect

describe("presets", function()
	local orig_connected, orig_select, orig_notify

	before_each(function()
		orig_connected = mare.ui.connected
		orig_select = mare.ui.select
		orig_notify = mare.ui.notify
		H.clear_persisted_state()
	end)

	after_each(function()
		mare.ui.connected = orig_connected
		mare.ui.select = orig_select
		mare.ui.notify = orig_notify
		H.clear_persisted_state()
	end)

	it("uses the subagent type registry for selection and observes withdrawals", function()
		local f =
			H.fixture({ reviewer = { description = "Review changes", system = "review guidance", tools = { "read" } } })
		expect.truthy(f.types.reviewer)
		expect.eq(f.types.reviewer.description, "Review changes")
		expect.eq(f.types.reviewer.system, "review guidance")
		local release =
			f.subagent:register_type({ name = "external", description = "External", system = "external guidance" })
		f.command("external")
		expect.eq(f.service.current().id, "external")
		expect.truthy(f:prompt():find("external guidance", 1, true))
		release()
		f.command("external")
		expect.eq(f:last().level, "error")
	end)

	it("preset definitions override discovered types and restore them on disposal", function()
		local initial = { explore = { name = "explore", description = "builtin", system = "builtin prompt" } }
		local f = H.fixture(
			{ explore = { description = "custom", system = "custom prompt" } },
			nil,
			{ initial_types = initial }
		)
		expect.eq(f.types.explore.description, "custom")
		f.command("explore")
		expect.truthy(f:prompt():find("custom prompt", 1, true))
		f.dispose()
		expect.eq(f.types.explore.description, "builtin")
	end)

	it("lists and opens the picker from one registry snapshot per operation", function()
		local f = H.fixture({ a = { default = true }, b = {}, c = {} })
		f.list_type_calls = 0
		f.command("list")
		expect.eq(f.list_type_calls, 1)
		f.connected, f.pick, f.list_type_calls = true, nil, 0
		f.command("")
		expect.eq(f.list_type_calls, 1)
	end)

	it("fails explicitly without ctx.llm:constrain_tools", function()
		expect.error(function()
			H.fixture(nil, nil, { with_constrain_tools = false })
		end, "constrain_tools")
	end)

	it(
		"applies idle/prompt/constraint state and rejects busy, switching, readonly, missing, and error paths",
		function()
			local f = H.fixture()
			expect.eq(#f.sections, 0)
			expect.eq(f.suppress_count, 0)

			f.command("review")
			expect.eq(f:last().level, "info")
			expect.truthy(f:prompt():find("review {{literal}}", 1, true))
			expect.eq(#f.sections, 1)
			expect.eq(f.sections[1].interpolate, false)
			expect.eq(#f.constraint(), 1)
			expect.eq(f.constraint()[1], "read")

			f.busy = true
			f.command("none")
			expect.eq(f:last().level, "error")
			expect.eq(#f.constraint(), 1)
			f.busy = false

			f.switching = true
			f.command("none")
			expect.eq(f:last().level, "error")
			f.switching = false

			f.readonly = true
			f.command("none")
			expect.eq(f:last().level, "error")
			f.readonly = false

			f.command("missing")
			expect.eq(f:last().level, "error")
			f.command("unknown")
			expect.eq(f:last().level, "error")

			f.command("none")
			expect.eq(#f.constraint(), 0)
			expect.eq(#f.sections, 0)
			expect.falsy(f:prompt():find("review", 1, true))

			f.command("all")
			expect.eq(f.constraint(), nil)
			expect.eq(#f.sections, 1)
			expect.truthy(f:prompt():find("all tools", 1, true))

			f.complete = true
			f.command("review")
			expect.eq(f:last().level, "error")
			f.complete = false
			expect.truthy(f:prompt():find("all tools", 1, true))

			f.prompt_error = true
			f.command("review")
			expect.eq(f:last().level, "error")
			f.prompt_error = false
			expect.truthy(f:prompt():find("all tools", 1, true))

			f.command("clear")
			expect.eq(f.constraint(), nil)
			expect.eq(#f.sections, 0)
			expect.eq(f.suppress_count, 0)
			expect.eq(f:prompt(), "base")
		end
	)

	it("handles persona prefix/suffix, runtime suppression, complete, and preview conflict rejection", function()
		local f = H.fixture()
		f.command("persona_only")
		expect.eq(f:last().level, "info")
		expect.eq(f.suppress_count, 1)
		expect.eq(#f.sections, 2)
		expect.truthy(f:prompt():find("You are orig-id helper.", 1, true))
		expect.truthy(f:prompt():find("Always be concise.", 1, true))

		f.command("bad_var")
		expect.eq(f:last().level, "error")
		expect.eq(f.service.current().id, "persona_only")
		expect.eq(f.suppress_count, 1)

		f.shadowed = "persona"
		f.command("complete_persona")
		expect.eq(f:last().level, "error")
		expect.eq(f.service.current().id, "persona_only")
		f.shadowed = nil

		f.complete = true
		f.command("complete_persona")
		expect.eq(f:last().level, "error")
		expect.eq(f.service.current().id, "persona_only")
		f.complete = false

		f.unpreserved = true
		f.command("complete_persona")
		expect.eq(f:last().level, "error")
		expect.eq(f.service.current().id, "persona_only")
		f.unpreserved = false

		f.command("complete_persona")
		expect.eq(f:last().level, "info")
		expect.eq(f.suppress_count, 0)
		expect.eq(#f.sections, 1)
		expect.eq(f.sections[1].complete, true)
		expect.truthy(f:prompt():find("Complete orig-id persona.", 1, true))

		f.command("clear")
		expect.eq(#f.sections, 0)
		expect.eq(f.suppress_count, 0)
	end)

	it("applies tool glob and denylist constraints and cleans up on generation change and dispose", function()
		local f = H.fixture()
		f.command("glob_deny")
		expect.eq(#f.constraint(), 1)
		expect.eq(f.constraint()[1], "read")

		f.command("deny_only")
		local denied = f.constraint()
		expect.eq(#denied, 2)
		expect.eq(denied[1], "read")
		expect.eq(denied[2], "read_file")
		f.command("clear")

		f.command("persona_only")
		expect.eq(#f.sections, 2)
		expect.eq(f.suppress_count, 1)
		f.generation = "two"
		expect.eq(f.constraint(), nil)
		expect.eq(f:prompt(), "base")
		expect.eq(#f.sections, 0)
		expect.eq(f.suppress_count, 0)

		f.command("review")
		f.generation = "three"
		f.hooks["session/changed"]()
		expect.eq(f:prompt(), "base")
		expect.eq(#f.sections, 0)

		f.swap = true
		f.command("review")
		expect.eq(f:last().level, "error")
		expect.eq(f.constraint(), nil)
		expect.eq(#f.sections, 0)
		f.swap = false

		f.command("persona_only")
		expect.eq(#f.sections, 2)
		expect.eq(f.suppress_count, 1)
		f.dispose()
		expect.eq(#f.sections, 0)
		expect.eq(f.suppress_count, 0)
	end)

	it("keeps legacy tool globs current as tools are registered", function()
		local f = H.fixture()
		f.command("glob_deny")
		f.available_tools[#f.available_tools + 1] = "read_added_later"
		local allowed = f.constraint()
		expect.eq(#allowed, 2)
		expect.eq(allowed[1], "read")
		expect.eq(allowed[2], "read_added_later")
	end)

	it("selects models with original alias, handles setter failure, and rejects invalid definitions", function()
		local m = H.fixture()
		m.command("selected")
		expect.eq(m:last().level, "info")
		expect.eq(m.model, m.alternate)
		expect.eq(m.calls[1], "alias-high")
		expect.eq(m.saved, "alias-high")
		expect.eq(m.recent[1], "alias-high")
		expect.eq(m.effort, "high")
		expect.truthy(m:prompt():find("selected guidance", 1, true))

		m.command("clear")
		expect.eq(m.model, m.alternate)
		expect.eq(#m.calls, 1)
		expect.eq(m:prompt(), "base")

		m.command("unknown_model")
		expect.eq(m:last().level, "error")
		expect.truthy(m:last().text:find("Unknown preset model", 1, true))
		expect.eq(#m.calls, 1)

		m.command("review")
		m.setter_failure = true
		m.command("selected")
		expect.eq(m:last().level, "error")
		expect.truthy(m:last().text:find("no rollback", 1, true))
		expect.eq(#m.calls, 2)
		expect.eq(m.model, m.alternate)
		expect.truthy(m:prompt():find("review", 1, true))
		m.setter_failure = false

		-- Context rejection happens before the setter and does not report success.
		m.complete = true
		m.command("selected")
		expect.eq(m:last().level, "error")
		expect.eq(#m.calls, 2)

		for _, bad in ipairs({
			{ x = { model = false } },
			{ x = { permissions = "full-access" } },
			{ x = { tools = { [2] = "read" } } },
			{ x = { tools = { false } } },
			{ x = { denylist = { 123 } } },
			{ x = { complete = true } },
			{ x = { includeRuntimeContext = "no" } },
			{ clear = {} },
			{ list = {} },
			{ inspect = {} },
			{ default = {} },
			{ stage = {} },
			{ help = {} },
		}) do
			local invalid = H.fixture(bad)
			expect.eq(#invalid.subagent:list_types().data, 0)
			invalid.command("list")
			expect.truthy(invalid:last().text:find("broken", 1, true))
		end
	end)

	it("manages roster, dynamic registration, and interactive picker", function()
		local roster = H.fixture({ good = { name = "Good", order = -1, default = true }, broken = { model = false } })
		expect.eq(roster.subagent:list_types().data[1].name, "good")
		roster.command("list")
		expect.truthy(roster:last().text:find("Good [good] (default)", 1, true))
		expect.truthy(roster.service.stage(nil, nil, "good"))
		expect.eq(roster.service.staged().id, "good")

		local detached = roster.subagent:list_types().data[1]
		detached.name = "mutated"
		expect.eq(roster.subagent:list_types().data[1].name, "good")

		local remove = roster.subagent:register_type({
			name = "runtime",
			description = "Runtime",
			system = "retained revision",
			tools = {},
		})
		expect.error(function()
			roster.subagent:register_type({ name = "runtime", description = "duplicate" })
		end)
		expect.truthy(roster.service.select(nil, nil, "runtime"))
		expect.eq(#roster.constraint(), 0)
		remove()
		local ok_select, err_select = pcall(roster.service.select, nil, nil, "runtime")
		expect.falsy(ok_select)
		expect.eq(err_select.code, "presets.unknown_preset")
		expect.eq(roster.service.current().id, nil)
		expect.falsy(roster:prompt():find("retained revision", 1, true))

		H.clear_persisted_state()
		local picker = H.fixture({
			a = { name = "First", system = "first prompt", default = true },
			b = { name = "Second", system = "second prompt" },
		})
		expect.eq(picker.command("").status, "rejected")
		picker.connected, picker.pick = true, 2
		picker.command("")
		expect.eq(picker.service.current().id, "b")
		expect.eq(#picker.dialog.items, 2)
		expect.eq(picker.dialog.items[1].label, "First (default)")
		expect.eq(picker.dialog.items[2].label, "Second")
		expect.match(mare.json.encode(picker.dialog.items[2].preview), "second prompt")

		expect.truthy(picker.service.set_default(nil, nil, "b"))
		picker.command("list")
		expect.truthy(picker:last().text:find("Second [b] (current) (default)", 1, true))

		picker.pick = nil
		expect.eq(picker.command("").status, "cancelled")
		expect.eq(picker.service.current().id, "b")
		expect.eq(picker.dialog.items[2].label, "Second (current) (default)")

		picker.pick = 1
		picker.picker_hook = function()
			picker.generation = "changed while choosing"
		end
		expect.eq(picker.command("").status, "rejected")
		expect.eq(picker.service.current().id, nil)
	end)

	it(
		"refreshes wildcard subagent tools/denylist on catalog change, handles nil select/model, and unpacks 4-tuple select",
		function()
			local dyn = H.fixture({
				no_mcp = { system = "No MCP", denylist = { "mcp__*" } },
				only_mcp = { system = "Only MCP", tools = { "mcp__*" } },
			})
			expect.eq(#dyn.types.no_mcp.disallowed_tools, 0)
			expect.eq(#dyn.types.only_mcp.tools, 0)

			dyn.command("no_mcp")
			expect.eq(dyn.service.current().id, "no_mcp")

			-- Late MCP tool registration triggers dynamic refresh without clearing active preset.
			dyn.available_tools[#dyn.available_tools + 1] = "mcp__github_search"
			dyn.hooks["mcp/ready"]({})
			expect.truthy((dyn.tool_revision_calls or 0) > 0)
			expect.eq(dyn.types.no_mcp.disallowed_tools[1], "mcp__github_search")
			expect.eq(dyn.types.only_mcp.tools[1], "mcp__github_search")
			expect.eq(dyn.service.current().id, "no_mcp")

			-- select(nil) clears active preset.
			expect.eq(dyn.service.select(nil, nil, nil), true)
			expect.eq(dyn.service.current().id, nil)

			-- Model-less preset succeeds with boolean true & info notice when llm:current() == nil.
			dyn.model = nil
			expect.eq(dyn.service.select(nil, nil, "no_mcp"), true)
			expect.eq(dyn.service.current().id, "no_mcp")
			expect.eq(dyn.command("only_mcp"), nil)
			expect.eq(dyn:last().level, "info")

			-- 4-tuple mare.ui.select returns reason in slot #2.
			dyn.connected = true
			mare.ui.select = function()
				return nil, "unavailable"
			end
			local res = dyn.command("")
			expect.eq(res.status, "rejected")
			expect.eq(res.reason, "unavailable")
		end
	)
end)
