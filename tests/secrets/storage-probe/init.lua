return {
	name = "secrets-storage-probe",
	inject = { "secrets", "llm", "tools", "agent", "session", "commands", "policy" },
	apply = function(ctx)
		local first, second = "FAKE_stored_secret_1a92", "FAKE_rotated_secret_82ab"
		local mode = mare.env("STORE_MODE") or "rpc"
		local report = assert(mare.env("STORE_REPORT"))
		local work = assert(mare.env("STORE_OUTPUT"))
		local sent, executions, child_checked = false, 0, false
		local function safe(value)
			local encoded = mare.json.encode(value)
			assert(not encoded:find(first, 1, true) and not encoded:find(second, 1, true), "stored value published")
		end
		local function record(kind, data)
			safe(data)
			assert(mare.fs.write(report, mare.json.encode({ kind = kind, data = data }) .. "\n", { append = true }))
		end
		ctx:on("turn/started", function()
			sent = false
		end)
		ctx.tools:register("stored_echo", {
			description = "Synthetic stored value execution",
			sensitive_inputs = { "value" },
			side_effect = "write",
			idempotent = true,
			parameters = { type = "object", properties = { value = { type = "string" } }, required = { "value" } },
			execute = function(args)
				assert(args.value == first or args.value == second)
				executions = executions + 1
				assert(mare.fs.write(work, (args.value == first and "first" or "second") .. "\n", { append = true }))
				return { content = args.value }
			end,
		})
		ctx.llm:register_provider({
			provider = "stored-faux",
			models = { { model_id = "m", context_window = 100000, max_output = 4096 } },
			is_configured = function()
				return true
			end,
			stream = function(req)
				safe({ req.system, req.messages, req.tools, req.params })
				safe(ctx.agent:activity())
				local refs = ctx.secrets:list()
				if #refs > 0 then
					assert(
						((req.system or "") .. mare.json.encode(req.messages)):find(refs[1].reference, 1, true),
						"loaded reference missing from actual model context"
					)
				end
				if mare.mode == "child" then
					assert(#refs == 1, "child named load lost its local registration")
					local stored = ctx.secrets:stored()
					assert(#stored == 2, "child metadata enumeration missed persisted names")
				end
				if mare.mode ~= "child" and #refs > 0 and not sent then
					sent = true
					return {
						role = "assistant",
						content = {
							{
								type = "tool_call",
								id = "stored-call",
								name = "stored_echo",
								arguments = {
									value = refs[1].reference,
								},
							},
						},
						stop_reason = "tool_use",
					}
				end
				return {
					role = "assistant",
					content = { { type = "text", text = "storage done" } },
					stop_reason = "stop",
				}
			end,
		})
		local function check(kind)
			local described = ctx.secrets:describe("STORE")
			safe(described)
			if kind == "absent" then
				assert(not described.configured and described.masked == nil and #ctx.secrets:list() == 0)
			elseif kind == "loaded" then
				assert(
					described.configured
						and described.masked == "FAKE_store•••••••••1a92"
						and #ctx.secrets:list() == 1
				)
				assert(ctx.secrets:list()[1].reference:find("[[mare-value:", 1, true) == 1)
			elseif kind == "stored-one" then
				local names = ctx.secrets:stored()
				safe(names)
				assert(
					#names == 1
						and names[1].name == "STORE"
						and names[1].configured
						and names[1].masked == "FAKE_store•••••••••1a92"
						and #ctx.secrets:list() == 0
				)
			elseif kind == "stored" then
				ctx.secrets:save("OTHER", second)
				local names = ctx.secrets:stored()
				safe(names)
				assert(
					#names == 2
						and names[1].name == "OTHER"
						and names[1].masked == "FAKE_rotat••••••••••82ab"
						and names[2].name == "STORE"
						and names[2].masked == "FAKE_rotat••••••••••82ab"
				)
			elseif kind == "mask-vectors" then
				local vectors = {
					{ "plain", "•••••" },
					{ "1234567890123456", string.rep("•", 16) },
					{ "12345678901234567", "12345••••••••4567" },
					{ "sk-1234567890123456", string.rep("•", 19) },
					{ "sk-12345678901234567", "sk-12345••••••••4567" },
					{ "vendor_1234567890abcdef", string.rep("•", 23) },
					{ "vendor_1234567890abcdefg", "vendor_12345••••••••defg" },
					{ "sk-proj-1234567890abcdef", "sk-proj-••••••••••••cdef" },
					{ "abc-def_123456789012", string.rep("•", 20) },
					{ "1234567890123456-", string.rep("•", 17) },
					{ string.rep("😀", 16), string.rep("•", 16) },
					{ string.rep("😀", 17), string.rep("😀", 5) .. string.rep("•", 8) .. string.rep("😀", 4) },
					{ "sk-" .. string.rep("😀", 16), string.rep("•", 19) },
					{
						"sk-" .. string.rep("😀", 17),
						"sk-" .. string.rep("😀", 5) .. string.rep("•", 8) .. string.rep("😀", 4),
					},
				}
				for _, pair in ipairs(vectors) do
					local saved = ctx.secrets:save("MASK_TEST", pair[1])
					assert(saved.masked == pair[2], "unexpected mask for vector: " .. tostring(saved.masked))
					assert(ctx.secrets:describe("MASK_TEST").masked == pair[2])
				end
				ctx.secrets:delete("MASK_TEST")
			elseif kind == "no-stored" then
				assert(#ctx.secrets:stored() == 0)
			elseif kind == "invalid" then
				local before = ctx.secrets:list()[1].reference
				assert(not pcall(ctx.secrets.save, ctx.secrets, "STORE", ""))
				assert(not pcall(ctx.secrets.save, ctx.secrets, "STORE", string.char(255)))
				assert(ctx.secrets:list()[1].reference == before and ctx.secrets:describe("STORE").configured)
			elseif kind == "blank" then
				ctx.llm:auth_set("mare-plugin/secrets/STORE", { version = 1, kind = "explicit-secret", value = "" })
				local ok_load, load_err = pcall(ctx.secrets.load, ctx.secrets, "STORE")
				assert(
					not ok_load and load_err and load_err.code == "secrets.not_configured" and #ctx.secrets:list() == 0
				)
				assert(not ctx.secrets:describe("STORE").configured)
			elseif kind == "malformed" then
				ctx.llm:auth_set("mare-plugin/secrets/STORE", { version = 99, kind = "explicit-secret", value = first })
				assert(not pcall(ctx.secrets.load, ctx.secrets, "STORE") and #ctx.secrets:list() == 0)
			elseif kind == "child" then
				local child = mare.subagent.start({ prompt = "explicit named child load", model = "stored-faux/m" })
				local result = child:wait()
				safe(result)
				assert(not result.error and result.text == "storage done")
				child_checked = true
			end
			record(kind, {
				described = described,
				refs = ctx.secrets:list(),
				executions = executions,
				child_checked = child_checked,
			})
		end
		ctx.commands:register("storage-check", { availability = "idle", run = check })
		ctx:on("app/ready", function()
			ctx.llm:set_model("stored-faux/m")
		end)
		ctx:on("turn/started", function()
			if mare.mode == "child" or mode == "headless" then
				local resolved = assert(ctx.secrets:resolve("STORE"))
				assert(resolved.reference:find("[[mare-value:", 1, true) == 1 and resolved.source == "auth")
				check("loaded")
			end
		end)
		if mode == "headless" then
			ctx.policy:voter("tool/approval", function()
				return { decision = "allow", grant = "allow_session", source = "user" }
			end, { prepend = true })
		end
		ctx:on("app/shutdown", function()
			safe(ctx.session:entries())
			record("summary", {
				executions = executions,
				child_checked = child_checked,
				configured = ctx.secrets:describe("STORE").configured,
			})
		end)
	end,
}
