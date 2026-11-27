local common = require("toolbelt.common")

return function(bin_path, cfg)
	return {
		description = "Fast read-only regex/literal text search using ripgrep (`rg`). Supports glob/type filters, context lines, multiline, and content/files_with_matches/count modes.",
		snippet = "Search file contents with ripgrep",
		side_effect = "read",
		idempotent = true,
		access = common.access_fn(),
		param_order = {
			"pattern",
			"path",
			"glob",
			"type",
			"output_mode",
			"-i",
			"-n",
			"-A",
			"-B",
			"-C",
			"head_limit",
			"offset",
			"multiline",
			"literal",
		},
		parameters = {
			type = "object",
			additionalProperties = false,
			required = { "pattern" },
			properties = {
				pattern = { type = "string", description = "Regex pattern (or fixed string when `literal` is true)." },
				path = { type = "string", description = "File or directory to search (defaults to workspace cwd)." },
				glob = { type = "string", description = "Glob filter for files (e.g. `*.lua`, `!*.min.js`)." },
				type = { type = "string", description = "Ripgrep file type filter (e.g. `rust`, `lua`, `py`)." },
				output_mode = {
					type = "string",
					enum = { "content", "files_with_matches", "count" },
					description = "Output format: `content` (default), `files_with_matches`, or `count`.",
				},
				["-i"] = { type = "boolean", description = "Case-insensitive search." },
				["-n"] = { type = "boolean", description = "Include line numbers in `content` mode (default true)." },
				["-A"] = { type = "integer", description = "Lines of trailing context after each match." },
				["-B"] = { type = "integer", description = "Lines of leading context before each match." },
				["-C"] = {
					type = "integer",
					description = "Lines of context before and after each match (overrides `-A`/`-B`).",
				},
				head_limit = {
					type = "integer",
					description = "Maximum entries to return after `offset` (0 for unlimited within byte cap).",
				},
				offset = { type = "integer", description = "Number of leading entries to skip." },
				multiline = {
					type = "boolean",
					description = "Allow matches across newlines (`-U --multiline-dotall`).",
				},
				literal = { type = "boolean", description = "Treat `pattern` as a literal fixed string (`-F`)." },
			},
		},
		summary = function(args)
			return ("Grep(%s)"):format(tostring(args.pattern or ""))
		end,
		render = function(args, res, expanded)
			return common.render_result("Grep(" .. tostring(args.pattern or "") .. ")", res, expanded)
		end,
		execute = function(args, tctx)
			return common.run_rg_like(bin_path, cfg, args, tctx, {
				allow_multiline = true,
				allow_literal = true,
				allow_context = true,
			})
		end,
	}
end
