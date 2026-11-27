-- A Stop block requests another step in the same logical run. The core owns continuation
-- publication and cancellation classification; this adapter never edits history or the inbox.
return function(ctx, run, register)
	local active_turn, active, warned_unavailable = nil, false, false
	register("agent/turn-stopping", function(event)
		if not event.cancel or not event.turn_id then
			-- the core event lacks the turn identity / cancellation the hook protocol needs: let the
			-- turn stop (blocking it every turn would loop to max turns) and say so once
			if not warned_unavailable then
				warned_unavailable = true
				mare.log("warn", "Stop hooks skipped: the core agent/turn-stopping event has no turn_id/cancel")
			end
			return
		end
		if event.cancel:is_cancelled() then
			return
		end
		if active_turn ~= event.turn_id then
			active_turn, active = event.turn_id, false
		end
		local text = {}
		for _, block in ipairs(event.message and event.message.content or {}) do
			if block.type == "text" then
				text[#text + 1] = block.text
			end
		end
		local vote = run("Stop", "", {
			stop_hook_active = active,
			turn_id = event.turn_id,
			last_assistant_message = #text > 0 and table.concat(text, "\n") or mare.json.null,
		}, { cancel = event.cancel, run_cancel = event.cancel })
		if vote.abort then
			ctx.agent:cancel({ turn_id = event.turn_id, reason = "hook" })
			return
		end
		if vote.decision ~= "allow" then
			active = true
			local feedback = vote.reason or "continue: blocked by Stop hook"
			if vote.context then
				feedback = feedback .. "\n\n" .. vote.context
			end
			return { message = feedback, source = "hooks" }
		end
	end)
end
