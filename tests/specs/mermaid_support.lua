local support = assert(load(mare.fs.read("tests/specs/support.lua"), "@tests/specs/support.lua"))()

local plugin = support.load_plugin("mermaid", {
	"mermaid.adapter",
	"mermaid.png",
	"mermaid.profile",
	"mermaid.queue",
	"mermaid.runtime",
	"mermaid.viewer",
})

local M = {}

M.plugin = plugin
M.support = support

function M.make_png_bytes(w, h)
	w = w or 120
	h = h or 80
	return "\137PNG\r\n\26\n\0\0\0\13IHDR" .. string.pack(">I4I4", w, h) .. "\8\6\0\0\0rest"
end

function M.wait_until(pred, timeout_ms, step_ms)
	local deadline = timeout_ms or 3000
	local step = step_ms or 5
	local elapsed = 0
	while not pred() do
		if elapsed >= deadline then
			return false
		end
		mare.task.sleep(step)
		elapsed = elapsed + step
	end
	return true
end

function M.make_env(opts)
	opts = opts or {}
	local events = {}
	local emitted = {}
	local notifications = {}
	local commands = {}
	local keymap_actions = {}
	local keymap_bindings = {}
	local active_transcript = nil
	local presenters = {}
	local registered_tools = {}
	local session_records = {}
	local outputs = {}
	local proc_runs = {}
	local proc_gate_factory = opts.proc_gate_factory
	local active_png = M.make_png_bytes(240, 160)
	local clipboard_calls = {}
	local clipboard_handler = opts.clipboard_copy
		or function(text)
			return { ok = true, method = "native", verified = true, bytes = #text }
		end
	local select_handler = opts.select_fn
	local images_mode = opts.images_mode ~= nil and opts.images_mode or "kitty"
	local connected = opts.connected ~= nil and opts.connected or true

	local orig = {
		proc = mare.proc,
		proc_run = mare.proc and mare.proc.run,
		ui_caps = mare.ui.caps,
		ui_connected = mare.ui.connected,
		ui_width = mare.ui.width,
		ui_height = mare.ui.height,
		ui_style = mare.ui.style,
		ui_renderer = mare.ui.renderer,
		ui_notify = mare.ui.notify,
		ui_transcript = mare.ui.transcript,
		ui_transcript_title = mare.ui.transcript_title,
		ui_transcript_close = mare.ui.transcript_close,
		ui_select = mare.ui.select,
		clipboard = mare.clipboard,
		clipboard_copy = mare.clipboard and mare.clipboard.copy,
		clipboard_max_osc52_bytes = mare.clipboard and mare.clipboard.max_osc52_bytes,
		keymap = mare.keymap,
		keymap_action = mare.keymap and mare.keymap.action,
		keymap_set = mare.keymap and mare.keymap.set,
		spill = mare.spill,
	}

	-- artifacts go to core mare.spill (no ctx.output service)
	mare.spill = {
		save_bytes = function(session_id, raw, popts)
			local spill_id = "out-" .. (#outputs + 1)
			outputs[#outputs + 1] = { spill_id = spill_id, session_id = session_id, raw = raw, opts = popts }
			return { spill_id = spill_id, size = #raw, backend = "mem" }
		end,
		read_bytes = function(spill_id, opts)
			local session_id = opts and opts.session_id
			for _, o in ipairs(outputs) do
				if o.session_id == session_id and o.spill_id == spill_id then
					return { bytes = o.raw, more = false, next_byte = #o.raw, size = #o.raw }
				end
			end
			error("spill object does not belong to this session", 0)
		end,
		delete = function(spill_id, opts)
			local session_id = opts and opts.session_id
			for i, o in ipairs(outputs) do
				if o.session_id == session_id and o.spill_id == spill_id then
					table.remove(outputs, i)
					return true
				end
			end
			return false
		end,
	}

	mare.proc = mare.proc or {}
	mare.proc.run = function(spec)
		proc_runs[#proc_runs + 1] = spec
		if proc_gate_factory then
			local gate = proc_gate_factory(spec, #proc_runs)
			if gate then
				if spec.cancel then
					mare.task.select(function()
						gate:wait()
					end, function()
						spec.cancel:wait()
					end)
					if spec.cancel:is_cancelled() then
						return { success = false, cancelled = true, code = -1, stdout = "", stderr = "" }
					end
				else
					gate:wait()
				end
			end
		end
		local payload = mare.json.encode({
			png = mare.crypto.base64_encode(active_png),
			version = "12.0.0",
			width = 240,
			height = 160,
		})
		return { success = true, code = 0, stdout = payload, stderr = "" }
	end

	mare.ui.caps = function()
		return { images = images_mode, cell_px = { 8, 16 } }
	end
	mare.ui.connected = function()
		return connected
	end
	mare.ui.width = function()
		return opts.width or 80
	end
	mare.ui.height = function()
		return opts.height or 24
	end
	mare.ui.style = function()
		return { bg = "#1e1e2e" }
	end
	mare.ui.renderer = function()
		return function() end
	end
	mare.ui.notify = function(msg, level)
		notifications[#notifications + 1] = { msg = msg, level = level }
	end
	mare.ui.transcript = function(title, node, topts)
		active_transcript = { title = title, node = node, opts = topts }
	end
	mare.ui.transcript_title = function()
		return active_transcript and active_transcript.title or nil
	end
	mare.ui.transcript_close = function(title)
		if not title or (active_transcript and active_transcript.title == title) then
			active_transcript = nil
		end
	end
	mare.ui.select = function(sopts)
		if select_handler then
			return select_handler(sopts)
		end
		return nil
	end

	mare.clipboard = mare.clipboard or {}
	mare.clipboard.max_osc52_bytes = 100000
	mare.clipboard.copy = function(text)
		clipboard_calls[#clipboard_calls + 1] = text
		return clipboard_handler(text)
	end

	mare.keymap = mare.keymap or {}
	mare.keymap.action = function(name, fn, kopts)
		local entry = { name = name, fn = fn, opts = kopts }
		keymap_actions[name] = entry
		return {
			name = name,
			remove = function()
				if keymap_actions[name] == entry then
					keymap_actions[name] = nil
				end
			end,
		}
	end
	mare.keymap.set = function(mode, key, action, kopts)
		local entry = { mode = mode, key = key, action = action, opts = kopts }
		keymap_bindings[#keymap_bindings + 1] = entry
		return {
			remove = function()
				entry.removed = true
			end,
		}
	end

	local dispose_cbs = {}
	local ctx = {
		tools = {
			capabilities = function()
				return { result_pipeline = 1 }
			end,
			register = function(_, name, def)
				registered_tools[name] = def
			end,
			execute = function(_, call, eopts)
				if eopts and eopts.on_state then
					local def = registered_tools[call.name]
					assert(eopts.on_state(call, "prepared", def) == true)
					assert(eopts.on_state(call, "started", def) == true)
				end
				local res = registered_tools[call.name].execute(call.arguments, { cancel = eopts and eopts.cancel })
				return res, call, res
			end,
		},
		ui = {
			-- like the core image reader: resolve the artifact by its (opaque) handle through
			-- mare.spill and check the bytes; a failure falls back to text in the viewer
			artifact_image = function(_, artifact, aopts)
				local page = mare.spill.read_bytes(artifact.spill_id, { session_id = artifact.session_id })
				assert(mare.crypto.sha256(page.bytes) == artifact.sha256, "artifact bytes do not match")
				return {
					kind = "artifact_image",
					artifact = artifact,
					read_bytes = #page.bytes,
					max_rows = aopts.max_rows,
					max_cols = aopts.max_cols,
					fallback = aopts.fallback,
				}
			end,
			markdown_presenter = function(_, lang, def)
				presenters[lang] = def
				return function()
					if presenters[lang] == def then
						presenters[lang] = nil
					end
				end
			end,
		},
		session = {
			info = function()
				return {
					session_id = "s1",
					session_epoch = "epoch-1",
					readonly = false,
					unstable = false,
					ephemeral = false,
				}
			end,
			switching = function()
				return false
			end,
			add_record = function(_, kind, data)
				session_records[#session_records + 1] = { kind = kind, data = data }
				return { durable = true }
			end,
			list_records = function(_, kind)
				local out = {}
				for _, r in ipairs(session_records) do
					if r.kind == kind then
						out[#out + 1] = r.data
					end
				end
				return { data = out }
			end,
			record_tool_state = function()
				return "entry-1"
			end,
		},
		commands = {
			register = function(_, name, def)
				commands[name] = def
			end,
		},
		inject = function(self, names, fn)
			if names[1] == "commands" then
				fn(setmetatable({
					commands = {
						register = function(_, cname, def)
							commands[cname] = def
						end,
					},
				}, { __index = self }))
			end
		end,
		emit = function(_, name, payload)
			emitted[#emitted + 1] = { name = name, payload = payload }
		end,
		on = function(_, name, fn)
			events[name] = fn
		end,
		effect = function(_, setup)
			local fn = setup()
			dispose_cbs[#dispose_cbs + 1] = fn
		end,
		bail = function()
			return true
		end,
	}

	return {
		ctx = ctx,
		presenters = presenters,
		tools = registered_tools,
		proc_runs = proc_runs,
		commands = commands,
		emitted = emitted,
		notifications = notifications,
		clipboard_calls = clipboard_calls,
		set_clipboard_handler = function(fn)
			clipboard_handler = fn
		end,
		set_select_handler = function(fn)
			select_handler = fn
		end,
		keymap_actions = keymap_actions,
		keymap_bindings = keymap_bindings,
		set_transcript = function(title)
			active_transcript = title and { title = title } or nil
		end,
		get_transcript = function()
			return active_transcript
		end,
		dispose = function()
			for _, fn in ipairs(dispose_cbs) do
				fn()
			end
		end,
		restore = function()
			mare.spill = orig.spill
			if orig.proc then
				mare.proc.run = orig.proc_run
			else
				mare.proc = nil
			end
			mare.ui.caps = orig.ui_caps
			mare.ui.connected = orig.ui_connected
			mare.ui.width = orig.ui_width
			mare.ui.height = orig.ui_height
			mare.ui.style = orig.ui_style
			mare.ui.renderer = orig.ui_renderer
			mare.ui.notify = orig.ui_notify
			mare.ui.transcript = orig.ui_transcript
			mare.ui.transcript_title = orig.ui_transcript_title
			mare.ui.transcript_close = orig.ui_transcript_close
			mare.ui.select = orig.ui_select
			if orig.clipboard then
				mare.clipboard.copy = orig.clipboard_copy
				mare.clipboard.max_osc52_bytes = orig.clipboard_max_osc52_bytes
			else
				mare.clipboard = nil
			end
			if orig.keymap then
				mare.keymap.action = orig.keymap_action
				mare.keymap.set = orig.keymap_set
			else
				mare.keymap = nil
			end
		end,
	}
end

function M.apply_plugin(env, overrides)
	local cfg = support.default_config(plugin)
	if overrides then
		for k, v in pairs(overrides) do
			cfg[k] = v
		end
	end
	plugin.apply(env.ctx, cfg)
	return plugin, cfg
end

function M.render_request(overrides)
	local req = {
		source = "graph TD\nA-->B",
		phase = "closed",
		block_id = "blk-1",
		width = 80,
		height = 24,
		supports_images = true,
		supports_artifact_images = true,
		session_id = "s1",
		session_epoch = "epoch-1",
		cancel = mare.task.token(),
	}
	if overrides then
		for k, v in pairs(overrides) do
			req[k] = v
		end
	end
	return req
end

return M
