local Profile = require("mermaid.profile")

local M = {}

local VIEWER_TITLE = "Mermaid Viewer"
local MIN_ZOOM_PERCENT = 50
local MAX_ZOOM_PERCENT = 200
local ZOOM_STEP_PERCENT = 25
local COPY_REVERT_MS = 1500
local COPY_LABELS = {
	idle = "[Copy Source]",
	copied = "[Copied]",
	sent = "[Sent via OSC 52]",
	failed = "[Copy failed]",
}

--- Send a UI notification when `mare.ui.notify` is available.
function M.notify(msg, level)
	if type(mare.ui.notify) == "function" then
		mare.ui.notify(msg, level)
	end
end

--- Create Mermaid Viewer, zoom, clipboard copy, /mermaid command, and keymap controller.
function M.new(ctx, cfg, hooks)
	local active_order = {}
	local active_diagrams = {}
	local inline_zoom_percent = 100
	local viewer_index = 1
	local viewer_show_source = true
	local viewer_copy_state = "idle"
	local viewer_copy_seq = 0
	local viewer_copy_token = nil
	local keymap_handles = {}
	local viewer = {}

	--- Return whether the connected UI supports terminal image rendering.
	function viewer:images_supported()
		local images = mare.ui.caps().images
		return mare.ui.connected() and images ~= nil and images ~= "none"
	end

	--- Return the current inline zoom percentage.
	function viewer:zoom_percent()
		return inline_zoom_percent
	end

	--- Scale `base_rows` by the active inline zoom, clamped to `[1, expanded_max_rows]`.
	function viewer:scaled_rows(base_rows)
		return math.max(1, math.min(cfg.expanded_max_rows, math.floor(base_rows * inline_zoom_percent / 100 + 0.5)))
	end

	--- Render an artifact image node with `fallback` when image placement fails or is unavailable.
	function viewer:artifact_node(artifact, max_rows, max_cols, fallback)
		local ok, node = pcall(ctx.ui.artifact_image, ctx.ui, artifact, {
			max_rows = max_rows,
			max_cols = max_cols,
			fallback = fallback,
		})
		return ok and node or fallback
	end

	--- Record an active diagram entry for the viewer LRU list.
	function viewer:record_active(occ_key, entry)
		Profile.lru_set(active_order, active_diagrams, occ_key, entry, 64)
		viewer_index = #active_order
	end

	local function build_viewer_node()
		local count = #active_order
		if count == 0 then
			return mare.ui.Lines({
				mare.ui.Paragraph(
					"No active Mermaid diagrams in this session yet. Render one via ```mermaid or the mermaid tool."
				),
				mare.ui.Gap(1),
				mare.ui.Paragraph(
					string.format(
						"Inline zoom: %d%% · auto: %s",
						inline_zoom_percent,
						hooks.get_automatic() and "on" or "off"
					)
				),
			})
		end
		viewer_index = math.max(1, math.min(count, viewer_index))
		local entry = active_diagrams[active_order[viewer_index]]
		if not entry then
			return mare.ui.Paragraph("Active Mermaid diagram is no longer available.")
		end
		local dims = entry.artifact
				and entry.artifact.width
				and entry.artifact.height
				and (tostring(entry.artifact.width) .. "x" .. tostring(entry.artifact.height))
			or "unrendered"
		local header = string.format(
			"Diagram %d/%d · %s · %s · zoom %d%% · auto %s · %s",
			viewer_index,
			count,
			tostring(entry.phase or "live"),
			dims,
			inline_zoom_percent,
			hooks.get_automatic() and "on" or "off",
			COPY_LABELS[viewer_copy_state] or COPY_LABELS.idle
		)
		local items = {
			mare.ui.Line({ mare.ui.Span(header) }),
			mare.ui.Gap(1),
		}
		local fallback = mare.ui.Code(entry.source or "", "mermaid")
		if entry.artifact and viewer:images_supported() then
			local term_w = (type(mare.ui.width) == "function" and mare.ui.width()) or cfg.max_cols
			local max_cols = math.max(4, math.min(term_w, cfg.max_cols))
			local base_rows = math.max(cfg.max_rows, math.min(cfg.expanded_max_rows, 40))
			items[#items + 1] = viewer:artifact_node(entry.artifact, viewer:scaled_rows(base_rows), max_cols, fallback)
		else
			items[#items + 1] = fallback
		end
		if viewer_show_source and entry.source then
			items[#items + 1] = mare.ui.Gap(1)
			items[#items + 1] = fallback
		end
		return mare.ui.Lines(items)
	end

	--- Open or refresh the Mermaid Viewer transcript dialog.
	function viewer:open_or_refresh(only_if_open)
		if type(mare.ui.transcript) ~= "function" then
			return false
		end
		if
			only_if_open
			and (type(mare.ui.transcript_title) ~= "function" or mare.ui.transcript_title() ~= VIEWER_TITLE)
		then
			return false
		end
		mare.ui.transcript(VIEWER_TITLE, build_viewer_node(), {
			keys = {
				{ action = { "mermaid.zoom_in", "mermaid.zoom_out", "mermaid.zoom_reset" }, label = "zoom" },
				{ action = "mermaid.toggle_source", label = "source" },
				{ action = "mermaid.copy_source", label = "copy" },
				{ action = { "mermaid.prev", "mermaid.next" }, label = "diagram" },
			},
		})
		return true
	end

	--- Cancel any pending revert timer and reset `[Copy Source]` badge to idle.
	function viewer:reset_copy_state()
		viewer_copy_seq = viewer_copy_seq + 1
		if viewer_copy_token then
			viewer_copy_token:cancel()
			viewer_copy_token = nil
		end
		viewer_copy_state = "idle"
	end

	--- Copy diagram source to clipboard, tracking verified vs unverified OSC 52 feedback.
	function viewer:copy_source(source, notify_result)
		if type(source) ~= "string" or #source == 0 then
			if notify_result then
				M.notify("No Mermaid source available to copy.", "warning")
			end
			return false
		end
		if type(mare.clipboard) ~= "table" or type(mare.clipboard.copy) ~= "function" then
			viewer:reset_copy_state()
			viewer_copy_state = "failed"
			viewer:open_or_refresh(true)
			if notify_result then
				M.notify("Clipboard is unavailable.", "warning")
			end
			return false
		end
		viewer:reset_copy_state()
		local seq = viewer_copy_seq
		local tok = mare.task.token()
		viewer_copy_token = tok
		mare.task.spawn(function()
			local ok, res = pcall(mare.clipboard.copy, source)
			if hooks.is_disposed() or tok:is_cancelled() or seq ~= viewer_copy_seq then
				return
			end
			if ok and type(res) == "table" and res.ok then
				local is_osc52 = res.method == "osc52" or res.verified == false
				local bytes = res.bytes or #source
				viewer_copy_state = is_osc52 and "sent" or "copied"
				if notify_result then
					if is_osc52 then
						M.notify(
							string.format(
								"Sent Mermaid source (%d bytes) to terminal clipboard via OSC 52 — depends on terminal allowing OSC 52.",
								bytes
							),
							"info"
						)
					else
						M.notify(string.format("Copied Mermaid source (%d bytes).", bytes), "success")
					end
				end
				viewer:open_or_refresh(true)
				if mare.task.sleep(COPY_REVERT_MS, tok) and not hooks.is_disposed() and seq == viewer_copy_seq then
					viewer_copy_state = "idle"
					if viewer_copy_token == tok then
						viewer_copy_token = nil
					end
					viewer:open_or_refresh(true)
				end
			else
				viewer_copy_state = "failed"
				local err_msg = (type(res) == "table" and res.error) or (not ok and res) or "clipboard error"
				if notify_result then
					M.notify("Could not copy Mermaid source: " .. tostring(err_msg), "error")
				end
				viewer:open_or_refresh(true)
			end
		end)
		return true
	end

	--- Clamp and apply inline zoom percentage, invalidating active presentations when changed.
	function viewer:set_zoom(percent, quiet)
		local next_zoom = math.max(MIN_ZOOM_PERCENT, math.min(MAX_ZOOM_PERCENT, math.floor(percent + 0.5)))
		local changed = next_zoom ~= inline_zoom_percent
		inline_zoom_percent = next_zoom
		-- Prefer the public UI invalidation API when available; fall back gracefully on older cores.
		if changed then
			if ctx.ui and type(ctx.ui.invalidate_presentations) == "function" then
				pcall(ctx.ui.invalidate_presentations, ctx.ui, { reason = "mermaid-zoom", zoom_percent = next_zoom })
			elseif ctx.bus then
				pcall(
					ctx.bus.emit,
					ctx.bus,
					"ui/presentation-invalidate",
					{ reason = "mermaid-zoom", zoom_percent = next_zoom }
				)
			end
		end
		viewer:open_or_refresh(true)
		if not quiet then
			M.notify("Mermaid zoom: " .. tostring(inline_zoom_percent) .. "%", "info")
		end
		return inline_zoom_percent
	end

	local function notify_status()
		M.notify(
			string.format(
				"Mermaid: auto=%s, zoom=%d%% (%d active diagrams)",
				hooks.get_automatic() and "on" or "off",
				inline_zoom_percent,
				#active_order
			),
			"info"
		)
	end

	local function handle_copy_command(arg)
		local count = #active_order
		if count == 0 then
			M.notify("No active Mermaid diagrams in this session yet.", "warning")
			return
		end
		local idx = viewer_index
		if arg ~= "" then
			local parsed = tonumber(arg)
			if not parsed or parsed % 1 ~= 0 or parsed < 1 or parsed > count then
				M.notify(string.format("Invalid diagram index %q (expected 1..%d).", arg, count), "warning")
				return
			end
			idx = parsed
		elseif idx < 1 or idx > count then
			idx = count
		end
		local entry = active_diagrams[active_order[idx]]
		viewer:copy_source(entry and entry.source, true)
	end

	local function handle_zoom_command(arg)
		if arg == "" or arg == "status" then
			notify_status()
		elseif arg == "in" or arg == "+" then
			viewer:set_zoom(inline_zoom_percent + ZOOM_STEP_PERCENT)
		elseif arg == "out" or arg == "-" then
			viewer:set_zoom(inline_zoom_percent - ZOOM_STEP_PERCENT)
		elseif arg == "reset" or arg == "0" then
			viewer:set_zoom(100)
		else
			local num = tonumber(arg)
			if num and num % 1 == 0 and num >= MIN_ZOOM_PERCENT and num <= MAX_ZOOM_PERCENT then
				viewer:set_zoom(num)
			else
				M.notify("Usage: /mermaid zoom <50-200|in|out|reset|status>", "warning")
			end
		end
	end

	--- Register the `/mermaid` command handler on `commands`.
	function viewer:register_commands(commands)
		if not commands or not require("mare_lib").callable(commands.register) then
			return
		end
		local USAGE = "Usage: /mermaid [view|on|off|toggle|prefs|copy [index]|zoom <50-200|in|out|reset|status>|status]"
		commands:register("mermaid", {
			description = "Open Mermaid Viewer, copy diagram source, or adjust rendering & zoom",
			args = "[view|on|off|toggle|prefs|copy [index]|zoom <50-200|in|out|reset|status>|status]",
			run = function(args)
				local trimmed = type(args) == "string" and args:match("^%s*(.-)%s*$") or ""
				if trimmed == "" or trimmed == "view" then
					if not viewer:open_or_refresh(false) then
						M.notify("Mermaid Viewer requires an interactive UI.", "warning")
					end
					return
				end
				local sub, arg = trimmed:match("^(%S+)%s*(.-)$")
				if sub == "on" and arg == "" then
					hooks.set_automatic(true)
				elseif sub == "off" and arg == "" then
					hooks.set_automatic(false)
				elseif sub == "toggle" and arg == "" then
					hooks.set_automatic(not hooks.get_automatic())
				elseif (sub == "prefs" or sub == "preference" or sub == "preferences") and arg == "" then
					hooks.open_preference_selector()
				elseif sub == "status" and arg == "" then
					notify_status()
				elseif sub == "copy" then
					handle_copy_command(arg)
				elseif sub == "zoom" then
					handle_zoom_command(arg)
				else
					M.notify(USAGE, "warning")
				end
			end,
		})
	end

	--- Register transcript-scoped keymap actions and bindings for Mermaid Viewer.
	function viewer:register_keymaps()
		if not (mare.keymap and type(mare.keymap.action) == "function" and type(mare.keymap.set) == "function") then
			return
		end
		local function viewer_action(fn)
			return function()
				if type(mare.ui.transcript_title) ~= "function" or mare.ui.transcript_title() ~= VIEWER_TITLE then
					return false
				end
				fn()
			end
		end
		local bindings = {
			{
				"mermaid.zoom_in",
				{ "+", "=" },
				"Zoom Mermaid diagram in",
				function()
					viewer:set_zoom(inline_zoom_percent + ZOOM_STEP_PERCENT, true)
				end,
			},
			{
				"mermaid.zoom_out",
				{ "-" },
				"Zoom Mermaid diagram out",
				function()
					viewer:set_zoom(inline_zoom_percent - ZOOM_STEP_PERCENT, true)
				end,
			},
			{
				"mermaid.zoom_reset",
				{ "0" },
				"Reset Mermaid diagram zoom",
				function()
					viewer:set_zoom(100, true)
				end,
			},
			{
				"mermaid.toggle_source",
				{ "s" },
				"Toggle Mermaid source in viewer",
				function()
					viewer_show_source = not viewer_show_source
					viewer:open_or_refresh(true)
				end,
			},
			{
				"mermaid.copy_source",
				{ "c" },
				"Copy active Mermaid diagram source",
				function()
					if #active_order > 0 then
						local entry = active_diagrams[active_order[viewer_index]]
						viewer:copy_source(entry and entry.source, true)
					end
				end,
			},
			{
				"mermaid.prev",
				{ "[" },
				"Previous Mermaid diagram",
				function()
					if #active_order > 0 then
						viewer:reset_copy_state()
						viewer_index = viewer_index > 1 and (viewer_index - 1) or #active_order
						viewer:open_or_refresh(true)
					end
				end,
			},
			{
				"mermaid.next",
				{ "]" },
				"Next Mermaid diagram",
				function()
					if #active_order > 0 then
						viewer:reset_copy_state()
						viewer_index = viewer_index < #active_order and (viewer_index + 1) or 1
						viewer:open_or_refresh(true)
					end
				end,
			},
		}
		for _, spec in ipairs(bindings) do
			keymap_handles[#keymap_handles + 1] =
				mare.keymap.action(spec[1], viewer_action(spec[4]), { desc = spec[3] })
			for _, key_name in ipairs(spec[2]) do
				keymap_handles[#keymap_handles + 1] =
					mare.keymap.set("transcript", key_name, spec[1], { desc = spec[3] })
			end
		end
	end

	--- Clear active viewer state and close the viewer transcript on session change.
	function viewer:reset_session()
		active_order, active_diagrams = {}, {}
		viewer_index = 1
		viewer:reset_copy_state()
		if type(mare.ui.transcript_close) == "function" then
			pcall(mare.ui.transcript_close, VIEWER_TITLE)
		end
	end

	--- Release keymaps, active diagram cache, and open viewer dialog.
	function viewer:dispose()
		viewer:reset_session()
		for _, handle in ipairs(keymap_handles) do
			if handle and type(handle.remove) == "function" then
				pcall(handle.remove, handle)
			end
		end
		keymap_handles = {}
	end

	return viewer
end

return M
