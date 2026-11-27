return {
	name = "secrets-probe",
	inject = { "secrets", "llm", "tools", "session", "commands", "agent", "policy" },
	apply = function(ctx)
		local secret = mare.env("SECRETS_VALUE") or "FAKE_registered_secret_83ef"
		local mode = mare.env("SECRETS_MODE") or "allow"
		if mare.mode == "child" then
			mode = "child-no-secrets"
		end
		local unregistered = mode == "resume" or mode == "child-no-secrets"
		local capture = assert(mare.env("SECRETS_CAPTURE"))
		local reference, executions, approvals, chunks, requests = nil, 0, 0, 0, 0
		local progress = 0
		local tool_sent = false
		ctx:on("session/changed", function()
			tool_sent = false
		end)
		local function record(kind, data)
			assert(mare.fs.write(capture, mare.json.encode({ kind = kind, data = data }) .. "\n", { append = true }))
		end
		local function safe(data)
			if type(data) == "string" then
				assert(not data:find(secret, 1, true), "registered value escaped boundary")
			elseif type(data) == "table" then
				for key, value in pairs(data) do
					safe(key)
					safe(value)
				end
			end
		end

		ctx.tools:register("secret_echo", {
			sensitive_inputs = { "value" },
			description = "Synthetic tool " .. (unregistered and "resumed" or secret),
			parameters = {
				type = "object",
				properties = {
					value = { type = "string", enum = unregistered and { "unavailable" } or { secret } },
				},
				required = { "value" },
				additionalProperties = false,
			},
			side_effect = "external",
			idempotent = true,
			execute = function(args, tctx)
				assert(args.value == secret, "execution did not restore exact value")
				executions = executions + 1
				if mode == "progress" or mode == "rpc" or mode == "tui-progress" then
					for cut = 1, #secret - 1 do
						tctx.update({ output = secret:sub(cut + 1) .. string.rep(".", #secret * 4) })
					end
					tctx.update({ output = secret:sub(2) .. "VISIBLE-PROGRESS" .. string.rep(".", #secret * 4) })
					if mode == "tui-progress" then
						-- barrier for the TUI driver: the tool is now holding. The abort pass holds
						-- until cancelled (60 s cap); the success pass returns at once
						record("tool-hold", {})
						local hold = mare.env("SECRETS_TUI_ABORT") == "1" and 60000 or 0
						if hold > 0 and not mare.task.sleep(hold, tctx.cancel) then
							record("tool-cancelled", {})
							return { content = "cancelled", is_error = true, cancelled = true }
						end
					end
				end

				if mode:match("^attack%-") and mare.os ~= "windows" then
					local output = mare.proc.run({ cmd = "printf", args = { "%s", args.value }, cancel = tctx.cancel })
					assert(output.code == 0 and output.stdout == secret)
					assert(not mare.fs.exists(mare.cwd .. "/INJECTED"))
				end

				if mode == "late-revoke" then
					ctx.secrets:remove("TEST")
				end
				if mode == "running-cancel" then
					tctx.cancel:cancel()
				end
				if tctx.update then
					tctx.update({ content = secret:sub(1, 13) })
					tctx.update({ content = secret:sub(14) })
				end
				if mode == "error" then
					error("synthetic failure " .. secret)
				end
				return {
					content = "tool echoed " .. secret,
					details = { value = secret },
					conclude_turn = mode == "conclude" or nil,
				}
			end,
		})
		if mode ~= "rpc" and mode ~= "tui-progress" then
			ctx.policy:voter("tool/approval", function(call, _, _, cancel)
				if call.name ~= "secret_echo" and not (mode:match("^file%-write") and call.name == "write") then
					return { decision = "deny" }
				end
				approvals = approvals + 1
				safe(call)
				assert(call.protected_arguments and call.projection_version == mare.projection.revision())
				record("approval", call)
				if mode == "deny" then
					return { decision = "deny", reason = "synthetic denial" }
				end
				if mode == "cancel" then
					assert(cancel)
					cancel:cancel()
				end
				if mode == "revoke" then
					ctx.secrets:remove("TEST")
				end
				if mode == "churn" then
					local lease = mare.projection.register("FAKE_churn_value_" .. approvals)
					-- close immediately: both registration and revocation invalidate this approval.
					lease:close()
				end
				-- Session grants must be normalized to once by the core, and protected_arguments require source = "user".
				return { decision = "allow", grant = "allow_session", source = mode ~= "policy-allow" and "user" or nil }
			end)
		end
		for _, event in ipairs({
			"item/started",
			"item/completed",
			"approval/requested",
			"approval/resolved",
			"turn/started",
			"queue/changed",
			"agent/settled",
		}) do
			ctx:on(event, function(data)
				safe(data)
				record(event, data)
				if event == "approval/resolved" and data.result and data.result.decision == "allow" then
					if mode == "post-approval-revoke" then
						ctx.secrets:remove("TEST")
					end
					if mode == "post-approval-churn" then
						local lease = mare.projection.register("FAKE_post_approval_" .. approvals)
						lease:close()
					end
				end
				if
					event == "item/started"
					and data
					and data.item
					and data.item.type == "tool_call"
					and data.item.status == "running"
				then
					if mode == "started-revoke" then
						ctx.secrets:remove("TEST")
					end
					if mode == "started-cancel" then
						ctx.agent:cancel()
					end
				end
			end)
		end
		ctx:on("item/delta", function(ev)
			safe(ev)
			if ev and ev.kind == "tool_output" then
				assert(
					mode == "progress" or mode == "rpc" or mode == "tui-progress",
					"unsupported partial shape escaped"
				)
				progress = progress + 1
				local text = assert(ev.partial and ev.partial.output)
				if progress < #secret then
					assert(text:match("^%.+$"), "secret suffix leaked from tail snapshot")
				else
					assert(text:find("VISIBLE-PROGRESS", 1, true), "safe live progress disappeared")
				end
				record("progress", ev)
			else
				chunks = chunks + 1
			end
		end)
		ctx:on("request/build", function(req, ev)
			local copy = table.copy(req)
			copy.system = (req.system or "") .. "\nSynthetic system " .. (unregistered and "resumed" or secret)
			return ev.next(copy)
		end)
		ctx.llm:register_provider({
			provider = mode == "tui-progress" and "faux" or "secrets-faux",
			replace = mode == "tui-progress" or nil,
			default_model = "echo",
			models = {
				{ model_id = "echo", context_window = 100000, max_output = 4096, remote_compact = true },
				{ model_id = "fallback", context_window = 100000, max_output = 4096 },
			},
			is_configured = function()
				return true
			end,
			compact = function(req)
				safe({ req.system, req.messages, req.tools, req.params })
				record("compact", { system = req.system, messages = req.messages })
				return { items = { { type = "text", text = secret } }, usage = { input = 1, output = 1 } }
			end,
			stream = function(req, sink)
				safe({ req.system, req.messages, req.tools, req.params })
				if req.purpose == "btw" then
					assert(
						req.system == reference
							and req.tools[1].description == reference
							and req.params.custom == reference
					)
					assert(req.messages[#req.messages].content[1].text == reference)
				end

				record("request", {
					system = req.system,
					messages = req.messages,
					tools = req.tools,
					params = req.params,
					purpose = req.purpose,
					model = req.model.ref,
				})
				if req.purpose == "agent" then
					requests = requests + 1
				end
				if req.purpose == "agent" and mode == "provider-error" then
					if sink then
						sink({ type = "text_delta", id = "err", delta = secret:sub(1, 13) })
						sink({ type = "text_delta", id = "err", delta = secret:sub(14) })
					end
					error("synthetic provider failure " .. secret)
				end
				if req.purpose == "agent" and mode == "retry" and requests == 1 then
					error({ message = "synthetic retry " .. secret, kind = "server", retryable = true })
				end
				if req.purpose == "agent" and not tool_sent then
					if mode == "fallback" and req.model.id == "echo" then
						error({ message = "unknown model", kind = "model_not_found", retryable = false })
					end
					tool_sent = true
					local refs = (mare.json.encode(req.messages) .. (req.system or "")):match(
						"(%[%[mare%-value:[%w%-]+%]%])"
					)
					assert(refs, "provider did not receive a hidden value reference")
					local content = {
						{
							type = "tool_call",
							id = "secret-tool-1",
							name = mode:match("^file%-write") and "write" or "secret_echo",
							arguments = mode:match("^file%-write")
									and { path = "registered-value.txt", content = refs }
								or { value = mode == "bad-enum" and "not-in-enum" or refs },
						},
					}
					return { role = "assistant", content = content, stop_reason = "tool_use" }
				end
				if req.purpose == "btw-error" or req.purpose == "btw-abort" then
					if sink then
						sink({ type = "text_delta", id = "cut", delta = secret:sub(1, 13) })
					end
					if req.purpose == "btw-error" then
						error("synthetic cut side stream")
					end
					req.cancel:cancel()
					return {
						role = "assistant",
						content = { { type = "text", text = secret:sub(1, 13) } },
						stop_reason = "aborted",
					}
				end
				local output = unregistered and "resumed" or secret
				if sink then
					if req.purpose == "btw" then
						sink({ type = "reasoning_delta", id = "think", delta = output:sub(1, 13) })
						sink({ type = "text_delta", id = "t2", delta = output:sub(1, 13) })
					end
					sink({ type = "text_delta", id = "t", delta = output:sub(1, 13) })
					if req.purpose == "btw" then
						sink({ type = "reasoning_delta", id = "think", delta = output:sub(14) })
						sink({ type = "text_delta", id = "t2", delta = output:sub(14) })
					end
					sink({ type = "text_delta", id = "t", delta = output:sub(14) })
				end
				return {
					role = "assistant",
					content = { { type = "text", text = "model echoed " .. output } },
					stop_reason = "stop",
				}
			end,
		})
		ctx:on("app/ready", function()
			local schema = {
				type = "object",
				properties = {
					opaque = { ["x-mare-secret"] = true },
					absent = { ["x-mare-secret"] = true },
					rows = { type = "array", items = { ["x-mare-secret"] = true } },
				},
			}
			local input = {
				opaque = "FAKE_schema_only_value",
				public = { token = "keep-public" },
				rows = mare.json.array({ "FAKE_schema_array_value", mare.json.null }),
			}
			local stripped = mare.schema.redact(schema, input)
			assert(input.opaque == "FAKE_schema_only_value" and stripped.value.opaque == nil)
			assert(stripped.value.public.token == "keep-public")
			assert(mare.json.is_array(stripped.value.rows) and stripped.value.rows[1] == mare.json.null)
			local found = {}
			for _, slot in ipairs(stripped.secrets) do
				found[table.concat(slot.path, "/")] = slot.set
			end
			assert(
				found.opaque == true and found.absent == false and found["rows/0"] == true and found["rows/1"] == true
			)
			assert(not pcall(mare.schema.redact, { ["$ref"] = "unsupported" }, input))
			record("schema-redaction", stripped)

			if mode == "rpc" or mode == "tui-progress" then
				return
			end
			if unregistered then
				assert(#ctx.secrets:list() == 0)
				return
			end
			reference = ctx.secrets:register("TEST", secret)
			if mode == "child-boundary" then
				local child = mare.subagent.start({
					prompt = "Use old parent reference " .. reference,
					model = "secrets-faux/echo",
					tools = { "secret_echo" },
				})

				local result = child:wait()
				safe(result)
				assert(
					mare.json.encode(result):find("PROJECTION_UNKNOWN", 1, true),
					"child accepted parent reference or did not exercise guarded execution"
				)
				record("child-boundary", { refused = true })
			end

			-- public projection stream, current contract (mare.projection.stream() from the start of a
			-- stream): a registered value split across chunks never reaches the public output, and an
			-- incomplete potential match stays private when the stream is closed
			local window = mare.projection.stream()
			local third = math.max(1, #secret // 3)
			local published = window:push("pre ")
				.. window:push(secret:sub(1, third))
				.. window:push(secret:sub(third + 1, 2 * third))
				.. window:push(secret:sub(2 * third + 1) .. " post")
				.. window:finish()
			assert(
				not published:find(secret, 1, true) and published:find("^pre ") and published:find(" post$"),
				"projection stream published a registered value (length " .. #published .. ")"
			)
			local partial = mare.projection.stream()
			local head = partial:push("pre " .. secret:sub(1, third))
			partial:close()
			assert(
				("pre "):sub(1, #head) == head, -- the safe prefix may be shorter (even empty), never more
				"projection stream published an incomplete potential match (published "
					.. #head
					.. " bytes, contains the fragment: "
					.. tostring(head:find(secret:sub(1, third), 1, true) ~= nil)
					.. ", fragment "
					.. third
					.. " of "
					.. #secret
					.. " bytes)"
			)
			local exposed = ctx.tools:get("secret_echo")
			exposed.sensitive_inputs[1] = "not-value"
			assert(ctx.tools:get("secret_echo").sensitive_inputs[1] == "value")
			if mode == "file-write-newline" then
				assert(mare.fs.write(mare.cwd .. "/registered-value.txt", "before\n"))
				ctx.tools:observe(mare.cwd .. "/registered-value.txt")
			end

			if mode == "lua-call" then
				assert(mare.args.no_session)
				local result, frozen = ctx.tools:execute(
					{ id = "lua-service-call", name = "secret_echo", arguments = { value = reference } },
					{ cancel = mare.task.token() }
				)
				safe(result)
				safe(frozen)
				-- A protected-argument call needs a native human approval receipt, which
				-- headless cannot give; exactly that denial is recorded (the driver reports the skip)
				local denied = result.is_error
					and mare.json.encode(result.content):find("nobody can answer in this mode", 1, true)
				if denied then
					record("lua-call", { unapproved = true })
				else
					assert(not result.is_error, mare.json.encode(result.content))
				end
			end

			if mode:match("^attack%-") then
				for _, command in ipairs({
					"printf '%s' " .. reference,
					"printf '%s' '" .. reference .. "'",
					'printf "%s" "' .. reference .. '"',
				}) do
					local denied = ctx.tools:execute(
						{ id = "hidden-shell", name = "bash", arguments = { command = command } },
						{
							on_state = function()
								return true
							end,
							approve = function()
								error("hidden shell input reached approval")
							end,
						}
					)
					assert(
						denied.is_error and denied.content:find("Hidden values are not supported", 1, true),
						mare.json.encode(denied)
					)
				end
				assert(not mare.fs.exists(mare.cwd .. "/INJECTED"))
			end

			assert(not pcall(mare.projection.restore, reference, mare.projection.revision()))
			ctx.commands:run("/secrets list")
			ctx.commands:run("/secrets add NO_UI") -- headless must not read an unmasked stdin value
			assert(#ctx.secrets:list() == 1)
			local auxiliary = ctx.llm:complete({
				purpose = "auxiliary",
				system = secret,
				messages = { { role = "user", content = { { type = "text", text = secret } } } },
				params = { custom = secret },
			})
			safe(auxiliary)

			local prefix = {
				system = secret,
				tools = {
					{
						name = "side_probe",
						description = secret,
						parameters = { type = "object", properties = { q = { type = "string", description = secret } } },
					},
				},
				params = { custom = secret },
			}
			local side_messages = { { role = "user", content = { { type = "text", text = secret } } } }
			local side_chunks = 0
			local side_by_id = {}
			for _ = 1, 2 do
				local request = table.copy(prefix)
				request.messages = side_messages
				request.purpose = "btw"
				local answer = ctx.llm:stream(request, function(event)
					safe(event)
					local key = event.type .. ":" .. tostring(event.id)
					side_by_id[key] = (side_by_id[key] or "") .. (event.delta or "")
					if event.type == "text_delta" then
						side_chunks = side_chunks + 1
					end
				end)
				safe(answer)
				assert(
					prefix.system == secret
						and prefix.tools[1].description == secret
						and side_messages[1].content[1].text == secret
				)
				table.insert(side_messages, answer)
				table.insert(side_messages, { role = "user", content = { { type = "text", text = secret } } })
			end
			assert(side_chunks > 0, "registered values disabled direct side streaming")
			for _, key in ipairs({ "text_delta:t", "text_delta:t2", "reasoning_delta:think" }) do
				assert(side_by_id[key] == reference .. reference, "stream channel mixed or exposed fragments: " .. key)
			end
			for _, purpose in ipairs({ "btw-error", "btw-abort" }) do
				local request = table.copy(prefix)
				request.messages = { { role = "user", content = { { type = "text", text = secret } } } }
				request.purpose = purpose
				local answer = ctx.llm:stream(request, function()
					error("incomplete sensitive tail escaped side stream")
				end)
				assert(#answer.content == 0 and not mare.json.encode(answer):find(secret:sub(1, 13), 1, true))
			end

			record("side-stream", { chunks = side_chunks })

			local direct_usage = 0
			ctx:on("llm/usage", function(ev)
				if ev.provider_id == "secrets-direct" then
					direct_usage = direct_usage + 1
				end
			end)
			local function direct_definition(replace_during_stream, replace_existing)
				return {
					provider = "secrets-direct",
					replace = replace_existing or nil,
					models = { { model_id = "probe", context_window = 100000, max_output = 4096 } },
					is_configured = function()
						return true
					end,
					stream = function(req, sink)
						safe({ req.system, req.messages, req.tools, req.params })
						assert(
							ctx.llm:side_requests_pending(ctx.session:info().session_id),
							"direct provider bypassed auxiliary ownership"
						)
						if replace_during_stream then
							ctx.llm:register_provider(direct_definition(false, true))
							assert(req.cancel:is_cancelled(), "provider replacement did not cancel its request")
						end
						if sink then
							sink({ type = "text_delta", id = "direct", delta = secret:sub(1, 13) })
							sink({ type = "text_delta", id = "direct", delta = secret:sub(14) })
						end
						return {
							role = "assistant",
							content = { { type = "text", text = secret } },
							stop_reason = "stop",
							usage = { input = 1, output = 1 },
						}
					end,
					compact = function(req)
						safe({ req.system, req.messages, req.tools, req.params })
						assert(ctx.llm:side_requests_pending(ctx.session:info().session_id))
						return { items = { { type = "text", text = secret } }, usage = { input = 1, output = 1 } }
					end,
				}
			end
			local direct_def = direct_definition(false, false)
			ctx.llm:register_provider(direct_def)
			local direct = assert(ctx.llm:provider("secrets-direct"))
			assert(
				not rawequal(direct.stream, direct_def.stream),
				"llm:provider returned raw provider table instead of projecting accessor"
			)
			local raw_request = table.copy(prefix)
			raw_request.model = direct.models[1]
			raw_request.messages = side_messages
			raw_request.purpose = "accessor"
			local direct_text = {}
			local reply = direct.stream(raw_request, function(ev)
				safe(ev)
				if ev.type == "text_delta" then
					direct_text[#direct_text + 1] = ev.delta
				end
			end)
			assert(reply.content[1].text == reference and table.concat(direct_text) == reference)
			assert(direct.compact(raw_request).items[1].text == reference)
			assert(direct_usage == 2, "direct provider usage missing or duplicated")
			local listed = assert(ctx.llm:provider("secrets-direct"))
			assert(listed.stream == direct.stream)
			local original = listed.stream
			listed.stream = function(req, sink)
				return original(req, sink)
			end
			assert(ctx.llm:provider("secrets-direct").stream ~= original)
			local delegated = {}
			local wrapped_reply = listed.stream(raw_request, function(ev)
				safe(ev)
				if ev.type == "text_delta" then
					delegated[#delegated + 1] = ev.delta
				end
			end)
			assert(wrapped_reply.content[1].text == reference and table.concat(delegated) == reference)
			assert(direct_usage == 3, "transparent provider delegate duplicated usage scope")
			ctx.llm:register_provider(direct_definition(true, true))
			assert(not pcall(direct.stream, raw_request), "old provider generation still callable")
			local replacement = assert(ctx.llm:provider("secrets-direct"))
			local caller_cancel = mare.task.token()
			raw_request.cancel = caller_cancel
			raw_request.purpose = "agent"
			assert(not pcall(replacement.stream, raw_request), "withdrawn in-flight provider returned a response")
			assert(not caller_cancel:is_cancelled(), "provider cancellation escaped its own request")
			assert(not ctx.llm:side_requests_pending(ctx.session:info().session_id))
			record(
				"provider-accessor",
				{ usage = direct_usage, stream = true, compact = true, old_generation_refused = true }
			)
			local compact = assert(ctx.llm:compact_remote({
				system = secret,
				messages = { { role = "user", content = { { type = "text", text = secret } } } },
			}))
			safe(compact)
		end)
		ctx:on("app/shutdown", function()
			safe(ctx.session:entries())
			record("summary", {
				executions = executions,
				progress = progress,
				approvals = approvals,
				chunks = chunks,
				requests = requests,
				entries = ctx.session:entries(),
				registrations = #ctx.secrets:list(),
			})
		end)
	end,
}
