local support = assert(load(mare.fs.read("tests/specs/support.lua"), "@tests/specs/support.lua"))()

local plugin = support.load_plugin("hooks", {
	"hooks.capability",
	"hooks.commands",
	"hooks.compact",
	"hooks.config",
	"hooks.fingerprint",
	"hooks.input",
	"hooks.lifecycle",
	"hooks.output",
	"hooks.permission",
	"hooks.post",
	"hooks.pre_tool",
	"hooks.run",
	"hooks.runtime",
	"hooks.session_end",
	"hooks.spill",
	"hooks.state",
	"hooks.stop",
})

local orig = {
	cwd = mare.cwd,
	os = mare.os,
	paths = mare.paths,
	env = mare.env,
	workspace = mare.workspace,
	plugins = mare.plugins,
	no_user_plugins = mare.no_user_plugins,
	trusted = mare.trusted,
	fs = mare.fs,
	text = mare.text,
	ui_notify = mare.ui.notify,
	ui_select = mare.ui.select,
	ui_working = mare.ui.working,
	ui_connected = mare.ui.connected,
	proc_run = mare.proc.run,
	proc_shell = mare.proc.shell,
	proc_spill_write = mare.proc.spill_write,
	proc_spill_remove = mare.proc.spill_remove,
	task_spawn = mare.task.spawn,
	task_timeout = mare.task.timeout,
	task_now = mare.task.now,
}

local H = {}
H.plugin = plugin
H.orig = orig

local S = {
	result = { code = 0, stdout = "", stderr = "", dropped = 0 },
	events = {},
	runs = 0,
	registered = {},
	captured = nil,
	config = nil,
	proc_opts = nil,
	session_info = { session_id = "session", session_epoch = "epoch-1", path = "/session" },
	participants = {},
	committed = {},
	agent_aborted = nil,
	diagnostics = {},
	notifications = {},
	expected_cmd = "check",
	commands_reg = {},
	select_fn = nil,
	skip_proc_assert = false,
}
H.S = S

H.call = { id = "call", name = "probe", cwd = "/actual", arguments = { other = true } }

-- Plugins log through mare.log, which the specs restore in after_each.
local function capture_log()
	mare.log = function(_, message)
		S.diagnostics[#S.diagnostics + 1] = message
	end
end
capture_log()

H.ctx = {
	effect = function(_, setup)
		setup()
	end,
	tools = {},
	agent = {},
	session = {},
	llm = {},
	commands = {},
	on = function() end,
}

local function reset_ctx()
	capture_log()
	H.ctx.effect = function(_, setup)
		setup()
	end
	H.ctx.tools = {
		capabilities = function()
			return { result_pipeline = 1 }
		end,
	}
	H.ctx.agent = {
		capabilities = function()
			return { input_admission = 1 }
		end,
		step_participant = function(_, name, fn)
			S.participants[name] = fn
		end,
		step_state = function(_, name)
			return S.committed[name]
		end,
		cancel = function(_, opts)
			S.agent_aborted = opts
		end,
	}
	H.ctx.session = {
		info = function()
			return S.session_info
		end,
	}
	H.ctx.llm = {
		current = function()
			return { ref = "faux/echo" }
		end,
	}
	H.ctx.commands = {
		register = function(_, name, def)
			S.commands_reg[name] = def
		end,
	}
	H.ctx.on = function(_, ev, fn, opts)
		S.events[ev] = fn
		S.registered[ev] = opts or {}
	end
end

function H.clear_persisted_state()
	if mare and mare.state and type(mare.state.update) == "function" then
		mare.state.update(function(st)
			st = type(st) == "table" and st or {}
			st.hooks = nil
			return st
		end)
	end
end

function H.restore_mare()
	mare.cwd = orig.cwd
	mare.os = orig.os
	mare.paths = orig.paths
	mare.env = orig.env
	mare.workspace = orig.workspace
	mare.plugins = orig.plugins
	mare.no_user_plugins = orig.no_user_plugins
	mare.trusted = orig.trusted
	mare.fs = orig.fs
	mare.text = orig.text
	mare.ui.notify = orig.ui_notify
	mare.ui.select = orig.ui_select
	mare.ui.working = orig.ui_working
	mare.ui.connected = orig.ui_connected
	mare.proc.run = orig.proc_run
	mare.proc.shell = orig.proc_shell
	mare.proc.spill_write = orig.proc_spill_write
	mare.proc.spill_remove = orig.proc_spill_remove
	mare.task.spawn = orig.task_spawn
	mare.task.timeout = orig.task_timeout
	mare.task.now = orig.task_now
end

function H.install_stubs()
	mare.ui.notify = function(text, level)
		S.notifications[#S.notifications + 1] = { text = text, level = level }
	end
	mare.ui.select = function(opts)
		if S.select_fn then
			return S.select_fn(opts)
		end
		return nil, nil, nil, nil, "unavailable"
	end
	mare.proc.shell = function()
		return { path = "/bin/sh", args = { "-c" }, transport = "argv", kind = "sh" }
	end
	mare.proc.run = function(opts)
		S.runs = S.runs + 1
		S.proc_opts = opts
		if type(opts.input) == "string" and opts.input ~= "" then
			S.captured = mare.json.decode_lossless(opts.input)
		else
			S.captured = nil
		end
		assert(opts.sandbox == "current" and opts.stderr == "pipe" and opts.max_output == 1048576)
		if not S.skip_proc_assert then
			assert(opts.args[2] == S.expected_cmd)
			local ev = S.captured.hook_event_name
			local is_tool = ev == "PreToolUse" or ev == "PostToolUse" or ev == "PermissionRequest"
			assert(opts.cwd == (is_tool and "/actual" or mare.cwd))
			if S.config.sources[1].dialect == "codex" then
				assert(opts.input:sub(-1) ~= "\n", "codex input must not end with newline")
			else
				assert(opts.input:sub(-1) == "\n", "claude-code input must end with newline")
			end
		end
		return S.result
	end
end

function H.reset()
	H.restore_mare()
	H.clear_persisted_state()
	S.events, S.runs, S.registered = {}, 0, {}
	S.captured, S.config, S.proc_opts = nil, nil, nil
	S.session_info = { session_id = "session", session_epoch = "epoch-1", path = "/session" }
	S.participants, S.committed, S.agent_aborted, S.diagnostics, S.notifications = {}, {}, nil, {}, {}
	S.commands_reg, S.select_fn, S.skip_proc_assert = {}, nil, false
	S.expected_cmd = "check"
	S.result = { code = 0, stdout = "", stderr = "", dropped = 0 }
	H.call.id = "call"
	H.call.name = "probe"
	H.call.cwd = "/actual"
	H.call.arguments = { other = true }
	reset_ctx()
	H.install_stubs()
end

function H.teardown()
	H.restore_mare()
	H.clear_persisted_state()
end

function H.setup(dialect)
	H.reset()
	S.config = {
		sources = {
			{
				dialect = dialect or "claude-code",
				hooks = {
					PreToolUse = {
						{
							matcher = dialect == "codex" and "*" or "probe",
							hooks = { { type = "command", command = "check", timeout = 1 } },
						},
					},
				},
			},
		},
	}
	H.plugin.apply(H.ctx, S.config)
end

function H.vote()
	return S.events["tool/before"](H.call)
end

function H.set_json(tbl)
	S.result = { code = 0, stdout = mare.json.encode_strict(tbl), stderr = "", dropped = 0 }
end

-- Build a virtual filesystem table from map<filepath, string|false> (`false` simulates read error).
function H.make_fs_tree(files)
	local function norm(p)
		return (p:gsub("/+$", ""))
	end
	return {
		exists = function(p)
			return files[p] ~= nil
		end,
		stat = function(p)
			p = norm(p)
			if files[p] ~= nil then
				local val = files[p]
				return { kind = "file", size = type(val) == "string" and #val or 1, mode = 420 }
			end
			local prefix = p .. "/"
			for k in pairs(files) do
				if k:sub(1, #prefix) == prefix then
					return { kind = "dir", size = 0, mode = 493 }
				end
			end
			return nil
		end,
		list = function(p)
			p = norm(p)
			local prefix = p .. "/"
			local seen, out = {}, {}
			for k in pairs(files) do
				if k:sub(1, #prefix) == prefix then
					local rest = k:sub(#prefix + 1)
					local slash = rest:find("/", 1, true)
					local name = slash and rest:sub(1, slash - 1) or rest
					if name ~= "" and not seen[name] then
						seen[name] = true
						out[#out + 1] = { name = name, kind = slash and "dir" or "file" }
					end
				end
			end
			table.sort(out, function(a, b)
				return a.name < b.name
			end)
			return out
		end,
		read = function(p)
			local val = files[p]
			if val == false then
				return nil, "permission denied"
			end
			if type(val) == "string" then
				return val
			end
			return nil, "not found"
		end,
	}
end

return H
