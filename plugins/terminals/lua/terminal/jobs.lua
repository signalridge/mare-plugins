-- Public jobs adapter for a single send operation; shell lifetime stays in the registry.
-- jobs_of(): the optional jobs service or nil, followed by the plugin.
return function(_, jobs_of)
	return function(r, operation)
		local svc = assert(jobs_of(), "Background send requires the jobs service")
		local job = svc:track({
			kind = "terminal",
			description = r.name or "Terminal send",
			handle = operation,
			owner = r.owner,
			background = true,
		})
		if job.over_limit then
			operation:kill()
			if type(svc.cancel) == "function" and job.job_id then
				pcall(svc.cancel, svc, job.job_id, "Background job limit reached")
			end
			error("Background job limit reached", 0)
		end
		return job
	end
end
