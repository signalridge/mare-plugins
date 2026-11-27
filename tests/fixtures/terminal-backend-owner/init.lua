-- A real independently reloadable backend owner, exercising caller-scope withdrawal.
return {
	name = "terminal-backend-owner",
	inject = { "terminals" },
	apply = function(ctx)
		ctx.terminals:register("reloadable", {
			open = function(opts)
				local delay = mare.env("TERMINAL_BACKEND_DELAY") or "1500"
				if delay then
					mare.task.sleep(tonumber(delay))
				end
				opts.cmd = assert(mare.proc.which("bash"))
				opts.args = { "--noprofile", "--norc", "-i" }
				return mare.pty.spawn(opts)
			end,
		})
	end,
}
