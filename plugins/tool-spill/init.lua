return {
	name = "tool-spill",
	tags = {},
	inject = { "tools", "session", "llm" },
	config_schema = {
		max_bytes = {
			type = "integer",
			default = 51200,
			min = 512,
			unit = "bytes",
			desc = "Inline tool result byte threshold before spilling to output storage.",
			apply = "next_op",
		},
		max_lines = {
			type = "integer",
			default = 2000,
			min = 3,
			unit = "lines",
			desc = "Inline tool result line threshold before spilling to output storage.",
			apply = "next_op",
		},
		cleanup_period_days = {
			type = "integer",
			default = 30,
			min = 1,
			unit = "days",
			desc = "Retention period in days for local spilled output files.",
			apply = "reload",
		},
		exclude = {
			type = "list",
			items = { type = "string" },
			default = { "read", "bash", "powershell", "read_spill" },
			desc = "Tool names excluded from automatic output spilling.",
			apply = "next_op",
		},
		backend = {
			type = "string",
			default = nil,
			nullable = true,
			desc = 'Spill storage backend; only "local" (or unset/empty for the default local store) is supported, and any other value errors (cannot be combined with root or non-default cleanup_period_days).',
			apply = "reload",
		},
		root = {
			type = "string",
			default = nil,
			nullable = true,
			desc = "Optional local spill directory override (cannot be combined with backend).",
			apply = "reload",
		},
		max_inline_tokens = {
			type = "integer",
			default = nil,
			nullable = true,
			min = 16,
			max = 9007199254740991,
			unit = "tokens",
			desc = "Optional inline token ceiling before spilling tool output.",
			apply = "next_op",
		},
	},
	apply = function(ctx, cfg)
		local notice = require("spill.notice")
		local retain = require("spill.retain")
		local backend = cfg.backend
		local local_store = nil
		if cfg.root or cfg.cleanup_period_days ~= 30 then
			assert(not backend, "spill root/cleanup options cannot be combined with a selected backend")
			local_store = mare.spill.new_local({ root = cfg.root, cleanup_period_days = cfg.cleanup_period_days })
			ctx:effect(function()
				return local_store.dispose
			end)
		elseif backend ~= nil and backend ~= "" and backend ~= "local" then
			error("spill backend unavailable: " .. tostring(backend), 0)
		end
		local backend_impl = local_store or mare.spill
		-- handles carry no store identity, and other producers (session-search events, mermaid
		-- artifacts) save to the default store: under a custom root a read falls back to it, and
		-- the configured store's own error is the one reported when neither has the handle
		local function read_with(method)
			return function(spill_id, opts)
				local ok, page = pcall(backend_impl[method], spill_id, opts)
				if ok or not local_store then
					return ok and page or error(page, 0)
				end
				local found, fallback = pcall(mare.spill[method], spill_id, opts)
				return found and fallback or error(page, 0)
			end
		end
		local storage = {
			save = backend_impl.save,
			save_bytes = backend_impl.save_bytes,
			delete = backend_impl.delete,
			read = read_with("read"),
			read_bytes = read_with("read_bytes"),
		}
		local function is_excluded(tool_name)
			for _, name in ipairs(cfg.exclude or {}) do
				if name == tool_name then
					return true
				end
			end
			return false
		end
		local function spill_result(result, call, budget)
			-- a cancelled call keeps its output as is and saves nothing: natively this listener runs in
			-- the plugin's own context, not the cancelled call's task, so a save would no longer be
			-- cancelled with it (the legacy listener's save failed and the original was kept)
			if result.cancelled then
				return result
			end
			local details_exempt = type(result.details) == "table" and result.details.spill_exempt
			if
				is_excluded(call.name)
				or result.no_truncate
				or result.spill_exempt
				or details_exempt
				or result.output_notice
				or result.truncated
			then
				return result
			end
			local ok, value, warn = pcall(retain, result, budget, cfg, storage, ctx.llm, call)
			if ok then
				if warn then
					mare.log("warn", warn)
				end
				return value
			end
			local err_str = tostring(value)
			if err_str:find("output budget cannot fit", 1, true) then
				mare.log("error", "spill: " .. err_str)
				local out = {}
				for k, v in pairs(result) do
					out[k] = v
				end
				local details = {}
				if type(result.details) == "table" then
					for k, v in pairs(result.details) do
						details[k] = v
					end
				end
				details.error_code = "output_budget_exceeded"
				details.spill_error = err_str
				out.content = type(result.content) == "table" and {} or ""
				out.output_notice = nil
				out.truncated = true
				out.is_error = true
				out.error_code = "output_budget_exceeded"
				out.details = details
				return out
			end
			mare.log("warn", "spill: keeping original output: " .. err_str)
			return result
		end
		-- tool/result is a waterfall: spill must see the final value after every other rewriter.
		-- Waterfall listeners take `(data, ev)` where `data = { result, call, operation }`,
		-- and a prepended listener calling `ev.next()` first sees what inner rewriters produced.
		ctx:on("tool/result", function(data, ev)
			local out = ev.next()
			if type(out) == "table" and out.result ~= nil then
				out.result = spill_result(out.result, out.call, out.operation)
			end
			return out
		end, { prepend = true })
		ctx.tools:register("read_spill", {
			description = "Read a saved complete tool result by its session-owned recovery handle. Use offset and limit for line pagination; explicit read restrictions still apply.",
			parameters = {
				type = "object",
				properties = {
					handle = { type = "string" },
					offset = { type = "integer" },
					limit = { type = "integer" },
					cursor = { type = "integer" },
				},
				required = { "handle" },
				additionalProperties = false,
			},
			side_effect = "read",
			idempotent = true,
			summary = function(args)
				local h = tostring(args and args.handle or "")
				if #h > 40 then
					h = notice.utf8_prefix(h, 37) .. "..."
				end
				return ("read_spill(%s)"):format(h)
			end,
			execute = function(args)
				local page = storage.read(args.handle, {
					session_id = ctx.session:info().session_id,
					offset = args.offset,
					limit = args.limit,
					cursor = args.cursor,
				})
				return {
					content = page.content
						.. (
							page.more
								and ("\n[more output remains; continue with cursor=%d and offset=1]"):format(
									page.next_byte
								)
							or ""
						),
					no_truncate = true,
				}
			end,
		})
	end,
}
