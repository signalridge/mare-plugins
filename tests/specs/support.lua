local M = {}

function M.load_lua(path)
	local src, err = mare.fs.read(path)
	assert(src, err)
	return assert(load(src, "@" .. path))()
end

function M.preload_modules(plugin_dir, modules)
	for _, mod in ipairs(modules) do
		local rel = mod:gsub("%.", "/")
		local path = ("plugins/%s/lua/%s.lua"):format(plugin_dir, rel)
		local src, err = mare.fs.read(path)
		assert(src, err)
		package.preload[mod] = assert(load(src, "@" .. path))
	end
end

-- Every plugin is a cordis component: it provides services through mare_lib.service and votes
-- through ctx.policy. A spec drives apply with a plain mock ctx instead of a cordis ctx: there the
-- service is handed to the mock's own `provide`, and `policy:voter/rewriter` register through the
-- mock's `on`, so the existing mocks and their assertions keep working unchanged.
-- Core waterfall listeners take `(data, ev)` where `ev.next(v)` continues
-- the chain; some legacy specs still call `handlers["tool/result"](result, call, op)` with 3 args
-- or pass a single table directly, so the adapter handles both seamlessly.
local TOOL_DATA_WATERFALLS = {
	["tool/result"] = true,
	["tool/after"] = true,
	["tool/program-result"] = true,
}
local WATERFALLS = {
	["request/build"] = true,
	["tool/result"] = true,
	["tool/after"] = true,
	["tool/program-result"] = true,
	["context/system"] = true,
	["context/transform"] = true,
	["input/transform"] = true,
	["permission/parse"] = true,
	["compact/summary-error"] = true,
	["theme/palette"] = true,
	["ui/caps"] = true,
}

local function adapt_native_mock(ctx, native)
	if type(ctx) ~= "table" then
		return
	end
	-- Mare events go through ctx.bus; a mock records them on its own emit/bail.
	if rawget(ctx, "bus") == nil then
		local bus = {}
		for _, m in ipairs({ "emit", "emit_checked", "bail", "waterfall", "waterfall_checked" }) do
			bus[m] = function(_, ...)
				local f = ctx[m] or (m == "emit_checked" and ctx.emit) or (m == "waterfall_checked" and ctx.waterfall)
				if f then
					return f(ctx, ...)
				end
			end
		end
		rawset(ctx, "bus", bus)
	end
	if native then
		-- ctx:inject(names, fn) follows a service; a mock runs the follower at once with a sub ctx
		-- that reads through to the mock, so a spec can set or clear the optional service later
		if rawget(ctx, "inject") == nil then
			ctx.inject = function(self, _, fn)
				local sub = setmetatable({
					effect = function(_, setup, ...)
						if type(self.effect) == "function" then
							return self:effect(setup, ...)
						end
						return setup()
					end,
				}, { __index = self })
				return fn(sub)
			end
		end
	end
	-- a spec may replace ctx.on between applies: wrap whatever on is current, once
	if not native or type(ctx.on) ~= "function" or ctx.on == rawget(ctx, "__spec_on_wrapper") then
		return
	end
	local on = ctx.on
	ctx.on = function(self, event, fn, opts)
		if WATERFALLS[event] then
			local inner = fn
			fn = function(...)
				local n = select("#", ...)
				local args = table.pack(...)
				if TOOL_DATA_WATERFALLS[event] and (n > 1 or type(args[1]) ~= "table" or args[1].result == nil) then
					local data = { result = args[1], call = args[2], operation = args[3] }
					local ev = {
						next = function(v)
							if v == nil then
								return data
							end
							return v
						end,
					}
					local out = inner(data, ev)
					if type(out) == "table" and out.result ~= nil then
						return out.result
					end
					return out
				end
				local data = args[1]
				local ev = n >= 2 and type(args[2]) == "table" and type(args[2].next) == "function" and args[2]
					or {
						next = function(v)
							if v == nil then
								return data
							end
							return v
						end,
					}
				return inner(data, ev)
			end
		end
		return on(self, event, fn, opts)
	end
	rawset(ctx, "__spec_on_wrapper", ctx.on)
	if rawget(ctx, "policy") == nil then
		local function register(_, point, f, opts)
			return ctx:on(point, f, opts) -- the current on (a spec may have replaced it)
		end
		ctx.policy = {
			voter = register,
			rewriter = register,
			epoch = function()
				return 0
			end,
			has_voters = function()
				return false
			end,
		}
	end
end

local function wrap_mare_lib_service()
	local lib = require("mare_lib")
	if rawget(lib, "__spec_mock_service") then
		return
	end
	local real = lib.service
	lib.service = function(ctx, name, impl)
		if type(ctx) == "table" and rawget(ctx, "cordis") == nil and type(rawget(ctx, "provide")) == "function" then
			ctx:provide(name, impl)
			return impl
		end
		return real(ctx, name, impl)
	end
	-- mare_lib.follow on a mock: the getter reads the mock's field live (present while a spec sets
	-- it, nil once cleared), as a real follower holds the service while its provider is up
	local real_follow = lib.follow
	lib.follow = function(ctx, name)
		if type(ctx) == "table" and rawget(ctx, "cordis") == nil and rawget(ctx, "__spec_on_wrapper") ~= nil then
			return function()
				return rawget(ctx, name)
			end
		end
		return real_follow(ctx, name)
	end
	local real_followers = lib.followers
	if type(real_followers) == "function" then
		lib.followers = function(ctx, names)
			if type(ctx) == "table" and rawget(ctx, "cordis") == nil and rawget(ctx, "__spec_on_wrapper") ~= nil then
				local allowed = {}
				for i = 1, #names do
					allowed[names[i]] = true
				end
				return setmetatable({}, {
					__index = function(_, name)
						if not allowed[name] then
							return nil
						end
						return rawget(ctx, name)
					end,
				})
			end
			return real_followers(ctx, names)
		end
	end
	rawset(lib, "__spec_mock_service", true)
end

-- for specs that hand a mock ctx straight to a plugin's modules (no apply): ctx.bus forwarding
function M.adapt_mock(ctx, native)
	if native then
		wrap_mare_lib_service()
	end
	adapt_native_mock(ctx, native)
	return ctx
end

function M.load_plugin(plugin_dir, modules)
	M.preload_modules(plugin_dir, modules or {})
	local def = M.load_lua(("plugins/%s/init.lua"):format(plugin_dir))
	if type(def) == "table" and type(def.apply) == "function" then
		wrap_mare_lib_service()
		local apply = def.apply
		def.apply = function(ctx, ...)
			adapt_native_mock(ctx, true)
			return apply(ctx, ...)
		end
	end
	return def
end

function M.copy_table(value)
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in pairs(value) do
		out[k] = M.copy_table(v)
	end
	return out
end

function M.default_config(plugin)
	if type(plugin.config) == "table" then
		return M.copy_table(plugin.config)
	end
	local cfg = {}
	for k, field in pairs(plugin.config_schema or {}) do
		if type(field) == "table" and field.default ~= nil then
			cfg[k] = M.copy_table(field.default)
		end
	end
	return cfg
end

return M
