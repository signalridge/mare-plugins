return {
	name = "toolbelt",
	tags = {},
	inject = { "tools" },
	config_schema = {
		grep = {
			type = "boolean",
			default = true,
			desc = "Register the read-only `grep` tool backed by ripgrep (`rg`).",
		},
		find = {
			type = "boolean",
			default = true,
			desc = "Register the read-only `find` tool backed by `fd`.",
		},
		code_search = {
			type = "boolean",
			default = true,
			desc = "Register the read-only `code_search` tool backed by `ast-grep` (falling back to `sg`).",
		},
		doc_search = {
			type = "boolean",
			default = true,
			desc = "Register the read-only `doc_search` tool backed by ripgrep-all (`rga`).",
		},
		timeout_ms = {
			type = "integer",
			default = 30000,
			min = 1000,
			unit = "ms",
			apply = "next_op",
			desc = "Execution timeout in milliseconds for each toolbelt process call.",
		},
		max_output_bytes = {
			type = "integer",
			default = 1048576,
			min = 1024,
			unit = "bytes",
			apply = "next_op",
			desc = "Maximum captured and formatted output size in bytes.",
		},
		head_limit_default = {
			type = "integer",
			default = 250,
			min = 1,
			apply = "next_op",
			desc = "Default maximum number of returned entries when `head_limit` is omitted.",
		},
	},
	apply = function(ctx, cfg)
		for _, flag in ipairs({ "grep", "find", "code_search", "doc_search" }) do
			assert(type(cfg[flag]) == "boolean", flag .. " must be a boolean")
		end
		for _, key in ipairs({ "timeout_ms", "max_output_bytes", "head_limit_default" }) do
			assert(
				type(cfg[key]) == "number" and cfg[key] % 1 == 0 and cfg[key] > 0 and cfg[key] < 2147483648,
				key .. " must be a positive bounded integer"
			)
		end
		assert(cfg.timeout_ms >= 1000, "timeout_ms must be >= 1000")
		assert(cfg.max_output_bytes >= 1024, "max_output_bytes must be >= 1024")

		local existing = {}
		if type(ctx.tools.list) == "function" then
			for _, def in ipairs(ctx.tools:list() or {}) do
				if type(def) == "table" and type(def.name) == "string" then
					existing[def.name] = true
				end
			end
		end

		local function has_existing_tool(name)
			if existing[name] then
				return true
			end
			return type(ctx.tools.get) == "function" and ctx.tools:get(name) ~= nil
		end

		local function is_ast_grep_binary(resolved, bin)
			if bin ~= "sg" then
				return true
			end
			if type(mare.proc.run) ~= "function" then
				return false
			end
			local ok_run, r = pcall(mare.proc.run, {
				cmd = resolved,
				args = { "--version" },
				timeout_ms = 2000,
				max_output = 4096,
			})
			return ok_run
				and type(r) == "table"
				and r.code == 0
				and type(r.stdout) == "string"
				and r.stdout:lower():find("ast-grep", 1, true) ~= nil
		end

		local function probe_binary(candidates)
			if type(mare.proc) ~= "table" or type(mare.proc.which) ~= "function" then
				return nil
			end
			for _, bin in ipairs(candidates) do
				local ok, resolved = pcall(mare.proc.which, bin)
				if ok and type(resolved) == "string" and resolved ~= "" and is_ast_grep_binary(resolved, bin) then
					return resolved, bin
				end
			end
			return nil
		end

		local specs = {
			{
				name = "grep",
				bins = { "rg" },
				builder = function()
					return require("toolbelt.grep")
				end,
			},
			{
				name = "find",
				bins = { "fd" },
				builder = function()
					return require("toolbelt.find")
				end,
			},
			{
				name = "code_search",
				bins = { "ast-grep", "sg" },
				builder = function()
					return require("toolbelt.code_search")
				end,
			},
			{
				name = "doc_search",
				bins = { "rga" },
				builder = function()
					return require("toolbelt.doc_search")
				end,
			},
		}

		local statuses = {}
		for _, spec in ipairs(specs) do
			if not cfg[spec.name] then
				statuses[#statuses + 1] = { tool = spec.name, status = "disabled" }
				mare.log("info", ("toolbelt: %s disabled by config"):format(spec.name))
			elseif has_existing_tool(spec.name) then
				statuses[#statuses + 1] = { tool = spec.name, status = "skipped_existing" }
				mare.log("info", ("toolbelt: %s skipped: core already registered %s"):format(spec.name, spec.name))
			else
				local resolved, bin_name = probe_binary(spec.bins)
				if not resolved then
					local label = table.concat(spec.bins, " / ")
					statuses[#statuses + 1] = { tool = spec.name, status = "unavailable", missing = label }
					mare.log("info", ("toolbelt: %s unavailable: %s not found on PATH"):format(spec.name, label))
				else
					local builder = spec.builder()
					ctx.tools:register(spec.name, builder(resolved, cfg))
					statuses[#statuses + 1] =
						{ tool = spec.name, status = "registered", binary = bin_name, path = resolved }
				end
			end
		end

		if type(ctx.on) == "function" then
			ctx:on("kernel/doctor", function(checks)
				checks[#checks + 1] = {
					name = "toolbelt binaries",
					ok = true,
					detail = mare.json.encode(statuses),
				}
			end)
		end
	end,
}
