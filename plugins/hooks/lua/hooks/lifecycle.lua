-- Real session lifecycle outputs become source-marked disclosures through the shared writer.
-- External commands run outside the synchronous participant; commit retries reuse cached data.
local spill = require("hooks.spill")

return function(ctx, run, register)
	require("hooks.capability").step(ctx, "SessionStart")
	local lifetime = mare.task.token()
	local current, cancel, items, failure
	ctx:effect(function()
		return function()
			lifetime:cancel()
		end
	end)
	local function start(source, force)
		local info = ctx.session:info()
		local owner = info.session_id .. ":" .. tostring(info.session_epoch)
		if current == owner and not force then
			return
		end
		if current ~= owner then
			if cancel then
				cancel:cancel()
			end
			current, cancel, items, failure = owner, lifetime:child(), {}, nil
		end
		local vote = run("SessionStart", source, { source = source }, { cancel = cancel })
		if current ~= owner then
			return
		end
		if vote.decision ~= "allow" then
			failure = vote.reason or "SessionStart hook stopped the session"
			return
		end
		if vote.context and vote.context ~= "" then
			if #items >= 16 then
				failure = "SessionStart context exceeds the shared disclosure budget"
				return
			end
			local capped, err = spill.cap_context(vote.context, 65536)
			if not capped then
				failure = err or "SessionStart context exceeds the shared disclosure budget"
				return
			end
			items[#items + 1] = { id = mare.crypto.random_hex(12), source = source, text = capped }
		end
	end
	register("session/started", function(event)
		start(event.resumed and "resume" or "startup")
	end)
	register("session/changed", function(event)
		start(
			event.reason == "new" and "clear"
				or (event.reason == "start" or event.reason == "fork") and "startup"
				or "resume"
		)
	end)
	register("compact/completed", function(event)
		if event and (event.status == "completed" or event.ok) then
			start("compact", true)
		end
	end)
	register("agent/step-ready", function() -- a decision point: the registrar makes it a voter
		if failure then
			return { decision = "deny", reason = failure }
		end
	end)
	ctx:on("agent/step-committed", function()
		local state = ctx.agent:step_state("hooks.lifecycle")
		if state and items then
			for index, item in ipairs(items) do
				if item.id == state.last_id then
					for _ = 1, index do
						table.remove(items, 1)
					end
					break
				end
			end
		end
	end)
	ctx.agent:step_participant("hooks.lifecycle", function(previous)
		if not items or #items == 0 then
			return
		end
		local last = previous and previous.last_id
		if last == items[#items].id then
			return
		end
		local first = 1
		for index, item in ipairs(items) do
			if item.id == last then
				first = index + 1
			end
		end
		local disclosures = {}
		for index = first, #items do
			local item = items[index]
			disclosures[#disclosures + 1] = {
				source = "hooks",
				text = item.text,
				metadata = { event = "SessionStart", source = item.source, id = item.id },
			}
		end
		return { state = { last_id = items[#items].id }, disclosures = disclosures }
	end, { output = "transaction" })
end
