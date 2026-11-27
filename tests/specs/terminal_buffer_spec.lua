local describe = mare.test.describe
local it = mare.test.it
local expect = mare.test.expect

local function load_lua(path)
	local src, err = mare.fs.read(path)
	assert(src, err)
	return assert(load(src, "@" .. path))()
end

local Buffer = load_lua("plugins/terminals/lua/terminal/buffer.lua")

describe("terminal.buffer", function()
	it("enforces budgets, returns exact delta from cursor, and truncates on UTF-8 boundaries", function()
		local b = Buffer.new(1024, 5)
		for i = 1, 100 do
			b:append("界" .. i .. "\n")
		end
		expect.truthy(#b.text <= 1024)
		expect.truthy(b.dropped)
		expect.truthy(utf8.len(b.text))
		expect.truthy(b.text:find("100", 1, true))
		local cursor = b.finish
		b:append("🌊 response\n")
		local delta, next_cursor, truncated = b:delta(cursor, 100)
		expect.eq(delta, "🌊 response\n")
		expect.eq(next_cursor, b.finish)
		expect.falsy(truncated)

		b:append(string.rep("界", 2000))
		expect.truthy(#b.text <= 1024)
		expect.truthy(utf8.len(b.text))
		delta, next_cursor, truncated = b:delta(0, 17)
		expect.truthy(#delta <= 17)
		expect.truthy(utf8.len(delta))
		expect.truthy(truncated)
		expect.eq(next_cursor, b.finish)
	end)

	it("preserves exact chunked parity for UTF-8 cuts, cursors, and trailing newlines", function()
		local function ref_new(max_bytes, max_lines)
			local r = { text = "", start = 0, finish = 0, dropped = false }
			function r:append(t)
				self.finish = self.finish + #t
				self.text = self.text .. t
				local cut = math.max(0, #self.text - max_bytes)
				local lines = 0
				for _ in self.text:gmatch("\n") do
					lines = lines + 1
				end
				local pos = 1
				while lines >= max_lines do
					local nl = self.text:find("\n", pos, true)
					if not nl then
						break
					end
					cut, pos, lines = math.max(cut, nl), nl + 1, lines - 1
				end
				while cut < #self.text do
					local byte = self.text:byte(cut + 1)
					if byte < 128 or byte >= 192 then
						break
					end
					cut = cut + 1
				end
				if cut > 0 then
					self.text, self.start, self.dropped = self.text:sub(cut + 1), self.start + cut, true
				end
			end
			function r:delta(cursor, mb)
				local begin = math.max(cursor, self.start)
				local text = self.text:sub(begin - self.start + 1)
				local truncated = cursor < self.start or #text > mb
				if #text > mb then
					local cut = #text - mb
					while cut < #text and (text:byte(cut + 1) & 192) == 128 do
						cut = cut + 1
					end
					text = text:sub(cut + 1)
				end
				return text, self.finish, truncated
			end
			return r
		end

		-- Multi-chunk appends including multi-byte UTF-8 split across chunk boundaries
		local payload = "alpha\n界🌊beta\ngamma\n" .. string.rep("中", 20) .. "\nend-no-nl"
		local b1 = Buffer.new(30, 4)
		local b2 = Buffer.new(30, 4)
		local r1 = ref_new(30, 4)
		local r2 = ref_new(30, 4)
		b2:append(payload)
		r2:append(payload)
		for i = 1, #payload, 2 do
			local chunk = payload:sub(i, i + 1)
			b1:append(chunk)
			r1:append(chunk)
			local d1, f1, tr1 = b1:delta(0, 11)
			local rd1, rf1, rtr1 = r1:delta(0, 11)
			expect.eq(d1, rd1)
			expect.eq(f1, rf1)
			expect.eq(tr1, rtr1)
			local d2, f2, tr2 = b1:delta(b1.start + 1, 11)
			local rd2, rf2, rtr2 = r1:delta(r1.start + 1, 11)
			expect.eq(d2, rd2)
			expect.eq(f2, rf2)
			expect.eq(tr2, rtr2)
			local d3, f3, tr3 = b1:delta(b1.finish, 11)
			expect.eq(f3, b1.finish)
			expect.eq(d3, "")
			expect.falsy(tr3)
		end
		expect.eq(b1.start, r1.start)
		expect.eq(b1.finish, r1.finish)
		expect.eq(b1.dropped, r1.dropped)
		expect.eq(b1.text, r1.text)
		expect.eq(b2.text, r1.text)
		expect.eq(b2.start, r1.start)

		for _, cursor in ipairs({ 0, b1.start, b1.start + 1, b1.finish - 5, b1.finish, b1.finish + 10 }) do
			for _, mb in ipairs({ 0, 1, 5, 11, 30, 100 }) do
				local td, tf, ttr = b1:delta(cursor, mb)
				local rd, rf, rtr = r1:delta(cursor, mb)
				expect.eq(td, rd)
				expect.eq(tf, rf)
				expect.eq(ttr, rtr)
			end
		end

		-- Trailing newline line-count boundary (max_lines = 3: 2 '\n' kept, 3rd '\n' drops 1st line)
		local tb = Buffer.new(1024, 3)
		tb:append("L1\n")
		tb:append("L2\n")
		expect.eq(tb.dropped, false)
		expect.eq(tb.text, "L1\nL2\n")
		tb:append("L3\n")
		expect.eq(tb.dropped, true)
		expect.eq(tb.text, "L2\nL3\n")
		tb:append("L4")
		expect.eq(tb.text, "L2\nL3\nL4")
	end)

	it("reclaims consumed head chunks/newline indices and coalesces tiny reads", function()
		-- 1. Large newline-heavy append into a small line-limited buffer must reclaim consumed prefix & nl index.
		collectgarbage("collect")
		local base_kb = collectgarbage("count")
		local b = Buffer.new(1024, 2)
		b:append(string.rep("ab\n", 400000) .. "xyz") -- ~1.2 MB input, only "xyz" (or last line) visible
		collectgarbage("collect")
		local after_kb = collectgarbage("count")
		expect.eq(b.text, "ab\nxyz")
		expect.truthy(after_kb - base_kb < 64)

		-- 2. 16,384 one-byte appends coalesce into bounded chunks instead of 16k chunk tables.
		collectgarbage("collect")
		local small_base_kb = collectgarbage("count")
		local sb = Buffer.new(4 * 1024 * 1024, 10000)
		for i = 1, 16384 do
			sb:append(i % 64 == 0 and "\n" or "a")
		end
		collectgarbage("collect")
		local small_after_kb = collectgarbage("count")
		expect.eq(#sb.text, 16384)
		expect.truthy(small_after_kb - small_base_kb < 128)
		local tail_delta, fin, trunc = sb:delta(sb.finish - 64, 64)
		expect.eq(#tail_delta, 64)
		expect.eq(fin, sb.finish)
		expect.falsy(trunc)
		expect.truthy(utf8.len(tail_delta) ~= nil)
	end)
end)
