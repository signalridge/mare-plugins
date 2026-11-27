-- Service contract validation on all 11 service-providing plugins.
-- Self-authored contract validation test.

local SERVICE_PLUGINS = {
	{ dir = "btw", service = "btw" },
	{ dir = "codemode", service = "codemode" },
	{ dir = "goal", service = "goals" },
	{ dir = "plan-mode", service = "plan_mode" },
	{ dir = "presets", service = "presets" },
	{ dir = "schedule", service = "schedule" },
	{ dir = "secrets", service = "secrets" },
	{ dir = "session-title", service = "session_title" },
	{ dir = "team", service = "team" },
	{ dir = "terminals", service = "terminals" },
	{ dir = "todo", service = "todo" },
}

local VALID_EXPOSE = { lua = true, both = true }
local VALID_ACCESS = { primary = true, peer = true, peer_default = true }
local VALID_SCOPE = { host = true, workspace = true, session = true }
local VALID_EVENT_MODE = { emit = true, waterfall = true, vote = true, request = true, policy = true }

local function check_method(service, method, spec)
	assert(type(spec) == "table", ("%s.%s: spec must be table"):format(service, method))
	assert(type(spec.doc) == "string" and spec.doc:find("%S") ~= nil, ("%s.%s: missing doc"):format(service, method))
	assert(
		VALID_EXPOSE[spec.expose],
		("%s.%s: invalid or missing expose (%s)"):format(service, method, tostring(spec.expose))
	)
	if spec.expose == "lua" then
		assert(
			spec.access == nil,
			("%s.%s: non-remote method cannot declare access (%s)"):format(service, method, tostring(spec.access))
		)
	elseif spec.access ~= nil then
		assert(VALID_ACCESS[spec.access], ("%s.%s: invalid access (%s)"):format(service, method, tostring(spec.access)))
	end
	assert(
		VALID_SCOPE[spec.scope],
		("%s.%s: invalid or missing scope (%s)"):format(service, method, tostring(spec.scope))
	)
	assert(
		type(spec.params) == "table" and spec.params.type == "object",
		("%s.%s: params must be object schema"):format(service, method)
	)
	assert(type(spec.order) == "table", ("%s.%s: missing order list"):format(service, method))
	if spec.registration then
		assert(spec.result == nil, ("%s.%s: registration method must not declare result"):format(service, method))
	else
		assert(type(spec.result) == "table", ("%s.%s: missing result schema"):format(service, method))
	end

	local props = type(spec.params.properties) == "table" and spec.params.properties or {}
	local lua_params = type(spec.lua) == "table" and spec.lua or {}
	local order_len = #spec.order
	local has_rest = order_len > 0 and spec.order[order_len] == "..."
	local seen = {}
	for i, name in ipairs(spec.order) do
		assert(type(name) == "string", ("%s.%s: order[%d] must be string"):format(service, method, i))
		if name == "..." then
			assert(i == order_len, ("%s.%s: '...' must be last in order"):format(service, method))
		else
			assert(
				props[name] ~= nil or lua_params[name] ~= nil,
				("%s.%s: order param '%s' not in params.properties"):format(service, method, name)
			)
			assert(not seen[name], ("%s.%s: duplicate param '%s' in order"):format(service, method, name))
			seen[name] = true
		end
	end
	if not has_rest then
		for name in pairs(props) do
			assert(seen[name], ("%s.%s: params.properties['%s'] missing from order"):format(service, method, name))
		end
		assert(
			spec.params.additionalProperties == false,
			("%s.%s: params.additionalProperties must be false without '...'"):format(service, method)
		)
	end
	if spec.scope == "session" then
		assert(
			props.session_id == nil,
			("%s.%s: session-scoped method must not declare session_id"):format(service, method)
		)
	end
	if spec.scope == "workspace" then
		assert(props.cwd == nil, ("%s.%s: workspace-scoped method must not declare cwd"):format(service, method))
	end
	if spec.errors ~= nil then
		assert(type(spec.errors) == "table", ("%s.%s: errors must be list"):format(service, method))
	end
	if spec.callbacks ~= nil then
		assert(type(spec.callbacks) == "table", ("%s.%s: callbacks must be table"):format(service, method))
		assert(has_rest, ("%s.%s: callbacks require '...' at end of order"):format(service, method))
		for cb_name, cb_type in pairs(spec.callbacks) do
			assert(
				type(cb_name) == "string" and type(cb_type) == "string" and cb_type:match("^fun%("),
				("%s.%s: callback '%s' must map to a LuaLS fun(...) type"):format(service, method, tostring(cb_name))
			)
		end
	end
end

local failures = {}
for _, entry in ipairs(SERVICE_PLUGINS) do
	local path = ("plugins/%s/init.lua"):format(entry.dir)
	local ok, err = pcall(function()
		local plugin = assert(loadfile(path))()
		assert(type(plugin) == "table", path .. ": must return table")
		assert(type(plugin.contracts) == "table", path .. ": missing contracts")
		local contract = plugin.contracts[entry.service]
		assert(type(contract) == "table", ("%s: missing contracts.%s"):format(path, entry.service))
		assert(
			type(contract.doc) == "string" and contract.doc:find("%S") ~= nil,
			("%s: contracts.%s.doc missing"):format(path, entry.service)
		)
		assert(
			type(contract.methods) == "table" and next(contract.methods) ~= nil,
			("%s: contracts.%s.methods missing or empty"):format(path, entry.service)
		)
		local declared_errors = {}
		if contract.errors ~= nil then
			assert(type(contract.errors) == "table", ("%s: errors must be table"):format(entry.service))
			for err_name, err_spec in pairs(contract.errors) do
				assert(
					type(err_name) == "string" and err_name:match("^[a-z][a-z0-9_]*$") ~= nil,
					("%s: invalid error name '%s'"):format(entry.service, tostring(err_name))
				)
				assert(type(err_spec) == "table", ("%s.errors.%s: must be table"):format(entry.service, err_name))
				assert(
					type(err_spec.doc) == "string" and err_spec.doc:find("%S") ~= nil,
					("%s.errors.%s: missing doc"):format(entry.service, err_name)
				)
				for field in pairs(err_spec) do
					assert(
						field == "doc" or field == "data",
						("%s.errors.%s: unknown field '%s'"):format(entry.service, err_name, tostring(field))
					)
				end
				declared_errors[err_name] = true
			end
		end
		local function check_events(root, events)
			assert(type(events) == "table", ("%s: events must be table"):format(root))
			for ev_name, ev_spec in pairs(events) do
				assert(
					type(ev_name) == "string" and ev_name:match("^[a-z][a-z0-9%-]*$") ~= nil,
					("%s: invalid event name '%s'"):format(root, tostring(ev_name))
				)
				assert(type(ev_spec) == "table", ("%s.events.%s: must be table"):format(root, ev_name))
				assert(
					type(ev_spec.doc) == "string" and ev_spec.doc:find("%S") ~= nil,
					("%s.events.%s: missing doc"):format(root, ev_name)
				)
				local mode = ev_spec.mode or "emit"
				assert(
					VALID_EVENT_MODE[mode],
					("%s.events.%s: invalid mode '%s'"):format(root, ev_name, tostring(mode))
				)
				local expose = ev_spec.expose or "lua"
				assert(
					VALID_EXPOSE[expose],
					("%s.events.%s: invalid expose '%s'"):format(root, ev_name, tostring(expose))
				)
			end
		end
		if contract.events ~= nil then
			check_events(entry.service, contract.events)
		end
		for root, extra in pairs(plugin.contracts) do
			if root ~= entry.service then
				assert(type(extra) == "table", ("%s: contracts.%s must be table"):format(path, tostring(root)))
				assert(
					type(extra.owner) == "string" and extra.owner:find("%S") ~= nil,
					("%s: event-only contract '%s' must declare owner"):format(path, tostring(root))
				)
				assert(
					type(extra.events) == "table" and next(extra.events) ~= nil,
					("%s: event-only contract '%s' must declare events"):format(path, tostring(root))
				)
				check_events(root, extra.events)
			end
		end
		for method, spec in pairs(contract.methods) do
			check_method(entry.service, method, spec)
			if spec.errors ~= nil then
				for _, err_name in ipairs(spec.errors) do
					assert(
						declared_errors[err_name],
						("%s.%s: undeclared error '%s'"):format(entry.service, method, tostring(err_name))
					)
				end
			end
		end
	end)
	if not ok then
		failures[#failures + 1] = err
	end
end

if #failures > 0 then
	io.stderr:write("Service contract failures:\n  - " .. table.concat(failures, "\n  - ") .. "\n")
	os.exit(1)
end

-- Scan every Lua file under plugins/ for bus:emit("<root>/<name>") literals and verify each is declared.
local function list_plugin_lua_files()
	local is_windows = package.config:sub(1, 1) == "\\"
	local cmd = is_windows and 'dir /b /s "plugins\\*.lua"' or 'find plugins -type f -name "*.lua" | sort'
	local pipe = assert(io.popen(cmd, "r"))
	local files = {}
	for line in pipe:lines() do
		local norm = line:gsub("\\", "/")
		local rel = norm:match("(plugins/.+%.lua)$")
		if rel then
			files[#files + 1] = rel
		end
	end
	pipe:close()
	assert(#files > 0, "failed to enumerate plugin Lua files")
	return files
end

local CORE_WORKFLOW_EVENTS = {
	["workflow/changed"] = true,
	["workflow/started"] = true,
	["workflow/phase"] = true,
	["workflow/log"] = true,
	["workflow/agent-started"] = true,
	["workflow/agent-completed"] = true,
	["workflow/completed"] = true,
}

local declared_by_plugin = {}
for _, file in ipairs(list_plugin_lua_files()) do
	local plugin_dir = file:match("^plugins/([^/]+)/")
	local handle = assert(io.open(file, "r"))
	local src = handle:read("*a")
	handle:close()
	for ev in src:gmatch('bus:emit%(%s*"([^"]+)"') do
		local root, short = ev:match("^([^/]+)/(.+)$")
		assert(root and short, ("%s: invalid bus:emit event name %q"):format(file, ev))
		if plugin_dir == "workflow" then
			assert(CORE_WORKFLOW_EVENTS[ev], ("%s: workflow emits undeclared event %q"):format(file, ev))
		else
			if declared_by_plugin[plugin_dir] == nil then
				local p = assert(loadfile(("plugins/%s/init.lua"):format(plugin_dir)))()
				local set = {}
				if type(p.contracts) == "table" then
					for croot, cspec in pairs(p.contracts) do
						if type(cspec) == "table" and type(cspec.events) == "table" then
							for ename in pairs(cspec.events) do
								set[croot .. "/" .. ename] = true
							end
						end
					end
				end
				declared_by_plugin[plugin_dir] = set
			end
			assert(
				declared_by_plugin[plugin_dir][ev],
				("%s: emitted event %q is not declared in plugins/%s/init.lua contracts"):format(file, ev, plugin_dir)
			)
		end
	end
end

-- Regression checks for schedule method schemas, callbacks, registration=true, and presets scope.
local schedule_plugin = assert(loadfile("plugins/schedule/init.lua"))()
local sched_methods = schedule_plugin.contracts.schedule.methods
assert(
	sched_methods.create.scope == "session"
		and sched_methods.create.result
		and sched_methods.create.result.type == "string",
	"schedule.create must be session string"
)
assert(
	sched_methods.list.scope == "session" and sched_methods.list.result.type == "array",
	"schedule.list must be session array"
)
assert(
	sched_methods.control.scope == "session"
		and sched_methods.control.params
		and sched_methods.control.order
		and sched_methods.control.result
		and sched_methods.control.result.type == "object",
	"schedule.control must have typed params/order/object result"
)
assert(
	sched_methods.submit.scope == "session"
		and sched_methods.submit.result
		and sched_methods.submit.result.type == "boolean",
	"schedule.submit must be session boolean"
)
assert(sched_methods.create_durable.scope == "host", "schedule.create_durable must be host")
assert(
	sched_methods.list_durable.scope == "host"
		and sched_methods.list_durable.result
		and sched_methods.list_durable.result.type == "object",
	"schedule.list_durable must be host object"
)
assert(
	sched_methods.view.scope == "host"
		and sched_methods.view.order
		and sched_methods.view.order[1] == "request"
		and sched_methods.view.result.type == "object",
	"schedule.view must take request object"
)
assert(
	sched_methods.history.scope == "host"
		and sched_methods.history.order
		and sched_methods.history.order[1] == "request"
		and sched_methods.history.result.type == "object",
	"schedule.history must take request object"
)
assert(
	sched_methods.delivery_limits.scope == "host" and sched_methods.delivery_limits.result.type == "object",
	"schedule.delivery_limits must be host object"
)

local terminal_plugin = assert(loadfile("plugins/terminals/init.lua"))()
local term_reg = terminal_plugin.contracts.terminals.methods.register
assert(
	type(term_reg.callbacks) == "table" and term_reg.callbacks.open == "fun(options: table, cancel?: any): any",
	"terminals.register must declare open(options, cancel?) in callbacks"
)
assert(term_reg.registration == true and term_reg.result == nil, "terminals.register must declare registration = true")
assert(term_reg.order[#term_reg.order] == "...", "terminals.register must use trailing '...' for backend opts")

local title_plugin = assert(loadfile("plugins/session-title/init.lua"))()
local title_reg = title_plugin.contracts.session_title.methods.register
assert(
	type(title_reg.callbacks) == "table" and title_reg.callbacks.generate == "fun(work: table): table?",
	"session_title.register must declare generate(work) in callbacks"
)
assert(title_reg.order[#title_reg.order] == "...", "session_title.register must use trailing '...' for definition opts")

local presets_plugin = assert(loadfile("plugins/presets/init.lua"))()
assert(presets_plugin.contracts.presets.methods.stage.scope == "host", "presets.stage scope must be host")
assert(presets_plugin.contracts.presets.methods.staged.scope == "host", "presets.staged scope must be host")
assert(
	presets_plugin.contracts.presets.methods.read == nil
		and presets_plugin.contracts.presets.methods.list == nil
		and presets_plugin.contracts.presets.methods.register == nil,
	"subagent type definitions must have one registry"
)

print(("All %d service-providing plugins pass service contract checks."):format(#SERVICE_PLUGINS))
