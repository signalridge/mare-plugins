local support = assert(load(mare.fs.read("tests/specs/support.lua"), "@tests/specs/support.lua"))()

local describe = mare.test.describe
local it = mare.test.it
local before_each = mare.test.before_each
local after_each = mare.test.after_each
local expect = mare.test.expect

local plugin = support.load_plugin("ask_user_question", {
	"ask_user_question.schema",
	"ask_user_question.validate",
	"ask_user_question.text",
	"ask_user_question.editor",
	"ask_user_question.questions",
	"ask_user_question.runtime",
})
local schema = require("ask_user_question.schema")
local validate = require("ask_user_question.validate").validate
local runtime_mod = require("ask_user_question.runtime")

local function base_q(overrides)
	local q = {
		id = "q1",
		header = "Target",
		question = "Which target?",
		options = {
			{ label = "Alpha", description = "First", recommended = true, preview = "preview" },
			{ label = "Beta", description = "Second" },
		},
	}
	for k, v in pairs(overrides or {}) do
		q[k] = v
	end
	return q
end

describe("ask_user_question", function()
	local events, disposers, tool
	local session_info, stored_records
	local record_should_nil, save_should_fail
	local ui_responders, select_fn, input_fn, notices
	local orig_mode, orig_can_respond, orig_select, orig_input, orig_notify
	local ctx

	local function run_tool(qs, steps, tctx)
		local idx = 0
		select_fn = function(opts)
			idx = idx + 1
			local step = assert(steps[idx], "unexpected select: " .. tostring(opts.title))
			if step.check then
				step.check(opts)
			end
			if step.disconnect then
				ui_responders = false
			end
			if step.cancel then
				tctx.cancel:cancel()
			end
			if step.raw ~= nil then
				return step.raw, step.reason
			end
			if step.reason then
				return nil, step.reason
			end
			if step.index then
				return step.index
			end
			for i, row in ipairs(opts.items) do
				local label = type(row) == "string" and row or row.label
				if label:find(step.label, 1, true) then
					expect.falsy(type(row) ~= "string" and row.disabled, "clicked disabled row: " .. label)
					return i
				end
			end
			error("missing row " .. tostring(step.label))
		end
		input_fn = function(opts)
			idx = idx + 1
			local step = assert(steps[idx], "unexpected input: " .. tostring(opts.title))
			if step.reason then
				return nil, step.reason
			end
			return step.text
		end
		local res = tool.execute({ questions = qs }, tctx)
		expect.eq(idx, #steps)
		return res
	end

	before_each(function()
		events, disposers, tool = {}, {}, nil
		session_info = { session_id = "s1", session_epoch = "g1", ephemeral = false, readonly = false }
		stored_records = {}
		record_should_nil, save_should_fail = false, false
		ui_responders = true
		select_fn, input_fn = nil, nil
		notices = {}

		orig_mode = mare.mode
		orig_can_respond = mare.ui.can_respond
		orig_select = mare.ui.select
		orig_input = mare.ui.input
		orig_notify = mare.ui.notify

		mare.mode = "main"
		mare.ui.can_respond = function()
			return ui_responders
		end
		mare.ui.select = function(opts)
			return select_fn(opts)
		end
		mare.ui.input = function(opts)
			return input_fn(opts)
		end
		mare.ui.notify = function(msg, level)
			notices[#notices + 1] = { msg = msg, level = level }
		end

		ctx = {
			tools = {
				register = function(_, name, def)
					expect.eq(name, "ask_user_question")
					tool = def
				end,
			},
			session = {
				info = function()
					return session_info
				end,
				list_records = function(_, kind, opts)
					expect.eq(kind, "ask-user/draft")
					if record_should_nil then
						return nil
					end
					local out = {}
					for _, rec in ipairs(stored_records) do
						if
							(not opts or not opts.session_id or rec.session_id == opts.session_id)
							and (not opts or not opts.session_epoch or rec.session_epoch == opts.session_epoch)
						then
							out[#out + 1] = rec.data
						end
					end
					return { data = out }
				end,
				add_record = function(_, kind, data, opts)
					expect.eq(kind, "ask-user/draft")
					expect.truthy(opts and opts.persist)
					if save_should_fail then
						error("disk write failed", 0)
					end
					stored_records[#stored_records + 1] = {
						session_id = opts.session_id,
						session_epoch = opts.session_epoch,
						data = data,
					}
					return { durable = true }
				end,
			},
			on = function(_, name, fn)
				events[name] = fn
			end,
			effect = function(_, setup)
				local fn = setup()
				disposers[#disposers + 1] = fn
			end,
		}
		plugin.apply(ctx)
	end)

	after_each(function()
		mare.mode = orig_mode
		mare.ui.can_respond = orig_can_respond
		mare.ui.select = orig_select
		mare.ui.input = orig_input
		mare.ui.notify = orig_notify
	end)

	it("registers tool metadata, schema invariants, and validates questions", function()
		expect.truthy(tool)
		expect.eq(tool.side_effect, "read")
		expect.eq(tool.timeout_ms, false)
		expect.truthy(tool.description:find("Empty selected with no custom means skipped", 1, true))
		expect.truthy(tool.description:find("empty answers with a note means dismissed", 1, true))

		expect.eq(schema.additionalProperties, false)
		expect.eq(schema.properties.questions.items.additionalProperties, false)
		expect.eq(schema.properties.questions.items.properties.options.items.additionalProperties, false)

		local bad_inputs = {
			"not a table",
			{},
			{
				base_q({ id = "1" }),
				base_q({ id = "2" }),
				base_q({ id = "3" }),
				base_q({ id = "4" }),
				base_q({ id = "5" }),
			},
			{ base_q(), base_q() },
			{ base_q({ id = "   " }) },
			{ base_q({ header = string.rep("h", 13) }) },
			{ base_q({ header = "\xff" }) },
			{ base_q({ multi_select = "yes" }) },
			{ base_q({ options = { { label = "Only", description = "1" } } }) },
			{ base_q({ options = {} }) },
			{ "not-a-table" },
			{ base_q({ options = { "a", "b" } }) },
			{ [1] = base_q({ id = "1" }), [3] = base_q({ id = "3" }) },
			{
				base_q({
					options = {
						{ label = "A", description = "1" },
						{ label = "B", description = "2" },
						{ label = "C", description = "3" },
						{ label = "D", description = "4" },
						{ label = "E", description = "5" },
					},
				}),
			},
			{ base_q({ options = { { label = "A", description = "1" }, { label = "A", description = "2" } } }) },
			{ base_q({ options = { { label = "A", description = "1" }, { label = " A ", description = "2" } } }) },
			{ base_q({ options = { { label = "A", description = "1" }, { label = "  Other ", description = "2" } } }) },
			{
				base_q({
					options = {
						{ label = "A", description = "1", preview = string.rep("p", 10001) },
						{ label = "B", description = "2" },
					},
				}),
			},
			{
				base_q({
					options = {
						{ label = "A", description = "1", recommended = true },
						{ label = "B", description = "2", recommended = true },
					},
				}),
			},
			{
				base_q({
					options = {
						{ label = "A", description = "1", recommended = "yes" },
						{ label = "B", description = "2" },
					},
				}),
			},
		}
		for _, bad in ipairs(bad_inputs) do
			expect.error(function()
				validate(bad)
			end)
		end

		local q_no_opts = base_q()
		q_no_opts.options = nil
		expect.error(function()
			validate({ q_no_opts })
		end)

		local bad_res = tool.execute({ questions = {} })
		expect.truthy(bad_res.is_error)
		expect.truthy(bad_res.content:find("1–4 questions", 1, true))

		local nil_res = tool.execute(nil)
		expect.truthy(nil_res.is_error)
		expect.truthy(nil_res.content:find("1–4 questions", 1, true))
	end)

	it("refuses child mode, missing UI responder, and review disconnect", function()
		mare.mode = "child"
		local child_res = tool.execute({ questions = { base_q() } })
		expect.truthy(child_res.is_error)
		expect.eq(child_res.details.error.code, "NO_PROVIDER")
		mare.mode = "main"

		ui_responders = false
		local no_ui_res = tool.execute({ questions = { base_q() } }, { execution_id = "exec-no-ui" })
		expect.truthy(no_ui_res.is_error)
		expect.eq(no_ui_res.details.error.code, "NO_PROVIDER")
		expect.eq(#stored_records, 0)
		ui_responders = true

		local step = 0
		select_fn = function(opts)
			step = step + 1
			if step == 1 then
				return 1
			end
			expect.eq(opts.title, "Review questions")
			ui_responders = false
			return nil
		end
		local disc_review = tool.execute({ questions = { base_q() } })
		expect.truthy(disc_review.is_error)
		expect.eq(disc_review.details.error.code, "DISCONNECTED")
	end)

	it("handles text editor, invalid UI answers, cancellation, and interruption", function()
		local text_res = run_tool({ base_q() }, {
			{ label = "Add notes" },
			{ text = string.rep("z", 10001) },
			{ label = "Other" },
			{ text = "first custom" },
			{ label = "Target — answered" },
			{ label = "Edit notes" },
			{ label = "Keep text" },
			{ label = "Edit notes" },
			{ label = "Replace text" },
			{ text = "   " },
			{
				label = "Alpha",
				check = function(opts)
					for _, row in ipairs(opts.items) do
						if row.label == "Done" then
							expect.truthy(row.disabled)
						end
					end
				end,
			},
			{ label = "Submit answers" },
		})
		expect.falsy(text_res.is_error)
		expect.eq(text_res.details.answers[1].selected[1], "Alpha")
		expect.eq(text_res.details.answers[1].custom, nil)
		expect.eq(#notices, 1)
		expect.eq(notices[1].level, "warning")

		local bad_ui = run_tool({ base_q() }, { { index = 99 } })
		expect.truthy(bad_ui.is_error)
		expect.eq(bad_ui.details.error.code, "BAD_ANSWER")

		local bad_review = run_tool({ base_q() }, { { label = "Alpha" }, { index = 99 } })
		expect.truthy(bad_review.is_error)
		expect.eq(bad_review.details.error.code, "BAD_ANSWER")

		local bad_skip_confirm = run_tool({ base_q() }, {
			{ label = "Skip this question" },
			{ label = "Submit answers" },
			{ index = 3 },
		})
		expect.truthy(bad_skip_confirm.is_error)
		expect.eq(bad_skip_confirm.details.error.code, "BAD_ANSWER")

		local bad_text_menu = run_tool({ base_q() }, {
			{ label = "Add notes" },
			{ text = "note" },
			{ label = "Edit notes" },
			{ index = 9 },
		})
		expect.truthy(bad_text_menu.is_error)
		expect.eq(bad_text_menu.details.error.code, "BAD_ANSWER")

		local bad_input_type = run_tool({ base_q() }, {
			{ label = "Other" },
			{ text = 123 },
		})
		expect.truthy(bad_input_type.is_error)
		expect.eq(bad_input_type.details.error.code, "BAD_ANSWER")

		local tok_skip_cancel = mare.task.token()
		local skip_cancel_res = run_tool({ base_q() }, {
			{ label = "Skip this question" },
			{ label = "Submit answers" },
			{ cancel = true, reason = "disconnected" },
		}, { cancel = tok_skip_cancel })
		expect.truthy(skip_cancel_res.is_error)
		expect.eq(skip_cancel_res.details.error.code, "ASK_ABORTED")

		local interrupted_res = run_tool({ base_q() }, {
			{ reason = "interrupted" },
		})
		expect.truthy(interrupted_res.is_error)
		expect.eq(interrupted_res.details.error.code, "ASK_ABORTED")
	end)

	it("persists drafts, isolates execution_id, and handles save failures and ephemeral sessions", function()
		local saved_res = run_tool({ base_q() }, {
			{ label = "Alpha" },
			{ label = "Submit answers" },
		}, { execution_id = "exec-1" })
		expect.falsy(saved_res.is_error)
		expect.truthy(#stored_records >= 2)
		expect.eq(stored_records[#stored_records].data.closed, true)
		expect.eq(stored_records[#stored_records].data.version, 2)

		stored_records = {
			{
				session_id = "s1",
				session_epoch = "g1",
				data = {
					version = 2,
					execution_id = "exec-bad",
					questions = { base_q() },
					draft = { position = 99, drafts = {} },
					closed = false,
				},
			},
		}
		local bad_draft_res = run_tool({ base_q() }, {
			{ label = "Beta" },
			{ label = "Submit answers" },
		}, { execution_id = "exec-bad" })
		expect.falsy(bad_draft_res.is_error)
		expect.eq(bad_draft_res.details.answers[1].selected[1], "Beta")

		stored_records = {
			{
				session_id = "s1",
				session_epoch = "g1",
				data = {
					version = 2,
					execution_id = "exec-resume",
					questions = { base_q() },
					draft = {
						position = 2,
						drafts = { { selected = { 2 }, status = "answered", custom = "restored" } },
					},
					closed = false,
				},
			},
		}
		local resumed_res = run_tool({ base_q() }, {
			{
				label = "Submit answers",
				check = function(opts)
					expect.eq(opts.title, "Review questions")
					expect.truthy(opts.items[1].detail:find("Beta", 1, true))
					expect.truthy(opts.items[1].detail:find("restored", 1, true))
				end,
			},
		}, { execution_id = "exec-resume" })
		expect.falsy(resumed_res.is_error)
		expect.eq(resumed_res.details.answers[1].selected[1], "Beta")
		expect.eq(resumed_res.details.answers[1].custom, "restored")
		expect.eq(stored_records[#stored_records].data.closed, true)

		local after_closed_res = run_tool({ base_q() }, {
			{
				label = "Alpha",
				check = function(opts)
					expect.eq(opts.title, "1/1 Target")
					expect.match(opts.items[2].label, "^%[ %] Beta")
				end,
			},
			{ label = "Submit answers" },
		}, { execution_id = "exec-resume" })
		expect.falsy(after_closed_res.is_error)
		expect.eq(after_closed_res.details.answers[1].selected[1], "Alpha")

		stored_records = {
			"corrupted-non-table-record",
			{
				session_id = "s1",
				session_epoch = "g1",
				data = {
					version = 2,
					execution_id = "exec-crashed",
					questions = { base_q() },
					draft = { position = 2, drafts = { { selected = { 2 }, status = "answered", custom = "stale" } } },
					closed = false,
				},
			},
		}
		local new_call_res = run_tool({ base_q() }, {
			{
				label = "Alpha",
				check = function(opts)
					expect.eq(opts.title, "1/1 Target")
					expect.match(opts.items[1].label, "^%[ %] Alpha")
					expect.match(opts.items[2].label, "^%[ %] Beta")
				end,
			},
			{ label = "Submit answers" },
		}, { execution_id = "exec-fresh" })
		expect.falsy(new_call_res.is_error)
		expect.eq(new_call_res.details.answers[1].selected[1], "Alpha")
		expect.eq(new_call_res.details.answers[1].custom, nil)

		stored_records = {
			{
				session_id = "s1",
				session_epoch = "g1",
				data = {
					version = 2,
					execution_id = "exec-changed-qs",
					questions = { base_q() },
					draft = { position = 2, drafts = { { selected = { 2 }, status = "answered" } } },
					closed = false,
				},
			},
		}
		local changed_qs_res = run_tool({ base_q({ question = "Different question?" }) }, {
			{
				label = "Alpha",
				check = function(opts)
					expect.eq(opts.title, "1/1 Target")
					expect.match(opts.items[2].label, "^%[ %] Beta")
				end,
			},
			{ label = "Submit answers" },
		}, { execution_id = "exec-changed-qs" })
		expect.falsy(changed_qs_res.is_error)
		expect.eq(changed_qs_res.details.answers[1].selected[1], "Alpha")

		stored_records = {
			{
				session_id = "s1",
				session_epoch = "g1",
				data = {
					version = 2,
					execution_id = "",
					questions = { base_q() },
					draft = { position = 2, drafts = { { selected = { 2 }, status = "answered" } } },
					closed = false,
				},
			},
		}
		local count_before = #stored_records
		local unnamed_res = run_tool({ base_q() }, {
			{
				label = "Alpha",
				check = function(opts)
					expect.eq(opts.title, "1/1 Target")
				end,
			},
			{ label = "Submit answers" },
		}, { execution_id = "" })
		expect.falsy(unnamed_res.is_error)
		expect.eq(#stored_records, count_before)

		save_should_fail = true
		expect.error(function()
			run_tool({ base_q() }, { { label = "Alpha" } }, { execution_id = "exec-fail" })
		end, "Could not save question progress")
		save_should_fail = false

		session_info.ephemeral = true
		stored_records = {}
		local eph_res = run_tool(
			{ base_q() },
			{ { label = "Alpha" }, { label = "Submit answers" } },
			{ execution_id = "exec-eph" }
		)
		expect.falsy(eph_res.is_error)
		expect.eq(#stored_records, 0)
	end)

	it("manages runtime queue, session/changed, restore nil, and dispose cancellation", function()
		local rt = runtime_mod.new(ctx)
		do
			local lease1 <close> = rt:enter()
			expect.truthy(lease1)
			events["session/changed"]()
			expect.truthy(lease1.token:is_cancelled())
		end

		record_should_nil = true
		do
			local lease2 <close> = rt:enter()
			expect.truthy(lease2)
			expect.falsy(rt:restore(lease2, "exec-nil", { base_q() }))
			expect.truthy(lease2.token:is_cancelled())
		end
		record_should_nil = false

		do
			local lease_a <close> = rt:enter()
			expect.truthy(lease_a)
			local done_tx, done_rx = mare.task.channel()
			mare.task.spawn(function()
				local lease_b <close> = rt:enter()
				done_tx:send(lease_b ~= nil)
			end)
			getmetatable(lease_a).__close(lease_a)
			expect.truthy(done_rx:recv())
		end

		disposers[#disposers]()
		local lease3 = rt:enter()
		expect.eq(lease3, nil)
	end)

	it(
		"scans drafts backwards from newest matching (version, execution_id) without resurrecting stale drafts",
		function()
			local rt = runtime_mod.new(ctx)
			local q = base_q()
			-- Oldest draft has option 1; newer matching draft has option 2; newest matching is closed.
			stored_records = {
				{
					session_id = "s1",
					session_epoch = "g1",
					data = {
						version = 2,
						execution_id = "exec-back",
						questions = { q },
						draft = { position = 1, drafts = { { selected = { 1 }, status = "answered" } } },
						closed = false,
					},
				},
				{
					session_id = "s1",
					session_epoch = "g1",
					data = {
						version = 2,
						execution_id = "exec-back",
						questions = { q },
						draft = { position = 2, drafts = { { selected = { 2 }, status = "answered" } } },
						closed = false,
					},
				},
				{
					session_id = "s1",
					session_epoch = "g1",
					data = {
						version = 2,
						execution_id = "other-exec",
						questions = { q },
						draft = { position = 1, drafts = { { selected = { 1 }, status = "answered" } } },
						closed = false,
					},
				},
				{
					session_id = "s1",
					session_epoch = "g1",
					data = {
						version = 1,
						execution_id = "exec-back",
						questions = { q },
						draft = { position = 1, drafts = { { selected = { 1 }, status = "answered" } } },
						closed = false,
					},
				},
			}
			local lease <close> = rt:enter()
			expect.truthy(lease)
			local restored = rt:restore(lease, "exec-back", { q })
			expect.truthy(restored)
			expect.eq(restored.position, 2)
			expect.eq(restored.drafts[1].selected[2], true)
			expect.falsy(restored.drafts[1].selected[1])

			-- Appending a closed record for the same execution_id must return nil (never fall back to older open draft).
			stored_records[#stored_records + 1] = {
				session_id = "s1",
				session_epoch = "g1",
				data = {
					version = 2,
					execution_id = "exec-back",
					questions = { q },
					closed = true,
				},
			}
			expect.eq(rt:restore(lease, "exec-back", { q }), nil)
		end
	)

	it(
		"handles Esc in input/sub-dialogs, multi-select untoggle, disconnect draft, final save, and enter cleanup",
		function()
			-- Esc ("cancelled") in input and sub-dialogs keeps previous text / returns to review.
			local esc_res = run_tool({ base_q() }, {
				{ label = "Add notes" },
				{ text = "kept-note" },
				{ label = "Edit notes" },
				{ reason = "cancelled" }, -- Esc on Replace/Clear/Keep menu keeps "kept-note"
				{ label = "Edit notes" },
				{ label = "Replace text" },
				{ reason = "cancelled" }, -- Esc on mare.ui.input keeps "kept-note"
				{ label = "Alpha" },
				{ label = "Submit answers" },
			})
			expect.falsy(esc_res.is_error)
			expect.eq(esc_res.details.answers[1].selected[1], "Alpha")
			expect.eq(esc_res.details.answers[1].custom, "kept-note")

			-- Esc on "Submit with skipped questions?" returns to review; "interrupted" aborts batch.
			local skip_esc_res = run_tool({ base_q() }, {
				{ label = "Skip this question" },
				{ label = "Submit answers" },
				{ reason = "cancelled" },
				{ label = "Submit answers" },
				{ label = "Submit answers" },
			})
			expect.falsy(skip_esc_res.is_error)
			expect.eq(#skip_esc_res.details.answers[1].selected, 0)

			local skip_int_res = run_tool({ base_q() }, {
				{ label = "Skip this question" },
				{ label = "Submit answers" },
				{ reason = "interrupted" },
			})
			expect.truthy(skip_int_res.is_error)
			expect.eq(skip_int_res.details.error.code, "ASK_ABORTED")

			local sub_unavail = run_tool({ base_q() }, {
				{ label = "Add notes" },
				{ text = "x" },
				{ label = "Edit notes" },
				{ reason = "unavailable" },
			})
			expect.truthy(sub_unavail.is_error)
			expect.eq(sub_unavail.details.error.code, "NO_PROVIDER")

			-- Untoggling the last multi-select option resets draft.status to nil (Done disabled).
			local untoggle_res = run_tool({ base_q({ multi_select = true }) }, {
				{ label = "Alpha" },
				{
					label = "Alpha",
					check = function(opts)
						for _, row in ipairs(opts.items) do
							if row.label == "Done" then
								expect.falsy(row.disabled)
							end
						end
					end,
				},
				{
					label = "Beta",
					check = function(opts)
						for _, row in ipairs(opts.items) do
							if row.label == "Done" then
								expect.truthy(row.disabled)
							end
						end
					end,
				},
				{ label = "Done" },
				{ label = "Submit answers" },
			})
			expect.falsy(untoggle_res.is_error)
			expect.eq(untoggle_res.details.answers[1].selected[1], "Beta")

			-- Disconnect preserves partial draft instead of writing closed = true.
			stored_records = {}
			local disc_res = run_tool({ base_q({ id = "q1" }), base_q({ id = "q2" }) }, {
				{ label = "Alpha" },
				{ disconnect = true, reason = "cancelled" },
			}, { execution_id = "exec-disc" })
			ui_responders = true
			expect.truthy(disc_res.is_error)
			expect.eq(disc_res.details.error.code, "DISCONNECTED")
			expect.truthy(#stored_records >= 1)
			expect.eq(stored_records[#stored_records].data.closed, false)

			-- Final save() error preserves already-submitted answers.
			local orig_log = mare.log
			local warned = false
			mare.log = function(_, msg)
				if tostring(msg):find("Could not save question progress", 1, true) then
					warned = true
				end
			end
			local final_save_res = run_tool({ base_q() }, {
				{ label = "Alpha" },
				{
					label = "Submit answers",
					check = function()
						save_should_fail = true
					end,
				},
			}, { execution_id = "exec-final-fail" })
			save_should_fail = false
			mare.log = orig_log
			expect.falsy(final_save_res.is_error)
			expect.eq(final_save_res.details.answers[1].selected[1], "Alpha")
			expect.truthy(warned)

			-- runtime:enter cleans up current lock if session:info() throws.
			local orig_info = ctx.session.info
			local info_calls = 0
			local bad_ctx = {
				session = {
					info = function()
						info_calls = info_calls + 1
						if info_calls == 2 then
							error("session info exploded")
						end
						return orig_info()
					end,
					list_records = ctx.session.list_records,
					add_record = ctx.session.add_record,
				},
				on = function() end,
				effect = function() end,
			}
			local rt_err = runtime_mod.new(bad_ctx)
			expect.error(function()
				rt_err:enter()
			end, "session info exploded")
			local recovered <close> = rt_err:enter()
			expect.truthy(recovered)
		end
	)
end)
