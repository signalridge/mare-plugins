local M = {}

function M.make_storage(cfg)
	cfg = cfg or {}
	local items = {}
	local counter = 0
	local removed = {}
	return {
		items = items,
		removed = removed,
		save = function(owner, content, opts)
			if cfg.fail_save then
				error(cfg.fail_save)
			end
			counter = counter + 1
			local spill_id = cfg.handle or ((cfg.prefix or "h-") .. counter)
			local path = "/tmp/spill/" .. spill_id .. ".txt"
			items[spill_id] = { owner = owner, kind = "text", content = content, size = #content, opts = opts }
			return {
				spill_id = spill_id,
				size = #content,
				path = path,
				backend = "test-backend",
				source = opts and opts.source or nil,
				retrieval_hint = cfg.retrieval_hint
					or ("Use read_spill with offset/limit, or read (offset/limit) / grep at " .. path .. "."),
			}
		end,
		save_bytes = function(owner, bytes, opts)
			counter = counter + 1
			if cfg.fail_save_bytes_at and counter == cfg.fail_save_bytes_at then
				error(cfg.fail_save_bytes_err or "ENOSPC: no space left on device")
			end
			local spill_id = "b-" .. counter
			items[spill_id] = { owner = owner, kind = "bytes", content = bytes, size = #bytes, opts = opts }
			return { spill_id = spill_id, size = #bytes, path = "/tmp/spill/" .. spill_id .. ".txt" }
		end,
		read = function(spill_id, opts)
			if cfg.fail_read then
				error(cfg.fail_read, 0)
			end
			local owner = opts and opts.session_id
			local item = assert(items[spill_id], (cfg.name or "store") .. ": missing spill_id: " .. tostring(spill_id))
			assert(item.owner == owner, "owner mismatch")
			return { content = item.content, more = false, next_byte = #item.content }
		end,
		delete = function(spill_id, opts)
			local owner = opts and opts.session_id
			local item = items[spill_id]
			if item and item.owner == owner then
				items[spill_id] = nil
				removed[spill_id] = true
			end
		end,
	}
end

function M.make_llm(opts)
	opts = opts or {}
	local valid_snap = opts.valid_snap
	local expired_snap = opts.expired_snap
	local image_tokens = opts.image_tokens or 50
	return {
		measure = function(_, route_or_snap, content)
			if not route_or_snap then
				return nil, "missing route"
			end
			if route_or_snap == expired_snap then
				return nil, "route snapshot has expired"
			end
			if valid_snap and route_or_snap ~= valid_snap and route_or_snap.provider ~= "test-prov" then
				return nil, "unknown measurement route"
			end
			local blocks = type(content) == "string" and { { type = "text", text = content } } or content
			local measured_blocks = {}
			local total = 0
			for i, b in ipairs(blocks) do
				local t
				if b.type == "text" then
					t = math.ceil(#b.text / 4) + 4
				elseif b.type == "image" then
					if opts.reject_images then
						return nil, "image pricing unsupported"
					end
					t = image_tokens + 4
				else
					return nil, "unsupported block"
				end
				total = total + t
				measured_blocks[i] = { index = i, kind = b.type, tokens = t }
			end
			return {
				tokens = total,
				estimated = true,
				method = "test-utf16",
				blocks = measured_blocks,
			}
		end,
	}
end

-- `storage` backs the default mare.spill; a custom root gets its own store (`local_storage`, or a
-- fresh one), as mare.spill.new_local does on disk
function M.make_ctx(storage, llm, local_storage)
	local handlers = {}
	local logs = {}
	local tools = {}
	local dispose_cbs = {}
	local_storage = local_storage or M.make_storage({ prefix = "l-", name = "custom root" })
	mare.spill = {
		new_local = function()
			return {
				save = local_storage.save,
				save_bytes = local_storage.save_bytes,
				read = local_storage.read,
				read_bytes = local_storage.read,
				delete = local_storage.delete,
				dispose = function()
					local_storage.disposed = (local_storage.disposed or 0) + 1
				end,
			}
		end,
		save = function(owner, content, opts)
			return storage.save(owner, content, opts)
		end,
		save_bytes = function(owner, bytes, opts)
			return storage.save_bytes(owner, bytes, opts)
		end,
		read = function(spill_id, opts)
			return storage.read(spill_id, opts)
		end,
		read_bytes = function(spill_id, opts)
			return storage.read(spill_id, opts)
		end,
		delete = function(spill_id, opts)
			return storage.delete(spill_id, opts)
		end,
	}
	local ctx = {
		logs = logs,
		tools_registered = tools,
		session = {
			info = function()
				return { session_id = "sess-1" }
			end,
		},
		llm = llm,
		tools = {
			register = function(_, name, def)
				tools[name] = def
			end,
		},
		dispose_cbs = dispose_cbs,
		on = function(_, event, fn)
			-- support.load_plugin's adapter already gives waterfall listeners their next
			handlers[event] = fn
		end,
		effect = function(_, setup)
			local fn = setup()
			dispose_cbs[#dispose_cbs + 1] = fn
		end,
	}
	mare.log = function(level, msg)
		logs[#logs + 1] = { level = level, msg = msg }
	end
	return ctx, handlers
end

return M
