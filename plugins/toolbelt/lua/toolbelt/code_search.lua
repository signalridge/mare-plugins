local common = require("toolbelt.common")

local SUPPORTED_LANGS = {
	bash = true,
	c = true,
	cpp = true,
	["c++"] = true,
	cs = true,
	csharp = true,
	css = true,
	dart = true,
	elixir = true,
	go = true,
	haskell = true,
	hcl = true,
	html = true,
	java = true,
	javascript = true,
	js = true,
	json = true,
	kotlin = true,
	kt = true,
	lua = true,
	nix = true,
	php = true,
	py = true,
	python = true,
	rb = true,
	rs = true,
	ruby = true,
	rust = true,
	scala = true,
	solidity = true,
	swift = true,
	ts = true,
	tsx = true,
	typescript = true,
	yaml = true,
	yml = true,
	zig = true,
}

local function first_line_trimmed(text)
	if type(text) ~= "string" then
		return ""
	end
	local first = text:match("^([^\r\n]*)") or text
	return common.trim(first)
end

return function(bin_path, cfg)
	return {
		description = "Structural AST pattern search using `ast-grep` (read-only). Use metavariables like `$NAME` or `$$$ARGS`.",
		snippet = "Search AST code patterns with ast-grep",
		side_effect = "read",
		idempotent = true,
		access = common.access_fn(),
		param_order = { "pattern", "lang", "path", "head_limit" },
		parameters = {
			type = "object",
			additionalProperties = false,
			required = { "pattern", "lang" },
			properties = {
				pattern = { type = "string", description = "ast-grep structural pattern." },
				lang = {
					type = "string",
					description = "Target language (e.g. `rust`, `lua`, `python`, `typescript`, `javascript`, `go`).",
				},
				path = { type = "string", description = "File or directory to search (defaults to workspace cwd)." },
				head_limit = {
					type = "integer",
					description = "Maximum matches to return (0 for unlimited within byte cap).",
				},
			},
		},
		summary = function(args)
			return ("CodeSearch(%s: %s)"):format(tostring(args.lang or ""), tostring(args.pattern or ""))
		end,
		render = function(args, res, expanded)
			return common.render_result("CodeSearch(" .. tostring(args.pattern or "") .. ")", res, expanded)
		end,
		execute = function(args, tctx)
			local pattern, perr = common.validate_text_arg(args.pattern, "pattern", true)
			if not pattern then
				return { content = perr, is_error = true }
			end
			local lang, lerr = common.validate_text_arg(args.lang, "lang", true)
			if not lang then
				return { content = lerr, is_error = true }
			end
			local norm_lang = lang:lower()
			if not SUPPORTED_LANGS[norm_lang] then
				return {
					content = "Unsupported language for code_search: " .. lang,
					is_error = true,
				}
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

			local argv = {
				"run",
				"--pattern=" .. pattern,
				"--lang",
				norm_lang,
				"--json=stream",
				"--",
				target.target,
			}

			local outcome, err_res = common.run_proc(bin_path, argv, target, cfg, tctx, function(res)
				return res.code == 1 and common.trim(res.stderr) == ""
			end)
			if not outcome then
				return err_res
			end
			if outcome.empty then
				return { content = "No matches", details = { matches = 0 } }
			end

			local proc_dropped = (outcome.res.dropped or 0) > 0
			local stdout = outcome.res.stdout or ""
			if proc_dropped then
				stdout = common.truncate_before_omission(stdout, false)
			end

			local entries = {}
			for line in stdout:gmatch("[^\r\n]+") do
				local ok, obj = pcall(mare.json.decode, line)
				if ok and type(obj) == "table" and type(obj.file) == "string" then
					local start_line = 0
					if
						type(obj.range) == "table"
						and type(obj.range.start) == "table"
						and type(obj.range.start.line) == "number"
					then
						start_line = obj.range.start.line
					end
					local rel = common.rel_path(obj.file, target)
					local matched = first_line_trimmed(obj.text or "")
					entries[#entries + 1] = ("%s:%d: %s"):format(rel, start_line + 1, matched)
				end
			end

			local total = #entries
			if total == 0 then
				if proc_dropped then
					return {
						content = common.truncation_line(),
						details = { matches = 0, truncated = true },
					}
				end
				return { content = "No matches", details = { matches = 0 } }
			end

			local content, truncated =
				common.join_capped(entries, total, 0, limit, cfg.max_output_bytes, { force_truncated = proc_dropped })
			return {
				content = content,
				details = { matches = total, truncated = truncated },
			}
		end,
	}
end
