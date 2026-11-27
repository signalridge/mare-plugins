return {
	name = "secrets-publication-probe",
	inject = { "secrets", "llm", "agent", "session", "commands", "policy" },
	apply = function(ctx)
		local secret = "FAKE_publication_secret_7ab3"
		local image = assert(mare.env("PUB_IMAGE"))
		local path = assert(mare.env("PUB_REPORT"))
		local mode = mare.env("PUB_MODE") or "headless"
		local queued, requests, ready, committed, events, structured = false, 0, 0, 0, 0, 0
		local late = "FAKE_publication_late_91d4"
		local late_lease, control, pending_cancel = nil, nil, nil
		local function safe(value)
			if type(value) == "string" then
				assert(not value:find(secret, 1, true), "raw publication secret escaped")
				if late_lease then
					assert(not value:find(late, 1, true), "late registration escaped publication")
				end
			elseif type(value) == "table" then
				for k, v in pairs(value) do
					safe(k)
					safe(v)
				end
			end
		end
		local function record(kind, value)
			safe(value)
			assert(mare.fs.write(path, mare.json.encode({ kind = kind, value = value }) .. "\n", { append = true }))
		end
		local function content(label)
			return mare.json.array({
				{ type = "text", text = label .. " " .. secret .. " " .. late },
				{ type = "file", path = "publication.txt", text = "file " .. secret },
				{ type = "image", data = image, mime = "image/png" },
			})
		end
		local function shape(entry)
			assert(
				#entry.content == 3
					and entry.content[1].type == "text"
					and entry.content[2].type == "file"
					and entry.content[3].type == "image"
			)
			assert(entry.content[2].path == "publication.txt" and entry.content[3].mime == "image/png")
		end
		local function switch_to_new_session()
			if type(ctx.session.switch) == "function" then
				ctx.session:switch({ kind = "new" })
			else
				ctx.session:create({})
			end
		end
		ctx.policy:voter("session/commit-ready", function(batch)
			if type(batch) ~= "table" or not batch.inbox then
				return nil
			end
			safe(batch)
			ready = ready + 1
			local row = batch.inbox.follow_up and batch.inbox.follow_up[1]
			if row and row.content then
				shape(row)
			end
			record("commit-ready", { batch = batch })
			if not late_lease then
				late_lease = mare.projection.register(late)
			end
			if control == "cancel" and pending_cancel then
				pending_cancel:cancel()
			end
			if control == "switch" then
				switch_to_new_session()
			end
			return { decision = "allow" }
		end, { prepend = true })
		ctx:on("queue/changed", function(event)
			safe(event)
			events = events + 1
			local has_queue_entry = false
			for _, entry in ipairs(ctx.session:entries()) do
				if entry.type == "custom" and entry.kind == "agent/queue" then
					has_queue_entry = true
					break
				end
			end
			assert(has_queue_entry, "queue/changed emitted without persisted queue entry")
			committed = committed + 1
			record("committed", { durable = true, queue = event })
			record("queue", event)
		end)
		ctx:on("turn/started", function(event)
			safe(event)
			record("start", event)
		end)
		ctx.llm:register_provider({
			provider = "pub-faux",
			models = { { model_id = "check", context_window = 100000, max_output = 4096, images = true } },
			is_configured = function()
				return true
			end,
			stream = function(req)
				safe({ req.system, req.messages, req.tools, req.params })
				requests = requests + 1
				if not queued and mode ~= "resume" then
					queued = true
					local q_res = ctx.agent:prompt(
						"",
						{ content = content("queued"), source = "publication", when_busy = "queue" }
					)
					assert(q_res.status == "queued", mare.json.encode(q_res))
					local snapshot = ctx.agent:list_queue()
					safe(snapshot)
					shape(snapshot.data[1])
					record("observation", snapshot)
					assert(ctx.agent:update_queued(snapshot.data[1].input_id, { input = "edited queued" }))
					record("queue-edit", ctx.agent:list_queue())
				end
				for _, msg in ipairs(req.messages) do
					if
						msg.role == "user"
						and type(msg.content) == "table"
						and #msg.content == 3
						and msg.content[2].type == "file"
						and msg.content[3].type == "image"
					then
						assert(msg.content[3].mime == "image/png")
						structured = structured + 1
					end
				end
				record("provider", { messages = req.messages })
				return {
					role = "assistant",
					content = { { type = "text", text = "publication done" } },
					stop_reason = "stop",
				}
			end,
		})
		local function check()
			local ok, result = pcall(function()
				return ctx.agent:prompt(string.char(255))
			end)
			assert(not (ctx.agent:get() or {}).busy, "invalid input left the prompt claim busy")
			assert(not ok or result.error, "invalid UTF8 unexpectedly accepted")
			record("settled", { busy = false })
			local before = committed
			for _, action in ipairs({ "cancel", "switch" }) do
				local info = ctx.session:info()
				pending_cancel = action == "cancel" and mare.task.token() or nil
				control = action == "cancel" and "cancel" or nil
				if action == "switch" then
					switch_to_new_session()
				end
				local ok_q, err_q = pcall(ctx.agent.prompt, ctx.agent, "", {
					content = content("rejected"),
					queue_only = true,
					expected_session = { session_id = info.session_id, session_epoch = info.session_epoch },
					source = "publication",
					cancel = pending_cancel,
				})
				control = nil
				pending_cancel = nil
				assert(not ok_q and committed == before and #ctx.agent:list_queue().data == 0)
				if action == "cancel" then
					assert(late_lease ~= nil, "cancel probe did not reach session/commit-ready: " .. tostring(err_q))
				end
				if action == "switch" then
					assert(ctx.session:info().session_id ~= info.session_id)
				end
				record("rejected", { action = action, committed = committed })
			end
			local answer = ctx.agent:prompt("", { content = content("source"), source = "publication" })
			safe(answer)
			assert(not answer.error)
			if answer.turn_id then
				local settled = ctx.agent:wait(answer.turn_id)
				safe(settled)
				assert(settled and not settled.error, mare.json.encode(settled))
			end
		end
		ctx.commands:register(
			"pub-check",
			{ availability = "idle", description = "Run synthetic publication checks", run = check }
		)
		ctx:on("app/ready", function()
			if mode ~= "rpc" then
				ctx.secrets:register("PUB", secret)
				if mode ~= "resume" then
					check()
				end
			end
		end)
		ctx:on("app/shutdown", function()
			safe(ctx.session:entries())
			record("summary", {
				session_id = ctx.session:info().session_id,
				requests = requests,
				ready = ready,
				committed = committed,
				events = events,
				structured = structured,
				entries = ctx.session:entries(),
			})
		end)
	end,
}
