local describe = mare.test.describe
local it = mare.test.it
local before_each = mare.test.before_each
local expect = mare.test.expect

local function load_lua(path)
	local src, err = mare.fs.read(path)
	assert(src, err)
	return assert(load(src, "@" .. path))()
end

local support = assert(load(mare.fs.read("tests/specs/support.lua"), "@tests/specs/support.lua"))()
local Config = load_lua("plugins/terminals/lua/terminal/config.lua")

local function copy_config(src)
	local out = {}
	for k, v in pairs(src) do
		if type(v) == "table" then
			local inner = {}
			for ik, iv in pairs(v) do
				inner[ik] = iv
			end
			out[k] = inner
		else
			out[k] = v
		end
	end
	return out
end

describe("terminal.config", function()
	local base_cfg
	local cfg

	before_each(function()
		base_cfg = base_cfg or support.default_config(load_lua("plugins/terminals/init.lua"))
		cfg = copy_config(base_cfg)
	end)

	it("validates default config and resolves bash argv via mare.proc.which", function()
		Config.validate(cfg)
		local expected_bash = mare.proc.which("bash")
		if mare.os == "windows" then
			local ok, shell, args = pcall(Config.shell, cfg)
			if ok then
				expect.truthy(shell:lower():match("bash%.exe$") ~= nil)
				expect.eq(args, { "--noprofile", "--norc", "-i" })
			else
				expect.truthy(tostring(shell):find("Terminal shell executable unavailable", 1, true) ~= nil)
			end
		elseif expected_bash then
			local shell, args = Config.shell(cfg)
			expect.eq(shell, expected_bash)
			expect.eq(args, { "--noprofile", "--norc", "-i" })
		else
			expect.error(function()
				Config.shell(cfg)
			end, "Terminal shell executable unavailable")
		end
	end)

	it("selects pwsh default args and clones shell_args", function()
		cfg.shell_dialect = "pwsh"
		cfg.shell = "/configured/pwsh"
		local shell, args = Config.shell(cfg)
		expect.eq(shell, "/configured/pwsh")
		expect.eq(args, { "-NoLogo", "-NoProfile" })

		cfg.shell = "/configured/bash"
		cfg.shell_args = { "--custom" }
		shell, args = Config.shell(cfg)
		expect.eq(shell, "/configured/bash")
		expect.eq(args, { "--custom" })
		args[1] = "changed"
		expect.eq(cfg.shell_args[1], "--custom")
	end)

	it("rejects invalid budgets and sparse shell_args", function()
		cfg.buffer_bytes = 2048
		cfg.read_max_bytes = 2049
		expect.error(function()
			Config.validate(cfg)
		end, "read_max_bytes exceeds retained buffer")

		cfg.read_max_bytes = 1024
		cfg.shell_args = { [1] = "a", [3] = "b" }
		expect.error(function()
			Config.validate(cfg)
		end, "Invalid terminal shell_args")
	end)
end)
