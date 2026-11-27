local common = require("toolbelt.common")

return function(bin_path, cfg)
	return {
		description = "Read-only search inside documents and archives (PDF, docx, zip, etc.) using ripgrep-all (`rga`).",
		snippet = "Search inside PDFs, documents, and archives",
		side_effect = "read",
		idempotent = true,
		access = common.access_fn(),
		param_order = { "pattern", "path", "glob", "-i", "output_mode", "head_limit" },
		parameters = {
			type = "object",
			additionalProperties = false,
			required = { "pattern" },
			properties = {
				pattern = { type = "string", description = "Regex pattern to search inside documents and archives." },
				path = { type = "string", description = "File or directory to search (defaults to workspace cwd)." },
				glob = { type = "string", description = "Glob filter for files (e.g. `*.pdf`, `*.zip`)." },
				["-i"] = { type = "boolean", description = "Case-insensitive search." },
				output_mode = {
					type = "string",
					enum = { "content", "files_with_matches" },
					description = "Output format: `content` (default) or `files_with_matches`.",
				},
				head_limit = {
					type = "integer",
					description = "Maximum entries to return (0 for unlimited within byte cap).",
				},
			},
		},
		summary = function(args)
			return ("DocSearch(%s)"):format(tostring(args.pattern or ""))
		end,
		render = function(args, res, expanded)
			return common.render_result("DocSearch(" .. tostring(args.pattern or "") .. ")", res, expanded)
		end,
		execute = function(args, tctx)
			local mode = args.output_mode or "content"
			if mode ~= "content" and mode ~= "files_with_matches" then
				return { content = "Unsupported output_mode for doc_search: " .. tostring(mode), is_error = true }
			end
			return common.run_rg_like(bin_path, cfg, args, tctx, {
				allow_multiline = false,
				allow_literal = false,
				allow_context = false,
				regexp_flag = true,
			})
		end,
	}
end
