-- Backend registrations belong to the registering public context, matching other mare services.
return function(ctx, cfg)
	local entries, cleanup, disposing = {}, function() end, false
	local service = {}
	function service:register(caller, name, backend)
		assert(not disposing, "Terminal service is disposing")
		assert(type(name) == "string" and name:match("^[a-z][a-z0-9_-]*$"), "Invalid terminal backend type")
		assert(type(backend) == "table" and type(backend.open) == "function", "Terminal backend requires open")
		assert(not entries[name], "Terminal backend type already registered")
		assert(
			backend.bootstrap == nil or type(backend.bootstrap) == "string",
			"Terminal backend bootstrap must be a string"
		)
		local entry = {
			name = name,
			open = backend.open,
			bootstrap = backend.bootstrap,
			active = true,
			removed = mare.task.token(),
		}
		entries[name] = entry
		local function remove()
			if entries[name] == entry then
				entries[name] = nil
				entry.active = false
				entry.removed:cancel()
				cleanup(entry)
			end
		end
		caller:effect(function()
			return remove
		end)
		return remove
	end
	function service:list()
		local names = {}
		for name in pairs(entries) do
			names[#names + 1] = name
		end
		table.sort(names)
		return mare.json.array(names)
	end
	local function native(dialect)
		return {
			open = function(opts)
				local effective = {}
				for key, value in pairs(cfg) do
					effective[key] = value
				end
				effective.shell_dialect = dialect
				if dialect ~= cfg.shell_dialect then
					effective.shell, effective.shell_args = nil, {}
				end
				opts.cmd, opts.args = require("terminal.config").shell(effective)
				return mare.pty.spawn(opts)
			end,
			bootstrap = dialect == "pwsh"
					and "[Console]::InputEncoding = [Text.UTF8Encoding]::new(); [Console]::OutputEncoding = [Text.UTF8Encoding]::new(); function global:prompt { $code = if ($?) { 0 } elseif ($LASTEXITCODE -is [int]) { $LASTEXITCODE } else { 1 }; [Console]::Write([char]27 + ']133;D;' + $code + [char]7); 'mare> ' }\r"
				or nil,
		}
	end
	service:register(ctx, "bash", native("bash"))
	service:register(ctx, "pwsh", native("pwsh"))
	ctx:effect(function()
		return function()
			disposing = true
		end
	end)
	require("mare_lib").service(ctx, "terminals", service)
	return {
		get = function(name)
			return assert(entries[name or cfg.shell_dialect], "Unknown terminal backend type")
		end,
		on_remove = function(fn)
			cleanup = fn
		end,
	}
end
