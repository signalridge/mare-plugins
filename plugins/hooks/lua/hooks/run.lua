-- Original process adapter; all command hooks share the sandbox and failure boundary.
local spill = require("hooks.spill")

local function can_spill_to_file()
	return mare.proc
		and type(mare.proc.spill_write) == "function"
		and mare.paths
		and type(mare.paths.state) == "string"
		and mare.paths.state ~= ""
end

local MAX_SPILL_READ_BYTES = 4 * 1024 * 1024
local MAX_PIPE_OUTPUT_BYTES = 1024 * 1024

-- PowerShell treats ASCII apostrophe and U+2018..U+201B as single-quote string delimiters;
-- doubling each delimiter escapes it inside a single-quoted literal.
local PS_SINGLE_QUOTES = {
	"'",
	"\u{2018}",
	"\u{2019}",
	"\u{201A}",
	"\u{201B}",
}

local function escape_ps_single_quoted(s)
	for _, q in ipairs(PS_SINGLE_QUOTES) do
		s = s:gsub(q, q .. q)
	end
	return s
end

local function read_spill_file(path)
	if not (path and mare.fs and type(mare.fs.read) == "function") then
		return nil
	end
	local ok, text, err = pcall(mare.fs.read, path, { max_bytes = MAX_SPILL_READ_BYTES })
	if ok and type(text) == "string" and #text > 0 then
		return text
	end
	return nil, err or (not ok and tostring(text) or nil)
end

return function(cmd, payload, env, operation)
	local payload_json = mare.json.encode_strict(payload)
	local program, args, input
	if cmd.argv then
		program = cmd.argv[1]
		args = {}
		for i = 2, #cmd.argv do
			args[#args + 1] = cmd.argv[i]
		end
		if cmd.legacy_notify then
			args[#args + 1] = payload_json
		else
			input = payload_json .. (cmd.source.dialect == "claude-code" and "\n" or "")
		end
	else
		local sh, err = mare.proc.shell({ model = true })
		assert(sh, err)
		assert(sh.transport == "argv", "hook requires a shell with argv transport")
		program = sh.path
		args = {}
		for i, a in ipairs(sh.args) do
			args[i] = a
		end
		local exec_cmd = (sh.kind == "powershell" and cmd.powershell_command) or cmd.command
		if cmd.legacy_notify then
			if sh.kind == "powershell" then
				args[#args + 1] = "$global:LASTEXITCODE = 0; "
					.. exec_cmd
					.. " '"
					.. escape_ps_single_quoted(payload_json)
					.. "'; $__mare_ok = $?; if (-not $__mare_ok) { if ($LASTEXITCODE) { exit $LASTEXITCODE } else { exit 1 } } else { exit 0 }"
			else
				args[#args + 1] = exec_cmd .. ' "$1"'
				args[#args + 1] = "legacy-notify"
				args[#args + 1] = payload_json
			end
		else
			if sh.kind == "powershell" then
				args[#args + 1] = "$global:LASTEXITCODE = 0; "
					.. exec_cmd
					.. "; $__mare_ok = $?; if (-not $__mare_ok) { if ($LASTEXITCODE) { exit $LASTEXITCODE } else { exit 1 } } else { exit 0 }"
			else
				args[#args + 1] = exec_cmd
			end
			input = payload_json .. (cmd.source.dialect == "claude-code" and "\n" or "")
		end
	end
	local spill_path = can_spill_to_file() and spill.new_path() or nil
	local result = mare.proc.run({
		cmd = program,
		args = args,
		cwd = payload.cwd,
		env = env,
		input = input,
		timeout_ms = cmd.timeout,
		cancel = operation and operation.cancel,
		max_output = 1024 * 1024,
		spill = spill_path,
		spill_prefix = spill_path and spill.PREFIX or nil,
		stderr = "pipe",
		sandbox = "current",
	})
	if result.timed_out or result.cancelled or result.signal then
		spill.remove(spill_path)
		error("hook timed out, cancelled or signalled", 0)
	end
	if result.sandbox_failed or result.denial or result.sandbox_denied then
		spill.remove(spill_path)
		error("hook sandbox refused execution", 0)
	end
	local stdout, saved_spill = result.stdout, nil
	if result.dropped and result.dropped ~= 0 then
		local full = read_spill_file(spill_path)
		if full and #full <= MAX_PIPE_OUTPUT_BYTES and full == result.stdout then
			spill.remove(spill_path)
		elseif not full and result.stdout == "" and #(result.stderr or "") >= 512 * 1024 then
			spill.remove(spill_path)
		else
			if not full then
				spill.remove(spill_path)
				error("hook output exceeded 1MiB", 0)
			end
			saved_spill = spill_path
			local trimmed = full:match("^%s*(.-)%s*$")
			local is_json = false
			if trimmed:sub(1, 1) == "{" then
				local ok_json, decoded = pcall(mare.json.decode, full)
				is_json = ok_json and type(decoded) == "table" and not mare.json.is_array(decoded)
			end
			if is_json then
				stdout = full
				spill.remove(spill_path)
				saved_spill = nil
			elseif cmd.event == "SessionStart" or cmd.event == "UserPromptSubmit" then
				stdout = spill.preview(full, spill_path, 8192)
			else
				error("hook output exceeded 1MiB (saved to " .. spill_path .. ")", 0)
			end
		end
	else
		spill.remove(spill_path)
	end
	local stderr = result.stderr:gsub("%s+", " "):match("^%s*(.-)%s*$")
	stderr = stderr:sub(1, (utf8.offset(stderr, cmd.stderr_limit + 1) or (#stderr + 1)) - 1)
	if result.code == 2 then
		return {
			decision = "deny",
			reason = stderr ~= "" and stderr or "hook exited with code 2",
			exit_code = 2,
			stderr_summary = stderr,
			spill_path = saved_spill,
		}
	end
	assert(
		result.code == 0,
		"hook failed with exit code " .. tostring(result.code) .. (stderr ~= "" and ": " .. stderr or "")
	)
	return { stdout = stdout, exit_code = result.code, stderr_summary = stderr, spill_path = saved_spill }
end
