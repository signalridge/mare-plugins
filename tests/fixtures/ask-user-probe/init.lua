return {
	name = "ask-user-probe",
	inject = { "tools", "session" },
	apply = function(ctx)
		ctx:on("app/ready", function()
			local report = mare.env("ASK_USER_REPORT")
			if not report then
				return
			end
			local ok, err = pcall(function()
				local tool = assert(ctx.tools:get("ask_user_question"))
				local original = { mare.ui.can_respond, mare.ui.select, mare.ui.input }
				local q = {
					id = "choice",
					header = "Choice",
					question = "Choose?",
					options = {
						{ label = "A", description = "first", recommended = true, preview = "a\nb" },
						{ label = "B", description = "second" },
					},
				}
				local function invoke(qs, steps, token)
					local count = 0
					mare.ui.can_respond = function()
						return true
					end
					mare.ui.select = function(t)
						count = count + 1
						local step = assert(steps[count], "unexpected select: " .. t.title)
						if step.disconnect then
							mare.ui.can_respond = function()
								return false
							end
						end
						if step.check then
							step.check(t)
						end
						if step.cancel then
							token:cancel()
							return nil
						end
						if step.nil_answer then
							return nil
						end
						for i, row in ipairs(t.items) do
							local label = type(row) == "string" and row or row.label
							if label:find(step.label, 1, true) then
								assert(type(row) == "string" or not row.disabled, "selected disabled row")
								return i
							end
						end
						error("missing row: " .. tostring(step.label) .. " in " .. t.title)
					end
					mare.ui.input = function(t)
						count = count + 1
						local step = assert(steps[count], "unexpected input: " .. t.title)
						return step.text
					end
					local r = tool.execute({ questions = qs }, { cancel = token })
					assert(count == #steps, "unused UI steps")
					return r
				end
				local r = invoke({ q }, {
					{
						label = "B",
						check = function(t)
							assert(t.selected == 1 and t.items[1].preview and t.items[1].label:find("Recommended"))
						end,
					},
					{ label = "Submit answers" },
				})
				assert(r.details.answers[1].selected[1] == "B")
				q.multi_select = true
				r = invoke({ q }, {
					{
						label = "A",
						check = function(t)
							assert(not t.items[1].label:find("%[x%]"))
						end,
					},
					{ label = "B" },
					{ label = "A" },
					{ label = "Other" },
					{ text = "custom" },
					{ label = "Done" },
					{ label = "Submit answers" },
				})
				assert(
					#r.details.answers[1].selected == 1
						and r.details.answers[1].selected[1] == "B"
						and r.details.answers[1].custom == "custom"
				)
				q.multi_select = false
				r = invoke({ q }, { { label = "Other" }, { text = "custom answer" }, { label = "Submit answers" } })
				assert(r.details.answers[1].custom == "custom answer")
				r = invoke({ q }, {
					{ label = "Other" },
					{},
					{ label = "B" },
					{ label = "Choice — answered" },
					{ label = "Add notes" },
					{ text = "details" },
					{ label = "Done" },
					{ label = "Submit answers" },
				})
				assert(r.details.answers[1].selected[1] == "B" and r.details.answers[1].custom == "details")
				r = invoke({ q }, {
					{ label = "Skip this question" },
					{ label = "Submit answers" },
					{ label = "Return to review" },
					{ label = "Choice — skipped" },
					{ label = "A" },
					{ label = "Submit answers" },
				})
				assert(r.details.answers[1].selected[1] == "A")
				local q2 = { id = "second", header = "Second", question = "Second?", options = q.options }
				r = invoke({ q, q2 }, {
					{ label = "A" },
					{ label = "Previous question" },
					{ label = "B" },
					{ label = "Skip this question" },
					{ label = "Submit answers" },
					{ label = "Submit answers" },
				})
				assert(r.details.answers[1].selected[1] == "B" and #r.details.answers[2].selected == 0)
				r = invoke({ q, q2 }, { { label = "A" }, { label = "Dismiss questions" } })
				assert(r.details.note ~= nil and #r.details.answers == 0 and not r.is_error)
				r = invoke({ q, q2 }, { { label = "A", disconnect = true } })
				assert(r.details.error.code == "DISCONNECTED" and #r.details.answers == 0 and r.is_error)
				local token = mare.task.token()
				r = invoke({ q, q2 }, { { label = "A" }, { cancel = true } }, token)
				assert(r.details.error.code == "ASK_ABORTED" and #r.details.answers == 0 and r.is_error)
				local four = {}
				for i = 1, 4 do
					four[i] = {
						id = "q" .. i,
						header = "Q" .. i,
						question = "Choose?",
						options = {
							{ label = "A", description = "a" },
							{ label = "B", description = "b" },
							{ label = "C", description = "c" },
							{ label = "D", description = "d" },
						},
					}
				end
				r = invoke(four, {
					{ label = "Skip this question" },
					{ label = "Skip this question" },
					{ label = "Skip this question" },
					{ label = "Skip this question" },
					{ label = "Submit answers" },
					{ label = "Submit answers" },
				})
				assert(#r.details.answers == 4 and #r.details.answers[4].selected == 0)
				four[5] = { id = "q5", header = "Q5", question = "Choose?", options = q.options }
				assert(tool.execute({ questions = four }).is_error)

				mare.ui.can_respond, mare.ui.select, mare.ui.input = table.unpack(original)
			end)
			assert(mare.fs.write(report, mare.json.encode({ ok = ok, detail = tostring(err or "passed") })))
		end)
	end,
}
