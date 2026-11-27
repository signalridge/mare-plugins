-- Independent implementation of bounded Lua codemode orchestration; public mare APIs only.
return {
	name = "codemode",
	tags = {},
	inject = { "tools", "cells" },
	provide = { "codemode" },
	contracts = {
		codemode = {
			doc = "Bounded Lua codemode execution capability.",
			methods = {
				available = {
					doc = "Return whether the codemode service is available.",
					expose = "lua",
					scope = "host",
					params = {
						type = "object",
						properties = {},
						additionalProperties = false,
					},
					order = {},
					result = { type = "boolean" },
				},
			},
		},
	},
	config_schema = {
		timeout_ms = {
			type = "integer",
			default = 60000,
			min = 1,
			unit = "ms",
			apply = "next_op",
			desc = "Default timeout in milliseconds for codemode cell execution.",
		},
	},
	apply = function(ctx, cfg)
		local view = require("codemode.view")
		require("mare_lib").service(ctx, "codemode", {
			available = function()
				return true
			end,
		})
		-- context and commands are optional: each registration lives in a follower that runs while
		-- the service is up and is withdrawn with it.
		ctx:inject({ "context" }, function(sub)
			sub.context:section({
				name = "codemode:guidance",
				order = 850,
				interpolate = false,
				text = "Use codemode to combine multiple tool calls, filter or transform large intermediate results in Lua, or call codemode-tier MCP tools (inspect ALL_TOOLS and call describe_tool(name) for schemas). Use codemode_wait to poll or terminate a running cell ID.",
			})
		end)
		ctx:inject({ "commands" }, function(sub)
			sub.commands:register("codemode", {
				description = "Manage script memory (/codemode status|reset|stop [cell_id])",
				complete = function()
					return { "status", "reset", "stop" }
				end,
				run = function(args)
					args = (args or ""):match("^%s*(.-)%s*$")
					local cell_id = args:match("^stop%s+(%S+)$")
					if cell_id then
						local ok, result = pcall(ctx.cells.wait, ctx.cells, cell_id, { terminate = true })
						if not ok or type(result) ~= "table" then
							mare.ui.notify(("Cell %s not found or already completed."):format(cell_id), "warning")
						elseif result.status == "cancelled" then
							mare.ui.notify(("Cell %s terminated."):format(cell_id), "info")
						elseif result.status == "completed" or result.status == "failed" then
							mare.ui.notify(("Cell %s already finished (%s)."):format(cell_id, result.status), "info")
						else
							mare.ui.notify(("Cell %s stop unconfirmed."):format(cell_id), "error")
						end
					elseif args == "reset" or args == "stop" then
						local ok = pcall(ctx.cells.reset, ctx.cells)
						mare.ui.notify(
							ok and "Program memory reset; completed tool effects remain."
								or "Script stop unconfirmed; memory was not reset.",
							ok and "info" or "error"
						)
					elseif args == "" or args == "status" then
						local state = ctx.cells:get()
						local active_cells, cursor = 0, nil
						repeat
							local page = ctx.cells:list(cursor and { cursor = cursor } or nil)
							active_cells = active_cells + #(page and page.data or {})
							cursor = page and page.next_cursor or nil
						until not cursor
						mare.ui.notify(
							("Scripts running: %d; active cells: %d; stored keys: %d; mode: %s. Memory is session-local and cleared on reload/resume."):format(
								state.running,
								active_cells,
								state.stored_keys,
								state.retains_state and "retained" or "fresh"
							),
							"info"
						)
					else
						mare.ui.notify("Usage: /codemode status|reset|stop [cell_id]", "warning")
					end
				end,
			})
		end)
		local function codemode_description()
			local ok, status = pcall(function()
				return ctx.cells:get()
			end)
			local retained = ok and type(status) == "table" and status.retains_state == true
			local vm_kind = retained
					and "bounded, retained capability VM (top-level globals and functions persist across calls in this session; restart, timeout, cancellation, /codemode reset, or sandbox/permission change clears retained state while completed tool effects remain)"
				or "bounded, fresh capability VM (state is not retained between runs except via store/load)"
			local timeout_desc = cfg.timeout_ms == false and "disabled by default"
				or ("defaults to " .. tostring(cfg.timeout_ms) .. " ms")
			return ('Execute Lua text in a %s. Only explicit outputs and return values reach the model; long scripts yield a cell ID for codemode_wait. Await pending tool calls and timers before the script ends; unfinished calls and timers are cancelled when the run finishes. Optionally start input with a first-line pragma `-- @exec: {"yield_time_ms": 10000, "max_output_tokens": 10000}` (`yield_time_ms` defaults to 10000 ms; `max_output_tokens` defaults to 10000 tokens; `timeout_ms` %s, or `false` to disable). Call tools with tools[name](arguments); filter ALL_TOOLS by name/description and call describe_tool(name) for schemas. json.null and json.array() preserve JSON null and empty arrays. No file/network/process access except through separately authorized tools. Tool failures raise errors (use pcall). Calls already made are not rolled back. Use parallel(calls,{settled=true}) for safe batches; mutating calls run alone. text/image/audio/generatedImage/exit, notify/yield_control, and session-local store/load are available. setTimeout/clearTimeout and sleep use bounded run-local timers.'):format(
				vm_kind,
				timeout_desc
			)
		end
		ctx.tools:register("codemode", {
			description = codemode_description,
			allow_nested = false,
			side_effect = "external",
			idempotent = false,
			timeout_ms = false,
			summary = function(args)
				return view.summary("codemode", args)
			end,
			render = function(args, result, expanded)
				return view.render("codemode", args, result, expanded)
			end,
			parameters = {
				type = "object",
				additionalProperties = false,
				required = { "input" },
				properties = {
					input = {
						type = "string",
						description = "Lua source text to execute (1..65536 bytes), optionally starting with a first-line `-- @exec: {...}` pragma.",
					},
					yield_time_ms = {
						type = "integer",
						description = "Yield early with a cell_id after this many milliseconds (0..600000; default 10000).",
					},
					max_output_tokens = {
						type = "integer",
						description = "Maximum output token budget for this observation (0..1000000; default 10000).",
					},
					timeout_ms = {
						oneOf = { { type = "integer" }, { type = "boolean", enum = { false } } },
						description = "Elapsed wall-clock deadline in milliseconds (1..600000), or false to disable.",
					},
				},
			},
			freeform = { syntax = "lark", definition = "start: source\nsource: /[\\s\\S]+/" },
			execute = function(args, tctx)
				local code, options = require("codemode.source")(args.input, args)
				local names, cursor = {}, nil
				repeat
					local page = ctx.cells:list_tools(cursor and { cursor = cursor } or nil)
					for _, d in ipairs(page and page.data or {}) do
						names[#names + 1] = d.name
					end
					cursor = page and page.next_cursor or nil
				until not cursor
				options.capabilities = names
				options.wait_cancel = function()
					return tctx.cancel
				end
				if options.timeout_ms == nil then
					options.timeout_ms = cfg.timeout_ms
				end
				return require("codemode.present")(ctx.cells:start(code, options), options.max_output_tokens)
			end,
		})
		ctx.tools:register("codemode_wait", {
			description = "Wait for a running script cell. Returns only output since the previous yield/wait. `yield_time_ms` defaults to 10000 ms; `max_output_tokens` defaults to 10000 tokens (including when `terminate=true`). A completed cell is consumed once; terminate=true cancels and confirms worker cleanup.",
			allow_nested = false,
			side_effect = "external",
			idempotent = false,
			timeout_ms = false,
			summary = function(args)
				return view.summary("codemode_wait", args)
			end,
			render = function(args, result, expanded)
				return view.render("codemode_wait", args, result, expanded)
			end,
			parameters = {
				type = "object",
				additionalProperties = false,
				required = { "cell_id" },
				properties = {
					cell_id = { type = "string", description = "Identifier of the running codemode cell." },
					yield_time_ms = {
						type = "integer",
						description = "Wait before yielding more output (0..600000 ms; default 10000).",
					},
					max_output_tokens = {
						type = "integer",
						description = "Output token budget for this wait or terminate observation (0..1000000; default 10000).",
					},
					terminate = {
						type = "boolean",
						description = "True stops the running cell and confirms cleanup; false or omitted waits for output.",
					},
				},
			},
			execute = function(args, tctx)
				assert(
					type(args.cell_id) == "string" and #args.cell_id > 0 and #args.cell_id <= 128,
					"cell_id must be a non-empty string up to 128 bytes"
				)
				if args.yield_time_ms ~= nil then
					assert(
						math.type(args.yield_time_ms) == "integer"
							and args.yield_time_ms >= 0
							and args.yield_time_ms <= 600000,
						"invalid wait option: yield_time_ms"
					)
				end
				if args.max_output_tokens ~= nil then
					assert(
						math.type(args.max_output_tokens) == "integer"
							and args.max_output_tokens >= 0
							and args.max_output_tokens <= 1000000,
						"invalid wait option: max_output_tokens"
					)
				end
				if args.terminate ~= nil then
					assert(type(args.terminate) == "boolean", "invalid wait option: terminate")
				end
				local options = table.copy(args)
				options.cell_id = nil
				options.cancel = function()
					return tctx.cancel
				end
				return require("codemode.present")(ctx.cells:wait(args.cell_id, options), options.max_output_tokens)
			end,
		})
	end,
}
