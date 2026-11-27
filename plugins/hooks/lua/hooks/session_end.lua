-- SessionEnd runs once per ended root session via the core `session/closed` boundary.
-- The payload uses the immutable closed-session snapshot (already flushed on disk).
-- Failures are diagnostic-only and never block teardown or switching.
return function(ctx, run)
	local capability = require("hooks.capability")
	if not (ctx and require("mare_lib").callable(ctx.on)) then
		capability.warn("hooks: SessionEnd skipped; event subscription is unavailable")
		return
	end
	local ok = pcall(ctx.on, ctx, "session/closed", function(snap)
		if type(snap) ~= "table" or not snap.session_id then
			return
		end
		local reason = (snap.reason == "new" or snap.reason == "clear") and "clear" or "other"
		run("SessionEnd", reason, {
			reason = reason,
			cwd = snap.cwd,
			session_id = snap.session_id,
			transcript_path = snap.path or "",
		})
	end)
	if not ok then
		capability.warn("hooks: SessionEnd skipped; core does not provide session/closed")
	end
end
