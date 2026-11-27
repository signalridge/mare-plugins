return {
	name = "themes-probe",
	inject = { "ui" },
	apply = function(ctx)
		local samples = {
			{ "MareAccent", "THEME-SNAPSHOT heading" },
			{ "MareMuted", "secondary" },
			{ "MareDim", "hint" },
			{ "MareToolOk", "tool success" },
			{ "MareToolError", "tool error" },
			{ "MareSelection", "selected row" },
			{ "MareDiffAdd", "+ added line" },
			{ "MareDiffDelete", "- removed line" },
			{ "MareModeAuto", "AUTO" },
			{ "md.code", "inline code" },
		}
		ctx.ui:widget("themes-probe", {
			order = -1000,
			render = function()
				local lines = {}
				for _, s in ipairs(samples) do
					lines[#lines + 1] = ui.Line({ ui.Span(s[2]):hl(s[1]) })
				end
				return ui.Lines(lines)
			end,
		})
		ctx:on("app/ready", function()
			local ok, err = pcall(function()
				local found = false
				for _, d in ipairs(mare.plugins.dirs("themes")) do
					if d.name == "test/themes" then
						found = true
					end
				end
				assert(found, "file package theme directory not discovered")
				local name = mare.env("THEME_FLAVOR")
				mare.o.flavor = name
				local accent = mare.ui.style("MareAccent").fg
				assert(accent and accent:match("^#"), "theme did not load")
				mare.ui.style("MareAccent", { fg = "#123456" })
				mare.o.flavor = "dark"
				mare.o.flavor = name
				assert(mare.ui.style("MareAccent").fg == "#123456", "explicit override lost")
				mare.ui.reset_style("MareAccent", { fg = accent })
			end)
			assert(mare.fs.write(mare.env("THEME_RESULT"), mare.json.encode({ ok = ok, error = tostring(err) })))
			assert(ok, err)
		end)
	end,
}
