-- PreCompact only stops compaction on continue:false (abort); ordinary deny/exit 2/failure log a warning and proceed.
-- PostCompact runs only after successful compaction (event.ok) and logs continue:false stop reasons.
return function(ctx, run, register, has_pre, has_post)
	if has_pre then
		register("compact/before", function(event)
			local trigger = event.reason == "manual" and "manual" or "auto"
			local vote = run("PreCompact", trigger, { trigger = trigger })
			if vote.abort then
				if vote.reason then
					mare.log("warn", vote.reason)
				end
				return false
			end
			if vote.decision ~= "allow" and vote.reason then
				mare.log("warn", vote.reason)
			end
		end)
	end
	if has_post then
		register("compact/completed", function(event)
			if not (event and (event.status == "completed" or event.ok)) then
				return
			end
			local trigger = event.reason == "manual" and "manual" or "auto"
			local vote = run("PostCompact", trigger, { trigger = trigger })
			if vote.abort and vote.reason then
				mare.log("warn", vote.reason)
			end
		end)
	end
end
