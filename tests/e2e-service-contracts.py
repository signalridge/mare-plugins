#!/usr/bin/env python3
"""Verify all 11 service-providing plugins load cleanly in mare and execute real service calls."""

import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

SERVICE_PLUGINS = [
    ("btw", "btw"),
    ("codemode", "codemode"),
    ("goal", "goals"),
    ("plan-mode", "plan_mode"),
    ("presets", "presets"),
    ("schedule", "schedule"),
    ("secrets", "secrets"),
    ("session-title", "session_title"),
    ("team", "team"),
    ("terminals", "terminals"),
    ("todo", "todo"),
]

FAULT_PLUGIN_LUA = r"""
return {
    name = "contract-probe-fault",
    provide = { "contract_probe_fault" },
    contracts = {
        contract_probe_fault = {
            doc = "Test-only fault service for the out-of-process service error boundary.",
            methods = {
                fail = {
                    doc = "Raise an undeclared provider error that carries a sentinel.",
                    expose = "both",
                    params = { type = "object", properties = {}, additionalProperties = false },
                    order = {},
                    result = { type = "boolean" },
                },
            },
        },
    },
    apply = function(ctx)
        -- admitted under the declared contract (a raw ctx:provide is not), so an undeclared
        -- provider error reaches callers as `internal`
        require("mare_lib").service(ctx, "contract_probe_fault", {
            fail = function()
                error("unexpected_probe_failure: __SECRET_SENTINEL__")
            end,
        })
    end,
}
"""

PROBE_PLUGIN_LUA = r"""
return {
    name = "contract-probe",
    -- commands is always there; every other service is checked for presence: read with ctx:get
    inject = { "commands" },
    apply = function(ctx)
        local report_path = assert(os.getenv("MARE_CONTRACT_PROBE_REPORT"))
        local function run_checks()
            local results = {}
            local notes = {}
            local function check(name, status_kind, fn)
                local ok, err = pcall(fn)
                results[name] = { ok = ok, kind = status_kind, error = ok and nil or tostring(err) }
            end

            if ctx:get("conversations") ~= nil then
                check("btw", "active", function()
                    assert(type(ctx:get("btw")) == "table", "missing ctx.btw")
                    local st = ctx:get("btw"):status()
                    assert(type(st) == "table" and st.open == false, "unexpected btw.status")
                end)
            else
                check("btw", "unavailable_missing_core_api", function()
                    assert(ctx:get("btw") == nil, "expected ctx.btw nil when ctx.conversations is absent from main")
                end)
            end
        check("codemode", "active", function()
            assert(type(ctx:get("codemode")) == "table", "missing ctx.codemode")
            assert(ctx:get("codemode"):available() == true, "unexpected codemode.available")
            -- Negative counter-test: provider ignores extra Lua args, so only the typed
            -- contract guard rejects an unexpected positional argument with invalid_arguments.
            local ok_extra, err_extra = pcall(ctx:get("codemode").available, ctx:get("codemode"), "unexpected_extra_arg")
            assert(not ok_extra and tostring(err_extra):find("invalid_arguments", 1, true),
                "typed contract guard did not reject extra arg on codemode.available: " .. tostring(err_extra))
        end)
        check("goals", "active", function()
            assert(type(ctx:get("goals")) == "table", "missing ctx.goals")
            local g = ctx:get("goals"):get()
            assert(type(g) == "table" and type(g.owner) == "table", "unexpected goals.get")
            local bad_ok, berr = pcall(ctx:get("goals").create, ctx:get("goals"), "")
            assert(not bad_ok and berr and berr.code == "goals.invalid_goal", "goals.create('') must raise goals.invalid_goal")
            local paused_ok, perr = pcall(ctx:get("goals").pause, ctx:get("goals"), { goal_id = "stale", revision = 0, session_id = "x", generation = 0 })
            assert(not paused_ok and perr and perr.code == "goals.stale_ref", "goals.pause(stale) must raise goals.stale_ref, got: " .. tostring(perr and perr.code))
        end)
        check("plan_mode", "active", function()
            assert(type(ctx:get("plan_mode")) == "table", "missing ctx.plan_mode")
            assert(ctx:get("plan_mode"):active() == false, "plan mode must start inactive")
            local view = ctx:get("plan_mode"):state()
            assert(type(view) == "table" and view.active == false, "unexpected plan_mode.state")
            local ok_extra, err_extra = pcall(ctx:get("plan_mode").active, ctx:get("plan_mode"), "unexpected_extra_arg")
            assert(not ok_extra and tostring(err_extra):find("invalid_arguments", 1, true),
                "typed contract guard did not reject extra arg on plan_mode.active: " .. tostring(err_extra))
        end)
        check("presets", "active", function()
            assert(type(ctx:get("presets")) == "table", "missing ctx.presets")
        end)
        check("schedule", "active", function()
            assert(type(ctx:get("schedule")) == "table", "missing ctx.schedule")
            local bad_ok, berr = pcall(ctx:get("schedule").create, ctx:get("schedule"), "bad", 59999)
            assert(not bad_ok and berr and berr.code == "schedule.invalid_schedule", "schedule.create(59999) must raise schedule.invalid_schedule")
            local id = ctx:get("schedule"):create("probe ping", 60000)
            assert(type(id) == "string" and id ~= "", "unexpected schedule.create id: " .. tostring(id))
            local list = ctx:get("schedule"):list()
            assert(type(list) == "table" and #list >= 1, "unexpected schedule.list")
            local paused = ctx:get("schedule"):control("pause", id)
            assert(type(paused) == "table" and paused.ok == true and paused.note == "Task paused", "unexpected schedule.control pause: " .. mare.json.encode(paused))
            local extra_ok, extra_err = pcall(ctx:get("schedule").control, ctx:get("schedule"), "pause", id, "unexpected_extra_arg")
            assert(not extra_ok and tostring(extra_err):find("invalid_arguments", 1, true), "extra arg on schedule.control must reject with invalid_arguments, got: " .. tostring(extra_err))
            local miss_ok, merr = pcall(ctx:get("schedule").control, ctx:get("schedule"), "pause", "missing-id")
            assert(not miss_ok and merr and merr.code == "schedule.not_found", "schedule.control(missing) must raise schedule.not_found")
            assert(ctx:get("schedule"):list()[1].status == "paused", "task status must remain paused after invalid/missing control")
            local stopped = ctx:get("schedule"):control("stop", id)
            assert(type(stopped) == "table" and stopped.ok == true and stopped.note == "Task stopped", "unexpected schedule.control stop")
            local sub_ok, sub_err = pcall(ctx:get("schedule").submit, ctx:get("schedule"), {
                task_id = id,
                revision = 1,
                run_token = "stale",
                delay_ms = 60000,
                reason = "stale",
            })
            assert(not sub_ok and sub_err and sub_err.code == "schedule.invalid_schedule", "stale schedule.submit must raise schedule.invalid_schedule, got: " .. tostring(sub_err and sub_err.code) .. " / " .. tostring(sub_err))
            local sel_ok, sel_err = pcall(ctx:get("schedule").list_durable, ctx:get("schedule"), { unknown_field = true })
            assert(not sel_ok and sel_err and sel_err.code == "schedule.invalid_schedule", "list_durable({unknown_field=true}) must raise schedule.invalid_schedule, got: " .. tostring(sel_err and sel_err.code))
            local view_ok, view_err = pcall(ctx:get("schedule").view, ctx:get("schedule"), { id = "missing-durable" })
            assert(not view_ok and view_err and view_err.code == "schedule.not_found", "schedule.view(missing) must raise schedule.not_found")
            local hist_ok, hist_err = pcall(ctx:get("schedule").history, ctx:get("schedule"), { id = "missing-durable", limit = 10 })
            assert(not hist_ok and hist_err and hist_err.code == "schedule.not_found", "schedule.history(missing) must raise schedule.not_found")
            -- Cancelled token on durable operation must preserve core 'cancelled' code via real proxy
            local ctok = mare.task.token()
            ctok:cancel()
            local cok, cerr = pcall(ctx:get("schedule").edit, ctx:get("schedule"), {
                id = "cancelled-durable",
                action = "delete",
            }, { cancel = ctok })
            assert(not cok and cerr and cerr.code == "cancelled", "cancelled schedule.edit must preserve core 'cancelled', got: " .. tostring(cerr and cerr.code))
            -- Positive control for durable create_durable, view, history, and cursor_not_found when core mare.time is available
            if type(mare.time) == "table" then
                local sess_id = ctx:get("session") and ctx:get("session"):info().session_id or "sess"
                local created = ctx:get("schedule"):create_durable({
                    title = "contract-durable",
                    prompt = "noop",
                    timing = { kind = "after", after_seconds = 7200 },
                    target = { kind = "session", session_id = sess_id },
                })
                assert(type(created) == "table" and type(created.record) == "table", "create_durable failed")
                local viewed = ctx:get("schedule"):view({ id = created.record.id })
                assert(type(viewed) == "table" and type(viewed.record) == "table" and viewed.record.id == created.record.id and viewed.record.title == "contract-durable", "schedule.view success check failed: " .. mare.json.encode(viewed))
                local hist = ctx:get("schedule"):history({ id = created.record.id, limit = 10 })
                assert(type(hist) == "table" and type(hist.records) == "table", "schedule.history success check failed")
                local cur_ok, cur_err = pcall(ctx:get("schedule").history, ctx:get("schedule"), { id = created.record.id, limit = 10, before = "nonexistent-cursor" })
                assert(not cur_ok and cur_err and cur_err.code == "schedule.not_found", "schedule.history(bad cursor) must raise schedule.not_found, got: " .. tostring(cur_err and cur_err.code))
                assert(ctx:get("schedule"):edit({ id = created.record.id, action = "delete", expected_updated_at = created.updated_at }))
            else
                notes[#notes + 1] = "schedule durable positive controls (create_durable/view/history/cursor) skipped: core has no mare.time"
            end
            local durable = ctx:get("schedule"):list_durable({})
            assert(type(durable) == "table" and type(durable.items) == "table", "unexpected schedule.list_durable")
            local limits = ctx:get("schedule"):delivery_limits()
            assert(type(limits) == "table" and limits.minimum_seconds == 60, "unexpected schedule.delivery_limits")
        end)
        check("secrets", "active", function()
            assert(type(ctx:get("secrets")) == "table", "missing ctx.secrets")
        end)
        check("session_title", "active", function()
            local st = ctx:get("session_title")
            assert(type(st) == "table", "missing ctx.session_title")
            local snap = st:get()
            assert(type(snap) == "table" and snap.id ~= nil, "session_title.get must return snapshot with session id")
            assert(st:cancel() == true, "session_title.cancel must return true")
            assert(st:rename("Contract Probe Title") == true, "session_title.rename must return true")
            local after = st:get()
            assert(type(after) == "table" and after.name == "Contract Probe Title", "session_title.get must reflect renamed title")
            local reg_ok, reg_err = pcall(st.register, st, {
                id = "probe_title",
                automatic = "first-prompt",
                generate = function() return nil end,
            })
            assert(not reg_ok and tostring(reg_err):find("already registered", 1, true), "duplicate session_title.register must fail clearly")
        end)
        check("team", "active", function()
            local team = ctx:get("team")
            assert(type(team) == "table", "missing ctx.team")
            local snap = team:list()
            assert(type(snap) == "table" and type(snap.tasks) == "table", "unexpected team.list")
            local ok_extra, err_extra = pcall(team.list, team, {}, "unexpected_extra_arg")
            assert(not ok_extra and tostring(err_extra):find("invalid_arguments", 1, true),
                "typed contract guard did not reject extra arg on team.list: " .. tostring(err_extra))
            local bad_ok, bad_err = pcall(team.claim, team, { id = "missing-task" })
            assert(not bad_ok and bad_err and bad_err.code == "team.unknown_task",
                "team.claim(missing-task) must raise team.unknown_task, got: " .. tostring(bad_err and bad_err.code))
        end)
        check("terminals", "active", function()
            assert(type(ctx:get("terminals")) == "table", "missing ctx.terminals")
            local list = ctx:get("terminals"):list()
            assert(type(list) == "table" and #list >= 1, "unexpected terminals.list")
            local ok_extra, err_extra = pcall(ctx:get("terminals").list, ctx:get("terminals"), "unexpected_extra_arg")
            assert(not ok_extra and tostring(err_extra):find("invalid_arguments", 1, true),
                "typed contract guard did not reject extra arg on terminals.list: " .. tostring(err_extra))
            local dispose = ctx:get("terminals"):register("probe_term", { open = function() end })
            assert(require("mare_lib").callable(dispose), "unexpected terminals.register return")
            dispose()
            dispose()
        end)
        check("todo", "active", function()
            assert(type(ctx:get("todo")) == "table", "missing ctx.todo")
            local snap = ctx:get("todo"):snapshot()
            assert(type(snap) == "table", "unexpected todo.snapshot")
        end)

            local f = assert(io.open(report_path, "w"))
            results._notes = notes
            f:write(mare.json.encode(results))
            f:close()
        end
        if ctx.commands and type(ctx.commands.register) == "function" then
            ctx.commands:register("contract-probe", {
                description = "Run service contract probes after initialization",
                run = function()
                    run_checks()
                end,
            })
            ctx.commands:register("contract-rpc-probe", {
                description = "Probe out-of-process RPC error handling",
                run = function(mode)
                    if mode == "fault-inprocess" then
                        -- Positive control: the sentinel really passes through the core service
                        -- proxy; an in-process Lua caller is trusted and sees it (service_error.rs:28-31).
                        local ok, err = pcall(ctx:get("contract_probe_fault").fail, ctx:get("contract_probe_fault"))
                        assert(not ok and err and err.code == "internal", "fault service must fail as internal: " .. tostring(err))
                        assert(tostring(err):find("__SECRET_SENTINEL__", 1, true), "in-process caller must see the detail: " .. tostring(err))
                    elseif mode == "structured" then
                        local ok, err = pcall(ctx:get("goals").pause, ctx:get("goals"), { goal_id = "stale", revision = 0, session_id = "x", generation = 0 })
                        assert(not ok and err and err.code == "goals.stale_ref", "expected goals.stale_ref, got: " .. tostring(err))
                        error(tostring(err), 0)
                    end
                end,
            })
        else
            run_checks()
        end
    end,
}
"""


def main() -> None:
    repo_root = pathlib.Path(__file__).resolve().parent.parent
    mare_bin = os.environ.get("MARE_BIN") or str(repo_root.parent / "mare/target/debug/mare")
    if not os.path.exists(mare_bin):
        print(f"mare executable not found: {mare_bin}", file=sys.stderr)
        sys.exit(1)

    with tempfile.TemporaryDirectory(prefix="mare-contracts-e2e.") as tmp:
        tmp_path = pathlib.Path(tmp)
        pkg_dir = tmp_path / "package"
        (pkg_dir / "plugins").mkdir(parents=True)
        shutil.copy2(repo_root / "mare-plugin.toml", pkg_dir / "mare-plugin.toml")
        for plugin_dir, _ in SERVICE_PLUGINS:
            shutil.copytree(repo_root / "plugins" / plugin_dir, pkg_dir / "plugins" / plugin_dir)

        fault_dir = pkg_dir / "plugins" / "contract-probe-fault"
        fault_dir.mkdir(parents=True)
        (fault_dir / "mare-plugin.toml").write_text('name = "contract-probe-fault"\nrequires = ">=0.1.0"\n', encoding="utf-8")
        (fault_dir / "init.lua").write_text(FAULT_PLUGIN_LUA, encoding="utf-8")

        probe_dir = pkg_dir / "plugins" / "contract-probe"
        probe_dir.mkdir(parents=True)
        (probe_dir / "mare-plugin.toml").write_text('name = "contract-probe"\nrequires = ">=0.1.0"\n', encoding="utf-8")
        (probe_dir / "init.lua").write_text(PROBE_PLUGIN_LUA, encoding="utf-8")

        subprocess.run(["git", "-C", str(pkg_dir), "init", "-q", "-b", "main"], check=True)
        subprocess.run(["git", "-C", str(pkg_dir), "add", "-A"], check=True)
        subprocess.run(
            [
                "git",
                "-C",
                str(pkg_dir),
                "-c",
                "user.name=mare test",
                "-c",
                "user.email=test@example.invalid",
                "-c",
                "commit.gpgsign=false",
                "commit",
                "-qm",
                "fixture",
            ],
            check=True,
        )

        home = tmp_path / "home"
        work = tmp_path / "work"
        (home / "config").mkdir(parents=True)
        work.mkdir(parents=True)
        faux = tmp_path / "faux.json"
        faux.write_text('[{"text":"ok"}]', encoding="utf-8")
        report_path = tmp_path / "probe-report.json"

        (home / "config" / "init.lua").write_text(
            f'mare.setup {{ model = "faux/echo" }}\nmare.plugins.add {{ {{ "test/service-contracts", url = "{pkg_dir.as_uri()}" }} }}\n',
            encoding="utf-8",
        )

        env = dict(
            os.environ,
            MARE_HOME=str(home),
            MARE_FAUX_SCRIPT=str(faux),
            MARE_CONTRACT_PROBE_REPORT=str(report_path),
        )
        subprocess.run([mare_bin, "-C", str(work), "plugin", "sync"], check=True, env=env)

        proc = subprocess.Popen(
            [mare_bin, "-C", str(work), "--rpc", "--model", "faux/echo"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
            encoding="utf-8",
        )
        assert proc.stdin and proc.stdout and proc.stderr

        notifications = []
        raw_lines: list[str] = []

        def req(req_id: int, method: str, params: dict) -> dict:
            proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": req_id, "method": method, "params": params}) + "\n")
            proc.stdin.flush()
            while True:
                line = proc.stdout.readline()
                if not line:
                    err = proc.stderr.read()
                    raise RuntimeError(f"EOF waiting for {method}; stderr:\n{err}")
                raw_lines.append(line)
                msg = json.loads(line)
                if msg.get("id") == req_id:
                    return msg
                notifications.append(msg)

        init_res = req(1, "initialize", {"protocol_version": "3.0", "capabilities": {}})
        assert "error" not in init_res, f"initialize error: {init_res}"

        probe_cmd_res = req(2, "commands.run", {"line": "/contract-probe"})
        assert "error" not in probe_cmd_res, f"/contract-probe failed: {probe_cmd_res}"

        # Verify expose="lua" boundary with valid protocol field `arguments` (plus positive control on services.list + llm.list_models).
        svc_list_res = req(3, "services.list", {})
        svc_list_data = svc_list_res.get("result")
        if isinstance(svc_list_data, dict):
            svc_list_data = svc_list_data.get("data")
        assert "error" not in svc_list_res and isinstance(svc_list_data, list), f"services.list failed: {svc_list_res}"
        pos_call_res = req(4, "llm.list_models", {})
        assert "error" not in pos_call_res and "result" in pos_call_res, f"positive llm.list_models failed: {pos_call_res}"
        rpc_call_res = req(5, "goals.pause", {"ref": {"goal_id": "x"}})
        assert "error" in rpc_call_res, f"expected RPC rejection for expose='lua' method, got: {rpc_call_res}"
        err_obj = rpc_call_res["error"]
        assert (err_obj.get("data") or {}).get("code") == "method_not_found" or "not exported" in str(err_obj.get("message", "")), (
            f"expected method_not_found/not exported for expose='lua' method (not invalid_arguments), got: {rpc_call_res}"
        )

        # Verify reachable external RPC entry propagates service proxy errors cleanly.
        rpc_struct_res = req(6, "commands.run", {"line": "/contract-rpc-probe structured"})
        assert "error" in rpc_struct_res, f"expected failed commands.run, got: {rpc_struct_res}"
        assert "stale" in str(rpc_struct_res["error"].get("message", "")).lower(), rpc_struct_res

        # Out-of-process service error boundary: a provider's undeclared error that
        # carries a sentinel goes through the real core service proxy to the reachable external
        # domain RPC method. Positive control first: the sentinel really is raised there.
        inproc_res = req(7, "commands.run", {"line": "/contract-rpc-probe fault-inprocess"})
        assert "error" not in inproc_res, f"in-process fault control failed: {inproc_res}"
        boundary_start = len(raw_lines)
        fault_res = req(9, "contract_probe_fault.fail", {})
        boundary_lines = raw_lines[boundary_start:]
        assert boundary_lines and json.loads(boundary_lines[-1]).get("id") == 9, boundary_lines
        for line in boundary_lines:
            assert "__SECRET_SENTINEL__" not in line and "unexpected_probe_failure" not in line, (
                f"raw provider error left the process: {line}"
            )
        fault_err = fault_res.get("error") or {}
        assert (fault_err.get("data") or {}).get("code") == "internal", f"expected internal, got: {fault_res}"
        assert fault_err.get("message") == "contract_probe_fault.fail failed (details are in the log)", (
            f"expected the fixed public message, got: {fault_res}"
        )

        req(8, "shutdown", {})
        proc.stdin.close()
        stderr = proc.stderr.read()
        proc.wait(timeout=10)

        assert proc.returncode == 0, f"mare exited {proc.returncode}; stderr:\n{stderr}"
        assert "service contract" not in stderr.lower(), f"contract error in stderr:\n{stderr}"
        assert "undeclared" not in stderr.lower(), f"undeclared method in stderr:\n{stderr}"
        assert report_path.exists(), (
            f"probe plugin did not write report;\nstderr:\n{stderr}\nnotifications:\n{json.dumps(notifications, indent=2)}"
        )

        report = json.loads(report_path.read_text(encoding="utf-8"))
        for note in report.pop("_notes", None) or []:
            print(f"note: {note}")
        expected_services = {svc for _, svc in SERVICE_PLUGINS}
        assert set(report.keys()) == expected_services, (
            f"expected {sorted(expected_services)}, got {sorted(report.keys())}"
        )
        failed = {k: v for k, v in report.items() if not v.get("ok")}
        assert not failed, f"service probe failures: {json.dumps(failed, indent=2)}"

        # Verify via `mare doctor` that any unavailable plugins failed ONLY for their
        # specific missing core APIs (never due to contract, syntax, or config errors).
        doctor = subprocess.run([mare_bin, "-C", str(work), "doctor"], capture_output=True, text=True, env=env, encoding="utf-8")
        plugin_failures = [
            line.strip()
            for line in doctor.stdout.splitlines()
            if line.lstrip().startswith("✗   plugin") and "startup is incomplete" not in line
        ]
        expected_reasons = (
            {"btw": "required service `conversations` is not available"}
            if report.get("btw", {}).get("kind") == "unavailable_missing_core_api"
            else {}
        )
        assert len(plugin_failures) == len(expected_reasons), (
            f"unexpected doctor plugin failures: {plugin_failures}"
        )
        for plugin_name, reason in expected_reasons.items():
            # A missing required service is a start failure ("not started:") or, on the
            # old path, a setup failure ("failed:")
            matched = [
                line
                for line in plugin_failures
                if f"plugin {plugin_name} failed:" in line or f"plugin {plugin_name} not started:" in line
            ]
            assert len(matched) == 1 and reason in matched[0], (
                f"expected {plugin_name} failure to cite '{reason}', got: {plugin_failures}"
            )

        ver = subprocess.run([mare_bin, "--version"], capture_output=True, text=True, check=True, encoding="utf-8").stdout.strip()
        expected_commit = os.environ.get("MARE_EXPECTED_COMMIT")
        if expected_commit:
            assert expected_commit in ver, f"expected mare commit {expected_commit}, got: {ver}"
        summary = ", ".join(f"{k}={report[k]['kind']}" for k in sorted(report))
        print(f"{ver}: verified all {len(report)} service plugins ({summary})")

        # Negative counterexample: empty method errors={} on goals.pause must downgrade goals.stale_ref to 'internal'.
        goal_init = pkg_dir / "plugins" / "goal" / "init.lua"
        goal_text = goal_init.read_text(encoding="utf-8")
        pause_marker = "pause = {"
        pause_idx = goal_text.find(pause_marker)
        assert pause_idx != -1, "pause method not found in goal/init.lua"
        old_err_decl = 'errors = { "stale_ref", "goal_fault", "goal_unavailable" }'
        err_idx = goal_text.find(old_err_decl, pause_idx)
        assert err_idx != -1, "pause errors declaration not found in goal/init.lua"
        goal_init.write_text(
            goal_text[:err_idx] + "errors = {}" + goal_text[err_idx + len(old_err_decl) :],
            encoding="utf-8",
        )
        subprocess.run(["git", "-C", str(pkg_dir), "add", "-A"], check=True)
        subprocess.run(
            [
                "git", "-C", str(pkg_dir),
                "-c", "user.name=mare test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false",
                "commit", "-qm", "counterexample",
            ],
            check=True,
        )
        subprocess.run([mare_bin, "-C", str(work), "plugin", "update"], check=True, env=env)
        neg_report = tmp_path / "neg-report.json"
        neg_env = dict(env, MARE_CONTRACT_PROBE_REPORT=str(neg_report))
        proc2 = subprocess.Popen(
            [mare_bin, "-C", str(work), "--rpc", "--model", "faux/echo"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=neg_env,
            encoding="utf-8",
        )
        assert proc2.stdin and proc2.stdout
        def req2(rid, method, params):
            proc2.stdin.write(json.dumps({"jsonrpc": "2.0", "id": rid, "method": method, "params": params}) + "\n")
            proc2.stdin.flush()
            while True:
                line = proc2.stdout.readline()
                if not line:
                    raise RuntimeError(f"mare exited before response to {method}")
                msg = json.loads(line)
                if msg.get("id") == rid:
                    return msg
        req2(1, "initialize", {"protocol_version": "3.0", "capabilities": {}})
        req2(2, "commands.run", {"line": "/contract-probe"})
        req2(3, "shutdown", {})
        proc2.stdin.close()
        proc2.wait(timeout=10)
        neg = json.loads(neg_report.read_text(encoding="utf-8"))
        neg.pop("_notes", None)
        assert not neg["goals"]["ok"] and "got: internal" in neg["goals"]["error"], (
            f"expected undeclared error downgrade to internal, got: {neg['goals']}"
        )


if __name__ == "__main__":
    main()
