local common = require("toolbelt.common")

return function(bin_path, cfg)
	return {
		description = "Fast read-only file finder using `fd` (`--glob`), sorted newest-modified first.",
		snippet = "Find files by glob pattern",
		side_effect = "read",
		idempotent = true,
		access = common.access_fn(),
		param_order = { "pattern", "path", "head_limit", "include_ignored", "include_dirs" },
		parameters = {
			type = "object",
			additionalProperties = false,
			required = { "pattern" },
			properties = {
				pattern = { type = "string", description = "Glob pattern to match files (e.g. `*.rs`, `**/*.lua`)." },
				path = { type = "string", description = "Directory to search (defaults to workspace cwd)." },
				head_limit = {
					type = "integer",
					description = "Maximum number of paths to return (0 for unlimited within byte cap).",
				},
				include_ignored = {
					type = "boolean",
					description = "Include hidden and gitignored files (`--hidden --no-ignore`).",
				},
				include_dirs = {
					type = "boolean",
					description = "Include matching directories in addition to files.",
				},
			},
		},
		summary = function(args)
			return ("Find(%s)"):format(tostring(args.pattern or ""))
		end,
		render = function(args, res, expanded)
			return common.render_result("Find(" .. tostring(args.pattern or "") .. ")", res, expanded)
		end,
		execute = function(args, tctx)
			local pattern, perr = common.validate_text_arg(args.pattern, "pattern", true)
			if not pattern then
				return { content = perr, is_error = true }
			end
			local head_limit, herr = common.validate_nonneg_int(args.head_limit, "head_limit")
			if herr then
				return { content = herr, is_error = true }
			end
			local limit = common.effective_limit(head_limit, cfg.head_limit_default)

			local target, target_err_res = common.search_target(args.path, tctx)
			if not target then
				return target_err_res
			end

			local clean_pat = (mare and mare.os == "windows" and pattern:gsub("\\", "/") or pattern):gsub("^%./+", "")
			if clean_pat == "" then
				return { content = "pattern must not be empty", is_error = true }
			end
			local argv = { "--glob" }
			local effective_pat = clean_pat
			if clean_pat:find("/", 1, true) then
				argv[#argv + 1] = "--full-path"
				if
					not clean_pat:match("^%*%*/")
					and clean_pat:sub(1, 1) ~= "/"
					and not clean_pat:match("^[A-Za-z]:/")
				then
					local root_for_glob = mare and mare.os == "windows" and target.target:gsub("\\", "/")
						or target.target
					local escaped_root = root_for_glob:gsub("([\\*?%[%]{}])", "\\%1")
					local root_prefix = (escaped_root == "/" or escaped_root:match("^[A-Za-z]:/$")) and escaped_root
						or (escaped_root .. "/")
					effective_pat = root_prefix .. clean_pat
					if not clean_pat:find("%u") and effective_pat:find("%u") then
						argv[#argv + 1] = "--ignore-case"
					end
				end
			end
			argv[#argv + 1] = "--type"
			argv[#argv + 1] = "f"
			if args.include_dirs == true then
				argv[#argv + 1] = "--type"
				argv[#argv + 1] = "d"
			end
			argv[#argv + 1] = "--color"
			argv[#argv + 1] = "never"
			if args.include_ignored == true then
				argv[#argv + 1] = "--hidden"
				argv[#argv + 1] = "--no-ignore"
			end
			argv[#argv + 1] = "-0"
			argv[#argv + 1] = "--"
			argv[#argv + 1] = effective_pat
			argv[#argv + 1] = target.target

			local outcome, err_res = common.run_proc(bin_path, argv, target, cfg, tctx)
			if not outcome then
				return err_res
			end

			local proc_dropped = (outcome.res.dropped or 0) > 0
			local raw_stdout = outcome.res.stdout or ""
			if proc_dropped then
				raw_stdout = common.truncate_before_omission(raw_stdout, true)
			end
			local all_paths = common.split_nul(raw_stdout)
			if #all_paths == 0 then
				if proc_dropped then
					return {
						content = common.truncation_line(),
						details = { matches = 0, truncated = true },
					}
				end
				return { content = "No matches", details = { matches = 0 } }
			end

			local sorted = common.sort_by_mtime_desc(all_paths)
			local rels = common.map_rel_paths(sorted, target)
			local content, truncated =
				common.join_capped(rels, #rels, 0, limit, cfg.max_output_bytes, { force_truncated = proc_dropped })
			return {
				content = content,
				details = { matches = #rels, truncated = truncated },
			}
		end,
	}
end
