local support = assert(load(mare.fs.read("tests/specs/support.lua"), "@tests/specs/support.lua"))()

local describe = mare.test.describe
local it = mare.test.it
local before_each = mare.test.before_each
local after_each = mare.test.after_each
local expect = mare.test.expect

local plugin = support.load_plugin("session-search", {
	"session_search.schema",
	"session_search.view",
})
local spill_plugin =
	support.load_plugin("tool-spill", { "spill.budget", "spill.media", "spill.notice", "spill.retain" })
local schema = require("session_search.schema")
local view = require("session_search.view")

local function clone(t)
	local out = {}
	for k, v in pairs(t) do
		out[k] = v
	end
	return out
end

describe("session-search", function()
	local tools, section, events, invalidations
	local spilled_items, removed_handles, output_counter
	local available_backends, output_save_hook
	local activity, supports_map, query_handler
	local orig_spill
	local ctx

	before_each(function()
		tools, section, events, invalidations = {}, nil, {}, 0
		spilled_items, removed_handles, output_counter = {}, {}, 0
		orig_spill = mare.spill
		mare.spill = {
			save = function(owner, content, opts)
				expect.eq(type(owner), "string")
				expect.truthy(owner ~= "")
				if output_save_hook then
					output_save_hook(owner, content, opts)
				end
				output_counter = output_counter + 1
				local spill_id = "spill:v1:local:ns:h" .. output_counter
				spilled_items[spill_id] = {
					owner = owner,
					content = content,
					backend = "local",
					opts = opts,
				}
				return {
					spill_id = spill_id,
					size = #content,
					retrieval_hint = "Use read_spill with offset/limit.",
					source = opts and opts.source or nil,
				}
			end,
			read = function(spill_id, opts)
				local owner = opts and opts.session_id
				local item = assert(spilled_items[spill_id], "missing spill locator")
				assert(item.owner == owner, "spill locator belongs to another session")
				return { content = item.content, more = false, next_byte = #item.content }
			end,
			delete = function(spill_id, opts)
				local owner = opts and opts.session_id
				local item = spilled_items[spill_id]
				if item and item.owner == owner then
					spilled_items[spill_id] = nil
					removed_handles[spill_id] = true
				end
			end,
		}
		available_backends = { ["local"] = true, archive = true }
		output_save_hook = nil
		activity = { session_id = "main-session" }
		supports_map = {
			["session.search"] = true,
			["session.events"] = true,
			["session.trace"] = true,
			["session.event_trace"] = true,
			["session.read"] = true,
		}
		query_handler = nil

		-- mare.subagent.identity is the real core function (not stubbed): the plugin must not rely on a
		-- no-argument form, which raises "nil to u64" (every tool call failed on core main)
		ctx = {
			agent = {
				activity = function()
					return activity
				end,
			},
			tools = {
				register = function(_, name, def)
					tools[name] = def
				end,
			},
			context = {
				section = function(_, def)
					section = def
				end,
				invalidate = function()
					invalidations = invalidations + 1
				end,
			},
			query = {
				supports = function(_, op)
					return supports_map[op] == true
				end,
				call = function(_, op, req, opts)
					return query_handler(op, req, opts)
				end,
			},
			on = function(_, name, fn)
				events[name] = fn
			end,
		}

		plugin.apply(ctx, { max_search_results = 3, search_timeout_ms = 5000, backend = "" })
	end)

	after_each(function()
		mare.spill = orig_spill
	end)

	it("validates config, service contracts, tool schemas, and context gating", function()
		expect.eq(plugin.config_schema.max_search_results.type, "integer")
		expect.eq(plugin.config_schema.max_search_results.min, 1)
		expect.eq(plugin.config_schema.search_timeout_ms.type, "integer")
		expect.eq(plugin.config_schema.search_timeout_ms.min, 1)
		expect.eq(plugin.config_schema.backend.type, "string")
		expect.eq(plugin.config_schema.backend.default, "")

		local bad_ctx = clone(ctx)
		bad_ctx.agent = {}
		expect.error(function()
			plugin.apply(bad_ctx, { max_search_results = 3, search_timeout_ms = 5000, backend = "" })
		end)

		local saved_spill = mare.spill
		mare.spill = nil
		expect.error(function()
			plugin.apply(ctx, { max_search_results = 3, search_timeout_ms = 5000, backend = "" })
		end)
		mare.spill = saved_spill

		for _, name in ipairs({
			"session_search",
			"session_event_search",
			"session_trace",
			"session_event_trace",
			"session_event_read",
		}) do
			expect.truthy(tools[name])
			expect.eq(tools[name].side_effect, "read")
			expect.eq(tools[name].idempotent, true)
			local s = schema[name]
			expect.eq(s.additionalProperties, false)
			expect.falsy(s.properties.cursor)
			expect.falsy(s.properties.limit)
			expect.falsy(s.properties.cwd)
		end

		expect.eq(tools.session_search.concurrency_safe, false)
		expect.eq(tools.session_search.timeout_ms, 5000)
		expect.eq(tools.session_event_search.concurrency_safe, false)
		expect.eq(tools.session_event_search.timeout_ms, 5000)
		expect.eq(tools.session_trace.concurrency_safe, true)
		expect.eq(tools.session_trace.timeout_ms, nil)
		expect.eq(tools.session_event_read.concurrency_safe, true)

		expect.eq(tools.session_search.summary({ query = "foo" }), "Search history: foo")
		expect.eq(tools.session_event_read.summary({ event_id = "ev1" }), "Read history: event")
		expect.eq(tools.session_trace.summary({}), "Trace session: current")
		expect.eq(tools.session_trace.summary({ session_id = "s9" }), "Trace session: s9")
		expect.eq(tools.session_event_trace.summary({ seq = 4 }), "Trace event: seq 4")

		expect.truthy(tools.session_search.enabled())
		supports_map["session.search"] = false
		expect.falsy(tools.session_search.enabled())
		expect.truthy(section.when())
		for k in pairs(supports_map) do
			supports_map[k] = false
		end
		expect.falsy(section.when())
		events["query/changed"]()
		expect.eq(invalidations, 1)
	end)

	it("handles pagination, cap overflow, cursor guards, and query forwarding", function()
		local calls = 0
		query_handler = function(op, req)
			expect.eq(op, "session.search")
			calls = calls + 1
			if not req.cursor then
				expect.eq(req.filters.exclude_session_ids[1], "main-session")
				return {
					provider = "p1",
					corpus_revision = "g1",
					data = { { session_id = "s1" }, { session_id = "s2" } },
					next_cursor = "c1",
					coverage = { live = false },
				}
			elseif req.cursor == "c1" then
				return {
					provider = "p1",
					corpus_revision = "g1",
					data = { { session_id = "s3" } },
					next_cursor = nil,
					coverage = { live = false },
				}
			end
			error("unexpected cursor")
		end
		local exact = tools.session_search.execute({ query = "needle" })
		expect.falsy(exact.is_error)
		expect.eq(#exact.details.data, 3)
		expect.eq(exact.details.capped, false)
		expect.eq(calls, 2)

		-- Overflow on 4th hit sets capped = true
		calls = 0
		query_handler = function(_, req)
			calls = calls + 1
			if not req.cursor then
				return {
					provider = "p1",
					corpus_revision = "g1",
					data = { { session_id = "s1" }, { session_id = "s2" }, { session_id = "s3" } },
					next_cursor = "c1",
				}
			end
			return {
				provider = "p1",
				corpus_revision = "g1",
				data = { { session_id = "s4" } },
				incomplete = true,
			}
		end
		local capped = tools.session_search.execute({ query = "needle" })
		expect.falsy(capped.is_error)
		expect.eq(#capped.details.data, 3)
		expect.eq(capped.details.capped, true)
		expect.truthy(capped.details.incomplete)

		-- Stale cursor when corpus_revision changes across pages
		query_handler = function(_, req)
			if not req.cursor then
				return { provider = "p1", corpus_revision = "g1", data = { { session_id = "s1" } }, next_cursor = "c1" }
			end
			return { provider = "p1", corpus_revision = "g2", data = { { session_id = "s2" } } }
		end
		local stale = tools.session_search.execute({ query = "needle" })
		expect.truthy(stale.is_error)
		expect.eq(stale.error_code, "QUERY_STALE_CURSOR")

		-- Repeated continuation cursor rejected
		query_handler = function()
			return { provider = "p1", corpus_revision = "g1", data = { { session_id = "s1" } }, next_cursor = "loop" }
		end
		local repeated = tools.session_search.execute({ query = "needle" })
		expect.truthy(repeated.is_error)
		expect.eq(repeated.error_code, "QUERY_INVALID_CURSOR")

		-- Empty intermediate page continues pagination via cursor
		calls = 0
		query_handler = function(_, req)
			calls = calls + 1
			if not req.cursor then
				return { provider = "p1", corpus_revision = "g1", data = {}, next_cursor = "c-empty" }
			elseif req.cursor == "c-empty" then
				return {
					provider = "p1",
					corpus_revision = "g1",
					data = { { session_id = "s-after-empty", event_id = "ev-ae", position = { seq = 1 } } },
				}
			end
			error("unexpected cursor")
		end
		local after_empty = tools.session_search.execute({ query = "needle" })
		expect.falsy(after_empty.is_error)
		expect.eq(calls, 2)
		expect.eq(#after_empty.details.data, 1)

		-- exclude_session_ids deduplicates caller_id and activity.session_id
		activity.session_id = "main-session"
		query_handler = function(_, req)
			expect.eq(#req.filters.exclude_session_ids, 1)
			expect.eq(req.filters.exclude_session_ids[1], "main-session")
			return { provider = "p1", corpus_revision = "g1", data = {} }
		end
		local dedup = tools.session_search.execute({ query = "needle" })
		expect.falsy(dedup.is_error)
		activity.session_id = "main-session"

		-- session_event_search forwards step_bound when targeting current session
		query_handler = function(op, req)
			expect.eq(op, "session.events")
			expect.eq(req.step_bound, true)
			error("QUERY_CAPABILITY_UNAVAILABLE: current-session step-bound observation is unavailable", 0)
		end
		local self_ev = tools.session_event_search.execute({ query = "x" })
		expect.truthy(self_ev.is_error)
		expect.eq(self_ev.error_code, "QUERY_CAPABILITY_UNAVAILABLE")

		activity.session_id = "child-1"
		local child_self_ev = tools.session_event_search.execute({ session_id = "child-1", query = "x" })
		expect.truthy(child_self_ev.is_error)
		expect.eq(child_self_ev.error_code, "QUERY_CAPABILITY_UNAVAILABLE")
		activity.session_id = "main-session"

		query_handler = function(op, req)
			expect.eq(op, "session.events")
			expect.eq(req.session_id, "main-session")
			expect.eq(req.step_bound, true)
			return {
				provider = "live-sessions",
				corpus_revision = "g-live",
				data = {
					{ session_id = "main-session", event_id = "ev-live", position = { seq = 2 }, surface = "current" },
				},
				coverage = { persisted = true, live = true },
			}
		end
		local live_self = tools.session_event_search.execute({ query = "prior" })
		expect.falsy(live_self.is_error)
		expect.eq(#live_self.details.data, 1)
		expect.eq(live_self.details.data[1].surface, "current")

		-- session_search forwards title_query, sort_key, and sort_direction
		query_handler = function(op, req)
			expect.eq(op, "session.search")
			expect.eq(req.title_query, "roadmap")
			expect.eq(req.sort_key, "updated_at_ms")
			expect.eq(req.sort_direction, "asc")
			return {
				provider = "live-sessions",
				corpus_revision = "g-title",
				data = { { session_id = "s-road", title = "Q4 Roadmap", event_id = "ev-r", position = { seq = 3 } } },
			}
		end
		local title_res = tools.session_search.execute({
			title_query = "roadmap",
			sort_key = "updated_at_ms",
			sort_direction = "asc",
		})
		expect.falsy(title_res.is_error)
		expect.eq(title_res.details.data[1].session_id, "s-road")

		-- session_event_trace forwards session_id and seq
		query_handler = function(op, req)
			expect.eq(op, "session.event_trace")
			expect.eq(req.session_id, "main-session")
			expect.eq(req.seq, 2)
			return {
				session_id = "main-session",
				seq = 2,
				type = "message",
				surface = "shadowed",
				replaced_by = 4,
				replacement_chain = { 4, 7 },
				source_event_seqs = { 1 },
				derived_event_seqs = { 4 },
				summary = "old msg",
			}
		end
		local ev_traced = tools.session_event_trace.execute({ seq = 2 })
		expect.falsy(ev_traced.is_error)
		expect.eq(ev_traced.details.surface, "shadowed")
	end)

	it("handles chunked read spill, ownership, backend routing, and cancellation", function()
		local big_chunks = { '{"type":"message",', '"content":"huge"}' }
		query_handler = function(op, req)
			expect.eq(op, "session.read")
			if not req.max_bytes then
				error("QUERY_EVENT_TOO_LARGE: event exceeds 64 KiB inline limit", 0)
			end
			if req.offset == 0 then
				return {
					session_id = "s1",
					corpus_revision = "g1",
					seq = 9,
					chunk = big_chunks[1],
					next_offset = #big_chunks[1],
					total_bytes = #big_chunks[1] + #big_chunks[2],
					neighbors = { { seq = 8, type = "message", summary = "before" } },
				}
			end
			return {
				session_id = "s1",
				corpus_revision = "g1",
				seq = 9,
				chunk = big_chunks[2],
				next_offset = nil,
				total_bytes = #big_chunks[1] + #big_chunks[2],
			}
		end

		local spilled = tools.session_event_read.execute(
			{ event_id = "big-1", before = 1 },
			{ tool_call_id = "call-1" }
		)
		expect.falsy(spilled.is_error)
		expect.eq(spilled.spill_exempt, true)
		expect.eq(spilled.details.spilled, true)
		expect.eq(spilled.details.backend, "local")
		expect.eq(spilled.details.retrieval_hint, "Use read_spill with offset/limit.")
		expect.eq(spilled.details.source.kind, "tool")
		expect.eq(spilled.details.source.tool_call_id, "call-1")
		expect.eq(spilled.details.truncated, false)
		expect.eq(spilled.details.neighbors[1].seq, 8)
		expect.eq(
			mare.spill.read(spilled.details.handle, { session_id = "main-session" }).content,
			table.concat(big_chunks)
		)
		-- the handle is opaque: the recovery path the model is told to use is the spill plugin's
		-- read_spill tool, so read it back through that tool.
		local spill_tools = {}
		spill_plugin.apply({
			on = function() end,
			log = function() end,
			llm = {},
			tools = {
				register = function(_, name, def)
					spill_tools[name] = def
				end,
			},
			session = {
				info = function()
					return { session_id = "main-session" }
				end,
			},
		}, { max_bytes = 51200, max_lines = 2000, cleanup_period_days = 30, exclude = {} })
		expect.eq(spill_tools.read_spill.execute({ handle = spilled.details.handle }).content, table.concat(big_chunks))
		expect.error(function()
			mare.spill.read(spilled.details.handle, { session_id = "other-session" })
		end)

		-- Child session ownership binds spilled handle to child_session_id
		activity.session_id = "child-owner"
		local child_spilled = tools.session_event_read.execute({ event_id = "big-1" })
		expect.falsy(child_spilled.is_error)
		expect.eq(child_spilled.details.source.kind, "session-reference")
		expect.eq(
			mare.spill.read(child_spilled.details.handle, { session_id = "child-owner" }).content,
			table.concat(big_chunks)
		)
		expect.error(function()
			mare.spill.read(child_spilled.details.handle, { session_id = "main-session" })
		end)
		activity.session_id = "main-session"

		-- Restricted read policy during spill save rejects cleanly as QUERY_UNAUTHORIZED
		output_save_hook = function()
			error("sandbox: recovery storage is not readable under the current policy")
		end
		local denied_spill = tools.session_event_read.execute({ event_id = "big-1" })
		expect.truthy(denied_spill.is_error)
		expect.eq(denied_spill.error_code, "QUERY_UNAUTHORIZED")
		output_save_hook = nil

		-- Mid-save cancellation cleans up handle via mare.spill.delete and returns QUERY_CANCELLED
		local mid_tok = mare.task.token()
		output_save_hook = function()
			mid_tok:cancel()
		end
		local mid_cancel = tools.session_event_read.execute({ event_id = "big-1" }, { cancel = mid_tok })
		output_save_hook = nil
		local last_handle = "spill:v1:local:ns:h" .. output_counter
		expect.truthy(mid_cancel.is_error)
		expect.eq(mid_cancel.error_code, "QUERY_CANCELLED")
		expect.eq(mid_cancel.cancelled, true)
		expect.eq(removed_handles[last_handle], true)
		expect.error(function()
			mare.spill.read(last_handle, { session_id = "main-session" })
		end)

		-- Local backend works via mare.spill; non-local custom backend fails with QUERY_CAPABILITY_UNAVAILABLE.
		plugin.apply(ctx, { max_search_results = 3, search_timeout_ms = 5000, backend = "local" })
		local local_spilled = tools.session_event_read.execute({ event_id = "big-1" })
		expect.falsy(local_spilled.is_error)
		expect.eq(local_spilled.details.backend, "local")
		expect.match(local_spilled.details.handle, "^spill:v1:local:")

		plugin.apply(ctx, { max_search_results = 3, search_timeout_ms = 5000, backend = "missing-backend" })
		local missing_backend = tools.session_event_read.execute({ event_id = "big-1" })
		expect.truthy(missing_backend.is_error)
		expect.eq(missing_backend.error_code, "QUERY_CAPABILITY_UNAVAILABLE")
	end)

	it("enforces caller identity, input validation, cancellation, and error sanitization", function()
		-- session_trace defaults session_id to child_session_id without mutating caller args
		activity.session_id = "child-1"
		local trace_args = {}
		query_handler = function(op, req)
			expect.eq(op, "session.trace")
			expect.eq(req.session_id, "child-1")
			return { target = { session_id = "child-1" }, ancestors = {}, descendants = {} }
		end
		local traced = tools.session_trace.execute(trace_args)
		expect.falsy(traced.is_error)
		expect.eq(trace_args.session_id, nil)
		activity.session_id = "main-session"

		-- Missing caller identity returns QUERY_CALLER_UNAVAILABLE
		activity.session_id = ""
		local no_caller = tools.session_trace.execute({})
		expect.truthy(no_caller.is_error)
		expect.eq(no_caller.error_code, "QUERY_CALLER_UNAVAILABLE")
		activity.session_id = "main-session"

		-- Cancellation before query execution returns cancelled = true
		local pre_tok = mare.task.token()
		pre_tok:cancel()
		local cancel_res = tools.session_event_read.execute({ event_id = "e1" }, { cancel = pre_tok })
		expect.truthy(cancel_res.is_error)
		expect.eq(cancel_res.error_code, "QUERY_CANCELLED")
		expect.eq(cancel_res.cancelled, true)

		-- Input validation guards
		local ws_q = tools.session_search.execute({ query = "   ", title_query = "roadmap" })
		expect.truthy(ws_q.is_error)
		expect.eq(ws_q.error_code, "QUERY_INVALID_QUERY")

		local nul_q = tools.session_search.execute({ query = "foo\0bar" })
		expect.truthy(nul_q.is_error)
		expect.eq(nul_q.error_code, "QUERY_INVALID_QUERY")

		local blank_ev = tools.session_event_search.execute({ query = " \t " })
		expect.truthy(blank_ev.is_error)
		expect.eq(blank_ev.error_code, "QUERY_INVALID_QUERY")

		local bad_win = tools.session_event_read.execute({ event_id = "ev1", before = 11 })
		expect.truthy(bad_win.is_error)
		expect.eq(bad_win.error_code, "QUERY_INVALID_WINDOW")

		local neg_win = tools.session_event_read.execute({ event_id = "ev1", after = -1 })
		expect.truthy(neg_win.is_error)
		expect.eq(neg_win.error_code, "QUERY_INVALID_WINDOW")

		local bad_evid = tools.session_event_read.execute({ event_id = "" })
		expect.truthy(bad_evid.is_error)
		expect.eq(bad_evid.error_code, "QUERY_INVALID_FILTER")

		local bad_seq = tools.session_event_trace.execute({ seq = 0 })
		expect.truthy(bad_seq.is_error)
		expect.eq(bad_seq.error_code, "QUERY_INVALID_FILTER")

		-- Stale history string error without QUERY_ prefix maps to QUERY_STALE_CURSOR
		query_handler = function()
			error("stale history event")
		end
		local stale_msg = tools.session_event_read.execute({ event_id = "e1" })
		expect.truthy(stale_msg.is_error)
		expect.eq(stale_msg.error_code, "QUERY_STALE_CURSOR")

		-- Unknown error maps to QUERY_FAILED without leaking internal message
		query_handler = function()
			error("internal secret path")
		end
		local failed = tools.session_event_read.execute({ event_id = "e1" })
		expect.truthy(failed.is_error)
		expect.eq(failed.error_code, "QUERY_FAILED")
		expect.eq(failed.content, "QUERY_FAILED: session query failed")

		-- Error sanitization maps core errors cleanly without leaking Lua file:line paths
		local error_cases = {
			{ msg = "stale history cursor", code = "QUERY_STALE_CURSOR" },
			{ msg = "invalid history token", code = "QUERY_INVALID_CURSOR" },
			{ msg = "event neighborhood must be 0..10", code = "QUERY_INVALID_WINDOW" },
			{ msg = "session unavailable", code = "QUERY_SESSION_UNAVAILABLE" },
			{ msg = "event unavailable", code = "QUERY_NOT_FOUND" },
			{ msg = "sandbox: access denied", code = "QUERY_UNAUTHORIZED" },
			{ msg = "QUERY_STALE_CURSOR: cursor expired", code = "QUERY_STALE_CURSOR" },
			{
				msg = "QUERY_INVALID_FILTER: reversed sequence range\nstack traceback:\n\tfoo.lua:42: in function <foo.lua:10>",
				code = "QUERY_INVALID_FILTER",
			},
		}
		for _, item in ipairs(error_cases) do
			query_handler = function()
				error(item.msg)
			end
			local res = tools.session_event_read.execute({ event_id = "e1" })
			expect.truthy(res.is_error)
			expect.eq(res.error_code, item.code)
			expect.falsy(res.content:find(".lua:", 1, true))
		end
	end)

	it("formats and renders view outputs with real mare.ui components", function()
		expect.match(view.format({ data = {}, incomplete = false, coverage = { live = false } }), "No matching history")
		expect.match(view.format({ data = {}, incomplete = true }), "some sources could not be searched")

		local hit_fmt = view.format({
			data = {
				{
					session_id = "s1\x1b",
					title = "",
					event_id = "ev1",
					position = { seq = 4 },
					snippet = "hello\x07world",
				},
			},
			capped = true,
			incomplete = true,
			coverage = { live = false },
		})
		expect.match(hit_fmt, "Untitled")
		expect.falsy(hit_fmt:find("\x1b", 1, true))
		expect.falsy(hit_fmt:find("\x07", 1, true))
		expect.match(hit_fmt, "Result limit reached")
		expect.match(hit_fmt, "persisted sessions only")

		local trace_fmt = view.format({
			target = { session_id = "s2" },
			ancestors = { { session_id = "s1" } },
			parent_boundary = true,
			descendants = { { session = { session_id = "s3" }, descendants = {} } },
			incomplete = true,
		})
		expect.match(trace_fmt, "outside the authorized corpus")
		expect.match(trace_fmt, "Some metadata sources")

		local ev_fmt = view.format({
			session_id = "s1",
			seq = 5,
			event = { type = "message" },
			neighbors = { { seq = 4, type = "message", summary = "prev" } },
		})
		expect.match(ev_fmt, "Neighbor seq 4")

		local etrace_fmt = view.format({
			session_id = "s1",
			seq = 2,
			type = "message",
			surface = "shadowed",
			replaced_by = 4,
			replacement_chain = { 4, 7 },
			source_event_seqs = { 1 },
			derived_event_seqs = { 4 },
			summary = "shadowed text",
		})
		expect.match(etrace_fmt, "surface: shadowed")
		expect.match(etrace_fmt, "Replacement chain: 4, 7")
		expect.match(etrace_fmt, "Derived events: 4")

		local spill_fmt = view.format({
			session_id = "s1",
			seq = 9,
			spilled = true,
			handle = "spill:v1:local:ns:h1",
			backend = "local",
			retrieval_hint = "Use read_spill with offset/limit.",
			total_bytes = 70000,
			neighbors = { { seq = 8, type = "message", summary = "before" } },
		})
		expect.match(spill_fmt, "spilled to handle spill:v1:local:ns:h1")
		expect.match(spill_fmt, "backend: local")
		expect.match(spill_fmt, "Use read_spill with offset/limit.")
		expect.match(spill_fmt, "Neighbor seq 8")

		local spill_fallback_fmt = view.format({
			session_id = "s1",
			seq = 9,
			spilled = true,
			handle = "spill:v1:archive:ns:h2",
			total_bytes = 70000,
		})
		expect.match(spill_fallback_fmt, "Use read_spill with this handle")

		local arch_hit = view.format({
			data = {
				{
					session_id = "s-arch",
					title = "Old Release",
					archived = true,
					availability = "persisted",
					event_id = "ev-a",
					position = { seq = 2 },
					updated_at_ms = 1700000000000,
					snippet = "release notes",
				},
			},
		})
		expect.truthy(arch_hit:find("[persisted] [archived]", 1, true))
		expect.truthy(arch_hit:find("updated 2023-11-14T22:13:20Z", 1, true))

		local root_trace = view.format({
			target = { session_id = "s-root", created_at_ms = 1700000000000 },
			ancestors = {},
			descendants = {},
		})
		expect.truthy(root_trace:find("- none (target is a root session)", 1, true))
		expect.truthy(root_trace:find("- none", 1, true))
		expect.truthy(root_trace:find("created 2023-11-14T22:13:20Z", 1, true))

		local ev_id_fmt = view.format({
			session_id = "s1",
			seq = 5,
			event = { type = "message" },
			neighbors = { { event_id = "ev-4", seq = 4, type = "message", summary = "prev" } },
		})
		expect.truthy(ev_id_fmt:find("Neighbor seq 4 · ev-4 | message", 1, true))

		local etrace_inc = view.format({
			session_id = "s1",
			seq = 3,
			event_id = "ev-3",
			availability = "persisted",
			type = "message",
			surface = "log_only",
			source_event_seqs = {},
			incomplete = true,
		})
		expect.truthy(etrace_inc:find("Event ID: ev-3", 1, true))
		expect.truthy(etrace_inc:find("Availability: persisted", 1, true))
		expect.truthy(etrace_inc:find("incomplete", 1, true))

		expect.match(mare.json.encode(view.render({}, nil, false)), "Searching session history…")
		expect.match(
			mare.json.encode(view.render({}, { is_error = true, cancelled = true, content = "QUERY_CANCELLED" }, false)),
			"History query cancelled"
		)
		expect.match(
			mare.json.encode(
				view.render({}, { details = { data = { 1, 2 }, capped = true, incomplete = true } }, false)
			),
			"History · 2 match%(es%) · capped · incomplete"
		)
		expect.match(
			mare.json.encode(view.render({}, {
				details = { target = { session_id = "s1" }, ancestors = { { session_id = "p0" } }, descendants = {} },
			}, false)),
			"Trace · s1 · 1 ancestor%(s%) · 0 descendant root%(s%)"
		)
		expect.match(
			mare.json.encode(view.render({}, {
				details = { seq = 3, surface = "shadowed", source_event_seqs = {}, incomplete = true },
			}, false)),
			"Event trace · seq 3 · shadowed · incomplete"
		)
		expect.match(
			mare.json.encode(view.render({}, {
				details = { seq = 9, spilled = true, handle = "spill:v1:local:ns:h1", total_bytes = 70000 },
			}, false)),
			"Event read · seq 9 · spilled %(70000 bytes%)"
		)
		expect.match(
			mare.json.encode(view.render({}, {
				details = { seq = 5, event = { type = "message" }, neighbors = { { seq = 4 } } },
			}, false)),
			"Event read · seq 5 · 1 neighbor%(s%)"
		)
	end)

	it(
		"pins provider and event identity across chunks, checks forward progress, and keeps before/after on initial chunk",
		function()
			local reqs = {}
			local provider_swapped = false
			local custom_query_call = 0
			query_handler = function(op, req)
				custom_query_call = custom_query_call + 1
				reqs[#reqs + 1] = { op = op, req = req }
				if custom_query_call == 1 then
					error("QUERY_EVENT_TOO_LARGE", 0)
				elseif custom_query_call == 2 then
					-- Initial chunk: before/after must be passed here
					expect.eq(req.offset, 0)
					expect.eq(req.before, 2)
					expect.eq(req.after, 1)
					return {
						session_id = "s1",
						corpus_revision = "g1",
						seq = 9,
						chunk = '{"part":1',
						next_offset = 9,
						total_bytes = 20,
						neighbors = { { seq = 8, type = "message" } },
					}
				end
				-- Second chunk: before/after omitted, and mismatching seq must be rejected
				expect.eq(req.before, nil)
				expect.eq(req.after, nil)
				return {
					session_id = "s1",
					corpus_revision = "g1",
					seq = 10,
					chunk = ',"part":2}',
					next_offset = nil,
					total_bytes = 20,
				}
			end
			local mismatch_res = tools.session_event_read.execute({ event_id = "big-1", before = 2, after = 1 })
			expect.eq(mismatch_res.is_error, true)
			expect.eq(mismatch_res.error_code, "QUERY_STALE_CURSOR")
			expect.truthy(mismatch_res.content:find("history changed", 1, true))

			-- Non-advancing next_offset must be rejected cleanly
			custom_query_call = 0
			query_handler = function(op, req)
				custom_query_call = custom_query_call + 1
				if custom_query_call == 1 then
					error("QUERY_EVENT_TOO_LARGE", 0)
				end
				return {
					session_id = "s1",
					corpus_revision = "g1",
					seq = 9,
					chunk = "abc",
					next_offset = 0,
					total_bytes = 10,
				}
			end
			local stalled_res = tools.session_event_read.execute({ event_id = "big-1" })
			expect.eq(stalled_res.is_error, true)
			expect.truthy(stalled_res.content:find("advance", 1, true))

			-- Provider is pinned via opts.provider across chunks, and mid-stream provider swap fails
			custom_query_call = 0
			local seen_providers = {}
			query_handler = function(op, req, opts)
				custom_query_call = custom_query_call + 1
				seen_providers[custom_query_call] = opts and opts.provider or false
				if custom_query_call == 1 then
					error("QUERY_EVENT_TOO_LARGE", 0)
				elseif custom_query_call == 2 then
					return {
						provider = "p1",
						session_id = "s1",
						corpus_revision = "g1",
						seq = 9,
						chunk = "hello ",
						next_offset = 6,
						total_bytes = 11,
					}
				end
				return {
					provider = "p1",
					session_id = "s1",
					corpus_revision = "g1",
					seq = 9,
					chunk = "world",
					next_offset = nil,
					total_bytes = 11,
				}
			end
			local pinned_res = tools.session_event_read.execute({ event_id = "big-1" })
			expect.falsy(pinned_res.is_error)
			expect.eq(seen_providers[2], false)
			expect.eq(seen_providers[3], "p1")
			expect.eq(
				mare.spill.read(pinned_res.details.handle, { session_id = "main-session" }).content,
				"hello world"
			)

			custom_query_call = 0
			query_handler = function()
				custom_query_call = custom_query_call + 1
				if custom_query_call == 1 then
					error("QUERY_EVENT_TOO_LARGE", 0)
				elseif custom_query_call == 2 then
					return {
						provider = "p1",
						session_id = "s1",
						corpus_revision = "g1",
						seq = 9,
						chunk = "hello ",
						next_offset = 6,
						total_bytes = 11,
					}
				end
				return {
					provider = "p2",
					session_id = "s1",
					corpus_revision = "g1",
					seq = 9,
					chunk = "world",
					next_offset = nil,
					total_bytes = 11,
				}
			end
			local swapped_res = tools.session_event_read.execute({ event_id = "big-1" })
			expect.eq(swapped_res.is_error, true)
			expect.eq(swapped_res.error_code, "QUERY_STALE_CURSOR")
		end
	)
end)
