-- Complementary side-conversation controls and inspection over core `conversations`.
-- Built-in `session` owns `/side`, `/btw`, and `conversations`; this plugin never shadows them.

local SIDE_BLOCKED_COMMANDS = {
	clear = true,
	compact = true,
	fork = true,
	model = true,
	new = true,
	rename = true,
	resume = true,
	retry = true,
	rewind = true,
	switch = true,
	tree = true,
	undo = true,
}

return {
	name = "btw",
	tags = {},
	-- conversations stays required: without it btw is not started
	inject = { "conversations", "agent", "session", "ui" },
	provide = { "btw" },
	contracts = {
		btw = {
			doc = "Side conversation status, transcript, and interaction controls.",
			errors = {
				btw_unavailable = { doc = "side conversation is unavailable or could not toggle/close" },
			},
			methods = {
				status = {
					doc = "Return the current side conversation status snapshot.",
					expose = "lua",
					scope = "session",
					params = {
						type = "object",
						properties = {},
						additionalProperties = false,
					},
					order = {},
					result = { type = "object" },
				},
				transcript = {
					doc = "Return the side conversation transcript snapshot.",
					expose = "lua",
					scope = "session",
					params = {
						type = "object",
						properties = {},
						additionalProperties = false,
					},
					order = {},
					result = { type = "object" },
				},
				view = {
					doc = "Open or focus the side conversation transcript view.",
					expose = "lua",
					scope = "session",
					params = {
						type = "object",
						properties = {},
						additionalProperties = false,
					},
					order = {},
					result = {},
				},
				toggle = {
					doc = "Toggle between the main conversation and the side conversation.",
					expose = "lua",
					scope = "session",
					params = {
						type = "object",
						properties = {},
						additionalProperties = false,
					},
					order = {},
					result = { type = "object" },
					errors = { "btw_unavailable" },
				},
				close = {
					doc = "Close the active side conversation.",
					expose = "lua",
					scope = "session",
					params = {
						type = "object",
						properties = {},
						additionalProperties = false,
					},
					order = {},
					result = { type = "boolean" },
					errors = { "btw_unavailable" },
				},
				ask = {
					doc = "Send a prompt to the side conversation, starting or focusing it if needed.",
					expose = "lua",
					scope = "session",
					params = {
						type = "object",
						properties = {
							text = { type = "string", description = "Prompt text to send to the side conversation." },
							opts = { type = "object", description = "Optional send options (such as replace = true)." },
						},
						required = { "text" },
						additionalProperties = false,
					},
					order = { "text", "opts" },
					result = { type = "object" },
				},
			},
		},
	},
	config_schema = {
		show_parked_status = {
			type = "boolean",
			default = true,
			desc = "Show parked side conversation status in the UI.",
			apply = "live",
		},
		max_turns = {
			type = "integer",
			default = 50,
			min = 1,
			max = 1000,
			desc = "Maximum number of turns retained in a side conversation.",
			apply = "next_op",
		},
		max_output_bytes = {
			type = "integer",
			default = 8192,
			min = 256,
			max = 1048576,
			unit = "bytes",
			desc = "Maximum output size in bytes for a single side-conversation reply.",
			apply = "next_op",
		},
		max_transcript_bytes = {
			type = "integer",
			default = 65536,
			min = 256,
			max = 4194304,
			unit = "bytes",
			desc = "Maximum transcript size in bytes for a side conversation.",
			apply = "next_op",
		},
	},
	apply = function(ctx, cfg)
		local tracker, render
		tracker = require("btw.tracker")(ctx, cfg, function()
			if render then
				render.invalidate()
			end
		end)
		render = require("btw.render")(ctx, cfg, tracker)
		render.invalidate()

		ctx.agent:register_activity("btw", tracker.activity)
		ctx:effect(function()
			return tracker.dispose
		end)

		local service = {}

		function service.status()
			return tracker.status()
		end

		function service.transcript()
			return tracker.transcript()
		end

		function service.view()
			return render.view()
		end

		local function fail_btw(msg)
			local text = tostring(msg or "Side conversation unavailable")
			if mare and type(mare.error) == "function" then
				error(mare.error("btw.btw_unavailable", text), 0)
			end
			error(text, 0)
		end

		function service.toggle()
			local res, err = ctx.conversations:toggle()
			if res == nil and err ~= nil then
				fail_btw(err)
			end
			return res
		end

		function service.close()
			local res, err = ctx.conversations:close()
			if res == nil and err ~= nil then
				fail_btw(err)
			end
			return res
		end

		function service.ask(_, _, text, opts)
			assert(type(text) == "string", "btw ask text must be a string")
			opts = opts or {}
			assert(type(opts) == "table", "btw ask options must be a table")
			local current = ctx.conversations:info()
			if opts.replace and current then
				ctx.conversations:close()
				current = nil
			end
			if not current then
				local started, err = ctx.conversations:start()
				if not started then
					return { error = err or "Unable to start side conversation" }
				end
			elseif not current.selected then
				local toggled, err = ctx.conversations:toggle()
				if not toggled then
					return { error = err or "Unable to focus side conversation" }
				end
			end
			local prompt_opts = opts.images and { images = opts.images } or nil
			local started = ctx.agent:prompt(text, prompt_opts)
			if type(started) == "table" and started.turn_id then
				tracker.record_prompt(started.turn_id, text)
				return ctx.agent:wait(started.turn_id)
			end
			return started
		end

		-- In the UI's ordered submit chain, btw runs before commands (20) and shell-mode (30);
		-- returning true stops further handlers.
		ctx.ui:handler("submit", "btw", { order = 10 }, function(ev)
			if type(ev) ~= "table" or type(ev.text) ~= "string" then
				return
			end
			local trimmed = ev.text:match("^%s*(.-)%s*$")
			if trimmed == "" then
				return
			end
			local info = ctx.conversations:info()
			local cmd, rest = trimmed:match("^/([%w%-_:]+)%s*(.*)$")
			if info and info.selected then
				tracker.clear_pending_open()
				if cmd then
					if SIDE_BLOCKED_COMMANDS[cmd] then
						ev.handled = true
						ev.command_result = {
							status = "rejected",
							reason = ("/%s is not available in a side conversation"):format(cmd),
						}
						ev.result = ev.command_result
						mare.ui.notify(("/%s is not available in a side conversation"):format(cmd), "warning")
					end
				elseif trimmed:sub(1, 1) ~= "!" then
					tracker.queue_prompt(trimmed)
				end
			elseif cmd == "side" or cmd == "btw" then
				local arg = (rest or ""):match("^%s*(.-)%s*$")
				if arg ~= "" and arg ~= "back" and arg ~= "close" and arg ~= "toggle" then
					tracker.set_pending_open(arg)
				else
					tracker.clear_pending_open()
				end
			else
				tracker.clear_pending_open()
			end
			return ev.handled == true
		end)

		require("mare_lib").service(ctx, "btw", service)

		ctx.ui:action("btw.toggle", function()
			local ok, err = ctx.conversations:toggle()
			if not ok then
				mare.ui.notify(err or "No side conversation is open", "info")
			end
		end, { desc = "Toggle between main and side conversation" })

		ctx.ui:action("btw.view", function()
			render.view()
		end, { desc = "View side conversation transcript" })

		ctx.ui:action("btw.close", function()
			if not ctx.conversations:info() then
				mare.ui.notify("No side conversation is open", "info")
				return
			end
			ctx.conversations:close()
		end, { desc = "Close and discard side conversation" })
	end,
}
