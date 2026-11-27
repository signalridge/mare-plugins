-- Limits are validated before any process starts; shell backends select explicit argv.
local M = {}

function M.validate(cfg)
	assert(cfg.rows * cfg.cols <= 200000, "Terminal viewport exceeds cell budget")
	assert(cfg.read_max_bytes <= cfg.buffer_bytes, "read_max_bytes exceeds retained buffer")
	assert(
		cfg.handoff_grace_ms == 0 or cfg.handoff_grace_ms >= cfg.poll_interval_ms,
		"Invalid terminal.handoff_grace_ms"
	)
	assert(
		cfg.prompt_tail_grace_ms == 0 or cfg.prompt_tail_grace_ms >= cfg.poll_interval_ms,
		"Invalid terminal.prompt_tail_grace_ms"
	)
	local count = 0
	for i, arg in pairs(cfg.shell_args) do
		count = count + 1
		assert(
			math.type(i) == "integer"
				and i >= 1
				and i <= #cfg.shell_args
				and type(arg) == "string"
				and not arg:find("\0", 1, true),
			"Invalid terminal shell_args"
		)
	end
	assert(count == #cfg.shell_args, "terminal shell_args must be a dense array")
	assert(cfg.shell == nil or (cfg.shell ~= "" and not cfg.shell:find("\0", 1, true)), "Invalid terminal shell")
end
local function is_legacy_wsl_bash(path)
	if type(path) ~= "string" then
		return false
	end
	local lower = path:gsub("/", "\\"):lower()
	return lower:match("^[a-z]:\\windows\\system32\\bash%.exe$") ~= nil
		or lower:match("^[a-z]:\\windows\\sysnative\\bash%.exe$") ~= nil
end

local function stat_file(candidate)
	if type(mare.fs) == "table" and type(mare.fs.stat) == "function" then
		local ok, st = pcall(mare.fs.stat, candidate)
		if ok and st then
			return candidate
		end
	end
	return nil
end

local function resolve_windows_bash()
	if type(mare.proc.shell) == "function" then
		local ok, sh = pcall(mare.proc.shell)
		if ok and type(sh) == "table" and sh.kind == "bash" and sh.path then
			return sh.path
		end
	end
	if type(mare.env) == "function" then
		for _, env_name in ipairs({ "ProgramFiles", "ProgramFiles(x86)" }) do
			local root = mare.env(env_name)
			if type(root) == "string" and root ~= "" then
				local candidate = root:gsub("[/\\]+$", "") .. "\\Git\\bin\\bash.exe"
				if stat_file(candidate) then
					return candidate
				end
			end
		end
	end
	local path = mare.proc.which("bash.exe") or mare.proc.which("bash")
	if path and not is_legacy_wsl_bash(path) then
		return path
	end
	return path
end

local function resolve_windows_pwsh()
	local path = mare.proc.which("pwsh") or mare.proc.which("pwsh.exe")
	if path then
		return path
	end
	if type(mare.env) == "function" then
		for _, env_name in ipairs({ "ProgramFiles", "ProgramFiles(x86)" }) do
			local root = mare.env(env_name)
			if type(root) == "string" and root ~= "" then
				local candidate = root:gsub("[/\\]+$", "") .. "\\PowerShell\\7\\pwsh.exe"
				if stat_file(candidate) then
					return candidate
				end
			end
		end
	end
	path = mare.proc.which("powershell.exe") or mare.proc.which("powershell")
	if path then
		return path
	end
	if type(mare.env) == "function" then
		local sysroot = mare.env("SystemRoot")
		if type(sysroot) == "string" and sysroot ~= "" then
			local candidate = sysroot:gsub("[/\\]+$", "") .. "\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"
			if stat_file(candidate) then
				return candidate
			end
		end
	end
	return nil
end

local function resolve_shell_path(cfg)
	if cfg.shell then
		if not cfg.shell:find("[/\\]") then
			return mare.proc.which(cfg.shell) or cfg.shell
		end
		return cfg.shell
	end
	if cfg.shell_dialect == "pwsh" then
		if mare.os == "windows" then
			return resolve_windows_pwsh()
		end
		return mare.proc.which("pwsh")
	end
	if mare.os == "windows" then
		return resolve_windows_bash()
	end
	return mare.proc.which("bash")
end

function M.shell(cfg)
	local path = resolve_shell_path(cfg)
	assert(path, "Terminal shell executable unavailable")
	local args = {}
	for i, arg in ipairs(cfg.shell_args) do
		args[i] = arg
	end
	if #args == 0 then
		args = cfg.shell_dialect == "pwsh" and { "-NoLogo", "-NoProfile" } or { "--noprofile", "--norc", "-i" }
	end
	return path, args
end
return M
