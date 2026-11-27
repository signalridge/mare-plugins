-- Public-API feature detection. Optional hook events degrade cleanly with a warning and
-- notification when a capability is missing so core hooks such as PreToolUse remain active.
local M = {}

local function fail(feature, api)
	error(
		"hooks: "
			.. feature
			.. " requires the public API "
			.. api
			.. ", which this mare build does not provide; use a mare build that includes it"
			.. " or remove the hooks that need it from the configuration",
		0
	)
end

-- Logs a warning and notifies the UI without failing if notifications are unavailable.
function M.warn(msg)
	if mare and mare.log then
		mare.log("warn", msg)
	end
	if mare and mare.ui and mare.ui.notify then
		pcall(mare.ui.notify, msg, "warning")
	end
end

-- Probes `service:capabilities()[field] == expected`; warns and returns false when missing.
function M.check_capability(service, field, expected, feature, api)
	if service and require("mare_lib").callable(service.capabilities) then
		local ok, caps = pcall(service.capabilities, service)
		if ok and type(caps) == "table" and caps[field] == expected then
			return true
		end
	end
	M.warn("hooks: " .. feature .. " skipped; core does not provide " .. api)
	return false
end

-- Ensures ctx.agent exposes the step participant/state pair used by transactional events.
function M.step(ctx, feature)
	local agent = ctx.agent
	if not (agent and require("mare_lib").callable(agent.step_participant)) then
		fail(feature, "agent:step_participant")
	end
	if not require("mare_lib").callable(agent.step_state) then
		fail(feature, "agent:step_state")
	end
end

return M
