local fingerprint = require("hooks.fingerprint")
local EVENTS = {
	"PreToolUse",
	"PostToolUse",
	"SessionStart",
	"SessionEnd",
	"Stop",
	"UserPromptSubmit",
	"PreCompact",
	"PostCompact",
	"PermissionRequest",
}
local ALLOWED_EVENTS = {}
for _, ev in ipairs(EVENTS) do
	ALLOWED_EVENTS[ev] = true
end
local function fields(value, allowed, what)
	assert(type(value) == "table" and not mare.json.is_array(value), what .. " must be an object")
	for k in pairs(value) do
		assert(allowed[k], what .. ": unsupported field " .. tostring(k))
	end
end
local function sequence(value, what)
	assert(type(value) == "table", what .. " must be an array")
	local count = 0
	for k in pairs(value) do
		assert(type(k) == "number" and k >= 1 and k % 1 == 0, what .. " must be an array")
		count = count + 1
	end
	assert(count == #value, what .. " must not have holes")
end
local function optional_string(v, what)
	assert(v == nil or type(v) == "string", what .. " must be a string")
end
local function optional_boolean(v, what)
	assert(v == nil or type(v) == "boolean", what .. " must be a boolean")
end
local function string_array(v, what)
	sequence(v, what)
	assert(#v > 0, what .. " must not be empty")
	for _, item in ipairs(v) do
		assert(type(item) == "string" and item ~= "", what .. " items must be non-empty strings")
	end
end
local function shell_escape_token(val, quote)
	if quote == "'" then
		return (val:gsub("'", "'\\''"))
	elseif quote == '"' then
		return (val:gsub('[\\"$`]', "\\%1"))
	elseif val:match("^[A-Za-z0-9_./:@%%+=%-]+$") then
		return val
	else
		return "'" .. val:gsub("'", "'\\''") .. "'"
	end
end

local function powershell_escape_token(val, quote)
	if quote == "'" then
		return (val:gsub("'", "''"))
	elseif quote == '"' then
		return (val:gsub('([`"$])', "`%1"))
	elseif val:match("^[A-Za-z0-9_./:@%%+=%-\\]+$") then
		return val
	else
		return "'" .. val:gsub("'", "''") .. "'"
	end
end

local function substitute_claude_vars(command, source, shell_mode)
	if source.dialect ~= "claude-code" then
		return command
	end
	local vars = {
		CLAUDE_PLUGIN_ROOT = source.plugin_root,
		CLAUDE_PROJECT_DIR = mare.cwd,
	}
	if not shell_mode then
		for name, val in pairs(vars) do
			command = command:gsub("%${" .. name .. "}", function()
				return val
			end)
		end
		return command
	end
	local escaper = shell_mode == "powershell" and powershell_escape_token or shell_escape_token
	local out, quote, i, n = {}, nil, 1, #command
	while i <= n do
		local c = command:sub(i, i)
		if
			((c == "\\" and shell_mode ~= "powershell") or (c == "`" and shell_mode == "powershell"))
			and quote ~= "'"
		then
			if i < n then
				out[#out + 1] = command:sub(i, i + 1)
				i = i + 2
			else
				out[#out + 1] = c
				i = i + 1
			end
		elseif c == "'" and quote ~= '"' then
			if quote == "'" then
				quote = nil
			else
				quote = "'"
			end
			out[#out + 1] = c
			i = i + 1
		elseif c == '"' and quote ~= "'" then
			if quote == '"' then
				quote = nil
			else
				quote = '"'
			end
			out[#out + 1] = c
			i = i + 1
		elseif c == "$" and command:sub(i, i + 1) == "${" then
			local close = command:find("}", i + 2, true)
			local name = close and command:sub(i + 2, close - 1) or nil
			local val = name and vars[name] or nil
			if val ~= nil then
				out[#out + 1] = escaper(val, quote)
				i = close + 1
			else
				out[#out + 1] = c
				i = i + 1
			end
		else
			out[#out + 1] = c
			i = i + 1
		end
	end
	return table.concat(out)
end

local function normalize_discover(discover)
	if discover == nil or discover == false then
		return nil
	end
	if discover == true then
		return { mare = true, packages = true, claude = true, codex = true, user = true, project = true }
	end
	assert(type(discover) == "table" and not mare.json.is_array(discover), "discover must be a boolean or object")
	local keys = { mare = true, packages = true, claude = true, codex = true, user = true, project = true }
	fields(discover, keys, "discover")
	local explicit_on = false
	for _, k in ipairs({ "mare", "packages", "claude", "codex" }) do
		optional_boolean(discover[k], "discover." .. k)
		if discover[k] == true then
			explicit_on = true
		end
	end
	optional_boolean(discover.user, "discover.user")
	optional_boolean(discover.project, "discover.project")
	local function layer(k)
		if discover[k] ~= nil then
			return discover[k]
		end
		return not explicit_on
	end
	return {
		mare = layer("mare"),
		packages = layer("packages"),
		claude = layer("claude"),
		codex = layer("codex"),
		user = discover.user ~= false,
		project = discover.project ~= false,
	}
end

local function resolve_home()
	if type(mare.env) == "table" and type(mare.env.home) == "string" and mare.env.home ~= "" then
		return mare.env.home
	end
	if
		type(mare.env) == "function"
		or (type(mare.env) == "table" and getmetatable(mare.env) and getmetatable(mare.env).__call)
	then
		return mare.env("HOME")
	end
	return nil
end

local function workspace_roots()
	if mare.workspace and type(mare.workspace.dirs) == "function" then
		local ok, dirs = pcall(mare.workspace.dirs)
		if ok and type(dirs) == "table" and #dirs > 0 then
			return dirs
		end
	end
	return mare.cwd and { mare.cwd } or {}
end

local function canonical_path(path)
	if not path or path == "" then
		return ""
	end
	if mare.fs and type(mare.fs.realpath) == "function" then
		local ok, real = pcall(mare.fs.realpath, path)
		if ok and type(real) == "string" and real ~= "" then
			return real
		end
	end
	return path
end

local function discover_sources(opts, warnings, is_trusted)
	local discovered, seen = {}, {}
	local function try_load(path, meta)
		if not path or path == "" then
			return
		end
		if meta.project and not is_trusted then
			if mare.fs and type(mare.fs.exists) == "function" and mare.fs.exists(path) then
				warnings[#warnings + 1] = "skipping untrusted project hooks: " .. path
			end
			return
		end
		if mare.fs and type(mare.fs.exists) == "function" and not mare.fs.exists(path) then
			return
		end
		local key = canonical_path(path)
		if seen[key] then
			return
		end
		if not (mare.fs and type(mare.fs.read) == "function") then
			return
		end
		local ok, raw = pcall(mare.fs.read, path)
		if not ok or type(raw) ~= "string" then
			return
		end
		seen[key] = true
		assert(#raw <= 1024 * 1024, "hook configuration exceeds 1MiB: " .. path)
		local doc = mare.json.decode_lossless(raw)
		if type(doc) ~= "table" or doc.disableAllHooks == true then
			return
		end
		if meta.require_hooks_key and doc.hooks == nil then
			return
		end
		local hooks = doc.hooks or doc
		if type(hooks) ~= "table" or mare.json.is_array(hooks) then
			return
		end
		local dialect = meta.dialect or (type(doc.dialect) == "string" and doc.dialect or "codex")
		discovered[#discovered + 1] = {
			dialect = dialect,
			hooks = hooks,
			plugin_root = meta.plugin_root,
			requireTrust = meta.requireTrust,
			_discovered_path = path,
		}
	end

	local home = resolve_home()
	local workspaces = workspace_roots()
	if opts.mare then
		if opts.user and mare.paths and type(mare.paths.config) == "string" then
			try_load(mare.paths.config .. "/hooks.json", {})
		end
		if opts.project then
			for _, ws in ipairs(workspaces) do
				try_load(ws .. "/.mare/hooks.json", { project = true })
			end
		end
	end
	if opts.packages and not mare.no_user_plugins and mare.plugins and type(mare.plugins.dirs) == "function" then
		local ok, pkg_dirs = pcall(mare.plugins.dirs)
		if ok and type(pkg_dirs) == "table" then
			for _, pkg in ipairs(pkg_dirs) do
				if type(pkg) == "table" and type(pkg.dir) == "string" then
					try_load(pkg.dir .. "/hooks/hooks.json", { dialect = "claude-code", plugin_root = pkg.dir })
					try_load(pkg.dir .. "/hooks.json", { plugin_root = pkg.dir })
				end
			end
		end
	end
	if opts.claude then
		if opts.user and home then
			try_load(home .. "/.claude/settings.json", { dialect = "claude-code", require_hooks_key = true })
			try_load(home .. "/.claude/settings.local.json", { dialect = "claude-code", require_hooks_key = true })
		end
		if opts.project then
			for _, ws in ipairs(workspaces) do
				try_load(ws .. "/.claude/settings.json", {
					dialect = "claude-code",
					require_hooks_key = true,
					project = true,
				})
				try_load(ws .. "/.claude/settings.local.json", {
					dialect = "claude-code",
					require_hooks_key = true,
					project = true,
				})
			end
		end
	end
	if opts.codex then
		if opts.user and home then
			try_load(home .. "/.codex/hooks.json", { dialect = "codex" })
		end
		if opts.project then
			for _, ws in ipairs(workspaces) do
				try_load(ws .. "/.codex/hooks.json", { dialect = "codex", project = true })
			end
		end
	end
	return discovered
end

return function(cfg, opts)
	fields(cfg, {
		enabled = true,
		sources = true,
		discover = true,
		defaultTimeoutMs = true,
		stderrSummaryMaxChars = true,
		requireTrust = true,
	}, "hooks configuration")
	optional_boolean(cfg.enabled, "enabled")
	optional_boolean(cfg.requireTrust, "requireTrust")
	local is_trusted = (type(opts) == "table" and opts.trusted ~= nil) and (opts.trusted == true)
		or (mare.trusted == true)
	local commands, warnings, id_counts = {}, {}, {}
	local function unique_cmd_id(dialect, event, source_scope, declaration_hash)
		local base = dialect .. ":" .. event .. ":" .. fingerprint.hash_identity({ source_scope, declaration_hash })
		local count = (id_counts[base] or 0) + 1
		id_counts[base] = count
		return count == 1 and base or (base .. "#" .. tostring(count))
	end
	local default_timeout = cfg.defaultTimeoutMs or 600000
	local stderr_limit = cfg.stderrSummaryMaxChars or 500
	assert(
		type(default_timeout) == "number"
			and default_timeout > 0
			and default_timeout < math.huge
			and default_timeout % 1 == 0,
		"defaultTimeoutMs must be a positive integer"
	)
	assert(
		type(stderr_limit) == "number" and stderr_limit > 0 and stderr_limit % 1 == 0,
		"stderrSummaryMaxChars must be a positive integer"
	)
	local live_mt = {
		__index = function(_, key)
			if key == "timeout" then
				return cfg.defaultTimeoutMs or 600000
			elseif key == "stderr_limit" then
				return cfg.stderrSummaryMaxChars or 500
			elseif key == "require_trust" then
				return cfg.requireTrust == true
			end
		end,
	}
	local explicit_sources = cfg.sources
	if explicit_sources == nil then
		explicit_sources = {}
	else
		sequence(explicit_sources, "sources")
	end
	local all_sources = {}
	for _, s in ipairs(explicit_sources) do
		all_sources[#all_sources + 1] = s
	end
	local discover_opts = normalize_discover(cfg.discover)
	if discover_opts then
		for _, s in ipairs(discover_sources(discover_opts, warnings, is_trusted)) do
			all_sources[#all_sources + 1] = s
		end
	end
	for si, source in ipairs(all_sources) do
		fields(source, {
			dialect = true,
			path = true,
			hooks = true,
			plugin_root = true,
			requireTrust = true,
			notify = true,
			_discovered_path = true,
		}, "source")
		assert(source.dialect == "claude-code" or source.dialect == "codex", "unknown hook dialect")
		optional_string(source.plugin_root, "plugin_root")
		optional_boolean(source.requireTrust, "requireTrust")
		local require_trust = source.requireTrust
		if require_trust == nil then
			require_trust = cfg.requireTrust == true
		end
		if source.notify ~= nil then
			assert(source.dialect == "codex", "notify is a Codex option")
			string_array(source.notify, "notify")
		end
		assert(
			(source.path ~= nil) ~= (source.hooks ~= nil)
				or (source.notify ~= nil and source.path == nil and source.hooks == nil),
			"source requires exactly one of path or hooks"
		)
		local hooks = source.hooks or {}
		if source.path then
			assert(type(source.path) == "string", "path must be a string")
			local raw = assert(mare.fs.read(source.path))
			assert(#raw <= 1024 * 1024, "hook configuration exceeds 1MiB")
			local document = mare.json.decode_lossless(raw)
			hooks = document.hooks or document
		end
		if source._discovered_path then
			assert(type(hooks) == "table" and not mare.json.is_array(hooks), "hooks must be an object")
			local filtered = {}
			for k, val in pairs(hooks) do
				if ALLOWED_EVENTS[k] then
					filtered[k] = val
				elseif k ~= "dialect" and k ~= "disableAllHooks" then
					warnings[#warnings + 1] = source._discovered_path
						.. ': skipping unsupported hook event "'
						.. tostring(k)
						.. '"'
				end
			end
			hooks = filtered
		else
			fields(hooks, ALLOWED_EVENTS, "hooks")
		end
		local plugin_root = (type(source.plugin_root) == "string" and source.plugin_root ~= "") and source.plugin_root
			or nil
		local source_scope = source._discovered_path and ("discovered:" .. canonical_path(source._discovered_path))
			or source.path and ("file:" .. canonical_path(source.path))
			or plugin_root and ("plugin:" .. canonical_path(plugin_root))
			or ("inline:" .. canonical_path(mare.cwd or ""))
		local function bind_trust_fields(declaration_hash)
			if require_trust and plugin_root then
				local content_hash, fp_err = fingerprint.plugin_content_hash(plugin_root)
				if content_hash then
					return content_hash,
						nil,
						fingerprint.hash_identity({ "trusted-plugin", declaration_hash, content_hash })
				end
				return nil, fp_err, declaration_hash
			end
			return nil, nil, declaration_hash
		end
		if source.notify ~= nil then
			local timeout = default_timeout / 1000
			local argv = {}
			for i, a in ipairs(source.notify) do
				argv[i] = a
			end
			local cmd_str = table.concat(argv, " ")
			local label = source.dialect .. " Stop " .. si .. ":notify"
			local declaration_hash = fingerprint.hash_identity({
				"notify",
				"Stop",
				"",
				timeout * 1000,
				source.dialect,
				plugin_root or "",
				source.path or "",
				source._discovered_path or "",
				table.concat(argv, "\0"),
			})
			local plugin_content_hash, fingerprint_error, cmd_hash = bind_trust_fields(declaration_hash)
			commands[#commands + 1] = setmetatable({
				id = unique_cmd_id(source.dialect, "Stop", source_scope, declaration_hash),
				source = source,
				plugin_root = plugin_root,
				event = "Stop",
				command = cmd_str,
				argv = argv,
				legacy_notify = true,
				enabled = true,
				require_trust = source.requireTrust,
				declaration_hash = declaration_hash,
				plugin_content_hash = plugin_content_hash,
				fingerprint_error = fingerprint_error,
				hash = cmd_hash,
				dedup_key = source.dialect .. "\0legacy\0" .. table.concat(argv, "\0"),
				group_id = si .. ":Stop:notify",
				matcher = nil,
				literal = nil,
				regex = nil,
				label = label,
			}, live_mt)
		end
		for _, event in ipairs(EVENTS) do
			if hooks[event] ~= nil then
				sequence(hooks[event], event)
			end
			for gi, group in ipairs(hooks[event] or {}) do
				fields(group, { matcher = true, hooks = true }, "matcher group")
				local matcher = event ~= "Stop" and event ~= "UserPromptSubmit" and group.matcher or nil
				optional_string(matcher, "matcher")
				sequence(group.hooks, "group hooks")
				-- In every dialect: empty or "*" matches everything; a pattern of only [A-Za-z0-9_|] is exact alternatives; anything else is a
				-- regex (Rust regex syntax, unanchored is_match) - an invalid or unsupported one fails
				-- startup.
				local literal = matcher and matcher:match("^[A-Za-z0-9_|]+$")
				local regex
				if matcher and matcher ~= "" and matcher ~= "*" and not literal then
					local re, err = mare.text.regex(matcher)
					if not re then
						error(
							("hooks: %s matcher %q is not a supported regex (%s); lookaround and backreferences are not supported"):format(
								event,
								matcher,
								tostring(err)
							),
							0
						)
					end
					regex = re
				end
				for hi, hook in ipairs(group.hooks) do
					assert(type(hook) == "table" and not mare.json.is_array(hook), "hook must be an object")
					local hook_type = hook.type == nil and "command" or hook.type
					assert(type(hook_type) == "string", "hook type must be a string")
					local label = source.dialect .. " " .. event .. " " .. si .. ":" .. gi .. ":" .. hi
					if hook_type ~= "command" then
						warnings[#warnings + 1] = label .. ': skipping unsupported "' .. hook_type .. '" hook'
					else
						fields(hook, {
							type = true,
							command = true,
							commandWindows = true,
							command_windows = true,
							timeout = true,
							timeoutSec = true,
							description = true,
							async = true,
							statusMessage = true,
							enabled = true,
							legacy_notify = true,
							args = true,
						}, "command hook")
						assert(
							type(hook.command) == "string" and hook.command ~= "",
							"only command hooks are supported"
						)
						optional_string(hook.commandWindows, "commandWindows")
						optional_string(hook.command_windows, "command_windows")
						optional_string(hook.description, "description")
						optional_string(hook.statusMessage, "statusMessage")
						optional_boolean(hook.enabled, "enabled")
						optional_boolean(hook.legacy_notify, "legacy_notify")
						if hook.args ~= nil then
							string_array(hook.args, "args")
						end
						assert(hook.async == nil or type(hook.async) == "boolean", "async must be boolean")
						assert(source.dialect == "codex" or hook.timeoutSec == nil, "timeoutSec is a Codex alias")
						local selected = mare.os == "windows" and (hook.commandWindows or hook.command_windows)
							or hook.command
						assert(type(selected) == "string" and selected ~= "", "only command hooks are supported")
						local requested_async = hook.async == true
						local runs_async = requested_async and event ~= "SessionEnd"
						if requested_async and not runs_async then
							warnings[#warnings + 1] = label .. ": running async SessionEnd hook synchronously"
						end
						local raw_timeout = hook.timeout or hook.timeoutSec
						if raw_timeout ~= nil then
							assert(
								type(raw_timeout) == "number" and raw_timeout > 0 and raw_timeout < math.huge,
								"timeout must be a positive number"
							)
						end
						local timeout
						if event == "SessionEnd" then
							timeout = raw_timeout or 1
							if timeout > 3 then
								warnings[#warnings + 1] = label .. ": clamping SessionEnd timeout to 3s"
								timeout = 3
							end
						else
							timeout = raw_timeout or default_timeout / 1000
						end
						local shell_mode = hook.args == nil
						local substituted = substitute_claude_vars(selected, source, shell_mode)
						local powershell_command = shell_mode and substitute_claude_vars(selected, source, "powershell")
							or nil
						local argv
						if hook.args ~= nil then
							argv = { substituted }
							for _, a in ipairs(hook.args) do
								argv[#argv + 1] = substitute_claude_vars(a, source, false)
							end
						end
						local legacy_notify = hook.legacy_notify == true
						local hash_input = argv and table.concat(argv, "\0") or substituted
						local status_message = (hook.statusMessage and hook.statusMessage ~= "") and hook.statusMessage
							or nil
						local declaration_hash = fingerprint.hash_identity({
							"command",
							event,
							matcher or "",
							timeout * 1000,
							source.dialect,
							plugin_root or "",
							source.path or "",
							source._discovered_path or "",
							legacy_notify and "legacy" or "std",
							requested_async and "async" or "sync",
							status_message or "",
							hash_input,
						})
						local identity_hash = fingerprint.hash_identity({
							"command",
							event,
							source.dialect,
							plugin_root or "",
							source.path or "",
							source._discovered_path or "",
							legacy_notify and "legacy" or "std",
							hash_input,
						})
						local plugin_content_hash, fingerprint_error, cmd_hash = bind_trust_fields(declaration_hash)
						commands[#commands + 1] = setmetatable({
							id = unique_cmd_id(source.dialect, event, source_scope, identity_hash),
							source = source,
							plugin_root = plugin_root,
							event = event,
							command = argv and table.concat(argv, " ") or substituted,
							powershell_command = powershell_command,
							argv = argv,
							legacy_notify = legacy_notify,
							runs_async = runs_async,
							enabled = hook.enabled ~= false,
							require_trust = source.requireTrust,
							status_message = status_message,
							declaration_hash = declaration_hash,
							plugin_content_hash = plugin_content_hash,
							fingerprint_error = fingerprint_error,
							hash = cmd_hash,
							dedup_key = source.dialect
								.. "\0"
								.. (legacy_notify and "legacy" or "std")
								.. "\0"
								.. (runs_async and "async" or "sync")
								.. "\0"
								.. hash_input,
							group_id = si .. ":" .. event .. ":" .. gi,
							timeout = (raw_timeout ~= nil or event == "SessionEnd") and (timeout * 1000) or nil,
							matcher = matcher,
							literal = literal,
							regex = regex,
							label = label,
						}, live_mt)
					end
				end
			end
		end
	end
	return commands, warnings
end
