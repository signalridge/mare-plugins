local D = require("presets.definition")

local LIVE_NOTE =
	"Prompt/tools: live session only. Model selection uses ordinary /model saved/recent behavior; clear does not restore it. Tool declarations are constrained; permissions apply independently."

local function reject_notice(msg)
	mare.ui.notify(msg, "error")
	return { status = "rejected", reason = msg }
end

local function reject_status(reason, status)
	return nil, { status = status or "rejected", reason = reason }
end

return function(ctx, rt)
	local dialog_token = nil
	rt.set_on_dispose(function()
		if dialog_token then
			dialog_token:cancel()
		end
	end)

	local function inspect_preset(inspected)
		local def = rt.read(inspected)
		if def then
			local body = table.concat(
				D.format_definition_lines(def, rt.is_default(inspected), rt.staged_id() == inspected),
				"\n"
			)
			mare.ui.notify(def.name .. " [" .. inspected .. "]\n" .. (def.description or "") .. "\n" .. body, "info")
			return
		end
		if rt.broken_lines[inspected] then
			mare.ui.notify(inspected .. " [broken]\n" .. table.concat(rt.broken_lines[inspected], "\n"), "warning")
			return
		end
		return reject_notice("Unknown preset: " .. inspected)
	end

	local function run_target_cmd(arg, getter, setter, label, set_label)
		if not arg then
			mare.ui.notify(label .. (getter() or "none"), "info")
			return
		end
		local ok, err = setter(arg ~= "clear" and arg or nil)
		if not ok then
			return reject_notice(err)
		end
		mare.ui.notify((set_label or label) .. (getter() or "none"), "info")
	end

	local function pick_preset()
		if not (mare.ui.connected and mare.ui.connected()) then
			return reject_status("Preset picker requires a UI; use /preset list or /preset <id>")
		end
		local rows, items, selected, expected, versions = rt.list(), {}, 1, rt.generation(), {}
		for index, row in ipairs(rows) do
			local definition = row.definition
			versions[row.id] = definition and mare.json.encode(definition)
			if row.current then
				selected = index
			end
			items[index] = {
				id = row.id,
				label = row.name .. D.format_badges(row),
				detail = row.broken and ("Broken: " .. row.broken) or row.description,
				disabled = row.broken ~= nil,
				preview = definition and mare.ui.Lines(D.format_definition_lines(definition, row.default, row.staged))
					or (rt.broken_lines[row.id] and mare.ui.Lines(rt.broken_lines[row.id]) or nil),
			}
		end
		local token = mare.task.token()
		if dialog_token then
			dialog_token:cancel()
		end
		dialog_token = token
		local picked, tab_or_reason = mare.ui.select({
			title = "Presets",
			items = items,
			selected = selected,
			cancel = token,
			body = "Choose a preset. Esc leaves the current selection unchanged.",
		})
		if dialog_token ~= token then
			return reject_status("Preset dialog was replaced", "cancelled")
		end
		dialog_token = nil
		rt.sync()
		if not picked then
			local reason = tab_or_reason
			return reject_status(
				reason or "Preset selection cancelled",
				(reason == "unavailable" or reason == "disconnected") and "rejected" or "cancelled"
			)
		end
		local row = rows[picked]
		local latest = row and rt.read(row.id)
		if rt.generation() ~= expected or not row or not latest or mare.json.encode(latest) ~= versions[row.id] then
			return reject_status("Session or preset changed while choosing")
		end
		return row.id
	end

	ctx.commands:register("preset", {
		description = "Apply model selection, prompt and tool declaration preferences",
		args = "[id|clear|list|inspect id|default [id|clear]|stage [id|clear]|help [id]]",
		availability = "idle",
		run = function(args)
			rt.sync()
			local id = args:match("^%s*(.-)%s*$")
			if id == "help" then
				mare.ui.notify(
					"Usage: /preset [id|clear|list|inspect <id>|default [id|clear]|stage [id|clear]|help [id]]\n"
						.. LIVE_NOTE,
					"info"
				)
				return
			end
			local target_id = id:match("^help%s+(.+)$") or id:match("^inspect%s+(.+)$")
			if target_id then
				return inspect_preset(target_id)
			end
			if id == "default" or id:match("^default%s+") then
				return run_target_cmd(
					id:match("^default%s+(.+)$"),
					rt.effective_default,
					rt.set_default,
					"Default preset: "
				)
			end
			if id == "stage" or id:match("^stage%s+") then
				return run_target_cmd(
					id:match("^stage%s+(.+)$"),
					rt.staged_id,
					rt.stage_preset,
					"Staged preset: ",
					"Staged preset for next session: "
				)
			end
			if id == "" then
				local picked, err_res = pick_preset()
				if not picked then
					return err_res
				end
				id = picked
			elseif id == "list" then
				id = ""
			end
			if id ~= "" then
				local ok, err = rt.apply(id)
				if not ok then
					return reject_notice(err)
				end
			end
			local ids = {}
			for _, row in ipairs(rt.list()) do
				local tail = row.broken and (" — broken: " .. row.broken)
					or (row.description and " — " .. row.description or "")
				ids[#ids + 1] = ("%s [%s]%s%s"):format(row.name, row.id, D.format_badges(row), tail)
			end
			mare.ui.notify(
				("Preset: %s. %s\n%s"):format(rt.active() or "none", LIVE_NOTE, table.concat(ids, "\n")),
				"info"
			)
		end,
	})
end
