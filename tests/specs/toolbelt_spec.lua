local support = assert(load(mare.fs.read("tests/specs/support.lua"), "@tests/specs/support.lua"))()

local describe = mare.test.describe
local it = mare.test.it
local before_each = mare.test.before_each
local after_each = mare.test.after_each
local expect = mare.test.expect

describe("toolbelt", function()
	local plugin
	local tools, logs, notifications, doctor_cb
	local which_map, run_calls, run_handler, stat_map
	local orig_which, orig_run, orig_stat, orig_resolve, orig_realpath, orig_log, orig_notify, orig_cwd

	local function make_ctx(existing)
		tools = {}
		logs = {}
		notifications = {}
		doctor_cb = nil

		local ctx = {
			tools = {
				list = function()
					local out = {}
					for name, def in pairs(existing or {}) do
						local copy = support.copy_table(def)
						copy.name = name
						out[#out + 1] = copy
					end
					return out
				end,
				get = function(_, name)
					return existing and existing[name] or nil
				end,
				register = function(_, name, def)
					tools[name] = def
					return function() end, function()
						return true
					end
				end,
			},
			on = function(_, event, fn)
				if event == "kernel/doctor" then
					doctor_cb = fn
				end
			end,
		}
		return ctx
	end

	local function apply_with(cfg_overrides, existing)
		if not plugin then
			plugin = support.load_plugin("toolbelt", {
				"toolbelt.common",
				"toolbelt.grep",
				"toolbelt.find",
				"toolbelt.code_search",
				"toolbelt.doc_search",
			})
		end
		local cfg = support.default_config(plugin)
		for k, v in pairs(cfg_overrides or {}) do
			cfg[k] = v
		end
		local ctx = make_ctx(existing)
		plugin.apply(ctx, cfg)
		return ctx, cfg
	end

	before_each(function()
		which_map = {
			rg = "/usr/local/bin/rg",
			fd = "/usr/local/bin/fd",
			["ast-grep"] = "/usr/local/bin/ast-grep",
			sg = "/usr/local/bin/sg",
			rga = "/usr/local/bin/rga",
		}
		run_calls = {}
		run_handler = function()
			return { code = 0, success = true, stdout = "", stderr = "", timed_out = false, cancelled = false }
		end
		stat_map = {
			["/repo"] = { kind = "dir", size = 0, mtime = 100 },
			["/repo/sub"] = { kind = "dir", size = 0, mtime = 100 },
			["/repo/a.lua"] = { kind = "file", size = 10, mtime = 100 },
		}

		orig_which = mare.proc.which
		orig_run = mare.proc.run
		orig_stat = mare.fs.stat
		orig_resolve = mare.fs.resolve
		orig_realpath = mare.fs.realpath
		orig_log = mare.log
		orig_notify = mare.ui and mare.ui.notify
		orig_cwd = mare.cwd

		mare.cwd = "/repo"
		mare.proc.which = function(name)
			return which_map[name]
		end
		mare.proc.run = function(opts)
			run_calls[#run_calls + 1] = opts
			return run_handler(opts)
		end
		mare.fs.stat = function(path)
			return stat_map[path]
		end
		mare.fs.resolve = function(p)
			if p == "." or p == "" then
				return mare.cwd
			end
			if p:sub(1, 1) == "/" then
				return p
			end
			return mare.cwd .. "/" .. p
		end
		mare.fs.realpath = function(p)
			return p
		end
		mare.log = function(level, msg)
			logs[#logs + 1] = { level = level, msg = msg }
		end
		if mare.ui then
			mare.ui.notify = function(msg, level)
				notifications[#notifications + 1] = { msg = msg, level = level }
			end
		end
	end)

	after_each(function()
		mare.proc.which = orig_which
		mare.proc.run = orig_run
		mare.fs.stat = orig_stat
		mare.fs.resolve = orig_resolve
		mare.fs.realpath = orig_realpath
		mare.log = orig_log
		if mare.ui then
			mare.ui.notify = orig_notify
		end
		mare.cwd = orig_cwd
	end)

	it(
		"probes binaries at startup, falls back to sg, skips missing silently, and does not override core tools",
		function()
			apply_with()
			expect.truthy(tools.grep)
			expect.truthy(tools.find)
			expect.truthy(tools.code_search)
			expect.truthy(tools.doc_search)
			for _, name in ipairs({ "grep", "find", "code_search", "doc_search" }) do
				expect.eq(tools[name].readonly, nil)
				expect.eq(tools[name].side_effect, "read")
				expect.eq(tools[name].idempotent, true)
				expect.truthy(mare.schema.compile(tools[name].parameters))
			end

			-- Fallback to sg when ast-grep is missing (verifies ast-grep --version); rga missing is skipped silently
			which_map["ast-grep"] = nil
			which_map["rga"] = nil
			run_handler = function(opts)
				if opts.cmd == "/usr/local/bin/sg" and opts.args[1] == "--version" then
					return { code = 0, success = true, stdout = "ast-grep 0.36.0\n", stderr = "" }
				end
				return { code = 0, success = true, stdout = "", stderr = "" }
			end
			apply_with()
			expect.truthy(tools.code_search)
			expect.eq(tools.doc_search, nil)
			expect.eq(#notifications, 0)
			local found_rga_log = false
			for _, entry in ipairs(logs) do
				if
					entry.level == "info"
					and entry.msg:find("doc_search", 1, true)
					and entry.msg:find("rga", 1, true)
				then
					found_rga_log = true
				end
			end
			expect.truthy(found_rga_log)

			tools.code_search.execute({ pattern = "foo()", lang = "lua" }, {})
			expect.eq(run_calls[#run_calls].cmd, "/usr/local/bin/sg")

			-- Existing core tool is not overridden
			which_map["rga"] = "/usr/local/bin/rga"
			apply_with(nil, { grep = { name = "grep" } })
			expect.eq(tools.grep, nil)
			expect.truthy(tools.find)

			-- Config flag disables individual tool
			apply_with({ find = false })
			expect.eq(tools.find, nil)
			expect.truthy(tools.grep)

			-- Doctor check reports tool status
			expect.truthy(doctor_cb)
			local checks = {}
			doctor_cb(checks)
			expect.eq(#checks, 1)
			expect.eq(checks[1].ok, true)
		end
	)

	it("declares access for resolved root and fails closed when unresolvable", function()
		apply_with()
		for _, name in ipairs({ "grep", "find", "code_search", "doc_search" }) do
			local acc = tools[name].access({ path = "sub" })
			expect.eq(#acc, 1)
			expect.eq(acc[1].kind, "file")
			expect.eq(acc[1].op, "read")
			expect.eq(acc[1].path, "/repo/sub")
			expect.eq(acc[1].recursive, true)

			local ok_bad = pcall(tools[name].access, { path = "bad\0path" })
			expect.eq(ok_bad, false)
			local ok_type = pcall(tools[name].access, { path = 123 })
			expect.eq(ok_type, false)
		end
	end)

	it("maps grep flags safely with --, never exposes write flags, and formats all output modes", function()
		apply_with()

		-- content mode with dash-prefixed pattern and flags
		run_handler = function()
			return {
				code = 0,
				success = true,
				stderr = "",
				stdout = table.concat({
					mare.json.encode({ type = "begin", data = { path = { text = "/repo/a.lua" } } }),
					mare.json.encode({
						type = "context",
						data = { path = { text = "/repo/a.lua" }, line_number = 9, lines = { text = "-- pre\n" } },
					}),
					mare.json.encode({
						type = "match",
						data = {
							path = { text = "/repo/a.lua" },
							line_number = 10,
							lines = { text = "local x = -flag\n" },
						},
					}),
					mare.json.encode({
						type = "match",
						data = { path = { text = "/outside/b.lua" }, line_number = 3, lines = { text = "other\n" } },
					}),
					mare.json.encode({ type = "summary", data = { stats = { matches = 2 } } }),
				}, "\n"),
			}
		end
		local tok = mare.task.token()
		local res = tools.grep.execute({
			pattern = "--replace=evil",
			path = ".",
			glob = "*.lua",
			type = "lua",
			["-i"] = true,
			["-C"] = 1,
			["-A"] = 5,
			multiline = true,
			literal = true,
		}, { cancel = tok })
		expect.falsy(res.is_error)
		local call = run_calls[#run_calls]
		expect.eq(call.cmd, "/usr/local/bin/rg")
		expect.eq(call.cwd, "/repo")
		expect.eq(call.cancel, tok)
		local joined = "\0" .. table.concat(call.args, "\0") .. "\0"
		expect.truthy(joined:find("\0--json\0", 1, true))
		expect.truthy(joined:find("\0--glob=*.lua\0", 1, true))
		expect.truthy(joined:find("\0--type=lua\0", 1, true))
		expect.truthy(joined:find("\0--ignore-case\0", 1, true))
		expect.truthy(joined:find("\0-C\0001\0", 1, true))
		expect.falsy(joined:find("\0-A\0", 1, true))
		expect.truthy(joined:find("\0-U\0", 1, true))
		expect.truthy(joined:find("\0--multiline-dotall\0", 1, true))
		expect.truthy(joined:find("\0-F\0", 1, true))
		-- -- appears before pattern
		local sep_idx, pat_idx
		for i, v in ipairs(call.args) do
			if v == "--" and not sep_idx then
				sep_idx = i
			elseif v == "--replace=evil" then
				pat_idx = i
			end
		end
		expect.truthy(sep_idx and pat_idx and sep_idx < pat_idx)
		expect.falsy(joined:find("\0--replace\0", 1, true))
		-- output formatting: relative inside /repo, absolute outside, blank line between files
		expect.eq(res.content, "a.lua-9- -- pre\na.lua:10: local x = -flag\n\n/outside/b.lua:3: other")

		-- -n = false omits line numbers
		local res_nonum = tools.grep.execute({ pattern = "x", ["-n"] = false }, {})
		expect.eq(res_nonum.content, "a.lua- -- pre\na.lua: local x = -flag\n\n/outside/b.lua: other")

		-- files_with_matches sorted by mtime newest first + offset + head_limit truncation
		stat_map["/repo/old.lua"] = { kind = "file", size = 5, mtime = 100 }
		stat_map["/repo/new.lua"] = { kind = "file", size = 5, mtime = 300 }
		stat_map["/repo/mid.lua"] = { kind = "file", size = 5, mtime = 200 }
		stat_map["/repo/extra.lua"] = { kind = "file", size = 5, mtime = 400 }
		run_handler = function()
			return {
				code = 0,
				success = true,
				stderr = "",
				stdout = "/repo/old.lua\0/repo/new.lua\0/repo/mid.lua\0/repo/extra.lua\0",
			}
		end
		local res_files = tools.grep.execute({
			pattern = "x",
			output_mode = "files_with_matches",
			head_limit = 2,
			offset = 1,
		}, {})
		expect.falsy(res_files.is_error)
		expect.eq(
			res_files.content,
			"new.lua\nmid.lua\n[... 1 more results truncated; narrow the path, glob or pattern]"
		)

		-- count mode
		run_handler = function()
			return {
				code = 0,
				success = true,
				stderr = "",
				stdout = "/repo/a.lua:2\n/repo/sub/b.lua:5\n/repo/sub/c.lua:1\n",
			}
		end
		local res_cnt = tools.grep.execute({ pattern = "x", output_mode = "count", head_limit = 2 }, {})
		expect.eq(
			res_cnt.content,
			"a.lua: 2\nsub/b.lua: 5\ntotal: 8\n[... 1 more results truncated; narrow the path, glob or pattern]"
		)

		-- exit code 1 = No matches (not an error); exit code 2 = error
		run_handler = function()
			return { code = 1, success = false, stdout = "", stderr = "" }
		end
		local res_empty = tools.grep.execute({ pattern = "missing" }, {})
		expect.falsy(res_empty.is_error)
		expect.eq(res_empty.content, "No matches")

		run_handler = function()
			return { code = 2, success = false, stdout = "", stderr = "regex parse error\ndetail\n" }
		end
		local res_err = tools.grep.execute({ pattern = "[" }, {})
		expect.eq(res_err.is_error, true)
		expect.truthy(res_err.content:find("regex parse error", 1, true))
	end)

	it("maps find flags, prevents exec flags, and sorts by mtime desc", function()
		apply_with()
		stat_map["/repo/old.lua"] = { kind = "file", size = 5, mtime = 50 }
		stat_map["/repo/new.lua"] = { kind = "file", size = 5, mtime = 500 }
		stat_map["/repo/mid.lua"] = { kind = "file", size = 5, mtime = 250 }
		run_handler = function()
			return {
				code = 0,
				success = true,
				stderr = "",
				stdout = "/repo/old.lua\0/repo/new.lua\0/repo/mid.lua\0",
			}
		end
		local res = tools.find.execute({
			pattern = "sub/*.lua",
			include_ignored = true,
			include_dirs = true,
			head_limit = 2,
		}, {})
		expect.falsy(res.is_error)
		local args = run_calls[#run_calls].args
		local joined = "\0" .. table.concat(args, "\0") .. "\0"
		expect.truthy(joined:find("\0--glob\0", 1, true))
		expect.truthy(joined:find("\0--full-path\0", 1, true))
		expect.truthy(joined:find("\0--type\0f\0", 1, true))
		expect.truthy(joined:find("\0--type\0d\0", 1, true))
		expect.truthy(joined:find("\0--color\0never\0", 1, true))
		expect.truthy(joined:find("\0--hidden\0", 1, true))
		expect.truthy(joined:find("\0--no-ignore\0", 1, true))
		expect.truthy(joined:find("\0-0\0", 1, true))
		expect.truthy(joined:find("\0--\0", 1, true))
		expect.falsy(joined:find("\0-x\0", 1, true))
		expect.falsy(joined:find("\0-X\0", 1, true))
		expect.eq(res.content, "new.lua\nmid.lua\n[... 1 more results truncated; narrow the path, glob or pattern]")
	end)

	it("maps code_search flags, validates lang, formats 1-based lines, and never passes write flags", function()
		apply_with()
		local bad_lang = tools.code_search.execute({ pattern = "x", lang = "brainfuck" }, {})
		expect.eq(bad_lang.is_error, true)
		expect.eq(#run_calls, 0)

		run_handler = function()
			return {
				code = 0,
				success = true,
				stderr = "",
				stdout = table.concat({
					mare.json.encode({
						file = "/repo/a.lua",
						range = { start = { line = 4, column = 0 } },
						text = "  local function foo()\n    return 1\n  end",
					}),
					mare.json.encode({
						file = "/repo/sub/b.lua",
						range = { start = { line = 0, column = 0 } },
						text = "local bar = 2",
					}),
				}, "\n"),
			}
		end
		local res = tools.code_search.execute({ pattern = "-x", lang = "lua", head_limit = 1 }, {})
		expect.falsy(res.is_error)
		local args = run_calls[#run_calls].args
		local joined = "\0" .. table.concat(args, "\0") .. "\0"
		expect.truthy(joined:find("\0run\0", 1, true))
		expect.truthy(joined:find("\0--pattern=-x\0", 1, true))
		expect.truthy(joined:find("\0--lang\0lua\0", 1, true))
		expect.truthy(joined:find("\0--json=stream\0", 1, true))
		expect.truthy(joined:find("\0--\0/repo\0", 1, true))
		expect.falsy(joined:find("\0-U\0", 1, true))
		expect.falsy(joined:find("\0--update-all\0", 1, true))
		expect.falsy(joined:find("\0-r\0", 1, true))
		expect.falsy(joined:find("\0--rewrite\0", 1, true))
		expect.eq(
			res.content,
			"a.lua:5: local function foo()\n[... 1 more results truncated; narrow the path, glob or pattern]"
		)

		run_handler = function()
			return { code = 1, success = false, stdout = "", stderr = "" }
		end
		local no_match = tools.code_search.execute({ pattern = "missing()", lang = "lua" }, {})
		expect.falsy(no_match.is_error)
		expect.eq(no_match.content, "No matches")
	end)

	it("handles doc_search rga archive/document null line numbers and files_with_matches", function()
		apply_with()
		run_handler = function()
			return {
				code = 0,
				success = true,
				stderr = "",
				stdout = table.concat({
					mare.json.encode({
						type = "match",
						data = {
							path = { text = "/repo/notes.pdf" },
							line_number = mare.json.null,
							lines = { text = "Page 2: invoice total\n" },
						},
					}),
					mare.json.encode({
						type = "match",
						data = {
							path = { text = "/repo/a.lua" },
							line_number = 3,
							lines = { text = "-- invoice\n" },
						},
					}),
				}, "\n"),
			}
		end
		local res = tools.doc_search.execute({ pattern = "invoice", glob = "*.pdf", ["-i"] = true }, {})
		expect.falsy(res.is_error)
		expect.eq(res.content, "notes.pdf: Page 2: invoice total\n\na.lua:3: -- invoice")
		local joined = "\0" .. table.concat(run_calls[#run_calls].args, "\0") .. "\0"
		expect.truthy(joined:find("\0--glob=*.pdf\0", 1, true))
		expect.truthy(joined:find("\0--ignore-case\0", 1, true))
		expect.truthy(joined:find("\0--\0", 1, true))
	end)

	it("maps timed_out, cancelled, and sandbox denial from mare.proc.run", function()
		apply_with({ timeout_ms = 5000 })

		run_handler = function()
			return { code = nil, stdout = "", stderr = "", timed_out = true, cancelled = false }
		end
		local to = tools.grep.execute({ pattern = "x" }, {})
		expect.eq(to.is_error, true)
		expect.eq(to.content, "timed out after 5000 ms")

		run_handler = function()
			return { code = nil, stdout = "", stderr = "", timed_out = false, cancelled = true }
		end
		local ca = tools.find.execute({ pattern = "*.lua" }, {})
		expect.eq(ca.is_error, true)
		expect.eq(ca.cancelled, true)
		expect.eq(ca.content, "cancelled")

		run_handler = function()
			return {
				code = 2,
				success = false,
				stdout = "",
				stderr = "Permission denied",
				timed_out = false,
				cancelled = false,
				sandbox_denied = "read",
				sandbox_marker = "[sandbox: file access denied under workspace-write mode]",
			}
		end
		local sb = tools.doc_search.execute({ pattern = "secret" }, {})
		expect.eq(sb.is_error, true)
		expect.truthy(sb.content:find("[sandbox: file access denied under workspace-write mode]", 1, true))
	end)

	it("enforces max_output_bytes and uses parent directory as cwd when path is a file", function()
		apply_with({ max_output_bytes = 1024 })
		local big_line = string.rep("x", 600)
		run_handler = function()
			return {
				code = 0,
				success = true,
				stderr = "",
				stdout = table.concat({
					mare.json.encode({
						type = "match",
						data = { path = { text = "/repo/a.lua" }, line_number = 1, lines = { text = big_line .. "\n" } },
					}),
					mare.json.encode({
						type = "match",
						data = { path = { text = "/repo/a.lua" }, line_number = 2, lines = { text = big_line .. "\n" } },
					}),
				}, "\n"),
			}
		end
		local res = tools.grep.execute({ pattern = "x", path = "a.lua" }, {})
		expect.falsy(res.is_error)
		expect.eq(run_calls[#run_calls].cwd, "/repo")
		expect.truthy(res.content:find("more results truncated", 1, true))
		expect.truthy(#res.content <= 1024)
	end)

	it("skips code_search silently when ast-grep is absent and sg is Linux shadow sg", function()
		which_map["ast-grep"] = nil
		which_map["sg"] = "/usr/bin/sg"
		run_handler = function(opts)
			if opts.cmd == "/usr/bin/sg" and opts.args[1] == "--version" then
				return {
					code = 2,
					success = false,
					stdout = "",
					stderr = "Usage: sg [-c command] [group]\n",
				}
			end
			return { code = 0, success = true, stdout = "", stderr = "" }
		end
		apply_with()
		expect.eq(tools.code_search, nil)
		expect.eq(#notifications, 0)
		local found_log = false
		for _, entry in ipairs(logs) do
			if
				entry.level == "info"
				and entry.msg:find("code_search", 1, true)
				and entry.msg:find("unavailable", 1, true)
			then
				found_log = true
			end
		end
		expect.truthy(found_log)
	end)

	it("passes --with-filename for grep count mode on a single file", function()
		apply_with()
		run_handler = function()
			return {
				code = 0,
				success = true,
				stderr = "",
				stdout = "/repo/a.lua:3\n",
			}
		end
		local res = tools.grep.execute({ pattern = "foo", path = "a.lua", output_mode = "count" }, {})
		expect.falsy(res.is_error)
		local joined = "\0" .. table.concat(run_calls[#run_calls].args, "\0") .. "\0"
		expect.truthy(joined:find("\0--count-matches\0", 1, true))
		expect.truthy(joined:find("\0--with-filename\0", 1, true))
		expect.eq(res.content, "a.lua: 3\ntotal: 3")
		expect.eq(res.details.matches, 3)
	end)

	it("discards partial records after max_output omission marker and marks truncated", function()
		apply_with()
		-- NUL-separated find / files_with_matches output truncated mid-path by HeadTail
		run_handler = function()
			return {
				code = 0,
				success = true,
				stderr = "",
				dropped = 420,
				stdout = "/repo/a.lua\0/repo/sub/b.lua\0/repo/partial_trun\n... 420 bytes omitted ...\n/repo/tail.lua\0",
			}
		end
		local res_find = tools.find.execute({ pattern = "*.lua" }, {})
		expect.falsy(res_find.is_error)
		expect.falsy(res_find.content:find("partial_trun", 1, true))
		expect.falsy(res_find.content:find("bytes omitted", 1, true))
		expect.falsy(res_find.content:find("tail.lua", 1, true))
		expect.truthy(res_find.content:find("a.lua", 1, true))
		expect.truthy(res_find.content:find("truncated", 1, true))
		expect.eq(res_find.details.truncated, true)

		local res_files = tools.grep.execute({ pattern = "x", output_mode = "files_with_matches" }, {})
		expect.falsy(res_files.content:find("partial_trun", 1, true))
		expect.falsy(res_files.content:find("tail.lua", 1, true))
		expect.eq(res_files.details.truncated, true)

		-- Line-delimited rg count output truncated mid-line before omission marker
		run_handler = function()
			return {
				code = 0,
				success = true,
				stderr = "",
				dropped = 300,
				stdout = "/repo/a.lua:2\n/repo/b.lua:1\n... 300 bytes omitted ...\n/repo/tail.lua:9\n",
			}
		end
		local res_cnt = tools.grep.execute({ pattern = "x", output_mode = "count" }, {})
		expect.falsy(res_cnt.is_error)
		expect.eq(res_cnt.details.matches, 2)
		expect.falsy(res_cnt.content:find("b.lua", 1, true))
		expect.falsy(res_cnt.content:find("tail.lua", 1, true))
		expect.truthy(res_cnt.content:find("truncated", 1, true))
		expect.eq(res_cnt.details.truncated, true)

		-- JSON stream output truncated inside first line still reports truncated (never "No matches")
		run_handler = function()
			return {
				code = 0,
				success = true,
				stderr = "",
				dropped = 900,
				stdout = '{"type":"match","data":{"path":{"text":"/repo/a.lua"}\n... 900 bytes omitted ...\n',
			}
		end
		local res_only_partial = tools.grep.execute({ pattern = "x" }, {})
		expect.falsy(res_only_partial.is_error)
		expect.falsy(res_only_partial.content == "No matches")
		expect.truthy(res_only_partial.content:find("truncated", 1, true))
		expect.eq(res_only_partial.details.truncated, true)

		-- code_search JSON stream output with dropped > 0 discards partial line & marks truncated
		run_handler = function()
			return {
				code = 0,
				success = true,
				stderr = "",
				dropped = 250,
				stdout = mare.json.encode({
					file = "/repo/a.lua",
					range = { start = { line = 0, column = 0 } },
					text = "local ok = 1",
				}) .. '\n{"file":"/repo/b.lua"\n... 250 bytes omitted ...\n{"file":"/repo/tail.lua"}\n',
			}
		end
		local res_cs_drop = tools.code_search.execute({ pattern = "local $X = 1", lang = "lua" }, {})
		expect.falsy(res_cs_drop.is_error)
		expect.falsy(res_cs_drop.content:find("b.lua", 1, true))
		expect.falsy(res_cs_drop.content:find("tail.lua", 1, true))
		expect.truthy(res_cs_drop.content:find("a.lua:1: local ok = 1", 1, true))
		expect.truthy(res_cs_drop.content:find("truncated", 1, true))
		expect.eq(res_cs_drop.details.truncated, true)
	end)

	it("strips leading ./ in find globs and anchors non-recursive relative paths to search root", function()
		apply_with()
		tools.find.execute({ pattern = "./src/*.rs" }, {})
		local a1 = run_calls[#run_calls].args
		local j1 = "\0" .. table.concat(a1, "\0") .. "\0"
		expect.truthy(j1:find("\0--full-path\0", 1, true))
		expect.truthy(j1:find("\0/repo/src/*.rs\0", 1, true))

		tools.find.execute({ pattern = "src/*.rs" }, {})
		local j2 = "\0" .. table.concat(run_calls[#run_calls].args, "\0") .. "\0"
		expect.truthy(j2:find("\0--full-path\0", 1, true))
		expect.truthy(j2:find("\0/repo/src/*.rs\0", 1, true))

		tools.find.execute({ pattern = "./*.lua" }, {})
		local j3 = "\0" .. table.concat(run_calls[#run_calls].args, "\0") .. "\0"
		expect.falsy(j3:find("\0--full-path\0", 1, true))
		expect.truthy(j3:find("\0*.lua\0", 1, true))

		tools.find.execute({ pattern = "**/src/*.rs" }, {})
		local j4 = "\0" .. table.concat(run_calls[#run_calls].args, "\0") .. "\0"
		expect.truthy(j4:find("\0--full-path\0", 1, true))
		expect.truthy(j4:find("\0**/src/*.rs\0", 1, true))
	end)

	it(
		"passes ctx.cwd to access, propagates sandbox_denied from fs.stat, validates min max_output_bytes, and supports head_limit=0 & doc_search files_with_matches",
		function()
			expect.eq(pcall(apply_with, { max_output_bytes = 512 }), false)

			apply_with()
			local acc = tools.grep.access({ path = "." }, { cwd = "/repo/sub" })
			expect.eq(acc[1].path, "/repo/sub")
			local acc_rel = tools.find.access({ path = "nested" }, { cwd = "/repo/sub" })
			expect.eq(acc_rel[1].path, "/repo/sub/nested")

			mare.fs.stat = function(path)
				if path == "/repo/sub" then
					error("sandbox: file access denied")
				end
				return stat_map[path]
			end
			local denied = tools.find.execute({ pattern = "*.lua", path = "sub" }, {})
			expect.eq(denied.is_error, true)
			expect.eq(denied.error_code, "sandbox_denied")
			mare.fs.stat = function(path)
				return stat_map[path]
			end

			-- head_limit = 0 returns all entries (even exceeding head_limit_default)
			apply_with({ head_limit_default = 1 })
			stat_map["/repo/b.lua"] = { kind = "file", size = 5, mtime = 200 }
			stat_map["/repo/c.lua"] = { kind = "file", size = 5, mtime = 300 }
			run_handler = function()
				return {
					code = 0,
					success = true,
					stderr = "",
					stdout = "/repo/a.lua\0/repo/b.lua\0/repo/c.lua\0",
				}
			end
			local unlimited = tools.find.execute({ pattern = "*.lua", head_limit = 0 }, {})
			expect.falsy(unlimited.is_error)
			expect.eq(unlimited.content, "c.lua\nb.lua\na.lua")
			expect.eq(unlimited.details.truncated, false)

			-- doc_search output_mode = files_with_matches
			apply_with()
			run_handler = function()
				return {
					code = 0,
					success = true,
					stderr = "",
					stdout = "/repo/notes.pdf\0/repo/a.lua\0",
				}
			end
			stat_map["/repo/notes.pdf"] = { kind = "file", size = 100, mtime = 900 }
			local doc_files = tools.doc_search.execute({ pattern = "invoice", output_mode = "files_with_matches" }, {})
			expect.falsy(doc_files.is_error)
			expect.eq(doc_files.content, "notes.pdf\na.lua")
			local doc_args = "\0" .. table.concat(run_calls[#run_calls].args, "\0") .. "\0"
			expect.truthy(doc_args:find("\0--files-with-matches\0", 1, true))
			expect.truthy(doc_args:find("\0-0\0", 1, true))

			-- join_capped does not prematurely drop the final entry via notice reserve
			apply_with({ max_output_bytes = 1024 })
			local line1 = string.rep("a", 500)
			local line2 = string.rep("b", 500)
			run_handler = function()
				return {
					code = 0,
					success = true,
					stderr = "",
					stdout = table.concat({
						mare.json.encode({
							type = "match",
							data = {
								path = { text = "/repo/a.lua" },
								line_number = 1,
								lines = { text = line1 .. "\n" },
							},
						}),
						mare.json.encode({
							type = "match",
							data = {
								path = { text = "/repo/a.lua" },
								line_number = 2,
								lines = { text = line2 .. "\n" },
							},
						}),
					}, "\n"),
				}
			end
			local exact_fit = tools.grep.execute({ pattern = "a", ["-n"] = false }, {})
			expect.falsy(exact_fit.is_error)
			expect.eq(exact_fit.details.truncated, false)
			expect.truthy(exact_fit.content:find(line2, 1, true))
		end
	)

	it(
		"passes --no-config/--color=never, --regexp= for doc_search, escapes find globs, and sorts before slice",
		function()
			apply_with()

			-- doc_search passes --no-config, --color=never, and --regexp= before --
			tools.doc_search.execute({ pattern = "--rga-config-file=/tmp/evil.json" }, {})
			local doc_args = run_calls[#run_calls].args
			local joined_doc = "\0" .. table.concat(doc_args, "\0") .. "\0"
			expect.truthy(joined_doc:find("\0--no-config\0", 1, true))
			expect.truthy(joined_doc:find("\0--color=never\0", 1, true))
			expect.truthy(joined_doc:find("\0--regexp=--rga-config-file=/tmp/evil.json\0", 1, true))
			local sep_idx
			for i, a in ipairs(doc_args) do
				if a == "--" then
					sep_idx = i
					break
				end
			end
			expect.truthy(sep_idx)
			expect.eq(doc_args[sep_idx + 1], "/repo")
			expect.eq(doc_args[sep_idx + 2], nil)

			-- grep passes --no-config and --color=never
			tools.grep.execute({ pattern = "needle" }, {})
			local grep_joined = "\0" .. table.concat(run_calls[#run_calls].args, "\0") .. "\0"
			expect.truthy(grep_joined:find("\0--no-config\0", 1, true))
			expect.truthy(grep_joined:find("\0--color=never\0", 1, true))

			-- find escapes glob metacharacters in root prefix and preserves smart-case
			mare.cwd = "/Repo/[id]"
			stat_map["/Repo/[id]"] = { kind = "dir", size = 0, mtime = 100 }
			mare.fs.resolve = function(p)
				if p == "." or p == "" then
					return mare.cwd
				end
				if p:sub(1, 1) == "/" then
					return p
				end
				return mare.cwd .. "/" .. p
			end
			tools.find.execute({ pattern = "sub/*.lua" }, {})
			local find_args = run_calls[#run_calls].args
			local find_joined = "\0" .. table.concat(find_args, "\0") .. "\0"
			expect.truthy(find_joined:find("\0--ignore-case\0", 1, true))
			expect.truthy(find_joined:find("\0/Repo/\\[id\\]/sub/*.lua\0", 1, true))

			-- Windows backslash/slash normalization
			local orig_os = mare.os
			mare.os = "windows"
			mare.cwd = "C:\\Repo"
			stat_map["C:\\Repo"] = { kind = "dir", size = 0, mtime = 100 }
			stat_map["C:/Repo/sub/win.lua"] = { kind = "file", size = 10, mtime = 500 }
			mare.fs.resolve = function(p)
				if p == "." or p == "" then
					return mare.cwd
				end
				return p
			end
			run_handler = function()
				return {
					code = 0,
					success = true,
					stderr = "",
					stdout = "C:/Repo/sub/win.lua\0",
				}
			end
			local win_res = tools.find.execute({ pattern = "*.lua" }, {})
			mare.os = orig_os
			expect.falsy(win_res.is_error)
			expect.eq(win_res.content, "sub/win.lua")
		end
	)
end)
