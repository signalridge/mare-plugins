-- Explicit opt-in registration; independently implemented using public APIs.
return {
	name = "secrets",
	inject = { "commands", "session", "agent", "context", "llm" },
	provide = { "secrets" },
	contracts = {
		secrets = {
			doc = "Explicitly registered hidden session secrets and stored profile credentials.",
			errors = {
				not_configured = { doc = "secret is not configured in this profile" },
				unavailable = { doc = "credential enumeration is unavailable in this mare build" },
			},
			methods = {
				register = {
					doc = "Register a secret value for the current session and return its opaque reference.",
					expose = "lua",
					scope = "session",
					params = {
						type = "object",
						properties = {
							name = { type = "string", description = "Uppercase secret identifier ([A-Z0-9_]+)." },
							value = { type = "string", description = "Non-empty secret value." },
						},
						required = { "name", "value" },
						additionalProperties = false,
					},
					order = { "name", "value" },
					result = { type = "string" },
				},
				remove = {
					doc = "Revoke a registered secret lease from the current session.",
					expose = "lua",
					scope = "session",
					params = {
						type = "object",
						properties = {
							name = { type = "string", description = "Secret identifier to remove." },
						},
						required = { "name" },
						additionalProperties = false,
					},
					order = { "name" },
					result = { type = "boolean" },
				},
				list = {
					doc = "List currently registered session secret names and opaque references.",
					expose = "lua",
					scope = "session",
					params = {
						type = "object",
						properties = {},
						additionalProperties = false,
					},
					order = {},
					result = {
						type = "array",
						items = {
							type = "object",
							properties = {
								name = { type = "string" },
								reference = { type = "string" },
							},
							required = { "name", "reference" },
							additionalProperties = false,
						},
					},
				},
				save = {
					doc = "Persist a secret value in the host credential store and return its descriptor.",
					expose = "lua",
					scope = "host",
					params = {
						type = "object",
						properties = {
							name = { type = "string", description = "Uppercase secret identifier." },
							value = { type = "string", description = "Non-empty secret value." },
						},
						required = { "name", "value" },
						additionalProperties = false,
					},
					order = { "name", "value" },
					result = { type = "object" },
				},
				load = {
					doc = "Load a stored secret into the current session and return its opaque reference.",
					expose = "lua",
					scope = "session",
					params = {
						type = "object",
						properties = {
							name = { type = "string", description = "Stored secret identifier." },
						},
						required = { "name" },
						additionalProperties = false,
					},
					order = { "name" },
					result = { type = "string" },
					errors = { "not_configured" },
				},
				resolve = {
					doc = "Load a stored secret into the current session and return its reference and source metadata.",
					expose = "lua",
					scope = "session",
					params = {
						type = "object",
						properties = {
							name = { type = "string", description = "Stored secret identifier." },
						},
						required = { "name" },
						additionalProperties = false,
					},
					order = { "name" },
					result = { type = "object" },
					errors = { "not_configured" },
				},
				delete = {
					doc = "Delete a stored secret from the host credential store and revoke any session lease.",
					expose = "lua",
					scope = "host",
					params = {
						type = "object",
						properties = {
							name = { type = "string", description = "Stored secret identifier." },
						},
						required = { "name" },
						additionalProperties = false,
					},
					order = { "name" },
					result = { type = "object" },
				},
				describe = {
					doc = "Return non-secret metadata and masked preview for a stored secret.",
					expose = "lua",
					scope = "host",
					params = {
						type = "object",
						properties = {
							name = { type = "string", description = "Stored secret identifier." },
						},
						required = { "name" },
						additionalProperties = false,
					},
					order = { "name" },
					result = { type = "object" },
				},
				stored = {
					doc = "List descriptors for all stored secrets in the host credential store.",
					expose = "lua",
					scope = "host",
					params = {
						type = "object",
						properties = {},
						additionalProperties = false,
					},
					order = {},
					result = { type = "array", items = { type = "object" } },
					errors = { "unavailable" },
				},
			},
		},
	},
	apply = function(ctx)
		assert(type(mare.projection) == "table", "secrets requires core mare.projection support")
		local init_info = ctx.session:info()
		local entries, session_id, generation = {}, init_info.session_id, init_info.session_epoch
		local disposed = false
		local active_tokens = {}
		local function clear()
			for _, entry in pairs(entries) do
				entry:close()
			end
			entries = {}
			ctx.context:invalidate()
		end
		local function sync()
			local current = ctx.session:info()
			if current.session_id ~= session_id or current.session_epoch ~= generation then
				clear()
				session_id, generation = current.session_id, current.session_epoch
			end
		end
		local RESERVED_KEYS = {
			"jsonrpc",
			"method",
			"params",
			"result",
			"error",
			"id",
			"name",
			"text",
			"type",
			"role",
			"data",
			"code",
			"path",
			"cwd",
			"mode",
			"kind",
			"size",
			"mtime",
			"ctime",
			"args",
			"cmd",
			"env",
			"input",
			"output",
			"stdout",
			"stderr",
			"exit_code",
			"timed_out",
			"cancelled",
			"signal",
			"dropped",
			"value",
			"reference",
			"configured",
			"source",
			"scope",
			"writable",
			"masked",
			"invalid",
			"version",
			"explicit-secret",
			"message",
			"messages",
			"system",
			"tools",
			"tool_calls",
			"tool_call_id",
			"tool_name",
			"arguments",
			"content",
			"details",
			"is_error",
			"stop_reason",
			"usage",
			"model",
			"effort",
			"session",
			"session_id",
			"generation",
			"ephemeral",
			"readonly",
			"status",
			"title",
			"body",
			"items",
			"label",
			"detail",
			"preview",
			"selected",
			"disabled",
			"cancel",
			"secret",
			"placeholder",
			"default",
			"level",
			"timestamp",
			"turn_id",
			"execution_id",
			"call_id",
			"request_id",
			"idempotency_key",
			"reason",
			"decision",
			"grant",
			"sandbox",
			"permissions",
			"command",
			"timeout_ms",
			"tokens",
			"choices",
			"stream",
			"provider",
			"headers",
			"metadata",
			"options",
			"records",
			"entries",
			"additionalProperties",
			"permission_mode",
			"authorization",
			"password",
			"apikey",
			"bearer",
			"basic",
			"oauth",
			"admin",
			"false",
			"patch",
			"write",
			"files",
			"hooks",
			"agent",
			"tasks",
			"users",
			"email",
			"index",
			"count",
			"total",
			"limit",
			"query",
			"start",
			"close",
			"event",
			"order",
			"style",
			"width",
			"lines",
			"spans",
			"frame",
			"reply",
			"notes",
			"clear",
			"reset",
			"force",
			"owner",
			"state",
		}
		local MIN_SECRET_LEN = 5
		local function validate_secret_value(name, value)
			assert(type(value) == "string" and value ~= "", "Secret value must be a non-empty string")
			local ulen = utf8.len(value)
			assert(ulen, "Invalid secret UTF-8")
			assert(
				#value >= MIN_SECRET_LEN and ulen >= MIN_SECRET_LEN,
				"Secret value must be at least " .. MIN_SECRET_LEN .. " characters"
			)
			assert(
				not value:find("[[mare-value:", 1, true) and not ("[[mare-value:"):find(value, 1, true),
				"Secret value conflicts with projection reference syntax"
			)
			for _, reserved in ipairs(RESERVED_KEYS) do
				assert(not reserved:find(value, 1, true), "Secret value conflicts with reserved protocol key")
			end
			assert(
				not name:find(value, 1, true)
					and not ("mare-plugin/secrets/" .. name):find(value, 1, true)
					and mare.projection.project(name) == name,
				"Secret names must not contain registered values"
			)
		end
		local function secret_name(name)
			assert(type(name) == "string", "Invalid secret name")
			name = name:match("^%s*(.-)%s*$")
			assert(name:match("^[A-Z0-9_]+$"), "Invalid secret name")
			return name
		end
		local service = {}
		-- No config/env/password-store ingestion. Local callers must already hold the value.
		function service.register(_, _, name, value)
			sync()
			name = secret_name(name)
			assert(not entries[name], "Secret name already registered; remove it before replacing")
			validate_secret_value(name, value)
			for known in pairs(entries) do
				assert(not known:find(value, 1, true), "Secret names must not contain registered values")
			end
			mare.projection.project(value)
			local lease = mare.projection.register(value)
			entries[name] = lease
			ctx.context:invalidate()
			return lease.reference
		end
		function service.remove(_, _, name)
			sync()
			name = secret_name(name)
			if not entries[name] then
				return false
			end
			entries[name]:close()
			entries[name] = nil
			ctx.context:invalidate()
			return true
		end
		function service.list()
			sync()
			local out = (mare and mare.json and mare.json.array) and mare.json.array({}) or {}
			for name, lease in pairs(entries) do
				out[#out + 1] = { name = name, reference = lease.reference }
			end
			table.sort(out, function(a, b)
				return a.name < b.name
			end)
			return out
		end
		require("secrets.storage")(ctx, service, secret_name, validate_secret_value, sync)
		ctx.context:section({
			name = "secrets:references",
			order = 1600,
			interpolate = false,
			text = function()
				local registered = service.list()
				if #registered == 0 then
					return nil
				end
				local lines = {
					"Registered hidden values for this session. Use the exact reference in tool arguments when needed; only declared pure-data fields accept them; shell/program text rejects hidden substitutions. Every use requires approval. Never invent references or ask to reveal the values.",
				}
				for _, entry in ipairs(registered) do
					lines[#lines + 1] = entry.name .. ": " .. entry.reference
				end
				return mare.projection.project(table.concat(lines, "\n"))
			end,
		})
		-- A mare.Service keeps the `(impl, caller, ...)` method signature.
		require("mare_lib").service(ctx, "secrets", service)
		ctx:on("session/changed", sync)
		ctx:effect(function()
			return function()
				disposed = true
				for tok in pairs(active_tokens) do
					pcall(tok.cancel, tok)
				end
				active_tokens = {}
				clear()
			end
		end)
		ctx.commands:register("secrets", {
			description = "Register hidden values for this session; tool use requires approval",
			args = "[add NAME|save NAME|load NAME|describe NAME|delete NAME|remove NAME|clear|list|stored]",
			availability = "idle",
			run = function(args)
				if disposed then
					return
				end
				sync()
				local action, name = args:match("^%s*(%S+)%s*(.-)%s*$")
				if (action == "add" or action == "save") and name ~= "" then
					local ok_name, valid_name = pcall(secret_name, name)
					if not ok_name then
						mare.ui.notify(mare.projection.project(tostring(valid_name)), "error")
						return
					end
					if action == "add" and entries[valid_name] then
						mare.ui.notify("Secret name already registered; remove it before replacing", "error")
						return
					end
					local owner_id, owner_gen = session_id, generation
					local cancel_token = mare.task and type(mare.task.token) == "function" and mare.task.token() or nil
					if cancel_token then
						active_tokens[cancel_token] = true
					end
					local value = mare.ui.input({
						title = (action == "save" and "Save secret " or "Register secret ")
							.. valid_name
							.. (action == "save" and " (profile plaintext credential file)" or " (session only)"),
						secret = true,
						cancel = cancel_token,
					})
					if cancel_token then
						active_tokens[cancel_token] = nil
					end
					if disposed or (cancel_token and cancel_token:is_cancelled()) then
						return
					end
					sync()
					if value == nil then
						mare.ui.notify("Secret entry cancelled or no masked input UI is available", "info")
						return
					end
					if session_id ~= owner_id or generation ~= owner_gen or (ctx.agent:get() or {}).busy then
						mare.ui.notify("Session changed while entering the value; register again", "error")
						return
					end
					local operation = action == "save" and service.save or service.register
					local ok, reference = pcall(operation, service, ctx, name, value)
					if not ok then
						mare.ui.notify(mare.projection.project(tostring(reference)), "error")
						return
					end
					if action == "save" then
						mare.ui.notify(
							"Saved " .. name .. ". Use /secrets load " .. name .. " to register it for this session.",
							"info"
						)
						return
					end
					mare.ui.notify(
						"Registered " .. name .. ": " .. reference .. ". Every tool use requires approval.",
						"info"
					)
				elseif (action == "load" or action == "describe" or action == "delete") and name ~= "" then
					local ok, result, reason = pcall(service[action], service, ctx, name)
					if not ok or result == nil then
						mare.ui.notify(mare.projection.project(tostring(reason or result)), "error")
					elseif action == "load" then
						mare.ui.notify(
							"Registered " .. name .. ": " .. result .. ". Every tool use requires approval.",
							"info"
						)
					else
						mare.ui.notify(
							mare.projection.project(
								name
									.. ": "
									.. (result.configured and "configured" or "not configured")
									.. (result.masked and (" [" .. result.masked .. "]") or "")
									.. " (profile plaintext credential file)"
							),
							"info"
						)
					end
				elseif action == "remove" and name ~= "" then
					local ok, removed = pcall(service.remove, service, ctx, name)
					if not ok then
						mare.ui.notify(mare.projection.project(tostring(removed)), "error")
						return
					end
					mare.ui.notify(removed and "Registration revoked" or "No such registration", "info")
				elseif action == "stored" and name == "" then
					local ok, rows = pcall(service.stored)
					if not ok then
						local msg = type(rows) == "table" and rows.message or tostring(rows)
						mare.ui.notify(mare.projection.project(msg), "warning")
						return
					end
					local lines = { "Saved profile names (values hidden):" }
					for _, row in ipairs(rows) do
						lines[#lines + 1] = row.name
							.. ": "
							.. (row.invalid and "invalid record" or row.configured and "configured" or "not configured")
							.. (row.masked and (" [" .. row.masked .. "]") or "")
					end
					mare.ui.notify(mare.projection.project(table.concat(lines, "\n")), "info")
				elseif action == "clear" and name == "" then
					clear()
					mare.ui.notify("Registrations revoked; late output remains projected until exit", "info")
				elseif not action or (action == "list" and name == "") then
					local lines = {
						"Registrations are session-only; saved names persist in the profile credential file. This list shows active registrations. Approved tools can use or transmit their values.",
					}
					for _, entry in ipairs(service.list()) do
						lines[#lines + 1] = entry.name .. ": " .. entry.reference
					end
					mare.ui.notify(mare.projection.project(table.concat(lines, "\n")), "info")
				else
					mare.ui.notify(
						"Usage: /secrets add NAME | save NAME | load NAME | describe NAME | delete NAME | remove NAME | clear | list | stored. Values go only into masked input.",
						"error"
					)
				end
			end,
		})
	end,
}
