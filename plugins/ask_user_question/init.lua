return {
	name = "ask_user_question",
	inject = { "tools", "session" },
	apply = function(ctx)
		local runtime = require("ask_user_question.runtime").new(ctx)
		ctx.tools:register("ask_user_question", {
			description = "Ask 1–4 questions when user input is necessary. Give each a unique id, short header, 2–4 distinct options and optional preview. Put the recommended option first and set recommended=true. Other/free text and Skip are supplied by the UI. Waits for a real answer; unavailable means nobody can answer and no choice was made. Empty selected with no custom means skipped, and empty answers with a note means dismissed: do not treat either as selecting the recommended option or granting permission, and do not re-ask.",
			side_effect = "read",
			timeout_ms = false,
			parameters = require("ask_user_question.schema"),
			execute = function(args, tctx)
				local ok, err = pcall(
					require("ask_user_question.questions").validate,
					type(args) == "table" and args.questions or nil
				)
				if not ok then
					return { content = tostring(err), is_error = true }
				end
				local lease <close> = runtime:enter(tctx and tctx.cancel)
				if not lease then
					local result = {
						answers = mare.json.array({}),
						error = {
							code = "ASK_ABORTED",
							message = "The question call was cancelled before it could open.",
						},
					}
					return { content = mare.json.encode(result), details = result, is_error = true }
				end
				local execution_id = tctx and tctx.execution_id
				local restored = runtime:restore(lease, execution_id, args.questions)
				local dirty = false
				local result = require("ask_user_question.questions").ask(
					args.questions,
					lease.token,
					restored,
					function(draft)
						runtime:save(lease, execution_id, args.questions, draft, false)
						dirty = true
					end
				)
				if (dirty or restored) and result.status ~= "disconnected" then
					local save_ok, save_err =
						pcall(runtime.save, runtime, lease, execution_id, args.questions, nil, true)
					if not save_ok and mare and type(mare.log) == "function" then
						mare.log("warn", tostring(save_err))
					end
				end
				-- Structured answers shape with optional dismiss note; flow status stays internal.
				local payload = { answers = result.answers }
				local failed = result.status ~= "answered" and result.status ~= "dismissed"
				if result.status == "dismissed" then
					payload.note = result.message
				elseif failed then
					payload.error = {
						code = ({
							cancelled = "ASK_ABORTED",
							interrupted = "ASK_ABORTED",
							unavailable = "NO_PROVIDER",
							invalid_ui_answer = "BAD_ANSWER",
							disconnected = "DISCONNECTED",
						})[result.status] or "BAD_ANSWER",
						message = result.message,
					}
				end
				return { content = mare.json.encode(payload), details = payload, is_error = failed }
			end,
		})
	end,
}
