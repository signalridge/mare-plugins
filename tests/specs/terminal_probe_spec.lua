local support = assert(load(mare.fs.read("tests/specs/support.lua"), "@tests/specs/support.lua"))()

local describe = mare.test.describe
local it = mare.test.it
local expect = mare.test.expect

local function load_reload()
	return support.load_lua("tests/fixtures/terminal-probe/lua/terminal_probe/reload.lua")
end

describe("terminal-probe reload helper", function()
	it("retries reload_gate busy rejections with backoff and succeeds", function()
		local reload_with_retry = load_reload()
		local calls, sleeps = 0, {}
		local fake_kernel = {
			reload = function(_, name)
				expect.eq(name, "terminals")
				calls = calls + 1
				if calls <= 3 then
					error(
						"internal: kernel.reload failed: reload or model request already in progress; retry afterwards"
					)
				end
				return { name }
			end,
		}
		local applied = reload_with_retry(fake_kernel, "terminals", {
			max_retries = 5,
			base_delay_ms = 10,
			max_delay_ms = 25,
			sleep = function(ms)
				sleeps[#sleeps + 1] = ms
			end,
		})
		expect.eq(calls, 4)
		expect.eq(#sleeps, 3)
		expect.eq(sleeps[1], 10)
		expect.eq(sleeps[2], 20)
		expect.eq(sleeps[3], 25)
		expect.eq(applied[1], "terminals")
	end)

	it("fails after exhausting max_retries on persistent busy rejections", function()
		local reload_with_retry = load_reload()
		local calls, sleeps = 0, 0
		local fake_kernel = {
			reload = function()
				calls = calls + 1
				error("internal: kernel.reload failed: reload or model request already in progress; retry afterwards")
			end,
		}
		local ok, err = pcall(reload_with_retry, fake_kernel, "terminal-backend-owner", {
			max_retries = 2,
			base_delay_ms = 5,
			sleep = function()
				sleeps = sleeps + 1
			end,
		})
		expect.eq(ok, false)
		expect.truthy(tostring(err):find("already in progress", 1, true))
		expect.eq(calls, 3)
		expect.eq(sleeps, 2)
	end)

	it("does not retry non-gate errors", function()
		local reload_with_retry = load_reload()
		local calls, sleeps = 0, 0
		local fake_kernel = {
			reload = function()
				calls = calls + 1
				error("unknown plugin `missing`")
			end,
		}
		local ok, err = pcall(reload_with_retry, fake_kernel, "missing", {
			max_retries = 4,
			sleep = function()
				sleeps = sleeps + 1
			end,
		})
		expect.eq(ok, false)
		expect.truthy(tostring(err):find("unknown plugin", 1, true))
		expect.eq(calls, 1)
		expect.eq(sleeps, 0)
	end)
end)
