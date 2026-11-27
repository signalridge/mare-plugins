-- Interactive PTY terminal registry, backend, and yield-aware wait tools.
-- All process, policy and terminal-text enforcement uses public mare.Pty primitives.
return {
	name = "terminals",
	tags = {},
	inject = { "tools", "context", "task" },
	provide = { "terminals" },
	contracts = {
		terminals = {
			doc = "Interactive PTY terminal backend registry.",
			methods = {
				register = {
					doc = "Register a named terminal backend implementation for the caller's lifetime.",
					expose = "lua",
					scope = "host",
					registration = true,
					params = {
						type = "object",
						properties = {
							name = { type = "string", description = "Unique backend name." },
							bootstrap = {
								type = "string",
								description = "Optional shell bootstrap snippet.",
							},
						},
						required = { "name" },
						additionalProperties = false,
					},
					order = { "name", "..." },
					callbacks = {
						open = "fun(options: table, cancel?: any): any",
					},
				},
				list = {
					doc = "List registered terminal backend names.",
					expose = "lua",
					scope = "host",
					params = {
						type = "object",
						properties = {},
						additionalProperties = false,
					},
					order = {},
					result = { type = "array", items = { type = "string" } },
				},
			},
		},
	},
	config_schema = {
		max_sessions = {
			type = "integer",
			default = 4,
			min = 1,
			max = 16,
			desc = "Maximum concurrent PTY sessions.",
			apply = "live",
		},
		buffer_bytes = {
			type = "integer",
			default = 4 * 1024 * 1024,
			min = 1024,
			max = 16 * 1024 * 1024,
			unit = "bytes",
			desc = "Maximum retained output buffer size per terminal session in bytes.",
			apply = "next_op",
		},
		scrollback_lines = {
			type = "integer",
			default = 10000,
			min = 1,
			max = 100000,
			unit = "lines",
			desc = "Maximum retained scrollback lines per terminal session.",
			apply = "next_op",
		},
		read_max_bytes = {
			type = "integer",
			default = 256 * 1024,
			min = 1,
			max = 4 * 1024 * 1024,
			unit = "bytes",
			desc = "Maximum bytes returned by a single terminal read.",
			apply = "next_op",
		},
		rows = {
			type = "integer",
			default = 40,
			min = 1,
			max = 1000,
			unit = "rows",
			desc = "Default terminal viewport rows.",
			apply = "next_op",
		},
		cols = {
			type = "integer",
			default = 160,
			min = 1,
			max = 1000,
			unit = "cols",
			desc = "Default terminal viewport columns.",
			apply = "next_op",
		},
		shell = {
			type = "string",
			default = nil,
			nullable = true,
			desc = "Optional explicit shell executable path or name.",
			apply = "next_op",
		},
		shell_dialect = {
			type = "enum",
			choices = { "bash", "pwsh" },
			default = "bash",
			desc = "Shell dialect used for default argument selection.",
			apply = "next_op",
		},
		shell_args = {
			type = "list",
			items = { type = "string" },
			default = {},
			desc = "Extra arguments passed when launching the shell.",
			apply = "next_op",
		},
		enable_run_in_background = {
			type = "boolean",
			default = true,
			desc = "Allow terminal sessions to continue running in the background.",
			apply = "live",
		},
		timeout_ms = {
			type = "integer",
			default = 30000,
			min = 1,
			max = 30000,
			unit = "ms",
			desc = "Default wait timeout in milliseconds for terminal operations.",
			apply = "next_op",
		},
		idle_silence_ms = {
			type = "integer",
			default = 1000,
			min = 1,
			max = 30000,
			unit = "ms",
			desc = "Idle silence threshold in milliseconds before returning output.",
			apply = "next_op",
		},
		handoff_grace_ms = {
			type = "integer",
			default = 500,
			min = 0,
			max = 30000,
			unit = "ms",
			desc = "Grace period in milliseconds when handing off a running terminal.",
			apply = "next_op",
		},
		prompt_tail_grace_ms = {
			type = "integer",
			default = 1000,
			min = 0,
			max = 30000,
			unit = "ms",
			desc = "Grace period in milliseconds waiting for prompt tail output.",
			apply = "next_op",
		},
		poll_interval_ms = {
			type = "integer",
			default = 50,
			min = 1,
			max = 1000,
			unit = "ms",
			desc = "Polling interval in milliseconds for PTY output checks.",
			apply = "next_op",
		},
		stop_grace_ms = {
			type = "integer",
			default = 3000,
			min = 0,
			max = 30000,
			unit = "ms",
			desc = "Grace period in milliseconds before force-stopping a terminal process.",
			apply = "next_op",
		},
	},
	apply = function(ctx, cfg)
		assert(mare.pty and type(mare.pty.capabilities) == "function", "terminal requires public bounded PTY support")
		local caps = mare.pty.capabilities()
		assert(
			caps.streaming_text and caps.terminal_view and caps.policy_fence and caps.max_write_bytes >= 16384,
			"terminal requires safe PTY text and policy fencing"
		)
		require("terminal.config").validate(cfg)
		local backends = require("terminal.backends")(ctx, cfg)
		local registry = require("terminal.registry")(ctx, cfg, backends)
		local operations = require("terminal.operation")(ctx, cfg, registry, caps)
		-- jobs is optional: follow it while its provider is available.
		local jobs_of = require("mare_lib").follow(ctx, "jobs")
		local track = require("terminal.jobs")(ctx, jobs_of)
		ctx.context:section({
			name = "terminal:guidance",
			order = 850,
			interpolate = false,
			text = "Use terminal tools only when state must persist across calls or a program needs interactive input (REPLs, read scripts, question-and-answer CLIs). Use bash for one-shot commands. Keep the terminal session_id and close the terminal when finished. A wait timeout returns control; it does not mean the command ended.",
		})
		local function result(value)
			return { content = mare.json.encode(value), details = value, is_error = value.stop_unconfirmed or nil }
		end
		local function integer(value, default, min, max)
			if value == nil then
				return default
			end
			assert(math.type(value) == "integer" and value >= min and value <= max, "Integer argument out of range")
			return value
		end
		local function ready(r, token)
			local deadline = mare.task.clock() + cfg.timeout_ms
			while true do
				if token:is_cancelled() then
					error("Terminal creation cancelled", 0)
				end
				if r.backend and r.backend.active == false then
					error("Terminal backend was removed during creation", 0)
				end
				if r.eof then
					error(r.read_error or "Terminal exited before startup readiness", 0)
				end
				local view, foreground = r.pty:view({ screen = false }), r.pty:foreground()
				if
					view.prompt_generation > 0
					and view.tail:sub(-6) == "mare> "
					and mare.task.clock() - r.last_output >= cfg.poll_interval_ms
					and (foreground or not caps.foreground)
				then
					r.shell_pgid = foreground and foreground.pgid
					return "prompt"
				end
				if mare.task.clock() >= deadline then
					error("Terminal startup readiness timeout", 0)
				end
				mare.task.sleep(cfg.poll_interval_ms, token)
			end
		end

		local function resolve_open_cwd(raw_cwd, base_cwd)
			local base = (type(base_cwd) == "string" and base_cwd ~= "") and base_cwd or mare.cwd
			if raw_cwd == nil or raw_cwd == "" or raw_cwd == "." then
				return mare.fs.resolve(base)
			end
			local raw = raw_cwd
			if not raw:match("^/") and not raw:match("^%a:[/\\]") then
				raw = base:gsub("[/\\]+$", "") .. "/" .. raw
			end
			return mare.fs.resolve(raw)
		end
		local function register(name, description, properties, required, effect, execute, extra)
			-- the schema follows the config only: jobs is followed and may come up after apply,
			-- so its availability is checked when a call asks for run_in_background
			if not cfg.enable_run_in_background then
				properties.run_in_background = nil
			end
			local def = {
				description = description,
				side_effect = effect,
				idempotent = effect == "read",
				summary = function(args)
					return name .. "(" .. (args.name or args.session_id or "") .. ")"
				end,
				render = function(args, value, expanded)
					return require("terminal.view")(name, args, value, expanded)
				end,
				timeout_ms = 60000,
				parameters = {
					type = "object",
					additionalProperties = false,
					properties = properties,
					required = mare.json.array(required),
				},
				execute = function(args, tool)
					local ok, value = pcall(execute, args, tool)
					if ok then
						return result(value)
					end
					if type(value) == "table" and value.cancelled then
						return { content = tostring(value.message), is_error = true, cancelled = true }
					end
					return {
						content = tostring(value),
						is_error = true,
						cancelled = tool and tool.cancel and tool.cancel:is_cancelled() or nil,
					}
				end,
			}
			for k, v in pairs(extra or {}) do
				def[k] = v
			end
			ctx.tools:register(name, def)
		end
		local function abort_error(msg)
			error({ message = msg, cancelled = true }, 0)
		end
		local command_shell = cfg.shell_dialect == "pwsh" and "powershell" or "bash"
		local open_bin = cfg.shell_dialect == "pwsh" and "pwsh" or "bash"
		local id = { type = "string", description = "Owned live terminal session_id from terminal_open/list" }
		register(
			"terminal_open",
			"Open a persistent interactive bash PTY for REPLs or multi-step input. Use bash for one-shot commands. Returns an owned session_id; keep it and close when finished. Returns only after the controlled shell prompt is observed; startup failures close the new terminal.",
			{
				name = { type = "string" },
				cwd = { type = "string" },
				type = {
					type = "string",
					description = "Registered terminal backend type; defaults to configured shell dialect",
				},
			},
			{},
			"external",
			function(args, tool)
				local name = args.name and args.name:match("^%s*(.-)%s*$")
				assert(not name or (#name > 0 and #name <= 64), "Terminal name must contain 1..64 bytes")
				local cwd = resolve_open_cwd(args.cwd, tool.cwd or mare.cwd)
				local st = mare.fs.stat(cwd)
				assert(st and st.kind == "dir", "Terminal cwd is not an accessible directory")
				local r = registry:open(name, cwd, tool, args.type)
				local ok, reason = pcall(ready, r, tool.cancel)
				if not ok then
					registry:close(r)
					if tool.cancel:is_cancelled() then
						abort_error(reason)
					end
					error(reason, 0)
				end
				local snapshot = registry:snapshot(r)
				snapshot.output, snapshot.cursor, snapshot.truncated = r.buffer:delta(0, cfg.read_max_bytes)
				snapshot.wait_reason = reason
				return snapshot
			end,
			{
				command_tool = true,
				command = { argv = { open_bin } },
			}
		)
		register(
			"terminal_send",
			"Send UTF-8 text to an owned interactive terminal; submit appends Enter. Waits for at most wait_ms, then returns output and current shell status. wait_elapsed does not mean the command ended. Cancellation interrupts the foreground operation and preserves shell state. Background mode creates an independent send job for job_output/job_kill.",
			{
				session_id = id,
				text = { type = "string" },
				submit = { type = "boolean" },
				wait_ms = { type = "integer" },
				run_in_background = { type = "boolean" },
			},
			{ "session_id", "text" },
			"external",
			function(args, tool)
				local r = registry:get(args.session_id)
				assert(utf8.len(args.text), "Terminal input must be valid UTF-8")
				local text = args.text .. (args.submit ~= false and "\r" or "")
				assert(
					#text <= 16384 and not text:find("\0", 1, true),
					"Terminal input must be at most 16384 bytes and contain no NUL"
				)
				local ms = integer(args.wait_ms, cfg.timeout_ms, 0, cfg.timeout_ms)
				assert(
					not args.run_in_background or (cfg.enable_run_in_background and jobs_of()),
					"Background send requires the jobs service"
				)
				if tool.cancel:is_cancelled() then
					abort_error("Terminal send cancelled before write")
				end
				local bg = args.run_in_background == true
				local job
				local op =
					operations:start(r, text, bg and cfg.timeout_ms or ms, bg and mare.task.token() or tool.cancel, {
						background = bg,
						before_write = bg and function(started_op)
							job = track(r, started_op)
							r.job = job
						end or nil,
					})
				if not bg then
					op:wait({
						timeout_ms = ms,
						cancel = tool.cancel,
						update = tool.update and function()
							local partial = registry:snapshot(r)
							partial.output, partial.cursor, partial.truncated =
								r.buffer:delta(op.initial_cursor, cfg.read_max_bytes)
							partial.wait_reason = op.reason or "running"
							tool.update(result(partial))
						end,
					})
				end
				if op.error then
					error(op.error, 0)
				end
				if op.cancelled then
					if not op.done then
						abort_error(
							"Terminal send cancelled; interrupt delivered, foreground still draining and terminal busy"
						)
					end
					if op.stop_unconfirmed then
						abort_error("Terminal send cancelled: foreground stop_unconfirmed; shell retained")
					end
					abort_error("Terminal send cancelled; foreground settled and shell retained")
				end
				local snapshot = registry:snapshot(r)
				snapshot.output, snapshot.cursor, snapshot.truncated =
					r.buffer:delta(op.initial_cursor, cfg.read_max_bytes)
				snapshot.wait_reason = job and "background" or (op.reason or "wait_elapsed")
				snapshot.job_id = job and job.job_id
				return snapshot
			end,
			{
				command_tool = true,
				command = { shell = command_shell, arg = "text" },
			}
		)
		register(
			"terminal_read",
			"Read a bounded page of retained terminal output without sending input. offset counts backward from newest retained lines; old output may have been dropped. This snapshot does not wait for or assert command completion.",
			{
				session_id = id,
				offset = { type = "integer" },
				count = { type = "integer" },
			},
			{ "session_id" },
			"read",
			function(args)
				local r = registry:get(args.session_id)
				local page = r.pty:page({
					offset = integer(args.offset, 0, 0, cfg.scrollback_lines),
					count = integer(args.count, 500, 1, cfg.scrollback_lines),
					max_bytes = cfg.read_max_bytes,
				})
				local snapshot = registry:snapshot(r)
				page.session_id, page.status = r.id, snapshot.status
				page.screen, page.alternate_screen = snapshot.screen, snapshot.alternate_screen
				page.command_exit_code = snapshot.command_exit_code
				if r.read_error then
					error(r.read_error, 0)
				end
				return page
			end
		)
		register(
			"terminal_list",
			"List this agent's terminal sessions and shell status. Exited shells are distinct from commands still running inside live shells; close unused sessions.",
			{},
			{},
			"read",
			function()
				return { sessions = registry:list() }
			end
		)
		register(
			"terminal_signal",
			"Send an allowed signal to the verified foreground process group of an owned terminal. Shell-targeted SIGKILL is rejected; use terminal_close to discard shell state. Delivery does not imply command completion.",
			{
				session_id = id,
				signal = { type = "string", enum = { "SIGINT", "SIGTERM", "SIGKILL", "SIGTSTP", "SIGHUP" } },
			},
			{ "session_id", "signal" },
			"external",
			function(args, tool)
				local r = registry:get(args.session_id)
				assert(not r.closing and not r.eof, "Terminal closing or exited")
				assert(caps.foreground_signals, "PTY_SIGNAL_UNSUPPORTED: foreground signalling unavailable")
				if tool.cancel:is_cancelled() then
					abort_error("Terminal signal cancelled before delivery")
				end
				local foreground = r.pty:foreground()
				assert(
					args.signal ~= "SIGKILL" or not foreground or foreground.pgid ~= r.shell_pgid,
					"Refusing SIGKILL on terminal shell; use terminal_close"
				)
				local pgid = r.pty:signal(args.signal, { protected_pgid = r.shell_pgid })
				return { session_id = r.id, signal = args.signal, target_pgid = pgid, delivered = true }
			end
		)
		register(
			"terminal_close",
			"Close an owned terminal and stop its whole process tree. Reports confirmed stopped or stop_unconfirmed; shell state is discarded. Close terminals when finished, before changing permission mode.",
			{ session_id = id },
			{ "session_id" },
			"external",
			function(args)
				if registry:closed(args.session_id) then
					return {
						session_id = args.session_id,
						stopped = true,
						stop_unconfirmed = false,
						already_closed = true,
					}
				end
				local r = registry:get_for_close(args.session_id)
				local stopped = registry:close(r)
				stopped.session_id = args.session_id
				return stopped
			end
		)
	end,
}
