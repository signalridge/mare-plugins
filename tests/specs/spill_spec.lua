local support = assert(load(mare.fs.read("tests/specs/support.lua"), "@tests/specs/support.lua"))()
local H = support.load_lua("tests/specs/spill_support.lua")

local describe = mare.test.describe
local it = mare.test.it
local before_each = mare.test.before_each
local after_each = mare.test.after_each
local expect = mare.test.expect

local plugin = support.load_plugin("tool-spill", { "spill.budget", "spill.media", "spill.notice", "spill.retain" })
local notice_mod = require("spill.notice")
local retain = require("spill.retain")
local budget = require("spill.budget")

local make_storage, make_llm, make_ctx = H.make_storage, H.make_llm, H.make_ctx

describe("spill", function()
	local real_log = mare.log
	mare.test.after_each(function()
		mare.log = real_log
	end)
	local orig_text_tokens, orig_spill

	before_each(function()
		orig_text_tokens = mare.text.tokens
		orig_spill = mare.spill
	end)

	after_each(function()
		mare.text.tokens = orig_text_tokens
		mare.spill = orig_spill
	end)

	it("validates max_inline_tokens config", function()
		local schema = plugin.config_schema.max_inline_tokens
		expect.eq(schema.type, "integer")
		expect.eq(schema.nullable, true)
		expect.eq(schema.min, 16)
		expect.eq(schema.max, 9007199254740991)
	end)

	it("keeps a cancelled call's output as is and saves nothing", function()
		local storage = make_storage()
		local llm = make_llm({ valid_snap = { id = "snap-1" }, expired_snap = { id = "snap-exp" } })
		local ctx, handlers = make_ctx(storage, llm)
		plugin.apply(ctx, {
			max_bytes = 64,
			max_lines = 2,
			cleanup_period_days = 30,
			exclude = {},
		})
		local big = string.rep("abcd\n", 200)
		local out = handlers["tool/result"](
			{ content = big, cancelled = true },
			{ name = "probe" },
			{ session_id = "sess-1" }
		)
		expect.eq(out.content, big)
		expect.falsy(out.truncated)
		expect.eq(next(storage.items), nil)
	end)

	it("falls back deterministically when llm.measure is missing or route/snapshot fails", function()
		local storage = make_storage()
		local snap = { id = "snap-1" }
		local expired = { id = "snap-exp" }
		local llm = make_llm({ valid_snap = snap, expired_snap = expired })
		local ctx, handlers = make_ctx(storage, llm)
		plugin.apply(ctx, {
			max_bytes = 51200,
			max_lines = 2000,
			max_inline_tokens = 100,
			cleanup_period_days = 30,
			exclude = {},
		})
		local on_result = assert(handlers["tool/result"])
		local big = string.rep("abcd", 200)
		local res_no_route = on_result({ content = big }, { name = "probe" }, { session_id = "sess-1" })
		expect.truthy(res_no_route.truncated)
		expect.truthy(res_no_route.output_notice)
		expect.truthy(res_no_route.content ~= big)
		expect.truthy(math.ceil(#(res_no_route.content .. "\n" .. res_no_route.output_notice) / 4) <= 100)
		expect.truthy(next(storage.items) ~= nil)

		local storage_exp = make_storage()
		local ctx_exp, handlers_exp = make_ctx(storage_exp, llm)
		plugin.apply(ctx_exp, {
			max_bytes = 51200,
			max_lines = 2000,
			max_inline_tokens = 100,
			cleanup_period_days = 30,
			exclude = {},
		})
		local res_expired = handlers_exp["tool/result"](
			{ content = big },
			{ name = "probe" },
			{ session_id = "sess-1", route_snapshot = expired }
		)
		expect.truthy(res_expired.truncated)
		expect.truthy(res_expired.output_notice)
		expect.truthy(res_expired.content ~= big)
		expect.truthy(math.ceil(#(res_expired.content .. "\n" .. res_expired.output_notice) / 4) <= 100)
		expect.truthy(next(storage_exp.items) ~= nil)
		expect.truthy(#ctx.logs >= 1 and #ctx_exp.logs >= 1)

		-- Built-in llm service without llm.measure (real mare runtime)
		local storage_no_m = make_storage()
		local ctx_no_m, handlers_no_m = make_ctx(storage_no_m, {})
		plugin.apply(ctx_no_m, {
			max_bytes = 51200,
			max_lines = 2000,
			max_inline_tokens = 100,
			cleanup_period_days = 30,
			exclude = {},
		})
		local res_no_m = handlers_no_m["tool/result"](
			{ content = big },
			{ name = "probe" },
			{ session_id = "sess-1", route = "responses" }
		)
		expect.truthy(res_no_m.truncated)
		expect.truthy(res_no_m.output_notice)
		expect.truthy(res_no_m.content ~= big)
		expect.truthy(mare.text.tokens(res_no_m.content .. "\n" .. res_no_m.output_notice) <= 100)
		expect.truthy(next(storage_no_m.items) ~= nil)
		expect.truthy(#ctx_no_m.logs >= 1)
		expect.eq(ctx_no_m.logs[#ctx_no_m.logs].level, "warn")

		-- Dense punctuation and CJK/UTF-8 text exceeding mare.text.tokens budget is truncated within budget.
		for _, dense in ipairs({ string.rep("1,2,", 120), string.rep("中", 160) }) do
			local res_dense = handlers_no_m["tool/result"](
				{ content = dense },
				{ name = "probe" },
				{ session_id = "sess-1", route = "responses" }
			)
			expect.truthy(res_dense.truncated)
			expect.truthy(res_dense.output_notice)
			expect.truthy(res_dense.content ~= dense)
			expect.truthy(mare.text.tokens(res_dense.content .. "\n" .. res_dense.output_notice) <= 100)
		end
	end)

	it("retains token-budgeted text safely at UTF-8 boundaries", function()
		local storage = make_storage()
		local snap = { id = "snap-ok" }
		local llm = make_llm({ valid_snap = snap })
		local cfg = { max_bytes = 51200, max_lines = 2000, max_inline_tokens = 80 }
		local utf8_text = string.rep("αβ😀中", 120) -- > 80 tokens, < 51200 bytes
		local retained = retain(
			{ content = utf8_text },
			{ session_id = "sess-1", max_bytes = 51200, max_lines = 2000, route_snapshot = snap },
			cfg,
			storage,
			llm
		)
		expect.truthy(retained.truncated)
		expect.truthy(retained.output_notice)
		expect.match(retained.content, "omitted %d+ bytes")
		local combined = retained.content .. "\n" .. retained.output_notice
		local m = assert(llm:measure(snap, combined))
		expect.truthy(m.tokens <= 80)
		for _, b in ipairs({ utf8.codepoint(combined, 1, #combined) }) do
			expect.truthy(b >= 0)
		end
	end)

	it("falls back to compact notice when rich hint exceeds max_inline_tokens", function()
		-- Rich hint (> 55 tokens) falls back to compact read_spill notice (<= 55 tokens) without spilling over budget
		local hint_storage = make_storage({ retrieval_hint = string.rep("H", 240) })
		local snap = { id = "snap-compact" }
		local llm = make_llm({ valid_snap = snap })
		local ctx, handlers = make_ctx(hint_storage, llm)
		plugin.apply(ctx, {
			max_bytes = 51200,
			max_lines = 2000,
			max_inline_tokens = 55,
			cleanup_period_days = 30,
			exclude = {},
		})
		local out = handlers["tool/result"](
			{ content = string.rep("C", 1200) },
			{ name = "probe" },
			{ session_id = "sess-1", max_bytes = 51200, max_lines = 2000, route_snapshot = snap }
		)
		expect.truthy(out.truncated)
		expect.truthy(out.output_notice)
		expect.truthy(out.output_notice:find("Use read_spill with offset/limit.", 1, true))
		local wire = out.content == "" and out.output_notice or (out.content .. "\n" .. out.output_notice)
		local mc = assert(llm:measure(snap, wire))
		expect.truthy(mc.tokens <= 55)
	end)

	it("preserves multimodal head-tail order, whole images, omitted counts, and replay", function()
		local storage = make_storage()
		local snap = { id = "snap-mm" }
		local llm = make_llm({ valid_snap = snap, image_tokens = 40 })
		local cfg = { max_bytes = 51200, max_lines = 2000, max_inline_tokens = 150 }
		local blocks = {
			{ type = "text", text = "HEAD:" .. string.rep("A", 40) },
			{ type = "image", data = "iVBORw0KGgo=", mime_type = "image/png" },
			{ type = "text", text = string.rep("M", 800) },
			{ type = "image", data = "/9j/4AAQ", mime_type = "image/jpeg" },
			{ type = "text", text = "TAIL:" .. string.rep("Z", 40) },
		}
		local retained = retain(
			{ content = blocks },
			{ session_id = "sess-1", max_bytes = 51200, max_lines = 2000, route_snapshot = snap },
			cfg,
			storage,
			llm
		)
		expect.truthy(retained.truncated)
		expect.eq(type(retained.content), "table")
		expect.eq(retained.content[#retained.content].text, retained.output_notice)
		local m = assert(llm:measure(snap, retained.content))
		expect.truthy(m.tokens <= 150)

		local text_handle = retained.output_notice:match("%): (%S+)%. Use read_spill")
		local full_saved = storage.read(text_handle, { session_id = "sess-1" }).content
		expect.truthy(full_saved:find("Image #1: mime=image/png", 1, true))
		expect.truthy(full_saved:find("spill_id=b-1", 1, true))
		expect.eq(full_saved:find("handle=", 1, true), nil)
		expect.truthy(full_saved:find("Image #2: mime=image/jpeg", 1, true))
		expect.eq(storage.items["b-1"].content, string.char(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A))
		expect.eq(storage.items["b-2"].content, string.char(0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10))
		expect.eq(#retained.details.spill.images, 2)
		expect.eq(retained.details.spill.images[1].mime, "image/png")
		expect.eq(retained.details.spill.images[1].size, 8)
		expect.eq(retained.details.spill.images[2].mime, "image/jpeg")
		expect.eq(retained.details.spill.images[2].size, 6)

		local found_omission = false
		for _, b in ipairs(retained.content) do
			if b.type == "text" and b.text:find("omitted %d+ bytes") then
				found_omission = true
			end
		end
		expect.truthy(found_omission)

		local before_count = 0
		for _ in pairs(storage.items) do
			before_count = before_count + 1
		end
		local replayed = retain(
			{ content = retained.content },
			{ session_id = "sess-1", max_bytes = 51200, max_lines = 2000, route_snapshot = snap },
			cfg,
			storage,
			llm
		)
		local after_count = 0
		for _ in pairs(storage.items) do
			after_count = after_count + 1
		end
		expect.eq(before_count, after_count)
		expect.eq(replayed.output_notice, retained.output_notice)
		expect.eq(replayed.truncated, true)
	end)

	it("splits persisted spill notices from body text", function()
		local body, persisted =
			notice_mod.split("abc\n[Complete tool output (10 bytes): h-1. Use read_spill with offset/limit.]")
		expect.eq(body, "abc")
		expect.eq(persisted, "[Complete tool output (10 bytes): h-1. Use read_spill with offset/limit.]")

		local rich =
			"[Complete tool output (10 bytes): h-1. Use read_spill with offset/limit, or read (offset/limit) / grep at /tmp/a[b]/h-1.txt.]"
		local rbody, rpersisted = notice_mod.split("abc\n" .. rich)
		expect.eq(rbody, "abc")
		expect.eq(rpersisted, rich)

		local only_body, only_persisted =
			notice_mod.split("[Complete tool output (10 bytes): h-1. Use read_spill with offset/limit.]")
		expect.eq(only_body, "")
		expect.truthy(only_persisted)
	end)

	it("attaches rich spill metadata and forwards session-reference sources", function()
		local storage = make_storage()
		local ctx, handlers = make_ctx(storage, make_llm())
		plugin.apply(ctx, {
			max_bytes = 512,
			max_lines = 50,
			cleanup_period_days = 30,
			exclude = {},
		})
		local on_result = assert(handlers["tool/result"])
		local big = "START:" .. string.rep("line\n", 120) .. ":END"
		local res = on_result(
			{ content = big, details = { label = "build log" } },
			{ name = "build_tool", id = "call-42" },
			{ session_id = "sess-1", max_bytes = 512, max_lines = 50 }
		)
		expect.truthy(res.truncated)
		expect.truthy(res.output_notice)
		expect.truthy(#res.content + 1 + #res.output_notice <= 512)
		expect.truthy(res.output_notice:find("read (offset/limit) / grep at /tmp/spill/", 1, true))
		local spill_meta = assert(res.details and res.details.spill)
		expect.eq(spill_meta.suggested_name, "build_tool.txt")
		expect.eq(spill_meta.source.kind, "tool")
		expect.eq(spill_meta.source.tool_name, "build_tool")
		expect.eq(spill_meta.source.tool_call_id, "call-42")
		expect.eq(spill_meta.source.label, "build log")

		local sref = retain(
			{
				content = big,
				suggested_name = "parent-transcript",
				spill_source = { kind = "session-reference", session_id = "sess-parent", path = "/tmp/sess.jsonl" },
			},
			{ session_id = "sess-1", max_bytes = 512, max_lines = 50 },
			{ max_bytes = 512, max_lines = 50 },
			storage,
			nil,
			{ name = "delegate", id = "call-99" }
		)
		expect.eq(sref.details.spill.suggested_name, "parent-transcript.txt")
		expect.eq(sref.details.spill.source.kind, "session-reference")
		expect.eq(sref.details.spill.source.session_id, "sess-parent")
	end)

	it("keeps storage-failure and notice-overflow fallbacks strictly within budget", function()
		-- 8a. Text + byte/line budget + storage.save failure (ENOSPC)
		local storage = make_storage({ fail_save = "ENOSPC: no space left on device" })
		local ctx, handlers = make_ctx(storage, make_llm())
		plugin.apply(ctx, {
			max_bytes = 512,
			max_lines = 12,
			cleanup_period_days = 30,
			exclude = {},
		})
		local big = "PREFIX:" .. string.rep("x", 4000) .. "\nSUFFIX"
		local out = handlers["tool/result"](
			{ content = big },
			{ name = "probe", id = "call-enospc-bytes" },
			{ session_id = "sess-1", max_bytes = 512, max_lines = 12 }
		)
		expect.eq(out.truncated, true)
		expect.eq(out.output_notice, nil)
		expect.truthy(#out.content <= 512)
		expect.eq(out.content:sub(1, 7), "PREFIX:")
		expect.falsy(out.content:find("Complete tool output", 1, true))
		expect.truthy(out.content:find("could not be saved", 1, true))
		expect.truthy(out.details.spill_error:find("ENOSPC", 1, true))
		expect.truthy(#ctx.logs >= 1)
		expect.eq(ctx.logs[#ctx.logs].level, "warn")

		-- 8b. Text + token budget + storage.save failure
		local snap = { id = "snap-enospc" }
		local llm = make_llm({ valid_snap = snap })
		local ctx_tok, handlers_tok = make_ctx(storage, llm)
		plugin.apply(ctx_tok, {
			max_bytes = 51200,
			max_lines = 2000,
			max_inline_tokens = 80,
			cleanup_period_days = 30,
			exclude = {},
		})
		local big_tok = "TOKENHEAD:" .. string.rep("αβ😀中", 200)
		local out_tok = handlers_tok["tool/result"](
			{ content = big_tok },
			{ name = "probe" },
			{ session_id = "sess-1", max_bytes = 51200, max_lines = 2000, route_snapshot = snap }
		)
		expect.eq(out_tok.truncated, true)
		expect.eq(out_tok.output_notice, nil)
		expect.truthy(out_tok.content:find("could not be saved", 1, true))
		local mt = assert(llm:measure(snap, out_tok.content))
		expect.truthy(mt.tokens <= 80)

		-- 8c. Multimodal + partial save_bytes failure cleans up earlier image handles and truncates in-memory
		local mm_storage = make_storage({ fail_save_bytes_at = 2, fail_save_bytes_err = "ENOSPC: disk full" })
		local mm_llm = make_llm({ valid_snap = snap, image_tokens = 30 })
		local mm_ctx, mm_handlers = make_ctx(mm_storage, mm_llm)
		plugin.apply(mm_ctx, {
			max_bytes = 51200,
			max_lines = 2000,
			max_inline_tokens = 140,
			cleanup_period_days = 30,
			exclude = {},
		})
		local mm_out = mm_handlers["tool/result"]({
			content = {
				{ type = "text", text = "HEAD:" .. string.rep("A", 30) },
				{ type = "image", data = "iVBORw0KGgo=", mime_type = "image/png" },
				{ type = "text", text = string.rep("B", 1000) },
				{ type = "image", data = "iVBORw0KGgo=", mime_type = "image/png" },
			},
		}, { name = "probe" }, { session_id = "sess-1", max_bytes = 51200, max_lines = 2000, route_snapshot = snap })
		expect.eq(mm_out.truncated, true)
		expect.eq(mm_out.output_notice, nil)
		expect.eq(next(mm_storage.items), nil)
		expect.truthy(next(mm_storage.removed) ~= nil)
		local last_blk = mm_out.content[#mm_out.content]
		expect.eq(last_blk.type, "text")
		expect.truthy(last_blk.text:find("could not be saved", 1, true))
		local mmm = assert(mm_llm:measure(snap, mm_out.content))
		expect.truthy(mmm.tokens <= 140)

		-- 8d. Oversized handle/hint causes notice overflow -> revokes saved handle and falls back cleanly within budget
		local hint_storage = make_storage({ handle = string.rep("H", 600), retrieval_hint = string.rep("H", 800) })
		local h_ctx, h_handlers = make_ctx(hint_storage, make_llm())
		plugin.apply(h_ctx, {
			max_bytes = 512,
			max_lines = 20,
			cleanup_period_days = 30,
			exclude = {},
		})
		local h_out = h_handlers["tool/result"](
			{ content = string.rep("Z", 3000) },
			{ name = "probe" },
			{ session_id = "sess-1", max_bytes = 512, max_lines = 20 }
		)
		expect.eq(h_out.truncated, true)
		expect.eq(h_out.output_notice, nil)
		expect.truthy(#h_out.content <= 512)
		expect.eq(next(hint_storage.items), nil)
		expect.truthy(next(hint_storage.removed) ~= nil)
	end)

	it("cleans up handles on invalid image magic and enforces tight token boundaries", function()
		-- N10: valid PNG #1 followed by corrupted PNG #2 -> cleans up #1 handle and truncates in-memory
		local snap = { id = "snap-n10" }
		local n10_storage = make_storage()
		local n10_llm = make_llm({ valid_snap = snap, image_tokens = 25 })
		local n10_ctx, n10_handlers = make_ctx(n10_storage, n10_llm)
		plugin.apply(n10_ctx, {
			max_bytes = 51200,
			max_lines = 2000,
			max_inline_tokens = 120,
			cleanup_period_days = 30,
			exclude = {},
		})
		local bad_mm = n10_handlers["tool/result"]({
			content = {
				{ type = "text", text = "HEAD:" .. string.rep("Q", 40) },
				{ type = "image", data = "iVBORw0KGgo=", mime_type = "image/png" },
				{ type = "text", text = string.rep("R", 800) },
				{ type = "image", data = "bm90LXBuZw==", mime_type = "image/png" }, -- "not-png"
			},
		}, { name = "probe" }, { session_id = "sess-1", max_bytes = 51200, max_lines = 2000, route_snapshot = snap })
		expect.eq(bad_mm.truncated, true)
		expect.eq(bad_mm.output_notice, nil)
		expect.eq(next(n10_storage.items), nil)
		expect.truthy(next(n10_storage.removed) ~= nil)
		expect.truthy(bad_mm.details.spill_error:find("magic header", 1, true))
		local m_bad = assert(n10_llm:measure(snap, bad_mm.content))
		expect.truthy(m_bad.tokens <= 120)

		-- N11: tight token budget limit = 72 where notice fits <= 72 while omission+notice exceeds 72
		local items_tight, removed_tight = {}, {}
		local long_path =
			"/tmp/spill-session-dir/owner-key-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef/h.txt"
		local n11_storage = {
			items = items_tight,
			removed = removed_tight,
			save = function(owner, content)
				local h = "h-" .. (#removed_tight + 1)
				items_tight[h] = { owner = owner, content = content }
				return {
					spill_id = h,
					size = #content,
					path = long_path,
					retrieval_hint = "Use read_spill with offset/limit, or read (offset/limit) / grep at "
						.. long_path
						.. ".",
				}
			end,
			save_bytes = function(owner, bytes)
				local h = "b-1"
				items_tight[h] = { owner = owner, content = bytes }
				return { spill_id = h, size = #bytes, path = "/tmp/s/b-1.txt" }
			end,
			delete = function(h)
				items_tight[h] = nil
				removed_tight[h] = true
			end,
		}
		local n11_llm = make_llm({ valid_snap = snap, image_tokens = 30 })
		local t_ctx, t_handlers = make_ctx(n11_storage, n11_llm)
		plugin.apply(t_ctx, {
			max_bytes = 51200,
			max_lines = 2000,
			max_inline_tokens = 72,
			cleanup_period_days = 30,
			exclude = {},
		})
		local huge_txt = string.rep("X", 2000)
		local t_out = t_handlers["tool/result"](
			{ content = huge_txt },
			{ name = "probe" },
			{ session_id = "sess-1", max_bytes = 51200, max_lines = 2000, route_snapshot = snap }
		)
		expect.truthy(t_out.truncated)
		expect.truthy(t_out.output_notice)
		local t_wire = t_out.content == "" and t_out.output_notice or (t_out.content .. "\n" .. t_out.output_notice)
		local m_t = assert(n11_llm:measure(snap, t_wire))
		expect.truthy(m_t.tokens <= 72)

		-- Multimodal at limit = 72: notice alone fits <= 72, omission+notice > 72 -> returns ONLY notice block
		local mm_n11 = t_handlers["tool/result"]({
			content = {
				{ type = "text", text = string.rep("Y", 1000) },
				{ type = "image", data = "iVBORw0KGgo=", mime_type = "image/png" },
			},
		}, { name = "probe" }, { session_id = "sess-1", max_bytes = 51200, max_lines = 2000, route_snapshot = snap })
		expect.truthy(mm_n11.truncated)
		expect.truthy(mm_n11.output_notice)
		expect.eq(#mm_n11.content, 1)
		expect.eq(mm_n11.content[1].text, mm_n11.output_notice)
		local m_mm72 = assert(n11_llm:measure(snap, mm_n11.content))
		expect.truthy(m_mm72.tokens <= 72)

		-- Notice cannot fit at all (limit = 20): revokes handles & returns explicit in-budget failure
		for k in pairs(items_tight) do
			items_tight[k] = nil
		end
		for k in pairs(removed_tight) do
			removed_tight[k] = nil
		end
		local too_tight_ctx, too_tight_handlers = make_ctx(n11_storage, n11_llm)
		plugin.apply(too_tight_ctx, {
			max_bytes = 51200,
			max_lines = 2000,
			max_inline_tokens = 20,
			cleanup_period_days = 30,
			exclude = {},
		})
		local orig_mm = {
			content = {
				{ type = "text", text = string.rep("Z", 200) },
				{ type = "image", data = "iVBORw0KGgo=", mime_type = "image/png" },
			},
		}
		local tight_fail = too_tight_handlers["tool/result"](
			orig_mm,
			{ name = "probe" },
			{ session_id = "sess-1", max_bytes = 51200, max_lines = 2000, route_snapshot = snap }
		)
		expect.truthy(tight_fail ~= orig_mm)
		expect.eq(tight_fail.is_error, true)
		expect.eq(tight_fail.error_code, "output_budget_exceeded")
		expect.eq(tight_fail.truncated, true)
		expect.eq(tight_fail.output_notice, nil)
		local m_fail = assert(n11_llm:measure(snap, tight_fail.content))
		expect.truthy(m_fail.tokens <= 20)
		expect.eq(next(items_tight), nil)
		expect.truthy(next(removed_tight) ~= nil)
	end)

	it("preserves UTF-8 boundaries in short-string truncations", function()
		-- Multi-byte UTF-8 straddling byte 117 in format_storage_error
		local err_msg = string.rep("a", 115) .. "🦀🦀tail"
		local err_notice = notice_mod.format_storage_error(100, 0, err_msg)
		expect.truthy(utf8.len(err_notice) ~= nil)
		expect.falsy(err_notice:find("\xF0", 1, true))

		-- Multi-byte UTF-8 straddling byte 40 in suggested_name
		local storage = make_storage()
		local res = retain(
			{ content = string.rep("x", 1000), suggested_name = string.rep("b", 38) .. "🦀extra" },
			{ session_id = "sess-1", max_bytes = 512, max_lines = 20 },
			{ max_bytes = 512, max_lines = 20 },
			storage
		)
		local sname = res.details.spill.suggested_name
		expect.truthy(utf8.len(sname) ~= nil)
		expect.eq(sname, string.rep("b", 38) .. ".txt")

		-- Multi-byte UTF-8 straddling byte 37 in read_spill summary
		local ctx = make_ctx(storage, make_llm())
		plugin.apply(ctx, {
			max_bytes = 51200,
			max_lines = 2000,
			cleanup_period_days = 30,
			exclude = support.default_config(plugin).exclude,
		})
		local summary = ctx.tools_registered.read_spill.summary({ handle = string.rep("c", 35) .. "🦀tail" })
		expect.truthy(utf8.len(summary) ~= nil)
		expect.eq(summary, "read_spill(" .. string.rep("c", 35) .. "...)")
	end)

	it("respects default powershell exclusion, spill_exempt, and details metadata fallback", function()
		local storage = make_storage()
		local ctx, handlers = make_ctx(storage, make_llm())
		local spill_cfg = {
			max_bytes = 512,
			max_lines = 20,
			cleanup_period_days = 30,
			exclude = support.default_config(plugin).exclude,
		}
		plugin.apply(ctx, spill_cfg)
		local big = string.rep("P", 2000)

		local ps_out = handlers["tool/result"]({ content = big }, { name = "powershell" }, { session_id = "sess-1" })
		expect.eq(ps_out.content, big)
		expect.eq(ps_out.output_notice, nil)

		local ps_out = handlers["tool/result"]({ content = big }, { name = "powershell" }, { session_id = "sess-1" })
		expect.eq(ps_out.content, big)
		expect.eq(ps_out.output_notice, nil)

		local ex_top = handlers["tool/result"](
			{ content = big, spill_exempt = true },
			{ name = "custom" },
			{ session_id = "sess-1" }
		)
		expect.eq(ex_top.content, big)
		expect.eq(ex_top.output_notice, nil)

		local ex_det = handlers["tool/result"](
			{ content = big, details = { spill_exempt = true } },
			{ name = "custom" },
			{ session_id = "sess-1" }
		)
		expect.eq(ex_det.content, big)
		expect.eq(ex_det.output_notice, nil)

		local det_meta = handlers["tool/result"]({
			content = big,
			details = {
				label = "detached-lbl",
				suggested_name = "detached-report",
				spill_source = { kind = "session-reference", session_id = "sess-p" },
			},
		}, { name = "custom", id = "call-det" }, { session_id = "sess-1", max_bytes = 512, max_lines = 20 })
		expect.eq(det_meta.details.spill.suggested_name, "detached-report.txt")
		expect.eq(det_meta.details.spill.source.kind, "session-reference")
		expect.eq(det_meta.details.spill.source.session_id, "sess-p")

		spill_cfg.exclude = { "powershell", "custom" }
		local custom_excluded = handlers["tool/result"](
			{ content = big },
			{ name = "custom" },
			{ session_id = "sess-1" }
		)
		expect.eq(custom_excluded.content, big)
		expect.eq(custom_excluded.output_notice, nil)
	end)

	it("replays string and multimodal results at tighter budgets without re-saving", function()
		local snap = { id = "snap-replay" }
		local llm = make_llm({ valid_snap = snap, image_tokens = 35 })
		local storage = make_storage()

		-- String saved at 200 tokens, replayed at 80 tokens -> trimmed without second save
		local s_res = retain(
			{ content = "H:" .. string.rep("a", 1500) .. ":T" },
			{ session_id = "sess-1", max_bytes = 51200, max_lines = 2000, route_snapshot = snap },
			{ max_bytes = 51200, max_lines = 2000, max_inline_tokens = 200 },
			storage,
			llm
		)
		local wire_saved = s_res.content .. "\n" .. s_res.output_notice
		local saves_before = 0
		for _ in pairs(storage.items) do
			saves_before = saves_before + 1
		end
		local s_replay = retain(
			{ content = wire_saved },
			{ session_id = "sess-1", max_bytes = 51200, max_lines = 2000, route_snapshot = snap },
			{ max_bytes = 51200, max_lines = 2000, max_inline_tokens = 80 },
			storage,
			llm
		)
		local saves_after = 0
		for _ in pairs(storage.items) do
			saves_after = saves_after + 1
		end
		expect.eq(saves_before, saves_after)
		expect.eq(s_replay.output_notice, s_res.output_notice)
		expect.eq(s_replay.truncated, true)
		local m_sr = assert(llm:measure(snap, s_replay.content .. "\n" .. s_replay.output_notice))
		expect.truthy(m_sr.tokens <= 80)

		-- Multimodal saved at 220 tokens, replayed at 95 tokens -> re-trimmed without re-saving, notice kept at end
		local mm_res = retain(
			{
				content = {
					{ type = "text", text = "HEAD:" .. string.rep("A", 100) },
					{ type = "image", data = "iVBORw0KGgo=", mime_type = "image/png" },
					{ type = "text", text = string.rep("M", 900) },
					{ type = "image", data = "/9j/4AAQ", mime_type = "image/jpeg" },
					{ type = "text", text = "TAIL:" .. string.rep("Z", 100) },
				},
			},
			{ session_id = "sess-1", max_bytes = 51200, max_lines = 2000, route_snapshot = snap },
			{ max_bytes = 51200, max_lines = 2000, max_inline_tokens = 220 },
			storage,
			llm
		)
		local mm_saves_before = 0
		for _ in pairs(storage.items) do
			mm_saves_before = mm_saves_before + 1
		end
		local mm_replay = retain(
			{ content = mm_res.content },
			{ session_id = "sess-1", max_bytes = 51200, max_lines = 2000, route_snapshot = snap },
			{ max_bytes = 51200, max_lines = 2000, max_inline_tokens = 95 },
			storage,
			llm
		)
		local mm_saves_after = 0
		for _ in pairs(storage.items) do
			mm_saves_after = mm_saves_after + 1
		end
		expect.eq(mm_saves_before, mm_saves_after)
		expect.eq(next(storage.removed), nil)
		expect.eq(mm_replay.output_notice, mm_res.output_notice)
		expect.eq(mm_replay.truncated, true)
		expect.eq(mm_replay.content[#mm_replay.content].text, mm_replay.output_notice)
		local m_mmr = assert(llm:measure(snap, mm_replay.content))
		expect.truthy(m_mmr.tokens <= 95)

		-- Adjacent body text blocks merge before the final separate notice block
		expect.truthy(#mm_replay.content <= 2)
	end)

	it("handles tiny valid budget (16) and custom measurer failure paths", function()
		local snap, big_1k, E = { id = "snap-custom" }, string.rep("B", 1000), "output_budget_exceeded"
		local b_arg = { session_id = "sess-1", max_bytes = 51200, max_lines = 2000, route_snapshot = snap }
		local function make_custom_llm(mode)
			return {
				measure = function(_, r, content)
					assert(r == snap)
					assert(mode ~= "throw_err", "custom estimator threw")
					if mode == "return_err" then
						return nil, "custom estimator failed"
					end
					local blks = type(content) == "string" and { { type = "text", text = content } } or content
					local mb, total = {}, 0
					for i, b in ipairs(blks) do
						local t = mode == "always_over" and 20 or (b.type == "text" and #b.text or 10)
						total, mb[i] = total + t, { index = i, kind = b.type, tokens = t }
					end
					return { tokens = total, estimated = true, method = "custom-1char", blocks = mb }
				end,
			}
		end
		local function apply_with(storage, llm, limit)
			local ctx, handlers = make_ctx(storage, llm)
			local cfg = {
				max_bytes = 51200,
				max_lines = 2000,
				max_inline_tokens = limit,
				cleanup_period_days = 30,
				exclude = {},
			}
			plugin.apply(ctx, cfg)
			return ctx, handlers["tool/result"]
		end

		local n_llm = make_custom_llm("normal")
		local n_out = select(2, apply_with(make_storage(), n_llm, 120))({ content = big_1k }, { name = "probe" }, b_arg)
		expect.truthy(n_out.truncated)
		expect.truthy(n_out.output_notice)
		expect.truthy(assert(n_llm:measure(snap, n_out.content .. "\n" .. n_out.output_notice)).tokens <= 120)

		local t_stor = make_storage()
		local t_out = select(2, apply_with(t_stor, n_llm, 16))({ content = big_1k }, { name = "probe" }, b_arg)
		expect.truthy(t_out.content ~= big_1k)
		expect.truthy(t_out.is_error)
		expect.eq(t_out.error_code, E)
		expect.truthy(t_out.truncated)
		expect.eq(t_out.output_notice, nil)
		expect.eq(next(t_stor.items), nil)
		expect.truthy(assert(n_llm:measure(snap, t_out.content)).tokens <= 16)

		local o_ctx, o_on = apply_with(t_stor, make_custom_llm("always_over"), 16)
		for _, inp in ipairs({ big_1k, { { type = "text", text = big_1k } } }) do
			local ok, out = pcall(o_on, { content = inp }, { name = "probe" }, b_arg)
			expect.truthy(ok)
			expect.truthy(out.is_error)
			expect.eq(out.error_code, E)
			expect.truthy(out.truncated)
			expect.eq(out.output_notice, nil)
			expect.eq(next(t_stor.items), nil)
			expect.truthy(#o_ctx.logs >= 1)
			expect.eq(out.details.error_code, E)
			expect.truthy(out.details.spill_error:find("output budget", 1, true))
			expect.eq(type(out.content), type(inp))
			expect.truthy(type(inp) == "table" and #out.content == 0 or out.content == "")
		end

		for _, fm in ipairs({ "return_err", "throw_err" }) do
			local f_stor = make_storage()
			local f_ctx, f_on = apply_with(f_stor, make_custom_llm(fm), 100)
			local f_res = f_on({ content = big_1k }, { name = "probe" }, b_arg)
			expect.truthy(f_res.truncated)
			expect.truthy(f_res.content ~= big_1k)
			expect.truthy(f_res.output_notice)
			expect.truthy(mare.text.tokens(f_res.content .. "\n" .. f_res.output_notice) <= 100)
			expect.truthy(next(f_stor.items) ~= nil)
			expect.truthy(#f_ctx.logs >= 1)
			expect.eq(f_ctx.logs[1].level, "warn")

			local dense_cjk = string.rep("中", 160)
			local f_dense = f_on({ content = dense_cjk }, { name = "probe" }, b_arg)
			expect.truthy(f_dense.truncated)
			expect.truthy(f_dense.content ~= dense_cjk)
			expect.truthy(f_dense.output_notice)
			expect.truthy(mare.text.tokens(f_dense.content .. "\n" .. f_dense.output_notice) <= 100)
		end
	end)

	it("uses mare.text.tokens in fallback measurement instead of a second byte estimator", function()
		local calls = 0
		mare.text.tokens = function(s)
			calls = calls + 1
			return math.ceil(#s / 4)
		end

		local under_budget = string.rep("!@#$;", 30) -- 150 bytes; mare.text.tokens = 38 <= 100
		local over_budget = string.rep("中", 160) -- 480 bytes; mare.text.tokens = 120 > 100

		local mfn = budget.build_measure_fn(nil, nil)
		local mp = mfn(under_budget)
		expect.eq(mp.method, "fallback-tokens")
		expect.eq(mp.tokens, 38)
		local mc = mfn(over_budget)
		expect.eq(mc.method, "fallback-tokens")
		expect.eq(mc.tokens, 120)
		expect.truthy(calls >= 2)

		local snap = { id = "snap-lz156" }
		local failing_llm = {
			measure = function()
				return nil, "measure failed"
			end,
		}
		for _, llm_case in ipairs({
			{ llm = nil, arg = { session_id = "sess-1", max_bytes = 51200, max_lines = 2000 } },
			{
				llm = failing_llm,
				arg = { session_id = "sess-1", max_bytes = 51200, max_lines = 2000, route_snapshot = snap },
			},
		}) do
			local stor = make_storage()
			local ctx, handlers = make_ctx(stor, llm_case.llm)
			plugin.apply(ctx, {
				max_bytes = 51200,
				max_lines = 2000,
				max_inline_tokens = 100,
				cleanup_period_days = 30,
				exclude = {},
			})
			local kept = handlers["tool/result"]({ content = under_budget }, { name = "probe" }, llm_case.arg)
			expect.falsy(kept.truncated)
			expect.eq(kept.content, under_budget)

			local res = handlers["tool/result"]({ content = over_budget }, { name = "probe" }, llm_case.arg)
			expect.eq(res.truncated, true)
			expect.truthy(res.content ~= over_budget)
			expect.truthy(res.output_notice ~= nil)
			expect.truthy(mare.text.tokens(res.content .. "\n" .. res.output_notice) <= 100)
		end
	end)

	it("uses mare.spill.new_local with dispose on custom root and rejects unknown backend", function()
		local stor = make_storage({ prefix = "l-" })
		local ctx, handlers = make_ctx(make_storage(), make_llm(), stor)
		plugin.apply(ctx, {
			max_bytes = 51200,
			max_lines = 2000,
			cleanup_period_days = 7,
			root = "/tmp/custom-spill-root",
			exclude = {},
		})
		local res = handlers["tool/result"](
			{ content = string.rep("X", 60000) },
			{ name = "probe" },
			{ session_id = "sess-1", max_bytes = 51200, max_lines = 2000 }
		)
		expect.eq(res.truncated, true)
		for _, cb in ipairs(ctx.dispose_cbs) do
			cb()
		end
		expect.eq(stor.disposed, 1)

		local bad_ctx = make_ctx(make_storage(), make_llm())
		expect.error(function()
			plugin.apply(bad_ctx, {
				max_bytes = 51200,
				max_lines = 2000,
				cleanup_period_days = 30,
				backend = "missing-backend",
				exclude = {},
			})
		end)
	end)
	-- With spill.root set, handles saved by other
	-- producers (session-search events, mermaid artifacts) live in the default store; read_spill
	-- must still return them, and keep the configured store's own error when neither has it.
	it("read_spill reads default-store handles under a custom root and keeps the real error", function()
		local default_store = make_storage({ prefix = "ev-", name = "default" })
		local custom = make_storage({ prefix = "l-", name = "custom root" })
		local ctx, handlers = make_ctx(default_store, make_llm(), custom)
		plugin.apply(ctx, {
			max_bytes = 51200,
			max_lines = 2000,
			cleanup_period_days = 30,
			root = "/tmp/custom-spill-root",
			exclude = {},
		})
		local event = mare.spill.save("sess-1", "EVENT-BODY") -- as session-search saves a large event
		local res = handlers["tool/result"](
			{ content = string.rep("X", 60000) },
			{ name = "probe" },
			{ session_id = "sess-1", max_bytes = 51200, max_lines = 2000 }
		)
		expect.eq(res.truncated, true)
		local own = next(custom.items)
		local read_spill = ctx.tools_registered.read_spill
		expect.eq(read_spill.execute({ handle = event.spill_id }).content, "EVENT-BODY")
		expect.eq(read_spill.execute({ handle = own }).content, string.rep("X", 60000))
		local ok, err = pcall(read_spill.execute, { handle = "ev-missing" })
		expect.eq(ok, false)
		expect.truthy(tostring(err):find("custom root: missing spill_id", 1, true))

		-- a real failure of the configured store is reported as is
		local failing = make_storage({ prefix = "l-", fail_read = "EACCES: permission denied" })
		local ctx2 = make_ctx(make_storage({ prefix = "ev-" }), make_llm(), failing)
		plugin.apply(
			ctx2,
			{ max_bytes = 51200, max_lines = 2000, cleanup_period_days = 30, root = "/tmp/r", exclude = {} }
		)
		local ok2, err2 = pcall(ctx2.tools_registered.read_spill.execute, { handle = "l-1" })
		expect.eq(ok2, false)
		expect.truthy(tostring(err2):find("EACCES", 1, true))
	end)

	it("trims 2300 multimodal text blocks equivalently to linear budget assembly", function()
		local blocks = {
			{ type = "text", text = "HEAD-0" },
			{ type = "image", data = "iVBORw0KGgo=", mime_type = "image/png" },
		}
		for i = 1, 2300 do
			local body = (i % 50 == 0) and ("L" .. i .. "\n") or "x"
			blocks[#blocks + 1] = { type = "text", text = body .. string.rep("y", 29) }
		end
		blocks[#blocks + 1] = { type = "text", text = "" }
		blocks[#blocks + 1] = { type = "image", data = "iVBORw0KGgo=", mime_type = "image/png" }
		blocks[#blocks + 1] = { type = "text", text = "TAIL-END" }

		local notice = "[Complete tool output (5000 bytes): h-2300. Use read_spill with offset/limit.]"
		local out = budget.retain_multimodal(blocks, notice, nil, 51200, 2000, nil, nil)
		expect.truthy(#out >= 3)
		expect.eq(out[#out].text, notice)

		local txt_bytes, txt_lines, has_omission = 0, 0, false
		for _, b in ipairs(out) do
			if b.type == "text" then
				txt_bytes = txt_bytes + #b.text
				txt_lines = txt_lines + budget.count_lines(b.text)
				if b.text:find("omitted", 1, true) then
					has_omission = true
				end
			end
		end
		expect.truthy(txt_bytes <= 51200)
		expect.truthy(txt_lines <= 2000)
		expect.truthy(has_omission)
		expect.eq(out[1].text, "HEAD-0")
		expect.eq(out[2].type, "image")
		expect.eq(out[#out - 1].text, "TAIL-END")
		expect.eq(out[#out - 2].type, "image")

		-- Also verify 2300 single-char blocks (exceeding max_lines=2000) fits lines & bytes and includes omission + notice.
		local small_blocks = { { type = "image", data = "iVBORw0KGgo=", mime_type = "image/png" } }
		for i = 1, 2300 do
			small_blocks[#small_blocks + 1] = { type = "text", text = "x" }
		end
		local out_small = budget.retain_multimodal(small_blocks, notice, nil, 51200, 2000, nil, nil)
		local s_bytes, s_lines = 0, 0
		for _, b in ipairs(out_small) do
			if b.type == "text" then
				s_bytes = s_bytes + #b.text
				s_lines = s_lines + budget.count_lines(b.text)
			end
		end
		expect.truthy(s_bytes <= 51200)
		expect.truthy(s_lines <= 2000)
		expect.eq(out_small[#out_small].text, notice)

		-- Also verify exact omission byte/image counts with token measurement on 2300 blocks.
		local total_text_bytes = 0
		for _, b in ipairs(blocks) do
			if b.type == "text" then
				total_text_bytes = total_text_bytes + #b.text
			end
		end
		local mfn = budget.build_measure_fn(nil, nil)
		local measured = mfn(blocks)
		local out_tok = budget.retain_multimodal(blocks, notice, 600, 51200, 2000, measured, mfn)
		local tok_m = assert(mfn(out_tok))
		expect.truthy(tok_m.tokens <= 600)
		expect.eq(out_tok[#out_tok].text, notice)
		expect.eq(#out_tok, 2)
		local expected_ob = total_text_bytes - (#"HEAD-0" + #"TAIL-END")
		expect.eq(
			out_tok[1].text,
			"HEAD-0\n" .. ("[... omitted %d bytes, 2 images ...]"):format(expected_ob) .. "\nTAIL-END"
		)

		-- Also verify token-limited trimming that keeps 1 image and omits 1 image + exact text bytes.
		local blocks_img = {}
		for i = 1, #blocks - 1 do
			blocks_img[i] = blocks[i]
		end
		blocks_img[#blocks] = { type = "text", text = "TAIL-END-PADDING" }
		local img_total_bytes = total_text_bytes - #"TAIL-END" + #"TAIL-END-PADDING"
		local snap_tok = { id = "snap-2300-img" }
		local llm_tok = make_llm({ valid_snap = snap_tok, image_tokens = 100 })
		local mfn_img = budget.build_measure_fn(llm_tok, snap_tok)
		local measured_img = mfn_img(blocks_img)
		local out_img_tok = budget.retain_multimodal(blocks_img, notice, 260, 51200, 2000, measured_img, mfn_img)
		local img_m = assert(mfn_img(out_img_tok))
		expect.truthy(img_m.tokens <= 260)
		expect.eq(out_img_tok[#out_img_tok].text, notice)
		local kept_images = 0
		local omitted_str
		for _, b in ipairs(out_img_tok) do
			if b.type == "image" then
				kept_images = kept_images + 1
			elseif b.type == "text" then
				local match = b.text:match("%[%.%.%. omitted %d+ bytes[^%]]*%]")
				if match then
					omitted_str = match
				end
			end
		end
		expect.eq(kept_images, 1)
		local ob_str, oi_str = omitted_str:match("^%[%.%.%. omitted (%d+) bytes, (%d+) images %.%.%.%]$")
		expect.eq(tonumber(oi_str), 2 - kept_images)
		local kept_text_bytes = #"HEAD-0"
		for _, b in ipairs(out_img_tok) do
			if b.type == "text" and b.text ~= notice and b.text ~= "HEAD-0" then
				-- Strip omission line and the "\n" joiner if merged with tail text.
				local without_om = b.text:gsub("^%[%.%.%. omitted %d+ bytes, %d+ images %.%.%.%]\n?", "")
				kept_text_bytes = kept_text_bytes + #without_om
			end
		end
		expect.eq(tonumber(ob_str), img_total_bytes - kept_text_bytes)
	end)

	it(
		"sets no_truncate on multimodal spill, aligns trailing-newline count_lines, and normalizes save source",
		function()
			local storage = make_storage()
			local ctx, handlers = make_ctx(storage, make_llm())
			plugin.apply(ctx, {
				max_bytes = 512,
				max_lines = 5,
				cleanup_period_days = 30,
				exclude = {},
			})

			-- Multimodal spilled output marks no_truncate = true
			local mm_res = handlers["tool/result"]({
				content = {
					{ type = "text", text = string.rep("M", 1200) },
					{ type = "image", data = "iVBORw0KGgo=", mime_type = "image/png" },
				},
			}, { name = "probe" }, { session_id = "sess-1", tool_call_id = "c-mm", max_bytes = 512, max_lines = 5 })
			expect.eq(mm_res.no_truncate, true)
			expect.truthy(type(mm_res.content) == "table")

			-- count_lines matches core tools/results.lua (0 for empty, nl + 1 otherwise)
			expect.eq(budget.count_lines(""), 0)
			expect.eq(budget.count_lines("a\n"), 2)
			expect.eq(budget.count_lines("a\nb"), 2)
			expect.eq(budget.count_lines("a\nb\n"), 3)

			-- spill_source normalizes session_reference -> session-reference and strips non-schema fields
			local sr_res = handlers["tool/result"]({
				content = string.rep("S", 1200),
				spill_source = {
					kind = "session_reference",
					session_id = "sess-1",
					label = "ev",
					extra = "strip-me",
				},
			}, { name = "probe" }, { session_id = "sess-1", tool_call_id = "c1", max_bytes = 512, max_lines = 5 })
			local saved_sr = storage.items[sr_res.details.spill.handle]
			expect.eq(saved_sr.opts.source.kind, "session-reference")
			expect.eq(saved_sr.opts.source.session_id, "sess-1")
			expect.eq(saved_sr.opts.source.label, "ev")
			expect.eq(saved_sr.opts.source.extra, nil)
		end
	)
end)
