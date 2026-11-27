local Profile = require("mermaid.profile")
local Png = require("mermaid.png")
local Queue = require("mermaid.queue")
local Viewer = require("mermaid.viewer")
local adapter = require("mermaid.adapter")

return function(ctx, cfg)
	local metadata_order = {}
	local metadata = {}
	local automatic_enabled = cfg.automatic
	local presenter_removers = {}
	local disposed = false
	local queue = Queue.new({ max_concurrent = 2, max_waiters = 16 })
	local viewer

	local function info()
		return ctx.session:info()
	end

	local function same(owner, cancel)
		local current = info()
		return not disposed
			and not (cancel and cancel:is_cancelled())
			and current.session_id == owner.session_id
			and current.session_epoch == owner.session_epoch
	end

	local function writable(owner, cancel)
		local current = info()
		return same(owner, cancel) and not current.readonly and not current.unstable and not ctx.session:switching()
	end

	local function record(kind, data, owner, cancel)
		if not same(owner, cancel) then
			return nil, "session changed or cancelled"
		end
		local opts = { persist = not owner.ephemeral, sync = not owner.ephemeral }
		if not owner.ephemeral then
			opts.session_id, opts.session_epoch = owner.session_id, owner.session_epoch
		end
		local ok, saved, err = pcall(ctx.session.add_record, ctx.session, kind, data, opts)
		if not ok or not saved or not same(owner, cancel) then
			local detail = not ok and (require("mare_lib").error_message(saved) or saved)
				or (not saved and (require("mare_lib").error_message(err) or err))
			return nil, detail or "session changed after write"
		end
		return true
	end

	local function remember(artifact)
		Profile.lru_set(metadata_order, metadata, artifact.key, artifact, 64)
	end

	local function source_text(source, reason, is_error)
		return {
			content = reason .. "\n\nMermaid source:\n    " .. source:gsub("\n", "\n    "),
			is_error = is_error or nil,
		}
	end

	local function available(artifact, owner, cancel)
		if
			not artifact
			or artifact.session_id ~= owner.session_id
			or type(artifact.spill_id) ~= "string"
			or not same(owner, cancel)
		then
			return nil
		end
		return artifact
	end

	local function find(key, owner, cancel)
		local artifact = metadata[key]
		if available(artifact, owner, cancel) then
			return artifact
		end
		if not owner.ephemeral then
			local ok, entries = pcall(
				require("mare_lib").all_records,
				ctx.session,
				"mermaid/artifact",
				{ session_id = owner.session_id, session_epoch = owner.session_epoch }
			)
			if ok and type(entries) == "table" then
				for index = #entries, 1, -1 do
					local entry = entries[index]
					if entry.version == 1 and entry.key == key and available(entry, owner, cancel) then
						remember(entry)
						return entry
					end
				end
			end
		end
	end

	local function render_to_artifact(args, tool)
		local owner = info()
		if args.session_id or args.generation then
			if args.session_id ~= owner.session_id or args.generation ~= owner.session_epoch then
				return source_text(args.source, "Mermaid source shown: stale source owner.", true)
			end
		end
		local images = mare.ui.caps().images
		if
			args.format == "source"
			or (args.format ~= "png" and (not mare.ui.connected() or images == nil or images == "none"))
		then
			return source_text(args.source, "Mermaid source shown: images unavailable.")
		end
		local est = Profile.estimate_diagram_size(args.source)
		if est.nodes > cfg.max_nodes or est.edges > cfg.max_edges then
			return source_text(
				args.source,
				string.format(
					"Mermaid source shown: diagram exceeds complexity limit (%d/%d nodes, %d/%d edges).",
					est.nodes,
					cfg.max_nodes,
					est.edges,
					cfg.max_edges
				),
				true
			)
		end
		if not writable(owner, tool.cancel) then
			return source_text(args.source, "Mermaid source shown: session is not writable/stable.", true)
		end
		local profile = Profile.validate(args.profile or Profile.new(cfg, {
			source = args.source,
			zoom_percent = viewer:zoom_percent(),
		}))
		local key = Profile.key(cfg, args.source, profile)
		local run = mare.proc.run({
			cmd = cfg.node,
			args = {
				"--max-old-space-size=" .. tostring(cfg.max_heap_mb),
				"--input-type=commonjs",
				"-e",
				adapter,
				"--",
				cfg.command,
				cfg.renderer_script,
			},
			input = mare.json.encode({
				source = args.source,
				profile = profile,
				timeout_ms = cfg.timeout_ms,
				max_heap_mb = cfg.max_heap_mb,
				max_edges = cfg.max_edges,
			}),
			timeout_ms = cfg.timeout_ms,
			cancel = tool.cancel,
			max_output = 12 * 1024 * 1024,
			sandbox = "current",
		})
		if not run or run.cancelled then
			return source_text(args.source, "Mermaid source shown: cancelled.", true)
		end
		if run.timed_out then
			return source_text(args.source, "Mermaid source shown: renderer timed out.", true)
		end
		if not run.success then
			local detail = run.stderr and #run.stderr > 0 and run.stderr or ("exit " .. tostring(run.code))
			return source_text(args.source, "Mermaid source shown: renderer failed: " .. detail, true)
		end
		local ok, decoded = pcall(mare.json.decode, run.stdout)
		if not ok or type(decoded) ~= "table" or type(decoded.png) ~= "string" then
			return source_text(args.source, "Mermaid render returned invalid JSON.", true)
		end
		local raw_ok, raw = pcall(mare.crypto.base64_decode, decoded.png)
		local valid, width, height = false, "invalid base64", nil
		if raw_ok then
			valid, width, height = pcall(Png.validate, raw)
		end
		if not valid then
			return source_text(args.source, "Mermaid render returned invalid PNG: " .. tostring(width), true)
		end
		if not writable(owner, tool.cancel) then
			return source_text(args.source, "Mermaid source shown: session changed before artifact write.", true)
		end
		if cfg.backend ~= "" and cfg.backend ~= "local" then
			return source_text(args.source, "Mermaid spill backend unavailable: " .. tostring(cfg.backend), true)
		end
		local artifact = mare.spill.save_bytes(owner.session_id, raw, {})
		if not artifact or type(artifact.spill_id) ~= "string" then
			return source_text(args.source, "Mermaid output artifact write failed.", true)
		end
		if not same(owner, tool.cancel) then
			pcall(mare.spill.delete, artifact.spill_id, { session_id = owner.session_id })
			return source_text(args.source, "Mermaid source shown: session changed after artifact write.", true)
		end
		local sha256 = mare.crypto.sha256(raw)
		local entry = {
			version = 1,
			key = key,
			spill_id = artifact.spill_id,
			sha256 = sha256,
			media_type = "image/png",
			bytes = artifact.size or #raw,
			backend = artifact.backend,
			session_id = owner.session_id,
			renderer = tostring(decoded.version or "unknown"),
			width = width,
			height = height,
		}
		local persisted, err = record("mermaid/artifact", entry, owner, tool.cancel)
		if not persisted then
			pcall(mare.spill.delete, artifact.spill_id, { session_id = owner.session_id })
			return source_text(args.source, "Mermaid artifact persistence failed: " .. tostring(err), true)
		end
		remember(entry)
		viewer:record_active("tool:" .. key, {
			key = "tool:" .. key,
			source = args.source,
			phase = "tool",
			artifact = entry,
			profile = profile,
		})
		return {
			content = string.format(
				"Rendered Mermaid diagram (%dx%d PNG, mmdc %s, spill %s).",
				width,
				height,
				tostring(decoded.version or "unknown"),
				artifact.spill_id
			),
			details = { artifact = entry },
			value = { artifact = entry },
		}
	end

	ctx.tools:register("mermaid", {
		description = "Render Mermaid with an installed mmdc >=12 and Node. Uses normal tool approval/sandbox; source remains readable on failure. PNG artifacts use the shared output backend.",
		side_effect = "external",
		idempotent = false,
		parameters = {
			type = "object",
			additionalProperties = false,
			required = { "source" },
			properties = {
				source = { type = "string" },
				format = { type = "string", enum = { "auto", "png", "source" } },
				session_id = { type = "string" },
				generation = { type = "string" },
				profile = {
					type = "object",
					additionalProperties = false,
					required = { "size_px", "scale", "theme", "background" },
					properties = {
						size_px = { type = "integer" },
						scale = { type = "integer", enum = { 1, 2 } },
						theme = { type = "string", enum = { "dark", "default" } },
						background = { type = "string" },
						aspect_per_mille = { type = "integer" },
						node_spacing = { type = "number" },
						rank_spacing = { type = "number" },
						node_padding_x = { type = "number" },
						node_padding_y = { type = "number" },
					},
				},
			},
		},
		execute = function(args, tool)
			assert(
				type(args.source) == "string" and #args.source > 0 and #args.source <= 65536 and utf8.len(args.source),
				"invalid Mermaid source"
			)
			return render_to_artifact(args, tool)
		end,
	})

	local function make_renderer(expanded)
		return function(call, result)
			local source = call and call.arguments and call.arguments.source or ""
			local fallback = mare.ui.Code(source, "mermaid")
			local artifact = result and result.details and result.details.artifact
			if artifact and viewer:images_supported() then
				local max_rows = expanded and cfg.expanded_max_rows or viewer:scaled_rows(cfg.max_rows)
				local node = viewer:artifact_node(artifact, max_rows, cfg.max_cols, fallback)
				if node ~= fallback then
					return expanded and mare.ui.Lines({ node, fallback }) or node
				end
			end
			return fallback
		end
	end

	ctx:effect(function()
		return mare.ui.renderer("tool:mermaid", {
			compact = make_renderer(false),
			expanded = make_renderer(true),
		})
	end)

	local function execute_render(request, owner, profile, key, job_cancel)
		if not writable(owner, job_cancel) then
			return nil
		end
		local call = {
			id = "mermaid-" .. mare.crypto.uuid(),
			name = "mermaid",
			arguments = {
				source = request.source,
				profile = profile,
				format = "png",
				session_id = owner.session_id,
				generation = owner.session_epoch,
			},
		}
		local started, execution_info = false, nil
		local function state(c, phase, definition)
			if owner.ephemeral then
				if phase == "started" then
					started, execution_info =
						true, { side_effect = definition.side_effect, idempotent = definition.idempotent }
				end
				return true
			end
			local ok, saved, err = pcall(ctx.session.record_tool_state, ctx.session, {
				tool_call_id = c.id,
				name = c.name,
				state = phase,
				side_effect = definition.side_effect,
				idempotent = definition.idempotent,
				durable = phase ~= "completed",
				cancel = phase ~= "completed" and job_cancel or nil,
				session_id = owner.session_id,
				session_epoch = owner.session_epoch,
			})
			if not ok or not saved then
				local detail = not ok and (require("mare_lib").error_message(saved) or saved)
					or (require("mare_lib").error_message(err) or err)
				return nil, detail or "Mermaid execution state was not acknowledged"
			end
			if phase == "started" then
				started, execution_info =
					true, { side_effect = definition.side_effect, idempotent = definition.idempotent }
			end
			return true
		end
		local result, frozen, program =
			ctx.tools:execute(call, { on_state = state, cancel = job_cancel, audience = "program" })
		if not record("mermaid/result", { call = frozen or call, result = result }, owner, nil) then
			return nil
		end
		if started and not state(frozen or call, "completed", execution_info) then
			return nil
		end
		if not frozen or frozen.name ~= "mermaid" or frozen.arguments.source ~= request.source then
			return nil
		end
		local canonical = program or result
		local candidate = canonical and canonical.value and canonical.value.artifact
			or canonical and canonical.details and canonical.details.artifact
		if not candidate or candidate.key ~= key then
			return nil
		end
		return available(candidate, owner, job_cancel)
	end

	local function occurrence_key_for(owner, request)
		local block_id = request.block_id
		if block_id == nil then
			block_id = tostring(request.document_id or "") .. ":" .. tostring(request.start or "")
		end
		return owner.session_id .. "\0" .. tostring(owner.session_epoch) .. "\0" .. tostring(block_id)
	end

	local function nontrivial_open_source(source, est)
		if #source < 12 or not source:find("\n", 1, true) then
			return false
		end
		return est.edges > 0 or est.nodes > 0 or #source >= 20
	end

	local function present(request)
		if not automatic_enabled or not request.supports_images or not request.supports_artifact_images or disposed then
			return nil
		end
		local est = Profile.estimate_diagram_size(request.source)
		if est.nodes > cfg.max_nodes or est.edges > cfg.max_edges then
			return nil
		end
		if request.phase == "open" then
			if
				not nontrivial_open_source(request.source, est)
				or not mare.task.sleep(cfg.preview_debounce_ms, request.cancel)
			then
				return nil
			end
		end
		local owner = info()
		if owner.session_id ~= request.session_id or owner.session_epoch ~= request.session_epoch then
			return nil
		end
		while ctx.session:switching() do
			if not mare.task.sleep(10, request.cancel) or not same(owner, request.cancel) then
				return nil
			end
		end
		local occ_key = occurrence_key_for(owner, request)
		local profile = Profile.new(cfg, {
			source = request.source,
			width = request.width,
			height = request.height,
			theme = request.theme,
			capabilities = request.capabilities,
			zoom_percent = viewer:zoom_percent(),
		})
		local key = Profile.key(cfg, request.source, profile)
		local priority = request.phase == "open" and 3 or (request.replay and 2 or 1)
		local artifact = find(key, owner, request.cancel)
		if not artifact then
			if not writable(owner, request.cancel) then
				return nil
			end
			local inflight_key = owner.session_id .. "\0" .. tostring(owner.session_epoch) .. "\0" .. key
			local settled, rendered, err = queue:run_deduped(
				inflight_key,
				occ_key,
				priority,
				request.cancel,
				function(job_cancel)
					return execute_render(request, owner, profile, key, job_cancel)
				end
			)
			if not settled or not same(owner, request.cancel) then
				return nil
			end
			if err ~= nil then
				error(err, 0)
			end
			artifact = available(rendered, owner, request.cancel)
		end
		if not artifact or not same(owner, request.cancel) then
			return nil
		end
		viewer:record_active(occ_key, {
			key = occ_key,
			document_id = request.document_id,
			block_start = request.start,
			source = request.source,
			phase = request.phase or (request.replay and "replay" or "closed"),
			revision = request.revision,
			artifact = artifact,
			profile = profile,
		})
		viewer:open_or_refresh(true)
		local fallback = mare.ui.Code(request.source, "mermaid")
		local max_cols = math.min(request.width, cfg.max_cols)
		return {
			compact = viewer:artifact_node(artifact, viewer:scaled_rows(cfg.max_rows), max_cols, fallback),
			expanded = viewer:artifact_node(artifact, cfg.expanded_max_rows, max_cols, fallback),
		}
	end

	local function register_presenters()
		if disposed or #presenter_removers > 0 then
			return
		end
		for _, language in ipairs({ "mermaid", "mmd" }) do
			presenter_removers[#presenter_removers + 1] = ctx.ui:markdown_presenter(language, {
				render = present,
				preview = cfg.streaming_preview,
				timeout_ms = cfg.timeout_ms + 10000,
				requires_artifact_images = true,
			})
		end
	end

	local function unregister_presenters()
		for _, remove_fn in ipairs(presenter_removers) do
			if type(remove_fn) == "function" then
				pcall(remove_fn)
			end
		end
		presenter_removers = {}
	end

	local function set_automatic(enabled, quiet)
		local next_state = enabled == true
		local changed = next_state ~= automatic_enabled
		automatic_enabled = next_state
		if next_state then
			register_presenters()
		else
			unregister_presenters()
			queue:cancel_all()
		end
		viewer:open_or_refresh(true)
		if not quiet then
			local status = next_state and "enabled" or "disabled"
			local msg = changed and ("Mermaid automatic rendering " .. status .. ".")
				or ("Mermaid automatic rendering already " .. status .. ".")
			Viewer.notify(msg, "info")
		end
		return automatic_enabled
	end

	local function open_preference_selector()
		if type(mare.ui.select) ~= "function" then
			Viewer.notify(
				"Mermaid automatic rendering is "
					.. (automatic_enabled and "on" or "off")
					.. ". Use /mermaid on|off|toggle.",
				"info"
			)
			return
		end
		local choice = mare.ui.select({
			title = "Mermaid diagrams",
			items = {
				{ label = "On", detail = "Render mermaid and mmd code blocks automatically" },
				{ label = "Off", detail = "Keep mermaid and mmd code blocks as highlighted source" },
			},
			selected = automatic_enabled and 1 or 2,
		})
		if choice == 1 or choice == 2 then
			set_automatic(choice == 1)
		end
	end

	viewer = Viewer.new(ctx, cfg, {
		is_disposed = function()
			return disposed
		end,
		get_automatic = function()
			return automatic_enabled
		end,
		set_automatic = set_automatic,
		open_preference_selector = open_preference_selector,
	})

	if automatic_enabled then
		register_presenters()
	end
	-- Follow the optional commands service; withdraw registrations when it disappears or is replaced.
	ctx:inject({ "commands" }, function(sub)
		viewer:register_commands(sub.commands)
	end)
	viewer:register_keymaps()

	ctx:on("session/changed", function()
		metadata_order, metadata = {}, {}
		viewer:reset_session()
		queue:cancel_all()
	end)
	ctx:effect(function()
		return function()
			disposed = true
			unregister_presenters()
			metadata_order, metadata = {}, {}
			viewer:dispose()
			queue:cancel_all()
		end
	end)
end
