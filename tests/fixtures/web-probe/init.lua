return {
	name = "web-probe",
	inject = { "web", "task" },
	apply = function(ctx)
		local source = mare.env("WEB_SEARCH_FIXTURE")
		if source then
			ctx.web:register_search({
				provider_id = "local-fixture",
				search = function()
					return {
						content = "Fixture research",
						data = {
							{ url = source, title = "Source one", summary = "First source" },
							{ url = source .. "#second", title = "Source two", summary = "Second source" },
						},
					}
				end,
			})
		end
		ctx:on("request/build", function(req, ev)
			local path = mare.env("WEB_CAPTURE")
			assert(mare.fs.write(path, (mare.fs.read(path) or "") .. mare.json.encode(req.messages) .. "\n"))
			local meta = mare.env("WEB_CAPTURE_META")
			if meta then
				assert(mare.fs.write(meta, mare.json.encode({ system = req.system, tools = req.tools })))
			end
			return ev.next(req)
		end)
		ctx:on("kernel/doctor", function(checks)
			local token = mare.task.token()
			ctx:after(50, function()
				token:cancel()
			end)
			local ok, err = pcall(function()
				ctx.web:fetch(mare.env("WEB_SLOW_URL"), {
					cancel = function()
						return token
					end,
				})
			end)
			checks[#checks + 1] =
				{ name = "web cancellation", ok = not ok and token:is_cancelled(), detail = tostring(err) }
			-- which web-fetch-http runs: the core built-in, alone under its name
			local status = mare.plugins.status("web-fetch-http")
			local paths = {}
			for _, source in ipairs(status.sources or {}) do
				paths[#paths + 1] = source.origin .. "=" .. tostring(source.path)
			end
			checks[#checks + 1] = {
				name = "web-fetch-http origin",
				ok = status.active and status.origin == "builtin" and #paths == 1 and status.failure == nil,
				detail = tostring(status.origin) .. " " .. table.concat(paths, " "),
			}
		end)
	end,
}
