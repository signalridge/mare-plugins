-- Original strict dialect output decoder; input rewriting remains explicitly unsupported.
local function fields(value, allowed, what)
	assert(type(value) == "table" and not mare.json.is_array(value), what .. " must be an object")
	for k in pairs(value) do
		assert(allowed[k], what .. ": unsupported field " .. tostring(k))
	end
end
local function optional_string(v, what)
	assert(v == nil or type(v) == "string", what .. " must be a string")
end
return function(text, event)
	text = text:match("^%s*(.-)%s*$")
	if text:sub(1, 1) ~= "{" then
		return {
			decision = "allow",
			context = (event == "SessionStart" or event == "UserPromptSubmit") and text ~= "" and text or nil,
		}
	end
	local v = mare.json.decode_lossless(text)
	fields(v, {
		decision = true,
		reason = true,
		hookSpecificOutput = true,
		continue = true,
		stopReason = true,
		suppressOutput = true,
		systemMessage = true,
	}, "hook output")
	optional_string(v.reason, "reason")
	optional_string(v.stopReason, "stopReason")
	optional_string(v.systemMessage, "systemMessage")
	assert(v.continue == nil or type(v.continue) == "boolean", "continue must be boolean")
	assert(v.suppressOutput == nil or type(v.suppressOutput) == "boolean", "suppressOutput must be boolean")
	assert(v.decision == nil or v.decision == "approve" or v.decision == "block", "invalid top-level decision")
	assert(
		(event ~= "SessionStart" and event ~= "SessionEnd") or v.decision == nil,
		event .. " does not accept a decision field"
	)
	assert(
		(event ~= "Stop" and event ~= "PreCompact" and event ~= "PostCompact" and event ~= "SessionEnd")
			or v.hookSpecificOutput == nil,
		event .. " does not accept hookSpecificOutput"
	)
	assert(
		event ~= "PermissionRequest" or v.continue ~= false,
		"PermissionRequest hook returned unsupported continue:false"
	)
	assert(
		event ~= "PermissionRequest" or v.stopReason == nil,
		"PermissionRequest hook returned unsupported stopReason"
	)
	assert(
		(event ~= "PermissionRequest" and event ~= "PostToolUse") or v.suppressOutput ~= true,
		event .. " hook returned unsupported suppressOutput"
	)
	assert(
		event ~= "Stop" or v.decision ~= "block" or (v.reason and v.reason:match("%S")),
		"Stop block requires nonempty continuation feedback"
	)
	local decision = v.decision == "block" and "deny" or "allow"
	local reason, context, decided = v.reason, nil, false
	if v.hookSpecificOutput ~= nil then
		local h = v.hookSpecificOutput
		if event == "PermissionRequest" then
			fields(h, { hookEventName = true, decision = true }, "PermissionRequest output")
			assert(h.hookEventName == "PermissionRequest", "hookEventName must be PermissionRequest")
			if h.decision ~= nil then
				fields(h.decision, {
					behavior = true,
					message = true,
					updatedInput = true,
					updatedPermissions = true,
					interrupt = true,
				}, "PermissionRequest decision")
				assert(h.decision.updatedInput == nil, "PermissionRequest hook returned unsupported updatedInput")
				assert(
					h.decision.updatedPermissions == nil,
					"PermissionRequest hook returned unsupported updatedPermissions"
				)
				assert(not h.decision.interrupt, "PermissionRequest hook returned unsupported interrupt:true")
				assert(
					h.decision.behavior == "allow" or h.decision.behavior == "deny",
					"invalid PermissionRequest behavior"
				)
				optional_string(h.decision.message, "message")
				decision = h.decision.behavior
				decided = true
				if decision == "deny" then
					reason = (h.decision.message and h.decision.message:match("%S")) and h.decision.message
						or "PermissionRequest hook denied approval"
				end
			end
		else
			fields(h, {
				hookEventName = true,
				permissionDecision = true,
				permissionDecisionReason = true,
				additionalContext = true,
			}, event .. " output")
			assert(h.hookEventName == event, "hookEventName must be " .. event)
			assert(
				event == "PreToolUse" or (h.permissionDecision == nil and h.permissionDecisionReason == nil),
				"permissionDecision only applies to PreToolUse"
			)
			optional_string(h.additionalContext, "additionalContext")
			context = h.additionalContext
			assert(
				h.permissionDecision == nil
					or h.permissionDecision == "allow"
					or h.permissionDecision == "deny"
					or h.permissionDecision == "ask",
				"invalid permissionDecision"
			)
			optional_string(h.permissionDecisionReason, "permissionDecisionReason")
			decision, reason = h.permissionDecision or decision, h.permissionDecisionReason or reason
		end
	end
	local suppress_output = v.suppressOutput == true
	local system_message = v.systemMessage
	if v.continue == false then
		return {
			decision = "deny",
			abort = true,
			context = context,
			reason = v.stopReason or "hook stopped the turn",
			suppress_output = suppress_output,
			system_message = system_message,
			decided = true,
		}
	end
	return {
		decision = decision,
		reason = reason,
		context = context,
		suppress_output = suppress_output,
		system_message = system_message,
		decided = decided,
	}
end
