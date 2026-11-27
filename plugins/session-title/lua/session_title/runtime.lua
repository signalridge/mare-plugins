local RECORD_KIND = "session-title/state"
local warned_missing_api = false

local function fail_title(code, msg)
	local text = tostring(msg or "session title error")
	if mare and type(mare.error) == "function" then
		error(mare.error("session_title." .. code, text), 0)
	end
	error(text, 0)
end

local function error_message(err)
	if type(err) == "table" and err.message then
		return tostring(err.message)
	end
	return tostring(err)
end

return function(ctx, cfg)
	local mare_lib = require("mare_lib")
	if not mare_lib.callable(ctx.session.get) or not mare_lib.callable(ctx.session.update) then
		if not warned_missing_api then
			warned_missing_api = true
			mare.log("warn", "session-title disabled: session:get/update unavailable")
		end
		local disabled_err = "session-title disabled: session:get/update unavailable"
		mare_lib.service(ctx, "session_title", {
			get = function()
				return nil
			end,
			refresh = function()
				fail_title("title_unavailable", disabled_err)
			end,
			rename = function()
				fail_title("title_unavailable", disabled_err)
			end,
			register = function()
				return function() end
			end,
			cancel = function()
				return false
			end,
		})
		return
	end
	local text = require("session_title.text")
	local provider, pending, disposed, revision = nil, nil, false, 0
	local scheduled, last_model = nil, nil
	local recorded_meta, in_flight_commit = nil, nil
	local active, fallback_cancels = {}, {}
	local function find_recorded_meta(name, name_revision)
		if recorded_meta and recorded_meta.name == name and tonumber(recorded_meta.name_revision) == name_revision then
			return recorded_meta.metadata
		end
		if not mare_lib.callable(ctx.session.list_records) then
			return nil
		end
		local ok, rows = pcall(mare_lib.all_records, ctx.session, RECORD_KIND, { branch = "current" })
		if not ok or type(rows) ~= "table" then
			return nil
		end
		for i = #rows, 1, -1 do
			local r = rows[i]
			local entry = type(r) == "table" and type(r.data) == "table" and r.data or r
			if type(entry) == "table" and entry.name == name and tonumber(entry.name_revision) == name_revision then
				recorded_meta = entry
				return entry.metadata
			end
		end
		return nil
	end
	local function snapshot()
		local info = ctx.session:info()
		if not info or not info.session_id then
			return {
				id = info and info.session_id or nil,
				generation = info and info.session_epoch or nil,
				name = nil,
				revision = "0",
				name_revision = 0,
				metadata = nil,
				unstable = info and info.unstable,
				resume_error = info and info.resume_error,
				readonly = info and info.readonly,
				ephemeral = info and info.ephemeral,
			}
		end
		local ok, live = pcall(ctx.session.get, ctx.session, info.session_id)
		local name = ok and type(live) == "table" and live.name or info.name
		local name_rev = ok and type(live) == "table" and tonumber(live.name_revision) or 0
		local metadata = name and find_recorded_meta(name, name_rev) or nil
		return {
			id = info.session_id,
			generation = info.session_epoch,
			name = name,
			revision = tostring(name_rev),
			name_revision = name_rev,
			metadata = metadata,
			unstable = info.unstable,
			resume_error = info.resume_error,
			readonly = info.readonly,
			ephemeral = info.ephemeral,
		}
	end
	local function persist_meta(name, name_rev, metadata, owner_id, owner_gen)
		local entry = { name = name, name_revision = name_rev, metadata = metadata }
		if not mare_lib.callable(ctx.session.add_record) then
			recorded_meta = entry
			return true
		end
		local rec_opts = { sync = true }
		if type(owner_id) == "string" and type(owner_gen) == "string" then
			rec_opts.session_id = owner_id
			rec_opts.session_epoch = owner_gen
		end
		local call_ok, rec_ok, rec_err = pcall(ctx.session.add_record, ctx.session, RECORD_KIND, entry, rec_opts)
		if not call_ok or not rec_ok then
			local why = not call_ok and error_message(rec_ok) or error_message(rec_err or "session record rejected")
			mare.log("warn", "session-title: failed to persist title metadata: " .. why)
			return false, why
		end
		local cur = ctx.session:info()
		if not owner_id or (cur and cur.session_id == owner_id and cur.session_epoch == owner_gen) then
			recorded_meta = entry
		end
		return true
	end
	local function source(state)
		local m = state.metadata
		return m and m.kind == "session-title" and m.source or (state.name and "user" or nil)
	end
	local function usable()
		local info = ctx.session:info()
		return not disposed
			and not mare.agent_id
			and mare.mode ~= "child"
			and info.session_id ~= nil
			and not info.unstable
			and not info.resume_error
			and not info.readonly
			and not info.ephemeral
	end
	local function cancel()
		revision = revision + 1
		scheduled = nil
		for work in pairs(active) do
			work.cancel:cancel()
		end
		for tok in pairs(fallback_cancels) do
			tok:cancel()
		end
		fallback_cancels = {}
		pending = nil
	end
	local function is_user_source(src)
		return src == nil or src == "user" or src == "rpc" or src == "acp"
	end
	local function message_text(msg)
		if not msg or msg.role ~= "user" or msg.notification or msg.peer_message then
			return nil
		end
		local src = msg.input_source
		if src == nil then
			src = msg.source
		end
		if not is_user_source(src) then
			return nil
		end
		local parts = {}
		for _, block in ipairs(msg.input_content or msg.content or {}) do
			if block.type == "text" then
				parts[#parts + 1] = block.text
			end
		end
		local value = table.concat(parts, "\n")
		if text.normalize(value, #value) == "" then
			return nil
		end
		return value
	end
	local function inputs(limit)
		local out = {}
		for _, entry in ipairs(ctx.session:path_to()) do
			local value = message_text(entry.message)
			if value then
				out[#out + 1] = { id = entry.entry_id, text = value }
				if limit and #out >= limit then
					break
				end
			end
		end
		return out
	end
	local function emit(reason)
		ctx.bus:emit("session-title/changed", { state = snapshot(), reason = reason })
	end
	local function commit(title, kind, expected, details, cancel_tok)
		title = text.normalize(title, cfg.max_title_bytes)
		if title == "" then
			return nil, "empty session title"
		end
		if cancel_tok and cancel_tok:is_cancelled() then
			return nil, "cancelled"
		end
		local cur_info = ctx.session:info()
		if
			expected
			and expected.id
			and (not cur_info or cur_info.session_id ~= expected.id or cur_info.session_epoch ~= expected.generation)
		then
			return nil, "session changed"
		end
		local metadata = {
			kind = "session-title",
			source = kind,
			provider = details and details.provider,
			message_ids = details and details.message_ids,
			model = details and details.model,
		}
		local opts = expected and expected.name_revision ~= nil and { expected_revision = expected.name_revision }
			or nil
		in_flight_commit = {
			name = title,
			id = cur_info and cur_info.session_id,
			generation = cur_info and cur_info.session_epoch,
		}
		local ok, res = pcall(ctx.session.update, ctx.session, title, opts)
		in_flight_commit = nil
		if not ok then
			return nil, error_message(res)
		end
		local updated_rev = type(res) == "table" and tonumber(res.name_revision)
		local updated_name = type(res) == "table" and res.name or title
		if updated_rev == nil then
			local info = ctx.session:info()
			if info and info.session_id then
				local gok, live = pcall(ctx.session.get, ctx.session, info.session_id)
				if gok and type(live) == "table" then
					updated_rev = tonumber(live.name_revision)
					updated_name = live.name or updated_name
				end
			end
			updated_rev = updated_rev or 0
		end
		local meta_ok, meta_err = persist_meta(
			updated_name,
			updated_rev,
			metadata,
			cur_info and cur_info.session_id,
			cur_info and cur_info.session_epoch
		)
		if not meta_ok then
			emit("user")
			return nil, "title updated, but failed to persist title metadata: " .. tostring(meta_err)
		end
		emit(kind)
		return true
	end
	local function fallback(messages, expected)
		if not messages[1] then
			return nil, "no eligible user text"
		end
		local title = text.fallback(messages[1].text, cfg.fallback_max_words, cfg.fallback_max_bytes)
		if title == "" then
			return nil, "empty session title"
		end
		return commit(title, "fallback", expected, { message_ids = { messages[1].id } })
	end
	local function active_provider()
		if provider and provider.id == "llm" and not cfg.llm then
			return nil
		end
		return provider
	end
	local function provider_automatic(p)
		if p and p.id == "llm" then
			return cfg.automatic
		end
		return p and p.automatic
	end
	local function launch(messages, model, explicit)
		if not usable() then
			return nil, "session titles unavailable here"
		end
		local state = snapshot()
		local anchor = source(state) == "provider" and state.name or nil
		if not explicit and source(state) == "user" then
			return nil, "session title is pinned by the user"
		end
		if #messages == 0 then
			return nil, "no eligible user text"
		end
		cancel()
		local fallback_err
		if not state.name or explicit then
			local ok, err = fallback(messages, state)
			if ok then
				state = snapshot()
			elseif err ~= "empty session title" then
				return nil, err
			else
				fallback_err = err
			end
		end
		local registration = active_provider()
		if not registration then
			if fallback_err then
				return nil, fallback_err
			end
			return state
		end
		local work = {
			id = state.id,
			generation = state.generation,
			expected = state,
			revision = revision,
			cancel = mare.task.token(),
			messages = messages,
			model = model,
			anchor = anchor,
		}
		pending = work
		active[work] = registration
		work.task = ctx:spawn(function()
			local tracked <close> = setmetatable({}, {
				__close = function()
					active[work] = nil
					work.cancel:cancel()
				end,
			})
			local ok, finished, result = pcall(mare.task.timeout, cfg.timeout_ms, function()
				return registration.generate(work)
			end)
			if disposed or work.cancel:is_cancelled() then
				return
			end
			local current = snapshot()
			local valid = not disposed
				and pending == work
				and not work.cancel:is_cancelled()
				and provider == registration
				and current.id == work.id
				and current.generation == work.generation
				and current.revision == work.expected.revision
			if pending == work then
				pending = nil
			end
			if not valid then
				return
			end
			if not ok or not finished or type(result) ~= "table" or type(result.title) ~= "string" then
				mare.log(
					"warn",
					"session title generation failed: "
						.. tostring(ok and (finished and result or "timeout") or finished)
				)
				return
			end
			local saved, err = commit(
				result.title,
				"provider",
				work.expected,
				{ provider = registration.id, message_ids = result.message_ids, model = result.model },
				work.cancel
			)
			if not saved then
				mare.log("warn", "session title not saved: " .. tostring(err))
			end
		end)
		return state
	end
	local service = {}
	function service.get()
		return snapshot()
	end
	function service.cancel()
		cancel()
		return true
	end
	function service.refresh(_, _, opts)
		opts = opts or {}
		local current = snapshot()
		-- Concurrent explicit requests share the exact active generation unless forced.
		if pending and not opts.force then
			return current
		end
		local res, err = launch(inputs(), last_model or ctx.llm:current(), true)
		if res == nil and err ~= nil then
			fail_title("title_unavailable", err)
		end
		return res
	end
	function service.rename(_, _, name)
		if not usable() then
			fail_title("title_unavailable", "session titles unavailable here")
		end
		if type(name) ~= "string" then
			fail_title("invalid_title", "session title must be a string")
		end
		local title = text.normalize(name, cfg.max_title_bytes)
		if title == "" then
			fail_title("invalid_title", "empty session title")
		end
		cancel()
		local cur_info = ctx.session:info()
		in_flight_commit = {
			name = title,
			id = cur_info and cur_info.session_id,
			generation = cur_info and cur_info.session_epoch,
		}
		local ok, res = pcall(ctx.session.update, ctx.session, title)
		in_flight_commit = nil
		if not ok then
			fail_title("title_unavailable", error_message(res) or "failed to rename session")
		end
		local updated_rev = type(res) == "table" and tonumber(res.name_revision)
		local updated_name = type(res) == "table" and res.name or title
		if updated_rev == nil then
			local info = ctx.session:info()
			if info and info.session_id then
				local gok, live = pcall(ctx.session.get, ctx.session, info.session_id)
				if gok and type(live) == "table" then
					updated_rev = tonumber(live.name_revision)
					updated_name = live.name or updated_name
				end
			end
			updated_rev = updated_rev or 0
		end
		local meta_ok, meta_err = persist_meta(
			updated_name,
			updated_rev,
			{ kind = "session-title", source = "user" },
			cur_info and cur_info.session_id,
			cur_info and cur_info.session_epoch
		)
		emit("user")
		if not meta_ok then
			fail_title(
				"title_unavailable",
				"session renamed, but failed to persist title metadata: " .. tostring(meta_err)
			)
		end
		return true
	end
	function service.register(_, caller, definition)
		assert(not provider or (provider.id == "llm" and not cfg.llm), "a title provider is already registered")
		assert(
			type(definition) == "table"
				and type(definition.id) == "string"
				and definition.id ~= ""
				and type(definition.generate) == "function",
			"invalid title provider"
		)
		assert(
			definition.automatic == "first-prompt" or definition.automatic == "all-prompts",
			"invalid provider cadence"
		)
		local registration = { id = definition.id, generate = definition.generate, automatic = definition.automatic }
		provider = registration
		local function remove()
			if provider == registration then
				provider = nil
				cancel()
			end
			local draining = {}
			for work, owner in pairs(active) do
				if owner == registration then
					work.cancel:cancel()
					draining[#draining + 1] = work
				end
			end
			for _, work in ipairs(draining) do
				if work.task then
					pcall(work.task.wait, work.task)
				end
			end
		end
		caller:effect(function()
			return remove
		end)
		return remove
	end
	service.register(nil, ctx, require("session_title.llm")(ctx, cfg, text))
	require("mare_lib").service(ctx, "session_title", service)
	ctx:on("item/completed", function(ev)
		local msg = type(ev) == "table" and ev.item and ev.item.message or (type(ev) == "table" and ev.message or nil)
		if not usable() or not message_text(msg) then
			return
		end
		local state = snapshot()
		local state_source = source(state)
		if state_source == "user" then
			return
		end
		local p = active_provider()
		local auto = p and provider_automatic(p) or nil
		local needs_fallback = not state.name
		local needs_provider = p ~= nil and (auto == "all-prompts" or state_source ~= "provider")
		if not needs_fallback and not needs_provider then
			return
		end
		local limit
		if needs_provider and auto == "all-prompts" then
			limit = nil
		elseif needs_provider then
			limit = 2
		else
			limit = 1
		end
		local messages = inputs(limit)
		if #messages == 0 then
			return
		end
		if needs_provider and (auto == "all-prompts" or #messages == 1) then
			cancel()
		end
		local fb_rev = revision
		local fallback_task
		if needs_fallback then
			-- agent/message is observed while the agent still holds its persistence lease.
			-- Defer metadata writes until that callback has returned. The session writer
			-- enforces persistence errors; available() also rejects transient in-flight writes.
			local fb_cancel = mare.task.token()
			fallback_cancels[fb_cancel] = true
			fallback_task = ctx:after(0, function()
				fallback_cancels[fb_cancel] = nil
				if disposed or fb_cancel:is_cancelled() or fb_rev ~= revision then
					return
				end
				local current = snapshot()
				if
					usable()
					and current.id == state.id
					and current.generation == state.generation
					and not current.name
				then
					local ok, err = fallback(messages, current)
					if not ok and err ~= "empty session title" then
						mare.log("warn", tostring(err))
					end
				end
			end)
		end
		if needs_provider and (auto == "all-prompts" or #messages == 1) then
			scheduled = {
				id = state.id,
				generation = state.generation,
				revision = revision,
				messages = messages,
				fallback = fallback_task,
			}
		end
	end)
	-- request/build is a waterfall: a native listener receives `(req, ev)` and passes on with `ev.next(req)`
	ctx:on("request/build", function(req, ev)
		last_model = req.model
		local next_work = scheduled
		if next_work then
			scheduled = nil
			ctx:after(0, function()
				if next_work.fallback then
					pcall(next_work.fallback.wait, next_work.fallback)
				end
				local state = snapshot()
				if
					usable()
					and next_work.revision == revision
					and state.id == next_work.id
					and state.generation == next_work.generation
				then
					launch(next_work.messages, req.model, false)
				end
			end)
		end
		return ev.next(req)
	end)
	ctx:on("session/named", function(ev)
		if in_flight_commit then
			local cur = ctx.session:info()
			local same_owner = cur
				and cur.session_id == in_flight_commit.id
				and cur.session_epoch == in_flight_commit.generation
			local same_name = type(ev) ~= "table" or ev.name == nil or ev.name == in_flight_commit.name
			if same_owner and same_name then
				in_flight_commit = nil
				return
			end
		end
		recorded_meta = nil
		cancel()
		emit("user")
	end)
	ctx:on("session/changed", function()
		recorded_meta = nil
		cancel()
		last_model = nil
	end)
	ctx:on("session/loaded", function()
		recorded_meta = nil
		cancel()
		last_model = nil
	end)
	ctx:effect(function()
		return function()
			disposed = true
			cancel()
		end
	end)
	ctx.commands:register("title", {
		description = "Show, refresh, cancel or rename the session title",
		args = "[refresh|cancel|rename TEXT]",
		availability = { "session", "main" },
		run = function(args)
			local ok, err
			if args == "refresh" then
				local call_ok, call_res, call_err = pcall(service.refresh)
				if not call_ok then
					ok, err = false, type(call_res) == "table" and call_res.message or tostring(call_res)
				elseif call_res == nil and call_err ~= nil then
					ok, err = false, tostring(call_err)
				else
					ok = true
				end
			elseif args == "cancel" then
				ok = service.cancel()
			elseif args:match("^rename%s+") then
				ok, err = pcall(service.rename, nil, nil, args:match("^rename%s+(.+)$"))
			elseif args == "" then
				mare.ui.notify(snapshot().name or "No session title", "info")
				return
			else
				err = "Usage: /title [refresh|cancel|rename TEXT]"
			end
			if not ok then
				mare.ui.notify(tostring(err), "warning")
			end
		end,
	})
end
